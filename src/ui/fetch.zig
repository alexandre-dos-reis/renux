//! A file or a folder on its way from a pane's machine to this computer's Downloads folder.
//! A message at the foot of the window says how far it has got and can stop it; another says
//! where it went, and shows it there.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const fetch = @import("../rex/fetch.zig");
const Server = @import("../rex/server.zig").Server;

const gpa = std.heap.c_allocator;

/// Brings `path`, as the pane names it, to the Downloads folder.
pub fn start(widget: *gtk.Widget, server: *Server, session_id: []const u8, block_id: []const u8, path: []const u8) void {
    const ancestor = widget.getAncestor(adw.ToastOverlay.getGObjectType()) orelse return server.notifyMessage("Couldn't show the download's progress");
    const into = downloads() orelse return server.notifyMessage("Couldn't find this computer's Downloads folder");
    defer gpa.free(into);
    const name = gpa.dupe(u8, std.fs.path.basename(std.mem.trimEnd(u8, path, "/"))) catch return server.notifyMessage("Couldn't start the download");
    const p = gpa.create(Progress) catch {
        gpa.free(name);
        return server.notifyMessage("Couldn't start the download");
    };
    p.* = .{ .overlay = @ptrCast(ancestor), .toast = adw.Toast.new(""), .name = name };
    p.transfer = fetch.Fetch.start(server, session_id, block_id, path, into, .{ .ctx = p, .progress = Progress.changed, .finished = Progress.finished }) catch |err| {
        p.toast.unref();
        gpa.free(p.name);
        gpa.destroy(p);
        return server.notifyMessage(switch (err) {
            error.Offline => "Connect to this host before downloading from it",
            else => "Couldn't start the download",
        });
    };
    _ = p.overlay.as(gobject.Object).ref();
    p.toast.setUseMarkup(0);
    // It stays for as long as the download takes.
    p.toast.setTimeout(0);
    p.toast.setButtonLabel("Cancel");
    p.clicked = adw.Toast.signals.button_clicked.connect(p.toast, *Progress, &Progress.cancelled, p, .{});
    p.say(0, 0);
    // The overlay keeps the one it is given.
    _ = p.toast.as(gobject.Object).ref();
    p.overlay.addToast(p.toast);
}

/// This computer's Downloads folder, made if it isn't there.
fn downloads() ?[]u8 {
    const path = if (glib.getUserSpecialDir(.directory_download)) |known|
        gpa.dupeSentinel(u8, std.mem.span(known), 0) catch return null
    else
        std.fmt.allocPrintSentinel(gpa, "{s}/Downloads", .{std.mem.span(glib.getHomeDir())}, 0) catch return null;
    if (glib.mkdirWithParents(path.ptr, 0o755) != 0) {
        gpa.free(path);
        return null;
    }
    return path;
}

const Progress = struct {
    overlay: *adw.ToastOverlay,
    toast: *adw.Toast,
    transfer: *fetch.Fetch = undefined,
    /// What was asked for, by the last part of its path.
    name: []u8,
    clicked: c_ulong = 0,

    fn changed(ctx: *anyopaque, files: u32, bytes: u64) void {
        const p: *Progress = @ptrCast(@alignCast(ctx));
        p.say(files, bytes);
    }

    fn say(p: *Progress, files: u32, bytes: u64) void {
        var buf: [600]u8 = undefined;
        var amount: [96]u8 = undefined;
        var whole: [32]u8 = undefined;
        const t = p.transfer;
        const text: [:0]const u8 = (if (bytes == 0 and files == 0)
            std.fmt.bufPrintSentinel(&buf, "Downloading {s}…", .{p.name}, 0)
        else if (t.total > 0)
            std.fmt.bufPrintSentinel(&buf, "Downloading {s} · {s} of {s}", .{ p.name, sizeText(&amount, bytes), sizeText(&whole, t.total) }, 0)
        else
            std.fmt.bufPrintSentinel(&buf, "Downloading {s} · {s}", .{ p.name, amountText(&amount, t.folder, files, bytes) }, 0)) catch "Downloading…";
        p.toast.setTitle(text.ptr);
    }

    fn cancelled(_: *adw.Toast, p: *Progress) callconv(.c) void {
        p.transfer.cancel();
    }

    fn finished(ctx: *anyopaque, outcome: fetch.Outcome, message: []const u8) void {
        const p: *Progress = @ptrCast(@alignCast(ctx));
        const t = p.transfer;
        // Nothing more is heard from it, and its button has nothing left to stop.
        gobject.signalHandlerDisconnect(p.toast.as(gobject.Object), p.clicked);
        p.toast.dismiss();
        p.toast.unref();

        var buf: [900]u8 = undefined;
        var amount: [96]u8 = undefined;
        var left: [48]u8 = undefined;
        const left_out = if (t.skipped == 0) "" else std.fmt.bufPrint(&left, " · {d} left out", .{t.skipped}) catch "";
        // Under the name it has here, which is numbered when the name was taken.
        const made = if (t.to) |to| std.fs.path.basename(to) else p.name;
        const kept = t.count > 0 and t.to != null;
        const text: [:0]const u8 = switch (outcome) {
            .done => std.fmt.bufPrintSentinel(&buf, "Downloaded {s} to Downloads · {s}{s}", .{ made, amountText(&amount, t.folder, t.count, t.bytes), left_out }, 0),
            .cancelled => if (kept and t.folder)
                std.fmt.bufPrintSentinel(&buf, "Download cancelled · {s} of {s} kept", .{ amountText(&amount, true, t.count, t.bytes), made }, 0)
            else
                std.fmt.bufPrintSentinel(&buf, "Download of {s} cancelled", .{p.name}, 0),
            .failed => std.fmt.bufPrintSentinel(&buf, "{s}: {s}", .{ p.name, message }, 0),
        } catch "Download finished";
        const toast = adw.Toast.new(text.ptr);
        toast.setUseMarkup(0);
        toast.setTimeout(8);
        if (kept) if (glib.strndup(t.to.?.ptr, t.to.?.len)) |path| {
            toast.as(gobject.Object).setDataFull("renux-path", path, &glib.free);
            toast.setButtonLabel("Show");
            _ = adw.Toast.signals.button_clicked.connect(toast, *adw.ToastOverlay, &show, p.overlay, .{});
        };
        p.overlay.addToast(toast);
        p.overlay.as(gobject.Object).unref();
        gpa.free(p.name);
        gpa.destroy(p);
    }

    /// Opens the folder a download went to, with the download picked out in it.
    fn show(toast: *adw.Toast, overlay: *adw.ToastOverlay) callconv(.c) void {
        const path: [*:0]const u8 = @ptrCast(toast.as(gobject.Object).getData("renux-path") orelse return);
        const file = gio.File.newForPath(path);
        defer file.unref();
        const launcher = gtk.FileLauncher.new(file);
        defer launcher.unref();
        const window: ?*gtk.Window = if (overlay.as(gtk.Widget).getRoot()) |root| @ptrCast(@alignCast(root)) else null;
        launcher.openContainingFolder(window, null, null, null);
    }
};

/// How much has come: `12 files · 3.4 MB` for a folder, the size alone for a file.
fn amountText(buf: []u8, folder: bool, files: u32, bytes: u64) []const u8 {
    var size: [32]u8 = undefined;
    const s = sizeText(&size, bytes);
    if (!folder) return std.fmt.bufPrint(buf, "{s}", .{s}) catch "";
    return std.fmt.bufPrint(buf, "{d} {s} · {s}", .{ files, if (files == 1) "file" else "files", s }) catch "";
}

pub fn sizeText(buf: []u8, bytes: u64) [:0]const u8 {
    const n: f64 = @floatFromInt(bytes);
    return (if (bytes < 1024)
        std.fmt.bufPrintSentinel(buf, "{d} B", .{bytes}, 0)
    else if (bytes < 1024 * 1024)
        std.fmt.bufPrintSentinel(buf, "{d:.1} KB", .{n / 1024}, 0)
    else if (bytes < 1024 * 1024 * 1024)
        std.fmt.bufPrintSentinel(buf, "{d:.1} MB", .{n / (1024 * 1024)}, 0)
    else
        std.fmt.bufPrintSentinel(buf, "{d:.2} GB", .{n / (1024 * 1024 * 1024)}, 0)) catch "";
}

test "how much of a download has come" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("1 file · 12 B", amountText(&buf, true, 1, 12));
    try std.testing.expectEqualStrings("42 files · 3.0 MB", amountText(&buf, true, 42, 3 * 1024 * 1024));
    try std.testing.expectEqualStrings("1.50 GB", amountText(&buf, false, 1, 3 * 512 * 1024 * 1024));
}

//! A file on its way to a pane's machine. The pane draws it as dim text after its cursor, where
//! Rex will paste the path; a toast reports an upload that didn't arrive.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const upload = @import("../rex/upload.zig");
const Server = @import("../rex/server.zig").Server;

const gpa = std.heap.c_allocator;
var shown: std.ArrayList(*Progress) = .empty;

/// The pane showing an upload, told to draw again as the upload moves on.
pub const Watcher = struct { ctx: *anyopaque, changed: *const fn (ctx: *anyopaque) void };

/// Sends `files` to a pane's machine. `temporary` is for a single file made for the occasion,
/// such as a pasted picture, which is deleted afterwards.
pub fn start(widget: *gtk.Widget, server: *Server, session_id: []const u8, block_id: []const u8, files: []const *gio.File, temporary: bool, watcher: Watcher) bool {
    const ancestor = widget.getAncestor(adw.ToastOverlay.getGObjectType()) orelse {
        server.notifyMessage("Couldn't show file upload progress");
        return false;
    };
    shown.ensureUnusedCapacity(gpa, 1) catch {
        server.notifyMessage("Couldn't start the file upload");
        return false;
    };
    const p = gpa.create(Progress) catch {
        server.notifyMessage("Couldn't start the file upload");
        return false;
    };
    p.* = .{ .overlay = @ptrCast(ancestor), .watcher = watcher };
    p.transfer = upload.Upload.start(server, session_id, block_id, files, .{ .ctx = p, .progress = Progress.changed, .finished = Progress.finished }) catch |err| {
        gpa.destroy(p);
        server.notifyMessage(switch (err) {
            error.ServerOffline => "Connect to this host before sending a file",
            error.AlreadyUploading => "Files are already being sent to this pane",
            error.InvalidName => "That file's name isn't valid UTF-8",
            else => "Couldn't start the file upload",
        });
        return false;
    };
    if (temporary and files.len == 1) {
        _ = files[0].ref();
        p.source = files[0];
    }
    _ = p.overlay.as(gobject.Object).ref();
    shown.appendAssumeCapacity(p);
    watcher.changed(watcher.ctx);
    return true;
}

/// The upload under way to a pane, if there is one.
pub fn find(server: *Server, block_id: []const u8) ?*Progress {
    for (shown.items) |p| if (p.transfer.server == server and std.mem.eql(u8, p.transfer.block_id, block_id)) return p;
    return null;
}

/// Forgets a pane that is going away. Its upload carries on and reports by toast.
pub fn unwatch(ctx: *anyopaque) void {
    for (shown.items) |p| if (p.watcher) |w| {
        if (w.ctx == ctx) p.watcher = null;
    };
}

pub const Progress = struct {
    overlay: *adw.ToastOverlay,
    transfer: *upload.Upload = undefined,
    watcher: ?Watcher,
    /// How much has been sent; unknown until the first bytes are on their way.
    percent: ?u8 = null,
    /// Everything is sent and the server hasn't confirmed it yet. A cancel from here on can't
    /// tell whether the file arrived.
    finishing: bool = false,
    sent: u64 = 0,
    total: u64 = 0,
    source: ?*gio.File = null,

    pub fn name(p: *const Progress) []const u8 {
        return p.transfer.name;
    }

    /// How many more files are being sent along with the one named.
    pub fn others(p: *const Progress) usize {
        return p.transfer.files.len - 1;
    }

    pub fn cancel(p: *Progress) void {
        p.transfer.cancel();
    }

    /// How much of the file has been sent, from 0 to 1.
    pub fn fraction(p: *const Progress) f64 {
        if (p.finishing) return 1;
        if (p.percent == null or p.total == 0) return 0;
        return @as(f64, @floatFromInt(p.sent)) / @as(f64, @floatFromInt(p.total));
    }

    fn changed(ctx: *anyopaque, sent: u64, total: u64) void {
        const p: *Progress = @ptrCast(@alignCast(ctx));
        const percent: u8 = if (total == 0) 100 else @intCast(@min(100, @as(u128, sent) * 100 / total));
        const finishing = sent == total;
        p.sent = sent;
        p.total = total;
        if (p.percent == percent and p.finishing == finishing) return;
        p.percent = percent;
        p.finishing = finishing;
        if (p.watcher) |w| w.changed(w.ctx);
    }

    fn finished(ctx: *anyopaque, outcome: upload.Outcome, message: []const u8) void {
        const p: *Progress = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOfScalar(*Progress, shown.items, p)) |i| _ = shown.swapRemove(i);
        // The pasted path says a file arrived. Anything else gets a toast, and so does an
        // arrival whose pane is no longer there to show it.
        if (outcome != .sent or p.watcher == null) {
            var buf: [900]u8 = undefined;
            var more: [32]u8 = undefined;
            const and_more = if (p.others() == 0) "" else std.fmt.bufPrint(&more, " and {d} more", .{p.others()}) catch "";
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}: {s}", .{ p.transfer.name, and_more, message }, 0) catch "File upload finished";
            const toast = adw.Toast.new(text.ptr);
            toast.setUseMarkup(0);
            toast.setTimeout(8);
            p.overlay.addToast(toast);
        }
        if (p.watcher) |w| w.changed(w.ctx);
        p.overlay.as(gobject.Object).unref();
        if (p.source) |file| {
            file.deleteAsync(0, null, null, null);
            file.unref();
        }
        gpa.destroy(p);
    }
};

//! Explicit, read-only previews. Remote bytes are fetched only after a user gesture.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gdk = @import("gdk");
const gobject = @import("gobject");
const download = @import("../rex/download.zig");
const Server = @import("../rex/server.zig").Server;
const gpa = std.heap.c_allocator;

pub fn show(parent: *gtk.Widget, server: *Server, sid: []const u8, bid: []const u8, path: []const u8) void {
    _ = create(parent, server, sid, bid, path);
}

fn create(parent: *gtk.Widget, server: *Server, sid: []const u8, bid: []const u8, path: []const u8) ?*Preview {
    const p = gpa.create(Preview) catch return null;
    const title = gpa.dupeSentinel(u8, path, 0) catch {
        gpa.destroy(p);
        return null;
    };
    defer gpa.free(title);
    const dialog = adw.Dialog.new();
    dialog.setTitle(title.ptr);
    dialog.setContentWidth(800);
    dialog.setContentHeight(560);
    const box = gtk.Box.new(.vertical, 8);
    box.append(adw.HeaderBar.new().as(gtk.Widget));
    const location = std.fmt.allocPrintSentinel(gpa, "{s}\n{s}", .{ path, server.url }, 0) catch null;
    if (location) |text| {
        defer gpa.free(text);
        const label = gtk.Label.new(text.ptr);
        label.setSelectable(1);
        label.setEllipsize(.middle);
        box.append(label.as(gtk.Widget));
    }
    const status = gtk.Label.new("Loading file… (up to 16 MiB)");
    box.append(status.as(gtk.Widget));
    const scroller = gtk.ScrolledWindow.new();
    scroller.as(gtk.Widget).setVexpand(1);
    box.append(scroller.as(gtk.Widget));
    const actions = gtk.Box.new(.horizontal, 8);
    const open = gtk.Button.newWithLabel("Open With…");
    open.as(gtk.Widget).setSensitive(0);
    actions.append(open.as(gtk.Widget));
    const zoom = gtk.Button.newWithLabel("Actual Size / Fit");
    zoom.as(gtk.Widget).setVisible(0);
    actions.append(zoom.as(gtk.Widget));
    const close = gtk.Button.newWithLabel("Close / Cancel");
    actions.append(close.as(gtk.Widget));
    box.append(actions.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    p.* = .{ .dialog = dialog, .status = status, .scroller = scroller, .open = open, .zoom = zoom };
    _ = dialog.as(gobject.Object).ref();
    _ = adw.Dialog.signals.closed.connect(dialog, *Preview, &Preview.closed, p, .{});
    _ = gtk.Button.signals.clicked.connect(close, *Preview, &Preview.close, p, .{});
    _ = gtk.Button.signals.clicked.connect(open, *Preview, &Preview.openFile, p, .{});
    _ = gtk.Button.signals.clicked.connect(zoom, *Preview, &Preview.zoomImage, p, .{});
    dialog.present(parent);
    p.transfer = download.Download.start(server, sid, bid, path, .{ .ctx = p, .finished = Preview.received }) catch {
        status.setText("Couldn't start preview; connect to the host and check the path");
        return p;
    };
    return p;
}

const Preview = struct {
    dialog: *adw.Dialog,
    status: *gtk.Label,
    scroller: *gtk.ScrolledWindow,
    open: *gtk.Button,
    zoom: *gtk.Button,
    picture: ?*gtk.Picture = null,
    texture: ?*gdk.Texture = null,
    transfer: ?*download.Download = null,
    data: ?*glib.Bytes = null,
    file: ?*gio.File = null,
    refs: usize = 1,
    gone: bool = false,
    actual: bool = false,
    launched: bool = false,

    fn unref(p: *Preview) void {
        p.refs -= 1;
        if (p.refs != 0) return;
        if (p.data) |b| b.unref();
        if (p.texture) |t| t.as(gobject.Object).unref();
        if (p.file) |f| {
            if (!p.launched) f.deleteAsync(0, null, null, null);
            f.unref();
        }
        p.dialog.as(gobject.Object).unref();
        gpa.destroy(p);
    }
    fn close(_: *gtk.Button, p: *Preview) callconv(.c) void {
        _ = p.dialog.close();
    }
    fn closed(_: *adw.Dialog, p: *Preview) callconv(.c) void {
        p.gone = true;
        if (p.transfer) |d| d.cancel();
        p.unref();
    }
    fn received(ctx: *anyopaque, bytes: ?[]const u8, message: []const u8) void {
        const p: *Preview = @ptrCast(@alignCast(ctx));
        p.transfer = null;
        if (p.gone) return;
        const data = bytes orelse {
            const text = gpa.dupeSentinel(u8, message, 0) catch return;
            defer gpa.free(text);
            p.status.setText(text.ptr);
            return;
        };
        p.data = glib.Bytes.new(data.ptr, data.len);
        p.status.setText("Preparing preview…");
        p.refs += 1;
        const task = gio.Task.new(p.dialog.as(gobject.Object), null, &prepared, p);
        // Preview's worker reference keeps the bytes and result alive.
        task.setTaskData(p, null);
        task.runInThread(&prepare);
        task.unref();
    }
    fn prepare(task: *gio.Task, _: *gobject.Object, ctx: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const p: *Preview = @ptrCast(@alignCast(ctx.?));
        const bytes = p.data.?;
        const raw = bytes.getData(null) orelse "";
        const data = raw[0..bytes.getSize()];
        if (imageSize(data)) |size| {
            if (size[0] > 0 and size[1] > 0 and size[0] <= 16384 and size[1] <= 16384 and @as(u64, size[0]) * size[1] <= 32 * 1024 * 1024) {
                p.texture = gdk.Texture.newFromBytes(bytes, null);
            }
        }
        task.returnBoolean(1);
    }
    fn prepared(_: ?*gobject.Object, result: *gio.AsyncResult, ctx: ?*anyopaque) callconv(.c) void {
        const p: *Preview = @ptrCast(@alignCast(ctx.?));
        defer p.unref();
        _ = @as(*gio.Task, @ptrCast(result)).propagateBoolean(null);
        if (p.gone) return;
        p.open.as(gtk.Widget).setSensitive(1);
        if (p.texture) |texture| {
            const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
            picture.setCanShrink(1);
            picture.setContentFit(.contain);
            p.picture = picture;
            p.scroller.setChild(picture.as(gtk.Widget));
            p.zoom.as(gtk.Widget).setVisible(1);
            p.status.setText("Image preview");
            return;
        }
        const bytes = p.data.?;
        const raw = bytes.getData(null);
        const data = if (raw) |r| r[0..bytes.getSize()] else "";
        if (isText(data)) {
            const text = gtk.TextView.new();
            text.setEditable(0);
            text.setCursorVisible(0);
            text.setMonospace(1);
            const own = gpa.dupeSentinel(u8, data, 0) catch return;
            defer gpa.free(own);
            text.getBuffer().setText(own.ptr, @intCast(data.len));
            p.scroller.setChild(text.as(gtk.Widget));
            p.status.setText("Read-only text");
        } else p.status.setText("No inline preview for this type or size. Use Open With…");
    }
    fn zoomImage(_: *gtk.Button, p: *Preview) callconv(.c) void {
        const picture = p.picture orelse return;
        p.actual = !p.actual;
        picture.as(gtk.Widget).setSizeRequest(if (p.actual) p.texture.?.getWidth() else -1, if (p.actual) p.texture.?.getHeight() else -1);
    }
    fn openFile(_: *gtk.Button, p: *Preview) callconv(.c) void {
        p.open.as(gtk.Widget).setSensitive(0);
        p.refs += 1;
        const task = gio.Task.new(p.dialog.as(gobject.Object), null, &saved, p);
        task.setTaskData(p, null);
        task.runInThread(&save);
        task.unref();
    }
    fn save(task: *gio.Task, _: *gobject.Object, ctx: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const p: *Preview = @ptrCast(@alignCast(ctx.?));
        if (p.file == null) {
            var io: *gio.FileIOStream = undefined;
            if (gio.File.newTmp("renux-preview-XXXXXX", &io, null)) |file| {
                defer io.unref();
                const stream = io.as(gio.IOStream);
                defer _ = stream.close(null, null);
                const b = p.data.?;
                const raw = b.getData(null) orelse "";
                if (stream.getOutputStream().writeAll(@constCast(raw), b.getSize(), null, null, null) != 0 and stream.close(null, null) != 0) {
                    p.file = file;
                } else {
                    _ = file.delete(null, null);
                    file.unref();
                }
            }
        }
        task.returnBoolean(1);
    }
    fn saved(_: ?*gobject.Object, result: *gio.AsyncResult, ctx: ?*anyopaque) callconv(.c) void {
        const p: *Preview = @ptrCast(@alignCast(ctx.?));
        defer p.unref();
        _ = @as(*gio.Task, @ptrCast(result)).propagateBoolean(null);
        if (p.gone) return;
        p.open.as(gtk.Widget).setSensitive(1);
        const file = p.file orelse {
            p.status.setText("Couldn't save a temporary copy");
            return;
        };
        const launcher = gtk.FileLauncher.new(file);
        launcher.setAlwaysAsk(1);
        p.refs += 1;
        const parent: ?*gtk.Window = @ptrCast(@alignCast(p.dialog.as(gtk.Widget).getRoot()));
        launcher.launch(parent, null, &launchedFile, p);
        launcher.unref();
    }
    fn launchedFile(source: ?*gobject.Object, result: *gio.AsyncResult, ctx: ?*anyopaque) callconv(.c) void {
        const p: *Preview = @ptrCast(@alignCast(ctx.?));
        defer p.unref();
        const launcher: *gtk.FileLauncher = @ptrCast(source.?);
        if (launcher.launchFinish(result, null) != 0) p.launched = true;
    }
};

pub fn isText(data: []const u8) bool {
    if (data.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(data)) return false;
    for (data) |c| if (c < 32 and c != '\n' and c != '\r' and c != '\t') return false;
    return true;
}

/// Inspect dimensions before handing encoded data to an image decoder.
pub fn imageSize(data: []const u8) ?[2]u32 {
    if (data.len >= 24 and std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, data[12..16], "IHDR")) return .{ std.mem.readInt(u32, data[16..20], .big), std.mem.readInt(u32, data[20..24], .big) };
    if (data.len >= 10 and (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a"))) return .{ std.mem.readInt(u16, data[6..8], .little), std.mem.readInt(u16, data[8..10], .little) };
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return null;
    var i: usize = 2;
    while (i + 4 <= data.len) {
        if (data[i] != 0xff) return null;
        const marker = data[i + 1];
        if (marker == 0xff) {
            i += 1;
            continue;
        }
        if (marker == 0xda or marker == 0xd9) return null;
        const n = std.mem.readInt(u16, data[i + 2 ..][0..2], .big);
        if (n < 2 or n > data.len - i - 2) return null;
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc and n >= 7) return .{ std.mem.readInt(u16, data[i + 7 ..][0..2], .big), std.mem.readInt(u16, data[i + 5 ..][0..2], .big) };
        i += n + 2;
    }
    return null;
}

test "preview integration dialog" {
    const mode = std.mem.span(std.c.getenv("RENUX_PREVIEW_TEST_MODE") orelse return error.SkipZigTest);
    const success = std.mem.eql(u8, mode, "image") or std.mem.eql(u8, mode, "text") or std.mem.eql(u8, mode, "empty") or std.mem.eql(u8, mode, "binary");
    const cancel = std.mem.eql(u8, mode, "cancel");
    if (!success and !cancel) return;
    adw.init();
    var server: Server = .{ .url = try gpa.dupe(u8, std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_URL").?)), .client_label = try gpa.dupe(u8, "preview UI test"), .state = .online };
    defer gpa.free(server.url);
    defer gpa.free(server.client_label);
    const window = adw.Window.new();
    window.as(gtk.Window).setDefaultSize(900, 700);
    window.as(gtk.Window).present();
    defer window.as(gtk.Window).destroy();
    const p = create(window.as(gtk.Widget), &server, std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_SESSION").?), std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_BLOCK").?), std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_FILE").?)) orelse return error.NoDialog;
    p.refs += 1;
    defer {
        p.unref();
        const until = glib.getMonotonicTime() + 100_000;
        while (glib.getMonotonicTime() < until) {
            _ = glib.MainContext.default().iteration(0);
            glib.usleep(1000);
        }
    }
    if (cancel) _ = p.dialog.close();
    const context = glib.MainContext.default();
    const until = glib.getMonotonicTime() + 10_000_000;
    while (glib.getMonotonicTime() < until) {
        _ = context.iteration(0);
        if (cancel and p.gone or !cancel and p.open.as(gtk.Widget).getSensitive() != 0) break;
        glib.usleep(1000);
    }
    if (cancel) {
        try std.testing.expect(p.gone);
        try std.testing.expect(p.transfer == null);
    } else {
        try std.testing.expect(p.open.as(gtk.Widget).getSensitive() != 0);
        if (std.mem.eql(u8, mode, "image")) {
            try std.testing.expect(p.picture != null);
            try std.testing.expectEqual(@as(c_int, 3), p.texture.?.getWidth());
            Preview.zoomImage(p.zoom, p);
            try std.testing.expect(p.actual);
            Preview.zoomImage(p.zoom, p);
            try std.testing.expect(!p.actual);
        } else if (std.mem.eql(u8, mode, "binary")) {
            try std.testing.expect(p.scroller.getChild() == null);
            // Exercise the Open With copy without launching an external app during tests.
            const task = gio.Task.new(p.dialog.as(gobject.Object), null, null, null);
            defer task.unref();
            task.setTaskData(p, null);
            task.runInThreadSync(&Preview.save);
            try std.testing.expect(task.propagateBoolean(null) != 0);
            const file = p.file orelse return error.NoTemporaryCopy;
            const info = file.queryInfo("unix::mode,standard::size", .{}, null, null) orelse return error.NoFileInfo;
            defer info.unref();
            try std.testing.expectEqual(@as(u32, 0o600), info.getAttributeUint32("unix::mode") & 0o777);
            try std.testing.expectEqual(@as(i64, @intCast(p.data.?.getSize())), info.getSize());
        } else try std.testing.expect(p.scroller.getChild() != null);
        _ = p.dialog.close();
        while (!p.gone and glib.getMonotonicTime() < until) {
            _ = context.iteration(0);
            glib.usleep(1000);
        }
        try std.testing.expect(p.gone);
    }
}

test "preview rejects binary text and reads image bounds before decoding" {
    try std.testing.expect(isText("hello\n世界\t"));
    try std.testing.expect(!isText("hello\x00world"));
    try std.testing.expect(!isText("\x1b[31m"));
    try std.testing.expectEqual(@as(?[2]u32, .{ 2, 3 }), imageSize("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x03"));
    try std.testing.expectEqual(@as(?[2]u32, .{ 2, 3 }), imageSize("GIF89a\x02\x00\x03\x00"));
    try std.testing.expectEqual(@as(?[2]u32, .{ 2, 3 }), imageSize("\xff\xd8\xff\xc0\x00\x07\x08\x00\x03\x00\x02"));
    try std.testing.expect(imageSize("\xff\xd8\xff\xc0\x00\x07") == null);
    try std.testing.expect(imageSize("not an image") == null);
}

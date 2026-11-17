//! Bounded, cancellable file reads through Rex, including pane-relative local paths.
const std = @import("std");
const glib = @import("glib");
const control = @import("control.zig");
const ws = @import("ws.zig");
const json = @import("../util/json.zig");
const Server = @import("server.zig").Server;
const gpa = std.heap.c_allocator;
pub const limit = 16 * 1024 * 1024;
pub const Listener = struct {
    ctx: *anyopaque,
    finished: *const fn (*anyopaque, ?[]const u8, []const u8) void,
    /// Told the file's whole path once Rex has found it, before any of it arrives.
    located: ?*const fn (*anyopaque, []const u8) void = null,
};
var active: std.ArrayList(*Download) = .empty;

pub fn cancelForServer(server: *Server) void {
    var i: usize = 0;
    while (i < active.items.len) {
        if (active.items[i].server == server) active.items[i].cancel() else i += 1;
    }
}

pub const Download = struct {
    server: *Server,
    sid: []u8,
    bid: []u8,
    path: []u8,
    listener: Listener,
    ctl: ?*control.Control = null,
    socket: ?*ws.Socket = null,
    bytes: std.ArrayList(u8) = .empty,
    welcomed: bool = false,
    done: bool = false,
    timer: c_uint = 0,

    pub fn start(server: *Server, sid: []const u8, bid: []const u8, path: []const u8, listener: Listener) !*Download {
        if (server.state != .online) return error.Offline;
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const d = try gpa.create(Download);
        errdefer gpa.destroy(d);
        const s = try gpa.dupe(u8, sid);
        errdefer gpa.free(s);
        const b = try gpa.dupe(u8, bid);
        errdefer gpa.free(b);
        const p = try gpa.dupe(u8, path);
        errdefer gpa.free(p);
        try active.append(gpa, d);
        errdefer _ = active.pop();
        d.* = .{ .server = server, .sid = s, .bid = b, .path = p, .listener = listener };
        d.ctl = try control.Control.open(server.connectionUrl(), "Renux file preview", @import("server.zig").version, null, 13, .{
            .ctx = d,
            .on_welcome = welcome,
            .on_event = event,
            .on_closed = closed,
        });
        d.timer = glib.timeoutAdd(60_000, &timeout, d);
        return d;
    }

    pub fn cancel(d: *Download) void {
        d.finish(false, "Preview cancelled");
    }

    fn finish(d: *Download, success: bool, detail: []const u8) void {
        if (d.done) return;
        d.done = true;
        if (std.mem.indexOfScalar(*Download, active.items, d)) |i| _ = active.swapRemove(i);
        if (d.timer != 0) _ = glib.Source.remove(d.timer);
        if (d.socket) |s| s.close();
        if (d.ctl) |c| c.close();
        // Data and message are borrowed only for this callback.
        d.listener.finished(d.listener.ctx, if (success) d.bytes.items else null, detail);
        d.bytes.deinit(gpa);
        gpa.free(d.sid);
        gpa.free(d.bid);
        gpa.free(d.path);
        gpa.destroy(d);
    }

    fn timeout(data: ?*anyopaque) callconv(.c) c_int {
        const d: *Download = @ptrCast(@alignCast(data.?));
        d.timer = 0;
        d.finish(false, "File preview timed out");
        return 0;
    }
    fn welcome(ctx: *anyopaque, ctl: *control.Control, w: control.Welcome) void {
        const d: *Download = @ptrCast(@alignCast(ctx));
        if (w.api_revision < 13) return d.finish(false, "Update Rex on this host to preview files (API 13 required)");
        ctl.call("session.attach", .{ .session_id = d.sid }, control.Callback.of(Download, d, attached));
    }
    fn event(_: *anyopaque, _: *control.Control, _: []const u8, _: ?json.Value) void {}
    fn closed(ctx: *anyopaque, _: *control.Control, _: []const u8, _: u16) void {
        const d: *Download = @ptrCast(@alignCast(ctx));
        d.finish(false, "Lost the preview connection (Rex API 13 required)");
    }
    fn attached(d: *Download, result: control.Result) void {
        if (d.done) return;
        switch (result) {
            .err => return d.finish(false, "Couldn't attach to the file's session"),
            .ok => {},
        }
        const id = glib.uuidStringRandom();
        defer glib.free(id);
        var buf: [48]u8 = undefined;
        const ref = std.fmt.bufPrint(&buf, "download:{s}", .{std.mem.span(id)}) catch unreachable;
        d.ctl.?.call("com.superlogical.terminal.download_begin", .{ .session_id = d.sid, .block_id = d.bid, .args = .{ .ref = ref, .path = d.path } }, control.Callback.of(Download, d, reserved));
    }
    fn reserved(d: *Download, result: control.Result) void {
        if (d.done) return;
        const payload = switch (result) {
            .ok => |p| p,
            .err => return d.finish(false, "Can't read this file: check the path and permissions"),
        };
        if (d.listener.located) |tell| if (json.str(payload, "path")) |whole| tell(d.listener.ctx, whole);
        if (json.int(payload, "size")) |size| if (size > limit) return d.finish(false, "File is too large to preview (16 MiB limit)");
        const ticket = json.str(payload, "ticket") orelse return d.finish(false, "Rex returned no download ticket");
        const hello = @import("stream.zig").helloFor(ticket) orelse return d.finish(false, "Invalid download ticket");
        d.socket = ws.Socket.open(.{ .url = d.server.connectionUrl(), .path = "/api/data", .protocol = "rex.data.bytes.v1", .first_message = &hello }, .{
            .ctx = d,
            .on_open = opened,
            .on_message = message,
            .on_close = ended,
        }) catch return d.finish(false, "Couldn't open the download connection");
    }
    fn opened(_: *anyopaque) void {}
    fn message(ctx: *anyopaque, binary: bool, data: []const u8) void {
        const d: *Download = @ptrCast(@alignCast(ctx));
        if (!binary) return d.finish(false, "Invalid file data from Rex");
        if (!d.welcomed) {
            if (data.len != 32 or data[0] != 0x81) return d.finish(false, "Rex refused the download connection");
            d.welcomed = true;
            return;
        }
        if (data.len > limit - d.bytes.items.len) return d.finish(false, "File exceeded the 16 MiB preview limit");
        d.bytes.appendSlice(gpa, data) catch return d.finish(false, "Not enough memory for this preview");
    }
    fn ended(ctx: *anyopaque, code: u16, _: []const u8) void {
        const d: *Download = @ptrCast(@alignCast(ctx));
        d.socket = null;
        d.finish(d.welcomed and code == 1000, if (d.welcomed and code == 1000) "" else "Download ended before completion");
    }
};

test "download framing rejects incomplete transfers and bounds actual bytes" {
    const Probe = struct {
        success: bool = false,
        count: usize = 0,
        fn finished(ctx: *anyopaque, bytes: ?[]const u8, _: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.count += 1;
            p.success = bytes != null;
            if (bytes) |b| std.debug.assert(std.mem.eql(u8, b, "\x81payload"));
        }
    };
    for (0..4) |scenario| {
        var p: Probe = .{};
        const d = try gpa.create(Download);
        d.* = .{ .server = undefined, .sid = try gpa.dupe(u8, ""), .bid = try gpa.dupe(u8, ""), .path = try gpa.dupe(u8, ""), .listener = .{ .ctx = &p, .finished = Probe.finished } };
        var hello: [32]u8 = @splat(0);
        hello[0] = 0x81;
        if (scenario == 2) {
            Download.message(d, true, "bad handshake");
        } else {
            Download.message(d, true, &hello);
            if (scenario == 3) {
                try d.bytes.resize(gpa, limit);
                Download.message(d, true, "x");
            } else {
                Download.message(d, true, "\x81payload");
                Download.ended(d, if (scenario == 0) 1000 else 1006, "");
            }
        }
        try std.testing.expectEqual(@as(usize, 1), p.count);
        try std.testing.expectEqual(scenario == 0, p.success);
    }
}

test "preview integration download" {
    const mode = std.mem.span(std.c.getenv("RENUX_PREVIEW_TEST_MODE") orelse return error.SkipZigTest);
    @import("adw").init();
    const url = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_URL").?);
    const sid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_SESSION").?);
    const bid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_BLOCK").?);
    const path = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_FILE").?);
    var server: Server = .{ .url = try gpa.dupe(u8, url), .client_label = try gpa.dupe(u8, "preview test"), .state = .online };
    defer gpa.free(server.url);
    defer gpa.free(server.client_label);
    const Probe = struct {
        done: bool = false,
        success: bool = false,
        bytes: std.ArrayList(u8) = .empty,
        fn finished(ctx: *anyopaque, bytes: ?[]const u8, _: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.done = true;
            if (bytes) |b| {
                p.success = true;
                p.bytes.appendSlice(gpa, b) catch @panic("test allocation");
            }
        }
    };
    var p: Probe = .{};
    defer p.bytes.deinit(gpa);
    const d = try Download.start(&server, sid, bid, path, .{ .ctx = &p, .finished = Probe.finished });
    if (std.mem.eql(u8, mode, "cancel")) d.cancel();
    if (std.mem.eql(u8, mode, "host-removed")) cancelForServer(&server);
    if (std.mem.eql(u8, mode, "old-server")) Download.welcome(d, undefined, .{ .api_revision = 12, .client_id = "", .reconnect_token = null, .resumed = false });
    const context = glib.MainContext.default();
    const until = glib.getMonotonicTime() + 10_000_000;
    while (!p.done and glib.getMonotonicTime() < until) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
    if (!p.done) d.cancel();
    const success = std.mem.eql(u8, mode, "text") or std.mem.eql(u8, mode, "image") or std.mem.eql(u8, mode, "empty") or std.mem.eql(u8, mode, "binary") or std.mem.eql(u8, mode, "relative") or std.mem.eql(u8, mode, "symlink");
    try std.testing.expectEqual(success, p.success);
    if (success) {
        const expected_path = std.c.getenv("RENUX_PREVIEW_TEST_EXPECTED").?;
        var contents: [*]u8 = undefined;
        var size: usize = 0;
        try std.testing.expect(glib.fileGetContents(expected_path, &contents, &size, null) != 0);
        defer glib.free(contents);
        try std.testing.expectEqualSlices(u8, contents[0..size], p.bytes.items);
    }
    try std.testing.expectEqual(@as(usize, 0), active.items.len);
    const drain_until = glib.getMonotonicTime() + 100_000;
    while (glib.getMonotonicTime() < drain_until) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
}

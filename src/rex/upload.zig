//! One dropped file, sent on its own revision-11 control and byte-stream connections. The
//! terminal connection stays at its existing revision. All callbacks run on the main loop;
//! file reads are asynchronous and the socket's writer queue is kept small.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const control = @import("control.zig");
const ws = @import("ws.zig");
const json = @import("../util/json.zig");
const Server = @import("server.zig").Server;

const gpa = std.heap.c_allocator;
const protocol = "rex.data.bytes.v1";
const revision = 11;
const chunk_size = 64 * 1024;
const queue_limit = 512 * 1024;
var active: std.ArrayList(*Upload) = .empty;

pub const Outcome = enum { sent, cancelled, failed, unconfirmed };
pub const Listener = struct {
    ctx: *anyopaque,
    progress: *const fn (ctx: *anyopaque, sent: u64, total: u64) void,
    finished: *const fn (ctx: *anyopaque, outcome: Outcome, message: []const u8) void,
};

pub fn cancelForServer(server: *Server) void {
    var i: usize = 0;
    while (i < active.items.len) {
        if (active.items[i].server == server) active.items[i].cancel() else i += 1;
    }
}

pub const Upload = struct {
    server: *Server,
    session_id: []u8,
    block_id: []u8,
    name: []u8,
    listener: Listener,
    cancellable: *gio.Cancellable,
    input: ?*gio.FileInputStream = null,
    ctl: ?*control.Control = null,
    socket: ?*ws.Socket = null,
    refs: usize = 1,
    phase: enum { preparing, sending, finishing, done } = .preparing,
    size: u64 = 0,
    sent: u64 = 0,
    deadline: c_uint = 0,
    pump: c_uint = 0,

    /// The returned handle lives until `finished`; outstanding file reads hold their own refs.
    pub fn start(server: *Server, session_id: []const u8, block_id: []const u8, file: *gio.File, listener: Listener) !*Upload {
        if (server.state != .online) return error.ServerOffline;
        for (active.items) |u| if (u.server == server and std.mem.eql(u8, u.block_id, block_id)) return error.AlreadyUploading;
        const base = file.getBasename() orelse return error.InvalidName;
        defer glib.free(base);
        const name = std.mem.span(base);
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
        const u = try gpa.create(Upload);
        errdefer gpa.destroy(u);
        const sid = try gpa.dupe(u8, session_id);
        errdefer gpa.free(sid);
        const bid = try gpa.dupe(u8, block_id);
        errdefer gpa.free(bid);
        const own_name = try gpa.dupe(u8, name);
        errdefer gpa.free(own_name);
        try active.append(gpa, u);
        u.* = .{ .server = server, .session_id = sid, .block_id = bid, .name = own_name, .listener = listener, .cancellable = gio.Cancellable.new() };
        u.deadline = glib.timeoutAdd(30_000, &timedOut, u);
        u.ref();
        file.queryInfoAsync("standard::type", .{}, glib.PRIORITY_DEFAULT, u.cancellable, &checkedFile, u);
        return u;
    }

    pub fn cancel(u: *Upload) void {
        u.finish(.cancelled, "Upload cancelled");
    }

    fn ref(u: *Upload) void {
        u.refs += 1;
    }

    fn unref(u: *Upload) void {
        u.refs -= 1;
        if (u.refs != 0) return;
        if (u.input) |input| input.unref();
        u.cancellable.as(gobject.Object).unref();
        gpa.free(u.session_id);
        gpa.free(u.block_id);
        gpa.free(u.name);
        gpa.destroy(u);
    }

    fn finish(u: *Upload, outcome: Outcome, message: []const u8) void {
        if (u.phase == .done) return;
        const uncertain = u.phase == .finishing and outcome != .sent;
        u.phase = .done;
        if (std.mem.indexOfScalar(*Upload, active.items, u)) |i| _ = active.swapRemove(i);
        if (u.deadline != 0) _ = glib.Source.remove(u.deadline);
        if (u.pump != 0) _ = glib.Source.remove(u.pump);
        u.cancellable.cancel();
        if (u.socket) |socket| socket.close();
        u.socket = null;
        // Closing fails pending calls synchronously; the done phase keeps those callbacks inert.
        if (u.ctl) |ctl| ctl.close();
        u.ctl = null;
        u.listener.finished(u.listener.ctx, if (uncertain) .unconfirmed else outcome, if (uncertain) "Upload not confirmed; check the pane before sending again" else message);
        u.unref();
    }

    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const u: *Upload = @ptrCast(@alignCast(data.?));
        u.deadline = 0;
        u.finish(.failed, "File upload timed out");
        return 0;
    }

    fn checkedFile(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const u: *Upload = @ptrCast(@alignCast(data.?));
        defer u.unref();
        var err: ?*glib.Error = null;
        const file: *gio.File = @ptrCast(source.?);
        const info = file.queryInfoFinish(result, &err);
        defer if (err) |e| e.free();
        defer if (info) |i| i.unref();
        if (u.phase == .done) return;
        const i = info orelse return u.finish(.failed, "Couldn't inspect the dropped file");
        // Reject pipes and devices before an open could wait indefinitely for a writer.
        if (i.getFileType() != .regular) return u.finish(.failed, "Drop a regular file; folders and special files aren't supported");
        u.ref();
        file.readAsync(glib.PRIORITY_DEFAULT, u.cancellable, &openedFile, u);
    }

    fn openedFile(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const u: *Upload = @ptrCast(@alignCast(data.?));
        defer u.unref();
        var err: ?*glib.Error = null;
        const file: *gio.File = @ptrCast(source.?);
        const input = file.readFinish(result, &err);
        defer if (err) |e| e.free();
        if (u.phase == .done) {
            if (input) |in| in.unref();
            return;
        }
        u.input = input orelse return u.finish(.failed, "Couldn't open the dropped file");
        u.ref();
        u.input.?.queryInfoAsync("standard::type,standard::size", glib.PRIORITY_DEFAULT, u.cancellable, &fileInfo, u);
    }

    fn fileInfo(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const u: *Upload = @ptrCast(@alignCast(data.?));
        defer u.unref();
        var err: ?*glib.Error = null;
        const input: *gio.FileInputStream = @ptrCast(source.?);
        const info = input.queryInfoFinish(result, &err);
        defer if (err) |e| e.free();
        defer if (info) |i| i.unref();
        if (u.phase == .done) return;
        const i = info orelse return u.finish(.failed, "Couldn't read the dropped file's size");
        if (i.getFileType() != .regular or i.getSize() < 0) return u.finish(.failed, "Drop a regular file; folder uploads aren't supported");
        u.size = @intCast(i.getSize());
        u.ctl = control.Control.open(u.server.url, "Renux file upload", @import("server.zig").version, null, revision, .{
            .ctx = u,
            .on_welcome = welcomed,
            .on_event = event,
            .on_closed = controlClosed,
        }) catch return u.finish(.failed, "Couldn't start the file upload connection");
    }

    fn welcomed(ctx: *anyopaque, ctl: *control.Control, welcome: control.Welcome) void {
        const u: *Upload = @ptrCast(@alignCast(ctx));
        if (welcome.api_revision < revision) return u.finish(.failed, "Update Rex on this host to send files (API revision 11 required)");
        ctl.call("session.attach", .{ .session_id = u.session_id }, control.Callback.of(Upload, u, attached));
    }

    fn event(_: *anyopaque, _: *control.Control, _: []const u8, _: ?json.Value) void {}

    fn controlClosed(ctx: *anyopaque, _: *control.Control, _: []const u8, _: u16) void {
        const u: *Upload = @ptrCast(@alignCast(ctx));
        u.finish(.failed, "Lost the upload's server connection");
    }

    fn attached(u: *Upload, result: control.Result) void {
        if (u.phase == .done) return;
        switch (result) {
            .err => |e| return u.finish(.failed, e.message),
            .ok => {},
        }
        const id = glib.uuidStringRandom();
        defer glib.free(id);
        var buf: [48]u8 = undefined;
        const ref_id = std.fmt.bufPrint(&buf, "upload:{s}", .{std.mem.span(id)}) catch unreachable;
        u.ctl.?.call("com.superlogical.terminal.upload_begin", .{ .session_id = u.session_id, .block_id = u.block_id, .args = .{ .ref = ref_id, .name = u.name, .size = u.size } }, control.Callback.of(Upload, u, reserved));
    }

    fn reserved(u: *Upload, result: control.Result) void {
        if (u.phase == .done) return;
        const payload = switch (result) {
            .ok => |p| p,
            .err => |e| return u.finish(.failed, e.message),
        };
        const ticket = json.str(payload, "ticket") orelse return u.finish(.failed, "Rex returned no upload ticket");
        const hello = @import("stream.zig").helloFor(ticket) orelse return u.finish(.failed, "Rex returned an invalid upload ticket");
        u.socket = ws.Socket.open(.{ .url = u.server.url, .path = "/api/data", .protocol = protocol, .first_message = &hello }, .{
            .ctx = u,
            .on_open = dataOpened,
            .on_message = dataMessage,
            .on_close = dataClosed,
        }) catch return u.finish(.failed, "Couldn't open the file's data connection");
    }

    fn dataOpened(_: *anyopaque) void {}

    fn dataMessage(ctx: *anyopaque, binary: bool, data: []const u8) void {
        const u: *Upload = @ptrCast(@alignCast(ctx));
        u.ref();
        defer u.unref();
        if (u.phase != .preparing) return;
        if (!binary or data.len != 32 or data[0] != 0x81) return u.finish(.failed, "Rex refused the file's data connection");
        if (u.deadline != 0) _ = glib.Source.remove(u.deadline);
        u.deadline = 0;
        u.phase = .sending;
        u.listener.progress(u.listener.ctx, 0, u.size);
        u.readNext();
    }

    fn readNext(u: *Upload) void {
        if (u.phase != .sending) return;
        if (u.socket.?.queuedBytes() >= queue_limit) {
            u.pump = glib.timeoutAdd(15, &pumpLater, u);
            return;
        }
        u.ref();
        u.input.?.as(gio.InputStream).readBytesAsync(chunk_size, glib.PRIORITY_DEFAULT, u.cancellable, &readChunk, u);
    }

    fn pumpLater(data: ?*anyopaque) callconv(.c) c_int {
        const u: *Upload = @ptrCast(@alignCast(data.?));
        u.pump = 0;
        u.readNext();
        return 0;
    }

    fn readChunk(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const u: *Upload = @ptrCast(@alignCast(data.?));
        defer u.unref();
        var err: ?*glib.Error = null;
        const input: *gio.InputStream = @ptrCast(source.?);
        const bytes = input.readBytesFinish(result, &err);
        defer if (err) |e| e.free();
        defer if (bytes) |b| b.unref();
        if (u.phase == .done) return;
        const b = bytes orelse return u.finish(.failed, "Couldn't read the dropped file");
        const n = b.getSize();
        if (!fits(u.sent, u.size, n)) return u.finish(.failed, "The file changed size while sending; nothing was pasted");
        if (n == 0) {
            if (!u.socket.?.sendBinary("")) return u.finish(.failed, "Couldn't finish sending the file");
            // Once the half-close is queued, a disconnect may mean the path was already pasted.
            u.phase = .finishing;
            u.deadline = glib.timeoutAdd(60_000, &timedOut, u);
            u.listener.progress(u.listener.ctx, u.size, u.size);
            return;
        }
        const raw = b.getData(null).?;
        if (!u.socket.?.sendBinary(raw[0..n])) return u.finish(.failed, "The upload connection stopped accepting data");
        u.sent += n;
        u.listener.progress(u.listener.ctx, u.sent, u.size);
        u.readNext();
    }

    fn dataClosed(ctx: *anyopaque, code: u16, _: []const u8) void {
        const u: *Upload = @ptrCast(@alignCast(ctx));
        u.socket = null;
        if (u.phase == .finishing and code == 1000) return u.finish(.sent, "File sent; Rex pasted its path into the pane");
        u.finish(.failed, "The file upload connection closed before completion");
    }
};

/// EOF is valid only at exactly the reserved size; a nonempty chunk must fit the remainder.
fn fits(sent: u64, total: u64, n: usize) bool {
    return sent <= total and (if (n == 0) sent == total else n <= total - sent);
}

test "upload chunks must match the reserved length, including empty files" {
    try std.testing.expect(fits(0, 0, 0));
    try std.testing.expect(fits(0, 4, 4));
    try std.testing.expect(fits(4, 4, 0));
    try std.testing.expect(!fits(0, 4, 0));
    try std.testing.expect(!fits(3, 4, 2));
    try std.testing.expect(!fits(4, 4, 1));
    try std.testing.expect(!fits(5, 4, 0));
    try std.testing.expect(fits(std.math.maxInt(u64) - 1, std.math.maxInt(u64), 1));
}

// `zig build test-upload` supplies an isolated server and disposable files.
test "upload integration" {
    const mode = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_MODE") orelse return error.SkipZigTest);
    const url = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_URL") orelse return error.MissingTestUrl);
    const sid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_SESSION") orelse return error.MissingTestSession);
    const bid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_BLOCK") orelse return error.MissingTestBlock);
    const path = std.c.getenv("RENUX_UPLOAD_TEST_FILE") orelse return error.MissingTestFile;
    var server: Server = .{ .url = try gpa.dupe(u8, url), .client_label = try gpa.dupe(u8, "upload test"), .state = .online };
    defer gpa.free(server.url);
    defer gpa.free(server.client_label);
    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();
    const Probe = struct {
        loop: *glib.MainLoop,
        mode: []const u8,
        path: [*:0]const u8,
        transfer: *Upload = undefined,
        outcome: ?Outcome = null,
        timeout: c_uint = 0,
        timed_out: bool = false,
        message: [512]u8 = undefined,
        message_len: usize = 0,

        fn progress(ctx: *anyopaque, sent: u64, _: u64) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            if (sent == 0 and p.transfer.phase == .sending and (std.mem.eql(u8, p.mode, "grow") or std.mem.eql(u8, p.mode, "shrink"))) {
                const fd = std.c.open(p.path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
                if (fd < 0) return p.transfer.cancel();
                defer _ = std.c.close(fd);
                const size: i64 = if (std.mem.eql(u8, p.mode, "shrink")) 0 else @intCast(p.transfer.size + 1);
                if (std.c.ftruncate(fd, size) != 0) return p.transfer.cancel();
            }
            if (std.mem.eql(u8, p.mode, "cancel-sending") and sent > 0 and p.transfer.phase == .sending) p.transfer.cancel();
            if (std.mem.eql(u8, p.mode, "cancel-finishing") and p.transfer.phase == .finishing) p.transfer.cancel();
        }
        fn finished(ctx: *anyopaque, outcome: Outcome, message: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(p.outcome == null);
            p.outcome = outcome;
            p.message_len = @min(p.message.len, message.len);
            @memcpy(p.message[0..p.message_len], message[0..p.message_len]);
            p.loop.quit();
        }
        fn expired(data: ?*anyopaque) callconv(.c) c_int {
            const p: *@This() = @ptrCast(@alignCast(data.?));
            p.timeout = 0;
            p.timed_out = true;
            p.transfer.cancel();
            return 0;
        }
    };
    var p: Probe = .{ .loop = loop, .mode = mode, .path = path };
    const file = gio.File.newForPath(path);
    defer file.unref();
    const listener: Listener = .{ .ctx = &p, .progress = Probe.progress, .finished = Probe.finished };
    const u = try Upload.start(&server, sid, bid, file, listener);
    p.transfer = u;
    u.ref();
    defer u.unref();
    if (std.mem.eql(u8, mode, "duplicate")) try std.testing.expectError(error.AlreadyUploading, Upload.start(&server, sid, bid, file, listener));
    if (std.mem.eql(u8, mode, "cancel-preparing")) u.cancel();
    if (std.mem.eql(u8, mode, "host-removed")) cancelForServer(&server);
    if (std.mem.eql(u8, mode, "old-server")) Upload.welcomed(u, undefined, .{ .api_revision = 10, .client_id = "", .reconnect_token = null, .resumed = false });
    if (p.outcome == null) {
        p.timeout = glib.timeoutAdd(20_000, &Probe.expired, &p);
        loop.run();
        if (p.timeout != 0) _ = glib.Source.remove(p.timeout);
    }
    // Finish cancelled IO callbacks before stack-owned listener data and the server go away.
    const context = glib.MainContext.default();
    const until = glib.getMonotonicTime() + 5_000_000;
    while (u.refs > 1 and glib.getMonotonicTime() < until) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 1), u.refs);
    try std.testing.expect(!p.timed_out);
    const expected: Outcome = if (std.mem.eql(u8, mode, "cancel-finishing")) .unconfirmed else if (std.mem.startsWith(u8, mode, "cancel-") or std.mem.eql(u8, mode, "host-removed")) .cancelled else if (std.mem.eql(u8, mode, "missing") or std.mem.eql(u8, mode, "directory") or std.mem.eql(u8, mode, "fifo") or std.mem.eql(u8, mode, "old-server") or std.mem.eql(u8, mode, "grow") or std.mem.eql(u8, mode, "shrink")) .failed else .sent;
    if (p.outcome != expected) std.debug.print("upload outcome {any}, expected {s}: {s}\n", .{ p.outcome, @tagName(expected), p.message[0..p.message_len] });
    try std.testing.expectEqual(expected, p.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), active.items.len);
}

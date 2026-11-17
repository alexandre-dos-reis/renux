//! Dropped or pasted files, sent on their own revision-11 control connection and one byte
//! stream each. Several go as one batch, whose paths Rex pastes together once it has them all.
//! The terminal connection stays at its existing revision. All callbacks run on the main loop;
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
    /// The files, in the order their paths are pasted, and which one is being sent.
    files: []*gio.File,
    sizes: []u64,
    index: usize = 0,
    /// The first file's name, for whoever shows the upload.
    name: []u8,
    /// What groups several files, so that Rex pastes their paths together once all of them
    /// have arrived. One file on its own has no need of it.
    batch: [36]u8 = undefined,
    listener: Listener,
    cancellable: *gio.Cancellable,
    input: ?*gio.FileInputStream = null,
    ctl: ?*control.Control = null,
    socket: ?*ws.Socket = null,
    refs: usize = 1,
    /// `closing` is a file that isn't the last, all sent, waiting for Rex to take it;
    /// `finishing` is the last one, after which Rex pastes the paths.
    phase: enum { preparing, sending, closing, finishing, done } = .preparing,
    /// The file being sent: its size, how much of it has gone, and whether Rex has said its
    /// data connection is ready.
    size: u64 = 0,
    sent: u64 = 0,
    ready: bool = false,
    /// All the files' sizes together, and how much the files before this one came to.
    total: u64 = 0,
    before: u64 = 0,
    deadline: c_uint = 0,
    pump: c_uint = 0,

    /// Sends `files` to the machine a pane is on; Rex pastes their paths there, in this order,
    /// when all have arrived. The returned handle lives until `finished`; outstanding file
    /// reads hold their own refs.
    pub fn start(server: *Server, session_id: []const u8, block_id: []const u8, files: []const *gio.File, listener: Listener) !*Upload {
        if (server.state != .online) return error.ServerOffline;
        if (files.len == 0) return error.NoFiles;
        for (active.items) |u| if (u.server == server and std.mem.eql(u8, u.block_id, block_id)) return error.AlreadyUploading;
        for (files) |file| {
            const base = file.getBasename() orelse return error.InvalidName;
            defer glib.free(base);
            const name = std.mem.span(base);
            if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
        }
        const first = files[0].getBasename().?;
        defer glib.free(first);
        const u = try gpa.create(Upload);
        errdefer gpa.destroy(u);
        const sid = try gpa.dupe(u8, session_id);
        errdefer gpa.free(sid);
        const bid = try gpa.dupe(u8, block_id);
        errdefer gpa.free(bid);
        const own_name = try gpa.dupe(u8, std.mem.span(first));
        errdefer gpa.free(own_name);
        const own_files = try gpa.dupe(*gio.File, files);
        errdefer gpa.free(own_files);
        const sizes = try gpa.alloc(u64, files.len);
        errdefer gpa.free(sizes);
        @memset(sizes, 0);
        try active.append(gpa, u);
        for (own_files) |file| _ = file.ref();
        u.* = .{ .server = server, .session_id = sid, .block_id = bid, .files = own_files, .sizes = sizes, .name = own_name, .listener = listener, .cancellable = gio.Cancellable.new() };
        const id = glib.uuidStringRandom();
        defer glib.free(id);
        @memcpy(&u.batch, std.mem.span(id)[0..36]);
        u.deadline = glib.timeoutAdd(30_000, &timedOut, u);
        u.measure();
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
        for (u.files) |file| file.unref();
        gpa.free(u.files);
        gpa.free(u.sizes);
        gpa.free(u.session_id);
        gpa.free(u.block_id);
        gpa.free(u.name);
        gpa.destroy(u);
    }

    fn finish(u: *Upload, outcome: Outcome, message: []const u8) void {
        if (u.phase == .done) return;
        // Only the last file's arrival makes Rex paste, so only then can a path have been
        // pasted without our hearing of it.
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

    fn wait(u: *Upload, ms: c_uint) void {
        if (u.deadline != 0) _ = glib.Source.remove(u.deadline);
        u.deadline = if (ms == 0) 0 else glib.timeoutAdd(ms, &timedOut, u);
    }

    /// Looks at each file before anything is sent: all must be regular files, and their
    /// sizes say how far along the whole upload is.
    fn measure(u: *Upload) void {
        u.ref();
        u.files[u.index].queryInfoAsync("standard::type,standard::size", .{}, glib.PRIORITY_DEFAULT, u.cancellable, &measured, u);
    }

    fn measured(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
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
        u.sizes[u.index] = @intCast(@max(0, i.getSize()));
        u.total += u.sizes[u.index];
        u.index += 1;
        if (u.index < u.files.len) return u.measure();
        u.index = 0;
        u.open();
    }

    fn open(u: *Upload) void {
        u.ref();
        u.files[u.index].readAsync(glib.PRIORITY_DEFAULT, u.cancellable, &openedFile, u);
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
        if (u.input) |old| old.unref();
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
        // The size of the file as opened is the one promised to Rex; it may have changed
        // since it was looked at.
        u.size = @intCast(i.getSize());
        u.total = u.total - u.sizes[u.index] + u.size;
        u.sizes[u.index] = u.size;
        u.sent = 0;
        if (u.ctl != null) return u.reserve();
        u.ctl = control.Control.open(u.server.connectionUrl(), "Renux file upload", @import("server.zig").version, null, revision, .{
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
        u.reserve();
    }

    /// Asks Rex for room for the file being sent. Several files name their batch, their
    /// place in it and how many there are, and Rex holds their paths back until it has all.
    fn reserve(u: *Upload) void {
        const base = u.files[u.index].getBasename() orelse return u.finish(.failed, "That file's name isn't valid");
        defer glib.free(base);
        const name = std.mem.span(base);
        const id = glib.uuidStringRandom();
        defer glib.free(id);
        var buf: [48]u8 = undefined;
        const ref_id = std.fmt.bufPrint(&buf, "upload:{s}", .{std.mem.span(id)}) catch unreachable;
        const done = control.Callback.of(Upload, u, reserved);
        const method = "com.superlogical.terminal.upload_begin";
        if (u.files.len == 1) {
            u.ctl.?.call(method, .{ .session_id = u.session_id, .block_id = u.block_id, .args = .{ .ref = ref_id, .name = name, .size = u.size } }, done);
        } else {
            u.ctl.?.call(method, .{ .session_id = u.session_id, .block_id = u.block_id, .args = .{ .ref = ref_id, .name = name, .size = u.size, .batch = @as([]const u8, &u.batch), .index = u.index, .count = u.files.len } }, done);
        }
    }

    fn reserved(u: *Upload, result: control.Result) void {
        if (u.phase == .done) return;
        const payload = switch (result) {
            .ok => |p| p,
            .err => |e| return u.finish(.failed, e.message),
        };
        const ticket = json.str(payload, "ticket") orelse return u.finish(.failed, "Rex returned no upload ticket");
        const hello = @import("stream.zig").helloFor(ticket) orelse return u.finish(.failed, "Rex returned an invalid upload ticket");
        u.ready = false;
        u.socket = ws.Socket.open(.{ .url = u.server.connectionUrl(), .path = "/api/data", .protocol = protocol, .first_message = &hello }, .{
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
        if (u.ready or u.phase == .done) return;
        if (!binary or data.len != 32 or data[0] != 0x81) return u.finish(.failed, "Rex refused the file's data connection");
        u.ready = true;
        u.wait(0);
        u.phase = .sending;
        u.listener.progress(u.listener.ctx, u.before, u.total);
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
            u.wait(60_000);
            if (u.index + 1 < u.files.len) {
                u.phase = .closing;
                return;
            }
            // Once the last half-close is queued, a disconnect may mean the paths were pasted.
            u.phase = .finishing;
            u.listener.progress(u.listener.ctx, u.total, u.total);
            return;
        }
        const raw = b.getData(null).?;
        if (!u.socket.?.sendBinary(raw[0..n])) return u.finish(.failed, "The upload connection stopped accepting data");
        u.sent += n;
        u.listener.progress(u.listener.ctx, u.before + u.sent, u.total);
        u.readNext();
    }

    fn dataClosed(ctx: *anyopaque, code: u16, _: []const u8) void {
        const u: *Upload = @ptrCast(@alignCast(ctx));
        u.socket = null;
        if (u.phase == .finishing and code == 1000) return u.finish(.sent, "File sent; Rex pasted its path into the pane");
        if (u.phase != .closing or code != 1000) return u.finish(.failed, "The file upload connection closed before completion");
        // Rex has this file. The next one goes the same way, over the same control connection.
        u.before += u.size;
        u.index += 1;
        u.phase = .sending;
        u.wait(30_000);
        u.open();
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
            // The first file of two has gone and the second is on its way.
            if (std.mem.eql(u8, p.mode, "batch-cancel") and p.transfer.index == 1 and p.transfer.sent > 0) p.transfer.cancel();
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
    const second = if (std.c.getenv("RENUX_UPLOAD_TEST_FILE2")) |other| gio.File.newForPath(other) else null;
    defer if (second) |f| f.unref();
    const batch = std.mem.startsWith(u8, mode, "batch");
    const sending: []const *gio.File = if (batch) &.{ file, second orelse return error.MissingSecondFile } else &.{file};
    const u = try Upload.start(&server, sid, bid, sending, listener);
    p.transfer = u;
    u.ref();
    defer u.unref();
    if (std.mem.eql(u8, mode, "duplicate")) try std.testing.expectError(error.AlreadyUploading, Upload.start(&server, sid, bid, &.{file}, listener));
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
    const expected: Outcome = if (std.mem.eql(u8, mode, "cancel-finishing")) .unconfirmed else if (std.mem.startsWith(u8, mode, "cancel-") or std.mem.eql(u8, mode, "host-removed") or std.mem.eql(u8, mode, "batch-cancel")) .cancelled else if (std.mem.eql(u8, mode, "missing") or std.mem.eql(u8, mode, "directory") or std.mem.eql(u8, mode, "fifo") or std.mem.eql(u8, mode, "old-server") or std.mem.eql(u8, mode, "grow") or std.mem.eql(u8, mode, "shrink")) .failed else .sent;
    if (p.outcome != expected) std.debug.print("upload outcome {any}, expected {s}: {s}\n", .{ p.outcome, @tagName(expected), p.message[0..p.message_len] });
    try std.testing.expectEqual(expected, p.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), active.items.len);
}

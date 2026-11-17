//! Copies a file or a folder from a pane's machine into a folder on this computer, one file
//! at a time over Rex's download streams. Bytes go straight to disk, so size is no limit, and
//! nothing already on this computer is written over.
//! shortcut: one file at a time, about half a second each over a relayed link; bring several
//! at once if folders of hundreds of files turn out to matter.
const std = @import("std");
const glib = @import("glib");
const control = @import("control.zig");
const ws = @import("ws.zig");
const json = @import("../util/json.zig");
const Server = @import("server.zig").Server;
const gpa = std.heap.c_allocator;

pub const Outcome = enum { done, cancelled, failed };
pub const Listener = struct {
    ctx: *anyopaque,
    /// How many files have arrived whole, and how many bytes in all. Not the place to cancel
    /// from: the fetch is in the middle of its work.
    progress: *const fn (ctx: *anyopaque, files: u32, bytes: u64) void,
    /// The fetch is still whole for the length of this call: `to`, `count`, `bytes` and
    /// `skipped` say what was made.
    finished: *const fn (ctx: *anyopaque, outcome: Outcome, message: []const u8) void,
};
var active: std.ArrayList(*Fetch) = .empty;
/// With nothing heard from the host for this long, the fetch gives up.
const quiet_us = 60 * std.time.us_per_s;

pub fn cancelForServer(server: *Server) void {
    var i: usize = 0;
    while (i < active.items.len) {
        if (active.items[i].server == server) active.items[i].cancel() else i += 1;
    }
}

/// The app is closing, with no one left to tell: the files that were arriving are taken away.
pub fn shutdown() void {
    for (active.items) |f| f.dropPart();
}

pub const Fetch = struct {
    server: *Server,
    sid: []u8,
    bid: []u8,
    /// The file or folder on the pane's machine: as asked for, then whole once a folder's
    /// listing has said where it is.
    from: []u8,
    /// The folder on this computer it goes into, and what it is there once that is known.
    into: []u8,
    to: ?[:0]u8 = null,
    listener: Listener,
    ctl: ?*control.Control = null,
    socket: ?*ws.Socket = null,
    welcomed: bool = false,
    folder: bool = false,
    /// What is still to do, as paths under `from`: files to bring, and folders to list.
    files: std.ArrayList([]u8) = .empty,
    dirs: std.ArrayList([]u8) = .empty,
    /// The one being brought or listed now. Null for `from` itself.
    rel: ?[]u8 = null,
    /// The file arriving now, on this computer.
    part: ?[:0]u8 = null,
    fd: c_int = -1,
    count: u32 = 0,
    bytes: u64 = 0,
    /// How big a file by itself is, as Rex said when it began. A folder's size isn't known.
    total: u64 = 0,
    /// Files and folders left out: links to folders, what couldn't be read, names that
    /// aren't safe to make here, and the rest of a listing Rex cut short.
    skipped: u32 = 0,
    told_us: i64 = 0,
    heard_us: i64 = 0,
    timer: c_uint = 0,
    done: bool = false,

    /// Starts bringing `from` into the folder `into`, which must exist.
    pub fn start(server: *Server, sid: []const u8, bid: []const u8, from: []const u8, into: []const u8, listener: Listener) !*Fetch {
        if (server.state != .online) return error.Offline;
        if (from.len == 0 or from.len > 4096 or std.mem.indexOfScalar(u8, from, 0) != null) return error.InvalidPath;
        const f = try gpa.create(Fetch);
        errdefer gpa.destroy(f);
        const s = try gpa.dupe(u8, sid);
        errdefer gpa.free(s);
        const b = try gpa.dupe(u8, bid);
        errdefer gpa.free(b);
        const p = try gpa.dupe(u8, from);
        errdefer gpa.free(p);
        const i = try gpa.dupe(u8, into);
        errdefer gpa.free(i);
        try active.append(gpa, f);
        errdefer _ = active.pop();
        f.* = .{ .server = server, .sid = s, .bid = b, .from = p, .into = i, .listener = listener, .heard_us = glib.getMonotonicTime() };
        f.ctl = try control.Control.open(server.connectionUrl(), "Renux download", @import("server.zig").version, null, 13, .{
            .ctx = f,
            .on_welcome = welcome,
            .on_event = event,
            .on_closed = closed,
        });
        f.timer = glib.timeoutAdd(15_000, &watch, f);
        return f;
    }

    pub fn cancel(f: *Fetch) void {
        f.finish(.cancelled, "");
    }

    fn finish(f: *Fetch, outcome: Outcome, detail: []const u8) void {
        if (f.done) return;
        f.done = true;
        if (std.mem.indexOfScalar(*Fetch, active.items, f)) |i| _ = active.swapRemove(i);
        if (f.timer != 0) _ = glib.Source.remove(f.timer);
        if (f.socket) |s| s.close();
        if (f.ctl) |c| c.close();
        // Half a file is worse than none. The files that arrived whole stay.
        f.dropPart();
        f.listener.finished(f.listener.ctx, outcome, detail);
        for (f.files.items) |p| gpa.free(p);
        f.files.deinit(gpa);
        for (f.dirs.items) |p| gpa.free(p);
        f.dirs.deinit(gpa);
        if (f.rel) |p| gpa.free(p);
        if (f.to) |p| gpa.free(p);
        gpa.free(f.sid);
        gpa.free(f.bid);
        gpa.free(f.from);
        gpa.free(f.into);
        gpa.destroy(f);
    }

    fn watch(data: ?*anyopaque) callconv(.c) c_int {
        const f: *Fetch = @ptrCast(@alignCast(data.?));
        if (glib.getMonotonicTime() - f.heard_us < quiet_us) return 1;
        f.timer = 0;
        f.finish(.failed, "The host stopped answering");
        return 0;
    }

    fn welcome(ctx: *anyopaque, ctl: *control.Control, w: control.Welcome) void {
        const f: *Fetch = @ptrCast(@alignCast(ctx));
        if (w.api_revision < 13) return f.finish(.failed, "Update Rex on this host to download files (API 13 required)");
        ctl.call("session.attach", .{ .session_id = f.sid }, control.Callback.of(Fetch, f, attached));
    }
    fn event(_: *anyopaque, _: *control.Control, _: []const u8, _: ?json.Value) void {}
    fn closed(ctx: *anyopaque, _: *control.Control, _: []const u8, _: u16) void {
        const f: *Fetch = @ptrCast(@alignCast(ctx));
        f.finish(.failed, "Lost the connection to this host");
    }
    fn attached(f: *Fetch, result: control.Result) void {
        if (f.done) return;
        switch (result) {
            .err => return f.finish(.failed, "Couldn't attach to the pane's session"),
            .ok => {},
        }
        // A file answers to this. A folder refuses it, and is listed instead.
        f.request();
    }

    /// The path on the pane's machine of what is being brought or listed now.
    fn remote(f: *const Fetch) ![]u8 {
        return if (f.rel) |rel| join(gpa, f.from, rel) else gpa.dupe(u8, f.from);
    }

    fn request(f: *Fetch) void {
        const path = f.remote() catch return f.finish(.failed, "Not enough memory for this download");
        defer gpa.free(path);
        const id = glib.uuidStringRandom();
        defer glib.free(id);
        var buf: [48]u8 = undefined;
        const ref = std.fmt.bufPrint(&buf, "download:{s}", .{std.mem.span(id)}) catch unreachable;
        f.ctl.?.call("com.superlogical.terminal.download_begin", .{ .session_id = f.sid, .block_id = f.bid, .args = .{ .ref = ref, .path = path } }, control.Callback.of(Fetch, f, reserved));
    }

    fn reserved(f: *Fetch, result: control.Result) void {
        if (f.done) return;
        f.heard_us = glib.getMonotonicTime();
        const payload = switch (result) {
            .ok => |p| p,
            .err => return if (f.folder) f.skip() else f.list(),
        };
        const ticket = json.str(payload, "ticket") orelse return f.fileFailed();
        const hello = @import("stream.zig").helloFor(ticket) orelse return f.fileFailed();
        if (!f.folder) {
            // The name is the host's to give, and is checked like any other it gives.
            const name = json.str(payload, "name") orelse baseName(f.from);
            if (!safeName(name)) return f.finish(.failed, "That file's name can't be used on this computer");
            f.to = unused(gpa, f.into, name) catch return f.finish(.failed, "Couldn't find a free name for the file");
            f.total = @intCast(@max(0, json.int(payload, "size") orelse 0));
        }
        const part = (if (f.rel) |rel| std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ f.to.?, rel }, 0) else gpa.dupeSentinel(u8, f.to.?, 0)) catch
            return f.finish(.failed, "Not enough memory for this download");
        // Never an existing file: the name was free a moment ago, and this fails if it no longer is.
        f.fd = std.c.open(part.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o644));
        if (f.fd < 0) {
            gpa.free(part);
            return f.finish(.failed, "Couldn't write to the folder on this computer");
        }
        f.part = part;
        f.welcomed = false;
        f.socket = ws.Socket.open(.{ .url = f.server.connectionUrl(), .path = "/api/data", .protocol = "rex.data.bytes.v1", .first_message = &hello }, .{
            .ctx = f,
            .on_open = opened,
            .on_message = message,
            .on_close = ended,
        }) catch return f.fileFailed();
    }

    fn opened(_: *anyopaque) void {}
    fn message(ctx: *anyopaque, binary: bool, data: []const u8) void {
        const f: *Fetch = @ptrCast(@alignCast(ctx));
        if (f.done) return;
        f.heard_us = glib.getMonotonicTime();
        if (!binary) return f.fileFailed();
        if (!f.welcomed) {
            if (data.len != 32 or data[0] != 0x81) return f.fileFailed();
            f.welcomed = true;
            return;
        }
        var rest = data;
        while (rest.len > 0) {
            const n = std.c.write(f.fd, rest.ptr, rest.len);
            if (n <= 0) return f.finish(.failed, "Couldn't write to this computer: the disk may be full");
            rest = rest[@intCast(n)..];
        }
        f.bytes += data.len;
        f.tell(false);
    }
    fn ended(ctx: *anyopaque, code: u16, _: []const u8) void {
        const f: *Fetch = @ptrCast(@alignCast(ctx));
        f.socket = null;
        if (f.done) return;
        f.heard_us = glib.getMonotonicTime();
        if (!f.welcomed or code != 1000) return f.fileFailed();
        _ = std.c.close(f.fd);
        f.fd = -1;
        gpa.free(f.part.?);
        f.part = null;
        f.count += 1;
        f.tell(true);
        if (f.folder) f.next() else f.finish(.done, "");
    }

    /// Takes away the file that was arriving, which isn't whole.
    fn dropPart(f: *Fetch) void {
        if (f.fd >= 0) _ = std.c.close(f.fd);
        f.fd = -1;
        const part = f.part orelse return;
        _ = std.c.unlink(part.ptr);
        gpa.free(part);
        f.part = null;
    }

    /// One file didn't come. A folder goes on without it; a file by itself has failed.
    fn fileFailed(f: *Fetch) void {
        if (f.socket) |s| s.close();
        f.socket = null;
        f.dropPart();
        if (f.folder) f.skip() else f.finish(.failed, "The download ended before the file was whole");
    }

    fn skip(f: *Fetch) void {
        f.skipped += 1;
        f.next();
    }

    fn next(f: *Fetch) void {
        if (f.rel) |old| gpa.free(old);
        f.rel = null;
        if (f.files.pop()) |rel| {
            f.rel = rel;
            return f.request();
        }
        if (f.dirs.pop()) |rel| {
            f.rel = rel;
            return f.list();
        }
        f.finish(.done, "");
    }

    fn list(f: *Fetch) void {
        const path = f.remote() catch return f.finish(.failed, "Not enough memory for this download");
        defer gpa.free(path);
        f.ctl.?.call("com.superlogical.terminal.list_dir", .{ .session_id = f.sid, .block_id = f.bid, .args = .{ .path = path, .files = true, .limit = 100_000 } }, control.Callback.of(Fetch, f, listed));
    }

    fn listed(f: *Fetch, result: control.Result) void {
        if (f.done) return;
        f.heard_us = glib.getMonotonicTime();
        const payload: ?json.Value = switch (result) {
            .ok => |p| p,
            .err => null,
        };
        const status = json.str(payload, "status") orelse "";
        if (!std.mem.eql(u8, status, "ok")) {
            if (f.folder) return f.skip();
            return f.finish(.failed, if (std.mem.eql(u8, status, "denied")) "Rex isn't allowed to read that folder" else "There is no file or folder at that path");
        }
        if (!f.folder) {
            // The first listing is of the folder itself, and says where the whole of it is.
            const whole = json.str(payload, "path") orelse f.from;
            const name = baseName(whole);
            const own = gpa.dupe(u8, whole) catch return f.finish(.failed, "Not enough memory for this download");
            gpa.free(f.from);
            f.from = own;
            f.to = unused(gpa, f.into, if (safeName(name)) name else "folder") catch return f.finish(.failed, "Couldn't find a free name for the folder");
            if (std.c.mkdir(f.to.?.ptr, 0o755) != 0) return f.finish(.failed, "Couldn't write to the folder on this computer");
            f.folder = true;
        }
        if (json.boolean(payload, "truncated") orelse false) f.skipped += 1;
        for (json.array(payload, "entries")) |e| {
            const name = json.str(e, "name") orelse continue;
            const file = json.boolean(e, "file") orelse false;
            // A link to a folder may lead back to where this began, so it is left out.
            if (!safeName(name) or (!file and (json.boolean(e, "symlink") orelse false))) {
                f.skipped += 1;
                continue;
            }
            const rel = (if (f.rel) |under| join(gpa, under, name) else gpa.dupe(u8, name)) catch return f.finish(.failed, "Not enough memory for this download");
            if (!file) {
                const here = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ f.to.?, rel }, 0) catch {
                    gpa.free(rel);
                    return f.finish(.failed, "Not enough memory for this download");
                };
                defer gpa.free(here);
                if (std.c.mkdir(here.ptr, 0o755) != 0) {
                    gpa.free(rel);
                    f.skipped += 1;
                    continue;
                }
            }
            (if (file) &f.files else &f.dirs).append(gpa, rel) catch {
                gpa.free(rel);
                return f.finish(.failed, "Not enough memory for this download");
            };
        }
        f.next();
    }

    /// Says how far it has got: at once for a whole file, and now and then while one arrives.
    fn tell(f: *Fetch, now: bool) void {
        const at = glib.getMonotonicTime();
        if (!now and at - f.told_us < 100_000) return;
        f.told_us = at;
        f.listener.progress(f.listener.ctx, f.count, f.bytes);
    }
};

/// Whether a name the host gave can be made in a folder here and stay in it.
fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn baseName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| trimmed[slash + 1 ..] else trimmed;
}

fn join(a: std.mem.Allocator, folder: []const u8, name: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ folder, if (std.mem.endsWith(u8, folder, "/")) "" else "/", name });
}

/// `name` as the `n`th of its name: `notes (2).md`, `src (2)`.
fn numbered(a: std.mem.Allocator, name: []const u8, n: u32) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    // A name that only starts with a dot has no ending to keep apart.
    const stem = if (dot == 0) name.len else dot;
    return std.fmt.allocPrint(a, "{s} ({d}){s}", .{ name[0..stem], n, name[stem..] });
}

/// A path in `folder` for `name` that nothing has yet: the name itself, or the name numbered.
fn unused(a: std.mem.Allocator, folder: []const u8, name: []const u8) ![:0]u8 {
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const tried = if (n == 1) try a.dupe(u8, name) else try numbered(a, name, n);
        defer a.free(tried);
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ folder, tried }, 0);
        // A link that leads nowhere has the name too.
        if (glib.fileTest(path.ptr, .{ .exists = true, .is_symlink = true }) == 0) return path;
        a.free(path);
    }
    return error.NoFreeName;
}

test "names from a host stay inside the folder they are made in" {
    try std.testing.expect(safeName("notes.md"));
    try std.testing.expect(safeName(".git"));
    try std.testing.expect(safeName("a b ü"));
    try std.testing.expect(!safeName(""));
    try std.testing.expect(!safeName("."));
    try std.testing.expect(!safeName(".."));
    try std.testing.expect(!safeName("../x"));
    try std.testing.expect(!safeName("a/b"));
    try std.testing.expect(!safeName("a\x00b"));
}

test "paths on the host and names on this computer" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("loop", baseName("/Users/me/Work/loop/"));
    try std.testing.expectEqualStrings("loop", baseName("loop"));
    try std.testing.expectEqualStrings("", baseName("/"));
    const child = try join(a, "/", "etc");
    defer a.free(child);
    try std.testing.expectEqualStrings("/etc", child);
    const deep = try join(a, "/a/b", "c");
    defer a.free(deep);
    try std.testing.expectEqualStrings("/a/b/c", deep);
    for ([_][2][]const u8{ .{ "notes.md", "notes (2).md" }, .{ "src", "src (2)" }, .{ ".env", ".env (2)" }, .{ "a.tar.gz", "a.tar (2).gz" } }) |c| {
        const got = try numbered(a, c[0], 2);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "fetch integration" {
    const mode = std.mem.span(std.c.getenv("RENUX_FETCH_TEST_MODE") orelse return error.SkipZigTest);
    const url = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_URL").?);
    const sid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_SESSION").?);
    const bid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_BLOCK").?);
    const from = std.mem.span(std.c.getenv("RENUX_FETCH_TEST_FROM").?);
    const into = std.mem.span(std.c.getenv("RENUX_FETCH_TEST_INTO").?);
    var server: Server = .{ .url = try gpa.dupe(u8, url), .client_label = try gpa.dupe(u8, "fetch test"), .state = .online };
    defer gpa.free(server.url);
    defer gpa.free(server.client_label);
    const Probe = struct {
        outcome: ?Outcome = null,
        fetch: *Fetch = undefined,
        files: u32 = 0,
        fn progress(ctx: *anyopaque, files: u32, _: u64) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.files = files;
        }
        fn finished(ctx: *anyopaque, outcome: Outcome, _: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.outcome = outcome;
            // What the script checks the folder against.
            std.debug.print("FETCH {s} files={d} bytes={d} skipped={d} to={s}\n", .{ @tagName(outcome), p.fetch.count, p.fetch.bytes, p.fetch.skipped, if (p.fetch.to) |t| t else "" });
        }
    };
    var p: Probe = .{};
    p.fetch = try Fetch.start(&server, sid, bid, from, into, .{ .ctx = &p, .progress = Probe.progress, .finished = Probe.finished });
    if (std.mem.eql(u8, mode, "host-removed")) cancelForServer(&server);
    const context = glib.MainContext.default();
    const until = glib.getMonotonicTime() + 20_000_000;
    while (p.outcome == null and glib.getMonotonicTime() < until) {
        _ = context.iteration(0);
        if (p.outcome == null and p.files >= 2 and std.mem.eql(u8, mode, "cancel")) p.fetch.cancel();
        glib.usleep(500);
    }
    if (p.outcome == null) p.fetch.cancel();
    const wanted: Outcome = if (std.mem.eql(u8, mode, "missing")) .failed else if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "host-removed")) .cancelled else .done;
    try std.testing.expectEqual(wanted, p.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), active.items.len);
    const drain_until = glib.getMonotonicTime() + 100_000;
    while (glib.getMonotonicTime() < drain_until) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
}

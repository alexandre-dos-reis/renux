//! Local TCP forwards carried by Rex's CLI until the native dial-stream contract is documented.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");
const gobject = @import("gobject");
const Server = @import("server.zig").Server;
const gpa = std.heap.c_allocator;

pub const Target = struct {
    scheme: []const u8 = "http",
    host: []const u8 = "localhost",
    port: u16,
    suffix: []const u8 = "",

    /// Accepts an explicit TCP port, host:port, or an HTTP(S) URL with a port.
    pub fn parse(text: []const u8) !Target {
        if (text.len == 0 or text.len > 8192) return error.InvalidTarget;
        for (text) |c| if (c <= 32 or c == 127 or c == '\\') return error.InvalidTarget;
        var t: Target = .{ .port = undefined };
        var authority = text;
        if (std.mem.indexOf(u8, text, "://")) |at| {
            t.scheme = text[0..at];
            if (!std.ascii.eqlIgnoreCase(t.scheme, "http") and !std.ascii.eqlIgnoreCase(t.scheme, "https")) return error.InvalidTarget;
            authority = text[at + 3 ..];
            const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
            t.suffix = authority[end..];
            authority = authority[0..end];
        }
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
        if (colon == null and std.mem.indexOf(u8, text, "://") != null) return error.InvalidTarget;
        const digits = if (colon) |at| blk: {
            t.host = authority[0..at];
            break :blk authority[at + 1 ..];
        } else authority;
        if (digits.len == 0) return error.InvalidTarget;
        for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidTarget;
        t.port = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidTarget;
        if (t.port == 0 or t.host.len == 0 or t.host.len > 255) return error.InvalidTarget;
        const ipv6 = t.host[0] == '[' and t.host[t.host.len - 1] == ']';
        const host = if (ipv6) t.host[1 .. t.host.len - 1] else t.host;
        if (host.len == 0) return error.InvalidTarget;
        for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and !(ipv6 and c == ':')) return error.InvalidTarget;
        return t;
    }

    pub fn loopback(t: Target) bool {
        return std.ascii.eqlIgnoreCase(t.host, "localhost") or std.mem.eql(u8, t.host, "127.0.0.1") or std.mem.eql(u8, t.host, "[::1]") or std.mem.eql(u8, t.host, "0.0.0.0");
    }

    fn dialHost(t: Target) []const u8 {
        return if (std.mem.eql(u8, t.host, "0.0.0.0")) "localhost" else t.host;
    }

    pub fn rewrite(t: Target, allocator: std.mem.Allocator, port: u16) ![:0]u8 {
        return std.fmt.allocPrintSentinel(allocator, "{s}://127.0.0.1:{d}{s}", .{ t.scheme, port, t.suffix }, 0);
    }
};

pub fn remoteLink(server_url: []const u8, url: []const u8) bool {
    if (std.mem.startsWith(u8, server_url, "unix://")) return false;
    if (std.mem.indexOf(u8, url, "://") == null) return false;
    const target = Target.parse(url) catch return false;
    return target.loopback();
}

pub var active: std.ArrayList(*Forward) = .empty;
pub var generation: usize = 0;
var next_id: usize = 0;
var running: usize = 0;

pub fn cancelForServer(server: *Server) void {
    var i: usize = 0;
    while (i < active.items.len) {
        if (active.items[i].server == server) active.items[i].close() else i += 1;
    }
}

/// Let the CLI close its tunnel blocks, rather than leaving children behind when Renux quits.
pub fn shutdown() void {
    while (active.items.len > 0) active.items[0].close();
    const until = glib.getMonotonicTime() + 3_000_000;
    while (running > 0 and glib.getMonotonicTime() < until) {
        _ = glib.MainContext.default().iteration(0);
        glib.usleep(1000);
    }
}

pub fn open(server: *Server, sid: []const u8, url: []const u8, parent: ?*gtk.Window) void {
    const target = Target.parse(url) catch return server.notifyMessage("Enter a port from 1–65535, host:port, or an HTTP(S) URL with a port");
    const f = Forward.start(server, sid, target) catch return server.notifyMessage("Couldn't start port forwarding; install a Rex CLI with ‘forward open’ support");
    if (f.local_port != 0) return launch(target, f.local_port, parent);
    const pending = gpa.dupe(u8, url) catch return;
    f.pending.append(gpa, pending) catch {
        gpa.free(pending);
        return;
    };
    if (parent != null and f.parent == null) {
        f.parent = parent;
        _ = parent.?.as(gobject.Object).ref();
    }
}

fn launch(target: Target, port: u16, parent: ?*gtk.Window) void {
    const url = target.rewrite(gpa, port) catch return;
    defer gpa.free(url);
    const launcher = gtk.UriLauncher.new(url.ptr);
    defer launcher.unref();
    launcher.launch(parent, null, null, null);
}

pub const Forward = struct {
    id: usize,
    server: *Server,
    host: []u8,
    port: u16,
    process: *gio.Subprocess,
    local_port: u16 = 0,
    parent: ?*gtk.Window = null,
    pending: std.ArrayList([]u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    refs: usize = 1,
    timer: c_uint = 0,
    stopped: bool = false,

    fn start(server: *Server, sid: []const u8, target: Target) !*Forward {
        for (active.items) |f| if (f.server == server and f.port == target.port and std.ascii.eqlIgnoreCase(f.host, target.dialHost())) return f;
        const f = try gpa.create(Forward);
        errdefer gpa.destroy(f);
        const host = try gpa.dupe(u8, target.dialHost());
        errdefer gpa.free(host);
        const address = try gpa.dupeSentinel(u8, server.url, 0);
        defer gpa.free(address);
        const session = try gpa.dupeSentinel(u8, sid, 0);
        defer gpa.free(session);
        const dest = try std.fmt.allocPrintSentinel(gpa, "http://{s}:{d}", .{ host, target.port }, 0);
        defer gpa.free(dest);
        try active.ensureUnusedCapacity(gpa, 1);
        const l = gio.SubprocessLauncher.new(.{ .stdout_pipe = true, .stderr_merge = true });
        defer l.unref();
        inline for (.{ "REX_SERVER", "REX_SESSION", "REX_BLOCK", "REX_CLIENT" }) |name| l.unsetenv(name);
        const argv = [_:null]?[*:0]const u8{ "rex", "-S", address.ptr, "--autostart=false", "forward", "open", "--no-open", "--bind", "127.0.0.1", "--session", session.ptr, dest.ptr };
        var err: ?*glib.Error = null;
        const process = l.spawnv(@ptrCast(&argv), &err) orelse {
            if (err) |e| e.free();
            return error.SpawnFailed;
        };
        next_id += 1;
        f.* = .{ .id = next_id, .server = server, .host = host, .port = target.port, .process = process };
        active.appendAssumeCapacity(f);
        generation += 1;
        running += 1;
        process.waitAsync(null, &exited, f);
        f.timer = glib.timeoutAdd(15_000, &timeout, f);
        f.read();
        return f;
    }

    pub fn close(f: *Forward) void {
        if (f.stopped) return;
        f.stopped = true;
        if (std.mem.indexOfScalar(*Forward, active.items, f)) |i| _ = active.orderedRemove(i);
        generation += 1;
        if (f.timer != 0) _ = glib.Source.remove(f.timer);
        f.process.sendSignal(@backingInt(std.posix.SIG.INT));
        f.timer = glib.timeoutAdd(2000, &kill, f);
    }

    fn fail(f: *Forward, text: []const u8) void {
        if (f.stopped) return;
        f.server.notifyMessage(text);
        f.close();
    }

    fn unref(f: *Forward) void {
        f.refs -= 1;
        if (f.refs != 0) return;
        if (f.parent) |p| p.as(gobject.Object).unref();
        for (f.pending.items) |url| gpa.free(url);
        f.pending.deinit(gpa);
        f.output.deinit(gpa);
        f.process.unref();
        gpa.free(f.host);
        gpa.destroy(f);
    }

    fn timeout(data: ?*anyopaque) callconv(.c) c_int {
        const f: *Forward = @ptrCast(@alignCast(data.?));
        f.timer = 0;
        f.fail("Rex did not start the port forward within 15 seconds");
        return 0;
    }

    fn kill(data: ?*anyopaque) callconv(.c) c_int {
        const f: *Forward = @ptrCast(@alignCast(data.?));
        f.timer = 0;
        f.process.forceExit();
        return 0;
    }

    fn read(f: *Forward) void {
        f.refs += 1;
        f.process.getStdoutPipe().?.readBytesAsync(1024, 0, null, &received, f);
    }

    fn received(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const f: *Forward = @ptrCast(@alignCast(data.?));
        defer f.unref();
        var err: ?*glib.Error = null;
        const bytes = f.process.getStdoutPipe().?.readBytesFinish(result, &err) orelse {
            if (err) |e| e.free();
            return f.fail("Couldn't read the Rex port forward's address");
        };
        defer bytes.unref();
        if (f.stopped or bytes.getSize() == 0) return;
        if (f.local_port == 0) {
            const raw = bytes.getData(null).?[0..bytes.getSize()];
            if (raw.len + f.output.items.len > 4096) return f.fail("Rex returned an invalid port-forward address");
            f.output.appendSlice(gpa, raw) catch return f.fail("Not enough memory for port forwarding");
            if (std.mem.indexOfScalar(u8, f.output.items, '\n')) |end| {
                const line = std.mem.trim(u8, f.output.items[0..end], "\r");
                const address = Target.parse(line) catch {
                    if (std.unicode.utf8ValidateSlice(line)) f.fail(line) else f.fail("Rex couldn't create the port forward");
                    return;
                };
                if (!address.loopback()) return f.fail("Rex returned a non-local listening address");
                f.local_port = address.port;
                if (f.timer != 0) _ = glib.Source.remove(f.timer);
                f.timer = 0;
                generation += 1;
                for (f.pending.items) |url| {
                    if (Target.parse(url)) |target| launch(target, f.local_port, f.parent) else |_| {}
                    gpa.free(url);
                }
                f.pending.clearRetainingCapacity();
                if (f.parent) |p| p.as(gobject.Object).unref();
                f.parent = null;
            }
        }
        f.read();
    }

    fn exited(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const f: *Forward = @ptrCast(@alignCast(data.?));
        _ = f.process.waitFinish(result, null);
        if (!f.stopped) f.fail(if (f.local_port == 0) "Rex couldn't create the port forward; check the host and update the Rex CLI/server" else "Port forward closed");
        if (f.timer != 0) _ = glib.Source.remove(f.timer);
        f.timer = 0;
        running -= 1;
        f.unref();
    }
};

test "remote localhost links require an exact loopback host and explicit valid port" {
    for ([_][]const u8{ "http://localhost:3000", "https://LOCALHOST:443/x?q=1#top", "http://127.0.0.1:8000", "http://[::1]:8000", "http://0.0.0.0:8000" }) |url| {
        try std.testing.expect(remoteLink("http://remote:1234", url));
        try std.testing.expect(!remoteLink("unix:///tmp/rex.sock", url));
    }
    for ([_][]const u8{ "http://localhost/", "http://1234", "http://localhost:0", "http://localhost:65536", "http://localhost:-1", "http://localhost:abc", "http://localhost.evil:3000", "http://localhost:3000@evil:80", "http://user@localhost:80", "http://[::1]:3000evil", "http://::1:3000", "file://localhost:3000/a", "localhost:3000", "http://:3000", "http://local%68ost:3000", "http://localhost:80\n" }) |url| try std.testing.expect(!remoteLink("http://remote:1234", url));
}

test "typed forwarding targets validate ports and reject ambiguous authorities" {
    const ipv6 = try Target.parse("[::1]:65535");
    try std.testing.expectEqualStrings("[::1]", ipv6.host);
    try std.testing.expectEqual(@as(u16, 65535), ipv6.port);
    try std.testing.expectEqualStrings("localhost", (try Target.parse("0.0.0.0:8000")).dialHost());
    for ([_][]const u8{ "", "0", "65536", "-1", ":80", "[]:80", "localhost:80/extra", "user@host:80", "host:80 trailing", "host:80\x00" }) |text| try std.testing.expectError(error.InvalidTarget, Target.parse(text));
}

test "forward integration carries bytes, reuses a listener and closes cleanly" {
    const url = std.mem.span(std.c.getenv("RENUX_FORWARD_TEST_URL") orelse return error.SkipZigTest);
    const sid = std.mem.span(std.c.getenv("RENUX_FORWARD_TEST_SESSION").?);
    const target = try Target.parse(std.mem.span(std.c.getenv("RENUX_FORWARD_TEST_TARGET").?));
    var server: Server = .{ .url = try gpa.dupe(u8, url), .client_label = try gpa.dupe(u8, "forward test"), .state = .online };
    defer gpa.free(server.url);
    defer gpa.free(server.client_label);
    defer shutdown();
    const f = try Forward.start(&server, sid, target);
    try std.testing.expectEqual(f, try Forward.start(&server, sid, target));
    const until = glib.getMonotonicTime() + 10_000_000;
    while (active.items.len > 0 and f.local_port == 0 and glib.getMonotonicTime() < until) {
        _ = glib.MainContext.default().iteration(0);
        glib.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 1), active.items.len);
    try std.testing.expect(f.local_port != 0);
    const address = try target.rewrite(gpa, f.local_port);
    defer gpa.free(address);
    const output = try commandOutput(&.{ "curl", "-fsS", "--max-time", "5", address });
    defer glib.free(output);
    try std.testing.expectEqualStrings("/proof?from=integration\n", std.mem.span(output));
    cancelForServer(&server);
    shutdown();
    try std.testing.expectEqual(@as(usize, 0), active.items.len);
    try std.testing.expectEqual(@as(usize, 0), running);
    const listing = try commandOutput(&.{ "rex", "-S", url, "--autostart=false", "forward", "ls", "--session", sid, "--json" });
    defer glib.free(listing);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.span(listing), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), @import("../util/json.zig").array(parsed.value, "forwards").len);
    // A close before the address arrives must also reap the child and never open a browser.
    _ = try Forward.start(&server, sid, target);
    cancelForServer(&server);
    shutdown();
    try std.testing.expectEqual(@as(usize, 0), running);
}

fn commandOutput(args: []const [:0]const u8) ![*:0]u8 {
    var argv: [16]?[*:0]const u8 = @splat(null);
    for (args, 0..) |arg, i| argv[i] = arg.ptr;
    const process = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_pipe = true, .stderr_silence = true }, null) orelse return error.SpawnFailed;
    defer process.unref();
    var output: [*:0]u8 = undefined;
    if (process.communicateUtf8(null, null, &output, null, null) == 0) return error.CommandFailed;
    errdefer glib.free(output);
    try std.testing.expect(process.getSuccessful() != 0);
    return output;
}

test "rewrite preserves scheme, path, query and fragment, including encoded punctuation" {
    const allocator = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "http://localhost:3000", "http://127.0.0.1:4567" },
        .{ "https://[::1]:8000/a%2Fb?q=x%26y#top", "https://127.0.0.1:4567/a%2Fb?q=x%26y#top" },
        .{ "http://0.0.0.0:8000?x=1", "http://127.0.0.1:4567?x=1" },
        .{ "3000", "http://127.0.0.1:4567" },
        .{ "dev.internal:8080", "http://127.0.0.1:4567" },
    }) |pair| {
        const target = try Target.parse(pair[0]);
        const url = try target.rewrite(allocator, 4567);
        defer allocator.free(url);
        try std.testing.expectEqualStrings(pair[1], url);
    }
}

//! One system SSH process forwards a remote Unix socket for all of a host's WebSockets.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");
const json = @import("../util/json.zig");
const gpa = std.heap.c_allocator;

pub const Address = struct {
    destination: []const u8,
    host: []const u8,
    socket: ?[]const u8,
};

pub fn isSsh(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "ssh://");
}

/// Slices borrow the input. Bare user@host is accepted too; bare host remains an HTTP address.
pub fn parse(url: []const u8) !Address {
    const raw = if (isSsh(url)) url[6..] else if (std.mem.indexOfScalar(u8, url, '@') != null) url else return error.InvalidSshAddress;
    const end = std.mem.indexOfScalar(u8, raw, '/') orelse raw.len;
    const destination = raw[0..end];
    var host_port = destination;
    if (std.mem.indexOfScalar(u8, destination, '@')) |at| {
        if (at == 0) return error.InvalidSshAddress;
        for (destination[0..at]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return error.InvalidSshAddress;
        host_port = destination[at + 1 ..];
    }
    if (host_port.len == 0 or host_port[0] == '-') return error.InvalidSshAddress;
    var host: []const u8 = undefined;
    var port: []const u8 = "";
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.InvalidSshAddress;
        host = host_port[1..close];
        if (host.len == 0 or std.mem.indexOfScalar(u8, host, ':') == null) return error.InvalidSshAddress;
        for (host) |c| if (!std.ascii.isHex(c) and c != ':' and c != '.') return error.InvalidSshAddress;
        const rest = host_port[close + 1 ..];
        if (rest.len != 0) {
            if (rest[0] != ':') return error.InvalidSshAddress;
            port = rest;
        }
    } else {
        const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
        host = host_port[0..colon];
        port = host_port[colon..];
        if (host.len == 0) return error.InvalidSshAddress;
        for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidSshAddress;
    }
    if (port.len != 0) {
        if (port.len == 1) return error.InvalidSshAddress;
        for (port[1..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidSshAddress;
        const number = std.fmt.parseInt(u16, port[1..], 10) catch return error.InvalidSshAddress;
        if (number == 0) return error.InvalidSshAddress;
    }
    const socket = if (end < raw.len) raw[end..] else null;
    if (socket) |path| if (!validSocket(path)) return error.InvalidSshAddress;
    return .{ .destination = destination, .host = host, .socket = socket };
}

pub fn normalizeUrl(allocator: std.mem.Allocator, typed: []const u8) ![]u8 {
    const raw = std.mem.trim(u8, typed, " \r\n\t");
    if (raw.len == 0) return error.EmptyAddress;
    const has_scheme = std.mem.indexOf(u8, raw, "://") != null;
    const ssh = isSsh(raw) or (!has_scheme and std.mem.indexOfScalar(u8, raw, '@') != null);
    if (ssh) _ = try parse(raw);
    if (!has_scheme) return std.fmt.allocPrint(allocator, "{s}://{s}", .{ if (ssh) "ssh" else "http", raw });
    return allocator.dupe(u8, raw);
}

fn validSocket(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/') return false;
    // Colons change the meaning of OpenSSH's -L argument; no shell ever sees this path.
    for (path) |c| if (c < 32 or c == 127 or c == ':' or c == '%' or c == '?' or c == '#') return false;
    return true;
}

pub const Listener = struct {
    ctx: *anyopaque,
    /// Null means ready. Errors include SSH's diagnostic; no credential questions are hidden.
    changed: *const fn (*anyopaque, ?[]const u8) void,
};

pub const Tunnel = struct {
    listener: Listener,
    destination: [:0]u8,
    directory: [*:0]u8,
    path: [:0]u8,
    url: []u8,
    proc: ?*gio.Subprocess = null,
    timer: c_uint = 0,
    ticks: u16 = 0,
    dead: bool = false,
    timed_out: bool = false,

    pub fn start(address: []const u8, listener: Listener) !*Tunnel {
        const parsed = try parse(address);
        const destination = try std.fmt.allocPrintSentinel(gpa, "ssh://{s}", .{parsed.destination}, 0);
        errdefer gpa.free(destination);
        const dir = glib.Dir.makeTmp("renux-ssh-XXXXXX", null) orelse return error.NoTempFolder;
        errdefer {
            _ = std.c.rmdir(dir);
            glib.free(dir);
        }
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/rex.sock", .{dir}, 0);
        errdefer gpa.free(path);
        const url = try std.fmt.allocPrint(gpa, "unix://{s}", .{path});
        errdefer gpa.free(url);
        const t = try gpa.create(Tunnel);
        errdefer gpa.destroy(t);
        t.* = .{ .listener = listener, .destination = destination, .directory = dir, .path = path, .url = url };
        if (parsed.socket) |socket| {
            try t.forward(socket);
        } else {
            // Match Rex's public CLI bootstrap, including its unprivileged install location.
            const command = "if command -v rex >/dev/null 2>&1; then r=rex; else r=\"$HOME/.local/bin/rex\"; fi; " ++
                "case \"${REX_AUTOSTART-}\" in \"\"|1|t|T|true|TRUE|True) exec \"$r\" server start --json;; " ++
                "*) exec \"$r\" server status --json;; esac";
            const quoted = try std.fmt.allocPrint(gpa, "sh -c '{s}'", .{command});
            defer gpa.free(quoted);
            t.proc = try t.spawn(&.{ "-o", "ClearAllForwardings=yes", "--", t.destination, quoted });
            t.proc.?.communicateUtf8Async(null, null, &bootstrapped, t);
        }
        t.timer = glib.timeoutAdd(50, &poll, t);
        return t;
    }

    pub fn stop(t: *Tunnel) void {
        t.dead = true;
        t.cancelTimer();
        _ = std.c.unlink(t.path.ptr);
        _ = std.c.rmdir(t.directory);
        // The outstanding communicate callback owns the remaining lifetime.
        if (t.proc) |p| p.forceExit() else t.free();
    }

    fn free(t: *Tunnel) void {
        _ = std.c.unlink(t.path.ptr);
        _ = std.c.rmdir(t.directory);
        glib.free(t.directory);
        gpa.free(t.path);
        gpa.free(t.url);
        gpa.free(t.destination);
        gpa.destroy(t);
    }

    fn cancelTimer(t: *Tunnel) void {
        if (t.timer != 0) _ = glib.Source.remove(t.timer);
        t.timer = 0;
    }

    fn spawn(_: *Tunnel, tail: []const []const u8) !*gio.Subprocess {
        const common = [_][]const u8{ "ssh", "-T", "-n", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ControlMaster=no", "-o", "ControlPath=none" };
        var argv: [40:null]?[*:0]const u8 = @splat(null);
        var owned: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned.items) |arg| gpa.free(arg);
            owned.deinit(gpa);
        }
        for (0..common.len + tail.len) |i| {
            const arg = try gpa.dupeSentinel(u8, if (i < common.len) common[i] else tail[i - common.len], 0);
            owned.append(gpa, arg) catch |err| {
                gpa.free(arg);
                return err;
            };
            argv[i] = arg.ptr;
        }
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_pipe = true, .stderr_pipe = true });
        defer launcher.as(gobject.Object).unref();
        inline for (.{ "REX_SERVER", "REX_SESSION", "REX_BLOCK" }) |name| launcher.unsetenv(name);
        // BatchMode alone may still allow a configured askpass helper for host-key questions.
        launcher.setenv("SSH_ASKPASS_REQUIRE", "never", 1);
        var parent = std.c.getpid();
        if (@import("builtin").os.tag == .linux) launcher.setChildSetup(&dieWithParent, &parent, null);
        var err: ?*glib.Error = null;
        defer if (err) |e| e.free();
        return launcher.spawnv(@ptrCast(&argv), &err) orelse error.SshNotInstalled;
    }

    fn dieWithParent(data: ?*anyopaque) callconv(.c) void {
        if (@import("builtin").os.tag != .linux) return;
        const parent: *const std.c.pid_t = @ptrCast(@alignCast(data.?));
        const linux = std.os.linux;
        // A crash or SIGTERM must not leave an authenticated SSH connection running.
        if (linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0) != 0 or linux.getppid() != parent.*) linux.exit(127);
    }

    fn forward(t: *Tunnel, remote: []const u8) !void {
        if (!validSocket(remote)) return error.InvalidRemoteSocket;
        const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ t.path, remote });
        defer gpa.free(spec);
        t.proc = try t.spawn(&.{ "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindMask=0177", "-L", spec, "--", t.destination });
        t.proc.?.communicateUtf8Async(null, null, &ended, t);
    }

    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const t: *Tunnel = @ptrCast(@alignCast(data.?));
        t.ticks += 1;
        if (glib.fileTest(t.path.ptr, .{ .exists = true }) != 0) {
            t.timer = 0;
            t.listener.changed(t.listener.ctx, null);
            return 0;
        }
        if (t.ticks >= 400) {
            t.timer = 0;
            t.timed_out = true;
            if (t.proc) |p| p.forceExit();
            return 0;
        }
        return 1;
    }

    fn failure(t: *Tunnel, detail: []const u8) void {
        t.cancelTimer();
        const description = if (detail.len == 0) "Tunnel closed" else detail[0..@min(detail.len, 2048)];
        const message = std.fmt.allocPrint(gpa, "SSH: {s}\nUse a trusted host key and an unlocked key or agent; Renux cannot answer SSH questions yet.", .{description}) catch {
            t.listener.changed(t.listener.ctx, "SSH connection failed");
            return;
        };
        defer gpa.free(message);
        t.listener.changed(t.listener.ctx, message);
    }

    fn bootstrapped(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *Tunnel = @ptrCast(@alignCast(data.?));
        var out: ?[*:0]u8 = null;
        var stderr: ?[*:0]u8 = null;
        const p = t.proc.?;
        const ok = p.communicateUtf8Finish(result, @ptrCast(&out), @ptrCast(&stderr), null) != 0 and p.getSuccessful() != 0;
        p.as(gobject.Object).unref();
        t.proc = null;
        defer if (out) |s| glib.free(s);
        defer if (stderr) |s| glib.free(s);
        if (t.dead) return t.free();
        if (!ok or t.timed_out) return t.failure(if (t.timed_out) "Connection timed out" else if (stderr) |s| std.mem.trim(u8, std.mem.span(s), " \r\n") else "Couldn't discover the remote Rex server");
        const text = if (out) |s| std.mem.span(s) else "";
        var parsed = std.json.parseFromSlice(json.Value, gpa, text, .{ .ignore_unknown_fields = true }) catch return t.failure("Remote rex returned invalid status JSON");
        defer parsed.deinit();
        const endpoint = json.str(parsed.value, "endpoint") orelse return t.failure("Remote rex returned no endpoint");
        const path = @import("ws.zig").unixPath(endpoint) orelse return t.failure("Only remote Unix sockets are supported over SSH");
        t.forward(path) catch return t.failure("Couldn't forward the remote Rex socket");
    }

    fn ended(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *Tunnel = @ptrCast(@alignCast(data.?));
        var stderr: ?[*:0]u8 = null;
        const p = t.proc.?;
        _ = p.communicateUtf8Finish(result, null, @ptrCast(&stderr), null);
        p.as(gobject.Object).unref();
        t.proc = null;
        defer if (stderr) |s| glib.free(s);
        if (t.dead) return t.free();
        t.failure(if (t.timed_out) "Connection timed out" else if (stderr) |s| std.mem.trim(u8, std.mem.span(s), " \r\n") else "Tunnel closed");
    }
};

test "SSH address forms and explicit sockets" {
    const bare = try parse("user@box");
    try std.testing.expectEqualStrings("user@box", bare.destination);
    try std.testing.expectEqualStrings("box", bare.host);
    try std.testing.expect(bare.socket == null);
    const port = try parse("ssh://user@box:2222");
    try std.testing.expectEqualStrings("user@box:2222", port.destination);
    try std.testing.expectEqualStrings("box", port.host);
    const socket = try parse("ssh://box/run/rex/server.sock");
    try std.testing.expectEqualStrings("/run/rex/server.sock", socket.socket.?);
    const ipv6 = try parse("ssh://alice@[::1]:2222/tmp/rex.sock");
    try std.testing.expectEqualStrings("::1", ipv6.host);
    try std.testing.expectEqualStrings("alice@[::1]:2222", ipv6.destination);
}

test "host entry normalizes SSH shorthand without changing other transports" {
    for ([_][2][]const u8{
        .{ " user@box ", "ssh://user@box" },
        .{ "ssh://user@box:2222", "ssh://user@box:2222" },
        .{ "box:8765", "http://box:8765" },
        .{ "https://box", "https://box" },
        .{ "http://user@box", "http://user@box" },
        .{ "unix:///tmp/rex.sock", "unix:///tmp/rex.sock" },
    }) |pair| {
        const url = try normalizeUrl(std.testing.allocator, pair[0]);
        defer std.testing.allocator.free(url);
        try std.testing.expectEqualStrings(pair[1], url);
    }
    try std.testing.expectError(error.EmptyAddress, normalizeUrl(std.testing.allocator, " \n"));
    try std.testing.expectError(error.InvalidSshAddress, normalizeUrl(std.testing.allocator, "ssh://box:bad"));
}

test "SSH rejects malformed addresses and forwarding argument injection" {
    for ([_][]const u8{ "box", "ssh://", "ssh://@box", "ssh://-obox", "-oProxyCommand=x@box", "ssh://a@@box", "ssh://box:", "ssh://box:0", "ssh://box:65536", "ssh://box:+22", "ssh://box:22:23", "ssh://box x", "ssh://box\n", "ssh://[::1", "ssh://[::1]x", "ssh://[]", "ssh://box/", "ssh://box/tmp/a:b", "ssh://box/tmp/a\x00b", "ssh://box/tmp/a\nb", "ssh://box/tmp/%20" }) |bad| {
        try std.testing.expectError(error.InvalidSshAddress, parse(bad));
    }
}

test "SSH bootstrap, forwarding, errors and cancellation clean up their process and socket" {
    const dir = glib.Dir.makeTmp("renux-ssh-test-XXXXXX", null) orelse return error.NoTempFolder;
    defer glib.free(dir);
    defer _ = std.c.rmdir(dir);
    const script = try std.fmt.allocPrintSentinel(gpa, "{s}/ssh", .{dir}, 0);
    defer gpa.free(script);
    defer _ = std.c.unlink(script.ptr);
    const contents =
        "#!/bin/sh\n" ++
        "case \"$RENUX_SSH_FIXTURE\" in error) echo 'Host key verification failed.' >&2; exit 255;; pending) exec /bin/sleep 30;; esac\n" ++
        "while [ $# -gt 0 ]; do\n" ++
        " if [ \"$1\" = -L ]; then shift; : > \"${1%%:*}\"; exec /bin/sleep 30; fi\n" ++
        " shift\ndone\n" ++
        "printf '{\"endpoint\":\"unix:///tmp/fixture-rex.sock\"}\\n'\n";
    try std.testing.expect(glib.fileSetContentsFull(script.ptr, contents.ptr, contents.len, .{}, 0o700, null) != 0);
    const old_path = try gpa.dupeSentinel(u8, std.mem.span(std.c.getenv("PATH") orelse ""), 0);
    defer gpa.free(old_path);
    defer _ = glib.setenv("PATH", old_path.ptr, 1);
    defer glib.unsetenv("RENUX_SSH_FIXTURE");
    _ = glib.setenv("PATH", dir, 1);
    const Probe = struct {
        calls: usize = 0,
        failed: bool = false,
        fn changed(ctx: *anyopaque, message: ?[]const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.calls += 1;
            p.failed = message != null;
            if (message) |m| std.debug.assert(std.mem.indexOf(u8, m, "Host key verification failed") != null);
        }
    };
    for (0..4) |scenario| {
        _ = glib.setenv("RENUX_SSH_FIXTURE", if (scenario == 2) "error" else if (scenario == 3) "pending" else "success", 1);
        var p: Probe = .{};
        const t = try Tunnel.start(if (scenario == 1) "ssh://alice@box:2222/tmp/rex.sock" else "ssh://alice@box", .{ .ctx = &p, .changed = Probe.changed });
        const directory = try gpa.dupeSentinel(u8, std.mem.span(t.directory), 0);
        defer gpa.free(directory);
        if (scenario != 3) {
            var ticks: usize = 0;
            while (p.calls == 0 and ticks < 5000) : (ticks += 1) {
                _ = glib.MainContext.default().iteration(0);
                glib.usleep(1000);
            }
        }
        t.stop();
        // Let the cancelled communicate operation reap its child and finish freeing the tunnel.
        for (0..100) |_| {
            _ = glib.MainContext.default().iteration(0);
            glib.usleep(1000);
        }
        try std.testing.expectEqual(@as(usize, if (scenario == 3) 0 else 1), p.calls);
        try std.testing.expectEqual(scenario == 2, p.failed);
        try std.testing.expect(glib.fileTest(directory.ptr, .{ .exists = true }) == 0);
    }
}

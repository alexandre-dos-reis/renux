//! One desktop sleep inhibitor for all the working agents, including panes on other hosts.
const std = @import("std");
const gtk = @import("gtk");
const App = @import("app.zig").App;
const BlockInfo = @import("../rex/server.zig").BlockInfo;
const settings = @import("../settings/settings.zig");

/// A reported state counts, not a program name, progress bar, or an old cached state alone.
pub fn working(info: BlockInfo) bool {
    return info.has_status and info.status == .working;
}

fn needed(a: *App, enabled: bool) bool {
    if (!enabled) return false;
    for (a.hosts.items) |h| {
        if (h.server.state != .online) continue;
        // Session views exclude closed panes and sessions whose cached block details remain.
        var views = h.server.views.valueIterator();
        while (views.next()) |v| for (v.*.windows) |w| for (w.layers) |l| for (l.blocks) |b| {
            if (h.server.blockInfo(b.id)) |info| if (working(info.*)) return true;
        };
    }
    return false;
}

pub const Inhibitor = struct {
    cookie: c_uint = 0,
    /// Don't retry a desktop that refused on every block event. Off/on allows another try.
    requested: bool = false,

    pub fn sync(i: *Inhibitor, a: *App) void {
        if (!needed(a, settings.current.keep_awake_while_working)) return i.release(a.app.as(gtk.Application));
        if (i.requested) return;
        i.requested = true;
        i.cookie = a.app.as(gtk.Application).inhibit(a.window.as(gtk.Window), .{ .@"suspend" = true, .idle = true }, "An agent is working");
        if (i.cookie == 0) {
            std.log.warn("keep awake: the desktop did not grant a suspend/idle inhibitor", .{});
        } else if (@import("build_options").dev) std.log.info("keep awake: acquired suspend/idle inhibitor {d}", .{i.cookie});
    }

    pub fn release(i: *Inhibitor, app: *gtk.Application) void {
        if (i.cookie != 0) {
            app.uninhibit(i.cookie);
            if (@import("build_options").dev) std.log.info("keep awake: released inhibitor {d}", .{i.cookie});
        } else if (i.requested and @import("build_options").dev) std.log.info("keep awake: released request (desktop had refused it)", .{});
        i.cookie = 0;
        i.requested = false;
    }
};

test "sleep inhibition follows background panes, disconnection, closure and the switch" {
    const gpa = std.testing.allocator;
    const view = @import("../rex/view.zig");
    const Server = @import("../rex/server.zig").Server;
    const Host = @import("app.zig").Host;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"session_id":"s","windows":[{"window_id":"w","layers":[{"layer_id":"l","kind":"tiled","blocks":[{"block_id":"b"}]}]}]}
    , .{});
    defer parsed.deinit();
    const v = (try view.parse(parsed.value)).?;
    defer v.destroy();
    var server: Server = .{ .url = &.{}, .client_label = &.{}, .state = .online };
    defer server.views.deinit(gpa);
    defer server.blocks.deinit(gpa);
    try server.views.put(gpa, "s", v);
    try server.blocks.put(gpa, "b", .{ .has_status = true, .status = .working });
    var app: App = .{ .app = undefined };
    defer app.hosts.deinit(gpa);
    var host: Host = .{ .app = &app, .label = &.{}, .server = &server, .workspace = undefined, .page = undefined, .shot = undefined };
    try app.hosts.append(gpa, &host);
    try std.testing.expect(needed(&app, true));
    try std.testing.expect(!needed(&app, false));
    server.state = .offline;
    try std.testing.expect(!needed(&app, true));
    server.state = .online;
    server.blocks.getPtr("b").?.status = .blocked;
    try std.testing.expect(!needed(&app, true));
    server.blocks.getPtr("b").?.status = .working;
    try std.testing.expect(needed(&app, true));
    server.views.clearRetainingCapacity();
    try std.testing.expect(!needed(&app, true));
}

test "only a program reporting working requests sleep inhibition" {
    try std.testing.expect(working(.{ .has_status = true, .status = .working }));
    try std.testing.expect(!working(.{ .status = .working }));
    inline for (.{ .blocked, .done, .failed, .other }) |state| {
        try std.testing.expect(!working(.{ .has_status = true, .status = state }));
    }
    try std.testing.expect(!working(.{ .progress = -1 }));
    try std.testing.expect(!working(.{}));
}

//! The Wayland-only touch: saying which parts of a see-through window the desktop blurs.
//!
//! Hyprland blurs everything behind a see-through window, its empty parts too. A window that
//! names the region to blur, with the `ext-background-effect-v1` protocol, has only that
//! region blurred and the desktop shows sharp through the rest. Giving the region up brings
//! Hyprland's own blur back.
//!
//! This is done on Hyprland only. A desktop that blurs nothing unless asked would start to
//! blur what is named here, which is a different thing from what the caller wants.
const std = @import("std");

const Proxy = opaque {};
const Message = extern struct { name: [*:0]const u8, signature: [*:0]const u8, types: [*]const ?*const Interface };
const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

extern const wl_registry_interface: Interface;
extern const wl_compositor_interface: Interface;
extern const wl_region_interface: Interface;
extern const wl_surface_interface: Interface;
extern fn wl_proxy_marshal_flags(proxy: *Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, ...) ?*Proxy;
extern fn wl_proxy_add_listener(proxy: *Proxy, implementation: *const anyopaque, data: ?*anyopaque) c_int;
extern fn wl_proxy_create_wrapper(proxy: *anyopaque) ?*Proxy;
extern fn wl_proxy_wrapper_destroy(wrapper: *Proxy) void;
extern fn wl_proxy_set_queue(proxy: *Proxy, queue: ?*anyopaque) void;
extern fn wl_display_create_queue(display: *anyopaque) ?*anyopaque;
extern fn wl_display_roundtrip_queue(display: *anyopaque, queue: *anyopaque) c_int;
extern fn wl_display_flush(display: *anyopaque) c_int;
extern fn gdk_wayland_display_get_type() usize;
extern fn gdk_wayland_display_get_wl_display(display: *anyopaque) ?*anyopaque;
extern fn gdk_wayland_surface_get_wl_surface(surface: *anyopaque) ?*Proxy;
extern fn gdk_surface_get_display(surface: *anyopaque) *anyopaque;
extern fn gdk_surface_get_width(surface: *anyopaque) c_int;
extern fn gdk_surface_get_height(surface: *anyopaque) c_int;
extern fn g_type_check_instance_is_a(instance: *anyopaque, gtype: usize) c_int;

// The protocol, as `wayland-scanner` would write it out from ext-background-effect-v1.xml.
const no_types = [_]?*const Interface{null};
const effect_types = [_]?*const Interface{ &effect_interface, &wl_surface_interface };
const region_types = [_]?*const Interface{&wl_region_interface};
const manager_interface: Interface = .{
    .name = "ext_background_effect_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = &[_]Message{
        .{ .name = "destroy", .signature = "", .types = &no_types },
        .{ .name = "get_background_effect", .signature = "no", .types = &effect_types },
    },
    .event_count = 1,
    .events = &[_]Message{.{ .name = "capabilities", .signature = "u", .types = &no_types }},
};
const effect_interface: Interface = .{
    .name = "ext_background_effect_surface_v1",
    .version = 1,
    .method_count = 2,
    .methods = &[_]Message{
        .{ .name = "destroy", .signature = "", .types = &no_types },
        .{ .name = "set_blur_region", .signature = "?o", .types = &region_types },
    },
    .event_count = 0,
    .events = null,
};

/// Marks a request as the one that ends its object (WL_MARSHAL_FLAG_DESTROY).
const ends: u32 = 1;
const none: ?*anyopaque = null;

var asked = false;
var hyprland = false;
var manager: ?*Proxy = null;
var compositor: ?*Proxy = null;
/// The window's blur region, while it names one.
var effect: ?*Proxy = null;

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};
const registry_listener: RegistryListener = .{ .global = &global, .global_remove = &globalRemoved };

fn global(_: ?*anyopaque, registry: *Proxy, name: u32, interface: [*:0]const u8, _: u32) callconv(.c) void {
    const what = std.mem.span(interface);
    if (std.mem.eql(u8, what, "ext_background_effect_manager_v1")) {
        manager = bind(registry, name, &manager_interface);
    } else if (std.mem.eql(u8, what, "wl_compositor")) {
        compositor = bind(registry, name, &wl_compositor_interface);
    } else if (std.mem.startsWith(u8, what, "hyprland_")) {
        hyprland = true;
    }
}

fn globalRemoved(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

fn bind(registry: *Proxy, name: u32, interface: *const Interface) ?*Proxy {
    return wl_proxy_marshal_flags(registry, 0, interface, 1, 0, name, interface.name, @as(u32, 1), none);
}

/// Finds out, once, what the desktop offers. The answers come on a queue of their own, so
/// waiting for them runs none of GTK's own handlers from inside whatever asked.
fn ask(surface: *anyopaque) void {
    if (asked) return;
    asked = true;
    const gdk_display = gdk_surface_get_display(surface);
    if (g_type_check_instance_is_a(gdk_display, gdk_wayland_display_get_type()) == 0) return;
    const display = gdk_wayland_display_get_wl_display(gdk_display) orelse return;
    const queue = wl_display_create_queue(display) orelse return;
    const wrapper = wl_proxy_create_wrapper(display) orelse return;
    defer wl_proxy_wrapper_destroy(wrapper);
    wl_proxy_set_queue(wrapper, queue);
    const registry = wl_proxy_marshal_flags(wrapper, 1, &wl_registry_interface, 1, 0, none) orelse return;
    _ = wl_proxy_add_listener(registry, &registry_listener, null);
    _ = wl_display_roundtrip_queue(display, queue);
}

/// Goes up each time something is said about the blur. More than one part of the app names
/// what to blur, each remembering what it last said so as not to say it again on every frame;
/// by this each can tell that another has spoken since.
pub var said: u32 = 0;

/// A part of the window to blur, in the window's own units, with corners as round as the
/// card it lies behind.
pub const Part = struct { x: f64, y: f64, w: f64, h: f64, radius: f64 = 0 };

/// The region being put together, and the window's size, which it is kept inside: Hyprland
/// 0.57 blurs nothing at all while any of a region is outside the window.
const Naming = struct {
    region: *Proxy,
    effect: *Proxy,
    right: f64,
    bottom: f64,

    fn start(surface: *anyopaque) ?Naming {
        ask(surface);
        if (!hyprland) return null;
        const m = manager orelse return null;
        const c = compositor orelse return null;
        const wl_surface = gdk_wayland_surface_get_wl_surface(surface) orelse return null;
        if (effect == null) effect = wl_proxy_marshal_flags(m, 1, &effect_interface, 1, 0, none, wl_surface);
        const e = effect orelse return null;
        const region = wl_proxy_marshal_flags(c, 1, &wl_region_interface, 1, 0, none) orelse return null;
        return .{ .region = region, .effect = e, .right = @floatFromInt(gdk_surface_get_width(surface)), .bottom = @floatFromInt(gdk_surface_get_height(surface)) };
    }

    fn add(n: Naming, left: f64, top: f64, right: f64, bottom: f64) void {
        const x0 = std.math.clamp(@round(left), 0, n.right);
        const y0 = std.math.clamp(@round(top), 0, n.bottom);
        const x1 = std.math.clamp(@round(right), 0, n.right);
        const y1 = std.math.clamp(@round(bottom), 0, n.bottom);
        if (x1 <= x0 or y1 <= y0) return;
        _ = wl_proxy_marshal_flags(n.region, 1, null, 1, 0, @as(c_int, @intFromFloat(x0)), @as(c_int, @intFromFloat(y0)), @as(c_int, @intFromFloat(x1 - x0)), @as(c_int, @intFromFloat(y1 - y0)));
    }

    fn finish(n: Naming) void {
        _ = wl_proxy_marshal_flags(n.effect, 1, null, 1, 0, n.region);
        _ = wl_proxy_marshal_flags(n.region, 0, null, 1, ends);
        said +%= 1;
    }
};

/// Has the desktop blur only these parts of the window. It takes effect with the next frame
/// drawn, so it is called while drawing the frame the parts belong to. Does nothing where it
/// isn't needed or can't be done. A region is made of rectangles, so a round corner is a row
/// of them, one for each line of it.
pub fn blurParts(surface: *anyopaque, parts: []const Part) void {
    const n = Naming.start(surface) orelse return;
    for (parts) |p| {
        const r = @floor(@max(0, @min(p.radius, p.w / 2, p.h / 2)));
        n.add(p.x, p.y + r, p.x + p.w, p.y + p.h - r);
        var line: f64 = 0;
        while (line < r) : (line += 1) {
            const up = r - line - 0.5;
            const inset = r - @sqrt(r * r - up * up);
            n.add(p.x + inset, p.y + line, p.x + p.w - inset, p.y + line + 1);
            n.add(p.x + inset, p.y + p.h - line - 1, p.x + p.w - inset, p.y + p.h - line);
        }
    }
    n.finish();
}

/// Leaves the blur to the desktop again.
pub fn blurAsUsual(surface: *anyopaque) void {
    const e = effect orelse return;
    effect = null;
    said +%= 1;
    _ = wl_proxy_marshal_flags(e, 0, null, 1, ends);
    // Said at once: the frame that follows may look the same as the last one, and then
    // nothing is sent for it.
    const wl_surface = gdk_wayland_surface_get_wl_surface(surface) orelse return;
    _ = wl_proxy_marshal_flags(wl_surface, 6, null, 1, 0);
    if (gdk_wayland_display_get_wl_display(gdk_surface_get_display(surface))) |display| _ = wl_display_flush(display);
}

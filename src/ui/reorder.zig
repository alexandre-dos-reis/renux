//! Dragging a group of rows to another place in a list: a session and its windows in the
//! sidebar. The group lifts off as a picture of itself that follows the pointer, the groups it
//! passes slide out of its way, and on release it glides into the gap they left.
//!
//! The list's own rows never move while this goes on. The dragged ones turn clear where they
//! are, and the others are shifted by a style (`shift-up`, `shift-down`), which the toolkit
//! animates. So what is on screen at the end is exactly the new order, and when the caller then
//! builds the list again in that order, nothing jumps.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const graphene = @import("graphene");

const gpa = std.heap.c_allocator;

/// Rows `first` to `first + count - 1` of the list, which move together.
pub const Group = struct {
    first: usize,
    count: usize,
    /// Where it lies in the list, measured when the drag starts. `height` runs to the top of
    /// the next group, so the space between two groups belongs to the one above.
    top: f64 = 0,
    height: f64 = 0,
    /// The bottom of its last row, short of the space under it.
    rows_end: f64 = 0,
};

/// Called once the group has landed: it was group `from` and is to be group `to`.
pub const Done = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, from: usize, to: usize) void };

/// How long the picture takes to glide into place on release, and how long the list is given
/// to come back in its new order before the drag is forgotten.
const settle_us: i64 = 170_000;
const wait_ms: c_uint = 900;
/// The picture is this much larger than the rows it shows, on every side.
const pad: f64 = 4;
/// Near the top or bottom of the list's view, a drag scrolls it.
const edge: f64 = 36;

var active: ?*Reorder = null;
var shift_css: ?*gtk.CssProvider = null;

pub const Reorder = struct {
    list: *gtk.ListBox,
    layer: *gtk.Fixed,
    scroller: *gtk.ScrolledWindow,
    groups: []Group,
    dragged: usize,
    target: usize,
    done: Done,
    ghost: *gtk.Widget,
    /// The pointer in the layer at the last movement, and how far below the picture's top it
    /// took hold. The pointer stays where it is while the list scrolls under it.
    pointer: f64,
    grab: f64,
    start_pointer: f64,
    start_scroll: f64,
    /// The picture's top in the list now.
    at: f64,
    state: enum { dragging, settling, waiting } = .dragging,
    tick: c_uint = 0,
    last_us: i64 = 0,
    settle_from: f64 = 0,
    settle_began: i64 = 0,
    wait: c_uint = 0,
};

/// Whether a drag is under way, or still settling.
pub fn busy() bool {
    return active != null;
}

/// Starts dragging group `dragged` of `groups`, which must lie one after another in the list.
/// `pointer_y` is where the pointer took hold, in the coordinates of `from`. Returns false
/// when there is nothing to reorder.
pub fn begin(list: *gtk.ListBox, layer: *gtk.Fixed, scroller: *gtk.ScrolledWindow, groups: []const Group, dragged: usize, from: *gtk.Widget, pointer_y: f64, done: Done) bool {
    if (active != null or groups.len < 2 or dragged >= groups.len) return false;
    const own = gpa.dupe(Group, groups) catch return false;
    if (!measure(list, own)) {
        gpa.free(own);
        return false;
    }
    var p: graphene.Point = undefined;
    if (from.computePoint(layer.as(gtk.Widget), &.{ .f_x = 0, .f_y = @floatCast(pointer_y) }, &p) == 0) {
        gpa.free(own);
        return false;
    }
    const g = own[dragged];
    // The picture is taken before its rows turn clear.
    const ghost = makeGhost(list, layer, g) orelse {
        gpa.free(own);
        return false;
    };
    const r = gpa.create(Reorder) catch {
        gpa.free(own);
        return false;
    };
    const top_in_layer = toLayer(list, layer, g.top);
    r.* = .{
        .list = list,
        .layer = layer,
        .scroller = scroller,
        .groups = own,
        .dragged = dragged,
        .target = dragged,
        .done = done,
        .ghost = ghost,
        .pointer = p.f_y,
        .grab = p.f_y - top_in_layer,
        .start_pointer = p.f_y,
        .start_scroll = scroller.getVadjustment().getValue(),
        .at = g.top,
    };
    active = r;
    setShift(g.height);
    list.as(gtk.Widget).addCssClass("reordering");
    list.as(gtk.Widget).setCursorFromName("grabbing");
    for (g.first..g.first + g.count) |i| if (list.getRowAtIndex(@intCast(i))) |row| row.as(gtk.Widget).addCssClass("drag-source");
    layer.put(ghost, ghostX(list, layer, g), @floatCast(top_in_layer - pad));
    r.tick = layer.as(gtk.Widget).addTickCallback(&onTick, r, null);
    return true;
}

/// The pointer moved: `dy` is how far it is from where the drag started, as a drag gesture on
/// one of the list's rows reports it.
pub fn update(dy: f64) void {
    const r = active orelse return;
    if (r.state != .dragging) return;
    // The gesture measures against its row, which the list carries along as it scrolls.
    r.pointer = r.start_pointer + dy - (r.scroller.getVadjustment().getValue() - r.start_scroll);
    place(r);
}

/// The button was let go: the group glides into the gap, then `done` is told where it landed.
pub fn drop() void {
    const r = active orelse return;
    if (r.state != .dragging) return;
    r.state = .settling;
    r.settle_from = r.at;
    r.settle_began = 0;
    r.ghost.addCssClass("landing");
}

/// The caller built the list again. After a drop that is the new order arriving, and the
/// picture has done its work; during a drag the rows it was about are gone, so it ends.
pub fn rebuilt() void {
    const r = active orelse return;
    finish(r);
}

/// Ends the drag where it is and puts every row back.
pub fn cancel() void {
    const r = active orelse return;
    finish(r);
}

/// Which place a dragged group takes, given where each group lies and where the dragged one's
/// top is now. It changes places with a neighbour once it covers that neighbour's middle.
pub fn targetIndex(tops: []const f64, heights: []const f64, dragged: usize, top: f64) usize {
    var t = dragged;
    var i = dragged;
    while (i > 0) {
        i -= 1;
        if (top < tops[i] + heights[i] / 2) t = i else break;
    }
    if (t != dragged) return t;
    i = dragged + 1;
    while (i < tops.len) : (i += 1) {
        if (top + heights[dragged] > tops[i] + heights[i] / 2) t = i else break;
    }
    return t;
}

/// Where the dragged group's top is once it has landed at `target`: the groups between slid
/// over by its height, so it takes the far end of the space they filled.
pub fn slotTop(tops: []const f64, heights: []const f64, dragged: usize, target: usize) f64 {
    if (target < dragged) return tops[target];
    if (target > dragged) return tops[target] + heights[target] - heights[dragged];
    return tops[dragged];
}

fn measure(list: *gtk.ListBox, groups: []Group) bool {
    const lw = list.as(gtk.Widget);
    for (groups) |*g| {
        const head = list.getRowAtIndex(@intCast(g.first)) orelse return false;
        const tail = list.getRowAtIndex(@intCast(g.first + g.count - 1)) orelse return false;
        var a: graphene.Rect = undefined;
        var b: graphene.Rect = undefined;
        if (head.as(gtk.Widget).computeBounds(lw, &a) == 0 or tail.as(gtk.Widget).computeBounds(lw, &b) == 0) return false;
        g.top = a.f_origin.f_y;
        g.rows_end = b.f_origin.f_y + b.f_size.f_height;
    }
    // Each group runs to the top of the next; the last is given the same space under it.
    var gap: f64 = 0;
    for (groups[0 .. groups.len - 1], groups[1..]) |*g, next| {
        g.height = next.top - g.top;
        gap = next.top - g.rows_end;
    }
    const last = &groups[groups.len - 1];
    last.height = last.rows_end - last.top + gap;
    return true;
}

/// A picture of the group's rows as they look now, on a raised card.
fn makeGhost(list: *gtk.ListBox, layer: *gtk.Fixed, g: Group) ?*gtk.Widget {
    const lw = list.as(gtk.Widget);
    const inner = gtk.Fixed.new();
    var left: f64 = std.math.inf(f64);
    var right: f64 = 0;
    // The card stays inside the layer, which is as wide as the list's view: rows that reach
    // its edge leave the card no room beyond them on that side.
    var room: f64 = pad;
    for (g.first..g.first + g.count) |i| {
        const row = list.getRowAtIndex(@intCast(i)) orelse return null;
        var b: graphene.Rect = undefined;
        if (row.as(gtk.Widget).computeBounds(lw, &b) == 0) return null;
        left = @min(left, b.f_origin.f_x);
        right = @max(right, b.f_origin.f_x + b.f_size.f_width);
        var in_layer: graphene.Rect = undefined;
        if (row.as(gtk.Widget).computeBounds(layer.as(gtk.Widget), &in_layer) != 0) {
            const width: f64 = @floatFromInt(layer.as(gtk.Widget).getWidth());
            room = std.math.clamp(width - (in_layer.f_origin.f_x + in_layer.f_size.f_width), 0, room);
        }
    }
    for (g.first..g.first + g.count) |i| {
        const row = list.getRowAtIndex(@intCast(i)) orelse continue;
        var b: graphene.Rect = undefined;
        _ = row.as(gtk.Widget).computeBounds(lw, &b);
        const live = gtk.WidgetPaintable.new(row.as(gtk.Widget));
        defer live.unref();
        const still = live.as(gdk.Paintable).getCurrentImage();
        defer still.unref();
        const picture = gtk.Picture.newForPaintable(still);
        picture.setCanShrink(0);
        picture.as(gtk.Widget).setSizeRequest(@intFromFloat(@ceil(b.f_size.f_width)), @intFromFloat(@ceil(b.f_size.f_height)));
        inner.put(picture.as(gtk.Widget), @floatCast(pad + b.f_origin.f_x - left), @floatCast(pad + b.f_origin.f_y - g.top));
    }
    const w = inner.as(gtk.Widget);
    w.addCssClass("session-ghost");
    w.setCanTarget(0);
    w.setSizeRequest(@intFromFloat(@ceil(right - left + pad + room)), @intFromFloat(@ceil(g.rows_end - g.top + 2 * pad)));
    return w;
}

fn ghostX(list: *gtk.ListBox, layer: *gtk.Fixed, g: Group) f64 {
    const row = list.getRowAtIndex(@intCast(g.first)) orelse return 0;
    var b: graphene.Rect = undefined;
    if (row.as(gtk.Widget).computeBounds(layer.as(gtk.Widget), &b) == 0) return 0;
    return b.f_origin.f_x - pad;
}

fn toLayer(list: *gtk.ListBox, layer: *gtk.Fixed, y: f64) f64 {
    var p: graphene.Point = undefined;
    if (list.as(gtk.Widget).computePoint(layer.as(gtk.Widget), &.{ .f_x = 0, .f_y = @floatCast(y) }, &p) == 0) return y;
    return p.f_y;
}

fn toList(list: *gtk.ListBox, layer: *gtk.Fixed, y: f64) f64 {
    var p: graphene.Point = undefined;
    if (layer.as(gtk.Widget).computePoint(list.as(gtk.Widget), &.{ .f_x = 0, .f_y = @floatCast(y) }, &p) == 0) return y;
    return p.f_y;
}

/// Puts the picture under the pointer, kept within the groups it may change places with, and
/// slides the others for where it would land.
fn place(r: *Reorder) void {
    const first = r.groups[0];
    const last = r.groups[r.groups.len - 1];
    const h = r.groups[r.dragged].height;
    const wanted = toList(r.list, r.layer, r.pointer - r.grab);
    r.at = std.math.clamp(wanted, first.top, @max(first.top, last.top + last.height - h));
    moveGhost(r);
    var tops: [64]f64 = undefined;
    var heights: [64]f64 = undefined;
    const n = @min(r.groups.len, tops.len);
    for (r.groups[0..n], 0..) |g, i| {
        tops[i] = g.top;
        heights[i] = g.height;
    }
    const t = targetIndex(tops[0..n], heights[0..n], r.dragged, r.at);
    if (t != r.target) {
        r.target = t;
        shiftRows(r);
    }
}

fn moveGhost(r: *Reorder) void {
    r.layer.move(r.ghost, ghostX(r.list, r.layer, r.groups[r.dragged]), @floatCast(toLayer(r.list, r.layer, r.at) - pad));
}

/// Gives each group the shift that makes room for the dragged one at its target.
fn shiftRows(r: *Reorder) void {
    for (r.groups, 0..) |g, i| {
        const down = i >= r.target and i < r.dragged;
        const up = i > r.dragged and i <= r.target;
        for (g.first..g.first + g.count) |k| {
            const row = (r.list.getRowAtIndex(@intCast(k)) orelse continue).as(gtk.Widget);
            if (down) row.addCssClass("shift-down") else row.removeCssClass("shift-down");
            if (up) row.addCssClass("shift-up") else row.removeCssClass("shift-up");
        }
    }
}

/// The style that slides a row by the dragged group's height, which differs from drag to drag.
fn setShift(height: f64) void {
    const provider = shift_css orelse blk: {
        const p = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault() orelse return, p.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
        shift_css = p;
        break :blk p;
    };
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf,
        \\list > row.shift-up {{ transform: translateY(-{d:.1}px); }}
        \\list > row.shift-down {{ transform: translateY({d:.1}px); }}
    , .{ height, height }, 0) catch return;
    provider.loadFromString(text.ptr);
}

fn onTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
    const r: *Reorder = @ptrCast(@alignCast(data.?));
    const now = clock.getFrameTime();
    const dt: f64 = if (r.last_us == 0) 1.0 / 60.0 else @min(0.05, @as(f64, @floatFromInt(now - r.last_us)) / 1e6);
    r.last_us = now;
    switch (r.state) {
        .dragging => {
            // Held near the top or bottom of the view, the list scrolls, faster the nearer.
            const view: f64 = @floatFromInt(r.layer.as(gtk.Widget).getHeight());
            const adj = r.scroller.getVadjustment();
            const max = adj.getUpper() - adj.getPageSize();
            var speed: f64 = 0;
            if (r.pointer < edge) speed = -(edge - r.pointer) else if (r.pointer > view - edge) speed = r.pointer - (view - edge);
            if (speed != 0 and max > 0) {
                const value = std.math.clamp(adj.getValue() + std.math.clamp(speed, -edge, edge) * 14 * dt, 0, max);
                if (value != adj.getValue()) {
                    adj.setValue(value);
                    place(r);
                }
            }
        },
        .settling => {
            if (r.settle_began == 0) r.settle_began = now;
            const p = std.math.clamp(@as(f64, @floatFromInt(now - r.settle_began)) / @as(f64, @floatFromInt(settle_us)), 0, 1);
            var tops: [64]f64 = undefined;
            var heights: [64]f64 = undefined;
            const n = @min(r.groups.len, tops.len);
            for (r.groups[0..n], 0..) |g, i| {
                tops[i] = g.top;
                heights[i] = g.height;
            }
            const to = slotTop(tops[0..n], heights[0..n], r.dragged, r.target);
            // Fast at first, easing into place.
            const eased = 1 - std.math.pow(f64, 1 - p, 3);
            r.at = r.settle_from + (to - r.settle_from) * eased;
            moveGhost(r);
            if (p >= 1) landed(r);
        },
        .waiting => {},
    }
    return 1;
}

/// The picture is in the gap. Dropped where it started, that is all; otherwise the caller
/// moves the group for real, and the picture stays until the list comes back in that order.
fn landed(r: *Reorder) void {
    if (r.target == r.dragged) return finish(r);
    r.state = .waiting;
    r.wait = glib.timeoutAdd(wait_ms, &onWait, r);
    r.done.f(r.done.ctx, r.dragged, r.target);
}

fn onWait(data: ?*anyopaque) callconv(.c) c_int {
    const r: *Reorder = @ptrCast(@alignCast(data.?));
    r.wait = 0;
    // The order never changed: the rows go back where they were.
    if (active == r) finish(r);
    return 0;
}

fn finish(r: *Reorder) void {
    active = null;
    if (r.wait != 0) _ = glib.Source.remove(r.wait);
    if (r.tick != 0) r.layer.as(gtk.Widget).removeTickCallback(r.tick);
    const lw = r.list.as(gtk.Widget);
    // Rows that were slid aside and stay (a drag given up, a move refused) slide home. After
    // a move that went through, the list has been built again and has none of these.
    var child = lw.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) {
        c.removeCssClass("shift-up");
        c.removeCssClass("shift-down");
        c.removeCssClass("drag-source");
    }
    lw.removeCssClass("reordering");
    lw.setCursor(null);
    r.layer.remove(r.ghost);
    gpa.free(r.groups);
    gpa.destroy(r);
}

test "a dragged group changes places once it covers a neighbour's middle" {
    // Three groups, 40, 100 and 60 tall, one after another.
    const tops = [_]f64{ 0, 40, 140 };
    const heights = [_]f64{ 40, 100, 60 };
    // The first, dragged down: it stays until its bottom passes the middle of the second.
    try std.testing.expectEqual(@as(usize, 0), targetIndex(&tops, &heights, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), targetIndex(&tops, &heights, 0, 49));
    try std.testing.expectEqual(@as(usize, 1), targetIndex(&tops, &heights, 0, 51));
    try std.testing.expectEqual(@as(usize, 2), targetIndex(&tops, &heights, 0, 131));
    // The last, dragged up: its top has to pass a group's middle.
    try std.testing.expectEqual(@as(usize, 2), targetIndex(&tops, &heights, 2, 95));
    try std.testing.expectEqual(@as(usize, 1), targetIndex(&tops, &heights, 2, 85));
    try std.testing.expectEqual(@as(usize, 0), targetIndex(&tops, &heights, 2, 10));
}

test "a landed group takes the far end of the space its neighbours slid out of" {
    const tops = [_]f64{ 0, 40, 140 };
    const heights = [_]f64{ 40, 100, 60 };
    // The first group to the end: the other two slide up by 40, and it sits under them.
    try std.testing.expectEqual(@as(f64, 160), slotTop(&tops, &heights, 0, 2));
    // The last to the front: it sits where the first was.
    try std.testing.expectEqual(@as(f64, 0), slotTop(&tops, &heights, 2, 0));
    try std.testing.expectEqual(@as(f64, 40), slotTop(&tops, &heights, 1, 1));
}

//! Holds the sidebar so that, while the window has no background, it comes out from under the
//! panes.
//!
//! The split view slides its sidebar in from the window's edge. Without a background nothing
//! of the window shows there, so the sidebar would arrive out of thin air. Held here it starts
//! tucked under the panes instead, and slides out from beneath their edge as they make room:
//! the place the split view gives the sidebar ends where the panes begin, whatever is outside
//! that place is cut off, and the sidebar is moved inside it.
const gtk = @import("gtk");
const gsk = @import("gsk");
const graphene = @import("graphene");

/// Whether the sidebar comes out from under the panes: while the window has no background.
pub var from_under: bool = false;
/// The split view the sidebar slides in.
pub var within: ?*gtk.Widget = null;

/// How far under the panes the sidebar starts, as a share of its width, beyond staying where
/// it will end up. It crosses that way while the panes move off it, so it is seen to slide.
const tuck: f32 = 0.2;

pub fn new(child: *gtk.Widget) *gtk.Widget {
    const box = gtk.Box.new(.horizontal, 0);
    const w = box.as(gtk.Widget);
    w.setLayoutManager(gtk.CustomLayout.new(null, &measure, &allocate).as(gtk.LayoutManager));
    box.append(child);
    return w;
}

fn measure(w: *gtk.Widget, orientation: gtk.Orientation, for_size: c_int, min: *c_int, nat: *c_int, mb: *c_int, nb: *c_int) callconv(.c) void {
    mb.* = -1;
    nb.* = -1;
    const child = w.getFirstChild() orelse return;
    child.measure(orientation, for_size, min, nat, null, null);
}

fn allocate(w: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const child = w.getFirstChild() orelse return;
    // How far the split view has the sidebar's place hanging out of itself, on either side:
    // all of it when the sidebar is hidden, none when it is shown.
    var shift: f32 = 0;
    if (from_under) if (within) |outer| {
        var at: graphene.Rect = undefined;
        if (w.computeBounds(outer, &at) != 0) {
            const before = -at.f_origin.f_x;
            const after = at.f_origin.f_x + at.f_size.f_width - @as(f32, @floatFromInt(outer.getWidth()));
            if (before > 0) shift = before * (1 + tuck) else if (after > 0) shift = -after * (1 + tuck);
        }
    };
    var t: ?*gsk.Transform = null;
    if (shift != 0) t = gsk.Transform.new().translate(&.{ .f_x = shift, .f_y = 0 });
    child.allocate(width, height, -1, t);
}

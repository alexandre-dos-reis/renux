//! The panes of one Rex window, each a card, laid out the way the server tiles them. Panes keep
//! their terminal views across layout changes, so a split or a resize doesn't reconnect anything.
//!
//! Pointer work happens here too: dragging the gap between cards resizes, dragging a card by its
//! title moves it (an edge of another pane puts it there, the middle swaps the two), and floating
//! cards move by their title and resize by their corner.
//!
//! Cards glide to their new places on a spring when the layout changes, fade in when they appear
//! and fade out when they go.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const graphene = @import("graphene");
const gdk = @import("gdk");
const cairo = @import("cairo");
const gsk = @import("gsk");
const view = @import("../rex/view.zig");
const Server = @import("../rex/server.zig").Server;
const TermView = @import("../terminal/termview.zig").TermView;
const icons = @import("../icons/icons.zig");
const blockicon = @import("../icons/blockicon.zig");
const draw = @import("../util/draw.zig");
const programs = @import("../icons/programs.zig");
const settings = @import("../settings/settings.zig");
const window_bg = @import("window_bg.zig");
const wayland = @import("../platform/wayland.zig");

const gpa = std.heap.c_allocator;

/// Set by the overview: whether one of its previews shows a pane, so the window leaves that
/// pane's terminal alone when it stops showing the pane itself.
pub var previewed: ?*const fn (server: *Server, block_id: []const u8) bool = null;

/// Space between pane cards; Tight packs them edge to edge with one line between.
pub var gap: f64 = 8;
pub var tight = false;
pub var show_headers = true;

/// Where the window's corner (its buttons and the sidebar toggle) ends, in window pixels. A
/// pane title under it starts after it, which is the case while the sidebar is hidden.
pub var corner_right: f64 = 0;

pub fn setTight(on: bool) void {
    tight = on;
    gap = if (on) 1 else 8;
}

const Zone = enum { none, left, right, top, bottom, swap };

const Pane = struct {
    block_id: []u8,
    layer_id: []u8,
    /// The pane's card: its title row above the terminal.
    frame: *gtk.Widget,
    tile: *gtk.Widget,
    term: *TermView,
    grip: *gtk.Widget,
    title_row: *gtk.Widget,
    /// The title row's Float or dock and Minimize buttons, greyed while they can do nothing.
    float_button: ?*gtk.Widget = null,
    find: ?*@import("findbar.zig").FindBar = null,
    /// Back from the tray: the chip's look over the card, fading as the card grows from the
    /// chip's size (`face_w` wide) to its own.
    face: ?*gtk.Widget = null,
    face_w: f64 = 0,
    /// Minimize was just asked for: the card drops its outline at once and keeps it off
    /// until the server answers, or this moment passes if it never does.
    minimizing_until: i64 = 0,
    minimize_button: ?*gtk.Widget = null,
    rect: view.Rect = .{},
    floating: bool = false,
    /// A floating pane's whole layer, in window fractions; its panes move and resize together.
    bounds: view.Rect = .{},
    /// Where the pane was when a drag began.
    drag_start: view.Rect = .{},
    /// One of several panes in a floating layer, drawn joined as one card.
    joined: bool = false,
    /// The program's own background, for frames that match it.
    program_bg: u32 = 0,
    /// The background the card's style class is for now, or none.
    bg_applied: ?u32 = null,
    seen: bool = false,
    /// Where the card is drawn now, in pixels, and how fast that is moving toward `rect`.
    cur: [4]f64 = .{ 0, 0, 0, 0 },
    vel: [4]f64 = .{ 0, 0, 0, 0 },
    alpha: f64 = 0,
    /// Not placed yet: it starts slightly small and clear, then grows in.
    fresh: bool = true,
};

const Backdrop = struct { layer_id: []u8, widget: *gtk.Widget };

/// A card whose pane went away, fading out where it was.
const Leaving = struct {
    frame: *gtk.Widget,
    cur: [4]f64,
    /// The size the card keeps while it fades, so its terminal never asks for a new one.
    size: [2]f64,
    alpha: f64,
    block_id: []u8,
    /// Set for a card going to the tray: the layer whose chip it becomes. The chip stays
    /// unseen until the card has shrunk onto it, so there is only ever one thing on screen.
    to_layer: ?[]u8 = null,
    vel: [4]f64 = .{ 0, 0, 0, 0 },
    /// The chip's look laid over the card, showing through more the smaller the card gets,
    /// so the card already reads as the chip by the time it is chip sized.
    face: ?*gtk.Widget = null,
    /// How wide the card was when it set off.
    from_w: f64 = 0,
};

/// Where a chip was when its layer came back from the tray, for its card to grow out of.
const Restored = struct { layer_id: []u8, rect: [4]f64 };

const Divider = struct {
    horizontal: bool,
    rect: view.Rect,
    ratio: f64,
    before_id: []u8,
    after_id: []u8,
};

/// The edge of the workspace a minimized pane's chip keeps to.
const Edge = enum { bottom, top, left, right };

/// Where a chip was put by hand, kept by its layer for as long as the window runs: its edge,
/// its turn among the chips there, and how far along the edge it stays when it was dropped
/// clear of the others' row (0 when it joined the row).
const Dock = struct { edge: Edge, rank: u32, along: f64 };

/// A chip nobody has moved takes its turn after those somebody has, oldest first.
const unranked = std.math.maxInt(u32);

/// The room chips keep from the workspace's edges and from each other, and how near the
/// place the row has for it a dropped chip must be to join the row.
const chip_pad: f64 = 10;
const chip_gap: f64 = 6;
const chip_snap: f64 = 24;
/// Chips make room for one another as the sidebar's rows do for a session being moved, and a
/// chip let go settles as the session does: the same times and the same curves.
const chip_shift_us: f64 = 220_000;
const chip_settle_us: f64 = 170_000;

const Minimized = struct {
    layer_id: []u8,
    block_id: []u8,
    button: *gtk.Widget,
    label: *gtk.Label,
    edge: Edge = .bottom,
    rank: u32 = unranked,
    along: f64 = 0,
    size: [2]f64 = .{ 0, 0 },
    /// Where it is drawn, and where it belongs. Between the two it is on its way from `from`
    /// since `began`, making room for another chip or settling after being let go.
    cur: [2]f64 = .{ 0, 0 },
    to: [2]f64 = .{ 0, 0 },
    from: [2]f64 = .{ 0, 0 },
    began: i64 = 0,
    settling: bool = false,
    placed: bool = false,
};

/// A chip taken hold of: where on it, whether it has moved far enough to be carried and not
/// clicked, and, worked out at each layout, the edge it would keep to if let go now, its turn
/// there and how far along it would stay.
const ChipDrag = struct {
    button: *gtk.Widget,
    grab: [2]f64,
    carried: bool = false,
    edge: Edge = .bottom,
    along: f64 = 0,
    order: [64]usize = undefined,
    count: usize = 0,
};

pub const Workspace = struct {
    pub fn isTight() bool {
        return tight;
    }

    bg_idle: c_uint = 0,
    /// Set for a small copy of a tab in the overview, to the workspace of the window itself.
    /// A preview takes no keyboard, tells the server no sizes, and leaves alone the terminals
    /// of panes the window still shows.
    preview_of: ?*Workspace = null,
    /// The colors of frames that match their programs, and the text last loaded into it.
    bg_css: ?*gtk.CssProvider = null,
    bg_css_text: std.ArrayList(u8) = .empty,
    root: *gtk.Widget,
    /// While a tiled pane is carried: a small card under the pointer, and where it would land.
    ghost: *gtk.Widget,
    target: *gtk.Widget,
    /// The line shown on a divider under the pointer or being dragged, and which divider.
    line: *gtk.Widget,
    line_at: ?usize = null,
    restored: std.ArrayList(Restored) = .empty,
    keyboard_idle: c_uint = 0,
    swap_arrows: *gtk.Widget,
    target_cur: [4]f64 = .{ 0, 0, 0, 0 },
    target_vel: [4]f64 = .{ 0, 0, 0, 0 },
    empty: *gtk.Widget,
    server: *Server,
    session_id: ?[]u8 = null,
    window_id: ?[]u8 = null,
    focused: ?[]u8 = null,
    panes: std.ArrayList(Pane) = .empty,
    dividers: std.ArrayList(Divider) = .empty,
    minimized: std.ArrayList(Minimized) = .empty,
    /// Where chips were put by hand, by layer.
    docks: std.StringHashMapUnmanaged(Dock) = .empty,
    chip_drag: ?ChipDrag = null,
    /// A carried chip was let go just now: the click that letting go may also count as is
    /// not one. Cleared once that click is over, by `chip_idle`.
    chip_let_go: bool = false,
    chip_idle: c_uint = 0,

    // Dragging.
    resizing: ?usize = null,
    last_resize: i64 = 0,
    moving: ?usize = null,
    move_armed: bool = false,
    move_origin: [2]f64 = .{ 0, 0 },
    pointer: [2]f64 = .{ 0, 0 },
    zone: Zone = .none,
    zone_pane: ?usize = null,
    /// Where a floating layer started, for moving and resizing it.
    float_start: view.Rect = .{},
    /// The ratio under the pointer while a divider is dragged; the panes follow it here at once.
    local_ratio: f64 = 0,
    float_resizing: bool = false,
    /// The card behind each floating layer of several panes, which joins them.
    backdrops: std.ArrayList(Backdrop) = .empty,

    // Animation.
    leaving: std.ArrayList(Leaving) = .empty,
    tick: c_uint = 0,
    last_time: i64 = 0,
    last_size: [2]f64 = .{ 0, 0 },
    /// Put every card straight where it belongs on the next layout, such as for another window.
    snap: bool = false,

    pub fn create(server: *Server) !*Workspace {
        const ws = try gpa.create(Workspace);
        const root = PaneArea.new().as(gtk.Widget);
        root.setHexpand(1);
        root.setVexpand(1);
        root.addCssClass("workspace");
        const layout = gtk.CustomLayout.new(null, &measure, &allocate);
        root.setLayoutManager(layout.as(gtk.LayoutManager));

        // Above the cards while one is carried. They are plain widgets the GPU moves around,
        // so carrying never repaints the whole window.
        const ghost = gtk.Box.new(.horizontal, 0);
        ghost.as(gtk.Widget).addCssClass("carry-ghost");
        ghost.as(gtk.Widget).setCanTarget(0);
        ghost.as(gtk.Widget).setVisible(0);
        // A line between two panes while the pointer is on their divider or dragging it.
        const line = gtk.Box.new(.horizontal, 0);
        line.as(gtk.Widget).addCssClass("divider-line");
        line.as(gtk.Widget).setCanTarget(0);
        const target = gtk.Box.new(.horizontal, 0);
        target.as(gtk.Widget).addCssClass("drop-target");
        target.as(gtk.Widget).setCanTarget(0);
        target.as(gtk.Widget).setVisible(0);
        const arrows = gtk.DrawingArea.new();
        arrows.setContentWidth(40);
        arrows.setContentHeight(28);
        arrows.setDrawFunc(&drawSwap, null, null);
        arrows.as(gtk.Widget).setHexpand(1);
        arrows.as(gtk.Widget).setHalign(.center);
        arrows.as(gtk.Widget).setValign(.center);
        arrows.as(gtk.Widget).setVisible(0);
        target.append(arrows.as(gtk.Widget));

        // The workspace owns these, since it moves them above the cards by re-parenting.
        _ = ghost.as(gobject.Object).refSink();
        _ = target.as(gobject.Object).refSink();
        _ = line.as(gobject.Object).refSink();

        // What a session without windows shows: a way to open one.
        const empty = gtk.Box.new(.vertical, 12);
        const ew = empty.as(gtk.Widget);
        ew.setHalign(.center);
        ew.setValign(.center);
        ew.addCssClass("empty-session");
        const note = gtk.Label.new("No windows in this session");
        note.as(gtk.Widget).addCssClass("dim-label");
        empty.append(note.as(gtk.Widget));
        const open_one = gtk.Button.newWithLabel("New Window");
        open_one.as(gtk.Actionable).setActionName("app.new-window");
        open_one.as(gtk.Widget).addCssClass("pill");
        open_one.as(gtk.Widget).setHalign(.center);
        empty.append(open_one.as(gtk.Widget));
        ew.setVisible(0);
        ew.setParent(root);

        ws.* = .{ .root = root, .ghost = ghost.as(gtk.Widget), .target = target.as(gtk.Widget), .line = line.as(gtk.Widget), .swap_arrows = arrows.as(gtk.Widget), .empty = ew, .server = server };
        gobject.Object.setData(root.as(gobject.Object), "renux-workspace", ws);

        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &dividerBegin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &dividerUpdate, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &dividerEnd, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(drag, *Workspace, &dividerCancel, ws, .{});
        root.addController(drag.as(gtk.EventController));
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Workspace, &hover, ws, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Workspace, &hoverLeft, ws, .{});
        root.addController(motion.as(gtk.EventController));
        return ws;
    }

    /// A preview of one tab, for the overview: see `preview_of`.
    pub fn createPreview(server: *Server, main: *Workspace) !*Workspace {
        const ws = try create(server);
        ws.preview_of = main;
        ws.root.setCanTarget(0);
        return ws;
    }

    /// Shows a window, or nothing when `window` is null.
    pub fn show(ws: *Workspace, session_id: []const u8, window: ?*const view.Window) void {
        const same_session = if (ws.session_id) |s| std.mem.eql(u8, s, session_id) else false;
        if (!same_session) {
            ws.clear();
            replace(&ws.session_id, session_id);
            ws.snap = true;
        }
        ws.empty.setVisible(@intFromBool(window == null));
        const w = window orelse return ws.clear();
        ws.clearDividers();
        if (ws.window_id) |old| {
            if (!std.mem.eql(u8, old, w.id)) ws.snap = true;
        } else ws.snap = true;
        replace(&ws.window_id, w.id);
        if (w.focused_block_id) |f| replace(&ws.focused, f);

        for (ws.panes.items) |*p| p.seen = false;
        // A drag in progress follows its pane by block, since the list can change under it.
        const dragged: ?[*]const u8 = if (ws.moving) |m| (if (m < ws.panes.items.len) ws.panes.items[m].block_id.ptr else null) else null;
        if (w.zoomed_block_id) |z| {
            ws.place(session_id, z, "", .{}, null);
        } else if (w.tiled()) |layer| {
            if (layer.layout) |node| ws.placeNode(session_id, node, layer.id, null);
        }
        // Floating layers sit over the tiles, at their bounds; minimized ones wait in the tray.
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or layer.minimized) continue;
            if (layer.layout) |node| ws.placeNode(session_id, node, layer.id, layer.bounds);
        };
        ws.syncTray(w);

        var i: usize = 0;
        while (i < ws.panes.items.len) {
            if (!ws.panes.items[i].seen) {
                const p = ws.panes.orderedRemove(i);
                if (ws.snap) ws.drop(p) else ws.leave(p);
            } else i += 1;
        }
        // Another window's cards must not fade out over this one.
        if (ws.snap) ws.flushLeaving();
        if (ws.moving != null) {
            ws.moving = null;
            if (dragged) |d| for (ws.panes.items, 0..) |p, k| if (p.block_id.ptr == d) {
                ws.moving = k;
            };
            if (ws.moving == null) {
                // The pane under the pointer is gone, and its carried card with it.
                ws.float_resizing = false;
                ws.move_armed = false;
                ws.zone = .none;
                ws.zone_pane = null;
                ws.showCarry();
            }
        }
        if (ws.zone_pane) |z| if (z >= ws.panes.items.len) {
            ws.zone_pane = null;
            ws.zone = .none;
        };
        ws.restack(w);
        if (ws.resizing != null) ws.followDivider();
        ws.joinLayers();
        ws.markFocus();
        ws.syncKeyboard();
        // A minimize that never happened gives the card its outline back.
        const now = glib.getMonotonicTime();
        for (ws.panes.items) |*p| if (p.minimizing_until != 0 and now > p.minimizing_until and p.face == null) {
            p.minimizing_until = 0;
            p.frame.removeCssClass("to-tray");
        };
        ws.markTools();
        ws.cornerChanged();
        ws.root.queueAllocate();
    }

    /// The top-left pane's title starts after the window's corner while the sidebar is hidden.
    /// The room is worked out as the panes are placed, from where each card is going in this
    /// very frame, so the title never sits under the corner while the sidebar slides.
    pub fn cornerChanged(ws: *Workspace) void {
        ws.root.queueAllocate();
    }

    /// Gives a card's title row the room the corner takes from it. `origin` is where the
    /// workspace sits in the window and `at` where the card is about to be placed in it.
    fn cornerRoom(p: *Pane, origin: [2]f64, at: [4]f64) void {
        const top_left = !p.floating and p.rect.x < 0.001 and p.rect.y < 0.001;
        // The title starts 13 pixels in: the card's border and the title's padding.
        // Only a pane whose title is level with the corner; tabs above push panes down.
        const room: f64 = if (top_left and origin[1] + at[1] < 30) @max(0, corner_right + 6 - (origin[0] + at[0] + 13)) else 0;
        const want: c_int = @intFromFloat(@round(room));
        // The room goes before the title's contents, not before the row: the row's background
        // still runs under the corner, so the window's buttons sit on the pane's own color.
        if (p.tile.getMarginStart() != want) p.tile.setMarginStart(want);
    }

    /// Floating layers draw over every tiled pane, in the server's order, back to front; the
    /// drop target, the carried card and the chips stay above them all. Children only move when
    /// that order isn't already the one on screen, since moving one lays the workspace out again.
    fn restack(ws: *Workspace, w: *const view.Window) void {
        var want: std.ArrayList(*gtk.Widget) = .empty;
        defer want.deinit(gpa);
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or layer.minimized) continue;
            for (ws.panes.items) |p| if (p.floating and std.mem.eql(u8, p.layer_id, layer.id)) want.append(gpa, p.frame) catch {};
        };
        want.appendSlice(gpa, &.{ ws.line, ws.target, ws.ghost }) catch {};
        // A chip being carried is over the other chips.
        const carried: ?*gtk.Widget = if (ws.chip_drag) |d| (if (d.carried) d.button else null) else null;
        for (ws.minimized.items) |m| if (m.button != carried) want.append(gpa, m.button) catch {};
        if (carried) |c| want.append(gpa, c) catch {};
        // Compare with the children at the top, skipping the cards behind joined layers, which
        // `joinLayers` places itself.
        var child = ws.root.getLastChild();
        var k = want.items.len;
        while (k > 0) {
            const c = child orelse break;
            child = c.getPrevSibling();
            if (ws.isBackdrop(c)) continue;
            if (c != want.items[k - 1]) break;
            k -= 1;
        }
        if (k == 0) return;
        for (want.items) |x| {
            if (x.getParent() == null) x.setParent(ws.root) else x.insertBefore(ws.root, null);
        }
    }

    fn isBackdrop(ws: *Workspace, w: *gtk.Widget) bool {
        for (ws.backdrops.items) |bd| if (bd.widget == w) return true;
        return false;
    }

    /// Forgets any drag in progress, such as when the panes under it are gone.
    fn resetDrag(ws: *Workspace) void {
        ws.resizing = null;
        ws.moving = null;
        ws.move_armed = false;
        ws.float_resizing = false;
        ws.zone = .none;
        ws.zone_pane = null;
        ws.ghost.setVisible(0);
        ws.target.setVisible(0);
        ws.swap_arrows.setVisible(0);
        ws.root.setCursorFromName(null);
    }

    fn flushLeaving(ws: *Workspace) void {
        // Emptied first: `gone` asks whether a pane is shown, never whether one is leaving.
        var leaving = ws.leaving;
        ws.leaving = .empty;
        defer leaving.deinit(gpa);
        for (leaving.items) |l| ws.gone(l);
    }

    pub fn clear(ws: *Workspace) void {
        // Drag state points at panes by index, so it goes with them.
        ws.resetDrag();
        for (ws.panes.items) |p| ws.drop(p);
        ws.panes.clearRetainingCapacity();
        ws.flushLeaving();
        for (ws.backdrops.items) |bd| {
            bd.widget.unparent();
            gpa.free(bd.layer_id);
        }
        ws.backdrops.clearRetainingCapacity();
        ws.clearDividers();
        ws.clearTray();
        ws.root.queueAllocate();
    }

    /// Frees the workspace. Call it while `root` is still alive (before it leaves its parent)
    /// and while the server is: dropping the panes releases their terminals.
    pub fn destroy(ws: *Workspace) void {
        ws.clear();
        if (ws.bg_idle != 0) _ = glib.Source.remove(ws.bg_idle);
        if (ws.tick != 0) {
            ws.root.removeTickCallback(ws.tick);
            ticking -|= 1;
        }
        if (ws.bg_css) |pr| {
            if (gdk.Display.getDefault()) |d| gtk.StyleContext.removeProviderForDisplay(d, pr.as(gtk.StyleProvider));
            pr.unref();
        }
        ws.bg_css_text.deinit(gpa);
        // The layout and the gestures on `root` find the workspace through this.
        gobject.Object.setData(ws.root.as(gobject.Object), "renux-workspace", null);
        ws.empty.unparent();
        inline for (.{ ws.ghost, ws.target, ws.line }) |w| {
            if (w.getParent() != null) w.unparent();
            w.as(gobject.Object).unref();
        }
        ws.clearTray();
        if (ws.chip_idle != 0) _ = glib.Source.remove(ws.chip_idle);
        var docks = ws.docks.keyIterator();
        while (docks.next()) |key| gpa.free(key.*);
        ws.docks.deinit(gpa);
        // The gestures on `root` hold this pointer; without their widget they never fire again.
        ws.root.setCanTarget(0);
        ws.panes.deinit(gpa);
        ws.dividers.deinit(gpa);
        ws.minimized.deinit(gpa);
        ws.backdrops.deinit(gpa);
        ws.leaving.deinit(gpa);
        for (ws.restored.items) |r| gpa.free(r.layer_id);
        ws.restored.deinit(gpa);
        if (ws.keyboard_idle != 0) _ = glib.Source.remove(ws.keyboard_idle);
        inline for (.{ ws.session_id, ws.window_id, ws.focused }) |slot| if (slot) |v| gpa.free(v);
        gpa.destroy(ws);
    }

    fn clearDividers(ws: *Workspace) void {
        if (ws.resizing != null) return; // keep them while one is being dragged
        for (ws.dividers.items) |d| {
            gpa.free(d.before_id);
            gpa.free(d.after_id);
        }
        ws.dividers.clearRetainingCapacity();
    }

    fn clearTray(ws: *Workspace) void {
        ws.chip_drag = null;
        for (ws.minimized.items) |m| {
            m.button.unparent();
            gpa.free(m.layer_id);
            gpa.free(m.block_id);
        }
        ws.minimized.clearRetainingCapacity();
    }

    /// Shows a chip for each minimized layer. Chips that are already right stay as they are,
    /// keeping their hover and their place; only a change to the set rebuilds them, and the
    /// ones that stay then glide from where they were to where they belong now.
    fn syncTray(ws: *Workspace, w: *const view.Window) void {
        var same = true;
        var n: usize = 0;
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or !layer.minimized or layer.blocks.len == 0) continue;
            if (n >= ws.minimized.items.len or !std.mem.eql(u8, ws.minimized.items[n].layer_id, layer.id) or !std.mem.eql(u8, ws.minimized.items[n].block_id, layer.blocks[0].id)) same = false;
            n += 1;
        };
        if (same and n == ws.minimized.items.len) {
            for (ws.minimized.items) |m| ws.refreshChip(m);
            return;
        }
        ws.noteRestored(w);
        // Where each chip was, by its layer, for the chip made in its stead.
        const Was = struct { layer: u64, cur: [2]f64, to: [2]f64 };
        var was: [64]Was = undefined;
        var kept: usize = 0;
        for (ws.minimized.items) |m| if (m.placed and kept < was.len) {
            was[kept] = .{ .layer = std.hash.Wyhash.hash(0, m.layer_id), .cur = m.cur, .to = m.to };
            kept += 1;
        };
        ws.clearTray();
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (layer.floating and layer.minimized and layer.blocks.len > 0) ws.addToTray(layer.id, layer.blocks[0].id);
        };
        for (ws.minimized.items) |*m| {
            const layer = std.hash.Wyhash.hash(0, m.layer_id);
            for (was[0..kept]) |old| if (old.layer == layer) {
                m.cur = old.cur;
                m.to = old.to;
                m.placed = true;
            };
        }
    }

    /// Where a layer's chip belongs, or where the next chip will go if the layer has none yet:
    /// after the last on the bottom edge.
    fn chipRect(ws: *Workspace, layer_id: []const u8) [4]f64 {
        for (ws.minimized.items) |*m| if (std.mem.eql(u8, m.layer_id, layer_id)) {
            if (!m.placed) ws.placeChips(ws.width(), ws.height());
            return .{ m.to[0], m.to[1], m.size[0], m.size[1] };
        };
        var x = chip_pad;
        for (ws.minimized.items) |m| if (m.edge == .bottom and m.placed) {
            x = @max(x, m.to[0] + m.size[0] + chip_gap);
        };
        return .{ x, ws.height() - 42, 120, 32 };
    }

    // Chips keep to the workspace's edges. One nobody has moved is on the bottom edge, in the
    // row that starts at its left end, as all of them were before they could be moved. A chip
    // can be carried anywhere and let go: it then keeps to the nearest edge, where it was let
    // go, and the chips already there make room for it.

    fn chipIndex(ws: *Workspace, button: *gtk.Widget) ?usize {
        for (ws.minimized.items, 0..) |m, i| if (m.button == button) return i;
        return null;
    }

    /// The chip being carried, if one is.
    fn carriedChip(ws: *Workspace) ?usize {
        const d = ws.chip_drag orelse return null;
        return if (d.carried) ws.chipIndex(d.button) else null;
    }

    /// Works out where every chip belongs and sets it on its way there.
    fn placeChips(ws: *Workspace, w: f64, h: f64) void {
        if (ws.minimized.items.len == 0) return;
        const carried = ws.carriedChip();
        var min: c_int = 0;
        var nat: c_int = 0;
        // How tall the rows along the bottom and the top are.
        var rows = [2]f64{ 0, 0 };
        for (ws.minimized.items, 0..) |*m, i| {
            m.button.measure(.horizontal, -1, &min, &nat, null, null);
            m.size[0] = @max(1, @min(@as(f64, @floatFromInt(nat)), w - 2 * chip_pad));
            m.button.measure(.vertical, -1, &min, &nat, null, null);
            m.size[1] = @floatFromInt(nat);
            switch (if (carried == i) ws.chip_drag.?.edge else m.edge) {
                .bottom => rows[0] = @max(rows[0], m.size[1]),
                .top => rows[1] = @max(rows[1], m.size[1]),
                else => {},
            }
        }
        // The rows along the bottom and the top have the corners; the columns down the sides
        // run between them.
        const lo = chip_pad + (if (rows[1] > 0) rows[1] + chip_gap else 0);
        const hi = h - chip_pad - (if (rows[0] > 0) rows[0] + chip_gap else 0);
        inline for (.{ Edge.bottom, Edge.top, Edge.left, Edge.right }) |edge| ws.packEdge(edge, carried, w, h, lo, hi);
    }

    /// Places the chips of one edge: each as far along as it was put, or right after the one
    /// before it when that is further, and pushed back from the far end when they run past it.
    fn packEdge(ws: *Workspace, edge: Edge, carried: ?usize, w: f64, h: f64, lo: f64, hi: f64) void {
        const items = ws.minimized.items;
        const axis: usize = if (edge == .bottom or edge == .top) 0 else 1;
        const start = if (axis == 0) chip_pad else lo;
        const end = if (axis == 0) w - chip_pad else hi;
        var order: [64]usize = undefined;
        var n: usize = 0;
        // In turn: by rank, and for chips of one rank in the order the server has them.
        for (items, 0..) |m, i| {
            if (carried == i or m.edge != edge or n == order.len) continue;
            var k = n;
            while (k > 0 and items[order[k - 1]].rank > m.rank) : (k -= 1) order[k] = order[k - 1];
            order[k] = i;
            n += 1;
        }
        if (carried) |c| if (ws.chip_drag.?.edge == edge and n < order.len) {
            // The carried chip takes its turn where it is held: after every chip whose middle
            // its own middle has passed, as a session being moved in the sidebar does.
            const d = &ws.chip_drag.?;
            const m = &items[c];
            const mid = m.cur[axis] + m.size[axis] / 2;
            var at = start;
            // Where the row that starts at the edge's near end has got to.
            var row = start;
            var index: usize = 0;
            for (order[0..n]) |i| {
                const o = &items[i];
                const pos = @max(at, o.along);
                if (mid < pos + o.size[axis] / 2) break;
                at = pos + o.size[axis] + chip_gap;
                if (o.along == 0) row = at;
                index += 1;
            }
            // Held before the place the chips ahead of it leave for it, or only a little past
            // it, it joins them: in the row from the near end it stays part of the row, and
            // beside a chip put further along it stays beside that chip. Held clear of them,
            // it keeps the place it is held at.
            const near = m.cur[axis] - at <= chip_snap;
            d.along = if (!near) @min(m.cur[axis], end - m.size[axis]) else if (@abs(at - row) < 0.5) 0 else at;
            var k = n;
            while (k > index) : (k -= 1) order[k] = order[k - 1];
            order[index] = c;
            n += 1;
            d.order = order;
            d.count = n;
        };
        if (n == 0) return;
        var pos: [64]f64 = undefined;
        var at = start;
        for (order[0..n], 0..) |i, k| {
            const along = if (carried == i) ws.chip_drag.?.along else items[i].along;
            pos[k] = @max(at, along);
            at = pos[k] + items[i].size[axis] + chip_gap;
        }
        var limit = end;
        var k = n;
        while (k > 0) {
            k -= 1;
            pos[k] = @max(start, @min(pos[k], limit - items[order[k]].size[axis]));
            limit = pos[k] - chip_gap;
        }
        for (order[0..n], 0..) |i, at_k| {
            const m = &items[i];
            const to: [2]f64 = switch (edge) {
                .bottom => .{ pos[at_k], h - chip_pad - m.size[1] },
                .top => .{ pos[at_k], chip_pad },
                .left => .{ chip_pad, pos[at_k] },
                .right => .{ w - chip_pad - m.size[0], pos[at_k] },
            };
            // A chip seen for the first time, or shown for another window, is put straight
            // where it belongs.
            if (!m.placed or ws.snap) {
                m.placed = true;
                m.to = to;
                if (carried != i) {
                    m.cur = to;
                    m.began = 0;
                }
                continue;
            }
            if (@abs(to[0] - m.to[0]) < 0.5 and @abs(to[1] - m.to[1]) < 0.5) continue;
            m.to = to;
            // The carried chip is where the pointer has it; this is where it goes when let go.
            if (carried == i) continue;
            m.from = m.cur;
            m.began = glib.getMonotonicTime();
            m.settling = false;
        }
    }

    /// Moves each chip that is on its way a frame further. True while any still is.
    fn moveChips(ws: *Workspace, now: i64) bool {
        var moving = false;
        for (ws.minimized.items) |*m| {
            if (m.began == 0) continue;
            const took = if (m.settling) chip_settle_us else chip_shift_us;
            const p = std.math.clamp(@as(f64, @floatFromInt(now - m.began)) / took, 0, 1);
            // Settling is fast at first and eases into place, as a session let go in the
            // sidebar is; making room follows the curve the sidebar's rows do.
            const e = if (m.settling) 1 - std.math.pow(f64, 1 - p, 3) else bezier(0.2, 0.9, 0.3, 1, p);
            m.cur = .{ m.from[0] + (m.to[0] - m.from[0]) * e, m.from[1] + (m.to[1] - m.from[1]) * e };
            if (p >= 1) {
                m.cur = m.to;
                m.began = 0;
            } else moving = true;
        }
        return moving;
    }

    /// The chip that was only pressed is now being carried: it is lifted over the others.
    fn liftChip(ws: *Workspace) void {
        const d = &(ws.chip_drag orelse return);
        d.carried = true;
        if (ws.chipIndex(d.button)) |i| d.edge = ws.minimized.items[i].edge;
        d.button.addCssClass("carried");
        d.button.insertBefore(ws.root, null);
    }

    /// Carries the chip so the point of it that was taken hold of is at a point of the
    /// workspace.
    fn carryChip(ws: *Workspace, x: f64, y: f64) void {
        const d = &(ws.chip_drag orelse return);
        const i = ws.chipIndex(d.button) orelse return;
        const m = &ws.minimized.items[i];
        const w = ws.width();
        const h = ws.height();
        m.cur = .{ std.math.clamp(x - d.grab[0], 0, @max(0, w - m.size[0])), std.math.clamp(y - d.grab[1], 0, @max(0, h - m.size[1])) };
        m.began = 0;
        // It will keep to the edge its middle is nearest. The edge it is headed for holds on
        // a little, so the chips there don't jump back and forth near a corner.
        const mid = [2]f64{ m.cur[0] + m.size[0] / 2, m.cur[1] + m.size[1] / 2 };
        var far = [4]f64{ h - mid[1], mid[1], mid[0], w - mid[0] };
        far[@backingInt(d.edge)] -= 12;
        var best: usize = 0;
        for (far, 0..) |f, k| if (f < far[best]) {
            best = k;
        };
        d.edge = @fromBackingInt(@intCast(best));
        ws.root.queueAllocate();
    }

    /// Lets the carried chip go: it keeps to the edge it is nearest, where it is, takes its
    /// turn among the chips there, and settles into its place.
    fn dropChip(ws: *Workspace) void {
        const held = ws.chip_drag orelse return;
        if (!held.carried) {
            ws.chip_drag = null;
            return;
        }
        ws.placeChips(ws.width(), ws.height());
        const d = ws.chip_drag.?;
        ws.chip_drag = null;
        d.button.removeCssClass("carried");
        // Letting go may still count as a click on the chip, which would bring its pane
        // back: that click is passed over.
        ws.chip_let_go = true;
        if (ws.chip_idle == 0) ws.chip_idle = glib.idleAdd(&chipLetGoOver, ws);
        const i = ws.chipIndex(d.button) orelse return;
        const m = &ws.minimized.items[i];
        m.edge = d.edge;
        m.along = d.along;
        // Every chip on that edge now has its turn, and keeps it.
        for (d.order[0..d.count], 0..) |at, turn| {
            if (at >= ws.minimized.items.len) continue;
            ws.minimized.items[at].rank = @intCast(turn);
            ws.remember(&ws.minimized.items[at]);
        }
        m.from = m.cur;
        m.began = glib.getMonotonicTime();
        m.settling = true;
        ws.root.queueAllocate();
        ws.startTick();
    }

    /// Keeps where a chip was put, for when its chip is made again.
    fn remember(ws: *Workspace, m: *const Minimized) void {
        const home = ws.preview_of orelse ws;
        const dock: Dock = .{ .edge = m.edge, .rank = m.rank, .along = m.along };
        if (home.docks.getPtr(m.layer_id)) |slot| {
            slot.* = dock;
            return;
        }
        const key = gpa.dupe(u8, m.layer_id) catch return;
        home.docks.put(gpa, key, dock) catch gpa.free(key);
    }

    fn chipLetGoOver(data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        ws.chip_idle = 0;
        ws.chip_let_go = false;
        return 0;
    }

    /// A click on a chip brings its pane back.
    fn chipClicked(button: *gtk.Button, ws: *Workspace) callconv(.c) void {
        if (ws.chip_let_go) return;
        const i = ws.chipIndex(button.as(gtk.Widget)) orelse return;
        const app = gio.Application.getDefault() orelse return;
        const layer = gpa.dupeSentinel(u8, ws.minimized.items[i].layer_id, 0) catch return;
        defer gpa.free(layer);
        app.as(gio.ActionGroup).activateAction("restore-layer", glib.Variant.newString(layer.ptr));
    }

    const ChipGesture = struct {
        fn begin(g: *gtk.GestureDrag, x: f64, y: f64, ws: *Workspace) callconv(.c) void {
            const button = g.as(gtk.EventController).getWidget() orelse return;
            ws.chip_drag = .{ .button = button, .grab = .{ x, y } };
        }
        fn update(g: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
            const d = &(ws.chip_drag orelse return);
            if (!d.carried) {
                // A press that barely moves is a click, which brings the pane back.
                if (@abs(dx) < 6 and @abs(dy) < 6) return;
                _ = g.as(gtk.Gesture).setState(.claimed);
                ws.liftChip();
            }
            // The chip moves with the pointer, so the pointer's place is taken in the
            // workspace, which stays put; see `steadyOffset`.
            var sx: f64 = 0;
            var sy: f64 = 0;
            if (g.getStartPoint(&sx, &sy) == 0) return;
            var px: f64 = 0;
            var py: f64 = 0;
            if (d.button.translateCoordinates(ws.root, sx + dx, sy + dy, &px, &py) == 0) return;
            ws.carryChip(px, py);
        }
        fn end(_: *gtk.GestureDrag, _: f64, _: f64, ws: *Workspace) callconv(.c) void {
            ws.dropChip();
        }
        fn cancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, ws: *Workspace) callconv(.c) void {
            ws.dropChip();
        }
    };

    /// Development: takes hold of the nth chip by its middle and carries it to a point of the
    /// workspace, carries it on, and lets it go, as the pointer would.
    pub fn simulateChipCarry(ws: *Workspace, n: usize, x: f64, y: f64) void {
        if (n >= ws.minimized.items.len) return;
        const m = ws.minimized.items[n];
        ws.chip_drag = .{ .button = m.button, .grab = .{ m.size[0] / 2, m.size[1] / 2 } };
        ws.liftChip();
        ws.carryChip(x, y);
    }

    pub fn simulateChipMove(ws: *Workspace, x: f64, y: f64) void {
        ws.carryChip(x, y);
    }

    pub fn simulateChipDrop(ws: *Workspace) void {
        ws.dropChip();
    }

    /// Development: logs where each chip is and where it belongs.
    pub fn chipReport(ws: *Workspace) void {
        for (ws.minimized.items, 0..) |m, i| std.log.info("chip {d}: edge {s} rank {d} along {d:.1} at {d:.1},{d:.1} going to {d:.1},{d:.1}", .{ i, @tagName(m.edge), m.rank, m.along, m.cur[0], m.cur[1], m.to[0], m.to[1] });
    }

    /// Notes where the chips are that the window no longer has, so the cards coming back
    /// from them can grow out of those places.
    fn noteRestored(ws: *Workspace, w: *const view.Window) void {
        for (ws.restored.items) |r| gpa.free(r.layer_id);
        ws.restored.clearRetainingCapacity();
        for (ws.minimized.items) |m| {
            const still = for (w.layers) |layer| {
                if (layer.minimized and std.mem.eql(u8, layer.id, m.layer_id)) break true;
            } else false;
            if (still) continue;
            const id = gpa.dupe(u8, m.layer_id) catch continue;
            ws.restored.append(gpa, .{ .layer_id = id, .rect = ws.chipSpot(m.layer_id) }) catch gpa.free(id);
        }
    }

    /// The pane is about to go to the tray: its outline and highlight go the moment it is
    /// asked, without waiting for the server to say the layer is minimized.
    pub fn startMinimize(ws: *Workspace, block_id: []const u8) void {
        const p = ws.paneOf(block_id) orelse return;
        p.minimizing_until = glib.getMonotonicTime() + 1_500_000;
        p.frame.addCssClass("to-tray");
        // The card behind a layer of several panes carries the same highlight.
        for (ws.backdrops.items) |bd| if (std.mem.eql(u8, bd.layer_id, p.layer_id)) bd.widget.addCssClass("to-tray");
    }

    /// A chip's look to lay over a card. It is built exactly as the chip in the tray is, a
    /// button with the same parts and style, so nothing shifts or changes weight at the
    /// moment the real chip takes over.
    fn chipFace(ws: *Workspace, block_id: []const u8, opacity: f64) *gtk.Widget {
        const button = gtk.Button.new();
        const w = button.as(gtk.Widget);
        const line = gtk.Box.new(.horizontal, 6);
        line.append(blockicon.create(ws.server, block_id, 14));
        var buf: [256]u8 = undefined;
        const label = gtk.Label.new(chipTitle(ws.server, block_id, &buf).ptr);
        label.setEllipsize(.middle);
        label.setMaxWidthChars(32);
        line.append(label.as(gtk.Widget));
        button.setChild(line.as(gtk.Widget));
        w.addCssClass("tray-chip");
        w.addCssClass("chip-face");
        w.setCanTarget(0);
        w.setFocusable(0);
        w.setOpacity(opacity);
        return w;
    }

    /// Where a card on its way to or from the tray lines up with a chip: the chip's place,
    /// a pixel wider all round for the card's own (unseen) border, so the chip's look on
    /// the card sits exactly where the chip does.
    fn chipSpot(ws: *Workspace, layer_id: []const u8) [4]f64 {
        const r = ws.chipRect(layer_id);
        return .{ r[0] - 1, r[1] - 1, r[2] + 2, r[3] + 2 };
    }

    /// A card has become its chip: the chip shows from here on.
    fn showChip(ws: *Workspace, layer_id: []const u8) void {
        for (ws.minimized.items) |m| if (std.mem.eql(u8, m.layer_id, layer_id)) m.button.setOpacity(1);
    }

    fn refreshChip(ws: *Workspace, m: Minimized) void {
        var buf: [256]u8 = undefined;
        const title = chipTitle(ws.server, m.block_id, &buf);
        if (!std.mem.eql(u8, std.mem.span(m.label.getText()), title)) m.label.setText(title.ptr);
    }

    /// Lets a card fade out where it was before it goes.
    fn leave(ws: *Workspace, p: Pane) void {
        p.frame.setCanTarget(0);
        defer gpa.free(p.layer_id);
        // The terminal stays until the card has faded, so it fades with its text.
        const r = ws.paneRect(&p);
        // A pane whose layer just went to the tray shrinks into its chip there.
        var to_layer: ?[]u8 = null;
        for (ws.minimized.items) |m| if (std.mem.eql(u8, m.layer_id, p.layer_id)) {
            to_layer = gpa.dupe(u8, m.layer_id) catch null;
            if (to_layer != null) m.button.setOpacity(0);
        };
        if (to_layer != null) {
            p.term.freeze();
            // The title's buttons go, so the shrinking card shows its icon and name as the
            // chip it is turning into does.
            if (p.float_button) |b| if (b.getParent()) |tools| tools.setVisible(0);
        }
        var face: ?*gtk.Widget = p.face;
        if (to_layer != null and face == null) {
            face = ws.chipFace(p.block_id, 0);
            @as(*gtk.Overlay, @ptrCast(p.frame)).addOverlay(face.?);
            p.frame.addCssClass("to-tray");
        }
        ws.leaving.append(gpa, .{ .frame = p.frame, .cur = p.cur, .size = .{ @round(r[2]), @round(r[3]) }, .alpha = p.alpha, .block_id = p.block_id, .to_layer = to_layer, .face = face, .from_w = p.cur[2] }) catch {
            if (to_layer) |t| gpa.free(t);
            p.frame.unparent();
            if (!ws.stillShown(p.block_id)) ws.server.parkTerminal(p.block_id);
            gpa.free(p.block_id);
            return;
        };
        ws.startTick();
    }

    /// A faded card goes for good, and its terminal too unless the pane came back meanwhile.
    fn gone(ws: *Workspace, l: Leaving) void {
        if (l.to_layer) |t| {
            // However the card went, its chip must not stay hidden.
            ws.showChip(t);
            gpa.free(t);
        }
        l.frame.unparent();
        if (ws.paneOf(l.block_id) == null and !ws.stillShown(l.block_id)) ws.server.parkTerminal(l.block_id);
        gpa.free(l.block_id);
    }

    /// Whether a pane leaving this workspace is still on screen elsewhere, in the window itself
    /// or in a preview of it, which then goes on using its terminal.
    fn stillShown(ws: *Workspace, block_id: []const u8) bool {
        if (ws.preview_of) |main| return main.isShown(block_id);
        return if (previewed) |shows| shows(ws.server, block_id) else false;
    }

    fn drop(ws: *Workspace, p: Pane) void {
        p.frame.unparent();
        if (!ws.stillShown(p.block_id)) ws.server.parkTerminal(p.block_id);
        gpa.free(p.block_id);
        gpa.free(p.layer_id);
    }

    /// Places a layer's panes; `bounds` is set for a floating layer.
    fn placeNode(ws: *Workspace, session_id: []const u8, node: *const view.Node, layer_id: []const u8, bounds: ?view.Rect) void {
        switch (node.*) {
            // Leaf rectangles are already in window fractions, floating layers included.
            .leaf => |l| ws.place(session_id, l.block_id, layer_id, l.rect, bounds),
            .split => |s| {
                if (bounds == null and ws.resizing == null) ws.dividers.append(gpa, .{
                    .horizontal = s.horizontal,
                    .rect = s.rect,
                    .ratio = s.ratio,
                    .before_id = gpa.dupe(u8, firstLeaf(s.before)) catch return,
                    .after_id = gpa.dupe(u8, firstLeaf(s.after)) catch return,
                }) catch {};
                ws.placeNode(session_id, s.before, layer_id, bounds);
                ws.placeNode(session_id, s.after, layer_id, bounds);
            },
        }
    }

    fn place(ws: *Workspace, session_id: []const u8, block_id: []const u8, layer_id: []const u8, rect: view.Rect, bounds: ?view.Rect) void {
        const floating = bounds != null;
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) {
            // A floating layer being dragged here keeps its place until the server hears the drop.
            if (ws.draggingLayer(p.layer_id)) {
                p.seen = true;
                return;
            }
            p.rect = rect;
            p.bounds = bounds orelse .{};
            p.seen = true;
            replace2(&p.layer_id, layer_id);
            if (p.floating != floating) {
                p.floating = floating;
                if (floating) p.frame.addCssClass("floating") else p.frame.removeCssClass("floating");
                p.term.floating = floating;
                p.term.widget().queueDraw();
                p.grip.setVisible(@intFromBool(floating));
            }
            return;
        };
        const tv = TermView.create(ws.server, session_id, block_id) catch return;
        // A preview is drawn small; its size is no size for the program to hear about.
        if (ws.preview_of != null) tv.freeze();
        tv.floating = floating;
        tv.on_bg = .{ .ctx = ws, .f = programBg };
        tv.on_focus = .{ .ctx = ws, .f = clicked };
        const owned = gpa.dupe(u8, block_id) catch return;

        // The title row: the program's tile and title, then this pane's buttons.
        const row = gtk.Box.new(.horizontal, 2);
        row.as(gtk.Widget).addCssClass("pane-title");
        row.as(gtk.Widget).setVisible(@intFromBool(show_headers));
        const tile = blockicon.create(ws.server, block_id, 16);
        row.append(tile);
        const label = gtk.Label.new(null);
        label.as(gtk.Widget).addCssClass("title");
        label.setEllipsize(.end);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).setMarginStart(6);
        row.append(label.as(gtk.Widget));
        const tools = gtk.Box.new(.horizontal, 0);
        tools.as(gtk.Widget).addCssClass("pane-tools");
        var float_button: ?*gtk.Widget = null;
        var minimize_button: ?*gtk.Widget = null;
        const target = gpa.dupeSentinel(u8, block_id, 0) catch return;
        defer gpa.free(target);
        inline for (.{
            .{ icons.Kind.split_right, "Split right", "app.pane-split-right" },
            .{ icons.Kind.split_down, "Split down", "app.pane-split-down" },
            .{ icons.Kind.float, "Float or dock", "app.pane-float" },
            .{ icons.Kind.minimize, "Minimize", "app.pane-minimize" },
            .{ icons.Kind.zoom, "Zoom", "app.pane-zoom" },
            .{ icons.Kind.close, "Close pane", "app.pane-close" },
        }) |b| {
            const button = icons.button(b[0], b[1], b[2]);
            button.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(target.ptr));
            tools.append(button.as(gtk.Widget));
            if (b[0] == icons.Kind.float) float_button = button.as(gtk.Widget);
            if (b[0] == icons.Kind.minimize) minimize_button = button.as(gtk.Widget);
        }
        row.append(tools.as(gtk.Widget));
        const PaneDrag = struct {
            fn begin(g: *gtk.GestureDrag, x: f64, y: f64, w: *Workspace) callconv(.c) void {
                w.moveBegin(g.as(gtk.EventController).getWidget() orelse return, x, y);
            }
            fn update(g: *gtk.GestureDrag, dx: f64, dy: f64, w: *Workspace) callconv(.c) void {
                const d = w.steadyOffset(g, dx, dy) orelse return;
                w.moveUpdate(d[0], d[1]);
            }
            fn end(_: *gtk.GestureDrag, _: f64, _: f64, w: *Workspace) callconv(.c) void {
                w.moveEnd();
            }
            fn cancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, w: *Workspace) callconv(.c) void {
                w.moveCancel();
            }
        };
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &PaneDrag.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &PaneDrag.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &PaneDrag.end, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(drag, *Workspace, &PaneDrag.cancel, ws, .{});
        row.as(gtk.Widget).addController(drag.as(gtk.EventController));
        // The drag handlers find their pane by the widget, so tag it with the block.
        gobject.Object.setData(row.as(gobject.Object), "renux-block", owned.ptr);

        // The header above the terminal, in the container a pane shader takes its picture from.
        const card = tv.shaderSource();
        card.setOverflow(.hidden);
        row.as(gtk.Widget).setParent(card);
        // The pane's own find bar floats over its terminal's top right corner.
        const find = @import("findbar.zig").FindBar.create(tv);
        const body = gtk.Overlay.new();
        body.setChild(tv.widget());
        if (find) |f| body.addOverlay(f.widget());
        body.as(gtk.Widget).setVexpand(1);
        body.as(gtk.Widget).setParent(card);
        tv.setTitleLabel(label);

        // Floating cards resize from their bottom-right corner.
        const grip = gtk.DrawingArea.new();
        grip.setContentWidth(16);
        grip.setContentHeight(16);
        grip.setDrawFunc(&drawGrip, null, null);
        const gw = grip.as(gtk.Widget);
        gw.setHalign(.end);
        gw.setValign(.end);
        gw.setCursorFromName("se-resize");
        gw.setVisible(@intFromBool(floating));
        const GripDrag = struct {
            fn begin(g: *gtk.GestureDrag, x: f64, y: f64, w: *Workspace) callconv(.c) void {
                const handle = g.as(gtk.EventController).getWidget() orelse return;
                var px: f64 = 0;
                var py: f64 = 0;
                _ = handle.translateCoordinates(w.root, x, y, &px, &py);
                w.move_origin = .{ px, py };
                w.gripBegin(handle);
            }
            fn update(g: *gtk.GestureDrag, dx: f64, dy: f64, w: *Workspace) callconv(.c) void {
                const d = w.steadyOffset(g, dx, dy) orelse return;
                w.gripUpdate(d[0], d[1]);
            }
            fn end(_: *gtk.GestureDrag, _: f64, _: f64, w: *Workspace) callconv(.c) void {
                w.gripEnd();
            }
            fn cancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, w: *Workspace) callconv(.c) void {
                w.gripEnd();
            }
        };
        const gdrag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(gdrag, *Workspace, &GripDrag.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(gdrag, *Workspace, &GripDrag.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(gdrag, *Workspace, &GripDrag.end, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(gdrag, *Workspace, &GripDrag.cancel, ws, .{});
        gw.addController(gdrag.as(gtk.EventController));
        gobject.Object.setData(gw.as(gobject.Object), "renux-block", owned.ptr);

        const frame_overlay = gtk.Overlay.new();
        frame_overlay.setChild(card);
        // A pane shader's picture of the whole card, header and terminal, lies over it.
        frame_overlay.addOverlay(tv.shaderWidget());
        frame_overlay.addOverlay(gw);
        const frame = frame_overlay.as(gtk.Widget);
        frame.addCssClass("pane-card");
        frame.setOverflow(.hidden);
        gobject.Object.setData(frame.as(gobject.Object), "renux-block", owned.ptr);
        // Focus follows the mouse when that's on: pointing at a pane gives it the keyboard.
        const enter = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(enter, *Workspace, &pointerEntered, ws, .{});
        frame.addController(enter.as(gtk.EventController));
        if (floating) frame.addCssClass("floating");
        frame.setOpacity(0);
        frame.setParent(ws.root);
        ws.panes.append(gpa, .{
            .block_id = owned,
            .layer_id = gpa.dupe(u8, layer_id) catch return,
            .frame = frame,
            .tile = tile,
            .term = tv,
            .grip = gw,
            .title_row = row.as(gtk.Widget),
            .float_button = float_button,
            .find = find,
            .minimize_button = minimize_button,
            .rect = rect,
            .floating = floating,
            .bounds = bounds orelse .{},
            .seen = true,
        }) catch {};
    }

    fn addToTray(ws: *Workspace, layer_id: []const u8, block_id: []const u8) void {
        const button = gtk.Button.new();
        const line = gtk.Box.new(.horizontal, 6);
        line.append(blockicon.create(ws.server, block_id, 14));
        var buf: [256]u8 = undefined;
        const label = gtk.Label.new(chipTitle(ws.server, block_id, &buf).ptr);
        label.setEllipsize(.middle);
        label.setMaxWidthChars(32);
        line.append(label.as(gtk.Widget));
        button.setChild(line.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("tray-chip");
        button.as(gtk.Widget).setTooltipText("Bring back");
        _ = gtk.Button.signals.clicked.connect(button, *Workspace, &chipClicked, ws, .{});
        // A chip whose card is still on its way stays unseen until the card lands on it.
        for (ws.leaving.items) |l| if (l.to_layer) |t| {
            if (std.mem.eql(u8, t, layer_id)) button.as(gtk.Widget).setOpacity(0);
        };
        // It can be carried to another place. The gesture hears the press before the button
        // does, and takes it from the button once it is clearly no click.
        const drag = gtk.GestureDrag.new();
        drag.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &ChipGesture.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &ChipGesture.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &ChipGesture.end, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(drag, *Workspace, &ChipGesture.cancel, ws, .{});
        button.as(gtk.Widget).addController(drag.as(gtk.EventController));
        button.as(gtk.Widget).setParent(ws.root);
        // It goes back where it was put the last time, if it was put anywhere.
        const dock: Dock = (ws.preview_of orelse ws).docks.get(layer_id) orelse .{ .edge = .bottom, .rank = unranked, .along = 0 };
        ws.minimized.append(gpa, .{
            .layer_id = gpa.dupe(u8, layer_id) catch return,
            .block_id = gpa.dupe(u8, block_id) catch return,
            .button = button.as(gtk.Widget),
            .label = label,
            .edge = dock.edge,
            .rank = dock.rank,
            .along = dock.along,
        }) catch {};
    }

    fn clicked(ctx: *anyopaque, block_id: []const u8) void {
        const ws: *Workspace = @ptrCast(@alignCast(ctx));
        ws.server.clearAttention(block_id);
        replace(&ws.focused, block_id);
        ws.markFocus();
        if (ws.session_id) |s| {
            ws.server.focusBlock(s, block_id);
            if (ws.paneOf(block_id)) |p| if (p.floating) ws.server.raiseLayer(s, p.layer_id);
        }
    }

    fn markFocus(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            const on = if (ws.focused) |f| std.mem.eql(u8, f, p.block_id) else false;
            if (on) p.frame.addCssClass("focused") else p.frame.removeCssClass("focused");
            if (p.term.active_pane != on) {
                p.term.active_pane = on;
                p.term.widget().queueDraw();
            }
        }
        ws.markBackdropFocus();
    }

    /// The keyboard goes with the highlight: when another pane becomes the highlighted one (a
    /// new split, a pane closing), its terminal takes the keyboard from the pane that had it,
    /// so the cursor that blinks is the one that types. Done a moment later, once a new pane
    /// is on screen. A text field, menu or dialog that has the keyboard keeps it.
    fn syncKeyboard(ws: *Workspace) void {
        if (ws.preview_of != null) return;
        if (ws.keyboard_idle == 0) ws.keyboard_idle = glib.idleAdd(&keyboardLater, ws);
    }

    fn keyboardLater(data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        ws.keyboard_idle = 0;
        const target = (ws.focusedView() orelse return 0).widget();
        if (target.getMapped() == 0) return 0;
        const root = ws.root.getRoot() orelse return 0;
        const holder = root.getFocus();
        if (holder == target) return 0;
        var from_pane = holder == null;
        if (holder) |f| for (ws.panes.items) |p| {
            if (p.term.widget() == f) from_pane = true;
        };
        if (from_pane) _ = target.grabFocus();
        return 0;
    }

    /// The card behind a joined layer is lit while one of its panes has the focus.
    fn markBackdropFocus(ws: *Workspace) void {
        const layer: ?[]const u8 = if (ws.focused) |f| (if (ws.paneOf(f)) |p| p.layer_id else null) else null;
        for (ws.backdrops.items) |bd| {
            const on = if (layer) |l| std.mem.eql(u8, l, bd.layer_id) else false;
            if (on) bd.widget.addCssClass("focused") else bd.widget.removeCssClass("focused");
        }
    }

    /// How many panes sit in the window's tiles, floating ones aside.
    pub fn tiledCount(ws: *Workspace) usize {
        var n: usize = 0;
        for (ws.panes.items) |p| {
            if (!p.floating) n += 1;
        }
        return n;
    }

    /// Whether a tiled pane may float (or float on its way to the tray). The window's last
    /// tiled pane stays: Rex can only put a floating pane back beside a tiled one, so floating
    /// the last would leave nothing to dock to, and it can't be minimized either.
    pub fn canFloat(ws: *Workspace, p: *const Pane) bool {
        return !p.floating and ws.tiledCount() > 1;
    }

    /// Whether a floating pane's layer may go to the tray: Rex keeps the window's last visible
    /// panes on screen, so a layer holding all of them stays.
    pub fn canMinimize(ws: *Workspace, p: *const Pane) bool {
        if (!p.floating) return ws.canFloat(p);
        for (ws.panes.items) |other| {
            if (!std.mem.eql(u8, other.layer_id, p.layer_id)) return true;
        }
        return false;
    }

    /// Greys the title buttons that can do nothing for their pane right now, and names what
    /// the float button will do.
    fn markTools(ws: *Workspace) void {
        const tiled = ws.tiledCount();
        for (ws.panes.items) |*p| {
            if (p.float_button) |b| {
                // A floating pane always has somewhere to go: beside a tiled one, or, with
                // none, between filling the window and floating in it.
                b.setSensitive(@intFromBool(p.floating or ws.canFloat(p)));
                b.setTooltipText(if (!p.floating) (if (tiled > 1) "Float" else "The window's last tiled pane stays in place") else if (tiled > 0) "Dock" else "Fill the window or float");
            }
            if (p.minimize_button) |b| b.setSensitive(@intFromBool(ws.canMinimize(p)));
        }
    }

    pub fn paneOf(ws: *Workspace, block_id: []const u8) ?*Pane {
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) return p;
        return null;
    }

    /// The pane next to the focused one in a direction (left, right, up or down): the nearest
    /// one beside it, preferring the one that overlaps it most.
    pub fn neighbor(ws: *Workspace, direction: []const u8) ?[]const u8 {
        const cur = ws.paneOf(ws.focused orelse return null) orelse return null;
        const c = cur.rect;
        const eps = 0.001;
        var best: ?[]const u8 = null;
        var best_dist: f64 = std.math.inf(f64);
        var best_overlap: f64 = -1;
        for (ws.panes.items) |p| {
            if (p.floating != cur.floating or std.mem.eql(u8, p.block_id, cur.block_id)) continue;
            const r = p.rect;
            const horizontal = std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "right");
            const dist = if (std.mem.eql(u8, direction, "left")) c.x - (r.x + r.w) else if (std.mem.eql(u8, direction, "right")) r.x - (c.x + c.w) else if (std.mem.eql(u8, direction, "up")) c.y - (r.y + r.h) else r.y - (c.y + c.h);
            if (dist < -eps) continue;
            const overlap = if (horizontal) @min(c.y + c.h, r.y + r.h) - @max(c.y, r.y) else @min(c.x + c.w, r.x + r.w) - @max(c.x, r.x);
            if (overlap <= eps) continue;
            if (dist < best_dist - eps or (@abs(dist - best_dist) <= eps and overlap > best_overlap)) {
                best = p.block_id;
                best_dist = dist;
                best_overlap = overlap;
            }
        }
        return best;
    }

    /// Marks a pane focused here and on the server, such as before acting on it.
    pub fn focus(ws: *Workspace, block_id: []const u8) void {
        clicked(ws, block_id);
    }

    /// Gives the keyboard to the focused pane.
    pub fn grabFocus(ws: *Workspace) void {
        if (ws.focusedView()) |tv| _ = tv.widget().grabFocus();
    }

    fn restoredFrom(ws: *Workspace, layer_id: []const u8) ?[4]f64 {
        for (ws.restored.items) |r| if (std.mem.eql(u8, r.layer_id, layer_id)) return r.rect;
        return null;
    }

    /// The highlighted pane's find bar.
    pub fn focusedFind(ws: *Workspace) ?*@import("findbar.zig").FindBar {
        if (ws.focused) |f| if (ws.paneOf(f)) |p| return p.find;
        return if (ws.panes.items.len > 0) ws.panes.items[0].find else null;
    }

    /// The focused pane's terminal view.
    /// Where each floating card on screen is, and each joined layer's card around its panes.
    fn floatingHoles(ws: *Workspace, target: *gtk.Widget, out: []window_bg.Hole) usize {
        var n: usize = 0;
        for (ws.panes.items) |*p| {
            if (n == out.len) return n;
            if (!p.floating or p.frame.getMapped() == 0) continue;
            if (p.frame.computeBounds(target, &out[n].rect) != 0) {
                out[n].radius = window_bg.floating_radius;
                n += 1;
            }
        }
        for (ws.backdrops.items) |bd| {
            if (n == out.len) return n;
            if (bd.widget.getMapped() == 0) continue;
            if (bd.widget.computeBounds(target, &out[n].rect) != 0) {
                out[n].radius = window_bg.floating_radius;
                n += 1;
            }
        }
        return n;
    }

    /// Where each card is drawn now, seen from `target` and moved by `dx` and `dy`, with how
    /// round its corners are: what the desktop blurs behind while the window has no background.
    pub fn frostParts(ws: *Workspace, target: *gtk.Widget, dx: f64, dy: f64, out: *std.ArrayList(wayland.Part)) void {
        for (ws.panes.items) |*p| {
            if (p.frame.getMapped() == 0) continue;
            var at: graphene.Rect = undefined;
            if (p.frame.computeBounds(target, &at) == 0) continue;
            // Joined panes are square; the card behind them, below, has the round corners.
            const radius: f64 = if (p.joined) 0 else if (!tight) 11 else if (p.floating) 8 else 0;
            out.append(gpa, .{ .x = at.f_origin.f_x + dx, .y = at.f_origin.f_y + dy, .w = at.f_size.f_width, .h = at.f_size.f_height, .radius = radius }) catch return;
        }
        for (ws.backdrops.items) |bd| {
            if (bd.widget.getMapped() == 0) continue;
            var at: graphene.Rect = undefined;
            if (bd.widget.computeBounds(target, &at) == 0) continue;
            out.append(gpa, .{ .x = at.f_origin.f_x + dx, .y = at.f_origin.f_y + dy, .w = at.f_size.f_width, .h = at.f_size.f_height, .radius = window_bg.floating_radius }) catch return;
        }
    }

    fn isTiledCard(ws: *Workspace, w: *gtk.Widget) bool {
        for (ws.panes.items) |p| if (p.frame == w) return !p.floating;
        return false;
    }

    pub fn focusedView(ws: *Workspace) ?*TermView {
        if (ws.focused) |f| if (ws.paneOf(f)) |p| return p.term;
        return if (ws.panes.items.len > 0) ws.panes.items[0].term else null;
    }

    /// The pane with the keyboard, or the one the server says is focused.
    pub fn focusedBlock(ws: *Workspace) ?[]const u8 {
        return ws.focused;
    }

    /// A block's details changed: redraw its tile and title.
    pub fn blockChanged(ws: *Workspace, block_id: []const u8) void {
        if (ws.paneOf(block_id)) |p| {
            p.tile.queueDraw();
            p.term.updateTitle();
        }
    }

    pub fn isShown(ws: *Workspace, block_id: []const u8) bool {
        return ws.paneOf(block_id) != null;
    }

    pub fn headersChanged(ws: *Workspace) void {
        for (ws.panes.items) |p| p.title_row.setVisible(@intFromBool(show_headers));
    }

    pub fn redraw(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            p.term.widget().queueDraw();
            p.tile.queueDraw();
        }
    }

    /// The terminal font changed: every pane measures its cells again and refits.
    pub fn fontChanged(ws: *Workspace) void {
        for (ws.panes.items) |p| p.term.fontChanged();
    }

    /// After reconnecting, sizes must be sent again.
    /// Tells the server each pane's size if it changed, after sizes were held back.
    pub fn sendSizes(ws: *Workspace) void {
        for (ws.panes.items) |p| p.term.sendSize();
    }

    pub fn resendSizes(ws: *Workspace) void {
        for (ws.panes.items) |p| p.term.resendSize();
    }

    fn fromWidget(w: *gtk.Widget) ?*Workspace {
        return @ptrCast(@alignCast(gobject.Object.getData(w.as(gobject.Object), "renux-workspace") orelse return null));
    }

    // Geometry. Fractions of the window become pixels with one gap between neighbours and none at
    // the edges.

    fn width(ws: *Workspace) f64 {
        return @floatFromInt(ws.root.getWidth());
    }

    fn height(ws: *Workspace) f64 {
        return @floatFromInt(ws.root.getHeight());
    }

    fn pixels(ws: *Workspace, r: view.Rect) [4]f64 {
        return ws.pixelsGap(r, gap);
    }

    fn pixelsGap(ws: *Workspace, r: view.Rect, g: f64) [4]f64 {
        const w = ws.width();
        const h = ws.height();
        const x0 = r.x * (w + g);
        const y0 = r.y * (h + g);
        return .{ x0, y0, (r.x + r.w) * (w + g) - g - x0, (r.y + r.h) * (h + g) - g - y0 };
    }

    /// Where a pane's card goes: joined panes keep one line between them.
    fn paneRect(ws: *Workspace, p: *const Pane) [4]f64 {
        return ws.pixelsGap(p.rect, if (p.joined) 1 else gap);
    }

    /// Marks the panes of each floating layer of several as joined, with rounded corners only
    /// where the layer's are, and puts one card behind them.
    fn joinLayers(ws: *Workspace) void {
        var keep: std.ArrayList([]const u8) = .empty;
        defer keep.deinit(gpa);
        for (ws.panes.items) |*p| {
            var n: usize = 0;
            if (p.floating) for (ws.panes.items) |q| {
                if (q.floating and std.mem.eql(u8, q.layer_id, p.layer_id)) n += 1;
            };
            p.joined = n > 1;
            // The layer's outer edges, from its panes: the server's bounds can differ slightly.
            var b = p.rect;
            if (p.floating) for (ws.panes.items) |q| {
                if (!q.floating or !std.mem.eql(u8, q.layer_id, p.layer_id)) continue;
                const x1 = @max(b.x + b.w, q.rect.x + q.rect.w);
                const y1 = @max(b.y + b.h, q.rect.y + q.rect.h);
                b.x = @min(b.x, q.rect.x);
                b.y = @min(b.y, q.rect.y);
                b.w = x1 - b.x;
                b.h = y1 - b.y;
            };
            const eps = 0.01;
            const l = @abs(p.rect.x - b.x) < eps;
            const t = @abs(p.rect.y - b.y) < eps;
            const r = @abs(p.rect.x + p.rect.w - (b.x + b.w)) < eps;
            const bt = @abs(p.rect.y + p.rect.h - (b.y + b.h)) < eps;
            inline for (.{ .{ "joined", p.joined }, .{ "c-tl", p.joined and l and t }, .{ "c-tr", p.joined and r and t }, .{ "c-bl", p.joined and l and bt }, .{ "c-br", p.joined and r and bt } }) |e| {
                if (e[1]) p.frame.addCssClass(e[0]) else p.frame.removeCssClass(e[0]);
            }
            // One resize corner for the whole layer.
            p.grip.setVisible(@intFromBool(p.floating and (!p.joined or (r and bt))));
            if (p.joined) {
                var seen = false;
                for (keep.items) |k| if (std.mem.eql(u8, k, p.layer_id)) {
                    seen = true;
                };
                if (!seen) keep.append(gpa, p.layer_id) catch {};
            }
        }
        // Drop the cards of layers that are gone or down to one pane, then add the new ones.
        var i: usize = 0;
        while (i < ws.backdrops.items.len) {
            const bd = ws.backdrops.items[i];
            var wanted = false;
            for (keep.items) |k| if (std.mem.eql(u8, k, bd.layer_id)) {
                wanted = true;
            };
            if (wanted) {
                i += 1;
                continue;
            }
            bd.widget.unparent();
            gpa.free(bd.layer_id);
            _ = ws.backdrops.orderedRemove(i);
        }
        for (keep.items) |k| {
            var have = false;
            for (ws.backdrops.items) |bd| if (std.mem.eql(u8, bd.layer_id, k)) {
                have = true;
            };
            if (have) continue;
            const card = gtk.Box.new(.horizontal, 0);
            card.as(gtk.Widget).addCssClass("layer-card");
            card.as(gtk.Widget).setCanTarget(0);
            card.as(gtk.Widget).setParent(ws.root);
            ws.backdrops.append(gpa, .{ .layer_id = gpa.dupe(u8, k) catch continue, .widget = card.as(gtk.Widget) }) catch {};
        }
        // Each card sits just under its layer's first pane.
        for (ws.backdrops.items) |bd| {
            var child = ws.root.getFirstChild();
            while (child) |c| : (child = c.getNextSibling()) {
                if (c == bd.widget) continue;
                const is_layer = for (ws.panes.items) |p| {
                    if (p.frame == c) break std.mem.eql(u8, p.layer_id, bd.layer_id);
                } else false;
                if (is_layer) {
                    if (c.getPrevSibling() != bd.widget) bd.widget.insertBefore(ws.root, c);
                    break;
                }
            }
        }
        ws.markBackdropFocus();
    }

    // Dividers.

    fn dividerAt(ws: *Workspace, x: f64, y: f64) ?usize {
        const w = ws.width();
        const h = ws.height();
        const reach = @max(gap / 2 + 3, 5);
        for (ws.dividers.items, 0..) |d, i| {
            const r = ws.pixels(d.rect);
            if (d.horizontal) {
                const at = (d.rect.x + d.rect.w * d.ratio) * (w + gap) - gap / 2;
                if (@abs(x - at) <= reach and y >= r[1] and y <= r[1] + r[3]) return i;
            } else {
                const at = (d.rect.y + d.rect.h * d.ratio) * (h + gap) - gap / 2;
                if (@abs(y - at) <= reach and x >= r[0] and x <= r[0] + r[2]) return i;
            }
        }
        return null;
    }

    fn hover(_: *gtk.EventControllerMotion, x: f64, y: f64, ws: *Workspace) callconv(.c) void {
        if (ws.resizing != null or ws.moving != null) return;
        const at = ws.dividerAt(x, y);
        const cursor: ?[*:0]const u8 = if (at) |i| (if (ws.dividers.items[i].horizontal) "col-resize" else "row-resize") else null;
        ws.root.setCursorFromName(cursor);
        ws.showLine(at);
    }

    fn hoverLeft(_: *gtk.EventControllerMotion, ws: *Workspace) callconv(.c) void {
        if (ws.resizing == null) ws.showLine(null);
    }

    /// Shows the line on one divider, or fades it out. It keeps its last place while it fades.
    fn showLine(ws: *Workspace, at: ?usize) void {
        if (at) |i| {
            if (ws.line_at != i) {
                ws.line_at = i;
                ws.root.queueAllocate();
            }
            ws.line.addCssClass("shown");
        } else ws.line.removeCssClass("shown");
    }

    /// Where the line sits: along the middle of the gap between the divider's two sides, a
    /// little short of its ends.
    fn lineRect(ws: *Workspace) ?[4]f64 {
        const i = ws.line_at orelse return null;
        if (i >= ws.dividers.items.len) return null;
        const d = ws.dividers.items[i];
        const ratio = if (ws.resizing == i) ws.local_ratio else d.ratio;
        const r = ws.pixels(d.rect);
        const inset: f64 = 10;
        if (d.horizontal) {
            const x = (d.rect.x + d.rect.w * ratio) * (ws.width() + gap) - gap / 2;
            return .{ x - 1.5, r[1] + inset, 3, @max(1, r[3] - 2 * inset) };
        }
        const y = (d.rect.y + d.rect.h * ratio) * (ws.height() + gap) - gap / 2;
        return .{ r[0] + inset, y - 1.5, @max(1, r[2] - 2 * inset), 3 };
    }

    fn dividerBegin(g: *gtk.GestureDrag, x: f64, y: f64, ws: *Workspace) callconv(.c) void {
        ws.resizing = ws.dividerAt(x, y);
        if (ws.resizing == null) {
            _ = g.as(gtk.Gesture).setState(.denied);
            return;
        }
        _ = g.as(gtk.Gesture).setState(.claimed);
        ws.move_origin = .{ x, y };
        ws.local_ratio = ws.dividers.items[ws.resizing.?].ratio;
        for (ws.panes.items) |*p| p.drag_start = p.rect;
    }

    /// Lays the panes out for the ratio under the pointer straight away, from where they were when
    /// the drag began, without waiting for the server's answer.
    fn followDivider(ws: *Workspace) void {
        const i = ws.resizing orelse return;
        if (i >= ws.dividers.items.len) return;
        const d = ws.dividers.items[i];
        const eps = 0.0005;
        const start = if (d.horizontal) d.rect.x else d.rect.y;
        const size = if (d.horizontal) d.rect.w else d.rect.h;
        const old_at = start + size * d.ratio;
        const new_at = start + size * ws.local_ratio;
        for (ws.panes.items) |*p| {
            if (p.floating) continue;
            const r = p.drag_start;
            if (r.x < d.rect.x - eps or r.y < d.rect.y - eps or r.x + r.w > d.rect.x + d.rect.w + eps or r.y + r.h > d.rect.y + d.rect.h + eps) continue;
            const pos = if (d.horizontal) r.x else r.y;
            const len = if (d.horizontal) r.w else r.h;
            var np: f64 = 0;
            var nl: f64 = 0;
            if (pos + len <= old_at + eps) {
                const k = (new_at - start) / @max(old_at - start, eps);
                np = start + (pos - start) * k;
                nl = len * k;
            } else {
                const end = start + size;
                const k = (end - new_at) / @max(end - old_at, eps);
                np = new_at + (pos - old_at) * k;
                nl = len * k;
            }
            if (d.horizontal) {
                p.rect.x = np;
                p.rect.w = nl;
            } else {
                p.rect.y = np;
                p.rect.h = nl;
            }
        }
        ws.root.queueAllocate();
    }

    fn sendDivider(ws: *Workspace, dx: f64, dy: f64, force: bool) void {
        const i = ws.resizing orelse return;
        if (i >= ws.dividers.items.len) return;
        const d = &ws.dividers.items[i];
        const w = ws.width();
        const h = ws.height();
        // The ratio under the pointer, within the split's own rectangle.
        const ratio = if (d.horizontal)
            ((ws.move_origin[0] + dx + gap / 2) / (w + gap) - d.rect.x) / d.rect.w
        else
            ((ws.move_origin[1] + dy + gap / 2) / (h + gap) - d.rect.y) / d.rect.h;
        ws.local_ratio = std.math.clamp(ratio, 0.05, 0.95);
        ws.followDivider();
        // Each change makes programs redraw, so send at most every 60 ms while dragging.
        const now = glib.getMonotonicTime();
        if (!force and now - ws.last_resize < 60_000) return;
        ws.last_resize = now;
        if (ws.session_id) |s| ws.server.resizePane(s, d.horizontal, d.before_id, d.after_id, ws.local_ratio);
    }

    fn dividerUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
        ws.sendDivider(dx, dy, false);
    }

    fn dividerEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
        if (ws.resizing == null) return;
        ws.sendDivider(dx, dy, true);
        ws.resizing = null;
        ws.showLine(null);
    }

    /// The drag was taken away (a dialog opened, the compositor took the pointer) and no end
    /// follows. The split stays where it was let go, and the server hears that ratio.
    fn dividerCancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, ws: *Workspace) callconv(.c) void {
        const i = ws.resizing orelse return;
        ws.resizing = null;
        ws.showLine(null);
        if (i >= ws.dividers.items.len) return;
        const d = ws.dividers.items[i];
        if (ws.session_id) |s| ws.server.resizePane(s, d.horizontal, d.before_id, d.after_id, ws.local_ratio);
        ws.root.queueAllocate();
    }

    // Carrying a pane by its title.

    fn pointerEntered(ctl: *gtk.EventControllerMotion, _: f64, _: f64, ws: *Workspace) callconv(.c) void {
        if (!settings.current.focus_follows_mouse) return;
        if (ws.moving != null or ws.resizing != null) return;
        const w = ctl.as(gtk.EventController).getWidget() orelse return;
        const i = ws.paneOfWidget(w) orelse return;
        const p = ws.panes.items[i];
        if (ws.focused) |f| if (std.mem.eql(u8, f, p.block_id)) return;
        ws.focus(p.block_id);
        _ = p.term.widget().grabFocus();
    }

    /// A program changed its background; with frames matching programs, the card follows it.
    fn programBg(ctx: *anyopaque, block_id: []const u8, bg: u32) void {
        const ws: *Workspace = @ptrCast(@alignCast(ctx));
        var wanted = false;
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) {
            p.program_bg = bg;
            if (!std.meta.eql(p.bg_applied, wantedBg(p))) wanted = true;
        };
        // Styles can't change while drawing, so this waits for the next idle moment. Nothing
        // waits at all when no card would change, which is always so with the setting off.
        if (wanted and ws.bg_idle == 0) ws.bg_idle = glib.idleAdd(&applyProgramBgs, ws);
    }

    fn applyProgramBgs(data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        ws.bg_idle = 0;
        ws.refreshProgramBgs();
        return 0;
    }

    /// The background a card should take from its program, or none.
    fn wantedBg(p: *const Pane) ?u32 {
        if (!settings.current.match_program_bg or p.program_bg == 0) return null;
        return p.program_bg & 0xffffff;
    }

    /// Gives each card the style class of its program's background, named after the color, and
    /// loads the rules for the colors in use. Nothing is touched when nothing changed.
    pub fn refreshProgramBgs(ws: *Workspace) void {
        var css: std.ArrayList(u8) = .empty;
        defer css.deinit(gpa);
        for (ws.panes.items, 0..) |*p, i| {
            const want = wantedBg(p);
            if (!std.meta.eql(p.bg_applied, want)) {
                var old_buf: [16]u8 = undefined;
                if (p.bg_applied) |old| p.frame.removeCssClass(bgClass(&old_buf, old).ptr);
                if (want) |c| p.frame.addCssClass(bgClass(&old_buf, c).ptr);
                p.bg_applied = want;
            }
            const c = want orelse continue;
            // One rule per color, however many panes share it.
            const listed = for (ws.panes.items[0..i]) |q| {
                if (q.bg_applied) |qc| if (qc == c) break true;
            } else false;
            if (listed) continue;
            var name_buf: [16]u8 = undefined;
            const name = bgClass(&name_buf, c);
            css.print(gpa, ".pane-card.{s}, .pane-card.{s} .pane-title {{ background-color: #{x:0>6}; }}\n", .{ name, name, c }) catch {};
        }
        if (std.mem.eql(u8, css.items, ws.bg_css_text.items)) return;
        ws.bg_css_text.clearRetainingCapacity();
        ws.bg_css_text.appendSlice(gpa, css.items) catch {};
        css.append(gpa, 0) catch return;
        const provider = ws.bg_css orelse blk: {
            const display = gdk.Display.getDefault() orelse return;
            const pr = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(display, pr.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
            ws.bg_css = pr;
            break :blk pr;
        };
        provider.loadFromString(@ptrCast(css.items.ptr));
    }

    fn bgClass(buf: *[16]u8, color: u32) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "pbg-{x:0>6}", .{color & 0xffffff}, 0) catch "pbg";
    }

    fn paneOfWidget(ws: *Workspace, w: *gtk.Widget) ?usize {
        const data = gobject.Object.getData(w.as(gobject.Object), "renux-block") orelse return null;
        for (ws.panes.items, 0..) |p, i| if (@intFromPtr(p.block_id.ptr) == @intFromPtr(data)) return i;
        return null;
    }

    /// A drag's offset measured in the workspace, which stays put. GTK measures it in the dragged
    /// widget's own space, and that widget moves with the card, so the raw offset would fight the
    /// pointer and stutter.
    fn steadyOffset(ws: *Workspace, g: *gtk.GestureDrag, dx: f64, dy: f64) ?[2]f64 {
        const w = g.as(gtk.EventController).getWidget() orelse return null;
        var sx: f64 = 0;
        var sy: f64 = 0;
        if (g.getStartPoint(&sx, &sy) == 0) return null;
        var px: f64 = 0;
        var py: f64 = 0;
        if (w.translateCoordinates(ws.root, sx + dx, sy + dy, &px, &py) == 0) return null;
        return .{ px - ws.move_origin[0], py - ws.move_origin[1] };
    }

    fn moveBegin(ws: *Workspace, title: *gtk.Widget, x: f64, y: f64) void {
        const i = ws.paneOfWidget(title) orelse return;
        ws.moving = i;
        ws.move_armed = false;
        var px: f64 = 0;
        var py: f64 = 0;
        _ = title.translateCoordinates(ws.root, x, y, &px, &py);
        ws.move_origin = .{ px, py };
        ws.pointer = .{ px, py };
        ws.startLayerDrag(i);
        clicked(ws, ws.panes.items[i].block_id);
    }

    fn moveUpdate(ws: *Workspace, dx: f64, dy: f64) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing or i >= ws.panes.items.len) return;
        if (!ws.move_armed and @abs(dx) < 6 and @abs(dy) < 6) return;
        ws.move_armed = true;
        ws.pointer = .{ ws.move_origin[0] + dx, ws.move_origin[1] + dy };
        const p = &ws.panes.items[i];
        if (p.floating) {
            // A floating layer follows the pointer, all its panes together; the server hears
            // where it lands.
            var b = ws.float_start;
            b.x = view.clampWithin(b.x + dx / @max(ws.width(), 1), 0, 1 - b.w);
            b.y = view.clampWithin(b.y + dy / @max(ws.height(), 1), 0, 1 - b.h);
            ws.setLayerBounds(i, b);
            return;
        }
        ws.updateZone();
        ws.showCarry();
    }

    /// Notes where a pane's floating layer and its panes are as a drag begins.
    fn startLayerDrag(ws: *Workspace, i: usize) void {
        const p = ws.panes.items[i];
        ws.float_start = if (p.bounds.w > 0) p.bounds else p.rect;
        for (ws.panes.items) |*q| if (std.mem.eql(u8, q.layer_id, p.layer_id)) {
            q.drag_start = q.rect;
        };
    }

    /// Moves or resizes a pane's floating layer, scaling each of its panes with it.
    fn setLayerBounds(ws: *Workspace, i: usize, b: view.Rect) void {
        const sb = ws.float_start;
        const layer = ws.panes.items[i].layer_id;
        const sx = b.w / @max(sb.w, 0.0001);
        const sy = b.h / @max(sb.h, 0.0001);
        for (ws.panes.items) |*q| if (std.mem.eql(u8, q.layer_id, layer)) {
            const r = q.drag_start;
            q.rect = .{ .x = b.x + (r.x - sb.x) * sx, .y = b.y + (r.y - sb.y) * sy, .w = r.w * sx, .h = r.h * sy };
            q.bounds = b;
        };
        ws.root.queueAllocate();
    }

    /// Whether this floating layer is under the pointer being moved or resized.
    fn draggingLayer(ws: *Workspace, layer_id: []const u8) bool {
        const m = ws.moving orelse return false;
        if (m >= ws.panes.items.len) return false;
        const p = ws.panes.items[m];
        if (!p.floating or !(ws.float_resizing or ws.move_armed)) return false;
        return std.mem.eql(u8, p.layer_id, layer_id);
    }

    /// Shows the carried card under the pointer and where it would land.
    fn showCarry(ws: *Workspace) void {
        const carrying = if (ws.moving) |i| i < ws.panes.items.len and ws.move_armed and !ws.panes.items[i].floating else false;
        ws.ghost.setVisible(@intFromBool(carrying));
        const shown = carrying and ws.zone_pane != null;
        if (shown and ws.target.getVisible() == 0) {
            // It appears where it belongs, then glides between targets.
            ws.target_cur = ws.targetRect();
            ws.target_vel = .{ 0, 0, 0, 0 };
        }
        ws.target.setVisible(@intFromBool(shown));
        ws.swap_arrows.setVisible(@intFromBool(shown and ws.zone == .swap));
        ws.root.queueAllocate();
        if (shown) ws.startTick();
    }

    /// Where the carried pane would land, in pixels.
    fn targetRect(ws: *Workspace) [4]f64 {
        const t = ws.zone_pane orelse return .{ 0, 0, 0, 0 };
        if (t >= ws.panes.items.len) return .{ 0, 0, 0, 0 };
        const r = ws.pixels(ws.panes.items[t].rect);
        var x = r[0];
        var y = r[1];
        var w = r[2];
        var h = r[3];
        switch (ws.zone) {
            .left => w /= 2,
            .right => {
                x += w / 2;
                w /= 2;
            },
            .top => h /= 2,
            .bottom => {
                y += h / 2;
                h /= 2;
            },
            else => {},
        }
        return .{ x + 4, y + 4, w - 8, h - 8 };
    }

    fn moveEnd(ws: *Workspace) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing) return;
        defer {
            ws.moving = null;
            ws.zone = .none;
            ws.zone_pane = null;
            ws.showCarry();
        }
        if (!ws.move_armed) return;
        const sid = ws.session_id orelse return;
        if (i >= ws.panes.items.len) return;
        const p = ws.panes.items[i];
        if (p.floating) return ws.server.resizeLayer(sid, p.layer_id, p.bounds);
        const t = ws.zone_pane orelse return;
        if (t >= ws.panes.items.len) return;
        switch (ws.zone) {
            .none => {},
            .swap => ws.server.swapBlocks(sid, p.block_id, ws.panes.items[t].block_id),
            .left, .right, .top, .bottom => ws.server.moveBlock(
                sid,
                p.block_id,
                ws.panes.items[t].block_id,
                ws.zone == .left or ws.zone == .right,
                ws.zone == .left or ws.zone == .top,
            ),
        }
    }

    /// The drag was taken away and no end follows. A floating layer stays where it was let go
    /// and the server hears that; a carried pane is put down where it came from.
    fn moveCancel(ws: *Workspace) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing) return;
        if (i < ws.panes.items.len and ws.panes.items[i].floating) return ws.moveEnd();
        ws.moving = null;
        ws.zone = .none;
        ws.zone_pane = null;
        ws.showCarry();
    }

    fn updateZone(ws: *Workspace) void {
        const x = ws.pointer[0];
        const y = ws.pointer[1];
        ws.zone = .none;
        ws.zone_pane = null;
        for (ws.panes.items, 0..) |p, i| {
            if (p.floating or i == ws.moving.?) continue;
            const r = ws.pixels(p.rect);
            if (x < r[0] or y < r[1] or x > r[0] + r[2] or y > r[1] + r[3]) continue;
            // The nearest edge, unless the pointer is in the middle, which swaps.
            const fx = (x - r[0]) / r[2];
            const fy = (y - r[1]) / r[3];
            ws.zone_pane = i;
            if (fx > 0.3 and fx < 0.7 and fy > 0.3 and fy < 0.7) {
                ws.zone = .swap;
            } else {
                const d = [_]f64{ fx, 1 - fx, fy, 1 - fy };
                var best: usize = 0;
                for (d, 0..) |v, k| if (v < d[best]) {
                    best = k;
                };
                ws.zone = switch (best) {
                    0 => .left,
                    1 => .right,
                    2 => .top,
                    else => .bottom,
                };
            }
            return;
        }
    }

    // Animation. Each card's place follows its target on a critically damped spring, so it starts
    // gently, never overshoots and settles in about a quarter of a second.

    const spring = 20.0;

    fn startTick(ws: *Workspace) void {
        if (ws.tick != 0) return;
        ws.last_time = 0;
        ws.tick = ws.root.addTickCallback(&onTick, ws, null);
        ticking += 1;
    }

    fn onTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        const now = clock.getFrameTime();
        const dt: f64 = if (ws.last_time == 0) 1.0 / 60.0 else std.math.clamp(@as(f64, @floatFromInt(now - ws.last_time)) / 1e6, 0, 0.05);
        ws.last_time = now;
        const decay = @exp(-spring * dt);
        var busy = false;
        for (ws.panes.items, 0..) |*p, i| {
            // A card under the pointer is placed directly, but still fades in if it is new.
            const still = ws.pinned(i) or springStep(&p.cur, &p.vel, ws.paneRect(p), dt, decay);
            p.alpha += (1 - p.alpha) * (1 - @exp(-14 * dt));
            if (p.alpha > 0.995) p.alpha = 1;
            if (!still or p.alpha < 1) busy = true;
        }
        var i: usize = 0;
        while (i < ws.leaving.items.len) {
            const l = &ws.leaving.items[i];
            if (l.to_layer) |layer| {
                // To the tray: the card itself becomes the chip, moving with the same spring
                // as every other card. Once it has settled onto the chip's place the chip
                // takes over, and the card is done.
                const still = springStep(&l.cur, &l.vel, ws.chipSpot(layer), dt, decay);
                l.alpha = if (still) 0 else 1;
                if (still) ws.showChip(layer);
            } else {
                l.alpha -= dt / 0.16;
                // Shrinks a little toward its middle as it fades.
                const s = 1 - 0.25 * dt;
                l.cur = .{ l.cur[0] + l.cur[2] * (1 - s) / 2, l.cur[1] + l.cur[3] * (1 - s) / 2, l.cur[2] * s, l.cur[3] * s };
            }
            if (l.alpha <= 0) {
                ws.gone(ws.leaving.orderedRemove(i));
            } else i += 1;
        }
        if (ws.leaving.items.len > 0) busy = true;
        if (ws.target.getVisible() != 0 and !springStep(&ws.target_cur, &ws.target_vel, ws.targetRect(), dt, decay)) busy = true;
        if (ws.moveChips(now)) busy = true;
        ws.root.queueAllocate();
        if (!busy) {
            ws.tick = 0;
            ticking -|= 1;
            return 0;
        }
        return 1;
    }

    fn springStep(cur: *[4]f64, vel: *[4]f64, target: [4]f64, dt: f64, decay: f64) bool {
        var still = true;
        for (0..4) |k| {
            const d = cur[k] - target[k];
            const v = vel[k];
            const nd = (d + (v + spring * d) * dt) * decay;
            vel[k] = (v - spring * (v + spring * d) * dt) * decay;
            cur[k] = target[k] + nd;
            if (@abs(nd) > 0.4 or @abs(vel[k]) > 4) still = false;
        }
        if (still) {
            cur.* = target;
            vel.* = .{ 0, 0, 0, 0 };
        }
        return still;
    }

    /// A card under the pointer, moved or resized directly, follows it without easing.
    fn pinned(ws: *Workspace, i: usize) bool {
        if (ws.resizing != null) return !ws.panes.items[i].floating;
        return ws.draggingLayer(ws.panes.items[i].layer_id);
    }

    // For the development script: drive the same paths a pointer would.

    pub fn simulateCarry(ws: *Workspace, block_id: []const u8, x: f64, y: f64) void {
        const i = ws.indexOf(block_id) orelse return;
        const r = ws.pixels(ws.panes.items[i].rect);
        ws.moving = i;
        ws.move_armed = false;
        ws.move_origin = .{ r[0] + 40, r[1] + 16 };
        ws.startLayerDrag(i);
        ws.moveUpdate(x - ws.move_origin[0], y - ws.move_origin[1]);
    }

    pub fn simulateDrop(ws: *Workspace) void {
        ws.moveEnd();
    }

    /// Development: shows the line on the first divider, as the pointer over it would.
    pub fn simulateLine(ws: *Workspace) void {
        if (ws.dividers.items.len > 0) ws.showLine(0);
    }

    pub fn simulateDivider(ws: *Workspace, dx: f64) void {
        if (ws.dividers.items.len == 0) return;
        const d = ws.dividers.items[0];
        const w = ws.width();
        const h = ws.height();
        ws.resizing = 0;
        ws.move_origin = if (d.horizontal)
            .{ (d.rect.x + d.rect.w * d.ratio) * (w + gap) - gap / 2, 10 }
        else
            .{ 10, (d.rect.y + d.rect.h * d.ratio) * (h + gap) - gap / 2 };
        ws.sendDivider(if (d.horizontal) dx else 0, if (d.horizontal) 0 else dx, true);
        ws.resizing = null;
    }

    fn indexOf(ws: *Workspace, block_id: []const u8) ?usize {
        for (ws.panes.items, 0..) |p, i| if (std.mem.eql(u8, p.block_id, block_id)) return i;
        return null;
    }

    // Floating cards resize from their corner.

    fn gripBegin(ws: *Workspace, grip: *gtk.Widget) void {
        const i = ws.paneOfWidget(grip) orelse return;
        ws.moving = i;
        ws.float_resizing = true;
        ws.startLayerDrag(i);
    }

    fn gripUpdate(ws: *Workspace, dx: f64, dy: f64) void {
        if (!ws.float_resizing) return;
        const i = ws.moving orelse return;
        if (i >= ws.panes.items.len) return;
        var b = ws.float_start;
        b.w = view.clampWithin(b.w + dx / @max(ws.width(), 1), 0.15, 1 - b.x);
        b.h = view.clampWithin(b.h + dy / @max(ws.height(), 1), 0.15, 1 - b.y);
        ws.setLayerBounds(i, b);
    }

    /// Also where a cancelled resize ends, so it does nothing unless one is under way.
    fn gripEnd(ws: *Workspace) void {
        if (!ws.float_resizing) return;
        ws.float_resizing = false;
        const i = ws.moving orelse return;
        ws.moving = null;
        if (i >= ws.panes.items.len) return;
        const p = ws.panes.items[i];
        if (ws.session_id) |s| ws.server.resizeLayer(s, p.layer_id, p.bounds);
    }
};

fn firstLeaf(n: *const view.Node) []const u8 {
    return switch (n.*) {
        .leaf => |l| l.block_id,
        .split => |s| firstLeaf(s.before),
    };
}

fn measure(_: *gtk.Widget, _: gtk.Orientation, _: c_int, minimum: *c_int, natural: *c_int, min_baseline: *c_int, nat_baseline: *c_int) callconv(.c) void {
    minimum.* = 120;
    natural.* = 640;
    min_baseline.* = -1;
    nat_baseline.* = -1;
}

fn allocate(widget: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const ws = Workspace.fromWidget(widget) orelse return;
    // When the window itself changes size, cards keep up with it instead of easing behind.
    const size = [2]f64{ @floatFromInt(width), @floatFromInt(height) };
    const resized = size[0] != ws.last_size[0] or size[1] != ws.last_size[1];
    ws.last_size = size;
    var moving = false;
    // Where the workspace is in the window as of this layout, which its parents have just set.
    var origin = [2]f64{ 0, 0 };
    if (widget.getRoot()) |root| _ = widget.translateCoordinates(root.as(gtk.Widget), 0, 0, &origin[0], &origin[1]);
    for (ws.panes.items, 0..) |*p, i| {
        const target = ws.paneRect(p);
        if (p.fresh) {
            p.fresh = false;
            // The terminal's room in the settled card: the card less its border and title row.
            var title_min: c_int = 0;
            var title_h: c_int = 0;
            if (p.title_row.getVisible() != 0) p.title_row.measure(.vertical, -1, &title_min, &title_h, null, null);
            p.term.presize(target[2] - 2, target[3] - 2 - @as(f64, @floatFromInt(title_h)));
            if (ws.snap or resized) {
                p.cur = target;
                p.alpha = 1;
            } else if (ws.restoredFrom(p.layer_id)) |from| {
                // Back from the tray: the chip is gone and the card grows from its place, as
                // if the chip itself opened up.
                p.cur = from;
                p.alpha = 1;
                p.face = ws.chipFace(p.block_id, 1);
                p.face_w = from[2];
                @as(*gtk.Overlay, @ptrCast(p.frame)).addOverlay(p.face.?);
                p.frame.addCssClass("to-tray");
            } else {
                // A new card grows in from a little smaller than its place.
                const inset_x = target[2] * 0.04;
                const inset_y = target[3] * 0.04;
                p.cur = .{ target[0] + inset_x, target[1] + inset_y, target[2] - 2 * inset_x, target[3] - 2 * inset_y };
                p.alpha = 0;
            }
        } else if (ws.snap or resized or ws.pinned(i)) {
            p.cur = target;
            p.vel = .{ 0, 0, 0, 0 };
            if (ws.snap) p.alpha = 1;
        }
        for (0..4) |k| if (p.cur[k] != target[k]) {
            moving = true;
        };
        if (p.alpha < 1) moving = true;
        p.frame.setOpacity(p.alpha);
        if (p.face) |face| {
            // Growing out of the tray: the chip's look gives way to the pane's own.
            const shown = faceShown(p.cur[2], target[2], p.face_w);
            face.setOpacity(shown);
            if (shown <= 0) {
                @as(*gtk.Overlay, @ptrCast(p.frame)).removeOverlay(face);
                if (p.minimizing_until == 0) p.frame.removeCssClass("to-tray");
                p.face = null;
            }
        }
        Workspace.cornerRoom(p, origin, p.cur);
        allocateAt(p.frame, p.cur);
    }
    for (ws.leaving.items) |l| {
        l.frame.setOpacity(@max(0, l.alpha));
        if (l.to_layer) |layer| {
            // The chip's look comes through as the card nears the chip's size.
            if (l.face) |face| face.setOpacity(faceShown(l.cur[2], l.from_w, ws.chipSpot(layer)[2]));
            // Its terminal is frozen, so the card can take the shrinking size itself.
            allocateAt(l.frame, .{ l.cur[0], l.cur[1], @max(8, l.cur[2]), @max(8, l.cur[3]) });
            continue;
        }
        // A leaving card keeps its size, so its terminal never asks the server for a new one.
        allocateAt(l.frame, .{ l.cur[0] + (l.cur[2] - l.size[0]) / 2, l.cur[1] + (l.cur[3] - l.size[1]) / 2, l.size[0], l.size[1] });
    }
    // A joined layer's card wraps its panes where they are drawn now, a pixel outside them.
    for (ws.backdrops.items) |bd| {
        var lo = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        var hi = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
        var alpha: f64 = 0;
        for (ws.panes.items) |p| if (std.mem.eql(u8, p.layer_id, bd.layer_id)) {
            lo = .{ @min(lo[0], p.cur[0]), @min(lo[1], p.cur[1]) };
            hi = .{ @max(hi[0], p.cur[0] + p.cur[2]), @max(hi[1], p.cur[1] + p.cur[3]) };
            alpha = @max(alpha, p.alpha);
        };
        if (lo[0] > hi[0]) continue;
        bd.widget.setOpacity(alpha);
        var a: gtk.Allocation = .{
            .f_x = @intFromFloat(@round(lo[0] - 1)),
            .f_y = @intFromFloat(@round(lo[1] - 1)),
            .f_width = @intFromFloat(@max(1, @round(hi[0] - lo[0] + 2))),
            .f_height = @intFromFloat(@max(1, @round(hi[1] - lo[1] + 2))),
        };
        bd.widget.sizeAllocate(&a, -1);
    }
    if (ws.target.getVisible() != 0) allocateAt(ws.target, ws.target_cur);
    if (ws.line.getParent() != null) allocateAt(ws.line, ws.lineRect() orelse .{ 0, 0, 1, 1 });
    if (ws.ghost.getVisible() != 0) allocateAt(ws.ghost, .{ ws.pointer[0] - 75, ws.pointer[1] - 46, 150, 92 });
    if (moving or ws.leaving.items.len > 0) ws.startTick();
    var all: gtk.Allocation = .{ .f_x = 0, .f_y = 0, .f_width = width, .f_height = height };
    if (ws.empty.getVisible() != 0) ws.empty.sizeAllocate(&all, -1);
    // Minimized panes' chips keep to the edges, each where it was put.
    ws.placeChips(@floatFromInt(width), @floatFromInt(height));
    var chips_moving = false;
    for (ws.minimized.items) |m| {
        allocateAt(m.button, .{ m.cur[0], m.cur[1], m.size[0], m.size[1] });
        if (m.began != 0) chips_moving = true;
    }
    if (chips_moving) ws.startTick();
    ws.snap = false;
    // Where the floating cards are decides what is cut from the tiled ones under them.
    if (cut_floating) widget.queueDraw();
}

/// Told each time a workspace's cards are drawn, where they are by then.
pub var drawn: ?*const fn (ws: *Workspace) void = null;

/// Set while the window is see-through: the tiled cards are cut where a floating card lies
/// over them, so a floating pane shows the desktop behind the window, as the other panes do,
/// rather than the pane under it.
pub var cut_floating: bool = false;

/// The workspace's own widget: a container that lays its cards out itself (`allocate`) and,
/// while see-through, draws the tiled cards with the floating cards' places cut out.
const PaneArea = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxPaneArea",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        const w = self.as(gtk.Widget);
        var cut: [32]window_bg.Hole = undefined;
        const ws = Workspace.fromWidget(w);
        if (ws) |x| if (drawn) |f| f(x);
        const n = if (!cut_floating) 0 else if (ws) |x| x.floatingHoles(w, &cut) else 0;
        if (n == 0) {
            var c = w.getFirstChild();
            while (c) |child| : (c = child.getNextSibling()) w.snapshotChild(child, sn);
            return;
        }
        // The tiled cards first, cut, then everything else in its own order above them.
        if (n == 1) {
            cutOne(w, ws.?, sn, cut[0]);
        } else {
            window_bg.pushCut(sn, cut[0..n]);
            tiled(w, ws.?, sn);
            sn.pop();
        }
        var c = w.getFirstChild();
        while (c) |child| : (c = child.getNextSibling()) if (!ws.?.isTiledCard(child)) w.snapshotChild(child, sn);
    }

    fn tiled(w: *gtk.Widget, ws: *Workspace, sn: *gtk.Snapshot) void {
        var c = w.getFirstChild();
        while (c) |child| : (c = child.getNextSibling()) if (ws.isTiledCard(child)) w.snapshotChild(child, sn);
    }

    /// Draws the tiled cards with one floating card's place cut out of them, without a mask
    /// over the lot. A mask makes the GPU draw every tiled card into a picture of its own and
    /// then the hole into another, both the size of the hole, on each frame the floating pane
    /// changes: that was most of what a busy floating pane cost over a tiled one.
    ///
    /// Instead the cards are drawn in pieces, each inside a plain rectangle, which costs
    /// nothing: the four sides around the hole, and then the thin frame where the hole's edge
    /// and its rounded corners fall, the only place a mask is still needed. The pieces meet on
    /// whole screen pixels, so no line shows where two of them touch.
    fn cutOne(w: *gtk.Widget, ws: *Workspace, sn: *gtk.Snapshot, hole: window_bg.Hole) void {
        const grid = PixelGrid.of(w);
        const far = 4096;
        const x0: f64 = hole.rect.f_origin.f_x;
        const y0: f64 = hole.rect.f_origin.f_y;
        const x1 = x0 + hole.rect.f_size.f_width;
        const y1 = y0 + hole.rect.f_size.f_height;
        // The hole grown to whole pixels: outside it the cards are drawn as they are.
        const ox0 = grid.down(x0, 0);
        const oy0 = grid.down(y0, 1);
        const ox1 = grid.up(x1, 0);
        const oy1 = grid.up(y1, 1);
        const right: f64 = @floatFromInt(w.getWidth() + far);
        const bottom: f64 = @floatFromInt(w.getHeight() + far);
        const plain = [_][4]f64{
            .{ -far, -far, right, oy0 },
            .{ -far, oy1, right, bottom },
            .{ -far, oy0, ox0, oy1 },
            .{ ox1, oy0, right, oy1 },
        };
        for (plain) |r| {
            if (r[2] <= r[0] or r[3] <= r[1]) continue;
            sn.pushClip(&rectOf(r));
            tiled(w, ws, sn);
            sn.pop();
        }
        // The frame: the rows holding the top and bottom corners, and between them the pixel
        // or two the hole's sides fall in.
        const radius: f64 = hole.radius;
        var top = grid.up(y0 + radius, 1);
        var low = grid.down(y1 - radius, 1);
        if (low < top) {
            top = grid.down((y0 + y1) / 2, 1);
            low = top;
        }
        const framed = [_][4]f64{
            .{ ox0, oy0, ox1, top },
            .{ ox0, low, ox1, oy1 },
            .{ ox0, top, grid.up(x0, 0), low },
            .{ grid.down(x1, 0), top, ox1, low },
        };
        for (framed) |r| {
            if (r[2] <= r[0] or r[3] <= r[1]) continue;
            sn.pushClip(&rectOf(r));
            window_bg.pushCut(sn, &.{hole});
            tiled(w, ws, sn);
            sn.pop();
            sn.pop();
        }
    }

    fn rectOf(r: [4]f64) graphene.Rect {
        return .{
            .f_origin = .{ .f_x = @floatCast(r[0]), .f_y = @floatCast(r[1]) },
            .f_size = .{ .f_width = @floatCast(r[2] - r[0]), .f_height = @floatCast(r[3] - r[1]) },
        };
    }

    fn dispose(self: *Self) callconv(.c) void {
        const w = self.as(gtk.Widget);
        while (w.getFirstChild()) |child| child.unparent();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};

/// Where a widget's corner sits on the screen's pixels, and how many of them a unit is: for
/// placing edges between two pixels rather than inside one.
const PixelGrid = struct {
    origin: [2]f64 = .{ 0, 0 },
    scale: f64 = 1,

    fn of(w: *gtk.Widget) PixelGrid {
        var g: PixelGrid = .{};
        const native = w.getNative() orelse return g;
        if (native.getSurface()) |surface| g.scale = surface.getScale();
        if (@import("../terminal/termview.zig").shotScale()) |scale| g.scale = scale;
        var at: graphene.Point = undefined;
        if (w.computePoint(native.as(gtk.Widget), &.{ .f_x = 0, .f_y = 0 }, &at) == 0) return g;
        var dx: f64 = 0;
        var dy: f64 = 0;
        native.getSurfaceTransform(&dx, &dy);
        g.origin = .{ at.f_x + dx, at.f_y + dy };
        return g;
    }

    /// The pixel edge at or before a place, along x (0) or y (1).
    fn down(g: PixelGrid, v: f64, axis: usize) f64 {
        return @floor((v + g.origin[axis]) * g.scale + 0.001) / g.scale - g.origin[axis];
    }

    /// The pixel edge at or after a place.
    fn up(g: PixelGrid, v: f64, axis: usize) f64 {
        return @ceil((v + g.origin[axis]) * g.scale - 0.001) / g.scale - g.origin[axis];
    }
};

/// How many workspaces are animating, for RENUX_PERF.
pub var ticking: u32 = 0;

/// Places a card at its animated rect. The card takes that size rather than being scaled: scaling
/// makes the GPU redraw every glyph at a new size each frame, which cost 6 to 300 ms a frame.
/// The terminal inside keeps its grid until the size settles, since resizes are debounced.
fn allocateAt(w: *gtk.Widget, r: [4]f64) void {
    const cw: c_int = @intFromFloat(@max(1, @round(r[2])));
    const ch: c_int = @intFromFloat(@max(1, @round(r[3])));
    const fx = @round(r[0]);
    const fy = @round(r[1]);
    if (@abs(r[0] - fx) < 0.01 and @abs(r[1] - fy) < 0.01) {
        var a: gtk.Allocation = .{ .f_x = @intFromFloat(fx), .f_y = @intFromFloat(fy), .f_width = cw, .f_height = ch };
        w.sizeAllocate(&a, -1);
        return;
    }
    // Moving by fractions of a pixel keeps slow glides smooth on HiDPI screens.
    const t = gsk.Transform.new().translate(&.{ .f_x = @floatCast(r[0]), .f_y = @floatCast(r[1]) }) orelse return;
    w.allocate(cw, ch, -1, t);
}

/// How much of the chip's look shows on a card `width` wide, between its full width and the
/// chip's: none for the first part of the trip, all of it a little before the chip's size.
fn faceShown(width: f64, full: f64, chip: f64) f64 {
    if (full <= chip + 1) return 1;
    const gone = std.math.clamp((full - width) / (full - chip), 0, 1);
    const t = std.math.clamp((gone - 0.35) / 0.5, 0, 1);
    return t * t * (3 - 2 * t);
}

/// Two arrows passing each other, on a drop target that swaps.
fn drawSwap(area: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    setRgba(cr, ink, 0.9);
    const cx = @as(f64, @floatFromInt(w)) / 2;
    const cy = @as(f64, @floatFromInt(h)) / 2;
    cr.setLineWidth(2);
    cr.setLineCap(.round);
    cr.setLineJoin(.round);
    cr.moveTo(cx - 14, cy - 5);
    cr.lineTo(cx + 14, cy - 5);
    cr.lineTo(cx + 8, cy - 11);
    cr.moveTo(cx + 14, cy + 5);
    cr.lineTo(cx - 14, cy + 5);
    cr.lineTo(cx - 8, cy + 11);
    cr.stroke();
}

/// How far along a change is at a share `p` of its time, on the curve CSS calls
/// cubic-bezier(x1, y1, x2, y2).
fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, p: f64) f64 {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    // The curve gives time and progress for a parameter t; t is found for this time.
    var t = p;
    for (0..8) |_| {
        const u = 1 - t;
        const x = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t;
        const slope = 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2);
        if (@abs(slope) < 1e-6) break;
        t = std.math.clamp(t - (x - p) / slope, 0, 1);
    }
    const u = 1 - t;
    return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t;
}

test "the chips' curve starts and ends where CSS's does, and is ahead of time in between" {
    try std.testing.expectEqual(@as(f64, 0), bezier(0.2, 0.9, 0.3, 1, 0));
    try std.testing.expectEqual(@as(f64, 1), bezier(0.2, 0.9, 0.3, 1, 1));
    try std.testing.expect(bezier(0.2, 0.9, 0.3, 1, 0.25) > 0.7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), bezier(0, 0, 1, 1, 0.5), 0.001);
}

/// A minimized pane's name, as its title row would show it, such as "zsh ~/Work/bundle".
fn chipTitle(server: *Server, block_id: []const u8, out: *[256]u8) [:0]const u8 {
    const info = server.blockInfo(block_id) orelse return "Pane";
    const program = info.program orelse "";
    // Anything but a shell goes by the title it set.
    if (!TermView.isShell(programs.programName(program))) if (info.title) |t| if (t.len > 0) return std.fmt.bufPrintSentinel(out, "{s}", .{t}, 0) catch "Pane";
    if (info.program == null) return "Pane";
    var buf: [255]u8 = undefined;
    return std.fmt.bufPrintSentinel(out, "{s}", .{programs.displayTitle(&buf, program, info.folder)}, 0) catch "Pane";
}

const setRgba = draw.setRgba;

fn drawGrip(area: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    setRgba(cr, ink, 0.45);
    cr.setLineWidth(1.3);
    cr.setLineCap(.round);
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    for ([_]f64{ 4, 8 }) |o| {
        cr.moveTo(fw - 3, fh - 3 - o);
        cr.lineTo(fw - 3 - o, fh - 3);
        cr.stroke();
    }
}

fn replace(slot: *?[]u8, value: []const u8) void {
    if (slot.*) |old| {
        if (std.mem.eql(u8, old, value)) return;
        gpa.free(old);
    }
    slot.* = gpa.dupe(u8, value) catch null;
}

fn replace2(slot: *[]u8, value: []const u8) void {
    if (std.mem.eql(u8, slot.*, value)) return;
    const copy = gpa.dupe(u8, value) catch return;
    gpa.free(slot.*);
    slot.* = copy;
}

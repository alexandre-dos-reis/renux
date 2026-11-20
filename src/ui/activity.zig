//! The activity panel, like Rex's: what every program on every host is doing, with the ones
//! that need you first. Programs report their state with OSC 7501; a click jumps to the pane.
//!
//! It opens with the keyboard on its first row: J and K (or the arrows) move through the rows,
//! G and Shift+G go to the ends, Enter goes to the row's pane and closes the panel, and Escape
//! closes it. Any other key gives the keyboard back to the pane and leaves the panel open.
const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const glib = @import("glib");
const app_mod = @import("../app/app.zig");
const settings = @import("../settings/settings.zig");
const blockicon = @import("../icons/blockicon.zig");
const programs = @import("../icons/programs.zig");
const Server = @import("../rex/server.zig").Server;
const board = @import("board.zig");
const K = @import("../terminal/keys.zig");
const StatusKind = @import("../rex/server.zig").StatusKind;

const gpa = std.heap.c_allocator;

pub const Grouping = enum { priority, session };

const Item = struct {
    host: *app_mod.Host,
    session_id: []const u8,
    session_label: []const u8,
    window_id: []const u8,
    block_id: []const u8,
    rank: u8,
    /// It finished and hasn't been looked at: the row with the dot. Those come first in Done.
    unseen: bool = false,
};

/// One row's target, kept on the row until it is clicked.
const Target = struct { host: *app_mod.Host, session_id: [:0]u8, window_id: [:0]u8, block_id: [:0]u8 };

pub const Activity = struct {
    app: *app_mod.App,
    panel: *gtk.Widget,
    list: *gtk.ListBox,
    open: bool = false,
    grouping: Grouping = .priority,
    show_idle: bool = false,
    rebuild_source: c_uint = 0,
    /// Keeps "4 min" beside each row up to date while the panel is open.
    clock: c_uint = 0,
    /// What the rows show now, as `lookOf` sums it up.
    look: u64 = 0,
    targets: std.ArrayList(*Target) = .empty,

    pub fn create(a: *app_mod.App) *Activity {
        const act = gpa.create(Activity) catch @panic("out of memory");
        // The panel is always there, see-through and out of reach until its `shown` class
        // fades and slides it in, shadow and all, as the key hints are. A revealer would cut
        // the shadow off for as long as it slides, so the shadow came and went at a stroke.
        const panel = gtk.Box.new(.vertical, 0);
        panel.as(gtk.Widget).addCssClass("activity-panel");
        panel.as(gtk.Widget).setSizeRequest(300, -1);
        panel.as(gtk.Widget).setHalign(.end);
        panel.as(gtk.Widget).setCanTarget(0);
        panel.as(gtk.Widget).setCanFocus(0);

        const head = gtk.Box.new(.horizontal, 6);
        head.as(gtk.Widget).addCssClass("activity-head");
        const title = gtk.Label.new("Activity");
        title.as(gtk.Widget).addCssClass("activity-title");
        title.setXalign(0);
        title.as(gtk.Widget).setHexpand(1);
        head.append(title.as(gtk.Widget));
        const by = gtk.Box.new(.horizontal, 0);
        by.as(gtk.Widget).addCssClass("linked");
        const by_priority = gtk.ToggleButton.newWithLabel("Priority");
        const by_session = gtk.ToggleButton.newWithLabel("Session");
        by_session.setGroup(by_priority);
        by_priority.setActive(1);
        by.append(by_priority.as(gtk.Widget));
        by.append(by_session.as(gtk.Widget));
        head.append(by.as(gtk.Widget));
        panel.append(head.as(gtk.Widget));

        const idle = gtk.CheckButton.newWithLabel("Show idle programs");
        idle.as(gtk.Widget).addCssClass("activity-idle");
        panel.append(idle.as(gtk.Widget));

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("activity-list");
        list.setSelectionMode(.none);
        list.setActivateOnSingleClick(1);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .external);
        scroller.as(gtk.Widget).setVexpand(1);
        scroller.setChild(list.as(gtk.Widget));
        panel.append(scroller.as(gtk.Widget));
        const hint = gtk.Label.new("J K  move     Enter  go     Esc  close");
        hint.as(gtk.Widget).addCssClass("activity-hint");
        panel.append(hint.as(gtk.Widget));

        act.* = .{ .app = a, .panel = panel.as(gtk.Widget), .list = list };
        _ = gtk.ToggleButton.signals.toggled.connect(by_session, *Activity, &groupingToggled, act, .{});
        _ = gtk.CheckButton.signals.toggled.connect(idle, *Activity, &idleToggled, act, .{});
        _ = gtk.ListBox.signals.row_activated.connect(list, *Activity, &rowActivated, act, .{});
        return act;
    }

    pub fn widget(act: *Activity) *gtk.Widget {
        return act.panel;
    }

    pub fn shown(act: *Activity) bool {
        return act.open;
    }

    pub fn toggle(act: *Activity) void {
        act.open = !act.open;
        // Closing keeps the rows it showed while it fades out; they are made again when it
        // next opens.
        if (act.open) act.rebuild();
        if (act.open) act.panel.addCssClass("shown") else act.panel.removeCssClass("shown");
        act.panel.setCanTarget(@intFromBool(act.open));
        act.panel.setCanFocus(@intFromBool(act.open));
        if (act.clock != 0) _ = glib.Source.remove(act.clock);
        act.clock = if (act.open) glib.timeoutAddSeconds(30, &ticked, act) else 0;
        if (act.open) {
            // The keyboard comes with it, on the row of the pane it was in, so the panel opens
            // where you are. A pane with no row here leaves it on the first row of its tab, and
            // a tab with none on the row that most wants looking at.
            act.focusRow(act.homeRow());
        } else if (act.app.workspace) |ws| {
            // The keyboard doesn't stay on a row or a button of a panel that is gone.
            ws.grabFocus();
        }
    }

    fn ticked(data: ?*anyopaque) callconv(.c) c_int {
        const act: *Activity = @ptrCast(@alignCast(data.?));
        act.rebuild();
        return 1;
    }

    /// The row with the keyboard, counted among the rows that go somewhere, or none while the
    /// keyboard is elsewhere.
    pub fn cursor(act: *Activity) ?usize {
        if (!act.open) return null;
        const focus = act.app.window.as(gtk.Window).getFocus() orelse return null;
        const data = gobject.Object.getData(focus.as(gobject.Object), "target") orelse return null;
        const t: *Target = @ptrCast(@alignCast(data));
        return std.mem.indexOfScalar(*Target, act.targets.items, t);
    }

    /// The row to open on: the focused pane's, else the first of the tab on screen, else the
    /// first of all.
    fn homeRow(act: *Activity) usize {
        const tab = act.app.shownTab() orelse return 0;
        const here = if (act.app.workspace) |ws| ws.focusedBlock() else null;
        var in_tab: ?usize = null;
        for (act.targets.items, 0..) |t, i| {
            if (t.host != tab.host or !std.mem.eql(u8, t.session_id, tab.session_id) or !std.mem.eql(u8, t.window_id, tab.window_id)) continue;
            if (here) |id| if (std.mem.eql(u8, t.block_id, id)) return i;
            if (in_tab == null) in_tab = i;
        }
        return in_tab orelse 0;
    }

    /// Puts the keyboard on a row, the last one if there are fewer.
    fn focusRow(act: *Activity, index: usize) void {
        if (act.targets.items.len == 0) return;
        const want = act.targets.items[@min(index, act.targets.items.len - 1)];
        var child = act.list.as(gtk.Widget).getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) {
            if (gobject.Object.getData(c.as(gobject.Object), "target") != @as(?*anyopaque, @ptrCast(want))) continue;
            // The ring that marks the row with the keyboard shows only for keyboard focus.
            act.app.window.as(gtk.Window).setFocusVisible(1);
            _ = c.grabFocus();
            return;
        }
    }

    /// A key while a row has the keyboard. True when it was one of the panel's own.
    pub fn key(act: *Activity, keyval: c_uint, mods: u4) bool {
        const at = act.cursor() orelse return false;
        if (mods & (K.ctrl | K.alt | K.super) != 0) return false;
        const last = act.targets.items.len - 1;
        switch (keyval) {
            'j', 0xff54 => act.focusRow(@min(at + 1, last)), // Down
            'k', 0xff52 => act.focusRow(at -| 1), // Up
            'g', 0xff50 => act.focusRow(0), // Home
            'G', 0xff57 => act.focusRow(last), // End
            0xff0d, 0xff8d => { // Return, Enter on the keypad
                act.go(act.targets.items[at]);
                if (act.open) act.toggle();
            },
            0xff1b => act.toggle(), // Escape
            else => return false,
        }
        return true;
    }

    pub fn setGrouping(act: *Activity, g: Grouping) void {
        act.grouping = g;
        if (!act.shown()) act.toggle() else act.rebuild();
    }

    /// A host is gone: its rows go at once, since each holds a pointer to it.
    pub fn hostRemoved(act: *Activity) void {
        act.rebuild();
    }

    /// Something a program reports changed; the panel catches up on the next idle moment.
    pub fn changed(act: *Activity) void {
        if (!act.shown() or act.rebuild_source != 0) return;
        act.rebuild_source = glib.idleAdd(&rebuildLater, act);
    }

    fn rebuildLater(data: ?*anyopaque) callconv(.c) c_int {
        const act: *Activity = @ptrCast(@alignCast(data.?));
        act.rebuild_source = 0;
        act.rebuild();
        return 0;
    }

    fn groupingToggled(b: *gtk.ToggleButton, act: *Activity) callconv(.c) void {
        act.grouping = if (b.getActive() != 0) .session else .priority;
        act.rebuild();
    }

    fn idleToggled(b: *gtk.CheckButton, act: *Activity) callconv(.c) void {
        act.show_idle = b.getActive() != 0;
        act.rebuild();
    }

    /// Lower ranks need the person more: blocked, then failed, working, done, then idle.
    fn rankOf(info: anytype) u8 {
        if (!info.has_status) return 5;
        return switch (info.status) {
            .blocked => 0,
            .failed => 1,
            .working => 2,
            .done => 3,
            .other => 4,
        };
    }

    /// Everything the rows would show for these items, as one number: which rows, in what
    /// order, and each one's words, time, progress and marks.
    fn lookOf(act: *Activity, items: []const Item) u64 {
        var h = std.hash.Wyhash.init(@backingInt(act.grouping) + @as(u64, @intFromBool(act.show_idle)) * 2);
        const tab = act.app.shownTab();
        for (items) |it| {
            const info = it.host.server.blockInfo(it.block_id) orelse continue;
            h.update(std.mem.asBytes(&@intFromPtr(it.host)));
            inline for (.{ it.block_id, it.session_label, info.task orelse "", info.title orelse "", info.message orelse "", info.program orelse "", info.status_app orelse "", info.folder orelse "" }) |text| {
                h.update(std.mem.asBytes(&text.len));
                h.update(text);
            }
            var when_buf: [32]u8 = undefined;
            h.update(board.ago(&when_buf, info.since));
            const here = if (tab) |t| t.host == it.host and std.mem.eql(u8, t.session_id, it.session_id) and std.mem.eql(u8, t.window_id, it.window_id) else false;
            h.update(&.{ it.rank, @intFromBool(it.unseen), @intFromBool(info.attention), @intFromBool(info.has_status), @backingInt(info.status), @intFromBool(here) });
            const progress: i32 = info.progress orelse -1;
            h.update(std.mem.asBytes(&progress));
        }
        return h.final();
    }

    /// Makes the rows again from what the programs report now. The keyboard stays on the pane
    /// it was on, or on the row that took its place.
    fn rebuild(act: *Activity) void {
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        for (act.app.hosts.items) |h| {
            const s = h.server;
            for (s.sessions.items) |session| {
                const v = s.sessionView(session.id) orelse continue;
                for (v.windows) |w| for (w.layers) |l| for (l.blocks) |b| {
                    const info = s.blockInfo(b.id) orelse continue;
                    const rank = rankOf(info);
                    if (rank >= 4 and !act.show_idle) continue;
                    items.append(gpa, .{ .host = h, .session_id = session.id, .session_label = if (session.label.len > 0) session.label else session.id, .window_id = w.id, .block_id = b.id, .rank = rank, .unseen = rank == 3 and info.attention }) catch return;
                };
            }
        }
        const Sort = struct {
            fn byPriority(_: void, x: Item, y: Item) bool {
                if (x.rank != y.rank) return x.rank < y.rank;
                if (x.unseen != y.unseen) return x.unseen;
                return std.mem.lessThan(u8, x.session_label, y.session_label);
            }
            fn bySession(_: void, x: Item, y: Item) bool {
                const o = std.mem.order(u8, x.session_label, y.session_label);
                if (o != .eq) return o == .lt;
                if (x.rank != y.rank) return x.rank < y.rank;
                return x.unseen and !y.unseen;
            }
        };
        if (act.grouping == .priority) std.mem.sort(Item, items.items, {}, Sort.byPriority) else std.mem.sort(Item, items.items, {}, Sort.bySession);

        // Programs report more often than what a row shows changes, a build's progress above
        // all, and every report comes here. The rows are made again only when one would read
        // differently.
        const look = act.lookOf(items.items);
        if (look == act.look and act.list.as(gtk.Widget).getFirstChild() != null) return;
        act.look = look;

        const had = act.cursor();
        var had_block: [128]u8 = undefined;
        var had_len: usize = 0;
        if (had) |i| {
            const id = act.targets.items[i].block_id;
            had_len = @min(id.len, had_block.len);
            @memcpy(had_block[0..had_len], id[0..had_len]);
        }
        defer if (had) |i| {
            var to = i;
            for (act.targets.items, 0..) |t, n| if (std.mem.eql(u8, t.block_id, had_block[0..had_len])) {
                to = n;
            };
            // With no rows left the keyboard goes back to the pane.
            if (act.targets.items.len == 0) {
                if (act.app.workspace) |ws| ws.grabFocus();
            } else act.focusRow(to);
        };
        const list_w = act.list.as(gtk.Widget);
        while (list_w.getFirstChild()) |c| act.list.remove(c);
        for (act.targets.items) |t| freeTarget(t);
        act.targets.clearRetainingCapacity();

        if (items.items.len == 0) {
            const empty = gtk.Label.new(if (act.show_idle) "No programs are running" else "No programs are reporting activity");
            empty.as(gtk.Widget).addCssClass("dim-label");
            empty.as(gtk.Widget).setMarginTop(24);
            const row = gtk.ListBoxRow.new();
            row.setActivatable(0);
            row.as(gtk.Widget).setFocusable(0);
            row.setChild(empty.as(gtk.Widget));
            act.list.append(row.as(gtk.Widget));
            return;
        }
        var last_heading: []const u8 = "";
        for (items.items) |it| {
            const heading: []const u8 = if (act.grouping == .session) it.session_label else switch (it.rank) {
                0 => "Needs you",
                1 => "Failed",
                2 => "Working",
                3 => "Done",
                else => "Idle",
            };
            if (!std.mem.eql(u8, heading, last_heading)) {
                last_heading = heading;
                const z = gpa.dupeSentinel(u8, heading, 0) catch continue;
                defer gpa.free(z);
                const label = gtk.Label.new(z.ptr);
                label.as(gtk.Widget).addCssClass("activity-heading");
                label.setXalign(0);
                const row = gtk.ListBoxRow.new();
                row.setActivatable(0);
                row.as(gtk.Widget).setFocusable(0);
                row.setChild(label.as(gtk.Widget));
                act.list.append(row.as(gtk.Widget));
            }
            act.addRow(it);
        }
    }

    fn addRow(act: *Activity, it: Item) void {
        const s = it.host.server;
        const info = s.blockInfo(it.block_id) orelse return;
        const line = gtk.Box.new(.horizontal, 10);
        line.append(blockicon.create(s, it.block_id, 18));
        const text = gtk.Box.new(.vertical, 1);
        text.as(gtk.Widget).setHexpand(1);
        var tbuf: [256]u8 = undefined;
        var zbuf: [257]u8 = undefined;
        // What it is working on, as the eye's rows have it: the icon already says which
        // program it is. One that names no task goes by its program and folder; the app that
        // reported, such as claude, says more than the shell it runs in.
        const prog = (if (info.has_status) info.status_app else null) orelse info.program;
        const name = app_mod.App.taskOf(info) orelse programs.displayTitle(&tbuf, prog, info.folder);
        const title = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{name[0..@min(name.len, zbuf.len - 1)]}, 0) catch "program";
        const top = gtk.Label.new(title.ptr);
        top.setXalign(0);
        top.setEllipsize(.end);
        top.as(gtk.Widget).setHexpand(1);
        top.as(gtk.Widget).addCssClass("activity-name");
        // How long it has been so, at the end of the same line.
        var when_buf: [32]u8 = undefined;
        const when = gtk.Label.new(if (info.has_status and info.status != .other) board.ago(&when_buf, info.since).ptr else "");
        when.as(gtk.Widget).addCssClass("activity-when");
        const head = gtk.Box.new(.horizontal, 0);
        head.append(top.as(gtk.Widget));
        head.append(when.as(gtk.Widget));
        text.append(head.as(gtk.Widget));
        var mbuf: [320]u8 = undefined;
        const state = switch (info.status) {
            .blocked => "Needs you",
            .failed => "Failed",
            .working => "Working",
            .done => "Done",
            .other => "Idle",
        };
        const where = if (act.grouping == .priority) it.session_label else "";
        const detail = if (info.message) |m|
            std.fmt.bufPrintSentinel(&mbuf, "{s}{s}{s}", .{ m, if (where.len > 0) " · " else "", where }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&mbuf, "{s}{s}{s}", .{ if (info.has_status) state else "Idle", if (where.len > 0) " · " else "", where }, 0) catch "";
        const bottom = gtk.Label.new(detail.ptr);
        bottom.setXalign(0);
        bottom.setEllipsize(.end);
        bottom.as(gtk.Widget).addCssClass("activity-detail");
        text.append(bottom.as(gtk.Widget));
        // How far along it is, for a program that says, as its card on the board shows.
        if (info.has_status and info.status == .working) if (info.progress) |p| if (p >= 0) {
            const bar = gtk.ProgressBar.new();
            bar.as(gtk.Widget).addCssClass("activity-progress");
            bar.setFraction(@as(f64, @floatFromInt(@min(p, 100))) / 100.0);
            text.append(bar.as(gtk.Widget));
        };
        line.append(text.as(gtk.Widget));
        if (info.attention) {
            const dot = gtk.Box.new(.horizontal, 0);
            dot.as(gtk.Widget).addCssClass("activity-unread");
            dot.as(gtk.Widget).setValign(.center);
            line.append(dot.as(gtk.Widget));
        }
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("activity-row");
        // The rows of the tab on screen are marked, as its row in the sidebar is.
        if (act.app.shownTab()) |tab| {
            if (tab.host == it.host and std.mem.eql(u8, tab.session_id, it.session_id) and std.mem.eql(u8, tab.window_id, it.window_id)) row.as(gtk.Widget).addCssClass("current");
        }
        row.as(gtk.Widget).addCssClass(switch (info.status) {
            .blocked => "blocked",
            .failed => "failed",
            .working => "working",
            .done => "done",
            .other => "idle",
        });
        row.setChild(line.as(gtk.Widget));
        const t = gpa.create(Target) catch return;
        t.* = .{
            .host = it.host,
            .session_id = gpa.dupeSentinel(u8, it.session_id, 0) catch return,
            .window_id = gpa.dupeSentinel(u8, it.window_id, 0) catch return,
            .block_id = gpa.dupeSentinel(u8, it.block_id, 0) catch return,
        };
        act.targets.append(gpa, t) catch return;
        gobject.Object.setData(row.as(gobject.Object), "target", t);
        act.list.append(row.as(gtk.Widget));
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, act: *Activity) callconv(.c) void {
        const data = gobject.Object.getData(row.as(gobject.Object), "target") orelse return;
        act.go(@ptrCast(@alignCast(data)));
    }

    /// Goes to a row's pane.
    fn go(act: *Activity, t: *Target) void {
        // Only a host that is still here; a row can outlive its host by a moment.
        if (std.mem.indexOfScalar(*app_mod.Host, act.app.hosts.items, t.host) == null) return;
        act.app.jumpTo(t.host, t.session_id, t.window_id, t.block_id);
    }

    fn freeTarget(t: *Target) void {
        gpa.free(t.session_id);
        gpa.free(t.window_id);
        gpa.free(t.block_id);
        gpa.destroy(t);
    }
};

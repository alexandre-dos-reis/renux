//! The focused pane's listening ports and the forwards this Renux window carries for its host.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const control = @import("../rex/control.zig");
const forward = @import("../rex/forward.zig");
const json = @import("../util/json.zig");
const Server = @import("../rex/server.zig").Server;
const filterdialog = @import("filterdialog.zig");
const icons = @import("../icons/icons.zig");
const gpa = std.heap.c_allocator;
var dialogs: std.ArrayList(*Ports) = .empty;

pub fn serverGone(server: *Server) void {
    for (dialogs.items) |p| if (p.server == server) {
        p.server = null;
        _ = p.dialog.close();
    };
}

pub fn show(parent: *gtk.Widget, server: *Server, sid: []const u8, bid: ?[]const u8) void {
    const p = gpa.create(Ports) catch return;
    const session = gpa.dupe(u8, sid) catch {
        gpa.destroy(p);
        return;
    };
    const parts = filterdialog.build("Forward Port…", "Port, host:port, or HTTP(S) URL", 560, 480, "goto");
    const status = gtk.Label.new(if (bid != null) "Looking for TCP ports in this pane…" else "Focus a terminal to discover its ports, or type a port above");
    status.setWrap(1);
    status.setXalign(0);
    status.as(gtk.Widget).addCssClass("goto-detail");
    const location = gpa.dupeSentinel(u8, server.url, 0) catch null;
    if (location) |z| {
        defer gpa.free(z);
        const label = gtk.Label.new(z.ptr);
        label.setEllipsize(.middle);
        label.setXalign(0);
        label.as(gtk.Widget).addCssClass("goto-path");
        parts.box.prepend(label.as(gtk.Widget));
    }
    parts.box.insertChildAfter(status.as(gtk.Widget), parts.entry.as(gtk.Widget));
    const forwards = gtk.ListBox.new();
    forwards.as(gtk.Widget).addCssClass("navigation-sidebar");
    forwards.setSelectionMode(.none);
    const heading = gtk.Label.new("Open forwards · this window");
    heading.setXalign(0);
    heading.as(gtk.Widget).addCssClass("activity-heading");
    parts.box.append(heading.as(gtk.Widget));
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.setMaxContentHeight(160);
    scroll.setPropagateNaturalHeight(1);
    scroll.setChild(forwards.as(gtk.Widget));
    parts.box.append(scroll.as(gtk.Widget));
    const close = gtk.Button.newWithLabel("Done");
    close.as(gtk.Widget).addCssClass("pill");
    close.as(gtk.Widget).setHalign(.end);
    parts.box.append(close.as(gtk.Widget));
    p.* = .{ .dialog = parts.dialog, .entry = parts.entry, .list = parts.list, .status = status, .forwards = forwards, .server = server, .sid = session, .bid = if (bid) |b| gpa.dupe(u8, b) catch null else null };
    _ = p.dialog.as(gobject.Object).ref();
    dialogs.append(gpa, p) catch {};
    const typed = gtk.ListBoxRow.new();
    const title = gtk.Label.new("Forward and Open");
    title.setXalign(0);
    typed.setChild(title.as(gtk.Widget));
    p.typed = typed;
    p.typed_label = title;
    typed.as(gtk.Widget).addCssClass("goto-row");
    p.list.append(typed.as(gtk.Widget));
    typed.as(gtk.Widget).setVisible(0);
    _ = gtk.ListBox.signals.row_activated.connect(p.list, *Ports, &Ports.activated, p, .{});
    filterdialog.onQuery(p.entry, *Ports, &Ports.changed, p);
    _ = gtk.SearchEntry.signals.activate.connect(p.entry, *Ports, &Ports.enter, p, .{});
    _ = gtk.SearchEntry.signals.stop_search.connect(p.entry, *Ports, &Ports.stop, p, .{});
    _ = gtk.Button.signals.clicked.connect(close, *Ports, &Ports.done, p, .{});
    _ = adw.Dialog.signals.closed.connect(p.dialog, *Ports, &Ports.closed, p, .{});
    p.renderForwards();
    p.timer = glib.timeoutAdd(250, &Ports.tick, p);
    p.dialog.present(parent);
    _ = p.entry.as(gtk.Widget).grabFocus();
    // Discovery needs API 15; the pane's existing connection stays at its own revision.
    if (p.bid != null) p.ctl = control.Control.open(server.url, "Renux port discovery", @import("../rex/server.zig").version, null, 15, .{
        .ctx = p,
        .on_welcome = Ports.welcome,
        .on_event = Ports.event,
        .on_closed = Ports.disconnected,
    }) catch null;
    if (p.bid != null and p.ctl == null) status.setText("Couldn't connect for port discovery; type a port above.");
}

const Item = struct { row: *gtk.ListBoxRow, target: []u8, haystack: []u8 };
const Close = struct { id: usize };

const Ports = struct {
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    typed: *gtk.ListBoxRow = undefined,
    typed_label: *gtk.Label = undefined,
    status: *gtk.Label,
    forwards: *gtk.ListBox,
    server: ?*Server,
    sid: []u8,
    bid: ?[]u8,
    ctl: ?*control.Control = null,
    items: std.ArrayList(Item) = .empty,
    buttons: std.ArrayList(*Close) = .empty,
    generation: usize = 0,
    timer: c_uint = 0,
    refs: usize = 1,
    gone: bool = false,

    fn unref(p: *Ports) void {
        p.refs -= 1;
        if (p.refs != 0) return;
        for (p.items.items) |it| {
            gpa.free(it.target);
            gpa.free(it.haystack);
        }
        p.items.deinit(gpa);
        for (p.buttons.items) |b| gpa.destroy(b);
        p.buttons.deinit(gpa);
        gpa.free(p.sid);
        if (p.bid) |b| gpa.free(b);
        p.dialog.as(gobject.Object).unref();
        gpa.destroy(p);
    }

    fn welcome(ctx: *anyopaque, ctl: *control.Control, _: control.Welcome) void {
        const p: *Ports = @ptrCast(@alignCast(ctx));
        ctl.call("session.attach", .{ .session_id = p.sid }, control.Callback.of(Ports, p, attached));
    }
    fn event(_: *anyopaque, _: *control.Control, _: []const u8, _: ?json.Value) void {}
    fn disconnected(ctx: *anyopaque, ctl: *control.Control, _: []const u8, _: u16) void {
        const p: *Ports = @ptrCast(@alignCast(ctx));
        p.ctl = null;
        ctl.close();
        if (!p.gone) p.status.setText("Port discovery needs Rex API 15; type a port above.");
    }
    fn attached(p: *Ports, result: control.Result) void {
        if (p.gone) return;
        switch (result) {
            .err => return p.status.setText("Couldn't attach for port discovery; type a port above."),
            .ok => {},
        }
        p.refs += 1;
        p.ctl.?.call("com.superlogical.terminal.ports", .{ .session_id = p.sid, .block_id = p.bid.?, .args = json.Raw{ .text = "{}" } }, control.Callback.of(Ports, p, received));
    }

    fn received(p: *Ports, result: control.Result) void {
        defer p.unref();
        if (p.gone or p.server == null) return;
        const payload = switch (result) {
            .ok => |v| v,
            .err => |err| {
                std.log.warn("port discovery: {s}: {s}", .{ err.code, err.message });
                p.status.setText("This Rex server couldn't list ports. You can still type a port above.");
                return;
            },
        };
        const status = json.str(payload, "status") orelse "partial";
        const truncated = json.boolean(payload, "truncated") orelse false;
        p.status.setText(if (truncated) "Port list truncated; type a missing port above." else if (std.mem.eql(u8, status, "unsupported")) "Port discovery isn't supported here; type a port above." else if (!std.mem.eql(u8, status, "ok")) "Some programs couldn't be inspected; this list may be incomplete." else if (json.array(payload, "ports").len == 0) "No listening TCP ports found. You can type a port above." else "Choose a listening port to forward and open in your browser.");
        for (json.array(payload, "ports")) |port| {
            if (!std.mem.eql(u8, json.str(port, "protocol") orelse "", "tcp")) continue;
            const n = json.int(port, "port") orelse continue;
            if (n < 1 or n > 65535) continue;
            const address = json.str(port, "address") orelse continue;
            const host = if (std.mem.eql(u8, address, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, address, "::")) "::1" else address;
            const ipv6 = std.mem.indexOfScalar(u8, host, ':') != null;
            const target = std.fmt.allocPrint(gpa, "{s}{s}{s}:{d}", .{ if (ipv6) "[" else "", host, if (ipv6) "]" else "", n }) catch continue;
            defer gpa.free(target);
            const pid = json.int(port, "pid");
            const program = for (json.array(payload, "processes")) |process| {
                if (pid != null and json.int(process, "pid") == pid) break json.str(process, "script") orelse json.str(process, "argv0") orelse json.str(process, "name") orelse "";
            } else "";
            p.add(target, program);
        }
        p.filter();
    }

    fn add(p: *Ports, target: []const u8, program: []const u8) void {
        const z = gpa.dupeSentinel(u8, target, 0) catch return;
        defer gpa.free(z);
        const detail = gpa.dupeSentinel(u8, program, 0) catch return;
        defer gpa.free(detail);
        const owned = gpa.dupe(u8, target) catch return;
        const haystack = std.fmt.allocPrint(gpa, "{s} {s}", .{ target, program }) catch {
            gpa.free(owned);
            return;
        };
        for (haystack) |*c| c.* = std.ascii.toLower(c.*);
        p.items.ensureUnusedCapacity(gpa, 1) catch {
            gpa.free(owned);
            gpa.free(haystack);
            return;
        };
        const line = gtk.Box.new(.vertical, 2);
        const label = gtk.Label.new(z.ptr);
        label.setXalign(0);
        line.append(label.as(gtk.Widget));
        const sub = gtk.Label.new(detail.ptr);
        sub.setXalign(0);
        sub.setEllipsize(.middle);
        sub.as(gtk.Widget).addCssClass("goto-detail");
        line.append(sub.as(gtk.Widget));
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("goto-row");
        row.setChild(line.as(gtk.Widget));
        p.list.append(row.as(gtk.Widget));
        p.items.appendAssumeCapacity(.{ .row = row, .target = owned, .haystack = haystack });
    }

    fn filter(p: *Ports) void {
        const query = std.mem.trim(u8, filterdialog.query(p.entry), " \t");
        const valid = if (forward.Target.parse(query)) |_| true else |_| false;
        p.typed.as(gtk.Widget).setVisible(@intFromBool(valid));
        if (valid) {
            const title = std.fmt.allocPrintSentinel(gpa, "Forward and Open {s}", .{query}, 0) catch return;
            defer gpa.free(title);
            p.typed_label.setText(title.ptr);
            p.typed_label.setEllipsize(.end);
        }
        var first: ?*gtk.ListBoxRow = if (valid) p.typed else null;
        for (p.items.items) |it| {
            const match = filterdialog.matchesWords(it.haystack, query);
            it.row.as(gtk.Widget).setVisible(@intFromBool(match));
            if (match and first == null) first = it.row;
        }
        p.list.selectRow(first);
    }

    fn changed(_: *gtk.SearchEntry, p: *Ports) callconv(.c) void {
        p.filter();
    }
    fn enter(_: *gtk.SearchEntry, p: *Ports) callconv(.c) void {
        if (p.list.getSelectedRow()) |row| p.run(row) else p.status.setText("Enter a port from 1–65535 or host:port");
    }
    fn activated(_: *gtk.ListBox, row: *gtk.ListBoxRow, p: *Ports) callconv(.c) void {
        p.run(row);
    }
    fn run(p: *Ports, row: *gtk.ListBoxRow) void {
        const server = p.server orelse return;
        const target = if (row == p.typed) std.mem.trim(u8, filterdialog.query(p.entry), " \t") else for (p.items.items) |it| {
            if (it.row == row) break it.target;
        } else return;
        const parent: ?*gtk.Window = @ptrCast(@alignCast(p.dialog.as(gtk.Widget).getRoot()));
        forward.open(server, p.sid, target, parent);
        p.status.setText("Forward requested. It stays open when this dialog closes.");
        p.renderForwards();
    }
    fn stop(_: *gtk.SearchEntry, p: *Ports) callconv(.c) void {
        _ = p.dialog.close();
    }
    fn done(_: *gtk.Button, p: *Ports) callconv(.c) void {
        _ = p.dialog.close();
    }
    fn closed(_: *adw.Dialog, p: *Ports) callconv(.c) void {
        p.gone = true;
        if (p.ctl) |ctl| {
            p.ctl = null;
            ctl.close();
        }
        if (p.timer != 0) _ = glib.Source.remove(p.timer);
        if (std.mem.indexOfScalar(*Ports, dialogs.items, p)) |i| _ = dialogs.swapRemove(i);
        p.unref();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Ports = @ptrCast(@alignCast(data.?));
        if (p.generation != forward.generation) p.renderForwards();
        return 1;
    }
    fn renderForwards(p: *Ports) void {
        p.generation = forward.generation;
        while (p.forwards.as(gtk.Widget).getFirstChild()) |child| p.forwards.remove(child);
        for (p.buttons.items) |b| gpa.destroy(b);
        p.buttons.clearRetainingCapacity();
        var count: usize = 0;
        for (forward.active.items) |f| {
            if (f.server != p.server) continue;
            count += 1;
            const text = if (f.local_port == 0) std.fmt.allocPrintSentinel(gpa, "{s}:{d} ← starting…", .{ f.host, f.port }, 0) catch continue else std.fmt.allocPrintSentinel(gpa, "{s}:{d} ← 127.0.0.1:{d}", .{ f.host, f.port, f.local_port }, 0) catch continue;
            defer gpa.free(text);
            const line = gtk.Box.new(.horizontal, 10);
            const label = gtk.Label.new(text.ptr);
            label.setSelectable(1);
            label.setXalign(0);
            label.setEllipsize(.middle);
            label.as(gtk.Widget).setHexpand(1);
            line.append(label.as(gtk.Widget));
            const button = icons.button(.close, "Close forward", null);
            const close = gpa.create(Close) catch continue;
            close.* = .{ .id = f.id };
            p.buttons.append(gpa, close) catch {
                gpa.destroy(close);
                continue;
            };
            _ = gtk.Button.signals.clicked.connect(button, *Close, &closeForward, close, .{});
            line.append(button.as(gtk.Widget));
            const row = gtk.ListBoxRow.new();
            row.as(gtk.Widget).addCssClass("goto-row");
            row.setSelectable(0);
            row.setActivatable(0);
            row.setChild(line.as(gtk.Widget));
            p.forwards.append(row.as(gtk.Widget));
        }
        if (count == 0) {
            const label = gtk.Label.new("No forwards on this host");
            label.setXalign(0);
            label.as(gtk.Widget).addCssClass("goto-detail");
            const row = gtk.ListBoxRow.new();
            row.as(gtk.Widget).addCssClass("goto-row");
            row.setSelectable(0);
            row.setActivatable(0);
            row.setChild(label.as(gtk.Widget));
            p.forwards.append(row.as(gtk.Widget));
        }
    }
    fn closeForward(_: *gtk.Button, close: *Close) callconv(.c) void {
        for (forward.active.items) |f| if (f.id == close.id) {
            f.close();
            return;
        };
    }
};

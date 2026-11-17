//! The small client actions that don't need space in the window's action router.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const App = @import("app.zig").App;
const Host = @import("app.zig").Host;
const Server = @import("../rex/server.zig").Server;
const settings = @import("../settings/settings.zig");
const filterdialog = @import("../ui/filterdialog.zig");
const paths = @import("../terminal/paths.zig");
const gpa = std.heap.c_allocator;

pub fn perform(a: *App, action: []const u8) bool {
    const eql = std.mem.eql;
    if (eql(u8, action, "client.quick_look")) {
        quickLook(a);
    } else if (eql(u8, action, "session.refresh")) {
        (a.server orelse return false).refreshSessions();
    } else if (eql(u8, action, "client.host.switch")) {
        switchHost(a);
    } else if (eql(u8, action, "client.host.remove")) {
        removeHost(a);
    } else if (eql(u8, action, "client.tab.mute")) {
        const h = a.current orelse return false;
        const w = a.shownTab() orelse return false;
        if (h.muted_tabs.fetchRemove(w.window_id)) |old| {
            gpa.free(old.key);
            a.toast("Tab unmuted");
        } else {
            const id = gpa.dupe(u8, w.window_id) catch return false;
            h.muted_tabs.put(gpa, id, {}) catch {
                gpa.free(id);
                return false;
            };
            a.toast("Tab muted");
        }
        a.updateBadge();
    } else return false;
    return true;
}

pub fn muted(h: *Host, block: []const u8) bool {
    var views = h.server.views.valueIterator();
    while (views.next()) |v| if (v.*.windowOf(block)) |w| return h.muted_tabs.contains(w.id);
    return false;
}

test "muting one tab only silences blocks placed in that tab" {
    const t = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, t,
        \\{"session_id":"s","windows":[{"window_id":"w1","layers":[{"layer_id":"l1","blocks":[{"block_id":"b1"}]}]},{"window_id":"w2","layers":[{"layer_id":"l2","blocks":[{"block_id":"b2"}]}]}]}
    , .{});
    defer parsed.deinit();
    const v = (try @import("../rex/view.zig").parse(parsed.value)).?;
    defer v.destroy();
    var server: Server = .{ .url = &.{}, .client_label = &.{} };
    defer server.views.deinit(t);
    try server.views.put(t, "s", v);
    var host: Host = .{ .app = undefined, .label = &.{}, .server = &server, .workspace = undefined, .page = undefined, .shot = undefined };
    defer host.muted_tabs.deinit(t);
    try host.muted_tabs.put(t, "w1", {});
    try std.testing.expect(muted(&host, "b1"));
    try std.testing.expect(!muted(&host, "b2"));
    try std.testing.expect(!muted(&host, "closed"));
}

const HostChoice = struct { server: *Server, serial: usize };

const Picker = struct {
    app: *App,
    parts: filterdialog.Parts,
    server: ?*Server = null,
    block: ?[]u8 = null,
    items: std.ArrayList(Item) = .empty,

    const Item = struct {
        row: *gtk.ListBoxRow,
        haystack: []u8,
        host: ?HostChoice,
        url: ?[:0]u8,
        cell: [2]u16,
    };

    fn create(a: *App, title: [:0]const u8, placeholder: [:0]const u8) ?*Picker {
        const p = gpa.create(Picker) catch return null;
        p.* = .{ .app = a, .parts = filterdialog.build(title, placeholder, 560, 460, "goto") };
        filterdialog.onQuery(p.parts.entry, *Picker, &changed, p);
        _ = gtk.SearchEntry.signals.activate.connect(p.parts.entry, *Picker, &enter, p, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(p.parts.entry, *Picker, &stop, p, .{});
        _ = gtk.ListBox.signals.row_activated.connect(p.parts.list, *Picker, &activated, p, .{});
        _ = adw.Dialog.signals.closed.connect(p.parts.dialog, *Picker, &closed, p, .{});
        return p;
    }

    fn add(p: *Picker, title: []const u8, detail: []const u8, kind: [:0]const u8, host: ?HostChoice, url: ?[:0]const u8, cell: [2]u16) void {
        const hay = std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ title, detail, kind }) catch return;
        for (hay) |*c| c.* = std.ascii.toLower(c.*);
        const target = if (url) |u| gpa.dupeSentinel(u8, u, 0) catch {
            gpa.free(hay);
            return;
        } else null;
        p.items.ensureUnusedCapacity(gpa, 1) catch {
            gpa.free(hay);
            if (target) |u| gpa.free(u);
            return;
        };
        // Go to Anything's row, including its spacing, ellipsis, detail and kind chip.
        const line = gtk.Box.new(.horizontal, 10);
        const text = gtk.Box.new(.vertical, 1);
        text.as(gtk.Widget).setHexpand(1);
        const tz = gpa.dupeSentinel(u8, title, 0) catch {
            gpa.free(hay);
            if (target) |u| gpa.free(u);
            return;
        };
        defer gpa.free(tz);
        const dz = gpa.dupeSentinel(u8, detail, 0) catch {
            gpa.free(hay);
            if (target) |u| gpa.free(u);
            return;
        };
        defer gpa.free(dz);
        const name = gtk.Label.new(tz.ptr);
        name.setXalign(0);
        name.setEllipsize(.end);
        text.append(name.as(gtk.Widget));
        const sub = gtk.Label.new(dz.ptr);
        sub.setXalign(0);
        sub.setEllipsize(.end);
        sub.as(gtk.Widget).addCssClass("goto-detail");
        text.append(sub.as(gtk.Widget));
        line.append(text.as(gtk.Widget));
        const chip = gtk.Label.new(kind.ptr);
        chip.as(gtk.Widget).addCssClass("goto-kind");
        chip.as(gtk.Widget).setValign(.center);
        line.append(chip.as(gtk.Widget));
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("goto-row");
        row.setChild(line.as(gtk.Widget));
        p.parts.list.append(row.as(gtk.Widget));
        p.items.appendAssumeCapacity(.{ .row = row, .haystack = hay, .host = host, .url = target, .cell = cell });
    }

    fn present(p: *Picker) void {
        p.filter();
        p.parts.dialog.present(p.app.window.as(gtk.Widget));
        _ = p.parts.entry.as(gtk.Widget).grabFocus();
    }

    fn filter(p: *Picker) void {
        var first: ?*gtk.ListBoxRow = null;
        for (p.items.items) |it| {
            const show = filterdialog.matchesWords(it.haystack, filterdialog.query(p.parts.entry));
            it.row.as(gtk.Widget).setVisible(@intFromBool(show));
            if (show and first == null) first = it.row;
        }
        p.parts.list.selectRow(first);
    }

    fn pick(p: *Picker, row: *gtk.ListBoxRow) void {
        for (p.items.items) |it| if (it.row == row) {
            for (p.app.hosts.items) |h| {
                if (it.host) |choice| {
                    if (h.server != choice.server or h.serial != choice.serial) continue;
                    p.app.selectHost(h);
                    p.app.rebuildSidebar();
                } else if (h.server == p.server) {
                    if (h.workspace.paneOf(p.block.?)) |pane| pane.term.previewLink(it.url.?, it.cell);
                } else continue;
                break;
            }
            _ = p.parts.dialog.close();
            return;
        };
    }

    fn changed(_: *gtk.SearchEntry, p: *Picker) callconv(.c) void {
        p.filter();
    }
    fn enter(_: *gtk.SearchEntry, p: *Picker) callconv(.c) void {
        if (p.parts.list.getSelectedRow()) |r| p.pick(r);
    }
    fn activated(_: *gtk.ListBox, row: *gtk.ListBoxRow, p: *Picker) callconv(.c) void {
        p.pick(row);
    }
    fn stop(_: *gtk.SearchEntry, p: *Picker) callconv(.c) void {
        _ = p.parts.dialog.close();
    }
    fn closed(_: *adw.Dialog, p: *Picker) callconv(.c) void {
        for (p.items.items) |it| {
            gpa.free(it.haystack);
            if (it.url) |u| gpa.free(u);
        }
        p.items.deinit(gpa);
        if (p.block) |b| gpa.free(b);
        gpa.destroy(p);
    }
};

fn switchHost(a: *App) void {
    const p = Picker.create(a, "Switch Host", "Find a host") orelse return;
    for (a.hosts.items) |h| p.add(h.label, h.server.url, "Host", .{ .server = h.server, .serial = h.serial }, null, .{ 0, 0 });
    p.present();
}

fn removeHost(a: *App) void {
    const h = a.current orelse return;
    const Ctx = struct {
        app: *App,
        host: HostChoice,
        fn answered(_: *adw.AlertDialog, response: [*:0]const u8, c: *@This()) callconv(.c) void {
            defer gpa.destroy(c);
            if (!std.mem.eql(u8, std.mem.span(response), "remove")) return;
            for (c.app.hosts.items) |host| if (host.server == c.host.server and host.serial == c.host.serial) {
                for (settings.current.hosts.items, 0..) |saved, n| if (std.mem.eql(u8, saved.url, host.server.url)) {
                    settings.removeHost(n);
                    break;
                };
                c.app.removeHost(host);
                return;
            };
        }
    };
    const c = gpa.create(Ctx) catch return;
    c.* = .{ .app = a, .host = .{ .server = h.server, .serial = h.serial } };
    var buf: [512]u8 = undefined;
    const title = std.fmt.bufPrintSentinel(&buf, "Remove {s}?", .{h.label}, 0) catch "Remove host?";
    const d = adw.AlertDialog.new(title.ptr, "Disconnect and forget this host in Renux. Its sessions keep running on the server.");
    d.addResponse("cancel", "Cancel");
    d.addResponse("remove", "Remove Host");
    d.setResponseAppearance("remove", .destructive);
    d.setDefaultResponse("cancel");
    d.setCloseResponse("cancel");
    _ = adw.AlertDialog.signals.response.connect(d, *Ctx, &Ctx.answered, c, .{});
    d.as(adw.Dialog).present(a.window.as(gtk.Widget));
}

fn quickLook(a: *App) void {
    const tv = (a.workspace orelse return).focusedView() orelse return;
    const targets = tv.screenLinks() catch return;
    defer {
        for (targets) |t| gpa.free(t.url);
        gpa.free(targets);
    }
    if (targets.len == 0) return a.toast("No file paths or web links on this pane's screen");
    const block = gpa.dupe(u8, tv.block_id) catch return;
    const p = Picker.create(a, "Quick Look", "Files and links on this screen") orelse {
        gpa.free(block);
        return;
    };
    p.server = tv.server;
    p.block = block;
    for (targets) |t| {
        const file = std.mem.startsWith(u8, t.url, paths.prefix);
        const path = if (file) t.url[paths.prefix.len..] else t.url;
        const title = if (file) std.fs.path.basename(path) else path;
        p.add(title, if (file) path else "Open in your browser", if (file) "File" else "Link", null, t.url, t.cell);
    }
    p.present();
}

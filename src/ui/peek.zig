//! A small look at a file named in a pane, shown by its path: what the file is, the lines
//! around the one named, a picture, or a PDF's pages. Enter opens the file in an editor
//! in a new pane to the right, and Shift+Enter in a new window. A picture or a PDF goes to
//! the desktop's own viewer. A folder shows what is in it. Ctrl+D brings a file or a folder
//! on another machine to this computer's Downloads folder.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gdk = @import("gdk");
const gobject = @import("gobject");
const cairo = @import("cairo");
const download = @import("../rex/download.zig");
const fetch = @import("fetch.zig");
const preview = @import("preview.zig");
const pdf = @import("pdf.zig");
const highlight = @import("highlight.zig");
const programs = @import("../icons/programs.zig");
const table = @import("../icons/program_icons.zig");
const draw_util = @import("../util/draw.zig");
const settings = @import("../settings/settings.zig");
const stream = @import("../rex/stream.zig");
const Server = @import("../rex/server.zig").Server;

const gpa = std.heap.c_allocator;
/// How many of a file's lines the peek has room for. A picture gets the same room.
const shown_lines = 13;
/// The peek on screen, or about to be. A second one takes its place.
var open: ?*Peek = null;
/// The peek on its way out, on screen while it fades. One at a time.
var closing: ?*Peek = null;
/// How long the way out takes, in milliseconds; `peek-out` in the app's CSS runs as long.
const leave_ms = 200;

/// Shows the peek by `at`, a place in `parent`. `target` is a path as the pane wrote it, with
/// `:LINE` after it when the pane named a line.
pub fn show(parent: *gtk.Widget, at: gdk.Rectangle, server: *Server, sid: []const u8, bid: []const u8, target: []const u8) void {
    if (open) |old| old.dismiss();
    const where = split(target);
    if (where.path.len == 0) return;
    const p = Peek.create(parent, at, server, sid, bid, where.path, where.line) catch return;
    open = p;
    p.transfer = download.Download.start(server, sid, bid, where.path, .{ .ctx = p, .finished = Peek.received, .located = Peek.located }) catch {
        p.fail("Connect to this host to look at the file");
        return;
    };
    // A file nearby arrives before anyone could read "Loading", so the peek waits a moment
    // and opens with the file already in it. A slow one opens empty.
    p.timer = glib.timeoutAdd(120, &Peek.waited, p);
}

/// Takes down the peek of a widget that is going away.
pub fn closeFor(parent: *gtk.Widget) void {
    if (open) |p| if (p.parent == parent) p.leave();
    if (closing) |p| if (p.parent == parent) p.leave();
}

/// The peek's own window while it is on screen, for the development script's pictures.
pub fn visible() ?*gtk.Widget {
    const p = open orelse closing orelse return null;
    const w = p.pop.as(gtk.Widget);
    return if (w.getMapped() != 0) w else null;
}

/// Presses one of the peek's keys, by name; for the development script.
pub fn press(key: []const u8) void {
    const p = open orelse return;
    if (std.mem.eql(u8, key, "escape")) return p.dismiss();
    if (std.mem.eql(u8, key, "download")) return p.save();
    if (std.mem.eql(u8, key, "right") or std.mem.eql(u8, key, "page-down")) {
        _ = p.turnPage(true);
    } else if (std.mem.eql(u8, key, "left") or std.mem.eql(u8, key, "page-up")) {
        _ = p.turnPage(false);
    } else p.run(if (std.mem.eql(u8, key, "shift-enter")) .window else .beside);
}

/// A path and the line named after it, as in `src/main.zig:42`.
pub fn split(target: []const u8) struct { path: []const u8, line: ?u32 } {
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return .{ .path = target, .line = null };
    const line = std.fmt.parseInt(u32, target[colon + 1 ..], 10) catch return .{ .path = target, .line = null };
    return .{ .path = target[0..colon], .line = if (line == 0) null else line };
}

const Kind = enum { loading, text, image, pdf, folder, other, failed };
/// Where the editor goes: a new pane to the right of this one, or a new window.
const How = enum { beside, window };

const Peek = struct {
    pop: *gtk.Popover,
    parent: *gtk.Widget,
    server: *Server,
    sid: []u8,
    bid: []u8,
    /// The path as the pane wrote it, and the whole of it once Rex has found the file.
    path: []u8,
    resolved: ?[]u8 = null,
    line: ?u32,
    /// Where the file's lines or picture go, and what is there now. It keeps one size:
    /// GTK closes a popover whose size changes while it is open.
    body: *gtk.Overlay,
    shown: ?*gtk.Widget = null,
    /// The path under "Loading from", while that is what the peek shows.
    where: ?*gtk.Label = null,
    icon: *gtk.DrawingArea,
    meta: *gtk.Label,
    primary: *gtk.Button,
    primary_label: *gtk.Label,
    second: *gtk.Button,
    /// Brings the file to this computer, when it is on another.
    bring: *gtk.Button,
    transfer: ?*download.Download = null,
    /// What Rex said when the path turned out not to be a file it could read, kept while the
    /// peek asks whether it is a folder.
    refused: ?[]u8 = null,
    listing: bool = false,
    data: ?*glib.Bytes = null,
    texture: ?*gdk.Texture = null,
    /// PDF indices are zero-based; only the latest requested page waits for the worker.
    pages: u32 = 0,
    page: u32 = 0,
    wanted_page: u32 = 0,
    rendering: bool = false,
    picture: ?*gtk.Picture = null,
    kind: Kind = .loading,
    /// A key pressed before Rex had said where the file is, kept until it has.
    waiting: ?How = null,
    /// Runs out when the file is slow to arrive, and the peek opens without it.
    /// Then, once the peek is closing, runs out when it has faded.
    timer: c_uint = 0,
    popped: bool = false,
    refs: usize = 1,
    /// No longer the peek, though it may still be fading on screen.
    gone: bool = false,
    /// Taken off its parent.
    removed: bool = false,
    /// The window the peek is in while it listens there for what closes it.
    root: ?*gtk.Widget = null,
    outside: ?*gtk.GestureClick = null,
    window_changed: c_ulong = 0,

    fn create(parent: *gtk.Widget, at: gdk.Rectangle, server: *Server, sid: []const u8, bid: []const u8, path: []const u8, line: ?u32) !*Peek {
        const p = try gpa.create(Peek);
        errdefer gpa.destroy(p);
        const own_sid = try gpa.dupe(u8, sid);
        errdefer gpa.free(own_sid);
        const own_bid = try gpa.dupe(u8, bid);
        errdefer gpa.free(own_bid);
        const own_path = try gpa.dupe(u8, path);
        errdefer gpa.free(own_path);

        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setSizeRequest(640, -1);

        const head = gtk.Box.new(.horizontal, 9);
        head.as(gtk.Widget).addCssClass("peek-head");
        const icon = fileIcon(path);
        head.append(icon.as(gtk.Widget));
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        const name = label(base, "heading");
        name.setEllipsize(.middle);
        head.append(name.as(gtk.Widget));
        if (line) |n| {
            var buf: [32]u8 = undefined;
            head.append(label(std.fmt.bufPrint(&buf, "line {d}", .{n}) catch "", "dim-label").as(gtk.Widget));
        }
        const meta = label("", "dim-label");
        meta.setEllipsize(.end);
        meta.as(gtk.Widget).setHexpand(1);
        meta.setXalign(1);
        head.append(meta.as(gtk.Widget));
        box.append(head.as(gtk.Widget));

        // What it shows is laid over a blank as tall as the lines it has room for, so that
        // nothing which arrives later can change how big the peek is.
        const body = gtk.Overlay.new();
        body.as(gtk.Widget).addCssClass("peek-body");
        body.as(gtk.Widget).setOverflow(.hidden);
        const blank = gtk.Box.new(.vertical, 0);
        blank.as(gtk.Widget).setSizeRequest(-1, rowHeight() * shown_lines + 16);
        body.setChild(blank.as(gtk.Widget));
        box.append(body.as(gtk.Widget));

        const actions = gtk.Box.new(.horizontal, 8);
        const primary_label = gtk.Label.new("");
        const primary = keyButton(primary_label, "Enter");
        primary.as(gtk.Widget).addCssClass("suggested-action");
        actions.append(primary.as(gtk.Widget));
        const second = keyButton(gtk.Label.new("New Window"), "Shift Enter");
        actions.append(second.as(gtk.Widget));
        const bring = keyButton(gtk.Label.new("Download"), "Ctrl D");
        bring.as(gtk.Widget).setHexpand(1);
        bring.as(gtk.Widget).setHalign(.end);
        actions.append(bring.as(gtk.Widget));
        box.append(actions.as(gtk.Widget));

        const pop = gtk.Popover.new();
        pop.as(gtk.Widget).addCssClass("peek");
        pop.setChild(box.as(gtk.Widget));
        pop.as(gtk.Widget).setParent(parent);
        pop.setPointingTo(&at);
        pop.setPosition(.bottom);
        pop.setHasArrow(0);
        pop.setOffset(0, 4);
        // GTK would close it for a click anywhere else, but at once, with no time to fade.
        // The peek closes itself instead: see `watch`.
        pop.setAutohide(0);
        // Ours to keep until the popover has been taken off its parent.
        _ = pop.as(gobject.Object).ref();

        p.* = .{ .pop = pop, .parent = parent, .server = server, .sid = own_sid, .bid = own_bid, .path = own_path, .line = line, .body = body, .icon = icon, .meta = meta, .primary = primary, .primary_label = primary_label, .second = second, .bring = bring };
        _ = gtk.Popover.signals.closed.connect(pop, *Peek, &closed, p, .{});
        _ = gtk.Button.signals.clicked.connect(primary, *Peek, &clickedBeside, p, .{});
        _ = gtk.Button.signals.clicked.connect(second, *Peek, &clickedWindow, p, .{});
        _ = gtk.Button.signals.clicked.connect(bring, *Peek, &clickedBring, p, .{});
        // The keys are the peek's before a focused button gets them.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Peek, &onKey, p, .{});
        pop.as(gtk.Widget).addController(keys.as(gtk.EventController));
        p.showLoading();
        p.refresh();
        return p;
    }

    fn unref(p: *Peek) void {
        p.refs -= 1;
        if (p.refs != 0) return;
        if (p.data) |b| b.unref();
        if (p.texture) |t| t.as(gobject.Object).unref();
        if (p.resolved) |r| gpa.free(r);
        if (p.refused) |r| gpa.free(r);
        gpa.free(p.sid);
        gpa.free(p.bid);
        gpa.free(p.path);
        p.pop.as(gobject.Object).unref();
        gpa.destroy(p);
    }

    /// On screen, once there is something to show or the wait for it is over.
    fn present(p: *Peek) void {
        if (p.timer != 0) _ = glib.Source.remove(p.timer);
        p.timer = 0;
        if (p.popped or p.gone) return;
        p.popped = true;
        p.pop.popup();
        // Its keys come by way of whatever in it has the keyboard.
        _ = p.pop.as(gtk.Widget).childFocus(.tab_forward);
        p.watch();
    }

    /// Listens for what closes the peek: a click anywhere outside it, or its window being
    /// left for another.
    fn watch(p: *Peek) void {
        const root = (p.parent.getRoot() orelse return).as(gtk.Widget);
        _ = root.as(gobject.Object).ref();
        p.root = root;
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        click.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Peek, &pressedOutside, p, .{});
        root.addController(click.as(gtk.EventController));
        p.outside = click;
        p.window_changed = gobject.Object.signals.notify.connect(root.as(gobject.Object), *Peek, &windowChanged, p, .{ .detail = "is-active" });
    }

    fn unwatch(p: *Peek) void {
        const root = p.root orelse return;
        p.root = null;
        if (p.outside) |click| root.removeController(click.as(gtk.EventController));
        p.outside = null;
        gobject.signalHandlerDisconnect(root.as(gobject.Object), p.window_changed);
        root.as(gobject.Object).unref();
    }

    fn pressedOutside(click: *gtk.GestureClick, _: c_int, _: f64, _: f64, p: *Peek) callconv(.c) void {
        // A click in the peek comes by way of the window too.
        const event = click.as(gtk.EventController).getCurrentEvent() orelse return;
        if (event.getSurface() == p.pop.as(gtk.Native).getSurface()) return;
        // The click that closes the peek does nothing else, as with any popover.
        _ = click.as(gtk.Gesture).setState(.claimed);
        // Closing stops the listening, which can't be done from inside what is heard.
        p.refs += 1;
        _ = glib.idleAdd(&dismissLater, p);
    }

    fn dismissLater(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Peek = @ptrCast(@alignCast(data.?));
        defer p.unref();
        p.dismiss();
        return 0;
    }

    fn windowChanged(_: *gobject.Object, _: *gobject.ParamSpec, p: *Peek) callconv(.c) void {
        const window: *gtk.Window = @ptrCast(@alignCast(p.root orelse return));
        if (window.isActive() == 0) p.dismiss();
    }

    fn waited(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Peek = @ptrCast(@alignCast(data.?));
        p.timer = 0;
        p.present();
        return 0;
    }

    /// Off the screen the way it came, in reverse: it shrinks a little and fades, then goes.
    fn dismiss(p: *Peek) void {
        if (p.gone) return;
        const w = p.pop.as(gtk.Widget);
        // The pane has the keyboard back now, not when the fade is over.
        if (p.parent.getRoot()) |root| if (root.getFocus()) |focus| {
            if (focus.isAncestor(w) != 0) _ = p.parent.grabFocus();
        };
        if (!p.popped or w.getMapped() == 0 or adw.getEnableAnimations(w) == 0) return p.leave();
        p.stop();
        if (closing) |old| old.remove();
        closing = p;
        w.setCanTarget(0);
        w.addCssClass("leaving");
        p.timer = glib.timeoutAdd(leave_ms, &faded, p);
    }

    fn faded(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Peek = @ptrCast(@alignCast(data.?));
        p.timer = 0;
        p.remove();
        return 0;
    }

    /// Off the screen and off its parent at once; the parent may itself be going away.
    fn leave(p: *Peek) void {
        p.stop();
        p.remove();
    }

    /// No longer the peek: nothing more arrives for it, and nothing more closes it.
    fn stop(p: *Peek) void {
        if (p.gone) return;
        p.gone = true;
        if (open == p) open = null;
        if (p.timer != 0) _ = glib.Source.remove(p.timer);
        p.timer = 0;
        if (p.transfer) |d| d.cancel();
        p.unwatch();
    }

    fn remove(p: *Peek) void {
        if (p.removed) return;
        p.removed = true;
        if (closing == p) closing = null;
        if (p.timer != 0) _ = glib.Source.remove(p.timer);
        p.timer = 0;
        p.pop.as(gtk.Widget).unparent();
        // GTK is still using the popover while it says the popover has closed, so the last
        // hold on it is let go of afterwards.
        _ = glib.idleAdd(&release, p);
    }

    fn release(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Peek = @ptrCast(@alignCast(data.?));
        p.unref();
        return 0;
    }

    fn closed(_: *gtk.Popover, p: *Peek) callconv(.c) void {
        p.leave();
    }

    /// Whether the keys start the editor. Until the file has arrived its name decides, so a
    /// key works at once; a file that turns out not to be text goes to the desktop's apps.
    fn edits(p: *const Peek) bool {
        return switch (p.kind) {
            .text => true,
            .image, .pdf, .folder, .other => false,
            .loading => !looksLikeImage(p.path) and !looksLikePdf(p.path),
            // Too big to show here is still a file an editor can open.
            .failed => p.resolved != null,
        };
    }

    /// Whether the file is one the desktop has a viewer of its own for: a picture or a PDF.
    /// Until the file has arrived its name decides.
    fn viewed(p: *const Peek) bool {
        return switch (p.kind) {
            .image, .pdf => true,
            .loading => looksLikeImage(p.path) or looksLikePdf(p.path),
            else => false,
        };
    }

    /// Whether there is something on another machine to bring to this computer.
    fn brings(p: *const Peek) bool {
        return !p.onThisComputer() and !(p.kind == .failed and p.resolved == null);
    }

    /// The buttons say what the keys do for this file.
    fn refresh(p: *Peek) void {
        const missing = p.kind == .failed and p.resolved == null;
        const editing = p.edits();
        const folder = p.kind == .folder;
        var buf: [96]u8 = undefined;
        // A folder on another machine has one thing to be done with it, so Enter does it.
        const text: [:0]const u8 = if (folder) (if (p.onThisComputer()) "Open" else "Download") else if (editing) std.fmt.bufPrintSentinel(&buf, "Open in {s}", .{editorName()}, 0) catch "Open in Editor" else if (p.viewed()) "Open" else "Open With…";
        p.primary_label.setText(text.ptr);
        p.primary.as(gtk.Widget).setSensitive(@intFromBool(!missing));
        offer(p.second, editing);
        offer(p.bring, p.brings() and !folder);
    }

    fn located(ctx: *anyopaque, path: []const u8) void {
        const p: *Peek = @ptrCast(@alignCast(ctx));
        if (p.resolved == null) p.resolved = gpa.dupe(u8, path) catch null;
        // The whole path takes the place of the one the pane wrote.
        if (p.where) |where| if (gpa.dupeSentinel(u8, path, 0)) |z| {
            defer gpa.free(z);
            where.setText(z.ptr);
        } else |_| {};
        p.resumeLater();
    }

    fn resume_(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Peek = @ptrCast(@alignCast(data.?));
        defer p.unref();
        const how = p.waiting orelse return 0;
        p.waiting = null;
        p.run(how);
        return 0;
    }

    fn received(ctx: *anyopaque, bytes: ?[]const u8, detail: []const u8) void {
        const p: *Peek = @ptrCast(@alignCast(ctx));
        p.transfer = null;
        if (p.gone) return;
        // What Rex never found may be a folder, which it doesn't send.
        const data = bytes orelse {
            if (p.resolved == null) p.askFolder(detail) else p.fail(detail);
            return p.resumeLater();
        };
        p.resumeLater();
        var buf: [32]u8 = undefined;
        p.meta.setText(sizeText(&buf, data.len).ptr);
        // Kept for the worker that draws a picture, and for the copy another app is given.
        p.data = glib.Bytes.new(data.ptr, data.len);
        if (preview.imageSize(data)) |size| {
            if (size[0] > 0 and size[1] > 0 and size[0] <= 16384 and size[1] <= 16384 and @as(u64, size[0]) * size[1] <= 32 * 1024 * 1024) return p.draw(.image);
        }
        if (pdf.supported and pdf.isPdf(data)) return p.draw(.pdf);
        if (preview.isText(data)) {
            p.kind = .text;
            p.showLines(data);
        } else {
            p.kind = .other;
            p.setBody(message("No peek for this kind of file"));
        }
        p.refresh();
        p.present();
    }

    const Render = struct {
        peek: *Peek,
        bytes: *glib.Bytes,
        kind: Kind,
        page: u32,
        texture: ?*gdk.Texture = null,
        pages: u32 = 0,
    };

    /// The worker owns a snapshot, never mutable UI state. At most one render runs per peek.
    fn draw(p: *Peek, kind: Kind) void {
        std.debug.assert(!p.rendering);
        const job = gpa.create(Render) catch return p.fail("Not enough memory to show this file");
        job.* = .{ .peek = p, .bytes = p.data.?.ref(), .kind = kind, .page = p.wanted_page };
        p.kind = kind;
        p.rendering = true;
        if (@import("build_options").dev and kind == .pdf) std.log.info("PDF render: page {d}", .{job.page + 1});
        p.refs += 1;
        const task = gio.Task.new(p.pop.as(gobject.Object), null, &decoded, job);
        task.setTaskData(job, null);
        task.runInThread(&decode);
        task.unref();
    }

    fn decode(task: *gio.Task, _: *gobject.Object, ctx: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const job: *Render = @ptrCast(@alignCast(ctx.?));
        if (job.kind == .pdf) {
            // Twice the room the peek has, so the page is sharp on a dense screen.
            if (pdf.renderPage(job.bytes, job.page, 1600, 1200)) |page| {
                job.texture = page.texture;
                job.pages = page.pages;
            }
        } else job.texture = gdk.Texture.newFromBytes(job.bytes, null);
        task.returnBoolean(1);
    }

    fn turnPage(p: *Peek, forward: bool) bool {
        if (p.kind != .pdf) return false;
        const wanted = pdf.nextPage(p.wanted_page, p.pages, forward);
        if (wanted == p.wanted_page) return true;
        p.wanted_page = wanted;
        if (!p.rendering) p.draw(.pdf);
        return true;
    }

    fn decoded(_: ?*gobject.Object, result: *gio.AsyncResult, ctx: ?*anyopaque) callconv(.c) void {
        const job: *Render = @ptrCast(@alignCast(ctx.?));
        const p = job.peek;
        defer {
            if (job.texture) |t| t.as(gobject.Object).unref();
            job.bytes.unref();
            gpa.destroy(job);
            p.unref();
        }
        _ = @as(*gio.Task, @ptrCast(result)).propagateBoolean(null);
        p.rendering = false;
        if (p.gone) return;
        if (job.kind == .pdf and job.texture != null) {
            p.pages = job.pages;
            // Held keys change only the target. Skip a stale result and draw that target next.
            if (job.page != p.wanted_page) return p.draw(.pdf);
        }
        if (job.texture) |texture| {
            if (p.texture) |old| old.as(gobject.Object).unref();
            p.texture = texture;
            job.texture = null;
            p.page = job.page;
            if (p.picture) |picture| {
                picture.setPaintable(texture.as(gdk.Paintable));
            } else {
                const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
                picture.setCanShrink(1);
                picture.setContentFit(.contain);
                picture.as(gtk.Widget).addCssClass("peek-picture");
                p.picture = picture;
                p.setBody(picture.as(gtk.Widget));
            }
            var buf: [96]u8 = undefined;
            var size: [32]u8 = undefined;
            const bytes = sizeText(&size, p.data.?.getSize());
            const text = if (p.kind == .pdf)
                std.fmt.bufPrintSentinel(&buf, "page {d} of {d} · {s}", .{ p.page + 1, p.pages, bytes }, 0) catch ""
            else
                std.fmt.bufPrintSentinel(&buf, "{d} × {d} · {s}", .{ texture.getWidth(), texture.getHeight(), bytes }, 0) catch "";
            p.meta.setText(text.ptr);
        } else {
            const what: []const u8 = if (p.kind == .pdf) "This PDF couldn't be read" else "This picture couldn't be read";
            p.kind = .other;
            p.picture = null;
            p.setBody(message(what));
        }
        p.refresh();
        p.present();
    }

    fn askFolder(p: *Peek, detail: []const u8) void {
        p.refused = gpa.dupe(u8, detail) catch null;
        p.listing = true;
        p.refs += 1;
        p.server.listDir(p.sid, p.bid, p.path, true, .{ .ctx = p, .done = listed });
    }

    fn listed(ctx: *anyopaque, path: []const u8, names: []const []const u8, files: []const bool, readable: bool) void {
        const p: *Peek = @ptrCast(@alignCast(ctx));
        defer p.unref();
        p.listing = false;
        if (p.gone) return;
        defer p.resumeLater();
        if (!readable) return p.fail(p.refused orelse "Can't read this file: check the path and permissions");
        p.resolved = gpa.dupe(u8, path) catch null;
        p.kind = .folder;
        p.icon.setDrawFunc(&drawFolder, null, null);
        p.icon.as(gtk.Widget).queueDraw();
        var buf: [32]u8 = undefined;
        // A listing as long as Rex was asked for may not be all of it.
        const more = if (names.len >= Server.dir_limit) "+" else "";
        const count: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, "{d}{s} {s}", .{ names.len, more, if (names.len == 1) "item" else "items" }, 0) catch "";
        p.meta.setText(count.ptr);
        p.showFolder(names, files, more);
        p.refresh();
        p.present();
    }

    /// What is in a folder: its folders, then its files, each in name order.
    fn showFolder(p: *Peek, names: []const []const u8, files: []const bool, more: []const u8) void {
        if (names.len == 0) return p.setBody(message("Empty folder"));
        const Entry = struct { name: []const u8, file: bool };
        const entries = gpa.alloc(Entry, names.len) catch return p.setBody(message("Not enough memory to show this folder"));
        defer gpa.free(entries);
        for (entries, names, files) |*e, name, file| e.* = .{ .name = name, .file = file };
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, x: Entry, y: Entry) bool {
                if (x.file != y.file) return !x.file;
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.less);
        const rows = gtk.Box.new(.vertical, 0);
        // The last line says how many there was no room for.
        const room = if (entries.len > shown_lines) shown_lines - 1 else entries.len;
        for (entries[0..room]) |e| {
            const row = gtk.Box.new(.horizontal, 10);
            row.as(gtk.Widget).addCssClass("peek-row");
            row.as(gtk.Widget).addCssClass("peek-entry");
            const image = gtk.Image.newFromIconName(if (e.file) "text-x-generic-symbolic" else "folder-symbolic");
            image.setPixelSize(14);
            image.as(gtk.Widget).addCssClass("dim-label");
            row.append(image.as(gtk.Widget));
            const name = label(e.name, "monospace");
            name.setEllipsize(.middle);
            name.as(gtk.Widget).setHexpand(1);
            row.append(name.as(gtk.Widget));
            rows.append(row.as(gtk.Widget));
        }
        if (entries.len > room) {
            var buf: [48]u8 = undefined;
            const rest = label(std.fmt.bufPrint(&buf, "and {d}{s} more", .{ entries.len - room, more }) catch "", "dim-label");
            rest.as(gtk.Widget).addCssClass("peek-row");
            rest.as(gtk.Widget).addCssClass("peek-entry");
            rows.append(rest.as(gtk.Widget));
        }
        rows.as(gtk.Widget).addCssClass("peek-rows");
        rows.as(gtk.Widget).setValign(.start);
        p.setBody(rows.as(gtk.Widget));
    }

    fn fail(p: *Peek, detail: []const u8) void {
        p.kind = .failed;
        if (gpa.dupeSentinel(u8, detail, 0)) |text| {
            defer gpa.free(text);
            p.setBody(message(text));
        } else |_| {}
        p.refresh();
        p.present();
    }

    fn setBody(p: *Peek, child: *gtk.Widget) void {
        if (p.shown) |old| p.body.removeOverlay(old);
        p.where = null;
        p.shown = child;
        // What arrives while the peek is on screen fades in over what was there.
        if (p.popped) child.addCssClass("peek-arrived");
        p.body.addOverlay(child);
    }

    /// Until the file is here the peek says where it is coming from: the host, and the path
    /// there, which is the pane's own until Rex has said where the file is.
    fn showLoading(p: *Peek) void {
        const box = gtk.Box.new(.vertical, 6);
        box.as(gtk.Widget).setHalign(.center);
        box.as(gtk.Widget).setValign(.center);
        const row = gtk.Box.new(.horizontal, 10);
        row.as(gtk.Widget).setHalign(.center);
        row.append(adw.Spinner.new().as(gtk.Widget));
        var buf: [200]u8 = undefined;
        const text: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, "Loading from {s}", .{hostLabel(p.server.url)}, 0) catch "Loading…";
        row.append(gtk.Label.new(text.ptr).as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        const where = label(p.path, "peek-path");
        where.setXalign(0.5);
        where.setEllipsize(.middle);
        where.setMaxWidthChars(64);
        box.append(where.as(gtk.Widget));
        p.setBody(box.as(gtk.Widget));
        p.where = where;
    }

    /// The named line with the lines around it, or the file's first ones.
    fn showLines(p: *Peek, data: []const u8) void {
        if (data.len == 0) return p.setBody(message("Empty file"));
        const rows = gtk.Box.new(.vertical, 0);
        const want = excerpt(data, p.line);
        var lines: [shown_lines][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        var n: u32 = 0;
        while (it.next()) |raw| {
            n += 1;
            // What follows a file's last newline isn't a line of its own.
            if (raw.len == 0 and it.peek() == null and n > 1) break;
            if (n < want.first) continue;
            if (n > want.last or count == lines.len) break;
            lines[count] = std.mem.trimEnd(u8, raw, "\r");
            count += 1;
        }
        // Deep inside a function the lines start far to the right, so the indent they all
        // share is left out.
        const indent = sharedIndent(lines[0..count]);
        const lang = if (kindOf(p.path)) |k| k.lang else .none;
        const tints = p.colors();
        for (lines[0..count], want.first..) |text, number| {
            const row = gtk.Box.new(.horizontal, 14);
            row.as(gtk.Widget).addCssClass("peek-row");
            if (p.line != null and p.line.? == number) row.as(gtk.Widget).addCssClass("peek-target");
            var buf: [16]u8 = undefined;
            const gutter = label(std.fmt.bufPrint(&buf, "{d}", .{number}) catch "", "dim-label");
            gutter.as(gtk.Widget).addCssClass("monospace");
            gutter.setWidthChars(5);
            gutter.setXalign(1);
            row.append(gutter.as(gtk.Widget));
            const code = label("", "monospace");
            const shown = clip(text[@min(indent, text.len)..], 300);
            if (highlight.markup(gpa, shown, lang, tints)) |marked| {
                defer gpa.free(marked);
                code.setMarkup(marked.ptr);
            } else |_| {}
            code.setEllipsize(.end);
            code.as(gtk.Widget).setHexpand(1);
            row.append(code.as(gtk.Widget));
            rows.append(row.as(gtk.Widget));
        }
        rows.as(gtk.Widget).addCssClass("peek-rows");
        rows.as(gtk.Widget).setValign(.start);
        p.setBody(rows.as(gtk.Widget));
    }

    /// The pane's own colors for strings, numbers and keywords: the peek is drawn on the
    /// terminal's background, where those are made to be read.
    fn colors(p: *const Peek) highlight.Colors {
        const theme = p.server.windowColors();
        const palette: *const [256]u32 = if (theme) |*t| if (t.palette) |*own| own else &stream.builtin_palette else &stream.builtin_palette;
        return .{ .string = palette[2], .number = palette[3], .keyword = palette[5], .builtin = palette[6] };
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, p: *Peek) callconv(.c) c_int {
        const bits: u32 = @bitCast(state);
        const shift = bits & 1 != 0;
        const ctrl = bits & 4 != 0;
        if (ctrl and (keyval == gdk.KEY_d or keyval == gdk.KEY_D)) {
            p.save();
            return 1;
        }
        switch (keyval) {
            0xff0d, 0xff8d, 0xfe34 => p.run(if (shift) .window else .beside),
            0xff1b => p.dismiss(),
            gdk.KEY_Right, gdk.KEY_Page_Down => return @intFromBool(p.turnPage(true)),
            gdk.KEY_Left, gdk.KEY_Page_Up => return @intFromBool(p.turnPage(false)),
            else => return 0,
        }
        return 1;
    }

    fn clickedBeside(_: *gtk.Button, p: *Peek) callconv(.c) void {
        p.run(.beside);
    }
    fn clickedWindow(_: *gtk.Button, p: *Peek) callconv(.c) void {
        p.run(.window);
    }
    fn clickedBring(_: *gtk.Button, p: *Peek) callconv(.c) void {
        p.save();
    }

    /// Starts bringing the file or folder to this computer's Downloads folder, and closes.
    fn save(p: *Peek) void {
        if (p.gone or !p.server.isLive() or !p.brings()) return;
        fetch.start(p.parent, p.server, p.sid, p.bid, p.resolved orelse p.path);
        p.dismiss();
    }

    fn run(p: *Peek, how: How) void {
        if (p.gone or !p.server.isLive()) return;
        if (p.kind == .failed and p.resolved == null) return;
        if (p.kind == .folder and !p.onThisComputer()) return p.save();
        const editing = p.edits();
        // A key pressed before what it needs has arrived is kept, and acted on when it has.
        if (!p.ready(editing)) {
            p.waiting = how;
            return;
        }
        // Closing frees the peek once nothing else holds it, so it is held until this is done.
        p.refs += 1;
        defer p.unref();
        const parent = p.parent;
        if (editing) p.edit(how) else p.openOutside();
        p.dismiss();
        if (!editing) return;
        // The new pane takes the keyboard; until it is there the old one keeps it.
        _ = parent.grabFocus();
    }

    /// Whether a key can be acted on yet. An editor in a new pane needs the file's whole
    /// path, as its shell may start in another folder, where a path such as src/main.zig
    /// names nothing; Rex says where the file is a moment after the download begins. An app
    /// on this computer needs the file itself, or all of a copy of it.
    fn ready(p: *const Peek, editing: bool) bool {
        // Not until it is known whether this is a folder.
        if (p.listing) return false;
        if (p.transfer == null) return true;
        if (editing) return p.resolved != null or p.path[0] == '/' or p.path[0] == '~';
        return p.resolved != null and p.onThisComputer();
    }

    fn onThisComputer(p: *const Peek) bool {
        return std.mem.startsWith(u8, p.server.url, "unix://");
    }

    /// Acts on a key that was kept, once this turn of the main loop is over: what brings the
    /// news may still be in the middle of using the peek.
    fn resumeLater(p: *Peek) void {
        if (p.waiting == null) return;
        p.refs += 1;
        _ = glib.idleAdd(&resume_, p);
    }

    /// Hands the file to the desktop: the app it opens pictures with, or its list of apps for
    /// a file there is nothing to show of here.
    fn openOutside(p: *Peek) void {
        const file = p.fileHere() orelse return;
        defer file.unref();
        const launcher = gtk.FileLauncher.new(file);
        defer launcher.unref();
        // A folder goes to the desktop's files app.
        launcher.setAlwaysAsk(@intFromBool(!p.viewed() and p.kind != .folder));
        const window: ?*gtk.Window = if (p.parent.getRoot()) |root| @ptrCast(@alignCast(root)) else null;
        launcher.launch(window, null, null, null);
    }

    /// The file as an app on this computer can open it: the file itself when the pane is on
    /// this computer, and otherwise a copy under its own name, in a folder of its own that
    /// only this user can read. The copy is left for the system to clear away, as the app
    /// may go on reading it.
    fn fileHere(p: *Peek) ?*gio.File {
        if (p.onThisComputer()) if (p.resolved) |whole| {
            const z = gpa.dupeSentinel(u8, whole, 0) catch return null;
            defer gpa.free(z);
            return gio.File.newForPath(z.ptr);
        };
        const data = p.data orelse return null;
        const dir = glib.Dir.makeTmp("renux-peek-XXXXXX", null) orelse return null;
        defer glib.free(dir);
        const base = if (std.mem.lastIndexOfScalar(u8, p.path, '/')) |slash| p.path[slash + 1 ..] else p.path;
        const to = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ std.mem.span(dir), base }, 0) catch return null;
        defer gpa.free(to);
        const raw = data.getData(null) orelse "";
        if (glib.fileSetContents(to.ptr, raw, @intCast(data.getSize()), null) == 0) return null;
        return gio.File.newForPath(to.ptr);
    }

    /// Starts the editor by typing its command at the shell of a new pane to the right of
    /// this one, or of a new window.
    fn edit(p: *Peek, how: How) void {
        const cmd = command(gpa, settings.current.editor_command, p.resolved orelse p.path, p.line) catch return;
        defer gpa.free(cmd);
        // Without the whole path, the folder the pane is in is where the path makes sense.
        const folder: ?[]const u8 = if (p.resolved == null and p.path[0] != '/' and p.path[0] != '~') if (p.server.blockInfo(p.bid)) |info| info.folder else null else null;
        var buf: [4096]u8 = undefined;
        const dir = if (folder) |f| Server.folderPath(&buf, f) else null;
        const typed = if (dir) |d| blk: {
            const there = quoted(gpa, d) catch return;
            defer gpa.free(there);
            break :blk std.mem.concat(gpa, u8, &.{ "cd ", there, " && ", cmd, "\r" }) catch return;
        } else std.mem.concat(gpa, u8, &.{ cmd, "\r" }) catch return;
        defer gpa.free(typed);
        switch (how) {
            .beside => p.server.newSplitRunning(p.sid, p.bid, true, typed),
            .window => p.server.newWindowRunning(p.sid, typed),
        }
    }
};

fn label(text: []const u8, class: [:0]const u8) *gtk.Label {
    const l = gtk.Label.new("");
    if (gpa.dupeSentinel(u8, text, 0)) |z| {
        defer gpa.free(z);
        l.setText(z.ptr);
    } else |_| {}
    l.setXalign(0);
    l.as(gtk.Widget).addCssClass(class.ptr);
    return l;
}

/// The name the person gave a host, or one made from its address.
fn hostLabel(url: []const u8) []const u8 {
    for (settings.current.hosts.items) |h| if (std.mem.eql(u8, h.url, url)) return h.label;
    return settings.labelFor(url);
}

fn message(text: []const u8) *gtk.Widget {
    const l = label(text, "dim-label");
    l.setWrap(1);
    l.as(gtk.Widget).addCssClass("peek-message");
    l.as(gtk.Widget).setValign(.center);
    return l.as(gtk.Widget);
}

/// Shows a button or leaves its place empty. A hidden button would give its room up, and the
/// peek must keep its size.
fn offer(button: *gtk.Button, yes: bool) void {
    const w = button.as(gtk.Widget);
    w.setOpacity(if (yes) 1 else 0);
    w.setSensitive(@intFromBool(yes));
    w.setCanTarget(@intFromBool(yes));
    w.setFocusable(@intFromBool(yes));
}

/// A button that says what it does and which key does the same.
fn keyButton(text: *gtk.Label, key: [:0]const u8) *gtk.Button {
    const box = gtk.Box.new(.horizontal, 10);
    box.append(text.as(gtk.Widget));
    const cap = gtk.Label.new(key.ptr);
    cap.as(gtk.Widget).addCssClass("peek-key");
    box.append(cap.as(gtk.Widget));
    const button = gtk.Button.new();
    button.setChild(box.as(gtk.Widget));
    return button;
}

/// The logo of the language a file is written in, by its name, or a plain page.
fn fileIcon(path: []const u8) *gtk.DrawingArea {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(18);
    area.setContentHeight(18);
    area.as(gtk.Widget).setValign(.center);
    const found = if (kindOf(path)) |k| if (k.icon.len > 0) programs.iconFor(null, k.icon) else null else null;
    const icon: ?*anyopaque = if (found) |i| @ptrCast(@constCast(i)) else null;
    area.setDrawFunc(&drawIcon, icon, null);
    return area;
}

/// What a file's name says it is: the icon that stands for it, by the icon's own name, and
/// how its text is read. Null for a name that says nothing.
const FileKind = struct { icon: []const u8, lang: highlight.Lang };

fn kindOf(path: []const u8) ?FileKind {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    if (std.ascii.eqlIgnoreCase(base, "Dockerfile")) return .{ .icon = "docker", .lang = .hash };
    if (std.ascii.eqlIgnoreCase(base, "Makefile")) return .{ .icon = "", .lang = .hash };
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    var buf: [12]u8 = undefined;
    const ext = base[dot + 1 ..];
    if (ext.len == 0 or ext.len > buf.len) return null;
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return kinds.get(buf[0..ext.len]);
}

const kinds = std.StaticStringMap(FileKind).initComptime(.{
    .{ "zig", FileKind{ .icon = "zig", .lang = .zig } },
    .{ "zon", FileKind{ .icon = "zig", .lang = .zig } },
    .{ "py", FileKind{ .icon = "python", .lang = .python } },
    .{ "go", FileKind{ .icon = "go", .lang = .go } },
    .{ "rs", FileKind{ .icon = "rust", .lang = .rust } },
    .{ "lua", FileKind{ .icon = "lua", .lang = .lua } },
    .{ "rb", FileKind{ .icon = "ruby", .lang = .ruby } },
    .{ "php", FileKind{ .icon = "php", .lang = .c } },
    .{ "js", FileKind{ .icon = "nodedotjs", .lang = .js } },
    .{ "mjs", FileKind{ .icon = "nodedotjs", .lang = .js } },
    .{ "cjs", FileKind{ .icon = "nodedotjs", .lang = .js } },
    .{ "ts", FileKind{ .icon = "nodedotjs", .lang = .js } },
    .{ "jsx", FileKind{ .icon = "nodedotjs", .lang = .js } },
    .{ "tsx", FileKind{ .icon = "nodedotjs", .lang = .js } },
    .{ "c", FileKind{ .icon = "cplusplus", .lang = .c } },
    .{ "h", FileKind{ .icon = "cplusplus", .lang = .c } },
    .{ "cc", FileKind{ .icon = "cplusplus", .lang = .c } },
    .{ "cpp", FileKind{ .icon = "cplusplus", .lang = .c } },
    .{ "hpp", FileKind{ .icon = "cplusplus", .lang = .c } },
    .{ "java", FileKind{ .icon = "openjdk", .lang = .c } },
    .{ "kt", FileKind{ .icon = "kotlin", .lang = .c } },
    .{ "swift", FileKind{ .icon = "swift", .lang = .c } },
    .{ "dart", FileKind{ .icon = "dart", .lang = .c } },
    .{ "hs", FileKind{ .icon = "haskell", .lang = .dash } },
    .{ "sh", FileKind{ .icon = "gnubash", .lang = .shell } },
    .{ "bash", FileKind{ .icon = "gnubash", .lang = .shell } },
    .{ "zsh", FileKind{ .icon = "zsh", .lang = .shell } },
    .{ "fish", FileKind{ .icon = "fishshell", .lang = .shell } },
    .{ "ex", FileKind{ .icon = "elixir", .lang = .hash } },
    .{ "exs", FileKind{ .icon = "elixir", .lang = .hash } },
    .{ "erl", FileKind{ .icon = "erlang", .lang = .none } },
    .{ "ml", FileKind{ .icon = "ocaml", .lang = .none } },
    .{ "jl", FileKind{ .icon = "julia", .lang = .hash } },
    .{ "r", FileKind{ .icon = "r", .lang = .hash } },
    .{ "pl", FileKind{ .icon = "perl", .lang = .hash } },
    .{ "tf", FileKind{ .icon = "terraform", .lang = .hash } },
    .{ "nix", FileKind{ .icon = "nixos", .lang = .hash } },
    .{ "ipynb", FileKind{ .icon = "jupyter", .lang = .data } },
    .{ "sql", FileKind{ .icon = "postgresql", .lang = .dash } },
    .{ "cmake", FileKind{ .icon = "cmake", .lang = .hash } },
    .{ "gradle", FileKind{ .icon = "gradle", .lang = .slash } },
    .{ "json", FileKind{ .icon = "", .lang = .data } },
    .{ "yaml", FileKind{ .icon = "", .lang = .hash } },
    .{ "yml", FileKind{ .icon = "", .lang = .hash } },
    .{ "toml", FileKind{ .icon = "", .lang = .hash } },
    .{ "ini", FileKind{ .icon = "", .lang = .hash } },
    .{ "conf", FileKind{ .icon = "", .lang = .hash } },
    .{ "css", FileKind{ .icon = "", .lang = .data } },
});

fn drawIcon(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    const size: f64 = @floatFromInt(width);
    if (data) |d| {
        const icon: *const table.Icon = @ptrCast(@alignCast(d));
        // Light text means a dark canvas.
        const dark = ink.f_red + ink.f_green + ink.f_blue > 1.5;
        return programs.drawTile(cr, icon, 0, 0, size, dark, if (dark) 0x3a3a3c else 0xdedee2, draw_util.rgb(ink));
    }
    // A page with its corner folded.
    cr.setSourceRgba(ink.f_red, ink.f_green, ink.f_blue, 0.75);
    cr.setLineWidth(1.4);
    const fold = size * 0.3;
    cr.moveTo(size * 0.22, size * 0.1);
    cr.lineTo(size * 0.78 - fold, size * 0.1);
    cr.lineTo(size * 0.78, size * 0.1 + fold);
    cr.lineTo(size * 0.78, size * 0.9);
    cr.lineTo(size * 0.22, size * 0.9);
    cr.closePath();
    cr.moveTo(size * 0.78 - fold, size * 0.1);
    cr.lineTo(size * 0.78 - fold, size * 0.1 + fold);
    cr.lineTo(size * 0.78, size * 0.1 + fold);
    cr.stroke();
}

/// A folder, in the same line as the page.
fn drawFolder(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, _: c_int, _: ?*anyopaque) callconv(.c) void {
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    const size: f64 = @floatFromInt(width);
    cr.setSourceRgba(ink.f_red, ink.f_green, ink.f_blue, 0.75);
    cr.setLineWidth(1.4);
    cr.moveTo(size * 0.1, size * 0.2);
    cr.lineTo(size * 0.4, size * 0.2);
    cr.lineTo(size * 0.5, size * 0.34);
    cr.lineTo(size * 0.9, size * 0.34);
    cr.lineTo(size * 0.9, size * 0.82);
    cr.lineTo(size * 0.1, size * 0.82);
    cr.closePath();
    cr.stroke();
}

fn looksLikeImage(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "tif", "tiff", "avif", "heic" }) |ext| {
        if (std.ascii.eqlIgnoreCase(path[dot + 1 ..], ext)) return true;
    }
    return false;
}

fn looksLikePdf(path: []const u8) bool {
    return pdf.supported and std.ascii.endsWithIgnoreCase(path, ".pdf");
}

/// The editor as the button names it: the command's first word, without its folder.
fn editorName() []const u8 {
    var words = std.mem.tokenizeScalar(u8, settings.current.editor_command, ' ');
    const first = words.next() orelse return "Editor";
    return if (std.mem.lastIndexOfScalar(u8, first, '/')) |slash| first[slash + 1 ..] else first;
}

/// The lines to show, counted from 1: as many as the peek has room for, with the named line
/// in the middle or as near it as the file's two ends allow. The first ones when no line is
/// named, or the one named isn't in the file.
fn excerpt(data: []const u8, line: ?u32) struct { first: u32, last: u32 } {
    var count: u32 = 1;
    for (data) |c| {
        if (c == '\n') count += 1;
    }
    if (data.len > 0 and data[data.len - 1] == '\n') count -= 1;
    const n = line orelse return .{ .first = 1, .last = shown_lines };
    if (n > count) return .{ .first = 1, .last = shown_lines };
    const last = @min(count, @max(1, n -| shown_lines / 2) + shown_lines - 1);
    return .{ .first = @max(1, (last + 1) -| shown_lines), .last = last };
}

/// How tall one line of a file is in the peek, in the font and spacing it has there.
fn rowHeight() c_int {
    const row = gtk.Box.new(.horizontal, 14);
    _ = row.as(gobject.Object).refSink();
    defer row.as(gobject.Object).unref();
    row.as(gtk.Widget).addCssClass("peek-row");
    row.append(label("0", "monospace").as(gtk.Widget));
    var least: c_int = 0;
    var natural: c_int = 0;
    row.as(gtk.Widget).measure(.vertical, -1, &least, &natural, null, null);
    return @max(natural, 14);
}

/// How many spaces or tabs every line that has text starts with.
fn sharedIndent(lines: []const []const u8) usize {
    var shared: ?usize = null;
    for (lines) |text| {
        const start = std.mem.indexOfNone(u8, text, " \t") orelse continue;
        shared = @min(shared orelse start, start);
    }
    return shared orelse 0;
}

/// At most `max` bytes of a line, cut between characters.
fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

const sizeText = fetch.sizeText;

/// A path as a shell takes it as one word, in quotes only when it has a character a shell
/// would read as something else. A leading `~/` stays outside the quotes, where the shell
/// still reads it as the home folder.
fn quoted(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const home = std.mem.startsWith(u8, path, "~/");
    const plain = for (if (home) path[2..] else path) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._/+-@%,=", c) == null) break false;
    } else path.len > 0;
    if (plain) return a.dupe(u8, path);
    const z = try a.dupeSentinel(u8, if (home) path[2..] else path, 0);
    defer a.free(z);
    const q = glib.shellQuote(z.ptr);
    defer glib.free(q);
    return std.mem.concat(a, u8, &.{ if (home) "~/" else "", std.mem.span(q) });
}

/// The editor's command for a file: `{path}` and `{line}` in the setting are filled in, and
/// a setting that names no `{path}` gets the path after it.
fn command(a: std.mem.Allocator, template: []const u8, path: []const u8, line: ?u32) ![]u8 {
    const q = try quoted(a, path);
    defer a.free(q);
    var number: [16]u8 = undefined;
    const n = std.fmt.bufPrint(&number, "{d}", .{line orelse 1}) catch unreachable;
    const base = if (std.mem.trim(u8, template, " ").len == 0) "nvim +{line} {path}" else template;
    const with_line = try std.mem.replaceOwned(u8, a, base, "{line}", n);
    defer a.free(with_line);
    if (std.mem.indexOf(u8, with_line, "{path}") == null) return std.mem.concat(a, u8, &.{ with_line, " ", q });
    return std.mem.replaceOwned(u8, a, with_line, "{path}", q);
}

test "a path and the line named after it" {
    try std.testing.expectEqualStrings("src/main.zig", split("src/main.zig:42").path);
    try std.testing.expectEqual(@as(?u32, 42), split("src/main.zig:42").line);
    try std.testing.expectEqual(@as(?u32, null), split("src/main.zig").line);
    try std.testing.expectEqualStrings("./a b.png", split("./a b.png").path);
}

test "the editor's command quotes the path and names the line" {
    const a = std.testing.allocator;
    const plain = try command(a, "nvim +{line} {path}", "src/main.zig", 42);
    defer a.free(plain);
    try std.testing.expectEqualStrings("nvim +42 src/main.zig", plain);
    const spaced = try command(a, "nvim +{line} {path}", "~/my notes/it's.md", null);
    defer a.free(spaced);
    try std.testing.expectEqualStrings("nvim +1 ~/'my notes/it'\\''s.md'", spaced);
    const bare = try command(a, "hx", "a.txt", 7);
    defer a.free(bare);
    try std.testing.expectEqualStrings("hx a.txt", bare);
}

test "the lines a peek shows" {
    const text = "1\n2\n3\n4\n5\n6\n7\n8";
    try std.testing.expectEqual(@as(u32, 1), excerpt(text, 6).first);
    try std.testing.expectEqual(@as(u32, 8), excerpt(text, 6).last);
    try std.testing.expectEqual(@as(u32, 8), excerpt(text ++ "\n", 6).last);
    try std.testing.expectEqual(@as(u32, 1), excerpt(text, 99).first);
    try std.testing.expectEqual(@as(u32, shown_lines), excerpt(text, null).last);
    // Forty lines.
    var forty: [79]u8 = undefined;
    for (&forty, 0..) |*c, i| c.* = if (i % 2 == 0) 'x' else '\n';
    const long: []const u8 = &forty;
    try std.testing.expectEqual(@as(u32, 14), excerpt(long, 20).first);
    try std.testing.expectEqual(@as(u32, 26), excerpt(long, 20).last);
    try std.testing.expectEqual(@as(u32, 28), excerpt(long, 39).first);
    try std.testing.expectEqual(@as(u32, 40), excerpt(long, 39).last);
    try std.testing.expectEqual(@as(u32, 1), excerpt(long, 3).first);
    try std.testing.expectEqual(@as(u32, 13), excerpt(long, 3).last);
    try std.testing.expectEqualStrings("né", clip("néé", 4));
    try std.testing.expectEqual(@as(usize, 4), sharedIndent(&.{ "        a", "", "    b", "   " }));
    try std.testing.expectEqual(@as(usize, 0), sharedIndent(&.{ "", "" }));
}

test "what a file's name says it is" {
    try std.testing.expectEqual(highlight.Lang.zig, kindOf("src/main.zig").?.lang);
    try std.testing.expectEqual(highlight.Lang.hash, kindOf("deploy/Dockerfile").?.lang);
    try std.testing.expect(kindOf("README") == null);
    try std.testing.expect(kindOf("notes.txt") == null);
}

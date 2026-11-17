//! The copy-mode snapshot and its small bridge to a terminal pane.
const std = @import("std");
const gdk = @import("gdk");
const cm = @import("copymode.zig");
const keys = @import("keys.zig");
const tv = @import("termview.zig");
const Term = @import("term.zig").Term;
const J = @import("../util/json.zig");

pub const Session = struct {
    term: *Term,
    mode: cm.Mode,

    fn create(live: *Term) ?Session {
        _ = live.render(true);
        const f = &live.frame;
        if (f.cols == 0 or f.rows == 0 or f.scroll_total == 0) return null;
        const frozen = live.freeze() orelse return null;
        frozen.clearSelection();
        const top: usize = @intCast(f.scroll_offset);
        const cursor: cm.Point = .{ .x = @min(f.cursor_x, f.cols - 1), .y = top + if (f.cursor_visible) @as(usize, f.cursor_y) else f.rows - 1 };
        return .{ .term = frozen, .mode = cm.Mode.init(frozen.copyGrid(), cursor, top, f.rows) };
    }
};

pub fn enter(v: *tv.TermView) bool {
    if (v.copy_mode != null) return true;
    const live = v.term() orelse return false;
    v.copy_mode = Session.create(live) orelse {
        v.server.notifyMessage("Couldn't enter copy mode while a terminal update was unfinished; try again");
        return true;
    };
    v.endCopyAnimation();
    v.scroll_velocity = 0;
    sync(v);
    return true;
}

pub fn exit(v: *tv.TermView) void {
    const session = v.copy_mode orelse return;
    v.copy_mode = null;
    session.term.destroy();
    if (v.term()) |live| {
        _ = live.render(true);
        v.last_total = live.frame.scroll_total;
        v.scroll_px = @as(f64, @floatFromInt(live.frame.rowsUp())) * v.cell_h;
        v.scroll_target = v.scroll_px;
    }
    v.widget().queueDraw();
    if (tv.on_mode_changed) |f| f();
}

fn sync(v: *tv.TermView) void {
    const s = if (v.copy_mode) |*s| s else return;
    const t = s.term;
    t.scrollToRow(s.mode.top);
    if (s.mode.selection(t.copyGrid())) |range| t.selectGrid(range) else t.clearSelection();
    _ = t.render(true);
    v.last_total = t.frame.scroll_total;
    v.scroll_px = @as(f64, @floatFromInt(t.frame.rowsUp())) * v.cell_h;
    v.scroll_target = v.scroll_px;
    v.widget().queueDraw();
    if (tv.on_mode_changed) |f| f();
}

fn finish(v: *tv.TermView, result: cm.Result) void {
    sync(v);
    if (result == .yank) {
        v.copySelection(false);
        v.endCopyAnimation();
    }
    if (result != .stay) exit(v);
}

pub fn key(v: *tv.TermView, keyval: u32, mods: u4) void {
    const s = if (v.copy_mode) |*s| s else return;
    const cp = gdk.keyvalToUnicode(keyval);
    var buf: [40]u8 = undefined;
    const raw_name = keys.rexName(&buf, keyval, cp, mods) orelse "";
    var canonical: [40]u8 = undefined;
    var parsed_name = keys.parseName(raw_name);
    const name = if (parsed_name) |*p| (if (p.mods == 0) p.base() else std.fmt.bufPrint(&canonical, "{s}+{s}", .{ keys.modsString(p.mods), p.base() }) catch raw_name) else raw_name;
    // Configured copy-mode keys take precedence over the built-in Vim keys, but text
    // being entered for a search or character find belongs to that prompt.
    if (!s.mode.searching and s.mode.pending_find == null) {
        for (v.server.modeBindings()) |b| {
            if (!std.mem.eql(u8, b.mode, "copy") or !keys.sameKey(b.keys, name)) continue;
            if (std.mem.startsWith(u8, b.action, "pane.copy_mode.")) {
                const parsed = if (b.args) |args| std.json.parseFromSlice(J.Value, std.heap.c_allocator, args, .{}) catch return else null;
                defer if (parsed) |p| p.deinit();
                _ = action(v, b.action[15..], if (parsed) |p| p.value else null);
            } else v.runAction(b.action, b.args, false);
            return;
        }
    }
    const result = s.mode.key(s.term.copyGrid(), name, if (mods & (keys.ctrl | keys.alt | keys.super) == 0) cp else 0);
    finish(v, result);
}

pub fn status(v: *tv.TermView, buf: []u8) ?[:0]const u8 {
    const s = if (v.copy_mode) |*s| s else return null;
    const m = &s.mode;
    if (m.searching) {
        var text: [1024]u8 = undefined;
        var n: usize = 0;
        for (m.query[0..m.query_len]) |cp| n += std.unicode.utf8Encode(@intCast(cp), text[n..][0..4]) catch 0;
        return std.fmt.bufPrintSentinel(buf, "COPY {c}{s} · Enter to search", .{ @as(u8, if (m.backward) '?' else '/'), text[0..n] }, 0) catch "COPY · search";
    }
    if (m.count > 0) return std.fmt.bufPrintSentinel(buf, "COPY · {d}… · Esc to leave", .{m.count}, 0) catch "COPY";
    const kind = if (m.anchor == null) "" else switch (m.kind) {
        .character => " · character",
        .line => " · line",
        .rectangle => " · rectangle",
    };
    return std.fmt.bufPrintSentinel(buf, "COPY{s}{s} · {d}:{d} · Esc to leave", .{ kind, if (m.not_found) " · not found" else if (m.pending_find != null) " · find character…" else "", m.cursor.y + 1, m.cursor.x + 1 }, 0) catch "COPY · Esc to leave";
}

/// These are Renux's local action arguments, not an undocumented Mac wire protocol.
pub fn action(v: *tv.TermView, name: []const u8, args: ?J.Value) bool {
    const eql = std.mem.eql;
    if (eql(u8, name, "enter")) return enter(v);
    const s = if (v.copy_mode) |*s| s else return false;
    const m = &s.mode;
    const g = s.term.copyGrid();
    var result: cm.Result = .stay;
    if (eql(u8, name, "exit")) {
        result = .exit;
    } else if (eql(u8, name, "yank")) {
        result = .yank;
    } else if (eql(u8, name, "move")) {
        m.move(g, std.meta.stringToEnum(cm.Motion, J.str(args, "motion") orelse return false) orelse return false);
    } else if (eql(u8, name, "select")) {
        m.select(std.meta.stringToEnum(cm.Kind, J.str(args, "kind") orelse "character") orelse return false);
    } else if (eql(u8, name, "swap_ends")) {
        m.swap(g);
    } else if (eql(u8, name, "copy_to_line_end")) {
        m.anchor = m.cursor;
        m.kind = .character;
        m.move(g, .line_end);
        result = .yank;
    } else if (eql(u8, name, "search")) {
        m.startSearch(J.boolean(args, "backward") orelse false);
    } else if (eql(u8, name, "search_again")) {
        m.searchAgain(g, J.boolean(args, "reverse") orelse false);
    } else if (eql(u8, name, "find")) {
        m.pending_find = .{ .backward = J.boolean(args, "backward") orelse false, .till = J.boolean(args, "till") orelse false };
        m.find_count = @max(1, m.count);
        m.count = 0;
    } else if (eql(u8, name, "find_again")) {
        m.findAgain(g, J.boolean(args, "reverse") orelse false);
    } else if (eql(u8, name, "count")) {
        const digit = J.int(args, "digit") orelse return false;
        if (digit < 0 or digit > 9) return false;
        if (digit == 0 and m.count == 0) m.move(g, .line_start) else m.digit(@intCast(digit));
    } else return false;
    finish(v, result);
    return true;
}

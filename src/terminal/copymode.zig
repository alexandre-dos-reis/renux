//! Keyboard selection over a stable grid of terminal cells, independent of the UI.
const std = @import("std");

pub const Point = struct { x: usize = 0, y: usize = 0 };
pub const Cell = struct { cp: u32 = 0, spacer: bool = false };
pub const Grid = struct {
    ctx: *anyopaque,
    cols: usize,
    rows: usize,
    read: *const fn (*anyopaque, Point) Cell,
    wrapped: *const fn (*anyopaque, usize) bool,

    fn cell(g: Grid, p: Point) Cell {
        return g.read(g.ctx, p);
    }
    fn cp(g: Grid, p: Point) u32 {
        const c = g.cell(p).cp;
        return if (c == 0) ' ' else c;
    }
};
pub const Kind = enum { character, line, rectangle };
pub const Motion = enum {
    left,
    right,
    up,
    down,
    word_forward,
    word_backward,
    word_end,
    WORD_forward,
    WORD_backward,
    WORD_end,
    line_start,
    first_nonblank,
    line_end,
    screen_top,
    screen_middle,
    screen_bottom,
    half_up,
    half_down,
    page_up,
    page_down,
    top,
    bottom,
    paragraph_up,
    paragraph_down,
};
pub const Result = enum { stay, exit, yank };
const Find = struct { cp: u32 = 0, backward: bool = false, till: bool = false };
pub const Selection = struct { start: Point, end: Point, rectangle: bool };

pub const Mode = struct {
    cursor: Point,
    anchor: ?Point = null,
    kind: Kind = .character,
    count: usize = 0,
    top: usize,
    height: usize,
    pending_find: ?Find = null,
    last_find: ?Find = null,
    find_count: usize = 1,
    searching: bool = false,
    backward: bool = false,
    query: [256]u32 = undefined,
    query_len: usize = 0,
    saved_cursor: Point = .{},
    saved_query: [256]u32 = undefined,
    saved_query_len: usize = 0,
    saved_backward: bool = false,
    not_found: bool = false,

    pub fn init(g: Grid, cursor: Point, top: usize, height: usize) Mode {
        var m: Mode = .{ .cursor = cursor, .top = top, .height = @max(1, height) };
        m.clamp(g);
        return m;
    }

    fn clamp(m: *Mode, g: Grid) void {
        m.cursor.y = @min(m.cursor.y, g.rows - 1);
        m.cursor.x = @min(m.cursor.x, g.cols - 1);
        while (m.cursor.x > 0 and g.cell(m.cursor).spacer) m.cursor.x -= 1;
        if (m.cursor.y < m.top) m.top = m.cursor.y;
        if (m.cursor.y >= m.top + m.height) m.top = m.cursor.y - m.height + 1;
        m.top = @min(m.top, g.rows -| m.height);
    }

    fn takeCount(m: *Mode) usize {
        const n = @max(1, m.count);
        m.count = 0;
        return n;
    }
    pub fn digit(m: *Mode, d: usize) void {
        m.count = @min(100000, m.count *| 10 +| d);
    }

    fn step(p: *Point, g: Grid, backward: bool) bool {
        while (true) {
            if (backward) {
                if (p.x > 0) p.x -= 1 else if (p.y > 0) {
                    p.y -= 1;
                    p.x = g.cols - 1;
                } else return false;
            } else {
                if (p.x + 1 < g.cols) p.x += 1 else if (p.y + 1 < g.rows) {
                    p.y += 1;
                    p.x = 0;
                } else return false;
            }
            if (!g.cell(p.*).spacer) return true;
        }
    }

    fn category(cp: u32, big: bool) u2 {
        if (cp == 0 or cp == ' ' or cp == '\t') return 0;
        if (big or cp >= 128 or (cp < 128 and (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_'))) return 1;
        return 2;
    }

    fn word(m: *Mode, g: Grid, backward: bool, end: bool, big: bool) void {
        var p = m.cursor;
        if (backward or end) {
            if (!step(&p, g, backward)) return;
        }
        var cat = category(g.cp(p), big);
        if (!backward and !end) {
            while (category(g.cp(p), big) == cat) {
                const y = p.y;
                if (!step(&p, g, false)) {
                    m.cursor = p;
                    return;
                }
                if (p.y != y and !g.wrapped(g.ctx, y)) break;
            }
        }
        while (category(g.cp(p), big) == 0) if (!step(&p, g, backward)) {
            m.cursor = p;
            return;
        };
        if (backward or end) {
            cat = category(g.cp(p), big);
            while (true) {
                var next = p;
                if (!step(&next, g, backward) or category(g.cp(next), big) != cat) break;
                if (next.y != p.y and !g.wrapped(g.ctx, @min(next.y, p.y))) break;
                p = next;
            }
        }
        m.cursor = p;
    }

    fn lineStart(g: Grid, y: usize) usize {
        var row = y;
        while (row > 0 and g.wrapped(g.ctx, row - 1)) row -= 1;
        return row;
    }
    fn lineEnd(g: Grid, y: usize) usize {
        var row = y;
        while (row + 1 < g.rows and g.wrapped(g.ctx, row)) row += 1;
        return row;
    }
    fn lastColumn(g: Grid, y: usize) usize {
        var x = g.cols - 1;
        while (x > 0 and (g.cell(.{ .x = x, .y = y }).spacer or g.cp(.{ .x = x, .y = y }) == ' ')) x -= 1;
        return x;
    }
    fn blank(g: Grid, y: usize) bool {
        for (0..g.cols) |x| if (g.cp(.{ .x = x, .y = y }) != ' ') return false;
        return true;
    }

    pub fn move(m: *Mode, g: Grid, motion: Motion) void {
        const counted = m.count > 0;
        const n = m.takeCount();
        const max_y = g.rows - 1;
        switch (motion) {
            .up => m.cursor.y -|= n,
            .down => m.cursor.y = @min(max_y, m.cursor.y +| n),
            .half_up, .page_up => {
                const amount = n *| (if (motion == .half_up) @max(1, m.height / 2) else m.height);
                m.cursor.y -|= amount;
                m.top -|= amount;
            },
            .half_down, .page_down => {
                const amount = n *| (if (motion == .half_down) @max(1, m.height / 2) else m.height);
                m.cursor.y = @min(max_y, m.cursor.y +| amount);
                m.top = @min(g.rows -| m.height, m.top +| amount);
            },
            .top => {
                m.cursor.y = @min(max_y, n - 1);
                m.cursor.x = 0;
            },
            .bottom => {
                m.cursor.y = if (!counted) max_y else @min(max_y, n - 1);
                m.cursor.x = 0;
            },
            .screen_top => m.cursor.y = @min(max_y, m.top + @min(n - 1, m.height - 1)),
            .screen_middle => m.cursor.y = @min(max_y, m.top + m.height / 2),
            .screen_bottom => m.cursor.y = @min(max_y, m.top + m.height - @min(n, m.height)),
            .line_start, .first_nonblank => {
                m.cursor.y = lineStart(g, m.cursor.y);
                m.cursor.x = 0;
                if (motion == .first_nonblank) {
                    var p = m.cursor;
                    const last = lineEnd(g, p.y);
                    while (g.cp(p) == ' ') {
                        if (!step(&p, g, false) or p.y > last) break;
                    }
                    if (p.y <= last and g.cp(p) != ' ') m.cursor = p;
                }
            },
            .line_end => {
                m.cursor.y = lineEnd(g, @min(max_y, m.cursor.y +| (n - 1)));
                m.cursor.x = lastColumn(g, m.cursor.y);
            },
            else => for (0..n) |_| switch (motion) {
                .left => {
                    if (m.cursor.x > 0) {
                        m.cursor.x -= 1;
                        while (m.cursor.x > 0 and g.cell(m.cursor).spacer) m.cursor.x -= 1;
                    }
                },
                .right => {
                    var p = m.cursor;
                    if (step(&p, g, false) and p.y == m.cursor.y) m.cursor = p;
                },
                .word_forward, .WORD_forward => m.word(g, false, false, motion == .WORD_forward),
                .word_backward, .WORD_backward => m.word(g, true, false, motion == .WORD_backward),
                .word_end, .WORD_end => m.word(g, false, true, motion == .WORD_end),
                .paragraph_up, .paragraph_down => {
                    const back = motion == .paragraph_up;
                    var y = m.cursor.y;
                    while (true) {
                        if (back) {
                            if (y == 0) break;
                            y -= 1;
                        } else {
                            if (y == max_y) break;
                            y += 1;
                        }
                        if (blank(g, y)) break;
                    }
                    m.cursor = .{ .y = y };
                },
                else => unreachable,
            },
        }
        m.clamp(g);
    }

    pub fn select(m: *Mode, kind: Kind) void {
        if (m.anchor != null and m.kind == kind) m.anchor = null else {
            if (m.anchor == null) m.anchor = m.cursor;
            m.kind = kind;
        }
        m.count = 0;
    }
    pub fn swap(m: *Mode, g: Grid) void {
        if (m.anchor) |a| {
            m.anchor = m.cursor;
            m.cursor = a;
            m.clamp(g);
        }
    }
    pub fn selection(m: Mode, g: Grid) ?Selection {
        const anchor = m.anchor orelse return null;
        var a = anchor;
        var b = m.cursor;
        if (m.kind == .line) {
            if (a.y > b.y) std.mem.swap(Point, &a, &b);
            a = .{ .y = lineStart(g, a.y) };
            b = .{ .x = g.cols - 1, .y = lineEnd(g, b.y) };
        }
        return .{ .start = a, .end = b, .rectangle = m.kind == .rectangle };
    }

    pub fn startSearch(m: *Mode, backward: bool) void {
        m.saved_cursor = m.cursor;
        m.saved_query_len = m.query_len;
        @memcpy(m.saved_query[0..m.query_len], m.query[0..m.query_len]);
        m.saved_backward = m.backward;
        m.query_len = 0;
        m.backward = backward;
        m.searching = true;
        m.not_found = false;
    }
    fn matches(m: *Mode, g: Grid, start: Point) bool {
        var p = start;
        for (m.query[0..m.query_len], 0..) |cp, i| {
            if (g.cp(p) != cp) return false;
            if (i + 1 < m.query_len) {
                const y = p.y;
                if (!step(&p, g, false) or (p.y != y and !g.wrapped(g.ctx, y))) return false;
            }
        }
        return true;
    }
    pub fn searchAgain(m: *Mode, g: Grid, reverse: bool) void {
        const n = m.takeCount();
        if (m.query_len == 0) return;
        for (0..n) |_| {
            var p = m.cursor;
            var found = false;
            var visited: usize = 0;
            while (visited < g.rows * g.cols) : (visited += 1) {
                if (!step(&p, g, m.backward != reverse)) p = if (m.backward != reverse) .{ .x = g.cols - 1, .y = g.rows - 1 } else .{};
                if (!g.cell(p).spacer and m.matches(g, p)) {
                    m.cursor = p;
                    found = true;
                    break;
                }
            }
            m.not_found = !found;
            if (!found) break;
        }
        m.clamp(g);
    }
    pub fn findAgain(m: *Mode, g: Grid, reverse: bool) void {
        var f = m.last_find orelse return;
        f.backward = f.backward != reverse;
        m.findChar(g, f, m.takeCount(), true);
    }
    fn findChar(m: *Mode, g: Grid, f: Find, n: usize, repeat: bool) void {
        var p = m.cursor;
        // A till-motion stops beside its target; repeating must pass that target first.
        if (repeat and f.till) _ = step(&p, g, f.backward);
        const first = lineStart(g, p.y);
        const last = lineEnd(g, p.y);
        for (0..n) |_| {
            var found = false;
            while (step(&p, g, f.backward)) {
                if (p.y < first or p.y > last) break;
                if (g.cp(p) == f.cp) {
                    found = true;
                    break;
                }
            }
            if (!found) return;
        }
        if (f.till) _ = step(&p, g, !f.backward);
        m.cursor = p;
        m.clamp(g);
    }

    pub fn key(m: *Mode, g: Grid, name: []const u8, cp: u32) Result {
        const eq = std.mem.eql;
        if (m.searching) {
            if (eq(u8, name, "escape")) {
                m.searching = false;
                m.cursor = m.saved_cursor;
                m.query_len = m.saved_query_len;
                @memcpy(m.query[0..m.query_len], m.saved_query[0..m.query_len]);
                m.backward = m.saved_backward;
                m.not_found = false;
            } else if (eq(u8, name, "enter")) {
                m.searching = false;
                m.searchAgain(g, false);
            } else if (eq(u8, name, "backspace")) {
                m.query_len -|= 1;
            } else if (cp >= 32 and cp != 127 and m.query_len < m.query.len) {
                m.query[m.query_len] = cp;
                m.query_len += 1;
            }
            m.clamp(g);
            return .stay;
        }
        if (eq(u8, name, "escape")) return .exit;
        if (m.pending_find) |pending| {
            m.pending_find = null;
            if (cp >= 32) {
                var f = pending;
                f.cp = cp;
                m.last_find = f;
                m.findChar(g, f, m.find_count, false);
            }
            return .stay;
        }
        if (eq(u8, name, "q")) return .exit;
        if (name.len == 1 and name[0] >= '0' and name[0] <= '9' and (name[0] != '0' or m.count > 0)) {
            m.digit(name[0] - '0');
            return .stay;
        }
        if (motionForKey(name)) |motion| {
            m.move(g, motion);
            return .stay;
        }
        if (eq(u8, name, "v")) {
            m.select(.character);
        } else if (eq(u8, name, "shift+v")) {
            m.select(.line);
        } else if (eq(u8, name, "ctrl+v")) {
            m.select(.rectangle);
        } else if (eq(u8, name, "o")) {
            m.swap(g);
        } else if (eq(u8, name, "y") or eq(u8, name, "enter")) {
            return .yank;
        } else if (eq(u8, name, "shift+d")) {
            m.anchor = m.cursor;
            m.kind = .character;
            m.move(g, .line_end);
            return .yank;
        } else if (eq(u8, name, "/") or eq(u8, name, "shift+/")) {
            m.startSearch(eq(u8, name, "shift+/"));
        } else if (eq(u8, name, "n") or eq(u8, name, "shift+n")) {
            m.searchAgain(g, eq(u8, name, "shift+n"));
        } else if (eq(u8, name, ";") or eq(u8, name, ",")) {
            m.findAgain(g, eq(u8, name, ","));
        } else if (eq(u8, name, "f") or eq(u8, name, "shift+f") or eq(u8, name, "t") or eq(u8, name, "shift+t")) {
            m.pending_find = .{ .backward = std.mem.startsWith(u8, name, "shift+"), .till = name[name.len - 1] == 't' };
            m.find_count = m.takeCount();
        }
        return .stay;
    }
};

pub fn motionForKey(name: []const u8) ?Motion {
    if (std.mem.eql(u8, name, "page_up")) return .page_up;
    if (std.mem.eql(u8, name, "page_down")) return .page_down;
    const binds = .{
        .{ "h", Motion.left },                 .{ "left", Motion.left },             .{ "l", Motion.right },              .{ "right", Motion.right },
        .{ "j", Motion.down },                 .{ "down", Motion.down },             .{ "k", Motion.up },                 .{ "up", Motion.up },
        .{ "w", Motion.word_forward },         .{ "b", Motion.word_backward },       .{ "e", Motion.word_end },           .{ "shift+w", Motion.WORD_forward },
        .{ "shift+b", Motion.WORD_backward },  .{ "shift+e", Motion.WORD_end },      .{ "0", Motion.line_start },         .{ "home", Motion.line_start },
        .{ "shift+6", Motion.first_nonblank }, .{ "shift+4", Motion.line_end },      .{ "end", Motion.line_end },         .{ "shift+h", Motion.screen_top },
        .{ "shift+m", Motion.screen_middle },  .{ "shift+l", Motion.screen_bottom }, .{ "ctrl+u", Motion.half_up },       .{ "ctrl+d", Motion.half_down },
        .{ "ctrl+b", Motion.page_up },         .{ "pageup", Motion.page_up },        .{ "ctrl+f", Motion.page_down },     .{ "pagedown", Motion.page_down },
        .{ "g", Motion.top },                  .{ "shift+g", Motion.bottom },        .{ "shift+[", Motion.paragraph_up }, .{ "shift+]", Motion.paragraph_down },
    };
    inline for (binds) |b| if (std.mem.eql(u8, name, b[0])) return b[1];
    return null;
}

const Fixture = struct {
    rows: []const []const u8,
    wrap: ?usize = null,
    fn read(ctx: *anyopaque, p: Point) Cell {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        const row = f.rows[p.y];
        return .{ .cp = if (p.x < row.len) row[p.x] else 0 };
    }
    fn wrapped(ctx: *anyopaque, y: usize) bool {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return f.wrap == y;
    }
    fn grid(f: *Fixture) Grid {
        return .{ .ctx = f, .cols = 16, .rows = f.rows.len, .read = read, .wrapped = wrapped };
    }
};

test "counts, words, punctuation, big words and bounded character motions" {
    var f: Fixture = .{ .rows = &.{ "  one,two three", "second", "", "last" } };
    const g = f.grid();
    var m = Mode.init(g, .{}, 0, 2);
    m.move(g, .first_nonblank);
    try std.testing.expectEqual(@as(usize, 2), m.cursor.x);
    m.move(g, .word_forward);
    try std.testing.expectEqual(@as(usize, 5), m.cursor.x);
    m.move(g, .word_end);
    try std.testing.expectEqual(@as(usize, 8), m.cursor.x);
    m.move(g, .WORD_backward);
    try std.testing.expectEqual(@as(usize, 2), m.cursor.x);
    m.move(g, .WORD_end);
    try std.testing.expectEqual(@as(usize, 8), m.cursor.x);
    m.move(g, .word_forward);
    try std.testing.expectEqual(@as(usize, 10), m.cursor.x);
    _ = m.key(g, "2", '2');
    _ = m.key(g, "j", 'j');
    try std.testing.expectEqual(@as(usize, 2), m.cursor.y);
    try std.testing.expectEqual(@as(usize, 1), m.top);
    m.move(g, .paragraph_down);
    try std.testing.expectEqual(@as(usize, 3), m.cursor.y);
    m.move(g, .paragraph_up);
    try std.testing.expectEqual(@as(usize, 2), m.cursor.y);
    m.move(g, .top);
    m.move(g, .left);
    try std.testing.expectEqual(@as(usize, 0), m.cursor.x);
    m.digit(1);
    m.digit(0);
    m.move(g, .down);
    try std.testing.expectEqual(@as(usize, 3), m.cursor.y);
}

test "logical wrapped lines, line selections, rectangles and swapping ends" {
    var f: Fixture = .{ .rows = &.{ "0123456789abcdef", "continuation", "next" }, .wrap = 0 };
    const g = f.grid();
    var m = Mode.init(g, .{ .x = 4 }, 0, 2);
    m.select(.line);
    m.move(g, .line_end);
    const s = m.selection(g).?;
    try std.testing.expectEqual(Point{}, s.start);
    try std.testing.expectEqual(Point{ .x = 15, .y = 1 }, s.end);
    m.move(g, .line_start);
    try std.testing.expectEqual(Point{}, m.cursor);
    m.select(.rectangle);
    m.move(g, .down);
    m.swap(g);
    try std.testing.expectEqual(Point{ .x = 4 }, m.cursor);
    try std.testing.expect(m.selection(g).?.rectangle);
    m.select(.rectangle);
    try std.testing.expect(m.selection(g) == null);
}

test "search directions, repeat, cancel, missing matches, character find and till repeat" {
    var f: Fixture = .{ .rows = &.{ "a-b-c-b-d-b", "search needle", "needle again" } };
    const g = f.grid();
    var m = Mode.init(g, .{}, 0, 2);
    _ = m.key(g, "f", 'f');
    _ = m.key(g, "b", 'b');
    try std.testing.expectEqual(@as(usize, 2), m.cursor.x);
    _ = m.key(g, ";", ';');
    try std.testing.expectEqual(@as(usize, 6), m.cursor.x);
    _ = m.key(g, ",", ',');
    try std.testing.expectEqual(@as(usize, 2), m.cursor.x);
    m.cursor = .{};
    _ = m.key(g, "t", 't');
    _ = m.key(g, "b", 'b');
    try std.testing.expectEqual(@as(usize, 1), m.cursor.x);
    _ = m.key(g, ";", ';');
    try std.testing.expectEqual(@as(usize, 5), m.cursor.x);
    _ = m.key(g, "/", '/');
    for ("needle") |cp| {
        _ = m.key(g, "", cp);
    }
    _ = m.key(g, "enter", 0);
    try std.testing.expectEqual(Point{ .x = 7, .y = 1 }, m.cursor);
    _ = m.key(g, "n", 'n');
    try std.testing.expectEqual(@as(usize, 2), m.cursor.y);
    _ = m.key(g, "shift+n", 'N');
    try std.testing.expectEqual(@as(usize, 1), m.cursor.y);
    m.startSearch(true);
    _ = m.key(g, "", 'x');
    _ = m.key(g, "escape", 0);
    try std.testing.expectEqual(@as(usize, 6), m.query_len);
    m.startSearch(true);
    _ = m.key(g, "", 'x');
    _ = m.key(g, "enter", 0);
    try std.testing.expect(m.not_found);
}

test "wide cells are a single cursor stop and screen and page motions clamp" {
    const Wide = struct {
        fn read(_: *anyopaque, p: Point) Cell {
            return .{ .cp = if (p.x == 1) 0x754c else 'x', .spacer = p.x == 2 };
        }
        fn wrap(_: *anyopaque, _: usize) bool {
            return false;
        }
    };
    var ctx: u8 = 0;
    const g: Grid = .{ .ctx = &ctx, .cols = 5, .rows = 20, .read = Wide.read, .wrapped = Wide.wrap };
    var m = Mode.init(g, .{}, 0, 6);
    m.move(g, .right);
    m.move(g, .right);
    try std.testing.expectEqual(@as(usize, 3), m.cursor.x);
    m.move(g, .left);
    try std.testing.expectEqual(@as(usize, 1), m.cursor.x);
    m.move(g, .screen_bottom);
    try std.testing.expectEqual(@as(usize, 5), m.cursor.y);
    m.move(g, .half_down);
    try std.testing.expectEqual(@as(usize, 8), m.cursor.y);
    try std.testing.expectEqual(@as(usize, 3), m.top);
    m.move(g, .page_down);
    try std.testing.expectEqual(@as(usize, 14), m.cursor.y);
    m.move(g, .bottom);
    try std.testing.expectEqual(@as(usize, 19), m.cursor.y);
    m.move(g, .screen_top);
    try std.testing.expectEqual(@as(usize, 14), m.cursor.y);
    m.move(g, .screen_middle);
    try std.testing.expectEqual(@as(usize, 17), m.cursor.y);
    _ = m.key(g, "page_up", 0);
    try std.testing.expectEqual(@as(usize, 11), m.cursor.y);
    _ = m.key(g, "page_down", 0);
    try std.testing.expectEqual(@as(usize, 17), m.cursor.y);
}

test "logical newlines delimit words but soft wraps do not" {
    var f: Fixture = .{ .rows = &.{ "abcdefghijklmnop", "qrstuvwxyz", "", "next q" } };
    const g = f.grid();
    var m = Mode.init(g, .{}, 0, 2);
    m.move(g, .word_forward);
    try std.testing.expectEqual(Point{ .y = 1 }, m.cursor);
    m.move(g, .word_backward);
    try std.testing.expectEqual(Point{}, m.cursor);
    f.wrap = 0;
    m.move(g, .word_end);
    try std.testing.expectEqual(Point{ .x = 9, .y = 1 }, m.cursor);
    m.cursor = .{ .x = 8, .y = 2 };
    m.move(g, .first_nonblank);
    try std.testing.expectEqual(Point{ .y = 2 }, m.cursor);
    m.digit(1);
    m.move(g, .bottom);
    try std.testing.expectEqual(Point{}, m.cursor);
    m.move(g, .bottom);
    _ = m.key(g, "f", 'f');
    try std.testing.expectEqual(Result.stay, m.key(g, "q", 'q'));
    try std.testing.expectEqual(@as(usize, 5), m.cursor.x);
}

test "reverse search wraps, backspace edits, D y enter and q have the documented outcomes" {
    var f: Fixture = .{ .rows = &.{ "one needle", "middle", "needle last" } };
    const g = f.grid();
    var m = Mode.init(g, .{}, 0, 2);
    _ = m.key(g, "shift+/", '?');
    for ("needlex") |cp| {
        _ = m.key(g, "", cp);
    }
    _ = m.key(g, "backspace", 0);
    _ = m.key(g, "enter", 0);
    try std.testing.expectEqual(Point{ .y = 2 }, m.cursor);
    _ = m.key(g, "n", 'n');
    try std.testing.expectEqual(Point{ .x = 4 }, m.cursor);
    _ = m.key(g, "shift+n", 'N');
    try std.testing.expectEqual(Point{ .y = 2 }, m.cursor);
    try std.testing.expectEqual(Result.yank, m.key(g, "shift+d", 'D'));
    try std.testing.expectEqual(Point{ .x = 10, .y = 2 }, m.selection(g).?.end);
    try std.testing.expectEqual(Result.yank, m.key(g, "enter", 0));
    try std.testing.expectEqual(Result.yank, m.key(g, "y", 'y'));
    try std.testing.expectEqual(Result.exit, m.key(g, "q", 'q'));
    try std.testing.expectEqual(Result.exit, m.key(g, "escape", 0));
}

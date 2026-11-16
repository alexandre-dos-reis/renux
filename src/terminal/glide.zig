const std = @import("std");
const gtk = @import("gtk");
const gsk = @import("gsk");
const gdk = @import("gdk");
const term_mod = @import("term.zig");

const Cell = term_mod.Cell;
const gpa = std.heap.c_allocator;

const max_reach = 12;
const bridged_rows = 2;
const tolerated_cells = 2;
const anchoring_cells = 8;
const edge_columns = 1;
const least_still_text = 3;
const least_moved_rows = 3;
const lead_over_runner_up = 2;
const votes_to_move_band = 3;
const spring_rate = 70.0;
const least_rows_for_a_column = 8;
const rows_a_column_may_change = 2;
const most_rows_behind = 8.0;
const most_gaps = 4;
const rest_px = 0.5;
const rest_px_per_second = 5.0;

pub const Direction = enum { up, down, either };

pub const Band = struct {
    top: usize,
    bottom: usize,

    fn eql(a: Band, b: Band) bool {
        return a.top == b.top and a.bottom == b.bottom;
    }

    fn overlaps(a: Band, b: Band) bool {
        return a.top < b.bottom and b.top < a.bottom;
    }

    fn holds(b: Band, row: isize) bool {
        return row >= @as(isize, @intCast(b.top)) and row < @as(isize, @intCast(b.bottom));
    }
};

pub const Shift = struct { rows: isize, band: Band };

pub const Pixels = struct {
    origin: f64,
    scale: f64,

    fn edge(p: Pixels, y: f64) f64 {
        return @round((y + p.origin) * p.scale) / p.scale - p.origin;
    }

    fn distance(p: Pixels, d: f64) f64 {
        return @round(d * p.scale) / p.scale;
    }
};

const Likeness = enum { same, close, different };

fn sameCell(a: Cell, b: Cell) bool {
    return a.cp == b.cp and a.fg == b.fg and a.bg == b.bg and a.extra_len == b.extra_len and
        @as(u16, @bitCast(a.flags)) == @as(u16, @bitCast(b.flags));
}

fn compare(a: []const Cell, b: []const Cell) Likeness {
    var differing: usize = 0;
    var shared_text: usize = 0;
    for (a, b) |x, y| {
        if (!sameCell(x, y)) {
            differing += 1;
            if (differing > tolerated_cells) return .different;
        } else if (isText(x)) shared_text += 1;
    }
    if (differing == 0) return .same;
    return if (shared_text >= anchoring_cells) .close else .different;
}

fn rowOf(cells: []const Cell, cols: usize, y: usize) []const Cell {
    return cells[y * cols ..][0 .. cols - @min(edge_columns, cols - 1)];
}

fn stayed(old: []const Cell, new: []const Cell, cols: usize, y: usize) bool {
    return compare(rowOf(new, cols, y), rowOf(old, cols, y)) == .same;
}

fn isText(cell: Cell) bool {
    return cell.cp != 0 and cell.cp != ' ';
}

fn movedUnderSomethingStill(here: []const Cell, source: []const Cell, was_here: []const Cell) bool {
    var moved_text: usize = 0;
    var still_text: usize = 0;
    var unexplained: usize = 0;
    for (here, source, was_here) |cell, from, before| {
        if (sameCell(cell, from)) {
            moved_text += @intFromBool(isText(cell) and !sameCell(cell, before));
        } else if (sameCell(cell, before)) {
            still_text += @intFromBool(isText(cell));
        } else {
            unexplained += 1;
            if (unexplained > tolerated_cells) return false;
        }
    }
    return moved_text > 0 and still_text >= least_still_text;
}

fn matchesWhereItShowed(here: []const Cell, from: []const Cell, source: usize, covered: []const Still) bool {
    var was_covered = false;
    var differing: usize = 0;
    for (here, from, 0..) |cell, before, x| {
        if (wasCovered(covered, source, x)) {
            was_covered = true;
        } else if (!sameCell(cell, before)) {
            differing += 1;
            if (differing > tolerated_cells) return false;
        }
    }
    return was_covered;
}

fn wasCovered(covered: []const Still, row: usize, x: usize) bool {
    for (covered) |part| if (part.row == row and x >= part.from and x < part.to) return true;
    return false;
}

fn follows(old: []const Cell, new: []const Cell, cols: usize, y: usize, source: usize, covered: []const Still) bool {
    const here = rowOf(new, cols, y);
    const from = rowOf(old, cols, source);
    return compare(here, from) != .different or movedUnderSomethingStill(here, from, rowOf(old, cols, y)) or
        matchesWhereItShowed(here, from, source, covered);
}

const Run = struct { start: usize, last: usize, moved: usize };

fn longestRun(old: []const Cell, new: []const Cell, cols: usize, rows: usize, by: isize, covered: []const Still) ?Run {
    const from: usize = if (by < 0) @intCast(-by) else 0;
    const to: usize = if (by > 0) rows - @as(usize, @intCast(by)) else rows;
    var best: ?Run = null;
    var run: ?Run = null;
    var gap: usize = 0;
    var y = from;
    while (y < to) : (y += 1) {
        const source: usize = @intCast(@as(isize, @intCast(y)) + by);
        if (!follows(old, new, cols, y, source, covered)) {
            gap += 1;
            if (gap > bridged_rows) {
                if (run) |r| if (best == null or r.moved > best.?.moved) {
                    best = r;
                };
                run = null;
            }
            continue;
        }
        gap = 0;
        const moved = @intFromBool(!stayed(old, new, cols, y));
        if (run) |*r| {
            r.last = y;
            r.moved += moved;
        } else run = .{ .start = y, .last = y, .moved = moved };
    }
    if (run) |r| if (best == null or r.moved > best.?.moved) {
        best = r;
    };
    return best;
}

pub fn find(old: []const Cell, new: []const Cell, cols: usize, rows: usize, direction: Direction, covered: []const Still) ?Shift {
    if (cols == 0 or rows <= least_moved_rows or old.len != cols * rows or new.len != old.len) return null;
    const reach: isize = @intCast(@min(rows - least_moved_rows, max_reach));
    var best: ?Shift = null;
    var best_moved: usize = 0;
    var runner_up: usize = 0;
    var distance: isize = 1;
    while (distance <= reach) : (distance += 1) {
        for ([_]isize{ distance, -distance }) |by| {
            if ((by > 0 and direction == .down) or (by < 0 and direction == .up)) continue;
            const run = longestRun(old, new, cols, rows, by, covered) orelse continue;
            if (run.moved <= best_moved) {
                runner_up = @max(runner_up, run.moved);
                continue;
            }
            runner_up = best_moved;
            best_moved = run.moved;
            best = .{ .rows = by, .band = if (by > 0)
                .{ .top = run.start, .bottom = run.last + 1 + @as(usize, @intCast(by)) }
            else
                .{ .top = run.start - @as(usize, @intCast(-by)), .bottom = run.last + 1 } };
        }
    }
    if (best_moved < least_moved_rows or best_moved < runner_up * lead_over_runner_up) return null;
    return best;
}

const Strip = struct {
    picture: *gsk.RenderNode,
    row: usize,
    at: isize,
    gaps: [most_gaps]Still = undefined,
    gap_count: usize = 0,
};

pub const Columns = struct { from: usize, to: usize };

pub const Still = struct { row: usize, from: usize, to: usize, behind: u32 = 0 };

pub const Place = struct {
    w: f64,
    h: f64,
    pad_x: f64,
    pad_y: f64,
    cell_w: f64,
    cell_h: f64,
    px: Pixels,
    fill_alpha: f64,

    fn row(p: Place, y: usize) f64 {
        return p.px.edge(p.pad_y + @as(f64, @floatFromInt(y)) * p.cell_h);
    }

    fn column(p: Place, x: usize) f64 {
        return p.pad_x + @as(f64, @floatFromInt(x)) * p.cell_w;
    }
};

pub const Glide = struct {
    cells: std.ArrayList(Cell) = .empty,
    cols: u16 = 0,
    rows: u16 = 0,
    picture: ?*gsk.RenderNode = null,
    strips: std.ArrayList(Strip) = .empty,
    still: std.ArrayList(Still) = .empty,
    remembered: std.ArrayList(Still) = .empty,
    columns: std.ArrayList(Columns) = .empty,
    band: Band = .{ .top = 0, .bottom = 0 },
    known: ?Band = null,
    proposed: ?Band = null,
    votes: u8 = 0,
    offset: f64 = 0,
    speed: f64 = 0,
    target: f64 = 0,
    cursor_row: u16 = 0,
    cursor_rides: bool = false,

    pub fn moving(g: *const Glide) bool {
        return g.offset != 0;
    }

    pub fn stop(g: *Glide) void {
        for (g.strips.items) |s| s.picture.unref();
        g.strips.clearRetainingCapacity();
        g.still.clearRetainingCapacity();
        g.columns.clearRetainingCapacity();
        g.offset = 0;
        g.speed = 0;
        g.cursor_rides = false;
    }

    pub fn forget(g: *Glide) void {
        g.stop();
        if (g.picture) |p| p.unref();
        g.picture = null;
        g.cells.clearAndFree(gpa);
        g.strips.clearAndFree(gpa);
        g.still.clearAndFree(gpa);
        g.remembered.clearAndFree(gpa);
        g.columns.clearAndFree(gpa);
        g.target = 0;
        g.cols = 0;
        g.rows = 0;
        g.known = null;
        g.proposed = null;
        g.votes = 0;
    }

    pub fn observe(g: *Glide, f: *const term_mod.Frame, armed: ?Direction, cell_h: f64) ?Shift {
        const cells = f.cells.items;
        var found: ?Shift = null;
        if (g.cols != f.cols or g.rows != f.rows or g.cells.items.len != cells.len) {
            g.stop();
            g.remembered.clearRetainingCapacity();
            g.known = null;
            g.proposed = null;
            g.votes = 0;
        } else if (armed) |direction| {
            if (find(g.cells.items, cells, f.cols, f.rows, direction, g.remembered.items)) |seen| {
                const band = g.settled(seen.band, cells);
                if (band.bottom > band.top) {
                    found = .{ .rows = seen.rows, .band = band };
                    g.shifted(found.?, cell_h);
                    g.findStill(found.?, cells);
                    g.cursor_rides = g.moving() and band.holds(f.cursor_y) and @as(isize, f.cursor_y) + seen.rows == @as(isize, g.cursor_row);
                }
            }
        }
        g.cells.resize(gpa, cells.len) catch {
            g.forget();
            return null;
        };
        @memcpy(g.cells.items, cells);
        g.cols = f.cols;
        g.rows = f.rows;
        g.cursor_row = f.cursor_y;
        return found;
    }

    pub fn cursorShift(g: *const Glide, px: Pixels) f64 {
        return if (g.cursor_rides) px.distance(g.offset) else 0;
    }

    pub fn keep(g: *Glide, picture: ?*gsk.RenderNode) void {
        if (g.picture) |p| p.unref();
        g.picture = picture;
    }

    fn withoutEdgesThatStayed(g: *const Glide, whole: Band, new: []const Cell) Band {
        var band = whole;
        while (band.top < band.bottom and stayed(g.cells.items, new, g.cols, band.top)) band.top += 1;
        while (band.bottom > band.top and stayed(g.cells.items, new, g.cols, band.bottom - 1)) band.bottom -= 1;
        return band;
    }

    fn settled(g: *Glide, found: Band, new: []const Cell) Band {
        const seen = g.withoutEdgesThatStayed(found, new);
        const known = g.known orelse {
            g.known = seen;
            return seen;
        };
        if (seen.top <= known.top and seen.bottom >= known.bottom) {
            g.known = seen;
            g.proposed = null;
            g.votes = 0;
            return seen;
        }
        if (g.proposed != null and g.proposed.?.eql(seen)) g.votes += 1 else {
            g.proposed = seen;
            g.votes = 1;
        }
        if (g.votes >= votes_to_move_band or !seen.overlaps(known)) {
            g.known = seen;
            g.proposed = null;
            g.votes = 0;
            return seen;
        }
        return g.withoutEdgesThatStayed(known, new);
    }

    fn shifted(g: *Glide, shift: Shift, cell_h: f64) void {
        const picture = g.picture orelse return;
        const band = shift.band;
        g.band = band;
        for (g.strips.items) |*s| s.at -= shift.rows;
        const count = @min(@abs(shift.rows), band.bottom - band.top);
        for (0..count) |i| {
            const row = if (shift.rows > 0) band.top + i else band.bottom - 1 - i;
            var strip: Strip = .{ .picture = picture.ref(), .row = row, .at = @as(isize, @intCast(row)) - shift.rows };
            for (g.remembered.items) |part| {
                if (part.row != row or strip.gap_count == most_gaps) continue;
                strip.gaps[strip.gap_count] = part;
                strip.gap_count += 1;
            }
            g.strips.append(gpa, strip) catch {
                picture.unref();
                break;
            };
        }
        const room = @min(@as(f64, @floatFromInt(band.bottom - band.top - 1)), most_rows_behind) * cell_h;
        g.offset = std.math.clamp(g.offset + @as(f64, @floatFromInt(shift.rows)) * cell_h, -room, room);
        if (g.offset == 0) g.stop() else g.prune(cell_h);
    }

    fn findStill(g: *Glide, shift: Shift, new: []const Cell) void {
        g.still.clearRetainingCapacity();
        g.columns.clearRetainingCapacity();
        if (!g.moving()) return;
        const old = g.cells.items;
        const cols: usize = g.cols;
        const covered = gpa.dupe(Still, g.remembered.items) catch return;
        defer gpa.free(covered);
        g.findColumns(shift.band, new);
        var y = shift.band.top;
        while (y < shift.band.bottom) : (y += 1) {
            const source = @as(isize, @intCast(y)) + shift.rows;
            if (!shift.band.holds(source)) {
                g.keepRemembered(y, new);
                continue;
            }
            g.forgetRow(y);
            const from: usize = @intCast(source);
            var x: usize = 0;
            while (x < cols) {
                const start = x;
                var text = false;
                while (x < cols) : (x += 1) {
                    const cell = new[y * cols + x];
                    if (g.inStillColumn(x) or wasCovered(covered, from, x)) break;
                    if (sameCell(cell, old[from * cols + x]) or !sameCell(cell, old[y * cols + x])) break;
                    text = text or isText(cell);
                }
                if (x == start) {
                    x += 1;
                    continue;
                }
                if (!text) continue;
                const part: Still = .{ .row = y, .from = start, .to = x, .behind = behind(new, cols, y, start, x) };
                g.still.append(gpa, part) catch return;
                g.remembered.append(gpa, part) catch return;
            }
        }
    }

    fn findColumns(g: *Glide, band: Band, new: []const Cell) void {
        const old = g.cells.items;
        const cols: usize = g.cols;
        const rows = band.bottom - band.top;
        if (rows < least_rows_for_a_column) return;
        for (0..cols) |x| {
            var unchanged: usize = 0;
            var text: usize = 0;
            for (band.top..band.bottom) |y| {
                const cell = new[y * cols + x];
                unchanged += @intFromBool(sameCell(cell, old[y * cols + x]));
                text += @intFromBool(isText(cell));
            }
            if (unchanged + rows_a_column_may_change < rows or text * 2 < rows) continue;
            const spans = g.columns.items;
            if (spans.len > 0 and spans[spans.len - 1].to == x) {
                spans[spans.len - 1].to = x + 1;
            } else g.columns.append(gpa, .{ .from = x, .to = x + 1 }) catch return;
        }
    }

    fn inStillColumn(g: *const Glide, x: usize) bool {
        for (g.columns.items) |span| if (x >= span.from and x < span.to) return true;
        return false;
    }

    fn hasStripAt(g: *const Glide, at: isize) bool {
        for (g.strips.items) |strip| if (strip.at == at) return true;
        return false;
    }

    fn rowsFilled(g: *const Glide, nearest: isize, further: isize) f64 {
        var rows: f64 = 0;
        var at = nearest;
        while (g.hasStripAt(at)) : (at += further) rows += 1;
        return rows;
    }

    fn reachable(g: *const Glide, cell_h: f64) f64 {
        if (g.target > 0) return @min(g.target, g.rowsFilled(@as(isize, @intCast(g.band.top)) - 1, -1) * cell_h);
        if (g.target < 0) return @max(g.target, -g.rowsFilled(@intCast(g.band.bottom), 1) * cell_h);
        return 0;
    }

    fn keepRemembered(g: *Glide, y: usize, new: []const Cell) void {
        const cols: usize = g.cols;
        for (g.remembered.items) |part| {
            if (part.row != y) continue;
            const unchanged = for (part.from..part.to) |x| {
                if (!sameCell(new[y * cols + x], g.cells.items[y * cols + x])) break false;
            } else true;
            if (!unchanged) continue;
            g.still.append(gpa, .{ .row = y, .from = part.from, .to = part.to, .behind = behind(new, cols, y, part.from, part.to) }) catch return;
        }
    }

    fn forgetRow(g: *Glide, y: usize) void {
        var i: usize = 0;
        while (i < g.remembered.items.len) {
            if (g.remembered.items[i].row == y) _ = g.remembered.orderedRemove(i) else i += 1;
        }
    }

    fn prune(g: *Glide, cell_h: f64) void {
        const top = @as(f64, @floatFromInt(g.band.top)) * cell_h;
        const bottom = @as(f64, @floatFromInt(g.band.bottom)) * cell_h;
        var i: usize = 0;
        while (i < g.strips.items.len) {
            const strip = g.strips.items[i];
            const shown = @as(f64, @floatFromInt(strip.at)) * cell_h + g.offset;
            if (!g.band.holds(strip.at) and shown + cell_h > top and shown < bottom) {
                i += 1;
                continue;
            }
            strip.picture.unref();
            _ = g.strips.swapRemove(i);
        }
    }

    pub fn ease(g: *Glide, seconds: f64, cell_h: f64) bool {
        const goal = g.reachable(cell_h);
        const away = g.offset - goal;
        if (away == 0 and g.speed == 0) return false;
        const pull = g.speed + spring_rate * away;
        const decay = @exp(-spring_rate * seconds);
        const next = (away + pull * seconds) * decay;
        g.speed = (g.speed - pull * spring_rate * seconds) * decay;
        const crossed = away != 0 and (next > 0) != (away > 0);
        const resting = @abs(next) < rest_px and @abs(g.speed) < rest_px_per_second;
        if (crossed or resting) {
            g.speed = 0;
            if (goal == 0) g.stop() else {
                g.offset = goal;
                g.prune(cell_h);
            }
            return false;
        }
        g.offset = goal + next;
        g.prune(cell_h);
        return true;
    }

    pub fn draw(g: *const Glide, sn: *gtk.Snapshot, content: *gsk.RenderNode, at: Place) void {
        const offset = at.px.distance(g.offset);
        const top = at.row(g.band.top);
        const bottom = at.row(g.band.bottom);
        clipped(sn, content, at.w, 0, top, 0);
        clipped(sn, content, at.w, bottom, at.h, 0);
        pushRows(sn, at.w, top, bottom);
        defer sn.pop();
        var x: f64 = 0;
        for (g.columns.items) |span| {
            const left = at.column(span.from);
            g.drawBetween(sn, content, at, offset, x, left);
            x = at.column(span.to);
            boxed(sn, content, left, x, top, bottom, 0);
        }
        g.drawBetween(sn, content, at, offset, x, at.w);
        for (g.still.items) |part| {
            boxed(sn, content, at.column(part.from), at.column(part.to), at.row(part.row), at.row(part.row + 1), 0);
        }
    }

    fn drawBetween(g: *const Glide, sn: *gtk.Snapshot, content: *gsk.RenderNode, at: Place, offset: f64, left: f64, right: f64) void {
        if (right <= left) return;
        const top = at.row(g.band.top);
        sn.pushClip(&.{ .f_origin = .{ .f_x = @floatCast(left), .f_y = @floatCast(top) }, .f_size = .{ .f_width = @floatCast(right - left), .f_height = @floatCast(at.row(g.band.bottom) - top) } });
        defer sn.pop();
        g.drawMoving(sn, content, at, offset);
        for (g.strips.items) |strip| {
            const drawn_from = at.row(strip.row);
            const shown_from = at.px.edge(at.pad_y + @as(f64, @floatFromInt(strip.at)) * at.cell_h) + offset;
            pieces(sn, strip.picture, at, drawn_from, at.row(strip.row + 1), shown_from - drawn_from, strip.gaps[0..strip.gap_count]);
        }
    }

    fn drawMoving(g: *const Glide, sn: *gtk.Snapshot, content: *gsk.RenderNode, at: Place, offset: f64) void {
        const parts = g.still.items;
        var next_row = g.band.top;
        var i: usize = 0;
        while (i < parts.len) {
            const row = parts[i].row;
            const first = i;
            while (i < parts.len and parts[i].row == row) i += 1;
            clipped(sn, content, at.w, at.row(next_row), at.row(row), offset);
            pieces(sn, content, at, at.row(row), at.row(row + 1), offset, parts[first..i]);
            next_row = row + 1;
        }
        clipped(sn, content, at.w, at.row(next_row), at.row(g.band.bottom), offset);
    }
};

fn behind(cells: []const Cell, cols: usize, y: usize, from: usize, to: usize) u32 {
    if (from > 0) return cells[y * cols + from - 1].bg;
    return if (to < cols) cells[y * cols + to].bg else 0;
}

fn pushRows(sn: *gtk.Snapshot, w: f64, from: f64, to: f64) void {
    sn.pushClip(&.{ .f_origin = .{ .f_x = 0, .f_y = @floatCast(from) }, .f_size = .{ .f_width = @floatCast(w), .f_height = @floatCast(@max(0, to - from)) } });
}

fn pieces(sn: *gtk.Snapshot, node: *gsk.RenderNode, at: Place, from: f64, to: f64, moved_by: f64, left_out: []const Still) void {
    var x: f64 = 0;
    for (left_out) |part| {
        const left = at.column(part.from);
        boxed(sn, node, x, left, from, to, moved_by);
        x = at.column(part.to);
        if (part.behind == 0 or to <= from) continue;
        const color: gdk.RGBA = .{
            .f_red = @as(f32, @floatFromInt((part.behind >> 16) & 0xff)) / 255,
            .f_green = @as(f32, @floatFromInt((part.behind >> 8) & 0xff)) / 255,
            .f_blue = @as(f32, @floatFromInt(part.behind & 0xff)) / 255,
            .f_alpha = @floatCast(at.fill_alpha),
        };
        sn.appendColor(&color, &.{ .f_origin = .{ .f_x = @floatCast(left), .f_y = @floatCast(from + moved_by) }, .f_size = .{ .f_width = @floatCast(x - left), .f_height = @floatCast(to - from) } });
    }
    boxed(sn, node, x, at.w, from, to, moved_by);
}

fn clipped(sn: *gtk.Snapshot, node: *gsk.RenderNode, w: f64, from: f64, to: f64, moved_by: f64) void {
    boxed(sn, node, 0, w, from, to, moved_by);
}

fn boxed(sn: *gtk.Snapshot, node: *gsk.RenderNode, left: f64, right: f64, from: f64, to: f64, moved_by: f64) void {
    if (to <= from or right <= left) return;
    sn.save();
    defer sn.restore();
    sn.translate(&.{ .f_x = 0, .f_y = @floatCast(moved_by) });
    sn.pushClip(&.{ .f_origin = .{ .f_x = @floatCast(left), .f_y = @floatCast(from) }, .f_size = .{ .f_width = @floatCast(right - left), .f_height = @floatCast(to - from) } });
    defer sn.pop();
    sn.appendNode(node);
}

fn screen(comptime lines: []const []const u8) [lines.len * lines[0].len]Cell {
    var cells: [lines.len * lines[0].len]Cell = undefined;
    for (lines, 0..) |line, y| for (line, 0..) |c, x| {
        cells[y * line.len + x] = .{ .cp = if (c == ' ') 0 else c };
    };
    return cells;
}

const scrolled_from = screen(&.{
    "header line stays ",
    "first of the text ",
    "second line of it ",
    "third line follows",
    "fourth one is here",
    "fifth and the last",
    "prompt row is kept",
});
const scrolled_to = screen(&.{
    "header line stays ",
    "second line of it ",
    "third line follows",
    "fourth one is here",
    "fifth and the last",
    "sixth newly shown ",
    "prompt row is kept",
});

test "a scrolled band is found between rows that stayed put" {
    const up = find(&scrolled_from, &scrolled_to, 18, 7, .either, &.{}).?;
    try std.testing.expectEqual(@as(isize, 1), up.rows);
    try std.testing.expectEqual(Band{ .top = 1, .bottom = 6 }, up.band);
    const down = find(&scrolled_to, &scrolled_from, 18, 7, .either, &.{}).?;
    try std.testing.expectEqual(@as(isize, -1), down.rows);
    try std.testing.expectEqual(Band{ .top = 1, .bottom = 6 }, down.band);
}

test "a shift against the way the wheel turned is not taken" {
    try std.testing.expect(find(&scrolled_from, &scrolled_to, 18, 7, .up, &.{}) != null);
    try std.testing.expectEqual(@as(?Shift, null), find(&scrolled_from, &scrolled_to, 18, 7, .down, &.{}));
}

test "a scrollbar that moved doesn't hide the shift" {
    const before = screen(&.{
        "first of the text  #",
        "second line of it  #",
        "third line follows  ",
        "fourth one is here  ",
        "fifth and the last  ",
        "sixth one after it  ",
    });
    const after = screen(&.{
        "third line follows  ",
        "fourth one is here #",
        "fifth and the last #",
        "sixth one after it  ",
        "seventh newly shown ",
        "eighth newly shown  ",
    });
    const shift = find(&before, &after, 20, 6, .either, &.{}).?;
    try std.testing.expectEqual(@as(isize, 2), shift.rows);
    try std.testing.expectEqual(Band{ .top = 0, .bottom = 6 }, shift.band);
}

test "a scrollbar that appears on every row doesn't hide the shift of short and empty rows" {
    const before = screen(&.{
        "a long line of text ",
        "}                   ",
        "                    ",
        "fi                  ",
        "done                ",
        "                    ",
        "EOF                 ",
        "the last of the text",
    });
    const after = screen(&.{
        "}                  |",
        "                   |",
        "fi                 |",
        "done               |",
        "                   #",
        "EOF                #",
        "the last of the tex|",
        "one more line here |",
    });
    const shift = find(&before, &after, 20, 8, .up, &.{}).?;
    try std.testing.expectEqual(@as(isize, 1), shift.rows);
    try std.testing.expectEqual(Band{ .top = 0, .bottom = 8 }, shift.band);
}

test "a short line under a label still takes its row along, and a pinned copy of the line coming in is left out" {
    const before = screen(&.{
        "the newest request, pinned ",
        "a first line of the answer ",
        "and the second line of it  ",
        "}                          ",
        "done          [ LABEL ]    ",
        "prompt row is kept         ",
    });
    const after = screen(&.{
        "the newest request, pinned ",
        "the newest request, pinned ",
        "a first line of the answer ",
        "and the second line of it  ",
        "}             [ LABEL ]    ",
        "prompt row is kept         ",
    });
    var g: Glide = .{ .cols = 27, .rows = 6 };
    defer g.forget();
    try g.cells.appendSlice(gpa, &before);
    const shift = find(&before, &after, 27, 6, .down, &.{}).?;
    try std.testing.expectEqual(Band{ .top = 0, .bottom = 5 }, shift.band);
    try std.testing.expectEqual(Band{ .top = 1, .bottom = 5 }, g.settled(shift.band, &after));
}

test "scrolling the other way, the row a label had covered still counts, so the row under the label slides in too" {
    const before = screen(&.{
        "a line from above comes in here ",
        "the first line of the text here ",
        "a second line follows the first ",
        "third line of the text [ LABEL ]",
        "prompt row is kept              ",
    });
    const after = screen(&.{
        "the first line of the text here ",
        "a second line follows the first ",
        "third line of the text is here  ",
        "a new line comes in at [ LABEL ]",
        "prompt row is kept              ",
    });
    const label = [_]Still{ .{ .row = 3, .from = 23, .to = 30 }, .{ .row = 3, .from = 31, .to = 32 } };
    try std.testing.expectEqual(@as(?Shift, null), find(&before, &after, 32, 5, .up, &.{}));
    const shift = find(&before, &after, 32, 5, .up, &label).?;
    try std.testing.expectEqual(@as(isize, 1), shift.rows);
    try std.testing.expectEqual(Band{ .top = 0, .bottom = 4 }, shift.band);
    var g: Glide = .{ .cols = 32, .rows = 5, .offset = 20, .band = shift.band };
    defer g.forget();
    try g.cells.appendSlice(gpa, &before);
    try g.remembered.appendSlice(gpa, &label);
    g.findStill(shift, &after);
    try std.testing.expectEqual(@as(usize, 2), g.still.items.len);
    try std.testing.expectEqual(@as(usize, 3), g.still.items[0].row);
}

test "a redraw that moved nothing is not a shift" {
    const before = screen(&.{
        "one line of output",
        "another line of it",
        "a third line there",
        "and a fourth below",
        "                  ",
        "                  ",
    });
    const after = screen(&.{
        "one line of output",
        "another line of it",
        "a third line there",
        "and a fourth below",
        "a fifth has come  ",
        "                  ",
    });
    try std.testing.expectEqual(@as(?Shift, null), find(&before, &after, 18, 6, .either, &.{}));
    try std.testing.expectEqual(@as(?Shift, null), find(&before, &before, 18, 6, .either, &.{}));
}

test "lines that repeat leave the distance unknown, so nothing is taken" {
    const before = screen(&.{
        "the same line of text",
        "another line repeated",
        "the same line of text",
        "another line repeated",
        "the same line of text",
        "another line repeated",
        "the same line of text",
        "another line repeated",
    });
    const after = screen(&.{
        "another line repeated",
        "the same line of text",
        "another line repeated",
        "the same line of text",
        "another line repeated",
        "the same line of text",
        "another line repeated",
        "the same line of text",
    });
    try std.testing.expectEqual(@as(?Shift, null), find(&before, &after, 21, 8, .up, &.{}));
}

test "a band holds until three steps in a row say otherwise, and edge rows that stayed are left out" {
    var g: Glide = .{ .cols = 18, .rows = 7 };
    defer g.forget();
    try g.cells.appendSlice(gpa, &scrolled_from);
    const first = Band{ .top = 1, .bottom = 6 };
    const smaller = Band{ .top = 2, .bottom = 6 };
    try std.testing.expectEqual(first, g.settled(first, &scrolled_to));
    try std.testing.expectEqual(first, g.settled(smaller, &scrolled_to));
    try std.testing.expectEqual(first, g.settled(smaller, &scrolled_to));
    try std.testing.expectEqual(smaller, g.settled(smaller, &scrolled_to));
    try std.testing.expectEqual(smaller, g.known.?);
    try std.testing.expectEqual(first, g.settled(first, &scrolled_to));
    try std.testing.expectEqual(first, g.known.?);
    g.known = .{ .top = 0, .bottom = 7 };
    try std.testing.expectEqual(first, g.settled(first, &scrolled_to));
}

test "a label that stays put over a moving row keeps the row in the band, and only the label still" {
    const before = screen(&.{
        "the first line of the text here ",
        "a second line follows the first ",
        "third line of the text is here  ",
        "the fourth line, under [ LABEL ]",
        "prompt row is kept              ",
    });
    const after = screen(&.{
        "a line from above comes in here ",
        "the first line of the text here ",
        "a second line follows the first ",
        "third line of the text [ LABEL ]",
        "prompt row is kept              ",
    });
    const shift = find(&before, &after, 32, 5, .down, &.{}).?;
    try std.testing.expectEqual(@as(isize, -1), shift.rows);
    try std.testing.expectEqual(Band{ .top = 0, .bottom = 4 }, shift.band);
    var g: Glide = .{ .cols = 32, .rows = 5, .offset = -20, .band = shift.band };
    defer g.forget();
    try g.cells.appendSlice(gpa, &before);
    g.findStill(shift, &after);
    try std.testing.expectEqual(@as(usize, 2), g.still.items.len);
    try std.testing.expectEqual(Still{ .row = 3, .from = 23, .to = 30 }, g.still.items[0]);
    try std.testing.expectEqual(Still{ .row = 3, .from = 31, .to = 32 }, g.still.items[1]);

    const back = screen(&.{
        "the first line of the text here ",
        "a second line follows the first ",
        "third line of the text and more ",
        "a line coming in under [ LABEL ]",
        "prompt row is kept              ",
    });
    g.cells.clearRetainingCapacity();
    try g.cells.appendSlice(gpa, &after);
    g.findStill(.{ .rows = 1, .band = shift.band }, &back);
    try std.testing.expectEqual(@as(usize, 2), g.still.items.len);
    try std.testing.expectEqual(@as(usize, 3), g.still.items[0].row);
}

test "a column that keeps its place, like a scrollbar, is told apart from the text that moved" {
    const before = screen(&.{
        "first line of text |",
        "second line of it  |",
        "third line follows #",
        "fourth one is here #",
        "fifth and the last |",
        "sixth one after it |",
        "seventh line of it |",
        "eighth and the end |",
    });
    const after = screen(&.{
        "second line of it  |",
        "third line follows |",
        "fourth one is here #",
        "fifth and the last #",
        "sixth one after it |",
        "seventh line of it |",
        "eighth and the end |",
        "ninth newly shown  |",
    });
    var g: Glide = .{ .cols = 20, .rows = 8, .offset = 20 };
    defer g.forget();
    try g.cells.appendSlice(gpa, &before);
    g.findColumns(.{ .top = 0, .bottom = 8 }, &after);
    try std.testing.expectEqual(@as(usize, 1), g.columns.items.len);
    try std.testing.expectEqual(Columns{ .from = 19, .to = 20 }, g.columns.items[0]);
}

test "text follows the fingers only as far as a row that left is there to fill the gap" {
    var g: Glide = .{ .band = .{ .top = 1, .bottom = 9 }, .target = 12 };
    defer g.forget();
    try std.testing.expectEqual(@as(f64, 0), g.reachable(20));
    g.offset = 20;
    g.picture = null;
    try std.testing.expect(!g.hasStripAt(0));
}

test "the glide comes to rest without passing its place" {
    var g: Glide = .{ .offset = 40 };
    var frames: usize = 0;
    var last = g.offset;
    while (g.ease(1.0 / 60.0, 20)) : (frames += 1) {
        try std.testing.expect(g.offset > 0 and g.offset < last);
        last = g.offset;
        try std.testing.expect(frames < 60);
    }
    try std.testing.expectEqual(@as(f64, 0), g.offset);
}

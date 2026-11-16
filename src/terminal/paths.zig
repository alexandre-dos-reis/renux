//! Conservative file-path hit testing; quoted paths can contain spaces and soft wraps.
const std = @import("std");
const links = @import("links.zig");
pub const prefix = "renux-file:";

pub fn candidate(text: []const u8) bool {
    if (text.len == 0 or text.len > 4096 or std.mem.indexOfScalar(u8, text, '\n') != null) return false;
    if (std.mem.indexOfScalar(u8, text, ':') != null or std.mem.startsWith(u8, text, "www.") or std.mem.eql(u8, text, "/")) return false;
    if (std.mem.indexOfScalar(u8, text, '/') != null) return true;
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return false;
    if (dot == 0) return text.len > 1;
    const ext = text[dot + 1 ..];
    if (ext.len == 0 or ext.len > 12) return false;
    for (ext) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    // Avoid treating decimal numbers as filenames.
    for (text[0..dot]) |c| if (!std.ascii.isDigit(c)) return true;
    return false;
}

fn space(c: u21) bool {
    return c == ' ' or c == '\t' or c == 0;
}
fn quote(c: u21) bool {
    return c == '\'' or c == '"' or c == '`';
}

pub fn at(a: std.mem.Allocator, rows: []const []const u21, wraps: []const bool, col: usize, row: usize) !?links.Link {
    if (row >= rows.len or col >= rows[row].len) return null;
    var first = row;
    while (first > 0 and first - 1 < wraps.len and wraps[first - 1]) first -= 1;
    var last = row;
    while (last + 1 < rows.len and last < wraps.len and wraps[last]) last += 1;
    var flat: std.ArrayList(u21) = .empty;
    defer flat.deinit(a);
    var hit: usize = col;
    for (first..last + 1) |y| {
        if (y < row) hit += rows[y].len;
        if (flat.items.len + rows[y].len > 16384) return null;
        try flat.appendSlice(a, rows[y]);
    }
    const line = flat.items;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (space(line[i]) or line[i] == '(' or line[i] == '[' or line[i] == '*')) : (i += 1) {}
        if (i == line.len) break;
        const quoted = quote(line[i]);
        const delimiter = line[i];
        if (quoted) i += 1;
        const start = i;
        while (i < line.len and (if (quoted) line[i] != delimiter else !space(line[i]))) : (i += 1) {}
        var end = i;
        var number: [2]usize = .{ 0, 0 };
        if (!quoted) {
            while (end > start and std.mem.indexOfScalar(u21, &.{ ',', ';', ':', ')', ']', '}', '.', '*' }, line[end - 1]) != null) end -= 1;
            // Compiler-style path:line[:column], and a range of lines as coding agents write
            // it, path:line-line. No path here has a colon of its own, so the first one ends
            // the path, and the line after it is kept.
            if (std.mem.indexOfScalar(u21, line[start..end], ':')) |colon| {
                const n = start + colon;
                var digits = n + 1;
                while (digits < end and line[digits] >= '0' and line[digits] <= '9') digits += 1;
                const numbers_only = for (line[digits..end]) |c| {
                    if (!(c >= '0' and c <= '9') and c != ':' and c != '-') break false;
                } else true;
                if (n > start and digits > n + 1 and numbers_only) {
                    number = .{ n + 1, digits };
                    end = n;
                }
            }
        }
        if (hit >= start and hit < end) {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(a);
            for (line[start..end]) |cp| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return null;
                try text.appendSlice(a, buf[0..len]);
            }
            if (!candidate(text.items)) return null;
            if (number[1] > number[0]) {
                try text.append(a, ':');
                for (line[number[0]..number[1]]) |digit| try text.append(a, @intCast(digit));
            }
            var result: links.Link = .{ .url = try std.mem.concat(a, u8, &.{ prefix, text.items }), .segments = .empty };
            errdefer result.deinit(a);
            var offset: usize = 0;
            for (first..last + 1) |y| {
                const from = @max(start, offset);
                const to = @min(end, offset + rows[y].len);
                if (to > from) try result.segments.append(a, .{ .row = y, .start = from - offset, .end = to - offset - 1 });
                offset += rows[y].len;
            }
            return result;
        }
        if (quoted and i < line.len) i += 1;
    }
    return null;
}

/// What a link made by a program points at, when that is a file and not an address on the
/// web: `prefix`, the path, and `:LINE` when the link names a line, as `path:42`, `path#L42`
/// or a `file://` address does. Coding agents link the files they mention this way, most
/// often with no more than a path. Null for anything with another scheme. The caller frees it.
pub fn fromHref(a: std.mem.Allocator, href: []const u8) !?[]u8 {
    var rest = href;
    if (std.ascii.startsWithIgnoreCase(rest, "file://")) {
        rest = rest["file://".len..];
        // Past the host, which is empty or this machine's name.
        rest = rest[std.mem.indexOfScalar(u8, rest, '/') orelse return null ..];
    } else if (schemeOf(rest)) return null;
    var line: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
        // #L42 and #L42-L50, as code hosts write them.
        const mark = std.mem.trimStart(u8, rest[hash + 1 ..], "Ll");
        line = mark[0 .. std.mem.indexOfNone(u8, mark, "0123456789") orelse mark.len];
        rest = rest[0..hash];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |query| rest = rest[0..query];
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        const after = rest[colon + 1 ..];
        const digits = after[0 .. std.mem.indexOfNone(u8, after, "0123456789") orelse after.len];
        if (digits.len == 0 or std.mem.indexOfNone(u8, after, "0123456789:-") != null) return null;
        line = digits;
        rest = rest[0..colon];
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, prefix);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        // %20 and the like are read back into the characters they stand for.
        const byte: ?u8 = if (rest[i] == '%' and i + 2 < rest.len) std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch null else null;
        if (byte) |b| {
            try out.append(a, b);
            i += 2;
        } else try out.append(a, rest[i]);
    }
    const path = out.items[prefix.len..];
    if (path.len == 0 or std.mem.indexOfAny(u8, path, ":\n\x00") != null) {
        out.deinit(a);
        return null;
    }
    if (line.len > 0) {
        try out.append(a, ':');
        try out.appendSlice(a, line);
    }
    return try out.toOwnedSlice(a);
}

/// Whether a link starts with a scheme, as https: and mailto: do. A name followed by a line
/// number, as in main.zig:42, isn't one.
fn schemeOf(href: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, href, ':') orelse return false;
    if (colon < 2 or colon + 1 >= href.len or std.ascii.isDigit(href[colon + 1])) return false;
    if (!std.ascii.isAlphabetic(href[0])) return false;
    for (href[0..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-') return false;
    return true;
}

test "links to files are told from links to the web" {
    const a = std.testing.allocator;
    const cases = [_]struct { href: []const u8, want: ?[]const u8 }{
        .{ .href = "src/main.zig", .want = "src/main.zig" },
        .{ .href = "src/main.zig:42", .want = "src/main.zig:42" },
        .{ .href = "src/main.zig:42:7", .want = "src/main.zig:42" },
        .{ .href = "main.zig:42-50", .want = "main.zig:42" },
        .{ .href = "src/main.zig#L42-L50", .want = "src/main.zig:42" },
        .{ .href = "./my%20notes/a.md", .want = "./my notes/a.md" },
        .{ .href = "file:///home/me/a%20b.png", .want = "/home/me/a b.png" },
        .{ .href = "file://host/tmp/x.txt#L3", .want = "/tmp/x.txt:3" },
        .{ .href = "https://example.com/a.png", .want = null },
        .{ .href = "mailto:me@example.com", .want = null },
        .{ .href = "vscode://file/tmp/x", .want = null },
        .{ .href = "#section", .want = null },
    };
    for (cases) |c| {
        const got = try fromHref(a, c.href);
        defer if (got) |g| a.free(g);
        if (c.want) |w| try std.testing.expectEqualStrings(w, got.?[prefix.len..]) else try std.testing.expect(got == null);
    }
}

test "file candidates reject URLs and ordinary words" {
    for ([_][]const u8{ "./out.png", "~/a.txt", "/tmp/file", "src/main.zig", "README.md", ".gitignore" }) |s| try std.testing.expect(candidate(s));
    for ([_][]const u8{ "hello", "3.14", "https://example.com/a.png", "www.example.com", "a\nb.txt" }) |s| try std.testing.expect(!candidate(s));
}

test "quoted paths soft wraps and line suffixes" {
    const a = std.testing.allocator;
    const cases = [_]struct { text: []const u8, hit: usize, path: []const u8 }{
        .{ .text = "see './my file.png' now", .hit = 12, .path = "./my file.png" },
        .{ .text = "(src/main.zig:42:7)", .hit = 6, .path = "src/main.zig:42" },
        .{ .text = "edit src/rex/server.zig:417-430", .hit = 8, .path = "src/rex/server.zig:417" },
        .{ .text = "see src/v2:10 there", .hit = 5, .path = "src/v2:10" },
        .{ .text = "created /tmp/result.png,", .hit = 14, .path = "/tmp/result.png" },
        .{ .text = "**./output.png**", .hit = 7, .path = "./output.png" },
    };
    for (cases) |c| {
        var row: [128]u21 = undefined;
        for (c.text, 0..) |ch, j| row[j] = ch;
        var l = (try at(a, &.{row[0..c.text.len]}, &.{false}, c.hit, 0)).?;
        defer l.deinit(a);
        try std.testing.expectEqualStrings(c.path, l.url[prefix.len..]);
    }
    const r1 = [_]u21{ '.', '/', 'l', 'o', 'n', 'g' };
    const r2 = [_]u21{ '.', 'p', 'n', 'g' };
    var l = (try at(a, &.{ &r1, &r2 }, &.{true}, 1, 1)).?;
    defer l.deinit(a);
    try std.testing.expectEqualStrings("./long.png", l.url[prefix.len..]);
    try std.testing.expectEqual(@as(usize, 2), l.segments.items.len);
}

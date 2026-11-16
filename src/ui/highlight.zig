//! Colors for a few lines of code, told by words and marks alone: comments, strings, numbers
//! and the words a language keeps for itself. There is no grammar behind it, so it can be wrong
//! at the edges, such as inside a comment that began lines earlier. It is for a glance.
const std = @import("std");

/// How a file's text is read. The first few only know a comment's mark.
pub const Lang = enum { none, data, hash, dash, slash, zig, python, js, go, rust, c, lua, ruby, shell };

/// 0xRRGGBB for each kind of word. Comments are the text's own color, dimmed.
pub const Colors = struct { string: u32, number: u32, keyword: u32, builtin: u32 };

/// One line as Pango markup. The caller frees it.
pub fn markup(a: std.mem.Allocator, line: []const u8, lang: Lang, colors: Colors) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (lang == .none) {
        try escape(a, &out, line);
        return out.toOwnedSliceSentinel(a, 0);
    }
    const comment = commentOf(lang);
    const words = keywordsOf(lang);
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (comment) |mark| if (std.mem.startsWith(u8, line[i..], mark)) {
            try out.appendSlice(a, "<span alpha=\"55%\">");
            try escape(a, &out, line[i..]);
            try out.appendSlice(a, "</span>");
            break;
        };
        if (c == '"' or c == '\'' or c == '`') {
            // In these a single quote holds one character, and a lone one is a lifetime or
            // an apostrophe, not the start of a string.
            const one = c == '\'' and (lang == .rust or lang == .c or lang == .zig or lang == .go);
            const end = (if (one) character(line, i) else closing(line, i)) orelse if (c == '"') line.len else {
                try escape(a, &out, line[i .. i + 1]);
                i += 1;
                continue;
            };
            try span(a, &out, colors.string, line[i..end]);
            i = end;
        } else if (std.ascii.isDigit(c) and (i == 0 or !word(line[i - 1]))) {
            var end = i + 1;
            while (end < line.len and (word(line[end]) or (line[end] == '.' and end + 1 < line.len and std.ascii.isDigit(line[end + 1])))) end += 1;
            try span(a, &out, colors.number, line[i..end]);
            i = end;
        } else if (std.ascii.isAlphabetic(c) or c == '_' or (c == '@' and lang == .zig)) {
            var end = i + 1;
            while (end < line.len and word(line[end])) end += 1;
            const text = line[i..end];
            if (c == '@' and end > i + 1) {
                try span(a, &out, colors.builtin, text);
            } else if (words.has(text)) {
                try span(a, &out, colors.keyword, text);
            } else try escape(a, &out, text);
            i = end;
        } else {
            // Whole characters go through together, so none is cut in half.
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const end = @min(line.len, i + len);
            try escape(a, &out, line[i..end]);
            i = end;
        }
    }
    return out.toOwnedSliceSentinel(a, 0);
}

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Just past the quote that ends the string starting at `from`, if the line has one.
fn closing(line: []const u8, from: usize) ?usize {
    var i = from + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
        } else if (line[i] == line[from]) return i + 1;
    }
    return null;
}

/// Just past a one-character literal such as 'a' or '\n' starting at `from`, if that is one.
fn character(line: []const u8, from: usize) ?usize {
    if (from + 1 >= line.len) return null;
    if (line[from + 1] == '\\') return closing(line, from);
    const len = std.unicode.utf8ByteSequenceLength(line[from + 1]) catch return null;
    const end = from + 1 + len;
    return if (end < line.len and line[end] == '\'') end + 1 else null;
}

fn span(a: std.mem.Allocator, out: *std.ArrayList(u8), color: u32, text: []const u8) !void {
    var buf: [40]u8 = undefined;
    try out.appendSlice(a, std.fmt.bufPrint(&buf, "<span foreground=\"#{x:0>6}\">", .{color & 0xffffff}) catch unreachable);
    try escape(a, out, text);
    try out.appendSlice(a, "</span>");
}

fn escape(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        else => try out.append(a, c),
    };
}

fn commentOf(lang: Lang) ?[]const u8 {
    return switch (lang) {
        .none, .data => null,
        .hash, .python, .ruby, .shell => "#",
        .dash, .lua => "--",
        .slash, .zig, .js, .go, .rust, .c => "//",
    };
}

const Words = std.StaticStringMap(void);
const no_words = Words.initComptime(.{});

fn keywordsOf(lang: Lang) *const Words {
    return switch (lang) {
        .none, .data, .hash, .dash, .slash => &no_words,
        .zig => &zig_words,
        .python => &python_words,
        .js => &js_words,
        .go => &go_words,
        .rust => &rust_words,
        .c => &c_words,
        .lua => &lua_words,
        .ruby => &ruby_words,
        .shell => &shell_words,
    };
}

fn set(comptime list: []const []const u8) Words {
    comptime var pairs: [list.len]struct { []const u8 } = undefined;
    inline for (list, 0..) |w, i| pairs[i] = .{w};
    const final = pairs;
    return Words.initComptime(final);
}

const zig_words = set(&.{ "fn", "pub", "const", "var", "return", "if", "else", "for", "while", "switch", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "struct", "enum", "union", "comptime", "inline", "export", "extern", "test", "and", "or", "error", "unreachable", "null", "undefined", "true", "false", "callconv", "packed", "opaque", "anytype", "void", "noreturn", "usingnamespace", "threadlocal", "volatile", "align", "linksection", "nosuspend", "suspend", "resume", "async", "await" });
const python_words = set(&.{ "def", "class", "import", "from", "as", "return", "if", "elif", "else", "for", "while", "in", "is", "not", "and", "or", "lambda", "pass", "raise", "try", "except", "finally", "with", "yield", "global", "nonlocal", "del", "assert", "break", "continue", "async", "await", "None", "True", "False", "self", "match", "case" });
const js_words = set(&.{ "function", "const", "let", "var", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "class", "extends", "super", "import", "export", "from", "as", "typeof", "instanceof", "in", "of", "try", "catch", "finally", "throw", "async", "await", "yield", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "void", "delete" });
const go_words = set(&.{ "func", "package", "import", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "select", "struct", "interface", "map", "type", "var", "const", "fallthrough", "goto", "nil", "true", "false" });
const rust_words = set(&.{ "fn", "pub", "let", "mut", "const", "static", "return", "if", "else", "for", "while", "loop", "match", "break", "continue", "struct", "enum", "trait", "impl", "use", "mod", "crate", "self", "Self", "super", "where", "as", "in", "ref", "move", "dyn", "unsafe", "async", "await", "type", "true", "false" });
const c_words = set(&.{ "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "struct", "union", "enum", "typedef", "const", "static", "extern", "inline", "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed", "bool", "sizeof", "class", "public", "private", "protected", "virtual", "override", "template", "typename", "namespace", "using", "new", "delete", "this", "try", "catch", "throw", "throws", "nullptr", "null", "true", "false", "auto", "constexpr", "final", "abstract", "interface", "extends", "implements", "import", "package", "fun", "val", "var", "func", "let", "guard", "when", "object", "super" });
const lua_words = set(&.{ "function", "local", "return", "if", "then", "else", "elseif", "end", "for", "while", "do", "repeat", "until", "break", "in", "and", "or", "not", "nil", "true", "false", "goto" });
const ruby_words = set(&.{ "def", "class", "module", "end", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "require", "include", "extend", "self", "nil", "true", "false", "and", "or", "not", "then", "case", "when", "break", "next", "super", "lambda", "proc" });
const shell_words = set(&.{ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "local", "export", "readonly", "unset", "set", "exit", "break", "continue", "source", "echo" });

test "words, strings, numbers and comments get their colors" {
    const a = std.testing.allocator;
    const colors: Colors = .{ .string = 0x00aa00, .number = 0xaaaa00, .keyword = 0xaa00aa, .builtin = 0x00aaaa };
    const zig = try markup(a, "const n: u8 = @min(x, 42); // a <b>", .zig, colors);
    defer a.free(zig);
    try std.testing.expectEqualStrings("<span foreground=\"#aa00aa\">const</span> n: u8 = <span foreground=\"#00aaaa\">@min</span>(x, <span foreground=\"#aaaa00\">42</span>); <span alpha=\"55%\">// a &lt;b&gt;</span>", zig);
    const py = try markup(a, "s = 'it''s' # x", .python, colors);
    defer a.free(py);
    try std.testing.expectEqualStrings("s = <span foreground=\"#00aa00\">'it'</span><span foreground=\"#00aa00\">'s'</span> <span alpha=\"55%\"># x</span>", py);
    const life = try markup(a, "fn f<'a>(x: &'a str)", .rust, colors);
    defer a.free(life);
    try std.testing.expectEqualStrings("<span foreground=\"#aa00aa\">fn</span> f&lt;'a&gt;(x: &amp;'a str)", life);
    const prose = try markup(a, "if a < b & c", .none, colors);
    defer a.free(prose);
    try std.testing.expectEqualStrings("if a &lt; b &amp; c", prose);
}

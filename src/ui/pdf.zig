//! The first page of a PDF as a picture, drawn by Poppler. Not on a Mac, where Renux is only
//! built for development and Poppler isn't linked.
const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const cairo = @import("cairo");

pub const supported = builtin.os.tag != .macos;

// The bindings Renux is built with have nothing for Poppler, so the few calls used are named here.
const Document = opaque {};
const Page = opaque {};
extern "c" fn poppler_document_new_from_bytes(bytes: *glib.Bytes, password: ?[*:0]const u8, err: ?*?*glib.Error) ?*Document;
extern "c" fn poppler_document_get_n_pages(doc: *Document) c_int;
extern "c" fn poppler_document_get_page(doc: *Document, index: c_int) ?*Page;
extern "c" fn poppler_page_get_size(page: *Page, width: *f64, height: *f64) void;
extern "c" fn poppler_page_render(page: *Page, cr: *cairo.Context) void;

/// Whether a file's bytes are a PDF's, by how they begin.
pub fn isPdf(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "%PDF-");
}

pub const FirstPage = struct { texture: *gdk.Texture, pages: u32 };

/// The first page on white, as large as fits in `max_w` by `max_h` pixels, and how many pages
/// there are. Null for a PDF that can't be read, such as one that wants a password. Slow
/// enough to belong on a worker.
pub fn firstPage(bytes: *glib.Bytes, max_w: f64, max_h: f64) ?FirstPage {
    if (!supported) return null;
    const doc = poppler_document_new_from_bytes(bytes, null, null) orelse return null;
    defer @as(*gobject.Object, @ptrCast(@alignCast(doc))).unref();
    const count = poppler_document_get_n_pages(doc);
    if (count < 1) return null;
    const page = poppler_document_get_page(doc, 0) orelse return null;
    defer @as(*gobject.Object, @ptrCast(@alignCast(page))).unref();
    var w: f64 = 0;
    var h: f64 = 0;
    poppler_page_get_size(page, &w, &h);
    // Written so that a size that isn't a number fails too.
    if (!(w >= 1 and h >= 1 and w <= 100_000 and h <= 100_000)) return null;
    const scale = @min(max_w / w, max_h / h);
    const pw: c_int = @intFromFloat(@max(1, @round(w * scale)));
    const ph: c_int = @intFromFloat(@max(1, @round(h * scale)));

    const surface = cairo.Surface.imageCreate(.argb32, pw, ph);
    defer surface.destroy();
    if (surface.status() != .success) return null;
    const cr = cairo.Context.create(surface);
    cr.setSourceRgb(1, 1, 1);
    cr.paint();
    cr.scale(scale, scale);
    poppler_page_render(page, cr);
    const drawn = cr.status() == .success;
    cr.destroy();
    if (!drawn) return null;
    surface.flush();

    const pixels = surface.imageGetData() orelse return null;
    const stride: usize = @intCast(surface.imageGetStride());
    const copy = glib.Bytes.new(pixels, stride * @as(usize, @intCast(ph)));
    defer copy.unref();
    // Cairo's pixels are in this order on the processors Renux runs on.
    const texture = gdk.MemoryTexture.new(pw, ph, .b8g8r8a8_premultiplied, copy, stride);
    return .{ .texture = texture.as(gdk.Texture), .pages = @intCast(count) };
}

test "a PDF is known by how it begins" {
    try std.testing.expect(isPdf("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"));
    try std.testing.expect(!isPdf("see %PDF-1.7"));
    try std.testing.expect(!isPdf(""));
}

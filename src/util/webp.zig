//! WebP decoding through libwebp, when the build asked for it.
//!
//! charttable decodes PNG itself (util/png.zig) because that is what most
//! tile servers send and a decoder for it is small. WebP is neither: VP8L
//! alone is Huffman coding, LZ77 backreferences, a color cache and four
//! transforms. Elevation tiles are commonly served as WebP, so rather than
//! carry a second codec this links the reference library — but only when
//! `-Dwebp=true`, so an embedder that does not need it does not acquire the
//! dependency.
//!
//! Without the option every call reports Unsupported, which the raster path
//! already handles the same way it handles a broken tile.

const std = @import("std");
const build_opts = @import("ct_build");

pub const have = build_opts.webp;

pub const Error = error{
    /// Not a WebP, or a WebP this build cannot read.
    Unsupported,
    /// A WebP whose header is intact but whose body is not.
    Malformed,
    OutOfMemory,
};

const c = if (have) @cImport({
    @cInclude("webp/decode.h");
}) else struct {};

/// Whether these bytes are a WebP at all: "RIFF" size "WEBP".
pub fn looksLikeWebp(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP");
}

pub const Image = struct {
    w: u32,
    h: u32,
    /// Straight-alpha RGBA8, allocated from the caller's allocator.
    rgba: []u8,
};

/// Decode to RGBA8. The pixels are copied out of libwebp's buffer into
/// `arena` so the caller's memory rules are the same as for PNG.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (!have) return error.Unsupported;
    if (!looksLikeWebp(bytes)) return error.Unsupported;

    var w: c_int = 0;
    var h: c_int = 0;
    if (c.WebPGetInfo(bytes.ptr, bytes.len, &w, &h) == 0) return error.Malformed;
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.Unsupported;

    // WebPDecodeRGBA writes the DECODED dimensions back into w and h, so the
    // check above was made against WebPGetInfo's answer and no longer covers
    // the numbers the allocation below uses. Check the ones that survived.
    const pixels = c.WebPDecodeRGBA(bytes.ptr, bytes.len, &w, &h) orelse return error.Malformed;
    defer c.WebPFree(pixels);
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.Unsupported;

    const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const out = try arena.alloc(u8, n);
    @memcpy(out, pixels[0..n]);
    return .{ .w = @intCast(w), .h = @intCast(h), .rgba = out };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "the RIFF/WEBP signature is what selects this decoder" {
    try testing.expect(looksLikeWebp("RIFF\x00\x00\x00\x00WEBPVP8L"));
    try testing.expect(!looksLikeWebp("RIFF\x00\x00\x00\x00WAVEfmt "));
    try testing.expect(!looksLikeWebp("\x89PNG\r\n\x1a\n\x00\x00\x00\x0d"));
    try testing.expect(!looksLikeWebp("RIFF"));
    try testing.expect(!looksLikeWebp(""));
}

test "a build without libwebp declines rather than pretending" {
    if (have) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Unsupported, decode(arena.allocator(), "RIFF\x00\x00\x00\x00WEBPVP8L"));
}

test "a real WebP decodes when the build has libwebp" {
    if (!have) return error.SkipZigTest;
    const env = std.c.getenv("CHARTTABLE_TEST_WEBP") orelse return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(env), a, .limited(16 << 20)) catch
        return error.SkipZigTest;
    const img = try decode(a, bytes);
    try testing.expect(img.w > 0 and img.h > 0);
    try testing.expectEqual(@as(usize, img.w) * img.h * 4, img.rgba.len);
}

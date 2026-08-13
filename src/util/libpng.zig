//! PNG decoding through libpng, when the build asked for it.
//!
//! charttable ships its own PNG reader (util/png.zig) so an embedder needs
//! no dependency to draw a sprite sheet or a raster tile. libpng is offered
//! alongside it for two reasons: it reads the shapes ours declines
//! (interlaced, 16-bit) and it is the reference for correctness.
//!
//! Whether it is FASTER is a question for a measurement, not an assumption;
//! `png.zig` carries the benchmark that compares them on a real tile.
//!
//! This uses libpng's simplified API (png_image_*, 1.6+), which is a few
//! calls rather than the callback-driven one. PNG_IMAGE_SIZE is a macro that
//! does not survive translation, so the buffer size is computed here: the
//! format is fixed to RGBA8, so it is w * h * 4.

const std = @import("std");
const build_opts = @import("ct_build");

pub const have = build_opts.libpng;

pub const Error = error{
    /// Not a PNG, or one libpng could not read.
    Malformed,
    /// This build has no libpng.
    Unsupported,
    OutOfMemory,
};

const c = if (have) @cImport({
    @cInclude("png.h");
}) else struct {};

pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8,
};

pub fn decode(arena: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (!have) return error.Unsupported;

    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;

    if (c.png_image_begin_read_from_memory(&image, bytes.ptr, bytes.len) == 0)
        return error.Malformed;
    // On any later failure libpng wants this called to release its state.
    errdefer c.png_image_free(&image);

    if (image.width == 0 or image.height == 0 or image.width > 16384 or image.height > 16384) {
        c.png_image_free(&image);
        return error.Malformed;
    }

    image.format = c.PNG_FORMAT_RGBA;
    const n = @as(usize, image.width) * image.height * 4;
    const out = try arena.alloc(u8, n);

    // stride 0 means "packed rows", which is what the size above assumes.
    if (c.png_image_finish_read(&image, null, out.ptr, 0, null) == 0)
        return error.Malformed;

    return .{ .w = image.width, .h = image.height, .rgba = out };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "a build without libpng declines rather than pretending" {
    if (have) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Unsupported, decode(arena.allocator(), "\x89PNG\r\n\x1a\n"));
}

test "libpng and our own reader agree, pixel for pixel" {
    if (!have) return error.SkipZigTest;
    const png = @import("png.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every color type our reader claims, round-tripped through both.
    const px = try a.alloc(u8, 16 * 16 * 4);
    for (px, 0..) |*b, i| b.* = @intCast((i * 37) % 256);
    const encoded = try png.encode(a, px, 16, 16);

    const ours = try png.read(a, encoded);
    const theirs = try decode(a, encoded);
    try testing.expectEqual(ours.w, theirs.w);
    try testing.expectEqual(ours.h, theirs.h);
    try testing.expectEqualSlices(u8, ours.rgba, theirs.rgba);
}

test "libpng reads a real palette tile the same way we do" {
    if (!have) return error.SkipZigTest;
    const png = @import("png.zig");
    const env = std.c.getenv("CHARTTABLE_TEST_PNG") orelse return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(env), a, .limited(16 << 20)) catch
        return error.SkipZigTest;

    const ours = try png.read(a, bytes);
    const theirs = try decode(a, bytes);
    try testing.expectEqual(ours.w, theirs.w);
    try testing.expectEqual(ours.h, theirs.h);
    try testing.expectEqualSlices(u8, ours.rgba, theirs.rgba);
}

test "BENCH: libpng against the built-in reader on a real tile" {
    if (!have) return error.SkipZigTest;
    const png = @import("png.zig");
    const clock = @import("clock.zig");
    const env = std.c.getenv("CHARTTABLE_TEST_PNG") orelse return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(env), a, .limited(16 << 20)) catch
        return error.SkipZigTest;

    const rounds = 200;
    // Each decode gets its own arena so the allocator is not the thing being
    // measured, and so neither decoder benefits from the other's warm pages.
    var t0 = clock.wallMs();
    for (0..rounds) |_| {
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        _ = try png.read(scratch.allocator(), bytes);
    }
    const ours_ms = clock.wallMs() - t0;

    t0 = clock.wallMs();
    for (0..rounds) |_| {
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        _ = try decode(scratch.allocator(), bytes);
    }
    const theirs_ms = clock.wallMs() - t0;

    std.debug.print(
        "\npng decode x{d}: built-in {d} ms, libpng {d} ms\n",
        .{ rounds, ours_ms, theirs_ms },
    );
}

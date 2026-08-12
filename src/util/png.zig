//! Minimal PNG codec.
//!
//! Writer: RGBA8, uncompressed DEFLATE stored blocks — enough to dump
//! offscreen GPU readbacks on a headless box, not a general encoder.
//!
//! Reader: 8-bit grayscale / grayscale+alpha / RGB / RGBA, all five filter
//! types, non-interlaced, zlib via std.compress.flate — what sprite sheets
//! and baked atlases actually are (PNG format per RFC 2083; tile57's writers
//! were the cross-check). Everything else is error.Unsupported; anything
//! structurally wrong (bad CRC, truncation, bogus filter byte) is
//! error.Malformed, never a crash.
const std = @import("std");

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn beU32(w: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try w.append(a, @intCast((v >> 24) & 0xff));
    try w.append(a, @intCast((v >> 16) & 0xff));
    try w.append(a, @intCast((v >> 8) & 0xff));
    try w.append(a, @intCast(v & 0xff));
}

fn chunk(w: *std.ArrayList(u8), a: std.mem.Allocator, typ: []const u8, data: []const u8) !void {
    try beU32(w, a, @intCast(data.len));
    const start = w.items.len;
    try w.appendSlice(a, typ);
    try w.appendSlice(a, data);
    const crc = std.hash.Crc32.hash(w.items[start..]);
    try beU32(w, a, crc);
}

/// Encode an RGBA8 image (top-to-bottom rows) as PNG bytes. Caller owns the
/// returned slice.
pub fn encode(a: std.mem.Allocator, px: []const u8, width: u32, height: u32) ![]u8 {
    std.debug.assert(px.len == @as(usize, width) * height * 4);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, a, "IHDR", &ihdr);

    // raw (filtered) scanlines: filter byte 0 + row
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        try raw.append(a, 0);
        try raw.appendSlice(a, px[y * width * 4 .. (y + 1) * width * 4]);
    }
    // zlib stream: header + stored deflate blocks + adler32
    var zl: std.ArrayList(u8) = .empty;
    defer zl.deinit(a);
    try zl.appendSlice(a, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.items.len) {
        const n: usize = @min(raw.items.len - off, 65535);
        const final: u8 = if (off + n >= raw.items.len) 1 else 0;
        try zl.append(a, final); // BTYPE=00 stored
        try zl.append(a, @intCast(n & 0xff));
        try zl.append(a, @intCast((n >> 8) & 0xff));
        try zl.append(a, @intCast((~n) & 0xff));
        try zl.append(a, @intCast(((~n) >> 8) & 0xff));
        try zl.appendSlice(a, raw.items[off .. off + n]);
        off += n;
    }
    try beU32(&zl, a, adler32(raw.items));
    try chunk(&out, a, "IDAT", zl.items);
    try chunk(&out, a, "IEND", "");
    return out.toOwnedSlice(a);
}

/// Write an RGBA8 image (top-to-bottom rows) as a PNG file.
pub fn write(a: std.mem.Allocator, path: []const u8, px: []const u8, width: u32, height: u32) !void {
    const bytes = try encode(a, px, width, height);
    defer a.free(bytes);
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ---- reader ---------------------------------------------------------------

/// A decoded image, always expanded to RGBA8 (top-to-bottom rows).
pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8,
};

pub const ReadError = error{
    /// Structurally broken: bad signature/CRC/zlib stream, truncated,
    /// impossible sizes, invalid filter byte.
    Malformed,
    /// Valid PNG, but a shape this minimal reader does not do: interlaced,
    /// palette, bit depths other than 8, or absurd dimensions.
    Unsupported,
    OutOfMemory,
};

const sig = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
/// Dimension cap: bounds every allocation (16384² RGBA = 1 GiB worst case)
/// so hostile headers cannot ask for arbitrary memory.
const max_dim: u32 = 16384;

/// Decode a PNG. `arena` should be an arena allocator — intermediate buffers
/// (inflate window, raw scanlines) are not individually freed. `Image.rgba`
/// lives in the same arena.
pub fn read(arena: std.mem.Allocator, bytes: []const u8) ReadError!Image {
    if (bytes.len < sig.len or !std.mem.eql(u8, bytes[0..sig.len], &sig))
        return error.Malformed;

    var width: u32 = 0;
    var height: u32 = 0;
    var channels: u32 = 0;
    var seen_ihdr = false;
    var idat: std.ArrayList(u8) = .empty;

    // Chunk walk. Every length is validated against the remaining input and
    // every chunk's CRC is checked before its data is believed.
    var pos: usize = sig.len;
    walk: while (true) {
        if (bytes.len - pos < 12) return error.Malformed; // len + type + crc
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;
        if (len > 0x7FFF_FFFF) return error.Malformed;
        if (bytes.len - pos < @as(usize, len) + 8) return error.Malformed;
        const typ = bytes[pos..][0..4];
        const data = bytes[pos + 4 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 4 + len ..][0..4], .big);
        if (crc != std.hash.Crc32.hash(bytes[pos .. pos + 4 + len]))
            return error.Malformed;
        pos += 4 + len + 4;

        if (std.mem.eql(u8, typ, "IHDR")) {
            if (seen_ihdr or len != 13) return error.Malformed;
            seen_ihdr = true;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0) return error.Malformed;
            if (width > max_dim or height > max_dim) return error.Unsupported;
            if (data[8] != 8) return error.Unsupported; // bit depth
            channels = switch (data[9]) { // color type
                0 => 1, // grayscale
                2 => 3, // RGB
                4 => 2, // grayscale + alpha
                6 => 4, // RGBA
                3 => return error.Unsupported, // palette
                else => return error.Malformed,
            };
            if (data[10] != 0) return error.Malformed; // compression method
            if (data[11] != 0) return error.Malformed; // filter method
            switch (data[12]) { // interlace
                0 => {},
                1 => return error.Unsupported, // Adam7
                else => return error.Malformed,
            }
        } else {
            if (!seen_ihdr) return error.Malformed; // IHDR must come first
            if (std.mem.eql(u8, typ, "IDAT")) {
                try idat.appendSlice(arena, data);
            } else if (std.mem.eql(u8, typ, "IEND")) {
                if (len != 0) return error.Malformed;
                break :walk; // trailing bytes after IEND are ignored
            }
            // Any other chunk (tRNS, gAMA, tEXt, …) is skipped.
        }
    }
    if (idat.items.len == 0) return error.Malformed;

    // Inflate the zlib stream into exactly the filtered-scanline size:
    // height rows of (filter byte + width*channels). Anything shorter or
    // longer than that is malformed, and the adler footer must match.
    const stride: usize = @as(usize, width) * channels;
    const raw = try arena.alloc(u8, height * (1 + stride));
    var in: std.Io.Reader = .fixed(idat.items);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, window);
    dec.reader.readSliceAll(raw) catch return error.Malformed;
    if (dec.reader.takeByte()) |_| {
        return error.Malformed; // decompressed stream longer than the image
    } else |e| if (e != error.EndOfStream) return error.Malformed;
    if (dec.container_metadata.zlib.adler != adler32(raw)) return error.Malformed;

    // Unfilter (RFC 2083 §6): bpp is whole bytes at 8-bit depth, prior row
    // is the already-reconstructed one.
    const pix = try arena.alloc(u8, height * stride);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src = raw[y * (1 + stride) + 1 ..][0..stride];
        const dst = pix[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else pix[(y - 1) * stride ..][0..stride];
        try unfilterRow(raw[y * (1 + stride)], src, dst, prev, channels);
    }

    // Expand to RGBA.
    const rgba = try arena.alloc(u8, @as(usize, width) * height * 4);
    const n: usize = @as(usize, width) * height;
    switch (channels) {
        1 => for (0..n) |i| {
            const v = pix[i];
            rgba[i * 4 ..][0..4].* = .{ v, v, v, 255 };
        },
        2 => for (0..n) |i| {
            const v = pix[i * 2];
            rgba[i * 4 ..][0..4].* = .{ v, v, v, pix[i * 2 + 1] };
        },
        3 => for (0..n) |i| {
            rgba[i * 4 ..][0..4].* = .{ pix[i * 3], pix[i * 3 + 1], pix[i * 3 + 2], 255 };
        },
        4 => @memcpy(rgba, pix),
        else => unreachable,
    }
    return .{ .w = width, .h = height, .rgba = rgba };
}

fn unfilterRow(filter: u8, src: []const u8, dst: []u8, prev: ?[]const u8, bpp: u32) error{Malformed}!void {
    switch (filter) {
        0 => @memcpy(dst, src),
        1 => for (src, 0..) |v, i| { // Sub: left neighbour
            dst[i] = v +% (if (i >= bpp) dst[i - bpp] else 0);
        },
        2 => for (src, 0..) |v, i| { // Up
            dst[i] = v +% (if (prev) |p| p[i] else 0);
        },
        3 => for (src, 0..) |v, i| { // Average
            const a: u32 = if (i >= bpp) dst[i - bpp] else 0;
            const b: u32 = if (prev) |p| p[i] else 0;
            dst[i] = v +% @as(u8, @intCast((a + b) / 2));
        },
        4 => for (src, 0..) |v, i| { // Paeth
            const a: u8 = if (i >= bpp) dst[i - bpp] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            dst[i] = v +% paeth(a, b, c);
        },
        else => return error.Malformed,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// Deterministic test pixels with structure a filter acts on.
fn fillPattern(px: []u8) void {
    for (px, 0..) |*v, i| v.* = @truncate(i * 7 + (i >> 3) * 13 + 5);
}

test "round-trip: encode then read gives back the same RGBA" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = 13; // deliberately not a power of two
    const h = 7;
    const px = try a.alloc(u8, w * h * 4);
    fillPattern(px);

    const bytes = try encode(a, px, w, h);
    const img = try read(a, bytes);
    try testing.expectEqual(@as(u32, w), img.w);
    try testing.expectEqual(@as(u32, h), img.h);
    try testing.expectEqualSlices(u8, px, img.rgba);
}

// Test-side FORWARD filtering (the inverse of unfilterRow), so the reader's
// five unfilters are checked against ground truth rather than themselves.
fn filterRow(filter: u8, cur: []const u8, prev: ?[]const u8, out: []u8, bpp: u32) void {
    for (cur, 0..) |v, i| {
        const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        out[i] = switch (filter) {
            0 => v,
            1 => v -% a,
            2 => v -% b,
            3 => v -% @as(u8, @intCast((@as(u32, a) + b) / 2)),
            4 => v -% paeth(a, b, c),
            else => unreachable,
        };
    }
}

// Build a PNG in the test: filtered scanlines (one filter per row, cycling
// through all five) in a stored-block zlib stream, real CRCs throughout.
fn makePng(a: std.mem.Allocator, color_type: u8, channels: u32, w: u32, h: u32, pix: []const u8) ![]u8 {
    const stride = w * channels;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    const row_buf = try a.alloc(u8, stride);
    defer a.free(row_buf);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const filter: u8 = @intCast(y % 5);
        const cur = pix[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else pix[(y - 1) * stride ..][0..stride];
        filterRow(filter, cur, prev, row_buf, channels);
        try raw.append(a, filter);
        try raw.appendSlice(a, row_buf);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &sig);
    var ihdr: [13]u8 = .{0} ** 13;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = color_type;
    try chunk(&out, a, "IHDR", &ihdr);

    var zl: std.ArrayList(u8) = .empty;
    defer zl.deinit(a);
    try zl.appendSlice(a, &.{ 0x78, 0x01 });
    std.debug.assert(raw.items.len <= 65535);
    try zl.append(a, 1); // BFINAL, stored
    try zl.append(a, @intCast(raw.items.len & 0xff));
    try zl.append(a, @intCast(raw.items.len >> 8));
    try zl.append(a, @intCast(~raw.items.len & 0xff));
    try zl.append(a, @intCast((~raw.items.len >> 8) & 0xff));
    try zl.appendSlice(a, raw.items);
    try beU32(&zl, a, adler32(raw.items));
    // Split the stream across two IDAT chunks to prove concatenation works.
    const half = zl.items.len / 2;
    try chunk(&out, a, "IDAT", zl.items[0..half]);
    try chunk(&out, a, "tEXt", "comment\x00skipped"); // ancillary between IDATs
    try chunk(&out, a, "IDAT", zl.items[half..]);
    try chunk(&out, a, "IEND", "");
    return out.toOwnedSlice(a);
}

test "all five filters reconstruct, for every supported color type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { ct: u8, ch: u32 }{
        .{ .ct = 0, .ch = 1 }, // grayscale
        .{ .ct = 4, .ch = 2 }, // grayscale + alpha
        .{ .ct = 2, .ch = 3 }, // RGB
        .{ .ct = 6, .ch = 4 }, // RGBA
    };
    const w = 11;
    const h = 10; // 10 rows: each of the 5 filters twice
    for (cases) |case| {
        const pix = try a.alloc(u8, w * h * case.ch);
        fillPattern(pix);
        const bytes = try makePng(a, case.ct, case.ch, w, h, pix);
        const img = try read(a, bytes);
        try testing.expectEqual(@as(u32, w), img.w);
        try testing.expectEqual(@as(u32, h), img.h);
        // Check the expansion to RGBA per pixel.
        for (0..@as(usize, w) * h) |i| {
            const got = img.rgba[i * 4 ..][0..4];
            const s = pix[i * case.ch ..];
            const want: [4]u8 = switch (case.ch) {
                1 => .{ s[0], s[0], s[0], 255 },
                2 => .{ s[0], s[0], s[0], s[1] },
                3 => .{ s[0], s[1], s[2], 255 },
                4 => .{ s[0], s[1], s[2], s[3] },
                else => unreachable,
            };
            try testing.expectEqualSlices(u8, &want, got);
        }
    }
}

test "a really-compressed stream decodes (std flate round trip)" {
    // The in-house encoder only emits stored blocks; a foreign sprite sheet
    // arrives with fixed/dynamic Huffman. Build one with std's compressor.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = 64;
    const h = 32;
    const px = try a.alloc(u8, w * h * 4);
    fillPattern(px);
    var raw: std.ArrayList(u8) = .empty;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        try raw.append(a, 0); // filter none
        try raw.appendSlice(a, px[y * w * 4 ..][0 .. w * 4]);
    }

    var zl: std.Io.Writer.Allocating = try .initCapacity(a, 256);
    const cwin = try a.alloc(u8, std.compress.flate.max_window_len);
    var comp = try std.compress.flate.Compress.init(&zl.writer, cwin, .zlib, .default);
    try comp.writer.writeAll(raw.items);
    try comp.finish();

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &sig);
    var ihdr: [13]u8 = .{0} ** 13;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    try chunk(&out, a, "IHDR", &ihdr);
    try chunk(&out, a, "IDAT", zl.written());
    try chunk(&out, a, "IEND", "");

    const img = try read(a, out.items);
    try testing.expectEqualSlices(u8, px, img.rgba);
}

test "unsupported shapes are rejected as Unsupported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const px = try a.alloc(u8, 4 * 4 * 4);
    fillPattern(px);
    const good = try encode(a, px, 4, 4);

    // Patch one IHDR byte at a time and refresh the chunk CRC (IHDR data
    // starts at offset 16; CRC covers type+data at [12, 12+4+13)).
    const Patch = struct { off: usize, val: u8, err: ReadError };
    const patches = [_]Patch{
        .{ .off = 16 + 8, .val = 16, .err = error.Unsupported }, // bit depth 16
        .{ .off = 16 + 9, .val = 3, .err = error.Unsupported }, // palette
        .{ .off = 16 + 12, .val = 1, .err = error.Unsupported }, // interlaced
        .{ .off = 16 + 9, .val = 7, .err = error.Malformed }, // bogus color type
        .{ .off = 16 + 10, .val = 1, .err = error.Malformed }, // bogus compression
    };
    for (patches) |p| {
        const bad = try a.dupe(u8, good);
        bad[p.off] = p.val;
        std.mem.writeInt(u32, bad[16 + 13 ..][0..4], std.hash.Crc32.hash(bad[12 .. 16 + 13]), .big);
        try testing.expectError(p.err, read(a, bad));
    }
}

test "corruption is Malformed: CRC flip, adler flip, oversized stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const px = try a.alloc(u8, 8 * 8 * 4);
    fillPattern(px);
    const good = try encode(a, px, 8, 8);

    { // flip a byte inside IDAT data -> chunk CRC mismatch
        const bad = try a.dupe(u8, good);
        bad[good.len - 20] ^= 0xff;
        try testing.expectError(error.Malformed, read(a, bad));
    }
    { // shrink the declared height -> decompressed stream now too long
        const bad = try a.dupe(u8, good);
        std.mem.writeInt(u32, bad[16 + 4 ..][0..4], 7, .big);
        std.mem.writeInt(u32, bad[16 + 13 ..][0..4], std.hash.Crc32.hash(bad[12 .. 16 + 13]), .big);
        try testing.expectError(error.Malformed, read(a, bad));
    }
    { // grow the declared height -> stream too short
        const bad = try a.dupe(u8, good);
        std.mem.writeInt(u32, bad[16 + 4 ..][0..4], 9, .big);
        std.mem.writeInt(u32, bad[16 + 13 ..][0..4], std.hash.Crc32.hash(bad[12 .. 16 + 13]), .big);
        try testing.expectError(error.Malformed, read(a, bad));
    }
    { // not a PNG at all
        try testing.expectError(error.Malformed, read(a, "definitely not a png"));
        try testing.expectError(error.Malformed, read(a, ""));
    }
}

test "every truncation errors, never crashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const px = try a.alloc(u8, 5 * 3 * 4);
    fillPattern(px);
    const good = try encode(a, px, 5, 3);
    var n: usize = 0;
    while (n < good.len) : (n += 1) {
        // Every strict prefix is missing at least IEND: must error.
        try testing.expectError(error.Malformed, read(a, good[0..n]));
    }
}

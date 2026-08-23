//! Fontnik glyph PBF decode + SDF atlas.
//!
//! The style's `glyphs` URL template (maplibre.org/maplibre-style-spec/glyphs)
//! serves `{fontstack}/{range}.pbf` files, each a 256-codepoint block of
//! signed-distance-field bitmaps. The style-spec page documents only the URL
//! contract; the wire format here is decoded against tile57's ENCODER
//! (tile57/src/sprite/glyphpbf.zig — same author, the clean-room reference):
//!
//!   glyphs    { repeated fontstack stacks = 1; }
//!   fontstack { string name = 1; string range = 2; repeated glyph glyphs = 3; }
//!   glyph     { uint32 id = 1; bytes bitmap = 2; uint32 width = 3;
//!               uint32 height = 4; sint32 left = 5; sint32 top = 6;
//!               uint32 advance = 7; }
//!
//! FIELDS 5 AND 6 ARE ZIGZAG sint32 — tile57/src/sprite/glyphpbf.zig:7-11
//! records the failure mode of reading them as plain varints: every even
//! value halves and every odd one NEGATES, scattering letters vertically by
//! parity ("words render with characters apparently missing"). The test
//! below locks the zigzag path with negative fixtures.
//!
//! `width`/`height` EXCLUDE the SDF buffer; the bitmap is the full padded
//! field of (width + 2*buffer) x (height + 2*buffer) bytes with fontnik's
//! fixed buffer of 3 px. A glyph with no bitmap (a space) carries metrics
//! only. Decoding is bounds-checked throughout — hostile input is
//! error.Malformed, never a crash (same discipline as source/mvt.zig).
//!
//! GlyphAtlas shelf-packs the padded SDF cells into ONE single-channel
//! plane (fixed width, grow-downward rows — the same simple packer as
//! symbol/sprite.zig) and resolves codepoints to the metrics shape lookout's
//! GlyphAtlas carries (lookout-marine src/atlas.zig:43-60): UV rect + cell
//! size + left/top/advance. `toRgba` expands the plane for the backends'
//! RGBA-only atlas upload (gpu_metal.zig uploadGlyphAtlas* take RGBA8 and
//! the SDF shader samples .r).

const std = @import("std");
const jsondepth = @import("../util/jsondepth.zig");
const Allocator = std.mem.Allocator;

/// Fontnik's fixed SDF padding around each glyph bitmap, px.
pub const buffer_px: u32 = 3;

pub const Error = error{ Malformed, Unsupported, AtlasFull, OutOfMemory };

/// One decoded glyph, exactly as on the wire. `bitmap` borrows from the
/// input PBF (empty for a metrics-only glyph) and is the full padded field.
pub const Glyph = struct {
    id: u21,
    bitmap: []const u8,
    width: u32, // unpadded ink box, px
    height: u32,
    left: i32, // ink box left edge relative to the pen, px (sint32!)
    top: i32, // ink box top relative to the baseline, px, y-up (sint32!)
    advance: u32, // pen advance, px
};

pub const Fontstack = struct {
    name: []const u8 = "",
    range: []const u8 = "",
    glyphs: []const Glyph = &.{},
};

// Sanity caps: fontnik bakes a 24 px em; nothing legitimate approaches these.
const max_glyph_px: u32 = 512;
const max_advance: u32 = 4096;
/// The band an SDF sheet's `em_px` must fall in. Values are DIVIDED into and
/// MULTIPLIED by, so "> 0" lets a denormal or a 1e300 through and the
/// products stop fitting the integers they are converted to.
const min_em_px: f64 = 1;
const max_em_px: f64 = 1024;

/// f64 -> T with the range checked first. @intFromFloat is illegal behavior
/// when the value does not fit — a panic under ReleaseSafe and undefined
/// under ReleaseFast — so every conversion of a number that came off the
/// wire goes through here. NaN and infinity fail both comparisons.
fn toInt(comptime T: type, x: f64) ?T {
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(x >= lo and x <= hi)) return null;
    return @intFromFloat(x);
}

/// Decode one range PBF. `a` should be a per-range arena (nothing is freed
/// individually); strings and bitmaps borrow from `data`, which must outlive
/// the result. Normally one fontstack per file, but repeats are legal.
pub fn decode(a: Allocator, data: []const u8) Error![]const Fontstack {
    var stacks = std.ArrayList(Fontstack).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        if (tag >> 3 == 1 and tag & 7 == 2) {
            try stacks.append(a, try decodeFontstack(a, try r.lenDelim()));
        } else try r.skip(tag & 7);
    }
    return stacks.items;
}

fn decodeFontstack(a: Allocator, data: []const u8) Error!Fontstack {
    var out = Fontstack{};
    var glyphs = std.ArrayList(Glyph).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        if (wire == 2) {
            const s = try r.lenDelim();
            switch (field) {
                1 => out.name = s,
                2 => out.range = s,
                3 => try glyphs.append(a, try decodeGlyph(s)),
                else => {},
            }
        } else try r.skip(wire);
    }
    out.glyphs = glyphs.items;
    return out;
}

fn decodeGlyph(data: []const u8) Error!Glyph {
    var out = Glyph{ .id = 0, .bitmap = &.{}, .width = 0, .height = 0, .left = 0, .top = 0, .advance = 0 };
    var seen_id = false;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        switch (field) {
            1 => {
                const v = try r.varint();
                if (v > 0x10FFFF) return error.Malformed;
                out.id = @intCast(v);
                seen_id = true;
            },
            2 => out.bitmap = try r.lenDelim(),
            3 => out.width = try boundedU32(&r, max_glyph_px),
            4 => out.height = try boundedU32(&r, max_glyph_px),
            // THE zigzag fields. Plain-varint reads halve/negate by parity.
            5 => out.left = try sint32(&r),
            6 => out.top = try sint32(&r),
            7 => out.advance = try boundedU32(&r, max_advance),
            else => try r.skip(wire),
        }
    }
    if (!seen_id) return error.Malformed;
    // The bitmap, when present, must be exactly the padded field.
    if (out.bitmap.len != 0) {
        const padded = @as(usize, out.width + 2 * buffer_px) * (out.height + 2 * buffer_px);
        if (out.bitmap.len != padded) return error.Malformed;
    } else if (out.width != 0 or out.height != 0) return error.Malformed;
    return out;
}

fn boundedU32(r: *Reader, max: u32) Error!u32 {
    const v = try r.varint();
    if (v > max) return error.Malformed;
    return @intCast(v);
}

fn sint32(r: *Reader) Error!i32 {
    const v = unzig(try r.varint());
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.Malformed;
    return @intCast(v);
}

fn unzig(u: u64) i64 {
    const i: i64 = @bitCast(u >> 1);
    return i ^ -@as(i64, @intCast(u & 1));
}

// Bounds-checked protobuf reader (the source/mvt.zig shape).
const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn varint(r: *Reader) error{Malformed}!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (r.pos >= r.buf.len) return error.Malformed;
            const b = r.buf[r.pos];
            r.pos += 1;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) return result;
            if (shift == 63) return error.Malformed;
            shift = @min(shift + 7, 63);
        }
    }

    fn lenDelim(r: *Reader) error{Malformed}![]const u8 {
        const n = try r.varint();
        if (n > r.buf.len - r.pos) return error.Malformed;
        const s = r.buf[r.pos..][0..@intCast(n)];
        r.pos += @intCast(n);
        return s;
    }

    fn skip(r: *Reader, wire: u64) error{Malformed}!void {
        switch (wire) {
            0 => _ = try r.varint(),
            1 => try r.advance(8),
            2 => _ = try r.lenDelim(),
            5 => try r.advance(4),
            else => return error.Malformed,
        }
    }

    fn advance(r: *Reader, n: usize) error{Malformed}!void {
        if (n > r.buf.len - r.pos) return error.Malformed;
        r.pos += n;
    }
};

// ---- SDF atlas ------------------------------------------------------------

/// A resolved glyph: UV rect of its padded SDF cell in the CURRENT atlas,
/// the cell size, and the layout metrics. The shape lookout's GlyphAtlas
/// resolves to (src/atlas.zig GlyphInfo), so the SDF pipeline consumes it
/// unchanged. A metrics-only glyph (space) has w == h == 0 and a degenerate
/// UV rect — emit no quad, advance the pen.
pub const GlyphMetrics = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    w: f32, // padded cell size, px (width + 2*buffer_px when inked)
    h: f32,
    left: f32, // unpadded ink-box metrics, px
    top: f32,
    advance: f32,
};

pub const default_width: u32 = 1024;
pub const max_height: u32 = 16384;
const pad: u32 = 1;

pub const GlyphAtlas = struct {
    alloc: Allocator,
    /// Single-channel SDF plane, `width * height` bytes, grow-downward.
    sdf: []u8 = &.{},
    width: u32,
    height: u32 = 0,
    glyphs: std.AutoHashMapUnmanaged(u21, Slot) = .empty,
    /// Bumped on every pixel change; the host re-uploads on staleness.
    generation: u32 = 0,
    pen_x: u32 = 0,
    pen_y: u32 = 0,
    row_h: u32 = 0,

    const Slot = struct {
        x: u32,
        y: u32,
        w: u32, // padded cell dims; 0 for metrics-only glyphs
        h: u32,
        left: i32,
        top: i32,
        advance: u32,
    };

    pub fn init(alloc: Allocator, width: u32) Error!GlyphAtlas {
        if (width < max_glyph_px + 2 * buffer_px or width > max_height) return error.Unsupported;
        return .{ .alloc = alloc, .width = width };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.alloc.free(self.sdf);
        self.glyphs.deinit(self.alloc);
        self.* = undefined;
    }

    /// Decode one range PBF and pack its glyphs. A codepoint already in the
    /// atlas is kept (first stack wins — ranges should not overlap; when a
    /// host loads fallback stacks, load the primary first). Returns how many
    /// glyphs were added.
    pub fn addRange(self: *GlyphAtlas, pbf: []const u8) Error!usize {
        var tmp = std.heap.ArenaAllocator.init(self.alloc);
        defer tmp.deinit();
        const stacks = try decode(tmp.allocator(), pbf);

        var added: usize = 0;
        for (stacks) |st| for (st.glyphs) |g| {
            const gop = try self.glyphs.getOrPut(self.alloc, g.id);
            if (gop.found_existing) continue;
            errdefer _ = self.glyphs.remove(g.id);
            gop.value_ptr.* = try self.pack(g);
            added += 1;
        };
        if (added > 0) self.generation +%= 1;
        return added;
    }

    /// Take a host-baked SDF atlas: an RGBA sheet plus an index describing
    /// each glyph as UVs into it and metrics in EM units.
    ///
    ///   {"em_px": 32, "pad": 6,
    ///    "glyphs": {"65": [u0, v0, u1, v1, off_x, off_y, w, h, advance]}}
    ///
    /// This is the shape tile57 bakes (tile57_bake_glyph_sdf), and it exists
    /// so a host with a text engine of its own does not also have to produce
    /// fontnik PBFs. Without some such path, a host that cannot supply PBFs
    /// draws no text at all -- which reads as "text is broken" rather than
    /// "nobody handed it a font".
    ///
    /// The sheet's red channel is the distance field; a cell is copied
    /// verbatim, so the field's own scale rides along with it.
    pub fn addSdfSheet(
        self: *GlyphAtlas,
        index_json: []const u8,
        rgba: []const u8,
        sheet_w: u32,
        sheet_h: u32,
    ) Error!usize {
        if (sheet_w == 0 or sheet_h == 0) return error.Malformed;
        if (rgba.len < @as(usize, sheet_w) * sheet_h * 4) return error.Malformed;

        var tmp = std.heap.ArenaAllocator.init(self.alloc);
        defer tmp.deinit();
        const a = tmp.allocator();

        // Same depth guard as Sprite.load, and the same split of OutOfMemory
        // from Malformed: mapping a genuine allocation failure to "bad input"
        // tells the host to stop retrying when it should back off instead.
        if (!jsondepth.ok(index_json)) return error.Malformed;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, index_json, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        if (parsed != .object) return error.Malformed;
        const em_px: f64 = switch (parsed.object.get("em_px") orelse return error.Malformed) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return error.Malformed,
        };
        if (!(em_px >= min_em_px and em_px <= max_em_px)) return error.Malformed;
        const glyphs_val = parsed.object.get("glyphs") orelse return error.Malformed;
        if (glyphs_val != .object) return error.Malformed;

        var added: usize = 0;
        var it = glyphs_val.object.iterator();
        while (it.next()) |kv| {
            const cp_int = std.fmt.parseInt(u21, kv.key_ptr.*, 10) catch continue;
            const arr = switch (kv.value_ptr.*) {
                .array => |ar| ar.items,
                else => continue,
            };
            if (arr.len < 9) continue;
            var f: [9]f64 = undefined;
            for (arr[0..9], 0..) |v, i| f[i] = switch (v) {
                .integer => |n| @floatFromInt(n),
                .float => |n| n,
                else => return error.Malformed,
            };

            // Convert BEFORE touching the map. getOrPut inserts the key with
            // an uninitialized value, so a skip after it would leave the
            // atlas holding a glyph nobody wrote.
            //
            // The cell, in sheet pixels. UVs are normalized -- but nothing on
            // the wire promises that, so range-check before converting rather
            // than sanity-checking the converted values afterwards.
            const px0 = toInt(u32, @round(f[0] * @as(f64, @floatFromInt(sheet_w)))) orelse continue;
            const py0 = toInt(u32, @round(f[1] * @as(f64, @floatFromInt(sheet_h)))) orelse continue;
            const px1 = toInt(u32, @round(f[2] * @as(f64, @floatFromInt(sheet_w)))) orelse continue;
            const py1 = toInt(u32, @round(f[3] * @as(f64, @floatFromInt(sheet_h)))) orelse continue;
            const left = toInt(i32, @round(f[4] * em_px)) orelse continue;
            const top = toInt(i32, @round(-f[5] * em_px)) orelse continue;
            const advance = @min(max_advance, toInt(u32, @max(0, @round(f[8] * em_px))) orelse continue);

            const gop = try self.glyphs.getOrPut(self.alloc, cp_int);
            if (gop.found_existing) continue;
            errdefer _ = self.glyphs.remove(cp_int);

            const degenerate = px1 <= px0 or py1 <= py0 or px1 > sheet_w or py1 > sheet_h or
                px1 - px0 > max_glyph_px or py1 - py0 > max_glyph_px;
            const cw = if (degenerate) 0 else px1 - px0;
            const chh = if (degenerate) 0 else py1 - py0;

            // A glyph with no ink -- the space, above all -- still carries an
            // advance, and dropping it runs every word into the next.
            if (degenerate or cw <= 2 * buffer_px or chh <= 2 * buffer_px) {
                gop.value_ptr.* = try self.pack(.{
                    .id = cp_int,
                    .bitmap = &.{},
                    .width = 0,
                    .height = 0,
                    .left = 0,
                    .top = 0,
                    .advance = advance,
                });
                added += 1;
                continue;
            }
            const cell = try a.alloc(u8, @as(usize, cw) * chh);
            for (0..chh) |row| {
                for (0..cw) |col| {
                    const si = ((@as(usize, py0) + row) * sheet_w + @as(usize, px0) + col) * 4;
                    // Rebase the field onto OUR edge. A distance field only
                    // means anything against the threshold it was made for:
                    // ours is at 191/255 (fontnik's 0.75), while a sheet
                    // baked at the usual 0.5 puts its edge at 128 and never
                    // reaches 191 at all -- every glyph tests as outside and
                    // the text is invisible while the atlas looks perfectly
                    // healthy. Shift the edge and widen the ramp to match.
                    const v: f32 = @floatFromInt(rgba[si]); // red is the field
                    const rebased = 191.0 + (v - 128.0) * 1.5;
                    cell[row * cw + col] = @intFromFloat(std.math.clamp(rebased, 0, 255));
                }
            }

            gop.value_ptr.* = try self.pack(.{
                .id = cp_int,
                .bitmap = cell,
                .width = cw - 2 * buffer_px,
                .height = chh - 2 * buffer_px,
                // EM units to pixels. off_y is measured downward from the
                // baseline; `top` is y-up, hence the negation.
                .left = left,
                .top = top,
                .advance = advance,
            });
            added += 1;
        }
        if (added > 0) self.generation +%= 1;
        return added;
    }

    /// Resolve a codepoint. UVs are computed against the current atlas
    /// dimensions, so they stay valid across growth.
    pub fn get(self: *const GlyphAtlas, cp: u21) ?GlyphMetrics {
        const s = self.glyphs.get(cp) orelse return null;
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(@max(self.height, 1));
        return .{
            .u0 = @as(f32, @floatFromInt(s.x)) / fw,
            .v0 = @as(f32, @floatFromInt(s.y)) / fh,
            .u1 = @as(f32, @floatFromInt(s.x + s.w)) / fw,
            .v1 = @as(f32, @floatFromInt(s.y + s.h)) / fh,
            .w = @floatFromInt(s.w),
            .h = @floatFromInt(s.h),
            .left = @floatFromInt(s.left),
            .top = @floatFromInt(s.top),
            .advance = @floatFromInt(s.advance),
        };
    }

    pub fn count(self: *const GlyphAtlas) usize {
        return self.glyphs.count();
    }

    /// Expand the single-channel plane to RGBA8 (value replicated into all
    /// four channels) for the backends' atlas upload: gpu_metal.zig's
    /// uploadGlyphAtlas* take RGBA and the SDF shader samples .r. Caller
    /// owns the slice.
    pub fn toRgba(self: *const GlyphAtlas, a: Allocator) Allocator.Error![]u8 {
        const out = try a.alloc(u8, @as(usize, self.width) * self.height * 4);
        for (self.sdf, 0..) |v, i| out[i * 4 ..][0..4].* = .{ v, v, v, v };
        return out;
    }

    fn pack(self: *GlyphAtlas, g: Glyph) Error!Slot {
        if (g.bitmap.len == 0) // metrics-only: no cell
            return .{ .x = 0, .y = 0, .w = 0, .h = 0, .left = g.left, .top = g.top, .advance = g.advance };

        const w = g.width + 2 * buffer_px;
        const h = g.height + 2 * buffer_px;
        if (self.pen_x + w + pad > self.width) {
            self.pen_x = 0;
            self.pen_y += self.row_h + pad;
            self.row_h = 0;
        }
        const need = self.pen_y + h + pad;
        if (need > self.height) try self.grow(need);

        const x = self.pen_x;
        const y = self.pen_y;
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const src = g.bitmap[@as(usize, row) * w ..][0..w];
            const dst = self.sdf[@as(usize, y + row) * self.width + x ..][0..w];
            @memcpy(dst, src);
        }
        self.pen_x += w + pad;
        self.row_h = @max(self.row_h, h);
        return .{ .x = x, .y = y, .w = w, .h = h, .left = g.left, .top = g.top, .advance = g.advance };
    }

    fn grow(self: *GlyphAtlas, need: u32) Error!void {
        if (need > max_height) return error.AtlasFull;
        const new_h: u32 = @min(max_height, @max(need, self.height + @max(self.height / 2, 64)));
        const plane = try self.alloc.alloc(u8, @as(usize, self.width) * new_h);
        @memcpy(plane[0..self.sdf.len], self.sdf);
        @memset(plane[self.sdf.len..], 0);
        self.alloc.free(self.sdf);
        self.sdf = plane;
        self.height = new_h;
    }
};

// ---- tests --------------------------------------------------------------
//
// The fixture encoder below is the ENCODE side of tile57's glyphpbf.zig
// (putVarint/putVarintField/putSintField/putBytesField), ported test-only so
// the decoder is exercised against the exact wire the real tool emits —
// including the zigzag sint32 fields 5/6.

const testing = std.testing;

fn putVarint(buf: *std.ArrayList(u8), a: Allocator, v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try buf.append(a, @intCast((x & 0x7f) | 0x80));
    try buf.append(a, @intCast(x));
}
fn putVarintField(buf: *std.ArrayList(u8), a: Allocator, field: u32, v: u64) !void {
    try putVarint(buf, a, (@as(u64, field) << 3) | 0);
    try putVarint(buf, a, v);
}
fn putSintField(buf: *std.ArrayList(u8), a: Allocator, field: u32, v: i32) !void {
    const zz = (@as(u64, @bitCast(@as(i64, v))) << 1) ^ @as(u64, @bitCast(@as(i64, v) >> 63));
    try putVarintField(buf, a, field, zz);
}
fn putBytesField(buf: *std.ArrayList(u8), a: Allocator, field: u32, bytes: []const u8) !void {
    try putVarint(buf, a, (@as(u64, field) << 3) | 2);
    try putVarint(buf, a, bytes.len);
    try buf.appendSlice(a, bytes);
}

const TestGlyph = struct { id: u21, w: u32, h: u32, left: i32, top: i32, advance: u32 };

// Padded bitmap filled with a per-glyph marker so packing can be verified.
fn testBitmap(a: Allocator, g: TestGlyph) ![]u8 {
    const n = @as(usize, g.w + 2 * buffer_px) * (g.h + 2 * buffer_px);
    const b = try a.alloc(u8, n);
    for (b, 0..) |*v, i| v.* = @truncate(@as(usize, g.id) * 31 + i);
    return b;
}

fn encodeTestRange(a: Allocator, name: []const u8, range: []const u8, gs: []const TestGlyph) ![]u8 {
    var stack = std.ArrayList(u8).empty;
    try putBytesField(&stack, a, 1, name);
    try putBytesField(&stack, a, 2, range);
    for (gs) |g| {
        var msg = std.ArrayList(u8).empty;
        try putVarintField(&msg, a, 1, g.id);
        if (g.w > 0 and g.h > 0) {
            const bm = try testBitmap(a, g);
            try putBytesField(&msg, a, 2, bm);
        }
        try putVarintField(&msg, a, 3, g.w);
        try putVarintField(&msg, a, 4, g.h);
        try putSintField(&msg, a, 5, g.left);
        try putSintField(&msg, a, 6, g.top);
        try putVarintField(&msg, a, 7, g.advance);
        try putBytesField(&stack, a, 3, msg.items);
    }
    var out = std.ArrayList(u8).empty;
    try putBytesField(&out, a, 1, stack.items);
    return out.items;
}

// 'A' with negative left, 'g' with negative top (descender), a space with
// metrics only — the negatives are what a plain-varint reader corrupts.
const test_glyphs = [_]TestGlyph{
    .{ .id = 'A', .w = 10, .h = 12, .left = -2, .top = 13, .advance = 11 },
    .{ .id = 'g', .w = 8, .h = 11, .left = 1, .top = -3, .advance = 9 },
    .{ .id = ' ', .w = 0, .h = 0, .left = 0, .top = 0, .advance = 6 },
};

test "decode: fields round-trip, zigzag sint32 negatives come back exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pbf = try encodeTestRange(a, "Test Sans", "0-255", &test_glyphs);
    const stacks = try decode(a, pbf);
    try testing.expectEqual(@as(usize, 1), stacks.len);
    try testing.expectEqualStrings("Test Sans", stacks[0].name);
    try testing.expectEqualStrings("0-255", stacks[0].range);
    try testing.expectEqual(@as(usize, 3), stacks[0].glyphs.len);

    for (stacks[0].glyphs, test_glyphs) |got, want| {
        try testing.expectEqual(want.id, got.id);
        try testing.expectEqual(want.w, got.width);
        try testing.expectEqual(want.h, got.height);
        // The war-story fields: -2 on the wire is zigzag 3; a plain-varint
        // reader would produce 3 (and 13 would come back as -7). Exactness
        // here IS the regression test.
        try testing.expectEqual(want.left, got.left);
        try testing.expectEqual(want.top, got.top);
        try testing.expectEqual(want.advance, got.advance);
        if (want.w > 0) {
            try testing.expectEqual(
                @as(usize, want.w + 2 * buffer_px) * (want.h + 2 * buffer_px),
                got.bitmap.len,
            );
        } else {
            try testing.expectEqual(@as(usize, 0), got.bitmap.len);
        }
    }
}

test "atlas: pack, UV -> pixels, metrics-only glyph, RGBA expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pbf = try encodeTestRange(a, "Test Sans", "0-255", &test_glyphs);
    var atlas = try GlyphAtlas.init(testing.allocator, default_width);
    defer atlas.deinit();
    try testing.expectEqual(@as(usize, 3), try atlas.addRange(pbf));
    try testing.expectEqual(@as(usize, 3), atlas.count());
    try testing.expect(atlas.generation > 0);

    // 'A': the UV rect must map back onto the packed bitmap bytes.
    const m = atlas.get('A').?;
    try testing.expectEqual(@as(f32, 10 + 6), m.w); // padded cell
    try testing.expectEqual(@as(f32, 12 + 6), m.h);
    try testing.expectEqual(@as(f32, -2), m.left);
    try testing.expectEqual(@as(f32, 13), m.top);
    try testing.expectEqual(@as(f32, 11), m.advance);
    const x: u32 = @intFromFloat(m.u0 * @as(f32, @floatFromInt(atlas.width)));
    const y: u32 = @intFromFloat(m.v0 * @as(f32, @floatFromInt(atlas.height)));
    try testing.expectEqual(@as(f32, @floatFromInt(x)) + m.w, m.u1 * @as(f32, @floatFromInt(atlas.width)));
    const want_bm = try testBitmap(a, test_glyphs[0]);
    var row: u32 = 0;
    while (row < 18) : (row += 1) {
        const got = atlas.sdf[@as(usize, y + row) * atlas.width + x ..][0..16];
        try testing.expectEqualSlices(u8, want_bm[@as(usize, row) * 16 ..][0..16], got);
    }

    // Space: metrics only, degenerate cell, no quad to emit.
    const sp = atlas.get(' ').?;
    try testing.expectEqual(@as(f32, 0), sp.w);
    try testing.expectEqual(@as(f32, 6), sp.advance);
    try testing.expect(atlas.get('Z') == null);

    // RGBA expansion replicates the channel.
    const rgba = try atlas.toRgba(a);
    try testing.expectEqual(@as(usize, atlas.width) * atlas.height * 4, rgba.len);
    const i = (@as(usize, y) * atlas.width + x); // 'A' cell corner
    try testing.expectEqual(atlas.sdf[i], rgba[i * 4]);
    try testing.expectEqual(atlas.sdf[i], rgba[i * 4 + 3]);
    try testing.expect(atlas.sdf[i] != 0); // marker pattern, non-blank
}

test "atlas: shelf newlines and growth keep earlier cells valid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Enough 30x30-cell glyphs to overflow several rows of a narrow atlas.
    var gs: [40]TestGlyph = undefined;
    for (&gs, 0..) |*g, i| {
        g.* = .{ .id = @intCast(0x4E00 + i), .w = 24, .h = 24, .left = 0, .top = 20, .advance = 26 };
    }
    const pbf = try encodeTestRange(a, "Test CJK", "19968-20223", &gs);

    var atlas = try GlyphAtlas.init(testing.allocator, 640);
    defer atlas.deinit();
    try testing.expectEqual(@as(usize, 40), try atlas.addRange(pbf));
    try testing.expect(atlas.height > 30); // more than one row -> grew

    // Every glyph's UV rect still addresses its own bitmap's first byte.
    for (gs) |g| {
        const m = atlas.get(g.id).?;
        const x: u32 = @intFromFloat(@round(m.u0 * @as(f32, @floatFromInt(atlas.width))));
        const y: u32 = @intFromFloat(@round(m.v0 * @as(f32, @floatFromInt(atlas.height))));
        const bm = try testBitmap(a, g);
        try testing.expectEqual(bm[0], atlas.sdf[@as(usize, y) * atlas.width + x]);
    }

    // Re-adding the same range: first wins, nothing added.
    try testing.expectEqual(@as(usize, 0), try atlas.addRange(pbf));
    try testing.expectEqual(@as(usize, 40), atlas.count());
}

test "malformed input: bitmap size lies, bad ids, truncation sweep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    { // bitmap length != padded field
        var msg = std.ArrayList(u8).empty;
        try putVarintField(&msg, a, 1, 'A');
        try putBytesField(&msg, a, 2, &[_]u8{ 1, 2, 3 }); // says 3 bytes...
        try putVarintField(&msg, a, 3, 10); // ...but claims 10x12 ink
        try putVarintField(&msg, a, 4, 12);
        var stack = std.ArrayList(u8).empty;
        try putBytesField(&stack, a, 3, msg.items);
        var out = std.ArrayList(u8).empty;
        try putBytesField(&out, a, 1, stack.items);
        try testing.expectError(error.Malformed, decode(a, out.items));
    }
    { // id above Unicode
        var msg = std.ArrayList(u8).empty;
        try putVarintField(&msg, a, 1, 0x110000);
        var stack = std.ArrayList(u8).empty;
        try putBytesField(&stack, a, 3, msg.items);
        var out = std.ArrayList(u8).empty;
        try putBytesField(&out, a, 1, stack.items);
        try testing.expectError(error.Malformed, decode(a, out.items));
    }
    { // glyph with no id at all
        var msg = std.ArrayList(u8).empty;
        try putVarintField(&msg, a, 7, 6);
        var stack = std.ArrayList(u8).empty;
        try putBytesField(&stack, a, 3, msg.items);
        var out = std.ArrayList(u8).empty;
        try putBytesField(&out, a, 1, stack.items);
        try testing.expectError(error.Malformed, decode(a, out.items));
    }

    // Every truncation of a valid range decodes or errors — never crashes
    // (a prefix can end on a message boundary and decode to fewer glyphs).
    const pbf = try encodeTestRange(a, "Test Sans", "0-255", &test_glyphs);
    var n: usize = 0;
    while (n < pbf.len) : (n += 1) {
        _ = decode(a, pbf[0..n]) catch |err| {
            try testing.expectEqual(error.Malformed, err);
        };
    }
}

test "loads a real glyph range when the fixture is present (integration)" {
    // Optional: point CHARTTABLE_TEST_GLYPHS_PBF at a fontnik range file
    // (e.g. a tile57-emitted `0-255.pbf`). Machines without one skip.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    const env = std.c.getenv("CHARTTABLE_TEST_GLYPHS_PBF") orelse return error.SkipZigTest;
    const data = std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(env), ar, .unlimited) catch
        return error.SkipZigTest;

    var atlas = try GlyphAtlas.init(a, default_width);
    defer atlas.deinit();
    const added = try atlas.addRange(data);
    try testing.expect(added > 0);
    try testing.expect(atlas.height > 0);

    var it = atlas.glyphs.iterator();
    while (it.next()) |e| {
        const m = atlas.get(e.key_ptr.*).?;
        try testing.expect(m.u0 >= 0 and m.u1 <= 1 and m.u0 <= m.u1);
        try testing.expect(m.v0 >= 0 and m.v1 <= 1 and m.v0 <= m.v1);
        try testing.expect(m.advance >= 0);
    }
}

test "addSdfSheet: hostile index numbers are refused, not converted" {
    const a = std.testing.allocator;
    var atlas = try GlyphAtlas.init(a, default_width);
    defer atlas.deinit();

    const sheet_w: u32 = 64;
    const sheet_h: u32 = 64;
    const rgba = try a.alloc(u8, sheet_w * sheet_h * 4);
    defer a.free(rgba);
    @memset(rgba, 128);

    // Every one of these puts a value into an @intFromFloat that the target
    // integer cannot hold. The PBF path caps glyph size and advance; this
    // path used to convert first and sanity-check afterwards.
    const hostile = [_][]const u8{
        // negative UV -> negative u32
        \\{"em_px": 24, "glyphs": {"65": [-1.0, 0, 0.5, 0.5, 0, 0, 0, 0, 10]}}
        ,
        // UV past 1e30 -> u32 overflow
        \\{"em_px": 24, "glyphs": {"65": [0, 0, 1e30, 0.5, 0, 0, 0, 0, 10]}}
        ,
        // left/top in em units, scaled by em_px, past i32
        \\{"em_px": 24, "glyphs": {"65": [0, 0, 0.5, 0.5, 1e30, 0, 0, 0, 10]}}
        ,
        \\{"em_px": 24, "glyphs": {"65": [0, 0, 0.5, 0.5, 0, -1e30, 0, 0, 10]}}
        ,
        // advance past u32
        \\{"em_px": 24, "glyphs": {"65": [0, 0, 0.5, 0.5, 0, 0, 0, 0, 1e30]}}
        ,
        // em_px itself: only "> 0" was required, so NaN and denormals passed
        \\{"em_px": 1e300, "glyphs": {"65": [0, 0, 0.5, 0.5, 1, 1, 0, 0, 10]}}
        ,
        \\{"em_px": 1e-300, "glyphs": {"65": [0, 0, 0.5, 0.5, 1, 1, 0, 0, 10]}}
        ,
    };
    for (hostile) |idx| {
        _ = atlas.addSdfSheet(idx, rgba, sheet_w, sheet_h) catch |e| {
            try std.testing.expect(e == error.Malformed);
            continue;
        };
    }

    // None of them left a half-written entry behind: getOrPut inserts the key
    // with an uninitialized value, so a skip must happen before it.
    try std.testing.expectEqual(@as(usize, 0), atlas.glyphs.count());

    // A well-formed sheet still lands.
    const good =
        \\{"em_px": 24, "glyphs": {"65": [0.0, 0.0, 0.5, 0.5, 1, 1, 0, 0, 10]}}
    ;
    try std.testing.expect(try atlas.addSdfSheet(good, rgba, sheet_w, sheet_h) > 0);
}

//! MapLibre Tile (MLT) v1 decoder — the column-oriented sibling of
//! source/mvt.zig, for archives baked by tile57 with `"encoding": "mlt"`
//! (pmtiles tile_type 6).
//!
//! Decode only — charttable consumes tiles, it never emits them (tile57 owns
//! the encoder; this is a port of its decode side, tile57/src/tiles/mlt.zig).
//! It understands exactly the subset tile57's encoder writes, which is the
//! only MLT charttable will ever be handed:
//!
//!   - a tile is a sequence of blocks `[varint blockLength][varint tag=1]
//!     [body]`; the body is embedded metadata (name, extent, columns) then
//!     per-column physical streams, each prefixed by a 2-byte StreamMetadata
//!     header + varint numValues + varint byteLength;
//!   - geometry: a per-feature GeometryType stream (plain varint), optional
//!     GEOMETRIES/PARTS/RINGS length streams (plain varint), and a VERTEX
//!     buffer (componentwise delta + zigzag + varint);
//!   - properties: scalar columns (string / int32 / uint32 / double / float),
//!     nullable via an ORC byte-RLE PRESENT bitmap; strings either plain
//!     (lengths + bytes) or dictionary-encoded (dict lengths + dict bytes +
//!     per-feature offsets).
//!
//! Integer decoding is varint (+ zigzag / componentwise-delta) and fixed-size
//! little-endian floats throughout — tile57 never emits FastPFOR or any other
//! physical-level technique, so none is needed here.
//!
//! The output is charttable's own mvt.Tile/Layer/Feature model with interned
//! keys/values, so map.zig consumes MVT and MLT tiles identically. Geometry
//! conventions match the MVT decoder: point features keep all points in one
//! part, one part per line, one part per polygon ring in exterior-then-holes
//! order — and rings come back OPEN. tile57's model rings carry an explicit
//! closing vertex (S-57 ring assembly; its MVT encoder drops it in favour of
//! ClosePath, its MLT encoder writes it verbatim), so a duplicated closing
//! vertex is dropped here to keep the two formats indistinguishable
//! downstream.
//!
//! Hardened like the MVT port: every read is bounds-checked, per-stream
//! element counts are capped against the stream's byte length before any
//! allocation, and all cursors into length/vertex streams are validated — a
//! truncated or hostile tile is error.Malformed, never a crash.
//!
//! Ownership: `decode` allocates into the caller's allocator and frees
//! nothing individually — use a per-tile arena. Strings (layer names, keys,
//! string values) BORROW from the input buffer, which must outlive the
//! decoded tile.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mvt = @import("mvt.zig");

// ---- wire ordinals (tile57's subset of the MLT spec enums) ---------------

// PhysicalStreamType (high nibble of StreamMetadata byte 0).
const PHYS_PRESENT: u8 = 0;
const PHYS_DATA: u8 = 1;
const PHYS_OFFSET: u8 = 2;
const PHYS_LENGTH: u8 = 3;
// LengthType (low nibble when LENGTH).
const LEN_VAR_BINARY: u8 = 0;
const LEN_GEOMETRIES: u8 = 1;
const LEN_PARTS: u8 = 2;
const LEN_RINGS: u8 = 3;
const LEN_DICTIONARY: u8 = 6;
// DictionaryType (low nibble when DATA).
const DICT_NONE: u8 = 0;
const DICT_SINGLE: u8 = 1;
const DICT_VERTEX: u8 = 3;
// OffsetType (low nibble when OFFSET).
const OFF_STRING: u8 = 2;
// MLT GeometryType ordinals.
const G_POINT: u32 = 0;
const G_LINESTRING: u32 = 1;
const G_POLYGON: u32 = 2;
const G_MULTIPOINT: u32 = 3;
const G_MULTILINESTRING: u32 = 4;
const G_MULTIPOLYGON: u32 = 5;
// Column typeCode: geometry 4, scalars 10 + scalarType*2 + nullable.
const TYPECODE_GEOMETRY: u8 = 4;
// ScalarType ordinals (for the 10+type*2+nullable typeCode).
const ST_INT32: u8 = 3;
const ST_UINT32: u8 = 4;
const ST_FLOAT: u8 = 7;
const ST_DOUBLE: u8 = 8;
const ST_STRING: u8 = 9;

// ---- bounds-checked reading -----------------------------------------------

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
            if (shift == 63) return error.Malformed; // > 10 bytes: not a u64
            shift = @min(shift + 7, 63);
        }
    }

    fn byte(r: *Reader) error{Malformed}!u8 {
        if (r.pos >= r.buf.len) return error.Malformed;
        const b = r.buf[r.pos];
        r.pos += 1;
        return b;
    }

    fn bytes(r: *Reader, n: u64) error{Malformed}![]const u8 {
        if (n > r.buf.len - r.pos) return error.Malformed;
        const s = r.buf[r.pos..][0..@intCast(n)];
        r.pos += @intCast(n);
        return s;
    }
};

fn unzigzag32(v: u64) i32 {
    const u: u32 = @truncate(v);
    return @bitCast((u >> 1) ^ (0 -% (u & 1)));
}

fn toUsize(v: u64) error{Malformed}!usize {
    return std.math.cast(usize, v) orelse error.Malformed;
}

/// A physical stream: its 2-byte header decoded plus its body sub-slice.
/// Taking the body up front (bounds-checked once) means every element read
/// below is naturally confined to this stream.
const Stream = struct { phys: u8, sub: u8, num_values: usize, data: []const u8 };

fn readStream(r: *Reader) error{Malformed}!Stream {
    const b0 = try r.byte();
    _ = try r.byte(); // llt/plt byte — tile57's streams are self-describing by (phys, sub)
    const nv = try toUsize(try r.varint());
    const bl = try r.varint();
    return .{ .phys = b0 >> 4, .sub = b0 & 0x0F, .num_values = nv, .data = try r.bytes(bl) };
}

/// Decode a plain-varint stream into u32s. Every varint is at least one
/// byte, so `num_values <= data.len` caps the allocation before it happens —
/// a hostile count can never allocate more than the stream's own bytes.
fn readVarintU32s(a: Allocator, s: Stream) ![]u32 {
    if (s.num_values > s.data.len) return error.Malformed;
    const out = try a.alloc(u32, s.num_values);
    var r = Reader{ .buf = s.data };
    for (out) |*v| v.* = std.math.cast(u32, try r.varint()) orelse return error.Malformed;
    return out;
}

/// Decode the VERTEX buffer: interleaved x,y with componentwise delta +
/// zigzag. num_values counts i32 components, so it must be even and — one
/// varint byte per component minimum — no larger than the stream itself.
fn readVertices(a: Allocator, s: Stream) ![]i32 {
    if (s.num_values > s.data.len or s.num_values % 2 != 0) return error.Malformed;
    const out = try a.alloc(i32, s.num_values);
    var r = Reader{ .buf = s.data };
    var px: i32 = 0;
    var py: i32 = 0;
    var k: usize = 0;
    while (k < out.len) : (k += 2) {
        // Wrapping adds: deltas in a well-formed tile stay in i32 range; a
        // hostile one must not panic the decoder.
        px +%= unzigzag32(try r.varint());
        py +%= unzigzag32(try r.varint());
        out[k] = px;
        out[k + 1] = py;
    }
    return out;
}

/// Decode a PRESENT stream: ORC byte-RLE (header >= 128 -> literal run of
/// 256-header bytes; < 128 -> header+3 repeats of the next byte) unpacked
/// into LSB-first per-feature bits. `want` is the layer's feature count —
/// anything else is malformed, which also pins the allocation size.
fn readPresent(a: Allocator, s: Stream, want: usize) ![]bool {
    if (s.num_values != want) return error.Malformed;
    const out = try a.alloc(bool, s.num_values);
    var r = Reader{ .buf = s.data };
    var bit: usize = 0;
    while (bit < out.len) {
        const h = try r.byte();
        if (h >= 128) {
            const n = @as(usize, 256) - h;
            for (0..n) |_| {
                unpack8(try r.byte(), out, &bit);
                if (bit >= out.len) break;
            }
        } else {
            const b = try r.byte();
            for (0..@as(usize, h) + 3) |_| {
                unpack8(b, out, &bit);
                if (bit >= out.len) break;
            }
        }
    }
    return out;
}

fn unpack8(b: u8, out: []bool, bit: *usize) void {
    var i: u4 = 0;
    while (i < 8 and bit.* < out.len) : (i += 1) {
        out[bit.*] = (b >> @intCast(i)) & 1 != 0;
        bit.* += 1;
    }
}

// ---- decode ---------------------------------------------------------------

const Kind = enum { string, int32, uint32, double, float };
const Col = struct { kind: Kind, nullable: bool, key: []const u8 };

/// Decode a tile. `a` should be a per-tile arena (nothing is individually
/// freed); the returned Tile borrows string bytes from `data`.
pub fn decode(a: Allocator, data: []const u8) !mvt.Tile {
    var layers = std.ArrayList(mvt.Layer).empty;
    var top = Reader{ .buf = data };
    while (top.pos < data.len) {
        const block = try top.bytes(try top.varint());
        try layers.append(a, try decodeBlock(a, block));
    }
    return .{ .layers = layers.items };
}

fn decodeBlock(a: Allocator, block: []const u8) !mvt.Layer {
    var r = Reader{ .buf = block };
    if ((try r.varint()) != 1) return error.Malformed; // tag = 1 (embedded metadata)

    // ---- embedded metadata: name, extent, columns -------------------------
    // Column 0 is always geometry; the rest are scalar property columns in
    // the same order their streams appear below. Their keys ARE the layer's
    // interned key table (tile57 emits each key as one column).
    const name = try r.bytes(try r.varint());
    const extent = std.math.cast(u32, try r.varint()) orelse return error.Malformed;
    const ncols = try r.varint();
    if (ncols == 0 or (try r.byte()) != TYPECODE_GEOMETRY) return error.Malformed;
    var cols = std.ArrayList(Col).empty;
    var i: u64 = 1;
    while (i < ncols) : (i += 1) { // each iteration consumes >= 2 bytes: bounded by the block
        const tc = try r.byte();
        if (tc < 10) return error.Malformed;
        const kind: Kind = switch ((tc - 10) / 2) {
            ST_STRING => .string,
            ST_INT32 => .int32,
            ST_UINT32 => .uint32,
            ST_DOUBLE => .double,
            ST_FLOAT => .float,
            else => return error.Malformed, // boolean/int64 columns: tile57 never emits them
        };
        const key = try r.bytes(try r.varint());
        try cols.append(a, .{ .kind = kind, .nullable = (tc - 10) % 2 == 1, .key = key });
    }

    // ---- geometry column ---------------------------------------------------
    // Stream 0 is GeometryType; LENGTH streams are keyed by their subtype;
    // the remaining DATA stream is the vertex buffer.
    const n_gstreams = try r.varint();
    var gtypes: []u32 = &.{};
    var geoms: []u32 = &.{};
    var parts_lens: []u32 = &.{};
    var rings_lens: []u32 = &.{};
    var verts: []i32 = &.{};
    var si: u64 = 0;
    while (si < n_gstreams) : (si += 1) { // each stream consumes >= 4 bytes: bounded by the block
        const s = try readStream(&r);
        if (si == 0) {
            gtypes = try readVarintU32s(a, s);
        } else if (s.phys == PHYS_LENGTH and s.sub == LEN_GEOMETRIES) {
            geoms = try readVarintU32s(a, s);
        } else if (s.phys == PHYS_LENGTH and s.sub == LEN_PARTS) {
            parts_lens = try readVarintU32s(a, s);
        } else if (s.phys == PHYS_LENGTH and s.sub == LEN_RINGS) {
            rings_lens = try readVarintU32s(a, s);
        } else {
            verts = try readVertices(a, s);
        }
    }

    // ---- rebuild features ---------------------------------------------------
    const feats = try a.alloc(mvt.Feature, gtypes.len);
    var vi: usize = 0; // vertex component cursor
    var gi: usize = 0; // GEOMETRIES cursor
    var pi: usize = 0; // PARTS cursor
    var ri: usize = 0; // RINGS cursor
    for (gtypes, feats) |g, *f| {
        switch (g) {
            G_POINT, G_MULTIPOINT => {
                const n: usize = if (g == G_POINT) 1 else try take(geoms, &gi);
                const parts = try a.alloc([]const mvt.Point, 1);
                parts[0] = try takeVerts(a, verts, &vi, n);
                f.* = .{ .geom_type = .point, .parts = parts };
            },
            G_LINESTRING, G_MULTILINESTRING => {
                const nlines: usize = if (g == G_MULTILINESTRING) try take(geoms, &gi) else 1;
                if (nlines > parts_lens.len - pi) return error.Malformed;
                const parts = try a.alloc([]const mvt.Point, nlines);
                for (parts) |*part| {
                    part.* = try takeVerts(a, verts, &vi, try take(parts_lens, &pi));
                }
                f.* = .{ .geom_type = .linestring, .parts = parts };
            },
            G_POLYGON => {
                const nrings = try take(parts_lens, &pi);
                if (nrings > rings_lens.len - ri) return error.Malformed;
                const parts = try a.alloc([]const mvt.Point, nrings);
                for (parts) |*part| {
                    const ring = try takeVerts(a, verts, &vi, try take(rings_lens, &ri));
                    // tile57's model rings are explicitly closed; MVT rings
                    // decode OPEN (ClosePath is implicit). Drop the closing
                    // duplicate so both formats agree downstream.
                    const open = if (ring.len >= 2 and
                        ring[0].x == ring[ring.len - 1].x and ring[0].y == ring[ring.len - 1].y)
                        ring[0 .. ring.len - 1]
                    else
                        ring;
                    part.* = open;
                }
                f.* = .{ .geom_type = .polygon, .parts = parts };
            },
            else => return error.Malformed, // MULTIPOLYGON and beyond: tile57 never emits them
        }
    }

    // ---- property columns ----------------------------------------------------
    // Build the interned model directly: keys = one entry per column, values
    // appended as decoded (dictionary entries intern naturally — one Value
    // per distinct string), tags = (column index, value index) per feature.
    const keys = try a.alloc([]const u8, cols.items.len);
    for (cols.items, keys) |c, *k| k.* = c.key;
    var values = std.ArrayList(mvt.Value).empty;
    const tagbuf = try a.alloc(std.ArrayList(u32), feats.len);
    for (tagbuf) |*tb| tb.* = .empty;

    for (cols.items, 0..) |col, ci| {
        const ckey: u32 = @intCast(ci); // cols.len <= block bytes / 2, fits easily
        if (col.kind == .string) {
            var nstreams = try r.varint();
            var present: ?[]const bool = null;
            if (col.nullable) {
                if (nstreams == 0) return error.Malformed;
                present = try readPresent(a, try readStream(&r), feats.len);
                nstreams -= 1;
            }
            if (nstreams == 3) { // dictionary: dict lengths + dict bytes + offsets
                const dlens = try readVarintU32s(a, try readStream(&r));
                var dr = Reader{ .buf = (try readStream(&r)).data };
                const base = values.items.len;
                for (dlens) |dl| try values.append(a, .{ .string = try dr.bytes(dl) });
                const os = try readStream(&r);
                if (os.num_values > os.data.len) return error.Malformed;
                var or_ = Reader{ .buf = os.data };
                var fi: usize = 0;
                for (0..os.num_values) |_| {
                    const ix = try toUsize(try or_.varint());
                    if (ix >= dlens.len) return error.Malformed;
                    const slot = try nextPresent(present, &fi, feats.len);
                    try appendTag(a, &tagbuf[slot], ckey, base + ix);
                }
            } else if (nstreams == 2) { // plain: lengths + bytes
                const lens = try readVarintU32s(a, try readStream(&r));
                var dr = Reader{ .buf = (try readStream(&r)).data };
                var fi: usize = 0;
                for (lens) |sl| {
                    const s = try dr.bytes(sl);
                    const slot = try nextPresent(present, &fi, feats.len);
                    try values.append(a, .{ .string = s });
                    try appendTag(a, &tagbuf[slot], ckey, values.items.len - 1);
                }
            } else return error.Malformed;
        } else {
            // Numeric: no stream-count prefix (hasStreamCount is false for
            // scalars) — an optional PRESENT stream, then one DATA stream.
            var present: ?[]const bool = null;
            if (col.nullable) present = try readPresent(a, try readStream(&r), feats.len);
            const s = try readStream(&r);
            switch (col.kind) {
                // Cap counts against the stream's bytes before decoding:
                // varints are >= 1 byte, doubles 8, floats 4.
                .int32, .uint32 => if (s.num_values > s.data.len) return error.Malformed,
                .double => if (s.num_values > s.data.len / 8) return error.Malformed,
                .float => if (s.num_values > s.data.len / 4) return error.Malformed,
                .string => unreachable,
            }
            var dr = Reader{ .buf = s.data };
            var fi: usize = 0;
            for (0..s.num_values) |_| {
                const v: mvt.Value = switch (col.kind) {
                    .int32 => .{ .int = unzigzag32(try dr.varint()) },
                    .uint32 => .{ .uint = try dr.varint() },
                    .double => .{ .double = @bitCast(std.mem.readInt(u64, (try dr.bytes(8))[0..8], .little)) },
                    // Wire float widens to double, same as the MVT decoder:
                    // consumers see one arm per value domain.
                    .float => .{ .double = @as(f32, @bitCast(std.mem.readInt(u32, (try dr.bytes(4))[0..4], .little))) },
                    .string => unreachable,
                };
                const slot = try nextPresent(present, &fi, feats.len);
                try values.append(a, v);
                try appendTag(a, &tagbuf[slot], ckey, values.items.len - 1);
            }
        }
    }
    for (feats, tagbuf) |*f, tb| f.tags = tb.items;

    return .{
        .name = name,
        .extent = extent,
        .keys = keys,
        .values = values.items,
        .features = feats,
    };
}

/// Consume the next value from a length/count stream, or error.Malformed
/// when a hostile tile's counts overrun it.
fn take(arr: []const u32, cursor: *usize) error{Malformed}!usize {
    if (cursor.* >= arr.len) return error.Malformed;
    const v = arr[cursor.*];
    cursor.* += 1;
    return v;
}

/// Copy the next `n` points out of the interleaved vertex buffer,
/// bounds-checked against what remains.
fn takeVerts(a: Allocator, verts: []const i32, vi: *usize, n: usize) ![]mvt.Point {
    if (n > (verts.len - vi.*) / 2) return error.Malformed;
    const pts = try a.alloc(mvt.Point, n);
    for (pts) |*p| {
        p.* = .{ .x = verts[vi.*], .y = verts[vi.* + 1] };
        vi.* += 2;
    }
    return pts;
}

/// The feature slot the next column value belongs to: with a PRESENT bitmap,
/// skip absent features; without, features are dense. Overrun (more values
/// than present features) is malformed.
fn nextPresent(present: ?[]const bool, fi: *usize, nfeats: usize) error{Malformed}!usize {
    if (present) |p| {
        while (fi.* < p.len and !p[fi.*]) fi.* += 1;
    }
    if (fi.* >= nfeats) return error.Malformed;
    const slot = fi.*;
    fi.* += 1;
    return slot;
}

/// Append one interned (key index, value index) pair. Value indices are u32
/// in the mvt model; a tile big enough to overflow that is malformed.
fn appendTag(a: Allocator, tags: *std.ArrayList(u32), key: u32, value_index: usize) !void {
    const vix = std.math.cast(u32, value_index) orelse return error.Malformed;
    try tags.appendSlice(a, &.{ key, vix });
}

// ---- tests ------------------------------------------------------------------
//
// The fixture writer below is a NON-PUB port of tile57's mlt.encode subset
// (tile57/src/tiles/mlt.zig encode()), test-only — the same pattern as
// pmtiles.zig's fixture writer. charttable never emits MLT; tile57 owns that.

const TestValue = union(enum) { string: []const u8, int32: i32, uint32: u32, double: f64, float: f32 };
const TestProp = struct { key: []const u8, value: TestValue };
const TestFeature = struct {
    geom_type: mvt.GeomType,
    parts: []const []const mvt.Point,
    props: []const TestProp = &.{},
};
const TestLayer = struct { name: []const u8, extent: u32 = 4096, features: []const TestFeature };

fn tPutVarint(b: *std.ArrayList(u8), a: Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try b.append(a, @intCast((v & 0x7F) | 0x80));
    try b.append(a, @intCast(v));
}

fn tZigzag32(n: i32) u32 {
    return @bitCast((n << 1) ^ (n >> 31));
}

fn tMeta(b: *std.ArrayList(u8), a: Allocator, phys: u8, sub: u8, llt1: u8, plt: u8, nv: u64, bl: u64) !void {
    try b.append(a, (phys << 4) | sub);
    try b.append(a, (llt1 << 5) | plt);
    try tPutVarint(b, a, nv);
    try tPutVarint(b, a, bl);
}

fn tFind(f: TestFeature, key: []const u8) ?TestValue {
    for (f.props) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

const TCol = struct { key: []const u8, kind: std.meta.Tag(TestValue), nullable: bool };

// Distinct keys in first-seen order (fixtures keep kinds consistent per key).
fn tCollectCols(feats: []const TestFeature, out: []TCol) usize {
    var n: usize = 0;
    for (feats) |f| next: for (f.props) |p| {
        for (out[0..n]) |c| if (std.mem.eql(u8, c.key, p.key)) continue :next;
        out[n] = .{ .key = p.key, .kind = std.meta.activeTag(p.value), .nullable = false };
        n += 1;
    };
    for (out[0..n]) |*c| {
        var count: usize = 0;
        for (feats) |f| {
            if (tFind(f, c.key) != null) count += 1;
        }
        c.nullable = count < feats.len;
    }
    return n;
}

fn tScalarOrdinal(kind: std.meta.Tag(TestValue)) u8 {
    return switch (kind) {
        .string => ST_STRING,
        .int32 => ST_INT32,
        .uint32 => ST_UINT32,
        .double => ST_DOUBLE,
        .float => ST_FLOAT,
    };
}

// ORC byte-RLE present stream, literal runs only (as tile57 emits).
fn tPresentStream(b: *std.ArrayList(u8), a: Allocator, present: []const bool) !void {
    const nbytes = (present.len + 7) / 8;
    const bits = try a.alloc(u8, nbytes);
    @memset(bits, 0);
    for (present, 0..) |p, i| if (p) {
        bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    };
    var rle = std.ArrayList(u8).empty;
    var off: usize = 0;
    while (off < nbytes) {
        const chunk = @min(nbytes - off, 128);
        try rle.append(a, @intCast(@as(usize, 256) - chunk)); // literal-run header
        try rle.appendSlice(a, bits[off .. off + chunk]);
        off += chunk;
    }
    try tMeta(b, a, PHYS_PRESENT, 0, 0, 0, present.len, rle.items.len);
    try b.appendSlice(a, rle.items);
}

fn tEncodeGeometry(body: *std.ArrayList(u8), a: Allocator, features: []const TestFeature) !void {
    const gtypes = try a.alloc(u32, features.len);
    var geom_lens = std.ArrayList(u8).empty;
    var part_lens = std.ArrayList(u8).empty;
    var ring_lens = std.ArrayList(u8).empty;
    var verts = std.ArrayList(i32).empty;
    var n_geom: u64 = 0;
    var n_part: u64 = 0;
    var n_ring: u64 = 0;

    for (features, gtypes) |f, *gt| {
        switch (f.geom_type) {
            .point => {
                var npts: u64 = 0;
                for (f.parts) |part| for (part) |p| {
                    try verts.appendSlice(a, &.{ p.x, p.y });
                    npts += 1;
                };
                if (npts == 1) {
                    gt.* = G_POINT;
                } else {
                    gt.* = G_MULTIPOINT;
                    try tPutVarint(&geom_lens, a, npts);
                    n_geom += 1;
                }
            },
            .linestring => {
                gt.* = G_MULTILINESTRING;
                try tPutVarint(&geom_lens, a, f.parts.len);
                n_geom += 1;
                for (f.parts) |line| {
                    try tPutVarint(&part_lens, a, line.len);
                    n_part += 1;
                    for (line) |p| try verts.appendSlice(a, &.{ p.x, p.y });
                }
            },
            .polygon => {
                gt.* = G_POLYGON;
                try tPutVarint(&part_lens, a, f.parts.len);
                n_part += 1;
                for (f.parts) |ring| {
                    try tPutVarint(&ring_lens, a, ring.len);
                    n_ring += 1;
                    for (ring) |p| try verts.appendSlice(a, &.{ p.x, p.y });
                }
            },
            .unknown => {
                gt.* = G_POINT;
                try verts.appendSlice(a, &.{ 0, 0 });
            },
        }
    }

    var num_streams: u64 = 2;
    if (n_geom > 0) num_streams += 1;
    if (n_part > 0) num_streams += 1;
    if (n_ring > 0) num_streams += 1;
    try tPutVarint(body, a, num_streams);

    var data = std.ArrayList(u8).empty;
    for (gtypes) |g| try tPutVarint(&data, a, g);
    try tMeta(body, a, PHYS_DATA, DICT_NONE, 0, 2, features.len, data.items.len);
    try body.appendSlice(a, data.items);

    if (n_geom > 0) {
        try tMeta(body, a, PHYS_LENGTH, LEN_GEOMETRIES, 0, 2, n_geom, geom_lens.items.len);
        try body.appendSlice(a, geom_lens.items);
    }
    if (n_part > 0) {
        try tMeta(body, a, PHYS_LENGTH, LEN_PARTS, 0, 2, n_part, part_lens.items.len);
        try body.appendSlice(a, part_lens.items);
    }
    if (n_ring > 0) {
        try tMeta(body, a, PHYS_LENGTH, LEN_RINGS, 0, 2, n_ring, ring_lens.items.len);
        try body.appendSlice(a, ring_lens.items);
    }

    data = .empty;
    var prev_x: i32 = 0;
    var prev_y: i32 = 0;
    var k: usize = 0;
    while (k < verts.items.len) : (k += 2) {
        try tPutVarint(&data, a, tZigzag32(verts.items[k] -% prev_x));
        try tPutVarint(&data, a, tZigzag32(verts.items[k + 1] -% prev_y));
        prev_x = verts.items[k];
        prev_y = verts.items[k + 1];
    }
    try tMeta(body, a, PHYS_DATA, DICT_VERTEX, 2, 2, verts.items.len, data.items.len);
    try body.appendSlice(a, data.items);
}

fn tEncodeStringColumn(body: *std.ArrayList(u8), a: Allocator, features: []const TestFeature, col: TCol) !void {
    var npresent: usize = 0;
    for (features) |f| {
        if (tFind(f, col.key) != null) npresent += 1;
    }
    var dict = std.ArrayList([]const u8).empty;
    var idxs = std.ArrayList(u32).empty;
    for (features) |f| {
        const s = (tFind(f, col.key) orelse continue).string;
        const found: ?u32 = for (dict.items, 0..) |d, di| {
            if (std.mem.eql(u8, d, s)) break @intCast(di);
        } else null;
        if (found) |ix| {
            try idxs.append(a, ix);
        } else {
            try idxs.append(a, @intCast(dict.items.len));
            try dict.append(a, s);
        }
    }
    const use_dict = dict.items.len < npresent;

    try tPutVarint(body, a, (if (col.nullable) @as(u64, 1) else 0) + (if (use_dict) @as(u64, 3) else 2));
    if (col.nullable) {
        const pr = try a.alloc(bool, features.len);
        for (features, pr) |f, *p| p.* = tFind(f, col.key) != null;
        try tPresentStream(body, a, pr);
    }

    if (use_dict) {
        var dlen = std.ArrayList(u8).empty;
        var dbytes = std.ArrayList(u8).empty;
        for (dict.items) |d| {
            try tPutVarint(&dlen, a, d.len);
            try dbytes.appendSlice(a, d);
        }
        try tMeta(body, a, PHYS_LENGTH, LEN_DICTIONARY, 0, 2, dict.items.len, dlen.items.len);
        try body.appendSlice(a, dlen.items);
        try tMeta(body, a, PHYS_DATA, DICT_SINGLE, 0, 0, dbytes.items.len, dbytes.items.len);
        try body.appendSlice(a, dbytes.items);
        var off = std.ArrayList(u8).empty;
        for (idxs.items) |ix| try tPutVarint(&off, a, ix);
        try tMeta(body, a, PHYS_OFFSET, OFF_STRING, 0, 2, npresent, off.items.len);
        try body.appendSlice(a, off.items);
    } else {
        var lens = std.ArrayList(u8).empty;
        var data = std.ArrayList(u8).empty;
        for (features) |f| {
            const s = (tFind(f, col.key) orelse continue).string;
            try tPutVarint(&lens, a, s.len);
            try data.appendSlice(a, s);
        }
        try tMeta(body, a, PHYS_LENGTH, LEN_VAR_BINARY, 0, 2, npresent, lens.items.len);
        try body.appendSlice(a, lens.items);
        try tMeta(body, a, PHYS_DATA, DICT_NONE, 0, 0, data.items.len, data.items.len);
        try body.appendSlice(a, data.items);
    }
}

fn tEncodePropColumn(body: *std.ArrayList(u8), a: Allocator, features: []const TestFeature, col: TCol) !void {
    if (col.kind == .string) return tEncodeStringColumn(body, a, features, col);
    if (col.nullable) {
        const pr = try a.alloc(bool, features.len);
        for (features, pr) |f, *p| p.* = tFind(f, col.key) != null;
        try tPresentStream(body, a, pr);
    }
    var data = std.ArrayList(u8).empty;
    var nvals: u64 = 0;
    for (features) |f| {
        const v = tFind(f, col.key) orelse continue;
        nvals += 1;
        switch (v) {
            .int32 => |n| try tPutVarint(&data, a, tZigzag32(n)),
            .uint32 => |n| try tPutVarint(&data, a, n),
            .double => |d| {
                var le: [8]u8 = undefined;
                std.mem.writeInt(u64, &le, @bitCast(d), .little);
                try data.appendSlice(a, &le);
            },
            .float => |fl| {
                var le: [4]u8 = undefined;
                std.mem.writeInt(u32, &le, @bitCast(fl), .little);
                try data.appendSlice(a, &le);
            },
            .string => unreachable,
        }
    }
    const plt: u8 = if (col.kind == .int32 or col.kind == .uint32) 2 else 0;
    try tMeta(body, a, PHYS_DATA, DICT_NONE, 0, plt, nvals, data.items.len);
    try body.appendSlice(a, data.items);
}

/// Encode a tile of TestLayers to MLT bytes — fixture writer, arena-backed.
fn testEncode(a: Allocator, layers: []const TestLayer) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var colbuf: [16]TCol = undefined;
    for (layers) |layer| {
        const cols = colbuf[0..tCollectCols(layer.features, &colbuf)];
        var body = std.ArrayList(u8).empty;
        try tPutVarint(&body, a, layer.name.len);
        try body.appendSlice(a, layer.name);
        try tPutVarint(&body, a, layer.extent);
        try tPutVarint(&body, a, 1 + cols.len);
        try body.append(a, TYPECODE_GEOMETRY);
        for (cols) |c| {
            try body.append(a, 10 + tScalarOrdinal(c.kind) * 2 + @as(u8, if (c.nullable) 1 else 0));
            try tPutVarint(&body, a, c.key.len);
            try body.appendSlice(a, c.key);
        }
        try tEncodeGeometry(&body, a, layer.features);
        for (cols) |c| try tEncodePropColumn(&body, a, layer.features, c);

        try tPutVarint(&out, a, 1 + body.items.len); // blockLength (tag + body)
        try out.append(a, 1); // tag = 1
        try out.appendSlice(a, body.items);
    }
    return out.toOwnedSlice(a);
}

// The rich fixture: adapted from tile57's round-trip test (mlt.zig:891) —
// a polygon with a hole (rings CLOSED as tile57's model carries them), a
// clip-split two-part line, and a point; dictionary strings (color_token
// repeats), a plain nullable string (symbol_name), int32/uint32/double/float
// columns, some nullable.
fn richFixture(a: Allocator) ![]u8 {
    const ring = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 80 }, .{ .x = 0, .y = 0 } };
    const hole = [_]mvt.Point{ .{ .x = 10, .y = 5 }, .{ .x = 20, .y = 5 }, .{ .x = 15, .y = 15 }, .{ .x = 10, .y = 5 } };
    const poly_parts = [_][]const mvt.Point{ &ring, &hole };
    const l1 = [_]mvt.Point{ .{ .x = -5, .y = 3 }, .{ .x = 50, .y = 60 } };
    const l2 = [_]mvt.Point{ .{ .x = 7, .y = 7 }, .{ .x = 8, .y = 9 }, .{ .x = 12, .y = 4 } };
    const line_parts = [_][]const mvt.Point{ &l1, &l2 };
    const pt = [_]mvt.Point{.{ .x = 42, .y = 17 }};
    const pt_parts = [_][]const mvt.Point{&pt};

    const poly_props = [_]TestProp{
        .{ .key = "color_token", .value = .{ .string = "DEPMS" } },
        .{ .key = "display_priority", .value = .{ .int32 = 3 } },
        .{ .key = "drval1", .value = .{ .float = 5.5 } },
        .{ .key = "band", .value = .{ .uint32 = 2 } },
    };
    const line_props = [_]TestProp{
        .{ .key = "color_token", .value = .{ .string = "CHBLK" } },
        .{ .key = "display_priority", .value = .{ .int32 = -6 } },
        .{ .key = "width_px", .value = .{ .double = 1.5 } },
        .{ .key = "band", .value = .{ .uint32 = 2 } },
    };
    const pt_props = [_]TestProp{
        .{ .key = "color_token", .value = .{ .string = "DEPMS" } }, // repeats -> dictionary
        .{ .key = "display_priority", .value = .{ .int32 = 9 } },
        .{ .key = "symbol_name", .value = .{ .string = "BOYLAT13" } }, // nullable, plain
        .{ .key = "band", .value = .{ .uint32 = 2 } },
    };
    const feats = [_]TestFeature{
        .{ .geom_type = .polygon, .parts = &poly_parts, .props = &poly_props },
        .{ .geom_type = .linestring, .parts = &line_parts, .props = &line_props },
        .{ .geom_type = .point, .parts = &pt_parts, .props = &pt_props },
    };
    const layers = [_]TestLayer{.{ .name = "areas", .extent = 4096, .features = &feats }};
    return testEncode(a, &layers);
}

test "decode round-trips the tile57 encoding: geometry, interning, dict + plain + numeric" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try richFixture(a);
    const tile = try decode(a, bytes);
    try t.expectEqual(@as(usize, 1), tile.layers.len);
    const l = tile.layer("areas").?;
    try t.expect(tile.layer("absent") == null);
    try t.expectEqual(@as(u32, 4096), l.extent);
    try t.expectEqual(@as(usize, 3), l.features.len);

    // Geometry: rings come back OPEN (closing duplicate dropped), exterior
    // first then the hole, matching what mvt.decode yields for the same bake.
    const poly = &l.features[0];
    try t.expectEqual(mvt.GeomType.polygon, poly.geom_type);
    try t.expectEqual(@as(usize, 2), poly.parts.len);
    try t.expectEqualSlices(mvt.Point, &.{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 80 } }, poly.parts[0]);
    try t.expectEqualSlices(mvt.Point, &.{ .{ .x = 10, .y = 5 }, .{ .x = 20, .y = 5 }, .{ .x = 15, .y = 15 } }, poly.parts[1]);
    try t.expect(mvt.ringArea2(poly.parts[0]) != 0);

    const line = &l.features[1];
    try t.expectEqual(mvt.GeomType.linestring, line.geom_type);
    try t.expectEqual(@as(usize, 2), line.parts.len);
    try t.expectEqualSlices(mvt.Point, &.{ .{ .x = -5, .y = 3 }, .{ .x = 50, .y = 60 } }, line.parts[0]);
    try t.expectEqualSlices(mvt.Point, &.{ .{ .x = 7, .y = 7 }, .{ .x = 8, .y = 9 }, .{ .x = 12, .y = 4 } }, line.parts[1]);

    const p = &l.features[2];
    try t.expectEqual(mvt.GeomType.point, p.geom_type);
    try t.expectEqual(@as(usize, 1), p.parts.len);
    try t.expectEqual(mvt.Point{ .x = 42, .y = 17 }, p.parts[0][0]);

    // Interned properties: resolve keys once, then read by index.
    const k_color = l.keyIndex("color_token").?;
    const k_prio = l.keyIndex("display_priority").?;
    const k_drval = l.keyIndex("drval1").?;
    const k_band = l.keyIndex("band").?;
    const k_width = l.keyIndex("width_px").?;
    const k_sym = l.keyIndex("symbol_name").?;
    try t.expect(l.keyIndex("no-such-key") == null);

    try t.expectEqualStrings("DEPMS", l.property(poly, k_color).?.string);
    try t.expectEqualStrings("CHBLK", l.property(line, k_color).?.string);
    try t.expectEqual(@as(i64, 3), l.property(poly, k_prio).?.int);
    try t.expectEqual(@as(i64, -6), l.property(line, k_prio).?.int); // zigzag round-trip
    try t.expectEqual(@as(i64, 9), l.property(p, k_prio).?.int);
    try t.expectEqual(@as(u64, 2), l.property(poly, k_band).?.uint);
    try t.expectEqual(@as(f64, 5.5), l.property(poly, k_drval).?.double); // float widened
    try t.expectEqual(@as(f64, 1.5), l.property(line, k_width).?.double);
    try t.expectEqualStrings("BOYLAT13", l.property(p, k_sym).?.string);

    // Nullable columns: absent stays absent.
    try t.expect(l.property(poly, k_sym) == null);
    try t.expect(l.property(line, k_drval) == null);
    try t.expect(l.property(p, k_width) == null);
    try t.expectEqual(@as(usize, 4), poly.propCount());

    // Dictionary interning is real: the two "DEPMS" features share ONE value
    // table entry.
    try t.expectEqual(poly.valueIndex(k_color).?, p.valueIndex(k_color).?);
}

test "multipoint stays one part; empty layer and multiple layers decode" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mp = [_]mvt.Point{ .{ .x = 3, .y = 4 }, .{ .x = 1, .y = 7 } };
    const mp_parts = [_][]const mvt.Point{&mp};
    const seg = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 9 } };
    const seg_parts = [_][]const mvt.Point{&seg};
    const layers = [_]TestLayer{
        .{ .name = "points", .features = &.{.{ .geom_type = .point, .parts = &mp_parts }} },
        .{ .name = "empty", .extent = 256, .features = &.{} },
        .{ .name = "lines", .features = &.{.{ .geom_type = .linestring, .parts = &seg_parts }} },
    };
    const tile = try decode(a, try testEncode(a, &layers));
    try t.expectEqual(@as(usize, 3), tile.layers.len);

    const f = &tile.layer("points").?.features[0];
    try t.expectEqual(@as(usize, 1), f.parts.len);
    try t.expectEqualSlices(mvt.Point, &.{ .{ .x = 3, .y = 4 }, .{ .x = 1, .y = 7 } }, f.parts[0]);

    try t.expectEqual(@as(usize, 0), tile.layer("empty").?.features.len);
    try t.expectEqual(@as(u32, 256), tile.layer("empty").?.extent);
    try t.expectEqual(@as(usize, 2), tile.layer("lines").?.features[0].parts[0].len);

    const empty = try decode(a, &[_]u8{});
    try t.expectEqual(@as(usize, 0), empty.layers.len);
}

// A minimal hand-built block: geometry column only, one feature of MLT
// geometry type `g`, an empty vertex buffer. Used to poke type validation
// and cursor hardening directly.
fn tinyBlock(comptime g: u8) [17]u8 {
    return [_]u8{16} // blockLength
    ++ [_]u8{1} // tag = 1
    ++ [_]u8{ 1, 'x' } // name "x"
    ++ [_]u8{16} // extent
    ++ [_]u8{1} // columnCount (geometry only)
    ++ [_]u8{TYPECODE_GEOMETRY} //
    ++ [_]u8{2} // numStreams
    ++ [_]u8{ 0x10, 0x02, 1, 1, g } // GeometryType: nv=1 bl=1 data=[g]
    ++ [_]u8{ 0x13, 0x42, 0, 0 }; // VertexBuffer: nv=0 bl=0
}

test "hostile input: bad types, overrun cursors, hostile counts, garbage" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // MULTIPOLYGON (and anything past it) is outside tile57's subset.
    try t.expectError(error.Malformed, decode(a, &tinyBlock(5)));
    try t.expectError(error.Malformed, decode(a, &tinyBlock(200)));
    // A polygon with no PARTS/RINGS streams overruns the length cursors.
    try t.expectError(error.Malformed, decode(a, &tinyBlock(2)));
    // A point with an empty vertex buffer overruns the vertex cursor.
    try t.expectError(error.Malformed, decode(a, &tinyBlock(0)));
    // A line with no PARTS stream.
    try t.expectError(error.Malformed, decode(a, &tinyBlock(1)));

    // Hostile count: numValues=2^32-1 with a 1-byte stream must not allocate.
    const hostile = [_]u8{ 15, 1, 1, 'x', 16, 1, TYPECODE_GEOMETRY, 2 } //
        ++ [_]u8{ 0x10, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } // nv=0xFFFFFFFF
        ++ [_]u8{0}; // bl=0
    try t.expectError(error.Malformed, decode(a, &hostile));

    // Block tag must be 1.
    try t.expectError(error.Malformed, decode(a, &[_]u8{ 2, 2, 0 }));
    // blockLength past the end of the buffer.
    try t.expectError(error.Malformed, decode(a, &[_]u8{ 0xFF, 0xFF, 0xFF }));
    // Truncated varint.
    try t.expectError(error.Malformed, decode(a, &[_]u8{0x80}));
}

// A hand-built block with one dictionary string column over one point
// feature; the final byte is the dictionary offset, so the two variants
// share a prefix.
const dict_block_prefix = [_]u8{39} // blockLength
    ++ [_]u8{1} // tag = 1
    ++ [_]u8{ 1, 'x' } // name
    ++ [_]u8{16} // extent
    ++ [_]u8{2} // columnCount
    ++ [_]u8{TYPECODE_GEOMETRY} //
    ++ [_]u8{ 28, 1, 'k' } // string col (10+9*2), key "k"
    ++ [_]u8{2} // geometry numStreams
    ++ [_]u8{ 0x10, 0x02, 1, 1, 0 } // GeometryType: [G_POINT]
    ++ [_]u8{ 0x13, 0x42, 2, 2, 0, 0 } // VertexBuffer: (0,0)
    ++ [_]u8{3} // string column numStreams (dictionary)
    ++ [_]u8{ 0x36, 0x02, 1, 1, 3 } // LENGTH/DICTIONARY: one entry, len 3
    ++ [_]u8{ 0x11, 0x00, 3, 3, 'a', 'b', 'c' } // DATA/SINGLE: "abc"
    ++ [_]u8{ 0x22, 0x02, 1, 1 }; // OFFSET/STRING header: nv=1 bl=1

test "dictionary offsets are validated; in-range ones intern" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const good = dict_block_prefix ++ [_]u8{0};
    const tile = try decode(a, &good);
    const l = &tile.layers[0];
    try t.expectEqualStrings("abc", l.property(&l.features[0], l.keyIndex("k").?).?.string);

    const bad = dict_block_prefix ++ [_]u8{7}; // index 7 into a 1-entry dictionary
    try t.expectError(error.Malformed, decode(a, &bad));
}

test "every truncation of the fixture decodes or errors — never crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try richFixture(a);
    var n: usize = 0;
    while (n < bytes.len) : (n += 1) {
        // A prefix may happen to end on a block boundary (valid tile) or not
        // (error.Malformed); either way the decoder must return.
        _ = decode(a, bytes[0..n]) catch |err| {
            try std.testing.expectEqual(error.Malformed, err);
        };
    }
}

test "decodes real MLT chart tiles via pmtiles (integration; skipped without chart data)" {
    const t = std.testing;
    const gpa = t.allocator;
    const pmtiles = @import("pmtiles.zig");
    const coord = @import("coord.zig");

    const io = std.Io.Threaded.global_single_threaded.io();
    // The M3 reference cell (DESIGN.md); machines without chart data skip.
    const path_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    const path = std.mem.span(path_env);
    var rd = pmtiles.Reader.open(gpa, io, path) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };
    defer rd.deinit();
    try t.expectEqual(pmtiles.TileType.mlt, rd.header.tile_type);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Walk the header bbox at mid zooms until tiles with the tile57/3 schema
    // layers show up; a baked harbour cell must serve them.
    const min_lon = @as(f64, @floatFromInt(rd.header.min_lon_e7)) / 1e7;
    const min_lat = @as(f64, @floatFromInt(rd.header.min_lat_e7)) / 1e7;
    const max_lon = @as(f64, @floatFromInt(rd.header.max_lon_e7)) / 1e7;
    const max_lat = @as(f64, @floatFromInt(rd.header.max_lat_e7)) / 1e7;

    var decoded: usize = 0;
    var seen_areas = false;
    var seen_lines = false;
    var seen_exterior = false; // a polygon whose first (exterior) ring has area
    var probes: usize = 0;
    const zooms = [_]u8{ 12, 11, 10, 13, 9, 8 };
    for (zooms) |z| {
        if (z < rd.header.min_zoom or z > rd.header.max_zoom) continue;
        const nw = coord.fromWorld(coord.lonLatToWorld(min_lon, max_lat), z);
        const se = coord.fromWorld(coord.lonLatToWorld(max_lon, min_lat), z);
        var ty = nw.y;
        while (ty <= se.y) : (ty += 1) {
            var tx = nw.x;
            while (tx <= se.x) : (tx += 1) {
                probes += 1;
                if (probes > 4096) break;
                const bytes = (try rd.getTile(a, z, tx, ty)) orelse continue;
                const tile = try decode(a, bytes);
                decoded += 1;

                for (tile.layers) |*l| {
                    try t.expect(l.name.len > 0);
                    try t.expect(l.extent > 0);
                    const bound = @as(i64, l.extent) * 8; // buffered tiles overhang a little
                    for (l.features) |*f| {
                        for (f.parts) |part| {
                            for (part) |pnt| {
                                try t.expect(@abs(@as(i64, pnt.x)) <= bound);
                                try t.expect(@abs(@as(i64, pnt.y)) <= bound);
                            }
                            switch (f.geom_type) {
                                .polygon => {
                                    // Rings decode OPEN, like the MVT path.
                                    try t.expect(part.len >= 3);
                                    const first = part[0];
                                    const last = part[part.len - 1];
                                    try t.expect(first.x != last.x or first.y != last.y);
                                },
                                .linestring => try t.expect(part.len >= 2),
                                else => {},
                            }
                        }
                        if (f.geom_type == .polygon and f.parts.len > 0 and
                            mvt.ringArea2(f.parts[0]) > 0) seen_exterior = true;
                        // Interned-lookup self-consistency on real data.
                        var i: usize = 0;
                        while (i < f.tags.len) : (i += 2) {
                            const ki = l.keyIndex(l.keys[f.tags[i]]).?;
                            const v = l.property(f, ki).?;
                            try t.expectEqual(std.meta.activeTag(l.values[f.tags[i + 1]]), std.meta.activeTag(v));
                        }
                    }
                }
                if (tile.layer("areas")) |l| {
                    if (l.features.len > 0) seen_areas = true;
                }
                if (tile.layer("lines")) |l| {
                    if (l.features.len > 0) seen_lines = true;
                }
            }
        }
        if (decoded > 0 and seen_areas and seen_lines) break;
    }
    try t.expect(decoded > 0);
    try t.expect(seen_areas);
    try t.expect(seen_lines);
    try t.expect(seen_exterior);
}

test "zigzag decode" {
    try std.testing.expectEqual(@as(i32, 0), unzigzag32(0));
    try std.testing.expectEqual(@as(i32, -1), unzigzag32(1));
    try std.testing.expectEqual(@as(i32, 1), unzigzag32(2));
    try std.testing.expectEqual(@as(i32, 25), unzigzag32(50));
    try std.testing.expectEqual(@as(i32, -6), unzigzag32(11));
}

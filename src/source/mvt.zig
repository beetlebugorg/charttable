//! Mapbox Vector Tile (MVT) v2 decoder.
//! Spec: https://github.com/mapbox/vector-tile-spec/tree/master/2.1
//!
//! Decode only — charttable consumes tiles, it never emits them (tile57 owns
//! the encoder this was ported from). Hardened relative to the tile57 test
//! decoder for foreign input: every read is bounds-checked and tag indices
//! are validated at decode, so a truncated or hostile tile is
//! error.Malformed, never a crash.
//!
//! Property access is shaped for the style engine's hot loop (DESIGN.md
//! "Interned property keys"): a layer's keys and values are interned tables,
//! a feature's properties are (key index, value index) pairs into them.
//! Resolve a key string to its per-layer index ONCE (`Layer.keyIndex`), then
//! read features by that index (`Layer.property`) — integer compares only,
//! no per-feature string hashing (expression evaluation runs per feature;
//! the maplibre-branch profile put half its worker samples there).
//!
//! Ownership: `decode` allocates into the caller's allocator and frees
//! nothing individually — use a per-tile arena. Strings (layer names, keys,
//! string values) BORROW from the input buffer, which must outlive the
//! decoded tile.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GeomType = enum(u8) { unknown = 0, point = 1, linestring = 2, polygon = 3 };

pub const Point = struct { x: i32, y: i32 };

/// A property value. Wire `float` (field 2) widens to `double` and `sint`
/// (field 6) folds into `int` at decode, so consumers see one arm per value
/// domain: string, f64, i64, u64, bool.
pub const Value = union(enum) {
    string: []const u8,
    double: f64,
    int: i64,
    uint: u64,
    boolean: bool,
};

/// A (key, value) property pair as strings — for tooling and tests; hot
/// paths go through the interned indexes instead.
pub const Prop = struct { key: []const u8, value: Value };

pub const Feature = struct {
    id: ?u64 = null,
    geom_type: GeomType = .unknown,
    /// Geometry decoded from the command stream into i32 tile coordinates
    /// (0..extent, y down; a buffered tile may overhang). One part per line
    /// (linestrings) or per ring (polygons: each exterior followed by its
    /// holes; rings are OPEN — ClosePath's closing vertex stays implicit).
    /// A point feature is a single part holding all its points.
    parts: []const []const Point = &.{},
    /// Interned properties: (key index, value index) pairs into the owning
    /// layer's `keys`/`values` tables. Validated in-range at decode, so
    /// lookups never re-check.
    tags: []const u32 = &.{},

    /// The value-table index for per-layer key index `key`, or null when the
    /// feature has no such property. Integer compares over a handful of
    /// pairs — the per-feature half of the two-step lookup.
    pub fn valueIndex(f: *const Feature, key: u32) ?u32 {
        var i: usize = 0;
        while (i < f.tags.len) : (i += 2) {
            if (f.tags[i] == key) return f.tags[i + 1];
        }
        return null;
    }

    /// Number of properties on this feature.
    pub fn propCount(f: *const Feature) usize {
        return f.tags.len / 2;
    }
};

pub const Layer = struct {
    name: []const u8 = "",
    version: u32 = 1,
    extent: u32 = 4096,
    /// Interned key table: each property key appears once per layer.
    keys: []const []const u8 = &.{},
    /// Interned value table: features reference values by index.
    values: []const Value = &.{},
    features: []const Feature = &.{},

    /// Resolve a property key string to this layer's key index — do this
    /// once per (style layer × tile layer), then use `property` per feature.
    /// Linear scan: it runs once, not per feature.
    pub fn keyIndex(l: *const Layer, key: []const u8) ?u32 {
        for (l.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return @intCast(i);
        }
        return null;
    }

    /// A feature's value for pre-resolved key index `key`, or null.
    pub fn property(l: *const Layer, f: *const Feature, key: u32) ?Value {
        const vi = f.valueIndex(key) orelse return null;
        return l.values[vi];
    }

    /// The i-th property of `f` as a (key string, value) pair — tooling only.
    pub fn prop(l: *const Layer, f: *const Feature, i: usize) Prop {
        return .{ .key = l.keys[f.tags[2 * i]], .value = l.values[f.tags[2 * i + 1]] };
    }
};

pub const Tile = struct {
    layers: []const Layer = &.{},

    /// The layer named `name`, or null. Linear — resolve once per tile.
    pub fn layer(t: *const Tile, name: []const u8) ?*const Layer {
        for (t.layers) |*l| {
            if (std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }
};

/// Twice the signed area of a ring (shoelace). y is down, so positive is a
/// clockwise (exterior) ring per the MVT spec, negative a hole — how a
/// consumer groups a polygon's parts into exterior+holes. Exact in i64 for
/// any i32 coordinates.
pub fn ringArea2(ring: []const Point) i64 {
    if (ring.len < 3) return 0;
    var acc: i64 = 0;
    var j: usize = ring.len - 1;
    for (ring, 0..) |p, i| {
        const q = ring[j];
        acc += @as(i64, q.x) * p.y - @as(i64, p.x) * q.y;
        j = i;
    }
    return acc;
}

// ---- protobuf reading -------------------------------------------------------

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

    fn bytes(r: *Reader, n: u64) error{Malformed}![]const u8 {
        if (n > r.buf.len - r.pos) return error.Malformed;
        const s = r.buf[r.pos..][0..@intCast(n)];
        r.pos += @intCast(n);
        return s;
    }

    fn lenDelim(r: *Reader) error{Malformed}![]const u8 {
        return r.bytes(try r.varint());
    }

    fn skip(r: *Reader, wire: u64) error{Malformed}!void {
        switch (wire) {
            0 => _ = try r.varint(),
            1 => _ = try r.bytes(8),
            2 => _ = try r.lenDelim(),
            5 => _ = try r.bytes(4),
            else => return error.Malformed,
        }
    }
};

fn unzig(u: u64) i64 {
    const i: i64 = @bitCast(u >> 1);
    return i ^ -@as(i64, @intCast(u & 1));
}

// ---- decode -------------------------------------------------------------

/// Decode a tile. `a` should be a per-tile arena (nothing is individually
/// freed); the returned Tile borrows string bytes from `data`.
pub fn decode(a: Allocator, data: []const u8) !Tile {
    var layers = std.ArrayList(Layer).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        if (field == 3 and wire == 2) {
            try layers.append(a, try decodeLayer(a, try r.lenDelim()));
        } else try r.skip(wire);
    }
    return .{ .layers = layers.items };
}

fn decodeLayer(a: Allocator, data: []const u8) !Layer {
    var out = Layer{};
    var keys = std.ArrayList([]const u8).empty;
    var values = std.ArrayList(Value).empty;
    // Features may precede the keys/values fields in the message, so collect
    // their sub-buffers and decode them once both tables are complete.
    var feat_bufs = std.ArrayList([]const u8).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        if (wire == 0) {
            const v = try r.varint();
            switch (field) {
                15 => out.version = @truncate(v),
                5 => out.extent = @truncate(v),
                else => {},
            }
        } else if (wire == 2) {
            const s = try r.lenDelim();
            switch (field) {
                1 => out.name = s,
                2 => try feat_bufs.append(a, s),
                3 => try keys.append(a, s),
                4 => try values.append(a, try decodeValue(s)),
                else => {},
            }
        } else try r.skip(wire);
    }
    out.keys = keys.items;
    out.values = values.items;
    const feats = try a.alloc(Feature, feat_bufs.items.len);
    for (feat_bufs.items, feats) |fb, *f| {
        f.* = try decodeFeature(a, fb, keys.items.len, values.items.len);
    }
    out.features = feats;
    return out;
}

/// Exactly one field is set per the spec; the last one present wins here,
/// and a value message with none is malformed.
fn decodeValue(data: []const u8) !Value {
    var r = Reader{ .buf = data };
    var out: ?Value = null;
    while (r.pos < data.len) {
        const tag = try r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        switch (field) {
            1 => out = .{ .string = try r.lenDelim() },
            2 => {
                const b = try r.bytes(4);
                const bits = std.mem.readInt(u32, b[0..4], .little);
                out = .{ .double = @as(f32, @bitCast(bits)) };
            },
            3 => {
                const b = try r.bytes(8);
                const bits = std.mem.readInt(u64, b[0..8], .little);
                out = .{ .double = @bitCast(bits) };
            },
            4 => out = .{ .int = @bitCast(try r.varint()) },
            5 => out = .{ .uint = try r.varint() },
            6 => out = .{ .int = unzig(try r.varint()) },
            7 => out = .{ .boolean = (try r.varint()) != 0 },
            else => try r.skip(wire),
        }
    }
    return out orelse error.Malformed;
}

fn decodeFeature(a: Allocator, data: []const u8, nkeys: usize, nvalues: usize) !Feature {
    var out = Feature{};
    var tags = std.ArrayList(u32).empty;
    var geom = std.ArrayList(u32).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        if (wire == 0) {
            const v = try r.varint();
            switch (field) {
                1 => out.id = v,
                3 => out.geom_type = switch (v) {
                    1 => .point,
                    2 => .linestring,
                    3 => .polygon,
                    else => .unknown,
                },
                else => {},
            }
        } else if (wire == 2) {
            var pr = Reader{ .buf = try r.lenDelim() };
            switch (field) {
                2 => while (pr.pos < pr.buf.len) {
                    const t = try pr.varint();
                    if (t > std.math.maxInt(u32)) return error.Malformed;
                    try tags.append(a, @intCast(t));
                },
                4 => while (pr.pos < pr.buf.len) {
                    const g = try pr.varint();
                    if (g > std.math.maxInt(u32)) return error.Malformed;
                    try geom.append(a, @intCast(g));
                },
                else => {},
            }
        } else try r.skip(wire);
    }
    // Validate the interned property pairs once here, so per-feature lookups
    // never bounds-check.
    if (tags.items.len % 2 != 0) return error.Malformed;
    var i: usize = 0;
    while (i < tags.items.len) : (i += 2) {
        if (tags.items[i] >= nkeys or tags.items[i + 1] >= nvalues) return error.Malformed;
    }
    out.tags = tags.items;
    out.parts = try decodeGeometry(a, out.geom_type, geom.items);
    return out;
}

fn decodeGeometry(a: Allocator, gt: GeomType, g: []const u32) ![]const []const Point {
    var parts = std.ArrayList([]const Point).empty;
    var cur = std.ArrayList(Point).empty;
    var cx: i32 = 0;
    var cy: i32 = 0;
    var i: usize = 0;
    while (i < g.len) {
        const command = g[i] & 0x7;
        const count: usize = g[i] >> 3;
        i += 1;
        switch (command) {
            1, 2 => { // MoveTo, LineTo
                if (count > (g.len - i) / 2) return error.Malformed;
                var k: usize = 0;
                while (k < count) : (k += 1) {
                    // Each MoveTo starts a new part (line/ring); a point
                    // feature keeps all its points in one part.
                    if (command == 1 and gt != .point and cur.items.len > 0) {
                        try parts.append(a, cur.items);
                        cur = .empty;
                    }
                    // Wrapping adds: deltas in a well-formed tile stay in
                    // i32 range; a hostile one must not panic the decoder.
                    cx +%= @as(i32, @truncate(unzig(g[i])));
                    cy +%= @as(i32, @truncate(unzig(g[i + 1])));
                    i += 2;
                    try cur.append(a, .{ .x = cx, .y = cy });
                }
            },
            7 => {}, // ClosePath: rings stay open, closure is implicit
            else => return error.Malformed,
        }
    }
    if (cur.items.len > 0) try parts.append(a, cur.items);
    return parts.items;
}

// ---- tests --------------------------------------------------------------
//
// The fixture below is hand-assembled protobuf, byte by byte (tile57's
// encoder — tile57/src/tiles/mvt.zig encode() — was the wire-layout
// reference; charttable deliberately gains no encoder). Message lengths are
// computed by comptime array concatenation so every piece stays legible.

fn strBytes(comptime s: []const u8) [s.len]u8 {
    return s[0..s.len].*;
}

// Feature 0: point (25,17), id 42, class="primary" oneway=true, plus an
// unknown length-delimited field (5) the decoder must skip.
const fx_feat_point = [_]u8{ 0x08, 42 } // id (field 1, varint) = 42
    ++ [_]u8{ 0x12, 4, 0, 0, 1, 1 } // tags (field 2, packed): k0=v0, k1=v1
    ++ [_]u8{ 0x18, 1 } // type (field 3) = point
    ++ [_]u8{ 0x22, 3, 9, 50, 34 } // geometry (field 4): MoveTo(1) zz(25) zz(17)
    ++ [_]u8{ 0x2A, 2, 0xDE, 0xAD }; // unknown field 5 (len-delim): skipped

// Feature 1: linestring (2,2)->(2,10)->(10,10), width=2.5 lanes=7 grade=1.5.
const fx_feat_line = [_]u8{ 0x12, 6, 2, 2, 3, 3, 4, 4 } // tags: k2=v2 k3=v3 k4=v4
    ++ [_]u8{ 0x18, 2 } // type = linestring
    ++ [_]u8{ 0x22, 8, 9, 4, 4, 18, 0, 16, 16, 0 }; // MoveTo(2,2) LineTo(2)(2,10)(10,10)

// Feature 2: polygon, exterior square (0,0)..(8,8) CW (y down) with a CCW
// hole (2,2)..(6,6); class=sint(-3), oneway=int(-1).
const fx_feat_poly = [_]u8{ 0x12, 4, 0, 5, 1, 6 } // tags: k0=v5 k1=v6
    ++ [_]u8{ 0x18, 3 } // type = polygon
    ++ [_]u8{ 0x22, 22 } // geometry, 22 command/parameter integers:
    ++ [_]u8{ 9, 0, 0, 26, 16, 0, 0, 16, 15, 0, 15 } // MoveTo(0,0) LineTo(3)(8,0)(8,8)(0,8) Close
    ++ [_]u8{ 9, 4, 11, 26, 0, 8, 8, 0, 0, 7, 15 }; // MoveTo(2,2) LineTo(3)(2,6)(6,6)(6,2) Close

const fx_keys = [_]u8{ 0x1A, 5 } ++ strBytes("class") // key 0
++ [_]u8{ 0x1A, 6 } ++ strBytes("oneway") // key 1
++ [_]u8{ 0x1A, 5 } ++ strBytes("width") // key 2
++ [_]u8{ 0x1A, 5 } ++ strBytes("lanes") // key 3
++ [_]u8{ 0x1A, 5 } ++ strBytes("grade"); // key 4

const fx_values = [_]u8{ 0x22, 9, 0x0A, 7 } ++ strBytes("primary") // v0 string
++ [_]u8{ 0x22, 2, 0x38, 1 } // v1 bool true
++ [_]u8{ 0x22, 9, 0x19, 0, 0, 0, 0, 0, 0, 0x04, 0x40 } // v2 double 2.5
++ [_]u8{ 0x22, 2, 0x28, 7 } // v3 uint 7
++ [_]u8{ 0x22, 5, 0x15, 0, 0, 0xC0, 0x3F } // v4 float 1.5 (widens to double)
++ [_]u8{ 0x22, 2, 0x30, 5 } // v5 sint -3 (folds to int)
++ [_]u8{ 0x22, 11, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }; // v6 int -1

const fx_layer = [_]u8{ 0x78, 2 } // version (field 15) = 2
    ++ [_]u8{ 0x0A, 5 } ++ strBytes("roads") // name (field 1)
    ++ [_]u8{ 0x12, fx_feat_point.len } ++ fx_feat_point ++ [_]u8{ 0x12, fx_feat_line.len } ++ fx_feat_line ++ [_]u8{ 0x12, fx_feat_poly.len } ++ fx_feat_poly ++ fx_keys ++ fx_values //
    ++ [_]u8{ 0x28, 0x80, 0x20 } // extent (field 5) = 4096
    ++ [_]u8{ 0x40, 5 } // unknown varint field 8: skipped
    ++ [_]u8{ 0x4D, 1, 2, 3, 4 }; // unknown fixed32 field 9: skipped

// Tile.layers is field 3; the layer body is >127 bytes, so a 2-byte varint.
const fx_tile = [_]u8{ 0x1A, 0x80 | (fx_layer.len & 0x7F), fx_layer.len >> 7 } ++ fx_layer;

test "decode: layers, features, geometry, and interned properties" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tile = try decode(a, &fx_tile);
    try t.expectEqual(@as(usize, 1), tile.layers.len);
    const l = tile.layer("roads").?;
    try t.expect(tile.layer("absent") == null);
    try t.expectEqual(@as(u32, 2), l.version);
    try t.expectEqual(@as(u32, 4096), l.extent);
    try t.expectEqual(@as(usize, 5), l.keys.len);
    try t.expectEqual(@as(usize, 7), l.values.len);
    try t.expectEqual(@as(usize, 3), l.features.len);

    // Resolve keys ONCE per layer; every per-feature read below is by index.
    const k_class = l.keyIndex("class").?;
    const k_oneway = l.keyIndex("oneway").?;
    const k_width = l.keyIndex("width").?;
    const k_lanes = l.keyIndex("lanes").?;
    const k_grade = l.keyIndex("grade").?;
    try t.expect(l.keyIndex("no-such-key") == null);

    // Point feature: id, geometry, string + bool properties.
    const f0 = &l.features[0];
    try t.expectEqual(@as(u64, 42), f0.id.?);
    try t.expectEqual(GeomType.point, f0.geom_type);
    try t.expectEqual(@as(usize, 1), f0.parts.len);
    try t.expectEqual(Point{ .x = 25, .y = 17 }, f0.parts[0][0]);
    try t.expectEqualStrings("primary", l.property(f0, k_class).?.string);
    try t.expectEqual(true, l.property(f0, k_oneway).?.boolean);
    try t.expectEqual(@as(usize, 2), f0.propCount());
    try t.expect(l.property(f0, k_width) == null); // key absent on this feature

    // Line feature: geometry chain, double/uint/widened-float values, no id.
    const f1 = &l.features[1];
    try t.expect(f1.id == null);
    try t.expectEqual(GeomType.linestring, f1.geom_type);
    try t.expectEqual(@as(usize, 1), f1.parts.len);
    try t.expectEqualSlices(Point, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 10 }, .{ .x = 10, .y = 10 } }, f1.parts[0]);
    try t.expectEqual(@as(f64, 2.5), l.property(f1, k_width).?.double);
    try t.expectEqual(@as(u64, 7), l.property(f1, k_lanes).?.uint);
    try t.expectEqual(@as(f64, 1.5), l.property(f1, k_grade).?.double); // float arm widened
    try t.expect(l.property(f1, k_class) == null);

    // Polygon feature: exterior then hole, both open; winding by ringArea2.
    const f2 = &l.features[2];
    try t.expectEqual(GeomType.polygon, f2.geom_type);
    try t.expectEqual(@as(usize, 2), f2.parts.len);
    try t.expectEqualSlices(Point, &.{ .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 8, .y = 8 }, .{ .x = 0, .y = 8 } }, f2.parts[0]);
    try t.expectEqualSlices(Point, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 }, .{ .x = 6, .y = 6 }, .{ .x = 6, .y = 2 } }, f2.parts[1]);
    try t.expect(ringArea2(f2.parts[0]) > 0); // CW in y-down = exterior
    try t.expect(ringArea2(f2.parts[1]) < 0); // hole
    try t.expectEqual(@as(i64, -3), l.property(f2, k_class).?.int); // sint arm folded
    try t.expectEqual(@as(i64, -1), l.property(f2, k_oneway).?.int); // 10-byte negative varint

    // The tooling accessor agrees with the interned path.
    const p0 = l.prop(f0, 0);
    try t.expectEqualStrings("class", p0.key);
    try t.expectEqualStrings("primary", p0.value.string);
}

test "multipoint stays one part; empty input is an empty tile" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Layer "mp" with one point feature: MoveTo(2) (3,4) then (1,7).
    const body = [_]u8{ 0x0A, 2, 'm', 'p' } ++ [_]u8{ 0x12, 9, 0x18, 1, 0x22, 5, 17, 6, 8, 3, 6 };
    const tile_bytes = [_]u8{ 0x1A, body.len } ++ body;
    const tile = try decode(a, &tile_bytes);
    const f = &tile.layers[0].features[0];
    try t.expectEqual(@as(usize, 1), f.parts.len);
    try t.expectEqualSlices(Point, &.{ .{ .x = 3, .y = 4 }, .{ .x = 1, .y = 7 } }, f.parts[0]);

    const empty = try decode(a, &[_]u8{});
    try t.expectEqual(@as(usize, 0), empty.layers.len);
}

test "out-of-range tag indices are rejected at decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One key, one value — but the feature tags reference key index 3.
    const body = [_]u8{ 0x0A, 1, 't' } // name
        ++ [_]u8{ 0x12, 4, 0x12, 2, 3, 0 } // feature: tags [3, 0]
        ++ [_]u8{ 0x1A, 1, 'k' } // keys: ["k"]
        ++ [_]u8{ 0x22, 2, 0x38, 1 }; // values: [true]
    const bad = [_]u8{ 0x1A, body.len } ++ body;
    try std.testing.expectError(error.Malformed, decode(a, &bad));
}

test "every truncation of the fixture decodes or errors — never crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: usize = 0;
    while (n < fx_tile.len) : (n += 1) {
        // A prefix may happen to end on a message boundary (valid tile) or
        // not (error.Malformed); either way the decoder must return.
        _ = decode(a, fx_tile[0..n]) catch |err| {
            try std.testing.expectEqual(error.Malformed, err);
        };
    }
}

test "decodes a real baked tile when tile57's fixture is present (integration)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // tile57's checked-in Annapolis z14 tile (161KB, from the Go reference
    // bake). Machines without a tile57 checkout skip.
    const io = std.Io.Threaded.global_single_threaded.io();
    const tile57_env = std.c.getenv("CHARTTABLE_TILE57_DIR") orelse return error.SkipZigTest;
    const path = try std.fmt.allocPrint(a, "{s}/src/testdata/annapolis_z14.mvt", .{std.mem.span(tile57_env)});
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch
        return error.SkipZigTest;

    const tile = try decode(a, data);
    // 11 layers is the same oracle tile57's pmtiles round-trip test pins.
    try t.expectEqual(@as(usize, 11), tile.layers.len);
    var features: usize = 0;
    for (tile.layers) |l| {
        try t.expect(l.name.len > 0);
        try t.expectEqual(@as(u32, 2), l.version);
        features += l.features.len;
        // Interned-lookup self-consistency on real data: resolving each key
        // string and reading by index must agree with the raw tag pairs.
        for (l.features) |*f| {
            var i: usize = 0;
            while (i < f.tags.len) : (i += 2) {
                const ki = l.keyIndex(l.keys[f.tags[i]]).?;
                const v = l.property(f, ki).?;
                try t.expectEqual(std.meta.activeTag(l.values[f.tags[i + 1]]), std.meta.activeTag(v));
            }
        }
    }
    try t.expect(features > 0);
}

test "zigzag decode" {
    try std.testing.expectEqual(@as(i64, 0), unzig(0));
    try std.testing.expectEqual(@as(i64, -1), unzig(1));
    try std.testing.expectEqual(@as(i64, 1), unzig(2));
    try std.testing.expectEqual(@as(i64, 25), unzig(50));
    try std.testing.expectEqual(@as(i64, -6), unzig(11));
    try std.testing.expectEqual(@as(i64, 12345), unzig(24690));
}

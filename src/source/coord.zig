//! Tile addressing: XYZ tile ids ↔ normalised web-mercator world space, and
//! the Hilbert tile ids PMTiles archives key their directories by.
//!
//! "World" space is web-mercator normalised to the unit square [0,1]² with y
//! DOWN: (0,0) is lon −180 at the north clamp, (1,1) is lon +180 at the south
//! clamp (±85.05112878°, where the square ends). Tile (z,x,y) covers the
//! square of side 2⁻ᶻ whose north-west corner is (x·2⁻ᶻ, y·2⁻ᶻ) — the same
//! addressing MVT tiles and the camera use, so a tile→clip matrix is a
//! scale+translate of this rect.
//!
//! Ported from tile57 (src/tiles/tile.zig lonLatToWorld and the tile-bounds
//! math; src/tiles/pmtiles.zig zxyToTileId). The baker-side projection,
//! clipping and simplification stayed behind: charttable consumes tiles, it
//! does not cut them.

const std = @import("std");

/// Highest zoom this addressing supports: x/y fit u32 and the Hilbert id
/// fits u64 up to here. Real pyramids stop far below (PMTiles caps at 27).
pub const MAX_ZOOM: u8 = 31;

pub const WorldRect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

pub const TileId = struct {
    z: u8,
    x: u32,
    y: u32,

    /// The world-space square this tile covers: side 2⁻ᶻ, NW corner at
    /// (x,y)·2⁻ᶻ. (x1,y1) is the far edge — the next tile's (x0,y0), so
    /// adjacent rects share edges exactly (the corner values are the same
    /// float expression on both sides, no seam).
    pub fn worldRect(t: TileId) WorldRect {
        std.debug.assert(t.z <= MAX_ZOOM);
        const inv = 1.0 / @as(f64, @floatFromInt(@as(u64, 1) << @intCast(t.z)));
        const x0 = @as(f64, @floatFromInt(t.x)) * inv;
        const y0 = @as(f64, @floatFromInt(t.y)) * inv;
        return .{ .x0 = x0, .y0 = y0, .x1 = x0 + inv, .y1 = y0 + inv };
    }

    /// The tile one zoom up containing this one; null at the root.
    pub fn parent(t: TileId) ?TileId {
        if (t.z == 0) return null;
        return .{ .z = t.z - 1, .x = t.x >> 1, .y = t.y >> 1 };
    }

    /// One of the four children a zoom down; (dx,dy) picks the quadrant
    /// (0,0 = NW … 1,1 = SE).
    pub fn child(t: TileId, dx: u1, dy: u1) TileId {
        return .{ .z = t.z + 1, .x = (t.x << 1) | dx, .y = (t.y << 1) | dy };
    }

    /// Whether `o` is `t` itself or lies in t's subtree — the overzoom
    /// question ("does resident tile t cover wanted tile o?").
    pub fn contains(t: TileId, o: TileId) bool {
        if (o.z < t.z) return false;
        const dz: u6 = @intCast(@min(@as(u32, o.z) - t.z, 63));
        return (@as(u64, o.x) >> dz) == t.x and (@as(u64, o.y) >> dz) == t.y;
    }

    /// This tile's Hilbert tile id (PMTiles directory addressing).
    pub fn hilbertId(t: TileId) u64 {
        return zxyToTileId(t.z, t.x, t.y);
    }
};

/// The tile containing world point `w` at zoom `z`. Out-of-square points
/// clamp into the edge tiles (w = 1.0 is the far edge of the last tile, not
/// one past it), so any camera point yields a valid tile.
pub fn fromWorld(w: [2]f64, z: u8) TileId {
    std.debug.assert(z <= MAX_ZOOM);
    const n = @as(u64, 1) << @intCast(z);
    const nf: f64 = @floatFromInt(n);
    const last: f64 = @floatFromInt(n - 1);
    const fx = std.math.clamp(@floor(w[0] * nf), 0, last);
    const fy = std.math.clamp(@floor(w[1] * nf), 0, last);
    return .{ .z = z, .x = @intFromFloat(fx), .y = @intFromFloat(fy) };
}

/// Normalised web-mercator: lon/lat (deg) → (x,y) in [0,1], y down.
/// Latitude clamps to ±85.05112878° (the square's edge).
pub fn lonLatToWorld(lon: f64, lat: f64) [2]f64 {
    const wx = (lon + 180.0) / 360.0;
    const clamped = std.math.clamp(lat, -85.05112878, 85.05112878);
    const rad = clamped * std.math.pi / 180.0;
    const wy = (1.0 - std.math.log(f64, std.math.e, std.math.tan(rad) + 1.0 / std.math.cos(rad)) / std.math.pi) / 2.0;
    return .{ wx, wy };
}

/// Inverse of `lonLatToWorld`. Values outside [0,1] extrapolate.
pub fn worldToLonLat(w: [2]f64) [2]f64 {
    const lon = w[0] * 360.0 - 180.0;
    const lat = std.math.atan(std.math.sinh(std.math.pi * (1.0 - 2.0 * w[1]))) * 180.0 / std.math.pi;
    return .{ lon, lat };
}

/// (z,x,y) → 64-bit Hilbert tile id (PMTiles addressing): tiles of all zooms
/// share one id space, zoom z starting at Σ 4ⁱ for i<z, ordered along the
/// Hilbert curve within the zoom.
pub fn zxyToTileId(z: u8, x_in: u32, y_in: u32) u64 {
    std.debug.assert(z <= MAX_ZOOM);
    var acc: u64 = 0;
    var t: u6 = 0;
    while (t < z) : (t += 1) {
        acc += (@as(u64, 1) << t) * (@as(u64, 1) << t);
    }
    var x: u64 = x_in;
    var y: u64 = y_in;
    var d: u64 = 0;
    var s: u64 = @as(u64, 1) << @intCast(z);
    s /= 2;
    while (s > 0) : (s /= 2) {
        const rx: u64 = if ((x & s) > 0) 1 else 0;
        const ry: u64 = if ((y & s) > 0) 1 else 0;
        d += s * s * ((3 * rx) ^ ry);
        // rotate (wrapping subtraction matches the PMTiles Go reference, which
        // relies on uint64 wraparound when rx==1 and x >= s).
        if (ry == 0) {
            if (rx == 1) {
                x = s -% 1 -% x;
                y = s -% 1 -% y;
            }
            const tmp = x;
            x = y;
            y = tmp;
        }
    }
    return acc + d;
}

// ---- tests -----------------------------------------------------------------

test "hilbert tile id matches PMTiles reference values" {
    // From the spec's zxy<->tileid table (same pins as tile57's pmtiles tests).
    try std.testing.expectEqual(@as(u64, 0), zxyToTileId(0, 0, 0));
    try std.testing.expectEqual(@as(u64, 1), zxyToTileId(1, 0, 0));
    try std.testing.expectEqual(@as(u64, 2), zxyToTileId(1, 0, 1));
    try std.testing.expectEqual(@as(u64, 3), zxyToTileId(1, 1, 1));
    try std.testing.expectEqual(@as(u64, 4), zxyToTileId(1, 1, 0));
    try std.testing.expectEqual(@as(u64, 5), zxyToTileId(2, 0, 0));
    // Method and free function agree.
    const t = TileId{ .z = 12, .x = 3423, .y = 1763 };
    try std.testing.expectEqual(zxyToTileId(12, 3423, 1763), t.hilbertId());
}

test "worldRect: root is the unit square, children tile their parent exactly" {
    const t = std.testing;
    const root = TileId{ .z = 0, .x = 0, .y = 0 };
    const r = root.worldRect();
    try t.expectEqual(@as(f64, 0), r.x0);
    try t.expectEqual(@as(f64, 0), r.y0);
    try t.expectEqual(@as(f64, 1), r.x1);
    try t.expectEqual(@as(f64, 1), r.y1);

    // The four children partition the parent: shared edges are the same value.
    const nw = root.child(0, 0).worldRect();
    const se = root.child(1, 1).worldRect();
    try t.expectEqual(@as(f64, 0.5), nw.x1);
    try t.expectEqual(@as(f64, 0.5), se.x0);
    try t.expectEqual(nw.y1, se.y0);

    // A deep tile's rect has side 2^-z and sits at (x,y)*2^-z.
    const deep = TileId{ .z = 14, .x = 4711, .y = 6262 };
    const dr = deep.worldRect();
    const side = 1.0 / 16384.0;
    try t.expectApproxEqAbs(side, dr.x1 - dr.x0, 1e-15);
    try t.expectApproxEqAbs(4711.0 * side, dr.x0, 1e-15);
}

test "parent/child round-trip; contains covers the overzoom question" {
    const t = std.testing;
    const base = TileId{ .z = 5, .x = 9, .y = 21 };
    inline for (.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |q| {
        const c = base.child(q[0], q[1]);
        try t.expectEqual(base, c.parent().?);
        try t.expect(base.contains(c));
        try t.expect(base.contains(c.child(1, 0))); // grandchild
        try t.expect(!c.contains(base)); // never upward
    }
    try t.expect((TileId{ .z = 0, .x = 0, .y = 0 }).parent() == null);
    try t.expect(base.contains(base)); // a tile covers itself
    const sibling = TileId{ .z = 5, .x = 10, .y = 21 };
    try t.expect(!base.contains(sibling));
    try t.expect(!base.contains(sibling.child(0, 0)));
}

test "fromWorld: rect centers map back, edges clamp into the square" {
    const t = std.testing;
    const tile = TileId{ .z = 7, .x = 100, .y = 3 };
    const r = tile.worldRect();
    const center = [2]f64{ (r.x0 + r.x1) / 2.0, (r.y0 + r.y1) / 2.0 };
    try t.expectEqual(tile, fromWorld(center, 7));
    // The world's far corner lands in the last tile, not one past it; negatives
    // clamp to tile 0.
    try t.expectEqual(TileId{ .z = 3, .x = 7, .y = 7 }, fromWorld(.{ 1.0, 1.0 }, 3));
    try t.expectEqual(TileId{ .z = 3, .x = 0, .y = 0 }, fromWorld(.{ -0.1, 0.0 }, 3));
    try t.expectEqual(TileId{ .z = 0, .x = 0, .y = 0 }, fromWorld(.{ 0.99, 0.5 }, 0));
}

test "Annapolis lands in the expected z14 tile (tile57 parity pin)" {
    // Annapolis harbour; the reference tile used across tile57 is z14/4711/6262.
    const w = lonLatToWorld(-76.482, 38.978);
    try std.testing.expectEqual(TileId{ .z = 14, .x = 4711, .y = 6262 }, fromWorld(w, 14));
}

test "lonLat <-> world round-trips inside the mercator clamp" {
    const t = std.testing;
    const samples = [_][2]f64{
        .{ 0, 0 }, .{ -76.482, 38.978 }, .{ 179.9, -84.9 }, .{ -179.9, 84.9 }, .{ 13.4, 52.5 },
    };
    for (samples) |s| {
        const back = worldToLonLat(lonLatToWorld(s[0], s[1]));
        try t.expectApproxEqAbs(s[0], back[0], 1e-9);
        try t.expectApproxEqAbs(s[1], back[1], 1e-9);
    }
    // Latitude beyond the clamp pins to the square's edge (y = 0 or 1).
    try t.expectApproxEqAbs(@as(f64, 0), lonLatToWorld(0, 90)[1], 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1), lonLatToWorld(0, -90)[1], 1e-9);
}

//! Polygon triangulation for fill layers: one decoded MVT polygon feature's
//! parts in, an indexed triangle mesh in the scene Vertex stream out.
//!
//! Provenance: the drive shape is tile57's (render/gpu.zig emitFill — rings
//! in, Vertex + u32 indices appended to caller lists, ox/oy zero, all screen
//! behavior in the per-tile matrix), but the kernel is NOT tile57's vendored
//! libtess2 (render/tess.zig): charttable triangulates in pure Zig so it
//! carries no C dependency and no new license entry. The ear clipper grew
//! from lookout overlay.zig earClip (the convex-corner ear test, the
//! strictly-inside point-in-triangle that lets self-touching rings clip, the
//! fan fallback that keeps degenerate input from crashing or looping),
//! extended with hole elimination — the classic max-x vertex / +x ray cast /
//! reflex-vertex refinement bridge, written from the published construction —
//! because a map fill has holes and lookout's canvas fills did not.
//!
//! Contract:
//! - Input is `Feature.parts` from source/mvt.zig: i32 tile coordinates
//!   (y down), rings OPEN, each exterior followed by its holes, winding per
//!   the MVT spec (ringArea2 > 0 exterior, < 0 hole). Grouping by that sign
//!   is the spec's nonzero classification for valid input — the same rule
//!   tile57 fed libtess2 for area fills.
//! - Output positions are tile-local world units: tile_span * coord / extent.
//!   The 64-unit buffer overhang stays in the geometry — clipping is the
//!   renderer's job (per-tile clip rects), never layout's.
//! - Fill vertices carry no screen offset: ox/oy zero, flags 0. Zoom window
//!   and paint-order depth pass through Options.
//! - Degenerate rings (< 3 distinct points, zero area) draw nothing and are
//!   not an error — buffered clipping produces them legitimately (tile57's
//!   tess wrapper made the same call). Self-TOUCHING rings (repeated
//!   vertices, pinch points) triangulate exactly; a self-CROSSING ring is
//!   not resolved (there is no sweep here) — it degrades to a best-effort
//!   fill and never crashes, the earcut-class trade every tessellated map
//!   renderer makes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../scene/types.zig");
const mvt = @import("../source/mvt.zig");

pub const Options = struct {
    /// Per-vertex zoom visibility window (scene/types.zig).
    zmin: u16 = types.ZMIN_ALL,
    zmax: u16 = types.ZMAX_ALL,
    /// Paint-order depth in (0,1): later paint = smaller. 0 always passes.
    depth: f32 = 0,
};

const Pt = struct { x: f64, y: f64 };

/// Triangulate one polygon feature's parts into `verts` + `indices`.
/// Exteriors (ringArea2 > 0) each start a polygon; the holes that follow cut
/// into it. Rings with no exterior to cut from, and degenerate rings, draw
/// nothing. Indices are absolute into `verts` (offset by the list length at
/// call time), so many features append into one bucket.
pub fn layoutPolygon(
    gpa: Allocator,
    parts: []const []const mvt.Point,
    extent: u32,
    tile_span: f64,
    opts: Options,
    verts: *std.ArrayList(types.Vertex),
    indices: *std.ArrayList(u32),
) Allocator.Error!void {
    if (extent == 0) return; // hostile tile: nothing sane to scale by
    var i: usize = 0;
    while (i < parts.len) {
        if (mvt.ringArea2(parts[i]) <= 0) {
            i += 1; // a hole before any exterior, or a zero-area ring
            continue;
        }
        // One exterior plus everything up to the next exterior. Zero-area
        // rings inside the span are swallowed here and dropped in dedupRing.
        var j = i + 1;
        while (j < parts.len and mvt.ringArea2(parts[j]) <= 0) : (j += 1) {}
        try triangulateGroup(gpa, parts[i..j], extent, tile_span, opts, verts, indices);
        i = j;
    }
}

/// One exterior + its holes: dedup, bridge every hole into the outer ring,
/// ear-clip the combined weakly-simple polygon, emit.
fn triangulateGroup(
    gpa: Allocator,
    rings: []const []const mvt.Point,
    extent: u32,
    tile_span: f64,
    opts: Options,
    verts: *std.ArrayList(types.Vertex),
    indices: *std.ArrayList(u32),
) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Geometry stays in raw tile coordinates (exact in f64 — coords are i32,
    // cross products stay far under 2^53) until vertex emission scales once.
    var flat = std.ArrayList(Pt).empty;

    const outer = (try dedupRing(a, rings[0], &flat)) orelse return;

    // Holes: dedup, then find each one's max-x vertex — the bridge always
    // leaves from the rightmost point, so nothing of the hole itself can
    // block the +x sight line.
    const Hole = struct { idx: []const u32, m: usize, mx: f64 };
    var holes = std.ArrayList(Hole).empty;
    for (rings[1..]) |ring| {
        const h = (try dedupRing(a, ring, &flat)) orelse continue;
        var m: usize = 0;
        for (h, 0..) |vi, k| {
            const p = flat.items[vi];
            const q = flat.items[h[m]];
            if (p.x > q.x or (p.x == q.x and p.y > q.y)) m = k;
        }
        try holes.append(a, .{ .idx = h, .m = m, .mx = flat.items[h[m]].x });
    }
    // Rightmost hole first: every hole that could sit between a later hole
    // and the outer boundary along +x is already part of the polygon when
    // that later hole casts its ray.
    std.mem.sort(Hole, holes.items, {}, struct {
        fn lt(_: void, x: Hole, y: Hole) bool {
            return x.mx > y.mx;
        }
    }.lt);

    var poly = std.ArrayList(u32).empty;
    try poly.appendSlice(a, outer);
    for (holes.items) |h| try bridgeHole(a, flat.items, &poly, h.idx, h.m);

    // Emit each surviving input point exactly once; triangles index into
    // them, so bridge duplicates in the traversal cost nothing in the buffer.
    const base: u32 = @intCast(verts.items.len);
    const scale = tile_span / @as(f64, @floatFromInt(extent));
    try verts.ensureUnusedCapacity(gpa, flat.items.len);
    for (flat.items) |p| verts.appendAssumeCapacity(.{
        .x = @floatCast(p.x * scale),
        .y = @floatCast(p.y * scale),
        .ox = 0,
        .oy = 0,
        .zmin = opts.zmin,
        .zmax = opts.zmax,
        .flags = 0,
        .depth = opts.depth,
    });

    try earClipEmit(gpa, a, flat.items, poly.items, base, indices);
}

/// Append `ring`'s distinct points to `flat` and return their indices, or
/// null (with `flat` rolled back) when the ring is degenerate: consecutive
/// repeats and a closing repeat of the first point are dropped, then fewer
/// than 3 points or zero signed area means nothing to fill.
fn dedupRing(a: Allocator, ring: []const mvt.Point, flat: *std.ArrayList(Pt)) Allocator.Error!?[]const u32 {
    const start = flat.items.len;
    var idx = std.ArrayList(u32).empty;
    for (ring) |ip| {
        const p = Pt{ .x = @floatFromInt(ip.x), .y = @floatFromInt(ip.y) };
        if (flat.items.len > start) {
            const prev = flat.items[flat.items.len - 1];
            if (prev.x == p.x and prev.y == p.y) continue;
        }
        try idx.append(a, @intCast(flat.items.len));
        try flat.append(a, p);
    }
    if (idx.items.len >= 2) {
        const f = flat.items[idx.items[0]];
        const l = flat.items[idx.items[idx.items.len - 1]];
        if (f.x == l.x and f.y == l.y) {
            _ = idx.pop();
            _ = flat.pop();
        }
    }
    if (idx.items.len < 3 or ringAreaF(flat.items, idx.items) == 0) {
        flat.shrinkRetainingCapacity(start);
        return null;
    }
    return idx.items;
}

/// Twice the signed area over an index list (same convention as
/// mvt.ringArea2: positive = MVT exterior winding, y down).
fn ringAreaF(flat: []const Pt, idx: []const u32) f64 {
    var acc: f64 = 0;
    var j = idx.len - 1;
    for (idx, 0..) |vi, i| {
        const p = flat[vi];
        const q = flat[idx[j]];
        acc += q.x * p.y - p.x * q.y;
        j = i;
    }
    return acc;
}

fn cross2(a: Pt, b: Pt, c: Pt) f64 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

/// Strictly inside test that tolerates either winding (used on the bridge
/// triangle, whose orientation depends on where I landed). Boundary points
/// count as outside.
fn inTriEitherWinding(p: Pt, a: Pt, b: Pt, c: Pt) bool {
    const d1 = cross2(a, b, p);
    const d2 = cross2(b, c, p);
    const d3 = cross2(c, a, p);
    return (d1 > 0 and d2 > 0 and d3 > 0) or (d1 < 0 and d2 < 0 and d3 < 0);
}

/// Splice `hole` into `poly` through a mutually visible vertex pair: M is
/// the hole's max-x vertex (position `m_pos`), P the polygon vertex found by
/// the ray-cast construction. The traversal becomes
/// … P, M, (hole onward from M), M, P, … — two coincident bridge edges the
/// ear clipper treats as a zero-width channel. The hole keeps its stored
/// order: MVT winds holes opposite to exteriors, which is exactly what the
/// combined polygon needs.
fn bridgeHole(
    a: Allocator,
    flat: []const Pt,
    poly: *std.ArrayList(u32),
    hole: []const u32,
    m_pos: usize,
) Allocator.Error!void {
    const items = poly.items;
    const n = items.len;
    const M = flat[hole[m_pos]];

    // Closest intersection of the +x ray from M with a polygon edge. The
    // half-open straddle test counts a vertex on the ray exactly once and
    // skips edges collinear with it.
    var best_x = std.math.inf(f64);
    var best_edge: ?usize = null;
    for (items, 0..) |vi, e| {
        const p0 = flat[vi];
        const p1 = flat[items[(e + 1) % n]];
        if ((p0.y <= M.y) == (p1.y <= M.y)) continue;
        const x = p0.x + (M.y - p0.y) * (p1.x - p0.x) / (p1.y - p0.y);
        if (x >= M.x and x < best_x) {
            best_x = x;
            best_edge = e;
        }
    }

    var cand: usize = undefined;
    if (best_edge) |e| {
        // P starts as the intersected edge's endpoint on the far side of I.
        const e1 = (e + 1) % n;
        cand = if (flat[items[e]].x > flat[items[e1]].x) e else e1;
        // Refinement: a reflex vertex strictly inside triangle (M, I, P)
        // blocks the sight line M–P; among the blockers, the one at the
        // smallest angle off the ray (ties: nearest) is guaranteed visible.
        const I = Pt{ .x = best_x, .y = M.y };
        const P = flat[items[cand]];
        var best_cos: f64 = -2;
        var best_d2 = std.math.inf(f64);
        for (items, 0..) |vi, j| {
            if (j == cand) continue;
            const q = flat[vi];
            if (q.x < M.x) continue;
            // Convex corners cannot block (exterior winding is positive).
            const qp = flat[items[(j + n - 1) % n]];
            const qn = flat[items[(j + 1) % n]];
            if (cross2(qp, q, qn) >= 0) continue;
            if (!inTriEitherWinding(q, M, I, P)) continue;
            const dx = q.x - M.x;
            const dy = q.y - M.y;
            const d2 = dx * dx + dy * dy;
            // cos of the angle to the +x ray; a coincident point (d2 == 0)
            // is a zero-length bridge — the best possible.
            const c = if (d2 > 0) dx / @sqrt(d2) else 2.0;
            if (c > best_cos or (c == best_cos and d2 < best_d2)) {
                best_cos = c;
                best_d2 = d2;
                cand = j;
            }
        }
    } else {
        // No intersection: the hole is not inside the polygon (malformed
        // input). Bridge to the nearest vertex — possibly wrong, never a
        // crash, and only for what was already invalid.
        var best_d2 = std.math.inf(f64);
        cand = 0;
        for (items, 0..) |vi, j| {
            const q = flat[vi];
            const dx = q.x - M.x;
            const dy = q.y - M.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                cand = j;
            }
        }
    }

    var merged = std.ArrayList(u32).empty;
    try merged.ensureTotalCapacity(a, n + hole.len + 2);
    merged.appendSliceAssumeCapacity(items[0 .. cand + 1]);
    merged.appendSliceAssumeCapacity(hole[m_pos..]);
    merged.appendSliceAssumeCapacity(hole[0..m_pos]);
    merged.appendAssumeCapacity(hole[m_pos]);
    merged.appendAssumeCapacity(items[cand]);
    merged.appendSliceAssumeCapacity(items[cand + 1 ..]);
    poly.* = merged;
}

/// Ear-clip `poly_in` (positive winding) and append base-offset triangle
/// indices. Port of lookout overlay.zig earClip reshaped for indexed output:
/// the convex-corner test, the strictly-inside containment (coincident
/// bridge duplicates never block an ear), and the fan fallback when no ear
/// is found — wrong only for input that was already unfillable, and the
/// guarantee the loop terminates.
fn earClipEmit(
    gpa: Allocator,
    a: Allocator,
    flat: []const Pt,
    poly_in: []const u32,
    base: u32,
    indices: *std.ArrayList(u32),
) Allocator.Error!void {
    var idx = std.ArrayList(u32).empty;
    try idx.appendSlice(a, poly_in);
    var m = idx.items.len;
    if (m < 3) return;

    while (m > 3) {
        var clipped = false;
        var k: usize = 0;
        ear: while (k < m) : (k += 1) {
            const ia = idx.items[(k + m - 1) % m];
            const ib = idx.items[k];
            const ic = idx.items[(k + 1) % m];
            const pa = flat[ia];
            const pb = flat[ib];
            const pc = flat[ic];
            if (cross2(pa, pb, pc) <= 0) continue; // reflex or flat corner
            var j: usize = 0;
            while (j < m) : (j += 1) {
                const jv = idx.items[j];
                if (jv == ia or jv == ib or jv == ic) continue;
                const q = flat[jv];
                // Positive-wound ear: strictly inside is three positive
                // crosses. A bridge duplicate shares coordinates with a
                // corner and lands on the boundary — never a blocker.
                if (cross2(pa, pb, q) > 0 and cross2(pb, pc, q) > 0 and cross2(pc, pa, q) > 0)
                    continue :ear;
            }
            try indices.appendSlice(gpa, &.{ base + ia, base + ib, base + ic });
            _ = idx.orderedRemove(k);
            m -= 1;
            clipped = true;
            break;
        }
        if (!clipped) {
            // Numerically stuck: fan the remainder rather than loop or drop.
            var i: usize = 1;
            while (i + 1 < m) : (i += 1) {
                try indices.appendSlice(gpa, &.{
                    base + idx.items[0],
                    base + idx.items[i],
                    base + idx.items[i + 1],
                });
            }
            return;
        }
    }
    try indices.appendSlice(gpa, &.{ base + idx.items[0], base + idx.items[1], base + idx.items[2] });
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

/// Sum of unsigned triangle areas over the emitted mesh — must equal the
/// polygon's own area if the tessellation invented or lost nothing (the same
/// oracle tile57's tess wrapper tests used).
fn meshArea(verts: []const types.Vertex, indices: []const u32) f64 {
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const p0 = verts[indices[i]];
        const p1 = verts[indices[i + 1]];
        const p2 = verts[indices[i + 2]];
        const cr = (@as(f64, p1.x) - p0.x) * (@as(f64, p2.y) - p0.y) -
            (@as(f64, p1.y) - p0.y) * (@as(f64, p2.x) - p0.x);
        sum += @abs(cr) / 2;
    }
    return sum;
}

test "square with a square hole: exact triangle count, area conserved" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    // MVT winding (y down): exterior positive, hole negative — the same
    // fixture shape mvt.zig's decoder test pins.
    const outer = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const hole = [_]mvt.Point{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 }, .{ .x = 6, .y = 6 }, .{ .x = 6, .y = 2 } };
    try testing.expect(mvt.ringArea2(&outer) > 0);
    try testing.expect(mvt.ringArea2(&hole) < 0);

    // tile_span == extent → world units equal tile coords: areas read plain.
    const parts = [_][]const mvt.Point{ &outer, &hole };
    try layoutPolygon(testing.allocator, &parts, 4096, 4096.0, .{}, &verts, &indices);

    // 8 input points; the bridged 10-gon clips to exactly n-2 = 8 triangles.
    try testing.expectEqual(@as(usize, 8), verts.items.len);
    try testing.expectEqual(@as(usize, 8 * 3), indices.items.len);
    try testing.expectApproxEqAbs(@as(f64, 100 - 16), meshArea(verts.items, indices.items), 1e-9);

    for (indices.items) |ix| try testing.expect(ix < verts.items.len);
    for (verts.items) |v| {
        try testing.expectEqual(@as(f32, 0), v.ox);
        try testing.expectEqual(@as(f32, 0), v.oy);
        try testing.expectEqual(@as(u8, 0), v.flags);
        try testing.expectEqual(types.ZMIN_ALL, v.zmin);
        try testing.expectEqual(types.ZMAX_ALL, v.zmax);
    }
}

test "two holes: both bridge, area conserved" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    const outer = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const h1 = [_]mvt.Point{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 1 } };
    const h2 = [_]mvt.Point{ .{ .x = 6, .y = 6 }, .{ .x = 6, .y = 8 }, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 6 } };
    const parts = [_][]const mvt.Point{ &outer, &h1, &h2 };
    try layoutPolygon(testing.allocator, &parts, 4096, 4096.0, .{}, &verts, &indices);

    // 12 points; 4 + (4+2) + (4+2) = 16-gon → 14 triangles.
    try testing.expectEqual(@as(usize, 12), verts.items.len);
    try testing.expectEqual(@as(usize, 14 * 3), indices.items.len);
    try testing.expectApproxEqAbs(@as(f64, 100 - 4 - 4), meshArea(verts.items, indices.items), 1e-9);
}

test "multipolygon: each exterior triangulates independently" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    const sq1 = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    const sq2 = [_]mvt.Point{ .{ .x = 10, .y = 10 }, .{ .x = 14, .y = 10 }, .{ .x = 14, .y = 14 }, .{ .x = 10, .y = 14 } };
    const parts = [_][]const mvt.Point{ &sq1, &sq2 };
    try layoutPolygon(testing.allocator, &parts, 4096, 4096.0, .{}, &verts, &indices);

    try testing.expectEqual(@as(usize, 8), verts.items.len);
    try testing.expectEqual(@as(usize, 4 * 3), indices.items.len);
    try testing.expectApproxEqAbs(@as(f64, 32), meshArea(verts.items, indices.items), 1e-9);
}

test "concave comb conserves area" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    // Two slots cut down from the top edge (y down): plenty of reflex
    // corners for the ear scan to route around.
    const comb = [_]mvt.Point{
        .{ .x = 0, .y = 0 },  .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 },
        .{ .x = 8, .y = 10 }, .{ .x = 8, .y = 2 },  .{ .x = 6, .y = 2 },
        .{ .x = 6, .y = 10 }, .{ .x = 4, .y = 10 }, .{ .x = 4, .y = 2 },
        .{ .x = 2, .y = 2 },  .{ .x = 2, .y = 10 }, .{ .x = 0, .y = 10 },
    };
    const want = @as(f64, @floatFromInt(mvt.ringArea2(&comb))) / 2;
    try testing.expect(want > 0);
    const parts = [_][]const mvt.Point{&comb};
    try layoutPolygon(testing.allocator, &parts, 4096, 4096.0, .{}, &verts, &indices);
    try testing.expectEqual(@as(usize, (12 - 2) * 3), indices.items.len);
    try testing.expectApproxEqAbs(want, meshArea(verts.items, indices.items), 1e-9);
}

test "self-touching ring (pinch) triangulates exactly" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    // Two triangles meeting at (2,2): the ring visits the pinch point twice.
    const pinch = [_]mvt.Point{
        .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 2, .y = 2 },
        .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 }, .{ .x = 2, .y = 2 },
    };
    const want = @as(f64, @floatFromInt(mvt.ringArea2(&pinch))) / 2;
    const parts = [_][]const mvt.Point{&pinch};
    try layoutPolygon(testing.allocator, &parts, 4096, 4096.0, .{}, &verts, &indices);
    try testing.expectApproxEqAbs(want, meshArea(verts.items, indices.items), 1e-9);
}

test "degenerate input draws nothing and never crashes" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    const two = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 } };
    const sliver = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 0 } };
    // A crossing bowtie has zero SIGNED area — classified degenerate here,
    // where libtess2's sweep would resolve the lobes.
    const bowtie = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 10 } };
    const repeats = [_]mvt.Point{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 } };
    // A lone hole (negative winding) has no exterior to cut from.
    const lone_hole = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 }, .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 0 } };

    const parts = [_][]const mvt.Point{ &two, &sliver, &bowtie, &repeats, &lone_hole, &.{} };
    try layoutPolygon(testing.allocator, &parts, 4096, 4096.0, .{}, &verts, &indices);
    try testing.expectEqual(@as(usize, 0), verts.items.len);
    try testing.expectEqual(@as(usize, 0), indices.items.len);

    // A degenerate hole inside a valid exterior is dropped, the fill stays.
    const outer = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 8, .y = 8 }, .{ .x = 0, .y = 8 } };
    const parts2 = [_][]const mvt.Point{ &outer, &two };
    try layoutPolygon(testing.allocator, &parts2, 4096, 4096.0, .{}, &verts, &indices);
    try testing.expectApproxEqAbs(@as(f64, 64), meshArea(verts.items, indices.items), 1e-9);

    // extent 0 (hostile) is a no-op, not a division.
    try layoutPolygon(testing.allocator, &parts2, 0, 4096.0, .{}, &verts, &indices);
}

test "buffer overhang is kept, and positions scale to tile-local world units" {
    var verts = std.ArrayList(types.Vertex).empty;
    defer verts.deinit(testing.allocator);
    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(testing.allocator);

    // A ring reaching 64 units past every tile edge (the MVT buffer).
    const ring = [_]mvt.Point{ .{ .x = -64, .y = -64 }, .{ .x = 4160, .y = -64 }, .{ .x = 4160, .y = 4160 }, .{ .x = -64, .y = 4160 } };
    const span = 1.0 / 16384.0; // a z14 tile's world side
    const parts = [_][]const mvt.Point{&ring};
    try layoutPolygon(testing.allocator, &parts, 4096, span, .{ .zmin = 100, .zmax = 200, .depth = 0.5 }, &verts, &indices);

    const scale = span / 4096.0;
    var min_x: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    for (verts.items) |v| {
        min_x = @min(min_x, v.x);
        max_x = @max(max_x, v.x);
        try testing.expectEqual(@as(u16, 100), v.zmin);
        try testing.expectEqual(@as(u16, 200), v.zmax);
        try testing.expectEqual(@as(f32, 0.5), v.depth);
    }
    try testing.expectApproxEqAbs(@as(f32, @floatCast(-64.0 * scale)), min_x, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(4160.0 * scale)), max_x, 1e-12);
    try testing.expect(min_x < 0); // overhang survives: clipping is not layout's job
    try testing.expect(max_x > span);
}

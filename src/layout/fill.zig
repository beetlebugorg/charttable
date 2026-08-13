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
const earcut = @import("earcut.zig");

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

    // Geometry stays in raw tile coordinates (exact in f64 -- coords are i32,
    // cross products stay far under 2^53) until vertex emission scales once.
    // Flat x,y pairs, exteriors first, because that is what earcut takes.
    var coords = std.ArrayList(f64).empty;
    var hole_starts = std.ArrayList(u32).empty;

    var wrote_outer = false;
    for (rings, 0..) |ring, ri| {
        const before: u32 = @intCast(coords.items.len / 2);
        var count: usize = 0;
        var last: ?Pt = null;
        for (ring) |pt| {
            const p = Pt{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) };
            // Drop consecutive repeats and the closing repeat; earcut
            // handles them, but they cost nodes in every later scan.
            if (last) |q| if (q.x == p.x and q.y == p.y) continue;
            try coords.appendSlice(a, &.{ p.x, p.y });
            last = p;
            count += 1;
        }
        // A ring that closes back onto its first point.
        if (count >= 2) {
            const fx = coords.items[@as(usize, before) * 2];
            const fy = coords.items[@as(usize, before) * 2 + 1];
            const lx = coords.items[coords.items.len - 2];
            const ly = coords.items[coords.items.len - 1];
            if (fx == lx and fy == ly) {
                coords.items.len -= 2;
                count -= 1;
            }
        }
        if (count < 3) {
            coords.items.len = @as(usize, before) * 2; // roll back
            continue;
        }
        if (ri == 0) {
            wrote_outer = true;
        } else {
            try hole_starts.append(a, before);
        }
    }
    if (!wrote_outer or coords.items.len < 6) return;

    // Emit each surviving input point exactly once; triangles index into
    // them, so the bridge duplicates earcut makes cost nothing in the buffer.
    const base: u32 = @intCast(verts.items.len);
    const scale = tile_span / @as(f64, @floatFromInt(extent));
    const n_pts = coords.items.len / 2;
    try verts.ensureUnusedCapacity(gpa, n_pts);
    for (0..n_pts) |i| verts.appendAssumeCapacity(.{
        .x = @floatCast(coords.items[i * 2] * scale),
        .y = @floatCast(coords.items[i * 2 + 1] * scale),
        .ox = 0,
        .oy = 0,
        .zmin = opts.zmin,
        .zmax = opts.zmax,
        .flags = 0,
        .depth = opts.depth,
    });

    var tess = earcut.Tess.init(a);
    var tris: std.ArrayListUnmanaged(u32) = .empty;
    try tess.run(coords.items, hole_starts.items, &tris);
    try indices.ensureUnusedCapacity(gpa, tris.items.len);
    for (tris.items) |t| indices.appendAssumeCapacity(base + t);
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

/// Ear-clip `poly_in` (positive winding) and append base-offset triangle
/// indices. Port of lookout overlay.zig earClip reshaped for indexed output:
/// the convex-corner test, the strictly-inside containment (coincident
/// bridge duplicates never block an ear), and the fan fallback when no ear
/// is found — wrong only for input that was already unfillable, and the
/// guarantee the loop terminates.

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

test "real chart polygons: fill lands inside the polygon, not beside it" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pmtiles = @import("../source/pmtiles.zig");
    const mlt = @import("../source/mlt.zig");
    const coord = @import("../source/coord.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = testing.allocator;

    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    var reader = pmtiles.Reader.open(gpa, io, std.mem.span(chart_env)) catch return error.SkipZigTest;
    defer reader.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Comparing mesh area against the shoelace area is NOT the test: real
    // chart rings cross themselves, and there the two disagree by
    // definition -- shoelace cancels the overlap, a triangulation covers it.
    // What actually matters is whether the fill lands where the polygon is,
    // so sample points and ask both.
    const center = coord.fromWorld(coord.lonLatToWorld(-76.4767, 38.9763), 14);
    var checked: usize = 0;
    var leaky: usize = 0;
    var worst: f64 = 0;

    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const bytes = reader.getTile(
                a,
                14,
                @intCast(@as(i64, center.x) + dx),
                @intCast(@as(i64, center.y) + dy),
            ) catch continue orelse continue;
            const tile = mlt.decode(a, bytes) catch mvt.decode(a, bytes) catch continue;

            for (tile.layers) |tl| {
                for (tl.features) |f| {
                    if (f.geom_type != .polygon) continue;

                    var verts: std.ArrayList(types.Vertex) = .empty;
                    defer verts.deinit(gpa);
                    var indices: std.ArrayList(u32) = .empty;
                    defer indices.deinit(gpa);
                    try layoutPolygon(gpa, f.parts, tl.extent, 1.0, .{}, &verts, &indices);
                    if (indices.items.len == 0) continue;
                    checked += 1;

                    // Sample the mesh's own bounding box: anywhere the mesh
                    // covers, the polygon should too.
                    var lo_x: f32 = verts.items[0].x;
                    var lo_y: f32 = verts.items[0].y;
                    var hi_x = lo_x;
                    var hi_y = lo_y;
                    for (verts.items) |v| {
                        lo_x = @min(lo_x, v.x);
                        lo_y = @min(lo_y, v.y);
                        hi_x = @max(hi_x, v.x);
                        hi_y = @max(hi_y, v.y);
                    }

                    const N = 24;
                    var covered: usize = 0;
                    var outside: usize = 0;
                    var gy: usize = 0;
                    while (gy < N) : (gy += 1) {
                        var gx: usize = 0;
                        while (gx < N) : (gx += 1) {
                            const px = lo_x + (hi_x - lo_x) * (@as(f32, @floatFromInt(gx)) + 0.5) / N;
                            const py = lo_y + (hi_y - lo_y) * (@as(f32, @floatFromInt(gy)) + 0.5) / N;
                            if (!meshCovers(verts.items, indices.items, px, py)) continue;
                            covered += 1;
                            if (!ringsCover(f.parts, tl.extent, px, py)) outside += 1;
                        }
                    }
                    if (covered == 0) continue;
                    const leak = @as(f64, @floatFromInt(outside)) / @as(f64, @floatFromInt(covered));
                    if (leak > 0.02) {
                        leaky += 1;
                        worst = @max(worst, leak);
                        var neg: usize = 0;
                        var pts: usize = 0;
                        for (f.parts) |ring| {
                            if (mvt.ringArea2(ring) <= 0) neg += 1;
                            pts += ring.len;
                        }
                        if (leaky <= 4) std.debug.print(
                            "  leak {d:.0}%: {d} rings ({d} neg), {d} pts\n",
                            .{ leak * 100, f.parts.len, neg, pts },
                        );
                    }
                }
            }
        }
    }

    std.debug.print(
        "\nfill: {d} real polygons, {d} paint outside themselves (worst {d:.1}% of covered area)\n",
        .{ checked, leaky, worst * 100 },
    );
    try testing.expect(checked > 100); // the neighbourhood really has fills

    // A ceiling, not a target. Where a source ring crosses itself there is
    // no single right answer, and the last stragglers are those. This was 16
    // of 616 with the old ear clipper and is 1 with earcut's recovery
    // stages; the bound is here so it cannot quietly grow again.
    try testing.expect(leaky <= 3);
}

/// Is (x, y) under any triangle of the mesh?
fn meshCovers(verts: []const types.Vertex, indices: []const u32, x: f32, y: f32) bool {
    var i: usize = 0;
    while (i + 2 < indices.len) : (i += 3) {
        const a = verts[indices[i]];
        const b = verts[indices[i + 1]];
        const c = verts[indices[i + 2]];
        if (inTriEitherWinding(
            .{ .x = x, .y = y },
            .{ .x = a.x, .y = a.y },
            .{ .x = b.x, .y = b.y },
            .{ .x = c.x, .y = c.y },
        )) return true;
    }
    return false;
}

/// Is (x, y) inside the source rings?
///
/// By the NON-ZERO winding rule, which is what the vector-tile spec says
/// fills use: exteriors wind one way, holes the other, and a ring that
/// overlaps itself still covers the overlap. Even-odd would call that
/// overlap a hole and report a correct triangulation as leaking.
fn ringsCover(parts: []const []const mvt.Point, extent: u32, x: f32, y: f32) bool {
    const scale = 1.0 / @as(f64, @floatFromInt(extent));
    var winding: i32 = 0;
    for (parts) |ring| {
        if (ring.len < 3) continue;
        var j: usize = ring.len - 1;
        for (ring, 0..) |pt, k| {
            const y1 = @as(f64, @floatFromInt(ring[j].y)) * scale;
            const y2 = @as(f64, @floatFromInt(pt.y)) * scale;
            const x1 = @as(f64, @floatFromInt(ring[j].x)) * scale;
            const x2 = @as(f64, @floatFromInt(pt.x)) * scale;
            if (y1 <= y) {
                if (y2 > y and (x2 - x1) * (@as(f64, y) - y1) - (@as(f64, x) - x1) * (y2 - y1) > 0)
                    winding += 1;
            } else {
                if (y2 <= y and (x2 - x1) * (@as(f64, y) - y1) - (@as(f64, x) - x1) * (y2 - y1) < 0)
                    winding -= 1;
            }
            j = k;
        }
    }
    return winding != 0;
}

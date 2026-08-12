//! Geometry support for the `within` and `distance` operators: GeoJSON
//! extraction from expression values, containment tests in lon/lat with
//! antimeridian normalization, and metric distance under a local ruler.
//!
//! Containment semantics per the spec and its fixtures: a point ON the
//! boundary is NOT within; a line is within only if every vertex is inside
//! and no segment crosses a ring; longitudes compare modulo 360 (a polygon
//! drawn at -185..-175 contains a point at 181).

const std = @import("std");
const vals = @import("value.zig");
const Value = vals.Value;

pub const Point = [2]f64; // lon, lat

/// One polygon: exterior ring first, then holes. Rings are closed or open;
/// the tests treat first==last transparently.
pub const Polygon = struct {
    rings: []const []const Point,
};

pub const Error = error{ Malformed, OutOfMemory };

fn valueToPoint(v: Value) Error!Point {
    const items = switch (v) {
        .array => |items| items,
        else => return error.Malformed,
    };
    if (items.len < 2) return error.Malformed;
    const x = switch (items[0]) {
        .number => |n| n,
        else => return error.Malformed,
    };
    const y = switch (items[1]) {
        .number => |n| n,
        else => return error.Malformed,
    };
    return .{ x, y };
}

fn valueToRing(a: std.mem.Allocator, v: Value) Error![]Point {
    const items = switch (v) {
        .array => |items| items,
        else => return error.Malformed,
    };
    const ring = try a.alloc(Point, items.len);
    for (items, 0..) |it, i| ring[i] = try valueToPoint(it);
    return ring;
}

fn objGet(entries: []const Value.Entry, key: []const u8) ?Value {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

/// Extract every polygon from a GeoJSON value: Polygon, MultiPolygon,
/// Feature, FeatureCollection, GeometryCollection.
pub fn valueToPolygons(a: std.mem.Allocator, v: Value, out: *std.ArrayList(Polygon)) Error!void {
    const entries = switch (v) {
        .object => |entries| entries,
        else => return error.Malformed,
    };
    const t = objGet(entries, "type") orelse return error.Malformed;
    const type_name = switch (t) {
        .string => |s| s,
        else => return error.Malformed,
    };
    if (std.mem.eql(u8, type_name, "Feature")) {
        const g = objGet(entries, "geometry") orelse return error.Malformed;
        return valueToPolygons(a, g, out);
    }
    if (std.mem.eql(u8, type_name, "FeatureCollection")) {
        const fs = objGet(entries, "features") orelse return error.Malformed;
        const items = switch (fs) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (items) |f| try valueToPolygons(a, f, out);
        return;
    }
    if (std.mem.eql(u8, type_name, "GeometryCollection")) {
        const gs = objGet(entries, "geometries") orelse return error.Malformed;
        const items = switch (gs) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (items) |g| try valueToPolygons(a, g, out);
        return;
    }
    const coords = objGet(entries, "coordinates") orelse return error.Malformed;
    if (std.mem.eql(u8, type_name, "Polygon")) {
        const rings_v = switch (coords) {
            .array => |items| items,
            else => return error.Malformed,
        };
        const rings = try a.alloc([]const Point, rings_v.len);
        for (rings_v, 0..) |rv, i| rings[i] = try valueToRing(a, rv);
        try out.append(a, .{ .rings = rings });
        return;
    }
    if (std.mem.eql(u8, type_name, "MultiPolygon")) {
        const polys_v = switch (coords) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (polys_v) |pv| {
            const rings_v = switch (pv) {
                .array => |items| items,
                else => return error.Malformed,
            };
            const rings = try a.alloc([]const Point, rings_v.len);
            for (rings_v, 0..) |rv, i| rings[i] = try valueToRing(a, rv);
            try out.append(a, .{ .rings = rings });
        }
        return;
    }
    return error.Malformed; // not an area geometry
}

/// Everything a GeoJSON value can carry, split by dimension: the target
/// set of the `distance` operator.
pub const Geoms = struct {
    points: []const Point = &.{},
    lines: []const []const Point = &.{},
    polygons: []const Polygon = &.{},

    pub fn isEmpty(g: Geoms) bool {
        return g.points.len == 0 and g.lines.len == 0 and g.polygons.len == 0;
    }
};

const GeomsBuilder = struct {
    points: std.ArrayList(Point) = .empty,
    lines: std.ArrayList([]const Point) = .empty,
    polygons: std.ArrayList(Polygon) = .empty,
};

/// Extract every geometry from a GeoJSON value: any geometry type, plus
/// Feature, FeatureCollection, and GeometryCollection wrappers.
pub fn valueToGeoms(a: std.mem.Allocator, v: Value) Error!Geoms {
    var b = GeomsBuilder{};
    try collectGeoms(a, v, &b);
    return .{ .points = b.points.items, .lines = b.lines.items, .polygons = b.polygons.items };
}

fn collectGeoms(a: std.mem.Allocator, v: Value, b: *GeomsBuilder) Error!void {
    const entries = switch (v) {
        .object => |entries| entries,
        else => return error.Malformed,
    };
    const t = objGet(entries, "type") orelse return error.Malformed;
    const type_name = switch (t) {
        .string => |s| s,
        else => return error.Malformed,
    };
    if (std.mem.eql(u8, type_name, "Feature")) {
        const g = objGet(entries, "geometry") orelse return error.Malformed;
        return collectGeoms(a, g, b);
    }
    if (std.mem.eql(u8, type_name, "FeatureCollection")) {
        const fs = objGet(entries, "features") orelse return error.Malformed;
        const items = switch (fs) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (items) |f| try collectGeoms(a, f, b);
        return;
    }
    if (std.mem.eql(u8, type_name, "GeometryCollection")) {
        const gs = objGet(entries, "geometries") orelse return error.Malformed;
        const items = switch (gs) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (items) |g| try collectGeoms(a, g, b);
        return;
    }
    const coords = objGet(entries, "coordinates") orelse return error.Malformed;
    if (std.mem.eql(u8, type_name, "Point")) {
        try b.points.append(a, try valueToPoint(coords));
        return;
    }
    if (std.mem.eql(u8, type_name, "MultiPoint")) {
        const items = switch (coords) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (items) |it| try b.points.append(a, try valueToPoint(it));
        return;
    }
    if (std.mem.eql(u8, type_name, "LineString")) {
        try b.lines.append(a, try valueToRing(a, coords));
        return;
    }
    if (std.mem.eql(u8, type_name, "MultiLineString")) {
        const items = switch (coords) {
            .array => |items| items,
            else => return error.Malformed,
        };
        for (items) |it| try b.lines.append(a, try valueToRing(a, it));
        return;
    }
    if (std.mem.eql(u8, type_name, "Polygon") or std.mem.eql(u8, type_name, "MultiPolygon")) {
        var polys: std.ArrayList(Polygon) = .empty;
        try valueToPolygons(a, v, &polys);
        for (polys.items) |p| try b.polygons.append(a, p);
        return;
    }
    return error.Malformed;
}

fn lonSpan(polys: []const Polygon) [2]f64 {
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (polys) |p| {
        for (p.rings) |r| {
            for (r) |pt| {
                lo = @min(lo, pt[0]);
                hi = @max(hi, pt[0]);
            }
        }
    }
    return .{ lo, hi };
}

/// Longitude shift (0, +360, -360) bringing `lon` nearest the polygons'
/// span — the antimeridian rule.
fn lonShift(lon: f64, span: [2]f64) f64 {
    const mid = (span[0] + span[1]) * 0.5;
    var best: f64 = 0;
    var best_d = @abs(lon - mid);
    for ([_]f64{ 360, -360 }) |s| {
        const d = @abs(lon + s - mid);
        if (d < best_d) {
            best_d = d;
            best = s;
        }
    }
    return best;
}

fn onSegment(p: Point, q1: Point, q2: Point) bool {
    const cross = (q2[0] - q1[0]) * (p[1] - q1[1]) - (q2[1] - q1[1]) * (p[0] - q1[0]);
    if (@abs(cross) > 1e-12) return false;
    return p[0] >= @min(q1[0], q2[0]) - 1e-12 and p[0] <= @max(q1[0], q2[0]) + 1e-12 and
        p[1] >= @min(q1[1], q2[1]) - 1e-12 and p[1] <= @max(q1[1], q2[1]) + 1e-12;
}

/// Strictly-inside test (boundary is false), even-odd over all rings.
fn pointInPolygon(p: Point, poly: Polygon) bool {
    var inside = false;
    for (poly.rings) |ring| {
        if (ring.len < 3) continue;
        var i: usize = 0;
        var j: usize = ring.len - 1;
        while (i < ring.len) : (i += 1) {
            const a = ring[i];
            const b = ring[j];
            if (onSegment(p, a, b)) return false; // boundary
            if ((a[1] > p[1]) != (b[1] > p[1])) {
                const x = (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0];
                if (p[0] < x) inside = !inside;
            }
            j = i;
        }
    }
    return inside;
}

fn orient(a: Point, b: Point, c: Point) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Proper segment intersection (shared endpoints/collinear touch do not
/// count as a crossing; the vertex-inside test covers those).
fn segmentsCross(p1: Point, p2: Point, q1: Point, q2: Point) bool {
    const d1 = orient(q1, q2, p1);
    const d2 = orient(q1, q2, p2);
    const d3 = orient(p1, p2, q1);
    const d4 = orient(p1, p2, q2);
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and
        ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

fn pointWithinAny(p: Point, polys: []const Polygon, span: [2]f64) bool {
    const shifted = Point{ p[0] + lonShift(p[0], span), p[1] };
    for (polys) |poly| {
        if (pointInPolygon(shifted, poly)) return true;
    }
    return false;
}

fn lineWithinAny(line: []const Point, polys: []const Polygon, span: [2]f64, scratch: []Point) bool {
    if (line.len == 0) return false;
    // One shift for the whole line, chosen by its first vertex.
    const s = lonShift(line[0][0], span);
    for (line, 0..) |pt, i| scratch[i] = .{ pt[0] + s, pt[1] };
    const sl = scratch[0..line.len];
    // Every vertex strictly inside ONE polygon, and no segment crosses any
    // of that polygon's rings.
    outer: for (polys) |poly| {
        for (sl) |pt| {
            if (!pointInPolygon(pt, poly)) continue :outer;
        }
        var i: usize = 0;
        while (i + 1 < sl.len) : (i += 1) {
            for (poly.rings) |ring| {
                var j: usize = 0;
                var k: usize = ring.len - 1;
                while (j < ring.len) : (j += 1) {
                    if (segmentsCross(sl[i], sl[i + 1], ring[j], ring[k])) continue :outer;
                    k = j;
                }
            }
        }
        return true;
    }
    return false;
}

/// The feature geometry the evaluator hands over: lon/lat parts.
pub const Geometry = struct {
    kind: enum { point, line, polygon },
    /// points: one part of N points; lines: one part per linestring.
    parts: []const []const Point,
};

/// The `within` decision for a feature geometry against GeoJSON polygons.
pub fn within(a: std.mem.Allocator, geom: Geometry, polys: []const Polygon) Error!bool {
    if (polys.len == 0) return false;
    const span = lonSpan(polys);
    switch (geom.kind) {
        .point => {
            for (geom.parts) |part| {
                for (part) |p| {
                    if (!pointWithinAny(p, polys, span)) return false;
                }
            }
            return true;
        },
        .line => {
            var max_len: usize = 0;
            for (geom.parts) |part| max_len = @max(max_len, part.len);
            const scratch = try a.alloc(Point, max_len);
            for (geom.parts) |part| {
                if (!lineWithinAny(part, polys, span, scratch)) return false;
            }
            return true;
        },
        .polygon => return false, // unsupported feature type: never within
    }
}

// ---- ["distance"]: metric distance under a local ruler ----------------------
//
// Semantics derived from the spec fixtures (distance/*): the result is the
// minimum distance in METERS between the feature geometry and the argument
// geometry, computed as a planar distance in lon/lat degrees scaled by the
// WGS84 meters-per-degree factors at a reference latitude — the feature
// geometry's first vertex (the "cheap ruler" local approximation; fixture
// from-point/to-line-through-point-vertical pins the reference latitude to
// the feature side, and multi-point pins it to its first vertex). Touching
// or contained geometry is at distance zero, with polygon containment
// tested even-odd across rings (a point in a hole is outside) and the
// boundary counting as inside.

/// Meters per degree of longitude/latitude at a fixed latitude, from the
/// WGS84 normal/meridional radii of curvature.
const Ruler = struct {
    kx: f64,
    ky: f64,

    fn at(lat_deg: f64) Ruler {
        const re = 6378137.0; // WGS84 equatorial radius, meters
        const fe = 1.0 / 298.257223563; // WGS84 flattening
        const e2 = fe * (2.0 - fe);
        const m = re * std.math.pi / 180.0;
        const cl = @cos(lat_deg * std.math.pi / 180.0);
        const w2 = 1.0 / (1.0 - e2 * (1.0 - cl * cl));
        const w = @sqrt(w2);
        return .{ .kx = m * w * cl, .ky = m * w * w2 * (1.0 - e2) };
    }
};

fn dPP(r: Ruler, p: Point, q: Point) f64 {
    return std.math.hypot((p[0] - q[0]) * r.kx, (p[1] - q[1]) * r.ky);
}

fn dPSeg(r: Ruler, p: Point, a: Point, b: Point) f64 {
    const dx = (b[0] - a[0]) * r.kx;
    const dy = (b[1] - a[1]) * r.ky;
    const px = (p[0] - a[0]) * r.kx;
    const py = (p[1] - a[1]) * r.ky;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return std.math.hypot(px, py);
    const t = std.math.clamp((px * dx + py * dy) / len2, 0, 1);
    return std.math.hypot(px - t * dx, py - t * dy);
}

fn dSegSeg(r: Ruler, p1: Point, p2: Point, q1: Point, q2: Point) f64 {
    if (segmentsCross(p1, p2, q1, q2)) return 0;
    return @min(
        @min(dPSeg(r, p1, q1, q2), dPSeg(r, p2, q1, q2)),
        @min(dPSeg(r, q1, p1, p2), dPSeg(r, q2, p1, p2)),
    );
}

/// Point to polyline (a single point is a degenerate part).
fn dPtPart(r: Ruler, p: Point, part: []const Point) f64 {
    if (part.len == 0) return std.math.inf(f64);
    if (part.len == 1) return dPP(r, p, part[0]);
    var best = std.math.inf(f64);
    var i: usize = 0;
    while (i + 1 < part.len) : (i += 1) best = @min(best, dPSeg(r, p, part[i], part[i + 1]));
    return best;
}

/// Polyline to polyline, minimum over segment pairs (crossings are zero).
fn dPartPart(r: Ruler, pa: []const Point, pb: []const Point) f64 {
    if (pa.len == 0 or pb.len == 0) return std.math.inf(f64);
    if (pa.len == 1) return dPtPart(r, pa[0], pb);
    if (pb.len == 1) return dPtPart(r, pb[0], pa);
    var best = std.math.inf(f64);
    var i: usize = 0;
    while (i + 1 < pa.len) : (i += 1) {
        var j: usize = 0;
        while (j + 1 < pb.len) : (j += 1) {
            best = @min(best, dSegSeg(r, pa[i], pa[i + 1], pb[j], pb[j + 1]));
        }
    }
    return best;
}

/// Even-odd containment over all rings where a boundary point counts as
/// INSIDE (touching geometry is at distance zero — unlike `within`).
fn pointInPolygonInclusive(p: Point, poly: Polygon) bool {
    var inside = false;
    for (poly.rings) |ring| {
        if (ring.len < 3) continue;
        var i: usize = 0;
        var j: usize = ring.len - 1;
        while (i < ring.len) : (i += 1) {
            const a = ring[i];
            const b = ring[j];
            if (onSegment(p, a, b)) return true; // boundary touches
            if ((a[1] > p[1]) != (b[1] > p[1])) {
                const x = (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0];
                if (p[0] < x) inside = !inside;
            }
            j = i;
        }
    }
    return inside;
}

fn pointToTarget(r: Ruler, p: Point, target: Geoms) f64 {
    var best = std.math.inf(f64);
    for (target.points) |q| best = @min(best, dPP(r, p, q));
    for (target.lines) |line| best = @min(best, dPtPart(r, p, line));
    for (target.polygons) |poly| {
        if (pointInPolygonInclusive(p, poly)) return 0;
        for (poly.rings) |ring| best = @min(best, dPtPart(r, p, ring));
    }
    return best;
}

/// Line or polygon-ring parts against the target. `feat_rings` is set when
/// the parts are the rings of a feature POLYGON, enabling the reverse
/// containment test (target vertex inside the feature).
fn partsToTarget(r: Ruler, parts: []const []const Point, feat_rings: ?[]const []const Point, target: Geoms) f64 {
    var best = std.math.inf(f64);
    const feat_poly: ?Polygon = if (feat_rings) |rings| .{ .rings = rings } else null;

    for (target.points) |q| {
        if (feat_poly) |fp| {
            if (pointInPolygonInclusive(q, fp)) return 0;
        }
        for (parts) |part| best = @min(best, dPtPart(r, q, part));
    }
    for (target.lines) |line| {
        if (feat_poly) |fp| {
            for (line) |q| {
                if (pointInPolygonInclusive(q, fp)) return 0;
            }
        }
        for (parts) |part| best = @min(best, dPartPart(r, part, line));
    }
    for (target.polygons) |poly| {
        for (parts) |part| {
            for (part) |p| {
                if (pointInPolygonInclusive(p, poly)) return 0;
            }
        }
        if (feat_poly) |fp| {
            for (poly.rings) |ring| {
                for (ring) |q| {
                    if (pointInPolygonInclusive(q, fp)) return 0;
                }
            }
        }
        for (poly.rings) |ring| {
            for (parts) |part| best = @min(best, dPartPart(r, part, ring));
        }
    }
    return best;
}

/// The `distance` result in meters for a feature geometry against a
/// GeoJSON geometry set; null when either side carries no coordinates.
pub fn distance(feat: Geometry, target: Geoms) ?f64 {
    if (target.isEmpty()) return null;
    var first: ?Point = null;
    for (feat.parts) |part| {
        if (part.len > 0) {
            first = part[0];
            break;
        }
    }
    const anchor = first orelse return null;
    const r = Ruler.at(anchor[1]);
    var best = std.math.inf(f64);
    switch (feat.kind) {
        .point => for (feat.parts) |part| {
            for (part) |p| best = @min(best, pointToTarget(r, p, target));
        },
        .line => best = partsToTarget(r, feat.parts, null, target),
        .polygon => best = partsToTarget(r, feat.parts, feat.parts, target),
    }
    return if (best == std.math.inf(f64)) null else best;
}

// ---- tests -----------------------------------------------------------------

const t_ring = [_]Point{ .{ 0, 0 }, .{ 0, 5 }, .{ 5, 5 }, .{ 5, 0 }, .{ 0, 0 } };

test "point in polygon, boundary excluded" {
    const poly = Polygon{ .rings = &.{&t_ring} };
    try std.testing.expect(pointInPolygon(.{ 2, 2 }, poly));
    try std.testing.expect(!pointInPolygon(.{ 6, 6 }, poly));
    try std.testing.expect(!pointInPolygon(.{ 5, 5 }, poly)); // corner
    try std.testing.expect(!pointInPolygon(.{ 0, 2.5 }, poly)); // edge
}

test "hole excludes, even-odd" {
    const hole = [_]Point{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 2 }, .{ 2, 1 }, .{ 1, 1 } };
    const poly = Polygon{ .rings = &.{ &t_ring, &hole } };
    try std.testing.expect(!pointInPolygon(.{ 1.5, 1.5 }, poly));
    try std.testing.expect(pointInPolygon(.{ 3, 3 }, poly));
}

test "line containment needs no boundary crossing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const polys = [_]Polygon{.{ .rings = &.{&t_ring} }};
    const inside = [_]Point{ .{ 3, 3 }, .{ 4, 1 } };
    const exits = [_]Point{ .{ 3, 3 }, .{ 6, 6 } };
    const g1 = Geometry{ .kind = .line, .parts = &.{&inside} };
    const g2 = Geometry{ .kind = .line, .parts = &.{&exits} };
    try std.testing.expect(try within(arena.allocator(), g1, &polys));
    try std.testing.expect(!try within(arena.allocator(), g2, &polys));
}

test "antimeridian: 181 lon matches a -185..-175 polygon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ring = [_]Point{ .{ -185, 60 }, .{ -175, 60 }, .{ -175, 65 }, .{ -185, 65 }, .{ -185, 60 } };
    const polys = [_]Polygon{.{ .rings = &.{&ring} }};
    const pts = [_]Point{ .{ -183, 62 }, .{ 181, 63 } };
    const g = Geometry{ .kind = .point, .parts = &.{&pts} };
    try std.testing.expect(try within(arena.allocator(), g, &polys));
}

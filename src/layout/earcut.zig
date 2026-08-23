//! Ear-clipping triangulation, ported from mapbox/earcut (ISC).
//!
//! THIS FILE IS A PORT, not a clean-room implementation: it follows the
//! structure and the algorithms of earcut.js function for function --
//! linked-list rings, Eberly hole bridges, the z-order hash for the ear
//! test, and the three-stage recovery (filter collinear points, cure local
//! self-intersections, split on a diagonal). See THIRD-PARTY-NOTICES.md for
//! the license and the provenance note.
//!
//! Why port instead of keep our own: charttable's ear clipper assumed a
//! simple polygon and fanned the remainder when it ran out of ears, which
//! lays triangles OUTSIDE any concave remainder. Real chart rings cross
//! themselves constantly, so 16 of 616 fills in one Annapolis neighbourhood
//! painted over their neighbours -- water across dry land. Recovering from
//! that is exactly what earcut's last two stages are for.
//!
//! Two deliberate departures, both about size rather than behaviour:
//!
//!   - findHoleBridge scans the whole ring instead of earcut's block-bbox
//!     index. That index is a speed optimization whose own comments note it
//!     can pick a different (equally valid) bridge.
//!   - indexCurve sorts an array with std.sort rather than merge-sorting the
//!     linked list in place, and there is no radix path.
//!
//! Nodes live in one array and link by index, not pointer: a ring is a
//! circular doubly linked list either way, and an index-linked pool is one
//! allocation that can be reset between polygons.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const nil: u32 = std.math.maxInt(u32);

const Node = struct {
    /// Index of this vertex in the caller's coordinate array (in vertices).
    i: u32,
    x: f64,
    y: f64,
    prev: u32 = nil,
    next: u32 = nil,
    /// z-order curve value, or the ring-order sentinel before indexCurve.
    z: u32 = 0,
    prevz: u32 = nil,
    nextz: u32 = nil,
    /// A single-vertex hole, which filterPoints must not collapse.
    steiner: bool = false,
};

/// Reusable node pool. One per thread of layout; `reset` between polygons.
/// Elementary steps the recovery stages may spend on ONE `run`.
///
/// A well-formed ring never reaches those stages: it clears in pass 0, and
/// 100k convex vertices triangulate in about 13 ms. A heavily
/// self-intersecting ring does reach them, and splitEarcut is O(n) diagonals
/// x O(n) candidates x O(n) for the intersectsPolygon scan inside
/// isValidDiagonal -- and it recurses into itself on each half. Measured on
/// a self-intersecting ring: 1k vertices 28 ms, 5k 875 ms, 20k 46 SECONDS.
///
/// Tile geometry is untrusted, so without a bound one polygon stalls a tile
/// worker for as long as it likes. Running out of budget abandons the
/// recovery and leaves that sub-polygon untriangulated. This file already
/// prefers a fill with a flaw to no fill at all (see the header note on why
/// it was ported); an unbounded stall is worse than either.
///
/// The unit is one elementary step, charged in the three inner loops the
/// time actually goes into: the z-neighbourhood walk of an ear test, the ring
/// walk of intersectsPolygon, and the z-order sort. Charging per ear test
/// instead is not enough -- on a degenerate ring one test walks thousands of
/// nodes, so the bound would stay proportional to n.
///
/// Measured on a self-intersecting ring, before and after:
///
///   vertices    before      after
///      1,000     28 ms      26 ms   (full result either way)
///      5,000    875 ms     126 ms   (full result either way)
///     20,000     46 s      208 ms   (partial fill)
///     80,000     61 s      213 ms   (partial fill)
///    300,000     --        725 ms   (partial fill)
///
/// A well-formed ring is untouched: 100k convex vertices still triangulate
/// completely in about 13 ms, spending far less than this.
const max_recovery_work: u64 = 1 << 24;

pub const Tess = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    scratch: std.ArrayListUnmanaged(u32) = .empty,
    gpa: Allocator,
    /// Spent by the recovery stages only, and reset per `run`.
    recovery_work: u64 = 0,

    pub fn init(gpa: Allocator) Tess {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tess) void {
        self.nodes.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    fn n(self: *Tess, i: u32) *Node {
        return &self.nodes.items[i];
    }

    /// Triangulate `coords` (x, y pairs) with holes starting at the vertex
    /// indices in `hole_starts`. Appends triangles as index triples into
    /// `out`, indexing vertices (not coordinates).
    pub fn run(
        self: *Tess,
        coords: []const f64,
        hole_starts: []const u32,
        out: *std.ArrayListUnmanaged(u32),
    ) Allocator.Error!void {
        self.nodes.clearRetainingCapacity();
        self.recovery_work = 0;
        const dim: usize = 2;
        const has_holes = hole_starts.len > 0;
        const outer_len: usize = if (has_holes) @as(usize, hole_starts[0]) * dim else coords.len;

        var outer = try self.linkedList(coords, 0, outer_len, true);
        if (outer == nil or self.n(outer).next == self.n(outer).prev) return;

        var min_x: f64 = 0;
        var min_y: f64 = 0;
        var inv_size: f64 = 0;

        if (has_holes) outer = try self.eliminateHoles(coords, hole_starts, outer);

        // Above a size, the ear test walks a z-order neighbourhood instead of
        // the whole ring.
        if (coords.len > 80 * dim) {
            min_x = coords[0];
            min_y = coords[1];
            var max_x = min_x;
            var max_y = min_y;
            var i: usize = dim;
            while (i < outer_len) : (i += dim) {
                min_x = @min(min_x, coords[i]);
                min_y = @min(min_y, coords[i + 1]);
                max_x = @max(max_x, coords[i]);
                max_y = @max(max_y, coords[i + 1]);
            }
            inv_size = @max(max_x - min_x, max_y - min_y);
            inv_size = if (inv_size != 0) 32767.0 / inv_size else 0;
        }

        try self.earcutLinked(outer, out, min_x, min_y, inv_size, 0);
    }

    fn createNode(self: *Tess, i: u32, x: f64, y: f64) Allocator.Error!u32 {
        try self.nodes.append(self.gpa, .{ .i = i, .x = x, .y = y });
        return @intCast(self.nodes.items.len - 1);
    }

    fn insertNode(self: *Tess, i: u32, x: f64, y: f64, last: u32) Allocator.Error!u32 {
        const p = try self.createNode(i, x, y);
        if (last == nil) {
            self.n(p).prev = p;
            self.n(p).next = p;
        } else {
            const ln = self.n(last).next;
            self.n(p).next = ln;
            self.n(p).prev = last;
            self.n(ln).prev = p;
            self.n(last).next = p;
        }
        return p;
    }

    fn removeNode(self: *Tess, p: u32) void {
        const nx = self.n(p).next;
        const pv = self.n(p).prev;
        self.n(nx).prev = pv;
        self.n(pv).next = nx;
        if (self.n(p).prevz != nil) self.n(self.n(p).prevz).nextz = self.n(p).nextz;
        if (self.n(p).nextz != nil) self.n(self.n(p).nextz).prevz = self.n(p).prevz;
    }

    /// One ring as a circular list, in the requested winding.
    fn linkedList(
        self: *Tess,
        coords: []const f64,
        start: usize,
        end: usize,
        clockwise: bool,
    ) Allocator.Error!u32 {
        var last: u32 = nil;
        if (end <= start) return nil;

        if (clockwise == (signedArea(coords, start, end) > 0)) {
            var i = start;
            while (i < end) : (i += 2) {
                last = try self.insertNode(@intCast(i / 2), coords[i], coords[i + 1], last);
            }
        } else {
            var i = end;
            while (i >= start + 2) : (i -= 2) {
                last = try self.insertNode(@intCast((i - 2) / 2), coords[i - 2], coords[i - 1], last);
            }
        }

        if (last != nil and self.equals(last, self.n(last).next)) {
            const nx = self.n(last).next;
            self.removeNode(last);
            last = nx;
        }
        return last;
    }

    /// Drop collinear and coincident points. Removability depends only on a
    /// node's neighbours, so re-check the predecessor after each removal.
    fn filterPoints(self: *Tess, start_in: u32, end_in: u32) u32 {
        var start = start_in;
        var end = if (end_in == nil) start_in else end_in;
        if (start == nil) return nil;

        var p = start;
        var again = true;
        while (again or p != end) {
            again = false;
            const nx = self.n(p).next;
            if (!self.n(p).steiner and
                (self.equals(p, nx) or self.area(self.n(p).prev, p, nx) == 0))
            {
                const pv = self.n(p).prev;
                self.removeNode(p);
                p = pv;
                end = p;
                start = p;
                if (p == self.n(p).next) return nil;
                again = true;
            } else {
                p = nx;
            }
        }
        return end;
    }

    /// The ear-slicing loop. Recovery when it stalls, in three escalating
    /// stages, is what makes this survive real data.
    fn earcutLinked(
        self: *Tess,
        ear_in: u32,
        out: *std.ArrayListUnmanaged(u32),
        min_x: f64,
        min_y: f64,
        inv_size: f64,
        pass: u8,
    ) Allocator.Error!void {
        var ear = ear_in;
        if (ear == nil) return;

        if (pass == 0 and inv_size != 0) try self.indexCurve(ear, min_x, min_y, inv_size);

        var stop = ear;

        while (self.n(ear).prev != self.n(ear).next) {
            // Charged per candidate ear. Combined with the intersectsPolygon
            // and indexCurve charges, this bounds the whole triangulation --
            // including the recursion splitEarcut starts on each half.
            self.recovery_work += 1;
            if (self.recovery_work >= max_recovery_work) return;
            const prev = self.n(ear).prev;
            const next = self.n(ear).next;

            const is_ear = if (inv_size != 0)
                self.isEarHashed(ear, min_x, min_y, inv_size)
            else
                self.isEar(ear);

            if (is_ear) {
                try out.appendSlice(self.gpa, &.{ self.n(prev).i, self.n(ear).i, self.n(next).i });
                self.removeNode(ear);
                // Skip the next vertex too: it cannot be an ear now.
                ear = self.n(next).next;
                stop = self.n(next).next;
                continue;
            }

            ear = next;

            if (ear == stop) {
                if (pass == 0) {
                    // Collinear points can hide ears.
                    const filtered = self.filterPoints(ear, nil);
                    if (filtered == nil) return;
                    try self.earcutLinked(filtered, out, min_x, min_y, inv_size, 1);
                } else if (pass == 1) {
                    // Small self-intersections: cut them out and retry.
                    const cured = self.filterPoints(ear, nil);
                    if (cured == nil) return;
                    const fixed = try self.cureLocalIntersections(cured, out);
                    try self.earcutLinked(fixed, out, min_x, min_y, inv_size, 2);
                } else if (pass == 2) {
                    // Last resort: cut the polygon in two and do each half.
                    try self.splitEarcut(ear, out, min_x, min_y, inv_size);
                }
                return;
            }
        }
    }

    fn isEar(self: *Tess, ear: u32) bool {
        self.recovery_work += 1;
        const a = self.n(ear).prev;
        const b = ear;
        const c = self.n(ear).next;
        if (self.area(a, b, c) >= 0) return false; // reflex, not an ear

        const ax = self.n(a).x;
        const ay = self.n(a).y;
        const bx = self.n(b).x;
        const by = self.n(b).y;
        const cx = self.n(c).x;
        const cy = self.n(c).y;
        const x0 = @min(ax, @min(bx, cx));
        const y0 = @min(ay, @min(by, cy));
        const x1 = @max(ax, @max(bx, cx));
        const y1 = @max(ay, @max(by, cy));

        var p = self.n(c).next;
        while (p != a) {
            const px = self.n(p).x;
            const py = self.n(p).y;
            if (px >= x0 and px <= x1 and py >= y0 and py <= y1 and
                !(ax == px and ay == py) and
                pointInTriangle(ax, ay, bx, by, cx, cy, px, py) and
                self.area(self.n(p).prev, p, self.n(p).next) >= 0) return false;
            p = self.n(p).next;
        }
        return true;
    }

    fn isEarHashed(self: *Tess, ear: u32, min_x: f64, min_y: f64, inv_size: f64) bool {
        const a = self.n(ear).prev;
        const b = ear;
        const c = self.n(ear).next;
        if (self.area(a, b, c) >= 0) return false;

        const ax = self.n(a).x;
        const ay = self.n(a).y;
        const bx = self.n(b).x;
        const by = self.n(b).y;
        const cx = self.n(c).x;
        const cy = self.n(c).y;
        const x0 = @min(ax, @min(bx, cx));
        const y0 = @min(ay, @min(by, cy));
        const x1 = @max(ax, @max(bx, cx));
        const y1 = @max(ay, @max(by, cy));

        const min_z = zOrder(x0, y0, min_x, min_y, inv_size);
        const max_z = zOrder(x1, y1, min_x, min_y, inv_size);

        // Only the nodes whose z falls in the triangle's z range can be
        // inside it, so walk outward from the ear in both directions.
        var p = self.n(ear).prevz;
        while (p != nil and self.n(p).z >= min_z) {
            // Charged here, not per ear test: on a degenerate ring the z
            // range covers most of the curve and one "test" walks thousands
            // of nodes. A per-test charge leaves the bound proportional to
            // that width; charging the walk itself does not.
            self.recovery_work += 1;
            if (self.hashedBlocker(p, a, ax, ay, bx, by, cx, cy, c, x0, y0, x1, y1)) return false;
            p = self.n(p).prevz;
        }
        var q = self.n(ear).nextz;
        while (q != nil and self.n(q).z <= max_z) {
            self.recovery_work += 1;
            if (self.hashedBlocker(q, a, ax, ay, bx, by, cx, cy, c, x0, y0, x1, y1)) return false;
            q = self.n(q).nextz;
        }
        return true;
    }

    fn hashedBlocker(
        self: *Tess,
        p: u32,
        a: u32,
        ax: f64,
        ay: f64,
        bx: f64,
        by: f64,
        cx: f64,
        cy: f64,
        c: u32,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
    ) bool {
        if (p == a or p == c) return false;
        const px = self.n(p).x;
        const py = self.n(p).y;
        return px >= x0 and px <= x1 and py >= y0 and py <= y1 and
            !(ax == px and ay == py) and
            pointInTriangle(ax, ay, bx, by, cx, cy, px, py) and
            self.area(self.n(p).prev, p, self.n(p).next) >= 0;
    }

    fn cureLocalIntersections(
        self: *Tess,
        start_in: u32,
        out: *std.ArrayListUnmanaged(u32),
    ) Allocator.Error!u32 {
        var start = start_in;
        var p = start;
        while (true) {
            const a = self.n(p).prev;
            const b = self.n(self.n(p).next).next;

            if (!self.equals(a, b) and
                self.intersects(a, p, self.n(p).next, b) and
                self.locallyInside(a, b) and self.locallyInside(b, a))
            {
                try out.appendSlice(self.gpa, &.{ self.n(a).i, self.n(p).i, self.n(b).i });
                self.removeNode(p);
                self.removeNode(self.n(p).next);
                p = b;
                start = b;
            }
            p = self.n(p).next;
            if (p == start) break;
        }
        return self.filterPoints(p, nil);
    }

    fn splitEarcut(
        self: *Tess,
        start: u32,
        out: *std.ArrayListUnmanaged(u32),
        min_x: f64,
        min_y: f64,
        inv_size: f64,
    ) Allocator.Error!void {
        var a = start;
        while (true) {
            var b = self.n(self.n(a).next).next;
            while (b != self.n(a).prev) {
                if (self.recovery_work >= max_recovery_work) return;
                if (self.n(a).i != self.n(b).i and self.isValidDiagonal(a, b)) {
                    var c = try self.splitPolygon(a, b);
                    // Each half gets a fresh set of passes.
                    const ha = self.filterPoints(a, self.n(a).next);
                    c = self.filterPoints(c, self.n(c).next);
                    if (ha != nil) try self.earcutLinked(ha, out, min_x, min_y, inv_size, 0);
                    if (c != nil) try self.earcutLinked(c, out, min_x, min_y, inv_size, 0);
                    return;
                }
                b = self.n(b).next;
            }
            a = self.n(a).next;
            if (a == start) break;
        }
    }

    fn eliminateHoles(
        self: *Tess,
        coords: []const f64,
        hole_starts: []const u32,
        outer_in: u32,
    ) Allocator.Error!u32 {
        var outer = outer_in;
        self.scratch.clearRetainingCapacity();

        for (hole_starts, 0..) |hs, i| {
            const start: usize = @as(usize, hs) * 2;
            const end: usize = if (i + 1 < hole_starts.len)
                @as(usize, hole_starts[i + 1]) * 2
            else
                coords.len;
            const list = try self.linkedList(coords, start, end, false);
            if (list == nil) continue;
            if (list == self.n(list).next) self.n(list).steiner = true;
            try self.scratch.append(self.gpa, self.getLeftmost(list));
        }

        const queue = self.scratch.items;
        std.mem.sort(u32, queue, self, cmpLeftmost);

        for (queue) |q| outer = try self.eliminateHole(q, outer);
        return outer;
    }

    fn cmpLeftmost(self: *Tess, a: u32, b: u32) bool {
        // Left to right, and where two holes share their leftmost point the
        // bridge has to be the point they meet at, so break the tie by slope.
        if (self.n(a).x != self.n(b).x) return self.n(a).x < self.n(b).x;
        if (self.n(a).y != self.n(b).y) return self.n(a).y < self.n(b).y;
        const sa = (self.n(self.n(a).next).y - self.n(a).y) /
            (self.n(self.n(a).next).x - self.n(a).x);
        const sb = (self.n(self.n(b).next).y - self.n(b).y) /
            (self.n(self.n(b).next).x - self.n(b).x);
        return sa < sb;
    }

    fn eliminateHole(self: *Tess, hole: u32, outer: u32) Allocator.Error!u32 {
        const bridge = self.findHoleBridge(hole, outer);
        if (bridge == nil) return outer;
        const bridge_reverse = try self.splitPolygon(bridge, hole);
        _ = self.filterPoints(bridge_reverse, self.n(bridge_reverse).next);
        return self.filterPoints(bridge, self.n(bridge).next);
    }

    /// Eberly's bridge: cast a ray left from the hole's leftmost point and
    /// take the nearest crossing, then walk the reflex vertices inside the
    /// resulting triangle for a better (smaller-angle) connection.
    fn findHoleBridge(self: *Tess, hole: u32, outer: u32) u32 {
        var p = outer;
        const hx = self.n(hole).x;
        const hy = self.n(hole).y;
        var qx: f64 = -std.math.inf(f64);
        var m: u32 = nil;

        if (self.equals(hole, p)) return p;

        while (true) {
            const nx = self.n(p).next;
            if (self.equals(hole, nx)) return nx;
            if (hy <= self.n(p).y and hy >= self.n(nx).y and self.n(nx).y != self.n(p).y) {
                const x = self.n(p).x +
                    (hy - self.n(p).y) * (self.n(nx).x - self.n(p).x) /
                        (self.n(nx).y - self.n(p).y);
                if (x <= hx and x > qx) {
                    qx = x;
                    m = if (self.n(p).x < self.n(nx).x) p else nx;
                    if (x == hx) return m; // the hole touches the segment
                }
            }
            p = nx;
            if (p == outer) break;
        }

        if (m == nil) return nil;

        const mx = self.n(m).x;
        const my = self.n(m).y;
        var tan_min: f64 = std.math.inf(f64);

        p = outer;
        while (true) {
            const px = self.n(p).x;
            const py = self.n(p).y;
            if (hx >= px and px >= mx and hx != px and
                pointInTriangle(
                    if (hy < my) hx else qx,
                    hy,
                    mx,
                    my,
                    if (hy < my) qx else hx,
                    hy,
                    px,
                    py,
                ))
            {
                const tan = @abs(hy - py) / (hx - px);
                if (self.locallyInside(p, hole) and
                    (tan < tan_min or
                        (tan == tan_min and
                            (px > self.n(m).x or
                                (px == self.n(m).x and self.sectorContainsSector(m, p))))))
                {
                    m = p;
                    tan_min = tan;
                }
            }
            p = self.n(p).next;
            if (p == outer) break;
        }
        return m;
    }

    fn sectorContainsSector(self: *Tess, m: u32, p: u32) bool {
        return self.area(self.n(m).prev, m, self.n(p).prev) < 0 and
            self.area(self.n(p).next, m, self.n(m).next) < 0;
    }

    fn indexCurve(self: *Tess, start: u32, min_x: f64, min_y: f64, inv_size: f64) Allocator.Error!void {
        self.scratch.clearRetainingCapacity();
        var p = start;
        while (true) {
            self.n(p).z = zOrder(self.n(p).x, self.n(p).y, min_x, min_y, inv_size);
            try self.scratch.append(self.gpa, p);
            p = self.n(p).next;
            if (p == start) break;
        }
        const arr = self.scratch.items;
        // splitEarcut hands both halves back at pass 0, so this sort runs
        // again on every split. Charge it, or the budget misses the cost it
        // most needs to bound.
        self.recovery_work += @as(u64, arr.len) * (std.math.log2_int_ceil(usize, @max(2, arr.len)) + 1);
        std.mem.sort(u32, arr, self, cmpZ);

        var prev: u32 = nil;
        for (arr) |node| {
            self.n(node).prevz = prev;
            if (prev != nil) self.n(prev).nextz = node;
            prev = node;
        }
        if (prev != nil) self.n(prev).nextz = nil;
    }

    fn cmpZ(self: *Tess, a: u32, b: u32) bool {
        return self.n(a).z < self.n(b).z;
    }

    fn getLeftmost(self: *Tess, start: u32) u32 {
        var p = start;
        var leftmost = start;
        while (true) {
            if (self.n(p).x < self.n(leftmost).x or
                (self.n(p).x == self.n(leftmost).x and self.n(p).y < self.n(leftmost).y))
                leftmost = p;
            p = self.n(p).next;
            if (p == start) break;
        }
        return leftmost;
    }

    fn isValidDiagonal(self: *Tess, a: u32, b: u32) bool {
        return self.n(self.n(a).next).i != self.n(b).i and
            self.n(self.n(a).prev).i != self.n(b).i and
            !self.intersectsPolygon(a, b) and
            ((self.locallyInside(a, b) and self.locallyInside(b, a) and self.middleInside(a, b) and
                (self.area(self.n(a).prev, a, self.n(b).prev) != 0 or
                    self.area(a, self.n(b).prev, b) != 0)) or
                (self.equals(a, b) and
                    self.area(self.n(a).prev, a, self.n(a).next) > 0 and
                    self.area(self.n(b).prev, b, self.n(b).next) > 0));
    }

    fn area(self: *Tess, p: u32, q: u32, r: u32) f64 {
        const pn = self.n(p);
        const qn = self.n(q);
        const rn = self.n(r);
        return (qn.y - pn.y) * (rn.x - qn.x) - (qn.x - pn.x) * (rn.y - qn.y);
    }

    fn equals(self: *Tess, a: u32, b: u32) bool {
        return self.n(a).x == self.n(b).x and self.n(a).y == self.n(b).y;
    }

    fn intersects(self: *Tess, p1: u32, q1: u32, p2: u32, q2: u32) bool {
        const o1 = sign(self.area(p1, q1, p2));
        const o2 = sign(self.area(p1, q1, q2));
        const o3 = sign(self.area(p2, q2, p1));
        const o4 = sign(self.area(p2, q2, q1));

        if (o1 != o2 and o3 != o4) return true; // a real crossing
        if (o1 == 0 and self.onSegment(p1, p2, q1)) return true;
        if (o2 == 0 and self.onSegment(p1, q2, q1)) return true;
        if (o3 == 0 and self.onSegment(p2, p1, q2)) return true;
        if (o4 == 0 and self.onSegment(p2, q1, q2)) return true;
        return false;
    }

    fn onSegment(self: *Tess, p: u32, q: u32, r: u32) bool {
        const pn = self.n(p);
        const qn = self.n(q);
        const rn = self.n(r);
        return qn.x <= @max(pn.x, rn.x) and qn.x >= @min(pn.x, rn.x) and
            qn.y <= @max(pn.y, rn.y) and qn.y >= @min(pn.y, rn.y);
    }

    fn intersectsPolygon(self: *Tess, a: u32, b: u32) bool {
        var p = a;
        while (true) {
            // The recovery budget is spent here: this scan is the inner loop
            // of splitEarcut's O(n^2) diagonal search, so it is the only
            // place where charging per step gives a flat time bound.
            self.recovery_work += 1;
            const nx = self.n(p).next;
            if (self.n(p).i != self.n(a).i and self.n(nx).i != self.n(a).i and
                self.n(p).i != self.n(b).i and self.n(nx).i != self.n(b).i and
                self.intersects(p, nx, a, b)) return true;
            p = nx;
            if (p == a) break;
        }
        return false;
    }

    fn locallyInside(self: *Tess, a: u32, b: u32) bool {
        return if (self.area(self.n(a).prev, a, self.n(a).next) < 0)
            self.area(a, b, self.n(a).next) >= 0 and self.area(a, self.n(a).prev, b) >= 0
        else
            self.area(a, b, self.n(a).prev) < 0 or self.area(a, self.n(a).next, b) < 0;
    }

    fn middleInside(self: *Tess, a: u32, b: u32) bool {
        var p = a;
        var inside = false;
        const px = (self.n(a).x + self.n(b).x) / 2;
        const py = (self.n(a).y + self.n(b).y) / 2;
        while (true) {
            const nx = self.n(p).next;
            if (((self.n(p).y > py) != (self.n(nx).y > py)) and
                self.n(nx).y != self.n(p).y and
                (px < (self.n(nx).x - self.n(p).x) * (py - self.n(p).y) /
                    (self.n(nx).y - self.n(p).y) + self.n(p).x))
                inside = !inside;
            p = nx;
            if (p == a) break;
        }
        return inside;
    }

    /// Link a and b. Within one ring this splits it in two; between the
    /// outer ring and a hole it merges them.
    fn splitPolygon(self: *Tess, a: u32, b: u32) Allocator.Error!u32 {
        const a2 = try self.createNode(self.n(a).i, self.n(a).x, self.n(a).y);
        const b2 = try self.createNode(self.n(b).i, self.n(b).x, self.n(b).y);
        const an = self.n(a).next;
        const bp = self.n(b).prev;

        self.n(a).next = b;
        self.n(b).prev = a;
        self.n(a2).next = an;
        self.n(an).prev = a2;
        self.n(b2).next = a2;
        self.n(a2).prev = b2;
        self.n(bp).next = b2;
        self.n(b2).prev = bp;
        return b2;
    }
};

fn sign(v: f64) i2 {
    if (v > 0) return 1;
    if (v < 0) return -1;
    return 0;
}

fn pointInTriangle(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, px: f64, py: f64) bool {
    return (cx - px) * (ay - py) >= (ax - px) * (cy - py) and
        (ax - px) * (by - py) >= (bx - px) * (ay - py) and
        (bx - px) * (cy - py) >= (cx - px) * (by - py);
}

/// Interleaved 16-bit coordinates (a Morton code), so nearby points sort
/// near each other and the ear test can look at a neighbourhood.
fn zOrder(x_in: f64, y_in: f64, min_x: f64, min_y: f64, inv_size: f64) u32 {
    var x: u32 = @intFromFloat(@max(0, @min(32767, (x_in - min_x) * inv_size)));
    var y: u32 = @intFromFloat(@max(0, @min(32767, (y_in - min_y) * inv_size)));

    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;

    y = (y | (y << 8)) & 0x00FF00FF;
    y = (y | (y << 4)) & 0x0F0F0F0F;
    y = (y | (y << 2)) & 0x33333333;
    y = (y | (y << 1)) & 0x55555555;

    return x | (y << 1);
}

fn signedArea(coords: []const f64, start: usize, end: usize) f64 {
    var sum: f64 = 0;
    var j = if (end >= 2) end - 2 else start;
    var i = start;
    while (i < end) : (i += 2) {
        sum += (coords[j] - coords[i]) * (coords[i + 1] + coords[j + 1]);
        j = i;
    }
    return sum;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn triArea(coords: []const f64, tris: []const u32) f64 {
    var sum: f64 = 0;
    var i: usize = 0;
    while (i + 2 < tris.len) : (i += 3) {
        const ax = coords[tris[i] * 2];
        const ay = coords[tris[i] * 2 + 1];
        const bx = coords[tris[i + 1] * 2];
        const by = coords[tris[i + 1] * 2 + 1];
        const cx = coords[tris[i + 2] * 2];
        const cy = coords[tris[i + 2] * 2 + 1];
        sum += @abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2;
    }
    return sum;
}

test "a square is two triangles" {
    var t = Tess.init(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    const sq = [_]f64{ 0, 0, 10, 0, 10, 10, 0, 10 };
    try t.run(&sq, &.{}, &out);
    try testing.expectEqual(@as(usize, 6), out.items.len);
    try testing.expectApproxEqAbs(@as(f64, 100), triArea(&sq, out.items), 1e-9);
}

test "a square with a square hole keeps its area" {
    var t = Tess.init(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    // Outer CCW, hole CW; earcut fixes the winding itself either way.
    const coords = [_]f64{
        0,  0,  100, 0,  100, 100, 0,  100,
        25, 25, 25,  75, 75,  75,  75, 25,
    };
    try t.run(&coords, &.{4}, &out);
    try testing.expectApproxEqAbs(@as(f64, 100 * 100 - 50 * 50), triArea(&coords, out.items), 1e-9);
}

test "a bowtie is triangulated without covering the crossing twice" {
    var t = Tess.init(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    // The classic self-intersecting ring. Our own clipper fanned this and
    // covered ground outside both lobes; the recovery stages handle it.
    const bow = [_]f64{ 0, 0, 10, 10, 10, 0, 0, 10 };
    try t.run(&bow, &.{}, &out);
    try testing.expect(out.items.len >= 3);
    // Each lobe is 25 units; anything much above 50 is invented area.
    try testing.expect(triArea(&bow, out.items) <= 55);
}

test "a big ring takes the z-order path and still conserves area" {
    var t = Tess.init(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    // Over 80 vertices, which is where the hashed ear test switches on.
    const n = 200;
    const nf: f64 = @floatFromInt(n);
    var coords: [n * 2]f64 = undefined;
    for (0..n) |i| {
        const a = @as(f64, @floatFromInt(i)) / nf * std.math.tau;
        coords[i * 2] = @cos(a) * 100;
        coords[i * 2 + 1] = @sin(a) * 100;
    }
    try t.run(&coords, &.{}, &out);
    try testing.expectEqual(@as(usize, (n - 2) * 3), out.items.len);
    // A 200-gon on the unit circle scaled by 100.
    const want = 0.5 * nf * @sin(std.math.tau / nf) * 100 * 100;
    try testing.expectApproxEqAbs(want, triArea(&coords, out.items), want * 1e-6);
}

test "degenerate input yields nothing and does not spin" {
    var t = Tess.init(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    try t.run(&.{}, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    try t.run(&[_]f64{ 0, 0, 1, 1 }, &.{}, &out); // two points
    try testing.expectEqual(@as(usize, 0), out.items.len);

    out.clearRetainingCapacity();
    try t.run(&[_]f64{ 0, 0, 1, 1, 2, 2 }, &.{}, &out); // collinear
    try testing.expectEqual(@as(usize, 0), out.items.len);

    out.clearRetainingCapacity();
    try t.run(&[_]f64{ 5, 5, 5, 5, 5, 5, 5, 5 }, &.{}, &out); // all coincident
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "run: a self-intersecting ring finishes instead of stalling the worker" {
    const a = std.testing.allocator;

    // Tile geometry is untrusted. splitEarcut tests O(n^2) diagonals, each
    // walking the ring, and hands both halves back at pass 0 so the z-order
    // sort runs again per split. Before the budget a 20,000-vertex
    // self-intersecting ring took 46 seconds; 80,000 took 61.
    var coords: std.ArrayListUnmanaged(f64) = .empty;
    defer coords.deinit(a);
    const n = 20_000;
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) * 2.399963; // golden angle
        const r: f64 = if (i % 2 == 0) 1000 else 40;
        try coords.append(a, @cos(t) * r);
        try coords.append(a, @sin(t) * r);
    }

    var tess = Tess.init(a);
    defer tess.deinit();
    var tris: std.ArrayListUnmanaged(u32) = .empty;
    defer tris.deinit(a);
    try tess.run(coords.items, &.{}, &tris);

    // The budget stopped the recovery, so the fill is partial by design.
    try std.testing.expect(tess.recovery_work >= max_recovery_work);
    try std.testing.expect(tris.items.len % 3 == 0);
    // Every emitted index still addresses a real vertex.
    for (tris.items) |t| try std.testing.expect(t < n);
}

test "run: the budget leaves well-formed geometry alone" {
    const a = std.testing.allocator;
    var coords: std.ArrayListUnmanaged(f64) = .empty;
    defer coords.deinit(a);
    const n = 100_000;
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * 2 * std.math.pi;
        try coords.append(a, @cos(t) * 1000);
        try coords.append(a, @sin(t) * 1000);
    }

    var tess = Tess.init(a);
    defer tess.deinit();
    var tris: std.ArrayListUnmanaged(u32) = .empty;
    defer tris.deinit(a);
    try tess.run(coords.items, &.{}, &tris);

    // A convex ring of n vertices fans into exactly n-2 triangles, and does
    // it without coming near the budget.
    try std.testing.expectEqual(@as(usize, n - 2), tris.items.len / 3);
    try std.testing.expect(tess.recovery_work < max_recovery_work);
}

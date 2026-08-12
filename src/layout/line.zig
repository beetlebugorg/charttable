//! Polyline stroking for line layers: a decoded MVT linestring in, triangles
//! in the scene Vertex stream out, with the anchor + screen-offset split from
//! scene/types.zig.
//!
//! Provenance: the anchor+offset quad — position ON the line, (ox, oy) the
//! segment normal in reference px, map_align always set — is tile57's
//! (render/gpu.zig emitStroke, including the comment explaining why a stroke
//! that forgets map_align shears to |cos(rotation)| of its width in a rotated
//! view). The join and cap geometry ports lookout overlay.zig strokeSub /
//! joinAt / capAt / fanBetween: outer-side selection by the turn's cross
//! product, the miter-limit test on the half-angle cosine, the 0.4 rad round
//! segmentation, the noise-length segment guard. Dash cutting ports lookout
//! emitPolyline's cycle-INDEXED cuts (a walked phase drifts a few ULP at any
//! fractional zoom and stalls the pattern — the own-ship speed-vector bug
//! documented there), generalized from one hardwired on/off pair to the
//! spec's line-dasharray, and re-anchored to arc length from the line's own
//! start so the pattern restarts per line at phase 0.
//!
//! Spec semantics (maplibre.org/maplibre-style-spec/layers/#line):
//! - line-cap butt | round | square (default butt); round/square extend past
//!   the endpoint by half the width.
//! - line-join miter | bevel | round (default miter).
//! - line-miter-limit (default 2): a miter whose length ratio exceeds the
//!   limit draws as a bevel.
//! - line-round-limit (default 1.05): a round join shallower than the limit
//!   draws as a miter.
//! - line-dasharray: alternating dash/gap lengths in WIDTH MULTIPLES ("to
//!   convert a dash length to pixels, multiply the length by the current
//!   line width"). An odd count alternates roles per period (the array
//!   doubled). The pattern restarts at each line's start, phase 0.
//!
//! Geometry has no zoom dependence: positions are tile-local world units
//! (tile_span * coord / extent, buffer overhang kept), widths live entirely
//! in the px offsets, and only the dash pattern measures the line in px —
//! through the caller's px_per_unit, a layout-time constant, never the
//! camera's fractional zoom. Each dash run is stroked as its own sub-line
//! (joins where it spans a vertex, caps at both cut ends). Zero-length
//! dashes draw nothing — no round-cap dots.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../scene/types.zig");
const mvt = @import("../source/mvt.zig");

pub const Cap = enum(u8) { butt, round, square };
pub const Join = enum(u8) { miter, bevel, round };

pub const Options = struct {
    /// Stroke width in reference px. Baked into the offsets at layout.
    width_px: f32,
    cap: Cap = .butt,
    join: Join = .miter,
    /// Spec line-miter-limit. Values <= 0 mean every miter draws as bevel.
    miter_limit: f32 = 2.0,
    /// Spec line-round-limit: rounds shallower than this draw as miters.
    round_limit: f32 = 1.05,
    /// Spec line-dasharray, in width multiples. Empty = solid.
    dasharray: []const f32 = &.{},
    /// Treat every part as a closed ring (a line layer over polygon
    /// features): the wrap segment is stroked and the seam gets a join, not
    /// caps. A dashed closed ring is cut as an open line through the wrap
    /// segment — the pattern still starts at the seam, phase 0.
    closed: bool = false,
    /// Per-vertex zoom visibility window (scene/types.zig).
    zmin: u16 = types.ZMIN_ALL,
    zmax: u16 = types.ZMAX_ALL,
    /// Paint-order depth in (0,1): later paint = smaller.
    depth: f32 = 0,
};

/// Round join/cap segmentation: one triangle per 0.4 rad of sweep (lookout
/// fanBetween's step) — 4 per right-angle join, 8 per half-circle cap.
const ROUND_STEP_RAD = 0.4;

/// Above this many dash cycles over one line the pattern is sub-pixel noise
/// and the line draws solid (lookout's MAX_DASHES_PER_SEG guard: the cut
/// loop must not emit millions of invisible quads).
const MAX_DASH_CYCLES = 4096.0;

/// |cross| below this between unit directions is "straight through".
const STRAIGHT_EPS = 1e-12;

const Pt = struct { x: f64, y: f64 };

/// Stroke one linestring feature's parts into `verts` + `indices`.
///
/// `px_per_unit` is reference px per tile-local world unit at layout (the
/// tile's on-screen size over tile_span — 512 * 2^z in the MapLibre
/// convention). Only the dash pattern reads it; a solid line never does.
/// Indices are absolute into `verts`, so many features append into one
/// bucket.
pub fn layoutLine(
    gpa: Allocator,
    parts: []const []const mvt.Point,
    extent: u32,
    tile_span: f64,
    px_per_unit: f64,
    opts: Options,
    verts: *std.ArrayList(types.Vertex),
    indices: *std.ArrayList(u32),
) Allocator.Error!void {
    if (extent == 0) return; // hostile tile: nothing sane to scale by
    const hw = @as(f64, opts.width_px) * 0.5;
    if (!(hw > 0)) return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var e = Emitter{ .gpa = gpa, .verts = verts, .indices = indices, .hw = hw, .opts = &opts };
    const scale = tile_span / @as(f64, @floatFromInt(extent));
    // Shortest segment worth a direction: anything under it is a repeated
    // point within rounding and its normal is noise (lookout SEG_EPS,
    // restated relative to the tile's scale).
    const eps = tile_span * 1e-12;

    const pattern = try compilePattern(a, opts.dasharray, opts.width_px);
    if (pattern) |pat| {
        if (pat.runs.len == 0) return; // all-gap pattern: nothing to draw
        std.debug.assert(px_per_unit > 0);
    }

    var wpts = std.ArrayList(Pt).empty;
    var cum = std.ArrayList(f64).empty;
    var run = std.ArrayList(Pt).empty;

    for (parts) |part| {
        if (part.len < 2) continue;
        wpts.clearRetainingCapacity();
        for (part) |ip| {
            const w = Pt{
                .x = @as(f64, @floatFromInt(ip.x)) * scale,
                .y = @as(f64, @floatFromInt(ip.y)) * scale,
            };
            if (wpts.items.len > 0 and nearPt(wpts.items[wpts.items.len - 1], w, eps)) continue;
            try wpts.append(a, w);
        }
        if (wpts.items.len < 2) continue;

        if (pattern == null) {
            try strokeRun(&e, wpts.items, opts.closed, eps);
            continue;
        }
        const pat = pattern.?;

        // Dashed: measure the part in px and cut. A closed ring's wrap
        // segment becomes explicit so the walk covers it.
        if (opts.closed and !nearPt(wpts.items[0], wpts.items[wpts.items.len - 1], eps)) {
            try wpts.append(a, wpts.items[0]);
        }
        cum.clearRetainingCapacity();
        try cum.ensureUnusedCapacity(a, wpts.items.len);
        var total: f64 = 0;
        cum.appendAssumeCapacity(0);
        for (wpts.items[1..], 0..) |q, k| {
            const p = wpts.items[k];
            total += @sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)) * px_per_unit;
            cum.appendAssumeCapacity(total);
        }
        if (!(total > 0)) continue;
        if (total / pat.period > MAX_DASH_CYCLES) {
            // Sub-pixel dashes cannot show: draw solid instead.
            try strokeRun(&e, wpts.items, opts.closed, eps);
            continue;
        }
        try dashRuns(&e, a, wpts.items, cum.items, total, pat, &run, eps);
    }
}

// ---- the emitter -------------------------------------------------------------

const Emitter = struct {
    gpa: Allocator,
    verts: *std.ArrayList(types.Vertex),
    indices: *std.ArrayList(u32),
    /// Half width, reference px.
    hw: f64,
    opts: *const Options,

    /// One vertex: anchor on the line (tile-local world units), offset in
    /// px. A line edge ALWAYS sets map_align — the offset is a map-frame
    /// normal, and an unrotated offset shears the pen (scene/types.zig).
    fn push(e: *Emitter, p: Pt, ox: f64, oy: f64) Allocator.Error!u32 {
        const i: u32 = @intCast(e.verts.items.len);
        try e.verts.append(e.gpa, .{
            .x = @floatCast(p.x),
            .y = @floatCast(p.y),
            .ox = @floatCast(ox),
            .oy = @floatCast(oy),
            .zmin = e.opts.zmin,
            .zmax = e.opts.zmax,
            .flags = types.Flags.map_align,
            .depth = e.opts.depth,
        });
        return i;
    }

    fn tri(e: *Emitter, ia: u32, ib: u32, ic: u32) Allocator.Error!void {
        try e.indices.appendSlice(e.gpa, &.{ ia, ib, ic });
    }

    /// The segment body: a px-wide quad riding two world anchors.
    fn quad(e: *Emitter, a: Pt, b: Pt, n: Pt) Allocator.Error!void {
        const v0 = try e.push(a, n.x * e.hw, n.y * e.hw);
        const v1 = try e.push(a, -n.x * e.hw, -n.y * e.hw);
        const v2 = try e.push(b, n.x * e.hw, n.y * e.hw);
        const v3 = try e.push(b, -n.x * e.hw, -n.y * e.hw);
        try e.tri(v0, v1, v2);
        try e.tri(v1, v3, v2);
    }

    /// Fill the wedge a turn opens on the outside of the joint at `p`
    /// between unit directions d1 (incoming) and d2 (outgoing).
    fn join(e: *Emitter, p: Pt, d1: Pt, d2: Pt) Allocator.Error!void {
        const cr = d1.x * d2.y - d1.y * d2.x;
        const dot = d1.x * d2.x + d1.y * d2.y;
        if (@abs(cr) < STRAIGHT_EPS and dot >= 0) return; // straight through
        const s: f64 = if (cr > 0) -1 else 1; // the outer side of the turn
        const o1 = Pt{ .x = -d1.y * s, .y = d1.x * s };
        const o2 = Pt{ .x = -d2.y * s, .y = d2.x * s };
        // A hairpin has no single outer side and an unbounded miter.
        const reversal = @abs(cr) < STRAIGHT_EPS;
        // cos of the half-angle between the outer normals; the miter length
        // ratio (miter length over width) is its reciprocal.
        const ch = @sqrt(@max(0.0, (1.0 + (o1.x * o2.x + o1.y * o2.y)) * 0.5));
        switch (e.opts.join) {
            .bevel => try e.bevel(p, o1, o2),
            .round => {
                // Spec line-round-limit: a shallow round IS a miter.
                if (!reversal and ch * @as(f64, e.opts.round_limit) >= 1.0)
                    return e.miter(p, o1, o2, ch);
                const a0 = std.math.atan2(o1.y, o1.x);
                if (reversal) {
                    // Bulge through the incoming direction: the half circle
                    // past the hairpin, two exact quarter turns.
                    const half = angDelta(a0, std.math.atan2(d1.y, d1.x));
                    try e.fan(p, a0, half * 2.0);
                } else {
                    try e.fan(p, a0, angDelta(a0, std.math.atan2(o2.y, o2.x)));
                }
            },
            .miter => {
                // ch * limit > 1 <=> ratio 1/ch < limit; ch = 0 (hairpin)
                // and limit <= 0 both fall to bevel without a division.
                if (!(ch * @as(f64, e.opts.miter_limit) > 1.0)) return e.bevel(p, o1, o2);
                try e.miter(p, o1, o2, ch);
            },
        }
    }

    fn bevel(e: *Emitter, p: Pt, o1: Pt, o2: Pt) Allocator.Error!void {
        const c = try e.push(p, 0, 0);
        const a1 = try e.push(p, o1.x * e.hw, o1.y * e.hw);
        const b1 = try e.push(p, o2.x * e.hw, o2.y * e.hw);
        try e.tri(c, a1, b1);
    }

    fn miter(e: *Emitter, p: Pt, o1: Pt, o2: Pt, ch: f64) Allocator.Error!void {
        var mx = o1.x + o2.x;
        var my = o1.y + o2.y;
        const ml = @sqrt(mx * mx + my * my);
        if (!(ml > 0)) return e.bevel(p, o1, o2);
        // The miter tip sits along the outer bisector at hw / ch.
        mx = mx / ml * (e.hw / ch);
        my = my / ml * (e.hw / ch);
        const c = try e.push(p, 0, 0);
        const a1 = try e.push(p, o1.x * e.hw, o1.y * e.hw);
        const mm = try e.push(p, mx, my);
        const b1 = try e.push(p, o2.x * e.hw, o2.y * e.hw);
        try e.tri(c, a1, mm);
        try e.tri(c, mm, b1);
    }

    /// Fan `sweep` radians (signed) from angle `a0` about `p`, offsets on
    /// the hw circle.
    fn fan(e: *Emitter, p: Pt, a0: f64, sweep: f64) Allocator.Error!void {
        if (sweep == 0) return;
        const steps: usize = @intFromFloat(@max(1.0, @ceil(@abs(sweep) / ROUND_STEP_RAD)));
        const c = try e.push(p, 0, 0);
        var prev = try e.push(p, @cos(a0) * e.hw, @sin(a0) * e.hw);
        var i: usize = 1;
        while (i <= steps) : (i += 1) {
            const ang = a0 + sweep * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const cur = try e.push(p, @cos(ang) * e.hw, @sin(ang) * e.hw);
            try e.tri(c, prev, cur);
            prev = cur;
        }
    }

    /// A cap at `p` for a segment leaving along unit `d` (pointing OUT of
    /// the line).
    fn capAt(e: *Emitter, p: Pt, d: Pt) Allocator.Error!void {
        const n = Pt{ .x = -d.y, .y = d.x };
        switch (e.opts.cap) {
            .butt => {},
            .square => {
                const v0 = try e.push(p, n.x * e.hw, n.y * e.hw);
                const v1 = try e.push(p, (d.x + n.x) * e.hw, (d.y + n.y) * e.hw);
                const v2 = try e.push(p, (d.x - n.x) * e.hw, (d.y - n.y) * e.hw);
                const v3 = try e.push(p, -n.x * e.hw, -n.y * e.hw);
                try e.tri(v0, v1, v2);
                try e.tri(v0, v2, v3);
            },
            .round => {
                // The half circle from +normal THROUGH d to -normal: the
                // sweep is twice the exact quarter turn toward d, so the
                // bulge is always the protruding side. (lookout's fanBetween
                // said "either way round draws the same half circle" — it
                // does not: one of them is the side the quad already covers.)
                const a0 = std.math.atan2(n.y, n.x);
                const half = angDelta(a0, std.math.atan2(d.y, d.x));
                try e.fan(p, a0, half * 2.0);
            },
        }
    }
};

/// Signed shortest angle from a0 to a1, in (-pi, pi].
fn angDelta(a0: f64, a1: f64) f64 {
    var d = a1 - a0;
    while (d > std.math.pi) d -= 2 * std.math.pi;
    while (d <= -std.math.pi) d += 2 * std.math.pi;
    return d;
}

fn nearPt(a: Pt, b: Pt, eps: f64) bool {
    return @abs(a.x - b.x) <= eps and @abs(a.y - b.y) <= eps;
}

/// Stroke one polyline: a quad per segment, a join at every interior vertex
/// (and the seam, when closed), caps at open ends. Port of lookout
/// strokeSub reshaped for the anchor+offset vertex split.
fn strokeRun(e: *Emitter, pts_in: []const Pt, closed: bool, eps: f64) Allocator.Error!void {
    var pts = pts_in;
    // A closed ring whose last point repeats the first within rounding would
    // contribute a noise-direction wrap segment and a wedge pointing
    // anywhere (lookout strokeSub's guard).
    while (closed and pts.len > 1 and nearPt(pts[0], pts[pts.len - 1], eps)) pts = pts[0 .. pts.len - 1];
    const n = pts.len;
    if (n < 2) return;
    const segs = if (closed) n else n - 1;
    var prev_dir: ?Pt = null;
    var first_dir: ?Pt = null;
    var first_pt: Pt = undefined;
    var last_pt: Pt = undefined;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a = pts[i];
        const b = pts[(i + 1) % n];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        // A shorter segment is a repeated point: its quad is invisible and
        // its direction is noise — neither may reach the join machinery.
        if (!(len > eps)) continue;
        const d = Pt{ .x = dx / len, .y = dy / len };
        try e.quad(a, b, .{ .x = -d.y, .y = d.x });
        if (prev_dir) |pd| try e.join(a, pd, d);
        if (first_dir == null) {
            first_dir = d;
            first_pt = a;
        }
        prev_dir = d;
        last_pt = b;
    }
    if (closed) {
        if (prev_dir != null and first_dir != null)
            try e.join(first_pt, prev_dir.?, first_dir.?);
        return;
    }
    if (e.opts.cap == .butt) return;
    if (first_dir) |fd| try e.capAt(first_pt, .{ .x = -fd.x, .y = -fd.y });
    if (prev_dir) |ld| try e.capAt(last_pt, ld);
}

// ---- dashes -------------------------------------------------------------------

/// One "on" run within a dash period, px.
const Run = struct { start: f64, len: f64 };

const Pattern = struct { runs: []const Run, period: f64 };

/// Compile line-dasharray (width multiples) into px on-runs within one
/// period. null = solid (empty array, zero period, or no gaps). A pattern
/// with runs.len == 0 is all gap: the line draws NOTHING, which is not
/// solid. Negative entries clamp to 0; an odd count alternates dash/gap
/// roles per period (the array doubled, the SVG rule); adjacent runs merge
/// across zero gaps, including the period seam.
fn compilePattern(a: Allocator, dasharray: []const f32, width_px: f32) Allocator.Error!?Pattern {
    if (dasharray.len == 0) return null;
    const n = if (dasharray.len % 2 == 1) dasharray.len * 2 else dasharray.len;
    var runs = std.ArrayList(Run).empty;
    var off_total: f64 = 0;
    var pos: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 2) {
        const on = @max(@as(f64, dasharray[i % dasharray.len]), 0) * @as(f64, width_px);
        const off = @max(@as(f64, dasharray[(i + 1) % dasharray.len]), 0) * @as(f64, width_px);
        if (on > 0) {
            const m = runs.items.len;
            if (m > 0 and runs.items[m - 1].start + runs.items[m - 1].len == pos) {
                runs.items[m - 1].len += on; // zero gap: one continuous dash
            } else {
                try runs.append(a, .{ .start = pos, .len = on });
            }
        }
        off_total += off;
        pos += on + off;
    }
    const period = pos;
    if (!(period > 0) or !(off_total > 0)) return null; // no pattern to show
    var items = runs.items;
    // A dash spanning the period seam (trailing gap 0, leading dash) is one
    // dash: fold the first run into the last, which then runs past `period`
    // into the next cycle it owns.
    if (items.len >= 2 and items[0].start == 0 and
        items[items.len - 1].start + items[items.len - 1].len == period)
    {
        items[items.len - 1].len += items[0].len;
        items = items[1..];
    }
    return .{ .runs = items, .period = period };
}

/// Cut the polyline into the pattern's on-runs and stroke each as its own
/// open sub-line. Cycle k's run r covers [k*period + r.start, +r.len) of
/// arc length px FROM THE LINE'S START — an index, not a walked phase, so
/// no ULP drift can stall the pattern (the lookout emitPolyline lesson).
fn dashRuns(
    e: *Emitter,
    a: Allocator,
    pts: []const Pt,
    cum: []const f64,
    total: f64,
    pat: Pattern,
    run: *std.ArrayList(Pt),
    eps: f64,
) Allocator.Error!void {
    var cursor: usize = 0; // segment index; t0 only ever grows
    var k: f64 = 0;
    outer: while (true) : (k += 1) {
        const cycle0 = k * pat.period;
        for (pat.runs) |r| {
            const t0 = cycle0 + r.start;
            // Run starts are increasing across runs AND cycles, so the
            // first start past the end finishes the whole line.
            if (t0 >= total) break :outer;
            const t1 = @min(t0 + r.len, total);
            if (!(t1 > t0)) continue;
            run.clearRetainingCapacity();
            while (cum[cursor + 1] < t0) cursor += 1;
            try run.append(a, pointAt(pts, cum, cursor, t0));
            var s = cursor;
            while (cum[s + 1] < t1) : (s += 1) {
                try run.append(a, pts[s + 1]);
            }
            try run.append(a, pointAt(pts, cum, s, t1));
            try strokeRun(e, run.items, false, eps);
        }
    }
}

/// The point at arc length `t` px on segment `seg` (cum[seg] <= t <= cum[seg+1]).
fn pointAt(pts: []const Pt, cum: []const f64, seg: usize, t: f64) Pt {
    const l0 = cum[seg];
    const l1 = cum[seg + 1];
    const f = if (l1 > l0) (t - l0) / (l1 - l0) else 0;
    return .{
        .x = pts[seg].x + (pts[seg + 1].x - pts[seg].x) * f,
        .y = pts[seg].y + (pts[seg + 1].y - pts[seg].y) * f,
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

const Built = struct {
    verts: std.ArrayList(types.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    fn deinit(b: *Built) void {
        b.verts.deinit(testing.allocator);
        b.indices.deinit(testing.allocator);
    }

    fn layout(b: *Built, parts: []const []const mvt.Point, span: f64, ppu: f64, opts: Options) !void {
        try layoutLine(testing.allocator, parts, 4096, span, ppu, opts, &b.verts, &b.indices);
    }
};

test "a straight 2-point line is one quad with correct normals" {
    var b = Built{};
    defer b.deinit();
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const parts = [_][]const mvt.Point{&pts};
    // span == extent: world units read as tile coords.
    try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10 });

    try testing.expectEqual(@as(usize, 4), b.verts.items.len);
    try testing.expectEqual(@as(usize, 6), b.indices.items.len);
    // Anchors sit ON the line; the width lives entirely in the offsets:
    // the +x segment's normal is (0, 1) (y down), half-width 5 px.
    const want = [4]struct { x: f32, oy: f32 }{
        .{ .x = 0, .oy = 5 },   .{ .x = 0, .oy = -5 },
        .{ .x = 100, .oy = 5 }, .{ .x = 100, .oy = -5 },
    };
    for (b.verts.items, want) |v, w| {
        try testing.expectEqual(w.x, v.x);
        try testing.expectEqual(@as(f32, 0), v.y);
        try testing.expectEqual(@as(f32, 0), v.ox);
        try testing.expectEqual(w.oy, v.oy);
        try testing.expectEqual(types.Flags.map_align, v.flags); // a line edge ALWAYS sets it
    }
    for (b.indices.items) |ix| try testing.expect(ix < b.verts.items.len);
}

test "right-angle joins: miter tip, limit fallback, bevel, round fan" {
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 } };
    const parts = [_][]const mvt.Point{&pts};

    { // miter within the default limit (ratio sqrt(2) <= 2): 4-vertex wedge
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .join = .miter });
        try testing.expectEqual(@as(usize, 12), b.verts.items.len); // 2 quads + join
        try testing.expectEqual(@as(usize, 18), b.indices.items.len);
        // The join anchors at the corner; the outer side of an east-then-
        // south turn is up-right (y down): o1=(0,-1), tip=(1,-1)*hw, o2=(1,0).
        const j = b.verts.items[8..12];
        for (j) |v| {
            try testing.expectEqual(@as(f32, 100), v.x);
            try testing.expectEqual(@as(f32, 0), v.y);
        }
        try testing.expectEqual(@as(f32, 0), j[0].ox); // center
        try testing.expectEqual(@as(f32, 0), j[0].oy);
        try testing.expectApproxEqAbs(@as(f32, 0), j[1].ox, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -5), j[1].oy, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 5), j[2].ox, 1e-6); // the miter tip
        try testing.expectApproxEqAbs(@as(f32, -5), j[2].oy, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 5), j[3].ox, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0), j[3].oy, 1e-6);
    }
    { // a limit below the ratio converts the miter to a 3-vertex bevel
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .join = .miter, .miter_limit = 1.0 });
        try testing.expectEqual(@as(usize, 11), b.verts.items.len);
        try testing.expectEqual(@as(usize, 15), b.indices.items.len);
    }
    { // bevel asked for directly
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .join = .bevel });
        try testing.expectEqual(@as(usize, 11), b.verts.items.len);
        try testing.expectEqual(@as(usize, 15), b.indices.items.len);
    }
    { // round: a pi/2 wedge at 0.4 rad per step = 4 segments, rim on the hw circle
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .join = .round });
        try testing.expectEqual(@as(usize, 8 + 6), b.verts.items.len);
        try testing.expectEqual(@as(usize, 12 + 12), b.indices.items.len);
        for (b.verts.items[9..14]) |v| { // the 5 rim vertices
            const r = @sqrt(@as(f64, v.ox) * v.ox + @as(f64, v.oy) * v.oy);
            try testing.expectApproxEqAbs(@as(f64, 5), r, 1e-6);
            try testing.expect(v.ox >= -1e-6 and v.oy <= 1e-6); // outer quadrant
        }
    }
    { // nearly straight round join: line-round-limit turns it into a miter
        var b = Built{};
        defer b.deinit();
        const shallow = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 200, .y = 5 } };
        const sparts = [_][]const mvt.Point{&shallow};
        try b.layout(&sparts, 4096.0, 1.0, .{ .width_px = 10, .join = .round });
        try testing.expectEqual(@as(usize, 12), b.verts.items.len); // miter wedge, not a fan
    }
}

test "caps: butt adds nothing, square a quad, round an 8-segment half fan" {
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const parts = [_][]const mvt.Point{&pts};

    { // butt
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .cap = .butt });
        try testing.expectEqual(@as(usize, 4), b.verts.items.len);
    }
    { // square: each cap protrudes hw along the line
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .cap = .square });
        try testing.expectEqual(@as(usize, 4 + 2 * 4), b.verts.items.len);
        try testing.expectEqual(@as(usize, 6 + 2 * 6), b.indices.items.len);
        // Start cap protrudes toward -x: ox = -5 on its outer corners.
        const c0 = b.verts.items[4..8];
        try testing.expectApproxEqAbs(@as(f32, -5), c0[1].ox, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -5), c0[2].ox, 1e-6);
        // End cap protrudes toward +x.
        const c1 = b.verts.items[8..12];
        try testing.expectApproxEqAbs(@as(f32, 5), c1[1].ox, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 5), c1[2].ox, 1e-6);
    }
    { // round: pi sweep at 0.4 rad per step = 8 segments per cap, bulging OUT
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .cap = .round });
        try testing.expectEqual(@as(usize, 4 + 2 * 10), b.verts.items.len);
        try testing.expectEqual(@as(usize, 6 + 2 * 24), b.indices.items.len);
        // Start cap rim never reaches +x; end cap rim never -x (the bulge
        // is the protruding side, not the side the quad already covers).
        for (b.verts.items[5..14]) |v| try testing.expect(v.ox <= 1e-6);
        for (b.verts.items[15..24]) |v| try testing.expect(v.ox >= -1e-6);
    }
}

test "dasharray cuts the expected dash count, pattern restarts per part" {
    var b = Built{};
    defer b.deinit();
    // 1000 px of line; {4, 6} x width 10 = 40 on / 60 off, period 100:
    // exactly 10 dashes, each its own butt-capped quad.
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1000, .y = 0 } };
    const parts = [_][]const mvt.Point{&pts};
    try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{ 4, 6 } });
    try testing.expectEqual(@as(usize, 10 * 4), b.verts.items.len);
    try testing.expectEqual(@as(usize, 10 * 6), b.indices.items.len);
    // Dash k covers [k*100, k*100+40].
    var k: usize = 0;
    while (k < 10) : (k += 1) {
        const q = b.verts.items[k * 4 ..][0..4];
        const x0: f32 = @floatFromInt(k * 100);
        try testing.expectEqual(x0, q[0].x);
        try testing.expectEqual(x0 + 40, q[2].x);
    }

    // A second part restarts the pattern at phase 0.
    var b2 = Built{};
    defer b2.deinit();
    const p1 = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const p2 = [_]mvt.Point{ .{ .x = 0, .y = 500 }, .{ .x = 100, .y = 500 } };
    const parts2 = [_][]const mvt.Point{ &p1, &p2 };
    try b2.layout(&parts2, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{ 4, 6 } });
    try testing.expectEqual(@as(usize, 2 * 4), b2.verts.items.len); // one dash each
    try testing.expectEqual(@as(f32, 0), b2.verts.items[0].x); // both start at the part head
    try testing.expectEqual(@as(f32, 40), b2.verts.items[2].x);
    try testing.expectEqual(@as(f32, 0), b2.verts.items[4].x);
    try testing.expectEqual(@as(f32, 40), b2.verts.items[6].x);
}

test "a dash spanning a vertex keeps its join; odd dasharray doubles" {
    var b = Built{};
    defer b.deinit();
    // L-shape, 150 px total. {60, 40} x width 1: dash [0,60) crosses the
    // corner at 50 -> 2 quads + 1 miter join; dash [100,150) is a plain quad.
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 50, .y = 0 }, .{ .x = 50, .y = 100 } };
    const parts = [_][]const mvt.Point{&pts};
    try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 1, .dasharray = &.{ 60, 40 } });
    try testing.expectEqual(@as(usize, 2 * 4 + 4 + 4), b.verts.items.len);
    try testing.expectEqual(@as(usize, 2 * 6 + 6 + 6), b.indices.items.len);

    // {2} reads as {2, 2}: 200 px / width 10 -> period 40, on 20 -> 5 dashes.
    var b2 = Built{};
    defer b2.deinit();
    const line2 = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 200, .y = 0 } };
    const parts2 = [_][]const mvt.Point{&line2};
    try b2.layout(&parts2, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{2} });
    try testing.expectEqual(@as(usize, 5 * 4), b2.verts.items.len);
}

test "dasharray edge cases: solid, invisible, sub-pixel fallback" {
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const parts = [_][]const mvt.Point{&pts};

    { // no gaps = solid
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{ 3, 0 } });
        try testing.expectEqual(@as(usize, 4), b.verts.items.len);
    }
    { // all gap = nothing (not solid)
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{ 0, 5 } });
        try testing.expectEqual(@as(usize, 0), b.verts.items.len);
    }
    { // negative entries clamp to 0: {-1, 5} is all gap too
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{ -1, 5 } });
        try testing.expectEqual(@as(usize, 0), b.verts.items.len);
    }
    { // more cycles than MAX_DASH_CYCLES: sub-pixel pattern draws solid
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1e6, .{ .width_px = 10, .dasharray = &.{ 0.001, 0.001 } });
        try testing.expectEqual(@as(usize, 4), b.verts.items.len);
    }
    { // zero-length dashes ({0,1,2,1} px roles) draw only the real runs
        var b = Built{};
        defer b.deinit();
        try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .dasharray = &.{ 0, 1, 2, 1 } });
        // period 40 px, one 20 px run at offset 10: dashes at [10,30), [50,70), [90,100].
        try testing.expectEqual(@as(usize, 3 * 4), b.verts.items.len);
    }
}

test "geometry is zoom-independent: px offsets identical, anchors scale with the tile" {
    // The SAME feature laid out for a tile of half the world span (one zoom
    // deeper) with px_per_unit doubled (same on-screen size): the px stream
    // must be bit-identical and the anchors exactly halved — geometry never
    // reads a fractional zoom.
    const pts = [_]mvt.Point{ .{ .x = 100, .y = 200 }, .{ .x = 900, .y = 200 }, .{ .x = 900, .y = 1000 } };
    const parts = [_][]const mvt.Point{&pts};
    const opts = Options{ .width_px = 7, .cap = .round, .join = .round, .dasharray = &.{ 3, 2 } };

    var z14 = Built{};
    defer z14.deinit();
    try z14.layout(&parts, 1.0 / 16384.0, 512.0 * 16384.0, opts);
    var z15 = Built{};
    defer z15.deinit();
    try z15.layout(&parts, 1.0 / 32768.0, 512.0 * 32768.0, opts);

    try testing.expect(z14.verts.items.len > 0);
    try testing.expectEqual(z14.verts.items.len, z15.verts.items.len);
    try testing.expectEqualSlices(u32, z14.indices.items, z15.indices.items);
    for (z14.verts.items, z15.verts.items) |a, b| {
        try testing.expectEqual(a.ox, b.ox); // widths are baked px: bit-equal
        try testing.expectEqual(a.oy, b.oy);
        try testing.expectEqual(a.x, b.x * 2); // anchors ride the tile scale
        try testing.expectEqual(a.y, b.y * 2);
        try testing.expectEqual(types.Flags.map_align, a.flags);
    }
}

test "closed ring: wrap segment stroked, seam joined, no caps" {
    var b = Built{};
    defer b.deinit();
    const ring = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 100 } };
    const parts = [_][]const mvt.Point{&ring};
    try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .join = .bevel, .cap = .round, .closed = true });
    // 4 segments (wrap included) + 4 bevel joins, and cap=round adds nothing.
    try testing.expectEqual(@as(usize, 4 * 4 + 4 * 3), b.verts.items.len);
    try testing.expectEqual(@as(usize, 4 * 6 + 4 * 3), b.indices.items.len);
}

test "degenerate lines draw nothing and never crash" {
    var b = Built{};
    defer b.deinit();
    const single = [_]mvt.Point{.{ .x = 5, .y = 5 }};
    const dup = [_]mvt.Point{ .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 } };
    const parts = [_][]const mvt.Point{ &single, &dup, &.{} };
    try b.layout(&parts, 4096.0, 1.0, .{ .width_px = 10, .cap = .round, .join = .round });
    try testing.expectEqual(@as(usize, 0), b.verts.items.len);

    // Zero and negative widths draw nothing.
    const pts = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const parts2 = [_][]const mvt.Point{&pts};
    try b.layout(&parts2, 4096.0, 1.0, .{ .width_px = 0 });
    try b.layout(&parts2, 4096.0, 1.0, .{ .width_px = -3 });
    try testing.expectEqual(@as(usize, 0), b.verts.items.len);

    // A hairpin (exact reversal) must not blow up any join kind.
    const hairpin = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 0, .y = 0 } };
    const parts3 = [_][]const mvt.Point{&hairpin};
    inline for (.{ Join.miter, Join.bevel, Join.round }) |j| {
        var hb = Built{};
        defer hb.deinit();
        try hb.layout(&parts3, 4096.0, 1.0, .{ .width_px = 10, .join = j });
        try testing.expect(hb.verts.items.len >= 8); // both quads present
        for (hb.verts.items) |v| {
            try testing.expect(@abs(v.ox) <= 5.0 + 1e-6); // no unbounded miter
            try testing.expect(@abs(v.oy) <= 5.0 + 1e-6);
        }
    }

    // extent 0 (hostile) is a no-op.
    try layoutLine(testing.allocator, &parts2, 0, 4096.0, 1.0, .{ .width_px = 10 }, &b.verts, &b.indices);
    try testing.expectEqual(@as(usize, 0), b.verts.items.len);
}

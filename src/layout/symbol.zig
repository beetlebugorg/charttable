//! Symbol layout: icons and text into the scene's Quad stream. Anchors are
//! tile-local world positions; corner offsets are reference px added after
//! projection, so a symbol holds its screen size while its anchor rides the
//! map (the scene contract in scene/types.zig). Rotation is baked into the
//! offsets; map-aligned symbols additionally set the map_align flag so a
//! turning view rotates them.
//!
//! Text shaping here is the chart subset: runs of glyphs from a fontnik SDF
//! atlas (EM 24 px), scaled to text-size, wrapped at spaces against
//! text-max-width, anchored per the spec's text-anchor vocabulary, offset in
//! em units. Vertical text and BiDi are later work.
//!
//! `placeAlongLine` is the spec's symbol-placement "line"/"line-center": the
//! arc-length walk ports tile57 scene/linestyle.zig (lsPointAndTangent /
//! drawComplexRun's period loop), including its half-open tile ownership rule
//! — an anchor in the buffer overhang belongs to exactly one tile, or every
//! seam draws the symbol twice.

const std = @import("std");
const types = @import("../scene/types.zig");
const sprites = @import("../symbol/sprite.zig");
const glyphs = @import("../symbol/glyphs.zig");
const mvt = @import("../source/mvt.zig");

/// Fontnik rasterization EM in atlas pixels (tile57 bakes at 24).
pub const glyph_em_px: f32 = 24.0;

pub const Anchor = enum {
    center,
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_left,
    bottom_right,

    pub fn parse(s: []const u8) ?Anchor {
        const table = std.StaticStringMap(Anchor).initComptime(.{
            .{ "center", .center },             .{ "left", .left },
            .{ "right", .right },               .{ "top", .top },
            .{ "bottom", .bottom },             .{ "top-left", .top_left },
            .{ "top-right", .top_right },       .{ "bottom-left", .bottom_left },
            .{ "bottom-right", .bottom_right },
        });
        return table.get(s);
    }
};

pub const Common = struct {
    /// Tile-local world anchor.
    x: f32,
    y: f32,
    /// Rotation baked into the corner offsets, degrees clockwise.
    rotate_deg: f32 = 0,
    /// Offsets stated in the map frame (rotate with the view).
    map_align: bool = false,
    /// Line-following text: let the shader turn the offsets 180° about the
    /// anchor when the run would read into the screen's left half-plane
    /// (the Quad.flip contract in scene/types.zig).
    flip: bool = false,
    /// The run's angle for that test, in /256 turns. Unused when flip is off.
    tangent_q: u8 = 0,
    zmin: u16 = types.ZMIN_ALL,
    zmax: u16 = types.ZMAX_ALL,
    depth: f32 = 0,
};

/// An angle (radians, y-down) as the Quad contract's /256 turns.
pub fn tangentQ(angle_rad: f32) u8 {
    const turns = angle_rad / (2.0 * std.math.pi);
    const wrapped = turns - @floor(turns); // [0, 1)
    return @intFromFloat(@min(255.0, wrapped * 256.0));
}

/// The screen-space box a placement occupies, reference px around the
/// projected anchor — what the collision pass tests.
pub const Box = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

fn rot(deg: f32, ox: f32, oy: f32) [2]f32 {
    if (deg == 0) return .{ ox, oy };
    const r = deg * std.math.pi / 180.0;
    const c = @cos(r);
    const s = @sin(r);
    return .{ c * ox - s * oy, s * ox + c * oy };
}

fn emitQuad(
    gpa: std.mem.Allocator,
    quads: *std.ArrayList(types.Quad),
    common: Common,
    // unrotated corner rect in reference px, y down
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    uv: [4]f32, // u0 v0 u1 v1
    weight: f32,
) !void {
    const flags: u8 = if (common.map_align) types.Flags.map_align else 0;
    const corners = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    const uvs = [4][2]f32{ .{ uv[0], uv[1] }, .{ uv[2], uv[1] }, .{ uv[2], uv[3] }, .{ uv[0], uv[3] } };
    const order = [6]u8{ 0, 1, 2, 0, 2, 3 };
    try quads.ensureUnusedCapacity(gpa, 6);
    for (order) |ci| {
        const o = rot(common.rotate_deg, corners[ci][0], corners[ci][1]);
        quads.appendAssumeCapacity(.{
            .x = common.x,
            .y = common.y,
            .ox = o[0],
            .oy = o[1],
            .u = uvs[ci][0],
            .v = uvs[ci][1],
            .weight = weight,
            .zmin = common.zmin,
            .zmax = common.zmax,
            .flags = flags,
            .flip = @intFromBool(common.flip),
            .tangent_q = common.tangent_q,
            .depth = common.depth,
        });
    }
}

/// One icon: six quad vertices centered on the anchor (spec default
/// icon-anchor center), scaled by icon-size / the sprite's pixel ratio.
/// Returns the screen-space box for collision.
pub fn layoutIcon(
    gpa: std.mem.Allocator,
    icon: sprites.Icon,
    size_mult: f32,
    common: Common,
    quads: *std.ArrayList(types.Quad),
) !Box {
    const w = @as(f32, @floatFromInt(icon.w)) / icon.pixel_ratio * size_mult;
    const h = @as(f32, @floatFromInt(icon.h)) / icon.pixel_ratio * size_mult;
    const x0 = -w * 0.5;
    const y0 = -h * 0.5;
    try emitQuad(gpa, quads, common, x0, y0, x0 + w, y0 + h, .{ icon.u0, icon.v0, icon.u1, icon.v1 }, 0);
    return .{ .x0 = x0, .y0 = y0, .x1 = x0 + w, .y1 = y0 + h };
}

pub const TextOpts = struct {
    size_px: f32 = 16,
    anchor: Anchor = .center,
    /// Spec text-offset, in ems of text-size.
    offset_em: [2]f32 = .{ 0, 0 },
    /// SDF embolden (halo handled by the draw's color).
    weight: f32 = 0,
    /// Spec text-max-width, ems: the greedy wrap point. 0 never wraps.
    max_width_em: f32 = 10,
};

/// Spec text-line-height's default, ems. Not a tier-1 property (no chart
/// style sets it), so the default is the whole implementation.
pub const line_height_em: f32 = 1.2;

/// A wrapped run is at most this many lines; the rest is dropped. A chart
/// label that wants more than eight lines is a data bug, not a label.
const max_lines = 8;

const Metrics = struct { width: f32, ascent: f32, descent: f32, inked: bool };

/// Advance width and ink extents of one line, in px at `scale`. Codepoints
/// missing from the atlas advance by half an em (the tofu-free chart
/// convention).
fn measure(text: []const u8, atlas: *const glyphs.GlyphAtlas, scale: f32) Metrics {
    var m = Metrics{ .width = 0, .ascent = 0, .descent = 0, .inked = false };
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        const g = atlas.get(cp) orelse {
            m.width += glyph_em_px * 0.5 * scale;
            continue;
        };
        m.width += g.advance * scale;
        if (g.h > 0) {
            m.ascent = @max(m.ascent, g.top * scale);
            m.descent = @max(m.descent, (g.h - 2 * @as(f32, @floatFromInt(glyphs.buffer_px)) - g.top) * scale);
            m.inked = true;
        }
    }
    return m;
}

/// Break `text` into display lines: hard breaks at "\n", then a greedy wrap
/// at spaces against `max_px`. A single word wider than the limit stays on
/// its own line (never split mid-word). Lines are slices of `text`.
fn wrapLines(
    text: []const u8,
    atlas: *const glyphs.GlyphAtlas,
    scale: f32,
    max_px: f32,
    out: *[max_lines][]const u8,
) usize {
    var n: usize = 0;
    var para_it = std.mem.splitScalar(u8, text, '\n');
    while (para_it.next()) |para| {
        if (n == max_lines) break;
        if (max_px <= 0) {
            out[n] = para;
            n += 1;
            continue;
        }
        var start: usize = 0; // line start in `para`
        var last_break: ?usize = null; // index of the last space seen after `start`
        var i: usize = 0;
        while (i <= para.len) : (i += 1) {
            const at_end = i == para.len;
            if (!at_end and para[i] != ' ') continue;
            // `para[start..i]` is the line with one more word on it.
            if (measure(para[start..i], atlas, scale).width > max_px) {
                if (last_break) |b| {
                    if (n == max_lines) return n;
                    out[n] = para[start..b];
                    n += 1;
                    start = b + 1;
                    last_break = null;
                    // Re-test the tail against the limit on the next word.
                }
            }
            if (!at_end) last_break = i;
        }
        if (n == max_lines) break;
        out[n] = para[start..];
        n += 1;
    }
    return n;
}

/// Shape text into SDF glyph quads: wrapped lines stacked at
/// `line_height_em`, the block anchored per the spec's text-anchor
/// vocabulary. Returns the block's collision box, or null when nothing
/// inked.
pub fn layoutText(
    gpa: std.mem.Allocator,
    text: []const u8,
    atlas: *const glyphs.GlyphAtlas,
    opts: TextOpts,
    common: Common,
    quads: *std.ArrayList(types.Quad),
) !?Box {
    const scale = opts.size_px / glyph_em_px;
    const em = opts.size_px;

    var lines: [max_lines][]const u8 = undefined;
    const n_lines = wrapLines(text, atlas, scale, opts.max_width_em * em, &lines);
    if (n_lines == 0) return null;

    var mets: [max_lines]Metrics = undefined;
    var any = false;
    var widest: f32 = 0;
    for (lines[0..n_lines], 0..) |ln, i| {
        mets[i] = measure(ln, atlas, scale);
        if (mets[i].inked) any = true;
        widest = @max(widest, mets[i].width);
    }
    if (!any or widest <= 0) return null;

    // The block: first baseline at `ascent` below its top, each next one a
    // line height further down.
    const lh = line_height_em * em;
    const ascent = mets[0].ascent;
    const descent = mets[n_lines - 1].descent;
    const height = @as(f32, @floatFromInt(n_lines - 1)) * lh + ascent + descent;

    // Anchor: where the anchor point sits ON the block.
    const top: f32 = switch (opts.anchor) {
        .top, .top_left, .top_right => 0,
        .bottom, .bottom_left, .bottom_right => -height,
        else => -height * 0.5,
    } + opts.offset_em[1] * em;
    const ox = opts.offset_em[0] * em;

    var box = Box{ .x0 = std.math.floatMax(f32), .y0 = top, .x1 = -std.math.floatMax(f32), .y1 = top + height };
    for (lines[0..n_lines], 0..) |ln, li| {
        const m = mets[li];
        // The pen starts at this line's left edge, on its baseline.
        const dx: f32 = ox + switch (opts.anchor) {
            .left, .top_left, .bottom_left => 0,
            .right, .top_right, .bottom_right => -m.width,
            else => -m.width * 0.5,
        };
        const dy: f32 = top + ascent + @as(f32, @floatFromInt(li)) * lh;
        box.x0 = @min(box.x0, dx);
        box.x1 = @max(box.x1, dx + m.width);

        var pen: f32 = 0;
        var it = std.unicode.Utf8View.initUnchecked(ln).iterator();
        while (it.nextCodepoint()) |cp| {
            const g = atlas.get(cp) orelse {
                pen += glyph_em_px * 0.5 * scale;
                continue;
            };
            if (g.h > 0) {
                const buf: f32 = @floatFromInt(glyphs.buffer_px);
                // The padded SDF cell, positioned by the unpadded ink metrics.
                const gx0 = dx + pen + (g.left - buf) * scale;
                const gy0 = dy - (g.top + buf) * scale;
                const gw = g.w * scale;
                const gh = g.h * scale;
                try emitQuad(gpa, quads, common, gx0, gy0, gx0 + gw, gy0 + gh, .{ g.u0, g.v0, g.u1, g.v1 }, opts.weight);
            }
            pen += g.advance * scale;
        }
    }
    return box;
}

// ---- symbol-placement: line / line-center ----------------------------------

/// One anchor found along a line: tile-local world position and the local
/// tangent angle (radians, atan2(dy, dx) in the tile's y-down frame).
pub const Placement = struct {
    x: f64,
    y: f64,
    angle: f32,
};

pub const LineOpts = struct {
    /// Spec symbol-spacing: reference px between anchors.
    spacing_px: f64 = 250,
    /// Reference px per tile-local world unit at the build's zoom. Arc
    /// length is measured in px because spacing is: the same line yields
    /// more anchors as the view zooms in (layout/line.zig does this for
    /// dashes through the same channel).
    px_per_unit: f64,
    /// Spec "line-center": one anchor at each part's arc midpoint instead of
    /// a spaced walk.
    center: bool = false,
    /// Spec text-max-angle, degrees: skip an anchor whose window turns by
    /// more than this in total. 0 disables the test.
    max_angle_deg: f32 = 0,
    /// The arc window that test measures, reference px — the label's own
    /// width. 0 with a max angle set measures the two segments at the anchor.
    window_px: f64 = 0,
    /// Tile ownership: anchors outside [0, tile_span) in the tile's own frame
    /// belong to the neighbour. Half-open, so a symbol on the seam is drawn
    /// by exactly one side — no gap, no double (tile57's rule; without it
    /// every tile boundary draws its buffer-zone symbols twice).
    tile_span: f64 = 0,
};

const Pt = struct { x: f64, y: f64 };

/// Point and (un-normalized) tangent at arc distance `d` px along the walk.
fn atArc(pts: []const Pt, arc: []const f64, d: f64) ?Placement {
    if (pts.len < 2) return null;
    const total = arc[arc.len - 1];
    const dd = std.math.clamp(d, 0, total);
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        if (dd <= arc[i + 1] or i + 2 == pts.len) {
            const seg = arc[i + 1] - arc[i];
            const t: f64 = if (seg > 1e-12) (dd - arc[i]) / seg else 0;
            const dx = pts[i + 1].x - pts[i].x;
            const dy = pts[i + 1].y - pts[i].y;
            return .{
                .x = pts[i].x + t * dx,
                .y = pts[i].y + t * dy,
                .angle = @floatCast(std.math.atan2(dy, dx)),
            };
        }
    }
    return null;
}

/// Total absolute turn (radians) of the polyline inside the arc window
/// centered on `d`. The spec states text-max-angle as the change "between
/// adjacent characters"; measuring the label's whole window is the same test
/// for the curvature that actually breaks a label, and needs no per-glyph
/// placement pass.
fn turnWithin(pts: []const Pt, arc: []const f64, d: f64, window: f64) f64 {
    const lo = d - window * 0.5;
    const hi = d + window * 0.5;
    var total: f64 = 0;
    var prev: ?f64 = null;
    for (0..pts.len - 1) |i| {
        if (arc[i + 1] < lo or arc[i] > hi) continue;
        const dx = pts[i + 1].x - pts[i].x;
        const dy = pts[i + 1].y - pts[i].y;
        if (dx == 0 and dy == 0) continue;
        const a = std.math.atan2(dy, dx);
        if (prev) |p| {
            var turn = a - p;
            while (turn > std.math.pi) turn -= 2 * std.math.pi;
            while (turn < -std.math.pi) turn += 2 * std.math.pi;
            total += @abs(turn);
        }
        prev = a;
    }
    return total;
}

/// Walk a feature's parts by arc length and collect symbol anchors: the
/// spec's symbol-placement "line" (every symbol-spacing px) and
/// "line-center" (one anchor per part, at its midpoint).
///
/// The first anchor of a spaced walk sits half a spacing in, so a decorated
/// boundary starts inside its own run rather than on the endpoint; a part too
/// short for even that still gets one anchor at its midpoint, which is what
/// keeps short restricted-area edges decorated.
pub fn placeAlongLine(
    gpa: std.mem.Allocator,
    parts: []const []const mvt.Point,
    extent: u32,
    tile_span: f64,
    opts: LineOpts,
    out: *std.ArrayList(Placement),
) std.mem.Allocator.Error!void {
    if (extent == 0 or !(opts.px_per_unit > 0)) return;
    const scale = tile_span / @as(f64, @floatFromInt(extent));
    const eps = tile_span * 1e-12;

    var pts: std.ArrayList(Pt) = .empty;
    defer pts.deinit(gpa);
    var arc: std.ArrayList(f64) = .empty;
    defer arc.deinit(gpa);

    for (parts) |part| {
        if (part.len < 2) continue;
        pts.clearRetainingCapacity();
        for (part) |ip| {
            const w = Pt{
                .x = @as(f64, @floatFromInt(ip.x)) * scale,
                .y = @as(f64, @floatFromInt(ip.y)) * scale,
            };
            if (pts.items.len > 0) {
                const p = pts.items[pts.items.len - 1];
                if (@abs(p.x - w.x) <= eps and @abs(p.y - w.y) <= eps) continue;
            }
            try pts.append(gpa, w);
        }
        if (pts.items.len < 2) continue;

        arc.clearRetainingCapacity();
        try arc.ensureUnusedCapacity(gpa, pts.items.len);
        arc.appendAssumeCapacity(0);
        var total: f64 = 0;
        for (pts.items[1..], 0..) |q, k| {
            const p = pts.items[k];
            total += std.math.hypot(q.x - p.x, q.y - p.y) * opts.px_per_unit;
            arc.appendAssumeCapacity(total);
        }
        if (!(total > 0)) continue;

        const spacing = @max(1.0, opts.spacing_px);
        // Anchors this part offers, by arc distance.
        var d: f64 = if (opts.center or total < spacing * 0.5) total * 0.5 else spacing * 0.5;
        const step: f64 = if (opts.center or total < spacing * 0.5) std.math.inf(f64) else spacing;
        while (d <= total) : (d += step) {
            const p = atArc(pts.items, arc.items, d) orelse break;
            if (opts.tile_span > 0) {
                // Half-open ownership in the tile's own frame.
                if (p.x < 0 or p.x >= opts.tile_span or p.y < 0 or p.y >= opts.tile_span) continue;
            }
            if (opts.max_angle_deg > 0) {
                const window = if (opts.window_px > 0) opts.window_px else spacing;
                const limit = @as(f64, opts.max_angle_deg) * std.math.pi / 180.0;
                if (turnWithin(pts.items, arc.items, d, window) > limit) continue;
            }
            try out.append(gpa, p);
        }
    }
}

/// Screen-space collision grid: place-or-reject for symbol boxes projected
/// to reference px at build time. Cheap and exact enough for one scene; a
/// rotation-aware frame-rate placement pass is later work (DESIGN.md).
pub const Collider = struct {
    const CELL: f32 = 64;
    gpa: std.mem.Allocator,
    cells: std.AutoHashMap(u64, std.ArrayList(Box)),

    pub fn init(gpa: std.mem.Allocator) Collider {
        return .{ .gpa = gpa, .cells = std.AutoHashMap(u64, std.ArrayList(Box)).init(gpa) };
    }

    fn key(cx: i32, cy: i32) u64 {
        return (@as(u64, @bitCast(@as(i64, cx))) << 32) ^ @as(u32, @bitCast(cy));
    }

    fn overlaps(a: Box, b: Box) bool {
        return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1;
    }

    /// True (and records the box) when `box` fits without overlap.
    /// `ignore_placement` boxes never block others: check but don't record.
    pub fn place(self: *Collider, box: Box, allow_overlap: bool, ignore_placement: bool) !bool {
        const cx0: i32 = @intFromFloat(@floor(box.x0 / CELL));
        const cy0: i32 = @intFromFloat(@floor(box.y0 / CELL));
        const cx1: i32 = @intFromFloat(@floor(box.x1 / CELL));
        const cy1: i32 = @intFromFloat(@floor(box.y1 / CELL));
        if (!allow_overlap) {
            var cy = cy0;
            while (cy <= cy1) : (cy += 1) {
                var cx = cx0;
                while (cx <= cx1) : (cx += 1) {
                    const cell = self.cells.get(key(cx, cy)) orelse continue;
                    for (cell.items) |b| {
                        if (overlaps(box, b)) return false;
                    }
                }
            }
        }
        if (!ignore_placement) {
            var cy = cy0;
            while (cy <= cy1) : (cy += 1) {
                var cx = cx0;
                while (cx <= cx1) : (cx += 1) {
                    const gop = try self.cells.getOrPut(key(cx, cy));
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.gpa, box);
                }
            }
        }
        return true;
    }

    pub fn deinit(self: *Collider) void {
        var it = self.cells.valueIterator();
        while (it.next()) |cell| cell.deinit(self.gpa);
        self.cells.deinit();
    }
};

// ---- tests -----------------------------------------------------------------

test "icon quads: centered, scaled, rotated, map-aligned" {
    var quads: std.ArrayList(types.Quad) = .empty;
    defer quads.deinit(std.testing.allocator);
    const icon = sprites.Icon{ .u0 = 0, .v0 = 0, .u1 = 0.5, .v1 = 0.5, .w = 32, .h = 16, .pixel_ratio = 2 };
    const box = try layoutIcon(std.testing.allocator, icon, 2.0, .{ .x = 0.5, .y = 0.5, .map_align = true }, &quads);
    try std.testing.expectEqual(@as(usize, 6), quads.items.len);
    // 32px/ratio2*size2 = 32 wide, 16 tall, centered
    try std.testing.expectApproxEqAbs(@as(f32, -16), box.x0, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 16), box.x1, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -8), box.y0, 1e-5);
    try std.testing.expect(quads.items[0].flags & types.Flags.map_align != 0);
    // rotation turns the offsets, not the anchor
    var rq: std.ArrayList(types.Quad) = .empty;
    defer rq.deinit(std.testing.allocator);
    _ = try layoutIcon(std.testing.allocator, icon, 2.0, .{ .x = 0.5, .y = 0.5, .rotate_deg = 90 }, &rq);
    try std.testing.expectApproxEqAbs(quads.items[0].ox, rq.items[0].oy, 1e-4);
    try std.testing.expectApproxEqAbs(quads.items[0].x, rq.items[0].x, 1e-6);
}

test "wrapLines: hard breaks, greedy wrap, and an unsplittable word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var atlas = try glyphs.GlyphAtlas.init(std.testing.allocator, glyphs.default_width);
    defer atlas.deinit();
    // Nothing is in the atlas, so every codepoint advances half an em: at
    // scale 1 that is 12 px a character.
    var out: [max_lines][]const u8 = undefined;

    // 60 px = five characters to a line.
    var n = wrapLines("aa bb cc dd", &atlas, 1.0, 60, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("aa bb", out[0]);
    try std.testing.expectEqualStrings("cc dd", out[1]);

    // A hard break always breaks, wrap limit or not.
    n = wrapLines("aa\nbb", &atlas, 1.0, 0, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("aa", out[0]);
    try std.testing.expectEqualStrings("bb", out[1]);

    // A word wider than the limit keeps its own line rather than splitting.
    n = wrapLines("aaaaaaaa bb", &atlas, 1.0, 60, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("aaaaaaaa", out[0]);
    try std.testing.expectEqualStrings("bb", out[1]);

    // max_width 0 never wraps.
    n = wrapLines("aa bb cc dd", &atlas, 1.0, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "tangentQ round-trips an angle into /256 turns" {
    try std.testing.expectEqual(@as(u8, 0), tangentQ(0));
    try std.testing.expectEqual(@as(u8, 64), tangentQ(std.math.pi * 0.5));
    try std.testing.expectEqual(@as(u8, 128), tangentQ(std.math.pi));
    // Negative angles wrap into [0, 1) turns rather than saturating at 0.
    try std.testing.expectEqual(@as(u8, 192), tangentQ(-std.math.pi * 0.5));
}

// A horizontal line 4 world units long. px_per_unit 100 makes it 400 px, so
// symbol-spacing 100 px puts anchors at arc 50, 150, 250, 350.
fn testLine(a: std.mem.Allocator, pts: []const [2]i32) ![]const []const mvt.Point {
    const part = try a.alloc(mvt.Point, pts.len);
    for (pts, 0..) |p, i| part[i] = .{ .x = p[0], .y = p[1] };
    const parts = try a.alloc([]const mvt.Point, 1);
    parts[0] = part;
    return parts;
}

test "placeAlongLine: spaced walk, tangent, and the short-line midpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // extent 4096 over a tile_span of 4 world units: 1024 units per world unit.
    const parts = try testLine(a, &.{ .{ 0, 2048 }, .{ 4096, 2048 } });

    var out: std.ArrayList(Placement) = .empty;
    try placeAlongLine(a, parts, 4096, 4.0, .{
        .spacing_px = 100,
        .px_per_unit = 100,
    }, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), out.items[0].x, 1e-9); // 50 px in
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), out.items[1].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), out.items[0].y, 1e-9);
    for (out.items) |p| try std.testing.expectApproxEqAbs(@as(f32, 0), p.angle, 1e-6);

    // Zooming in doubles the arc length in px, so the same line takes twice
    // the anchors: spacing is a SCREEN distance, not a geometry one.
    out.clearRetainingCapacity();
    try placeAlongLine(a, parts, 4096, 4.0, .{ .spacing_px = 100, .px_per_unit = 200 }, &out);
    try std.testing.expectEqual(@as(usize, 8), out.items.len);

    // A line too short for even the half-spacing lead-in still decorates,
    // once, at its midpoint.
    out.clearRetainingCapacity();
    try placeAlongLine(a, parts, 4096, 4.0, .{ .spacing_px = 10000, .px_per_unit = 100 }, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), out.items[0].x, 1e-9);

    // line-center: one anchor per part at its arc midpoint.
    out.clearRetainingCapacity();
    try placeAlongLine(a, parts, 4096, 4.0, .{ .spacing_px = 100, .px_per_unit = 100, .center = true }, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), out.items[0].x, 1e-9);
}

test "placeAlongLine: tangent follows the segment, tile ownership is half-open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Straight down the tile: tangent is +pi/2 in the y-down frame.
    const down = try testLine(a, &.{ .{ 2048, 0 }, .{ 2048, 4096 } });
    var out: std.ArrayList(Placement) = .empty;
    try placeAlongLine(a, down, 4096, 4.0, .{ .spacing_px = 100, .px_per_unit = 100 }, &out);
    try std.testing.expect(out.items.len > 0);
    for (out.items) |p| try std.testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.5), p.angle, 1e-6);

    // Geometry in the buffer overhang (negative x) belongs to the neighbour
    // when ownership is on: without the test the seam draws it twice.
    const over = try testLine(a, &.{ .{ -2048, 2048 }, .{ 0, 2048 } });
    out.clearRetainingCapacity();
    try placeAlongLine(a, over, 4096, 4.0, .{ .spacing_px = 100, .px_per_unit = 100, .tile_span = 4.0 }, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    out.clearRetainingCapacity();
    try placeAlongLine(a, over, 4096, 4.0, .{ .spacing_px = 100, .px_per_unit = 100 }, &out);
    try std.testing.expect(out.items.len > 0); // ownership off: the walk still finds them
}

test "placeAlongLine: text-max-angle skips a hairpin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Out and back: a 180-degree turn at the midpoint.
    const hairpin = try testLine(a, &.{ .{ 0, 2048 }, .{ 4096, 2048 }, .{ 0, 2050 } });
    var out: std.ArrayList(Placement) = .empty;
    try placeAlongLine(a, hairpin, 4096, 4.0, .{
        .spacing_px = 100,
        .px_per_unit = 100,
        .center = true,
        .max_angle_deg = 30,
        .window_px = 200,
    }, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    // The same midpoint places once the limit admits the turn.
    out.clearRetainingCapacity();
    try placeAlongLine(a, hairpin, 4096, 4.0, .{
        .spacing_px = 100,
        .px_per_unit = 100,
        .center = true,
        .max_angle_deg = 0,
    }, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "collider: overlap rejected, allow-overlap passes, ignored boxes don't block" {
    var c = Collider.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(try c.place(.{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }, false, false));
    try std.testing.expect(!try c.place(.{ .x0 = 5, .y0 = 5, .x1 = 15, .y1 = 15 }, false, false));
    try std.testing.expect(try c.place(.{ .x0 = 5, .y0 = 5, .x1 = 15, .y1 = 15 }, true, true));
    try std.testing.expect(try c.place(.{ .x0 = 20, .y0 = 0, .x1 = 30, .y1 = 10 }, false, false));
    // an ignore-placement box was not recorded: this spot is free
    try std.testing.expect(try c.place(.{ .x0 = 12, .y0 = 12, .x1 = 14, .y1 = 14 }, false, false));
}

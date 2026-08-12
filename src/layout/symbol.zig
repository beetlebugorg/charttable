//! Symbol layout: icons and text into the scene's Quad stream. Anchors are
//! tile-local world positions; corner offsets are reference px added after
//! projection, so a symbol holds its screen size while its anchor rides the
//! map (the scene contract in scene/types.zig). Rotation is baked into the
//! offsets; map-aligned symbols additionally set the map_align flag so a
//! turning view rotates them.
//!
//! Text shaping here is the chart subset: single-line runs of glyphs from a
//! fontnik SDF atlas (EM 24 px), scaled to text-size, anchored per the
//! spec's text-anchor vocabulary, offset in em units. Line breaking,
//! vertical text, and BiDi are later work.

const std = @import("std");
const types = @import("../scene/types.zig");
const sprites = @import("../symbol/sprite.zig");
const glyphs = @import("../symbol/glyphs.zig");

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
    zmin: u16 = types.ZMIN_ALL,
    zmax: u16 = types.ZMAX_ALL,
    depth: f32 = 0,
};

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
            .flip = 0,
            .tangent_q = 0,
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
};

/// Shape one line of text into SDF glyph quads. Codepoints missing from the
/// atlas advance by half an em (the tofu-free chart convention). Returns
/// the collision box, or null when nothing inked.
pub fn layoutText(
    gpa: std.mem.Allocator,
    text: []const u8,
    atlas: *const glyphs.GlyphAtlas,
    opts: TextOpts,
    common: Common,
    quads: *std.ArrayList(types.Quad),
) !?Box {
    const scale = opts.size_px / glyph_em_px;

    // Measure the run first: advance width and the ink ascent/descent.
    var width: f32 = 0;
    var ascent: f32 = 0;
    var descent: f32 = 0;
    var any = false;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (atlas.get(cp)) |g| {
            width += g.advance * scale;
            if (g.h > 0) {
                ascent = @max(ascent, g.top * scale);
                descent = @max(descent, (g.h - 2 * @as(f32, @floatFromInt(glyphs.buffer_px)) - g.top) * scale);
                any = true;
            }
        } else {
            width += glyph_em_px * 0.5 * scale;
        }
    }
    if (!any or width <= 0) return null;

    // Anchor: where the anchor point sits ON the text box. The pen starts
    // at the box's left edge on the baseline.
    const em = opts.size_px;
    var dx: f32 = switch (opts.anchor) {
        .left, .top_left, .bottom_left => 0,
        .right, .top_right, .bottom_right => -width,
        else => -width * 0.5,
    };
    var dy: f32 = switch (opts.anchor) {
        .top, .top_left, .top_right => ascent,
        .bottom, .bottom_left, .bottom_right => -descent,
        else => (ascent - descent) * 0.5,
    };
    dx += opts.offset_em[0] * em;
    dy += opts.offset_em[1] * em;

    var pen: f32 = 0;
    it = std.unicode.Utf8View.initUnchecked(text).iterator();
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
    return .{ .x0 = dx, .y0 = dy - ascent, .x1 = dx + width, .y1 = dy + descent };
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

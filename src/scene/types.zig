//! The GPU scene contract: the POD types every layout stage emits and every
//! backend draws. Informed by the battle-tested lookout/tile57 layouts (the
//! world-anchor + screen-offset split, map_align, paint-order depth), and
//! generalized for a style-spec renderer:
//!
//! - Geometry is TILE-LOCAL: positions are world units relative to the tile's
//!   NW corner, drawn with a per-tile matrix (Camera.mvpOrigin). Absolute
//!   world f32 quantizes visibly at depth; small values keep f32 exact.
//! - The S-52 gates (scamin, disp_cat) become a generic per-vertex zoom
//!   visibility window [zmin, zmax]. Zoom-only filter conjuncts bake into it
//!   at layout, the shader compares against the frame's fractional zoom, and
//!   a zoom change never re-runs layout. Quantized to 1/256 zoom steps.
//! - Paint is a SEPARATE stream. Stream A (Vertex/Quad) is geometry and
//!   never changes for a paint-only restyle; stream B (PaintVertex) is what
//!   a palette flip or setPaintProperty re-evaluates and re-uploads.
//!
//! Layout invariants a backend must keep (the vertex/uniform contract):
//! - (x, y) is transformed by the camera; (ox, oy) is added AFTER projection
//!   in reference px. That split is what keeps a symbol a constant screen
//!   size while its anchor rides the map, with no re-tessellation on zoom.
//! - map_align set means (ox, oy) is stated in the MAP frame: a rotated view
//!   must turn it by (rot_sin, rot_cos). A line edge always sets it — leave
//!   it and the pen shears to |cos(rotation)| of its width.
//! - depth: later paint = smaller. Opaque ranges may draw front-to-back with
//!   depth write as a pure optimization; everything else draws in paint
//!   order, test only. 0 always passes.

const std = @import("std");

/// Quantized fractional zoom for the per-vertex visibility window:
/// zoom * 256, saturating. u16 spans zoom 0..255 at 1/256 steps.
pub fn zq(zoom: f64) u16 {
    if (zoom <= 0) return 0;
    const q = zoom * 256.0;
    if (q >= 65535.0) return 65535;
    return @intFromFloat(q);
}

/// The always-visible window.
pub const ZMIN_ALL: u16 = 0;
pub const ZMAX_ALL: u16 = 65535;

pub const Flags = struct {
    /// (ox, oy) is stated in the map frame; the shader must rotate it.
    pub const map_align: u8 = 1 << 0;
};

/// One triangle vertex (stream A). 28 bytes.
pub const Vertex = extern struct {
    x: f32, // tile-local world units (world - tile NW corner)
    y: f32,
    ox: f32, // screen-space offset, reference px, added after projection
    oy: f32,
    zmin: u16, // visible while zmin <= zq(zoom) <= zmax
    zmax: u16,
    flags: u8, // Flags.*
    _pad: [3]u8 = .{ 0, 0, 0 },
    depth: f32, // paint-order depth in (0,1): later paint = smaller
};

/// One textured-quad vertex (stream A): a sprite or an SDF glyph. Six per
/// quad (two triangles), non-indexed. 40 bytes.
///
/// flip / tangent_q keep a line-following text run upright: when flip is
/// set, the shader negates (ox, oy) — a 180° turn about the anchor — for
/// vertices whose run, once the view rotation is added, would read into the
/// screen's left half-plane (cos(angle + view_rotation) < 0), where
/// angle = tangent_q / 256 * 2π. flip=0 leaves tangent_q unused.
pub const Quad = extern struct {
    x: f32, // tile-local anchor
    y: f32,
    ox: f32, // corner offset, reference px, already rotated to the glyph run
    oy: f32,
    u: f32, // atlas UV [0,1]
    v: f32,
    weight: f32, // SDF sharpen: 0 for a sprite, >0 emboldens a glyph
    zmin: u16,
    zmax: u16,
    flags: u8,
    flip: u8,
    tangent_q: u8,
    _pad: u8 = 0,
    depth: f32,
};

/// Stream B: evaluated paint, one per stream-A vertex (triangle vertices and
/// quad vertices each get their own stream-B buffer). Straight alpha. A
/// sprite ignores it; an SDF glyph tints by it. Grows as paint properties
/// move here (width multipliers, zoom-interpolated pairs) — today color is
/// the whole stream.
pub const PaintVertex = extern struct {
    color: [4]u8,
};

/// What a range draws — picks a pipeline, never the order. Order is
/// paint_key alone.
pub const Kind = enum(u8) {
    area = 0,
    pattern = 1,
    line = 2,
    symbol = 3,
    text = 4,
    raster = 5,
};

pub const Prim = enum(u8) {
    triangles = 0, // range.first/count index the index buffer
    quads = 1, // range.first/count are quad-buffer vertices (6 per quad)
};

/// Which atlas texture a quads range samples.
pub const Atlas = enum(u8) {
    none = 0,
    sprite = 1,
    glyph = 2,
    glyph_bold = 3,
    glyph_italic = 4,
};

pub const AtlasBit = struct {
    pub fn bit(a: Atlas) u8 {
        return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(a)));
    }
};

/// The five pipelines. One enum for every backend — Metal folding raster
/// into sprite or D3D12 keeping it separate is a backend detail; the
/// classification is shared.
pub const Pipeline = enum(u8) {
    fill = 0, // flat-colour triangles, colour per stream-B vertex
    pattern = 1, // area fill tiled from a pattern cell
    sprite = 2, // symbol quads from the sprite atlas
    sdf = 3, // SDF glyph quads with halo tiers
    raster = 4, // world-space textured quads (raster sources)
};

pub const NO_PATTERN: u32 = 0xFFFF_FFFF;

/// One image the scene carries its own texture for, indexed by Range.pattern.
///
/// Two uses, same table: an area-fill PATTERN cell (w and h ARE the on-screen
/// period in device px; the host tiles it per fragment, phase-anchored to the
/// WORLD origin so it rides the map under a pan instead of swimming), and a
/// RASTER tile (the whole image mapped once across its quad, sampled 0..1).
pub const PatternCell = struct {
    w: u32,
    h: u32,
    rgba: []const u8,
};

/// A contiguous slice of ONE buffer drawing with ONE pipeline. Ranges are
/// sorted by paint_key (opaque — compare, never decode); draw them in order
/// and the frame is correct.
pub const Range = extern struct {
    first: u32, // into indices (triangles) or quad vertices (quads)
    count: u32,
    paint_key: u32,
    pattern: u32 = NO_PATTERN, // into the scene's patterns, pattern ranges only
    kind: Kind,
    prim: Prim,
    atlas: Atlas = .none,
    flags: u8 = 0, // FLAG_*
    /// The SDF halo color for a text range, straight-alpha RGBA, valid only
    /// with FLAG_HALO. Without the flag the halo is the scene's effective
    /// background — right for a chart (S-52 halos ARE the background) and the
    /// only sane default for a style that sets no text-halo-color.
    halo: [4]u8 = .{ 0, 0, 0, 0 },

    pub const FLAG_OPAQUE: u8 = 1 << 0;
    pub const FLAG_HALO: u8 = 1 << 1;
};

/// Per-frame host state the batch classification depends on. Zero-init is
/// NOT the default — it would claim no atlases uploaded.
pub const BatchOpts = struct {
    /// Host draws opaque triangle ranges in its own depth pre-pass first.
    exclude_opaque_tris: bool = false,
    /// Bit per Atlas the host actually uploaded (AtlasBit.bit). A quads
    /// range whose atlas is missing falls back: bold/italic → glyph;
    /// glyph/sprite missing entirely → the range is dropped.
    atlas_have: u8,
    /// SDF halo background (the style's effective background), premixed.
    halo: [4]f32,
};

/// One draw call. first/count index the same buffers Range does; a merged
/// draw is a wider slice. The two uniform fields are the only parts of the
/// block that vary per draw.
pub const Draw = extern struct {
    first: u32,
    count: u32,
    prim: Prim,
    pipeline: Pipeline,
    atlas: Atlas, // AFTER the missing-tier fallback
    _pad: u8 = 0,
    pattern: u32, // look up YOUR cell texture; derive cell_px from its size
    color: [4]f32, // the uniform's color (halo on SDF draws)
};

/// The per-draw uniform block the shaders read, byte for byte. The layout is
/// not the host's to choose: it is the other half of the vertex contract.
/// std140 and C agree on this order: color at byte 96, the block 128 bytes.
pub const Uniforms = extern struct {
    mvp: [16]f32, // column-major tile-local -> clip (Camera.mvpOrigin)
    px_to_clip: [2]f32, // reference-px -> clip delta (the ox/oy channel)
    size_scale: f32, // pixel density x symbol size multiplier
    zoom: f32, // fractional zoom * 256, tested against zmin/zmax
    zoom_t: f32, // fract(zoom): shader-side mix for zoom-interpolated paint
    wrap_x: f32, // camera centre world-x (antimeridian wrap)
    rot_sin: f32,
    rot_cos: f32,
    color: [4]f32, // SDF halo background; SDF fragment stage only
    anchor_px: [2]f32, // pattern phase origin, framebuffer px
    cell_px: [2]f32, // pattern cell period, framebuffer px
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 28);
    std.debug.assert(@sizeOf(Quad) == 40);
    std.debug.assert(@sizeOf(PaintVertex) == 4);
    std.debug.assert(@sizeOf(Range) == 24);
    std.debug.assert(@sizeOf(Uniforms) == 128);
    std.debug.assert(@offsetOf(Uniforms, "color") == 96);
    std.debug.assert(@offsetOf(Uniforms, "anchor_px") == 112);
}

/// Layout guard: packs the sizes the shaders and backends assume so an ABI
/// or struct-layout skew fails loudly at open instead of shading wrong.
pub fn abiLayout() u32 {
    return @sizeOf(Vertex) | (@as(u32, @sizeOf(Quad)) << 8) |
        (@as(u32, @sizeOf(Range)) << 16) | (@as(u32, @sizeOf(Uniforms)) << 24);
}

// The GLSL in shaders/vk declares these offsets by hand (there is no vertex
// descriptor generated from this file), and so does every backend that binds
// the streams. A silent drift here shades wrong rather than failing, so pin
// them: shaders/vk/README.md carries the same table.
test "vertex attribute offsets match what the shaders declare" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Vertex, "x"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Vertex, "ox"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Vertex, "zmin"));
    try std.testing.expectEqual(@as(usize, 18), @offsetOf(Vertex, "zmax"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Vertex, "flags"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Vertex, "depth"));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Quad, "x"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Quad, "ox"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Quad, "u"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Quad, "weight"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Quad, "zmin"));
    try std.testing.expectEqual(@as(usize, 30), @offsetOf(Quad, "zmax"));
    // The shaders read one R32_UINT here and unpack it: flags in byte 0,
    // flip in byte 1, tangent_q in byte 2.
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Quad, "flags"));
    try std.testing.expectEqual(@as(usize, 33), @offsetOf(Quad, "flip"));
    try std.testing.expectEqual(@as(usize, 34), @offsetOf(Quad, "tangent_q"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Quad, "depth"));

    // And the zoom window really is one 32-bit word: zmin low, zmax high.
    const v = Vertex{ .x = 0, .y = 0, .ox = 0, .oy = 0, .zmin = 0x1234, .zmax = 0x5678, .flags = 1, .depth = 0 };
    const word = std.mem.bytesAsValue(u32, std.mem.asBytes(&v)[16..20]).*;
    try std.testing.expectEqual(@as(u32, 0x5678_1234), word);
}

test "zq quantizes and saturates" {
    try std.testing.expectEqual(@as(u16, 0), zq(-1.0));
    try std.testing.expectEqual(@as(u16, 0), zq(0.0));
    try std.testing.expectEqual(@as(u16, 256 * 12), zq(12.0));
    try std.testing.expectEqual(@as(u16, 3200), zq(12.5));
    try std.testing.expectEqual(@as(u16, 65535), zq(300.0));
}

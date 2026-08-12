// charttable chart shaders — Metal Shading Language.
//
// Ported from lookout/tile57 (tile57 shaders/lookout.metal) and rewritten for
// charttable's scene contract (src/scene/types.zig). Compiled at runtime by
// metal_shim.m (newLibraryWithSource), so there is no offline shader toolchain.
//
// Vertices are fetched by index from the raw scene buffers instead of through
// a vertex descriptor. TWO vertex streams: geometry rides [[buffer(0)]]
// (scene.Vertex / scene.Quad) and evaluated paint rides [[buffer(1)]]
// (scene.PaintVertex, one entry per stream-A vertex) — a paint-only restyle
// re-uploads stream B and never touches geometry. The uniform block sits at
// [[buffer(2)]] in the vertex stage and [[buffer(1)]] in the fragment stage.
//
// The structs below must stay byte-identical to scene/types.zig: Vertex 28 B,
// Quad 40 B, PaintVertex 4 B, Uniforms 128 B. The static_asserts turn a
// layout skew into a loud failure at pipeline build instead of a wrong frame.

#include <metal_stdlib>
using namespace metal;

// ---- shared uniform block (== scene.Uniforms, 128 bytes) --------------------
struct U {
    float4x4 mvp;        // column-major tile-local -> clip (Camera.mvpOrigin)
    float2   px_to_clip; // reference-px -> clip delta (the ox/oy channel)
    float    size_scale; // pixel density x symbol size multiplier
    float    zoom;       // fractional zoom * 256, tested against zmin/zmax
    float    zoom_t;     // fract(zoom): mix factor for zoom-interpolated paint
    float    wrap_x;     // camera centre x IN THE VERTEX FRAME (antimeridian)
    float    rot_sin;
    float    rot_cos;
    float4   color;      // SDF halo background; SDF fragment stage only
    float2   anchor_px;  // pattern phase origin, framebuffer px
    float2   cell_px;    // pattern cell period, framebuffer px
};
static_assert(sizeof(U) == 128, "U must match scene.Uniforms (128 B)");

// ---- vertex streams (== scene/types.zig structs) ----------------------------
struct Vertex {                 // scene.Vertex, 28 B
    // packed_float2 keeps the stride EXACTLY the CPU struct's — natural float2
    // alignment would round a mixed layout up and shear the stream.
    packed_float2 pos;          // tile-local world units (world - tile NW)
    packed_float2 off;          // screen offset, reference px, post-projection
    ushort zmin;                // visible while zmin <= u.zoom <= zmax
    ushort zmax;
    uchar  flags;               // bit 0: map_align
    uchar  pad0;
    uchar  pad1;
    uchar  pad2;
    float  depth;               // paint-order depth (0,1), later = smaller
};
static_assert(sizeof(Vertex) == 28, "Vertex must match scene.Vertex (28 B)");

struct Paint {                  // scene.PaintVertex, 4 B — stream B
    uchar4 color;               // straight-alpha RGBA
};
static_assert(sizeof(Paint) == 4, "Paint must match scene.PaintVertex (4 B)");

struct Quad {                   // scene.Quad, 40 B
    packed_float2 pos;          // tile-local anchor
    packed_float2 off;          // corner offset, reference px, run-rotated
    packed_float2 uv;           // atlas UV [0,1]
    float  weight;              // SDF halo/embolden width (0 for a sprite)
    ushort zmin;
    ushort zmax;
    uchar  flags;               // bit 0: map_align
    uchar  flip;                // 180-degree upright flip enable
    uchar  tangent_q;           // run angle, /256 turns
    uchar  pad;
    float  depth;
};
static_assert(sizeof(Quad) == 40, "Quad must match scene.Quad (40 B)");

constant uint FLAG_MAP_ALIGN = 1u;

// Longitude is cyclic: draw each vertex at the world instance nearest the
// camera (x, x-1 or x+1), so a view straddling the antimeridian is seamless.
// The world period is exactly 1.0 world unit in ANY translated frame, so this
// works on tile-local coordinates as long as u.wrap_x is stated in the same
// frame (host: camera.center.x - tile_origin.x).
static inline float4 project(constant U &u, float2 p) {
    float2 world = float2(p.x + rint(u.wrap_x - p.x), p.y);
    return u.mvp * float4(world, 0.0, 1.0);
}

// The per-vertex zoom visibility window: zmin/zmax quantized to 1/256 zoom
// steps (scene.zq), compared against the frame's fractional zoom. Inclusive
// on both ends. This replaces lookout's cat_mask/scamin gates.
static inline bool gate(constant U &u, ushort zmin, ushort zmax) {
    return float(zmin) <= u.zoom && u.zoom <= float(zmax);
}

// (ox, oy) is added AFTER projection, in reference px. map_align means it is
// stated in the MAP frame: a rotated view must turn it by (rot_sin, rot_cos)
// or the pen shears to |cos(rotation)| of its width.
static inline float2 screen_offset(constant U &u, float2 off, uchar flags) {
    if ((flags & FLAG_MAP_ALIGN) != 0u) {
        off = float2(off.x * u.rot_cos - off.y * u.rot_sin,
                     off.x * u.rot_sin + off.y * u.rot_cos);
    }
    return off;
}

// ---- fill: flat-colour triangles (area fills, line work) --------------------
// Colour comes from the PAINT stream, one entry per vertex — ranges of
// differently-coloured fills merge into one draw.
struct FillOut {
    float4 pos [[position]];
    float4 color;
};

vertex FillOut fill_vert(uint vid [[vertex_id]],
                         const device Vertex *verts [[buffer(0)]],
                         const device Paint *paint [[buffer(1)]],
                         constant U &u [[buffer(2)]]) {
    Vertex v = verts[vid];
    float4 clip = project(u, v.pos);
    float2 off = screen_offset(u, v.off, v.flags);
    clip.xy += off * u.px_to_clip * u.size_scale * clip.w;
    clip.z = v.depth * clip.w; // paint-order depth (ortho: w = 1)
    FillOut out;
    out.pos = gate(u, v.zmin, v.zmax) ? clip : float4(0.0, 0.0, 2.0, 1.0); // z=2 -> clipped
    out.color = float4(paint[vid].color) / 255.0;
    return out;
}

fragment float4 fill_frag(FillOut in [[stage_in]]) {
    return in.color;
}

// ---- pattern: area fills tiled from a pattern cell --------------------------
// The tessellated polygon interior projects like fill_vert; the tiling is done
// per-fragment so the cell keeps a constant screen size and stays ANCHORED TO
// THE WORLD under a pan instead of swimming with the screen.
struct PatternOut {
    float4 pos [[position]];
    float2 anchor;
    float2 cell;
};

vertex PatternOut pattern_vert(uint vid [[vertex_id]],
                               const device Vertex *verts [[buffer(0)]],
                               constant U &u [[buffer(2)]]) {
    Vertex v = verts[vid];
    float4 clip = project(u, v.pos);
    float2 off = screen_offset(u, v.off, v.flags);
    clip.xy += off * u.px_to_clip * u.size_scale * clip.w;
    clip.z = v.depth * clip.w; // paint-order depth: patterns depth-test too
    PatternOut out;
    out.pos = gate(u, v.zmin, v.zmax) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    out.anchor = u.anchor_px;
    out.cell = u.cell_px;
    return out;
}

// Phase = (fragment - world-origin) / cell, both in framebuffer px: a pan moves
// both by the same amount, so the pattern is fixed to the map, not the screen.
fragment float4 pattern_frag(PatternOut in [[stage_in]],
                             texture2d<float> cell [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
    float2 sz = max(in.cell, float2(1.0));
    float2 uv = fract((in.pos.xy - in.anchor) / sz);
    float4 c = cell.sample(smp, uv);
    if (c.a < 0.02) discard_fragment(); // pattern cells are mostly transparent
    return c;
}

// ---- sprite/SDF quads: symbols and text --------------------------------------
struct QuadOut {
    float4 pos [[position]];
    float2 uv;
    float4 color;
    float  weight;
};

vertex QuadOut sprite_vert(uint vid [[vertex_id]],
                           const device Quad *verts [[buffer(0)]],
                           const device Paint *paint [[buffer(1)]],
                           constant U &u [[buffer(2)]]) {
    Quad v = verts[vid];
    float tangent = float(v.tangent_q) / 256.0 * 6.2831853071795864;

    float4 clip = project(u, v.pos);
    float2 off = v.off;
    // Keep a tangent-rotated run (line-following text) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180 degrees about the anchor.
    if (v.flip != 0 && (cos(tangent) * u.rot_cos - sin(tangent) * u.rot_sin) < 0.0) {
        off = -off;
    }
    off = screen_offset(u, off, v.flags);
    clip.xy += off * u.px_to_clip * u.size_scale * clip.w;
    clip.z = v.depth * clip.w; // paint-order depth: quads lose to later fills

    QuadOut out;
    out.pos = gate(u, v.zmin, v.zmax) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    out.uv = v.uv;
    out.color = float4(paint[vid].color) / 255.0;
    out.weight = v.weight;
    return out;
}

fragment float4 sprite_frag(QuadOut in [[stage_in]],
                            texture2d<float> atlas [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    // A sprite keeps its authored colours: the paint stream is ignored here
    // (scene.PaintVertex doc). A fully transparent fragment must not reach the
    // depth buffer — a raster tile drawn through this pipeline WITH depth
    // write is transparent outside its coverage, and those pixels would
    // otherwise cut holes in content underneath.
    float4 c = atlas.sample(smp, in.uv);
    if (c.a < (1.0 / 255.0)) discard_fragment();
    return c;
}

// SDF text: sample the signed-distance field (.r), antialias with the
// screen-space derivative, tint by the PAINT stream. `weight` is the halo /
// embolden width in SDF field units (0 = none); the halo renders in the
// color the host stamped on the draw (u.color) — the style's
// text-halo-color, or the frame's effective background — so night text is not
// trapped inside a glaring light outline.
//
// SDF_EDGE is where fontnik puts the glyph outline: byte 191 of 255 (cutoff
// 0.25), with distance running 255/8 per px of a 24-px em. Thresholding at
// 0.5 instead would dilate every glyph by 2 em-px on each side — legible, but
// visibly bolder than the reference render.
constant float SDF_EDGE = 191.0 / 255.0;

fragment float4 sdf_frag(QuadOut in [[stage_in]],
                         constant U &u [[buffer(1)]],
                         texture2d<float> atlas [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float d = atlas.sample(smp, in.uv).r;
    float w = fwidth(d);
    float a = smoothstep(SDF_EDGE - w, SDF_EDGE + w, d);
    if (in.weight > 0.0) {
        float halo_a = smoothstep(SDF_EDGE - in.weight - w, SDF_EDGE - in.weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard_fragment();
        float3 col = mix(u.color.rgb, in.color.rgb, a);
        return float4(col, cov * in.color.a);
    }
    if (a <= 0.0) discard_fragment();
    return float4(in.color.rgb, in.color.a * a);
}

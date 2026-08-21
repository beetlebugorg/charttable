// charttable fill vertex shader: flat-color triangles — area fills and line
// work. The contract is src/scene/types.zig.
//
// TWO streams: geometry in slot 0 (scene.Vertex, 28 B), evaluated paint in
// slot 1 (scene.PaintVertex, 4 B), fetched by the same vertex index. A
// paint-only restyle re-uploads slot 1 and never touches geometry.

cbuffer U : register(b0) {
    column_major float4x4 u_mvp;
    float2 u_px_to_clip;
    float  u_size_scale;
    float  u_zoom;       // fractional zoom * 256
    float  u_zoom_t;
    float  u_wrap_x;
    float  u_rot_sin;
    float  u_rot_cos;
    float4 u_color;
    float2 u_anchor_px;
    float2 u_cell_px;
};

struct VSIn {
    float2 a_pos      : TEXCOORD0; // tile-local world units
    float2 a_off      : TEXCOORD1; // screen offset, reference px
    uint   a_zwin     : TEXCOORD2; // zmin | zmax<<16
    uint   a_flags    : TEXCOORD3; // bit 0: map_align; byte 1: width slope (wscale_q)
    float  a_depth    : TEXCOORD4; // paint-order depth (0,1)
    float4 a_color    : TEXCOORD5; // stream B, UNORM8x4 straight alpha
    // The zoom-interpolated pair's upper half: the same property one integer
    // zoom up, mixed by u_zoom_t. A scene with no such property binds stream B
    // here too, so the mix collapses to a no-op and costs nothing.
    float4 a_color_hi : TEXCOORD6;
};

struct VSOut {
    float4 pos   : SV_Position;
    float4 color : TEXCOORD0;
};

// Longitude is cyclic: draw each vertex at the world instance nearest the
// camera, so a view straddling the antimeridian is seamless. The world period
// is exactly 1.0 in ANY translated frame, so this works on tile-local
// coordinates as long as u_wrap_x is stated in the same frame.
float4 project(float2 p) {
    float2 world = float2(p.x + round(u_wrap_x - p.x), p.y);
    return mul(u_mvp, float4(world, 0.0, 1.0));
}

// The per-vertex zoom visibility window, quantized to 1/256 zoom steps and
// inclusive at both ends.
bool gate(uint zwin) {
    float zmin = float(zwin & 0xFFFF);
    float zmax = float(zwin >> 16);
    return zmin <= u_zoom && u_zoom <= zmax;
}

// (ox, oy) is added AFTER projection, in reference px. map_align means it is
// stated in the MAP frame: a rotated view must turn it, or the pen shears to
// |cos(rotation)| of its width.
float2 screen_offset(float2 off, uint flags) {
    if ((flags & 1) != 0) {
        off = float2(off.x * u_rot_cos - off.y * u_rot_sin,
                     off.x * u_rot_sin + off.y * u_rot_cos);
    }
    return off;
}

VSOut main(VSIn i) {
    VSOut o;
    float4 clip = project(i.a_pos);
    float2 off = screen_offset(i.a_off, i.a_flags);
    // The baked width slope (scene.Vertex.wscale_q, byte 1 of the flags
    // word): a zoom-curve line width keeps following the camera between
    // rebuilds. 128 states slope 0 and the factor collapses to 1. zoom_t is
    // deliberately NOT clamped here — past the bracket the slope
    // extrapolates, the continuous answer while the rebuild lands.
    float wslope = (float((i.a_flags >> 8) & 0xFF) - 128.0) * (1.0 / 32.0);
    off *= exp2(wslope * u_zoom_t);
    clip.xy += off * u_px_to_clip * u_size_scale * clip.w;
    clip.z = i.a_depth * clip.w; // paint-order depth (ortho: w = 1)
    o.pos = gate(i.a_zwin) ? clip : float4(0.0, 0.0, 2.0, 1.0); // z=2 -> clipped
    // Clamped: mid-gesture zoom_t can leave [0,1]; hold the end color
    // rather than wrapping to the far one.
    o.color = lerp(i.a_color, i.a_color_hi, saturate(u_zoom_t));
    return o;
}

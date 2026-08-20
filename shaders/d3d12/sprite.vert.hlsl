// Textured-quad vertex shader: sprite symbols and SDF text. One quad per
// symbol or glyph, 6 verts, non-indexed. Same anchor + screen-offset model as
// fill.vert.hlsl plus a UV, an SDF weight, and the upright flip.
//
// Slot 0 is scene.Quad (40 B); slots 1 and 2 are the paint streams. A sprite
// ignores the paint stream (its texels carry the color); an SDF glyph tints
// by it.

cbuffer U : register(b0) {
    column_major float4x4 u_mvp;
    float2 u_px_to_clip;
    float  u_size_scale;
    float  u_zoom;
    float  u_zoom_t;
    float  u_wrap_x;
    float  u_rot_sin;
    float  u_rot_cos;
    float4 u_color;
    float2 u_anchor_px;
    float2 u_cell_px;
};

struct VSIn {
    float2 a_pos      : TEXCOORD0; // tile-local anchor
    float2 a_off      : TEXCOORD1; // corner offset, reference px
    float2 a_uv       : TEXCOORD2;
    float  a_weight   : TEXCOORD3; // SDF halo width, 0 for a sprite
    uint   a_zwin     : TEXCOORD4; // zmin | zmax<<16
    uint   a_pack     : TEXCOORD5; // flags | flip<<8 | tangent_q<<16
    float  a_depth    : TEXCOORD6;
    float4 a_color    : TEXCOORD7; // stream B
    float4 a_color_hi : TEXCOORD8; // the zoom pair's upper half
};

struct VSOut {
    float4 pos    : SV_Position;
    float2 uv     : TEXCOORD0;
    float4 color  : TEXCOORD1;
    float  weight : TEXCOORD2;
};

VSOut main(VSIn i) {
    VSOut o;
    uint flags = i.a_pack & 0xFF;
    bool flip = ((i.a_pack >> 8) & 0xFF) != 0;
    float tangent = float((i.a_pack >> 16) & 0xFF) / 256.0 * 6.2831853071795864;

    float2 world = float2(i.a_pos.x + round(u_wrap_x - i.a_pos.x), i.a_pos.y);
    float4 clip = mul(u_mvp, float4(world, 0.0, 1.0));

    float2 off = i.a_off;
    // Keep a tangent-rotated run (line-following text) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180 degrees about the anchor.
    if (flip && (cos(tangent) * u_rot_cos - sin(tangent) * u_rot_sin) < 0.0) {
        off = -off;
    }
    if ((flags & 1) != 0) {
        off = float2(off.x * u_rot_cos - off.y * u_rot_sin,
                     off.x * u_rot_sin + off.y * u_rot_cos);
    }
    clip.xy += off * u_px_to_clip * u_size_scale * clip.w;
    clip.z = i.a_depth * clip.w;

    float zmin = float(i.a_zwin & 0xFFFF);
    float zmax = float(i.a_zwin >> 16);
    bool vis = zmin <= u_zoom && u_zoom <= zmax;
    o.pos = vis ? clip : float4(0.0, 0.0, 2.0, 1.0);
    o.uv = i.a_uv;
    o.color = lerp(i.a_color, i.a_color_hi, u_zoom_t);
    o.weight = i.a_weight;
    return o;
}

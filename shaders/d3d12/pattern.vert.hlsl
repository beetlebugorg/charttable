// Area fills tiled from a pattern cell. Same geometry stream as fill.vert.hlsl
// and the same projection; the tiling itself is per-fragment so the cell keeps
// a constant screen size and stays ANCHORED TO THE WORLD under a pan instead of
// swimming with the screen. No paint stream: the cell's own texels are the
// color.

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
    float2 a_pos   : TEXCOORD0;
    float2 a_off   : TEXCOORD1;
    uint   a_zwin  : TEXCOORD2;
    uint   a_flags : TEXCOORD3;
    float  a_depth : TEXCOORD4;
};

struct VSOut {
    float4 pos    : SV_Position;
    float2 anchor : TEXCOORD0;
    float2 cell   : TEXCOORD1;
};

VSOut main(VSIn i) {
    VSOut o;
    float2 world = float2(i.a_pos.x + round(u_wrap_x - i.a_pos.x), i.a_pos.y);
    float4 clip = mul(u_mvp, float4(world, 0.0, 1.0));
    float2 off = i.a_off;
    if ((i.a_flags & 1) != 0) {
        off = float2(off.x * u_rot_cos - off.y * u_rot_sin,
                     off.x * u_rot_sin + off.y * u_rot_cos);
    }
    clip.xy += off * u_px_to_clip * u_size_scale * clip.w;
    clip.z = i.a_depth * clip.w; // patterns depth-test with the fills

    float zmin = float(i.a_zwin & 0xFFFF);
    float zmax = float(i.a_zwin >> 16);
    bool vis = zmin <= u_zoom && u_zoom <= zmax;
    o.pos = vis ? clip : float4(0.0, 0.0, 2.0, 1.0);
    o.anchor = u_anchor_px;
    o.cell = u_cell_px;
    return o;
}

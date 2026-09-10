// Phase = (fragment - world origin) / cell, both in framebuffer px: a pan
// moves both by the same amount, so the pattern is fixed to the map and not
// to the screen. SV_Position in a pixel shader is the framebuffer position
// with its origin at the top-left corner, which is the frame u_anchor_px is
// stated in.

Texture2D    cell_tex : register(t0);
SamplerState cell_smp : register(s0);

// b0 is visible to both stages (the root signature says ALL), so the pixel
// stage reads the same block the vertex stage did.
cbuffer U : register(b0) {
    column_major float4x4 u_mvp;
    float2 u_px_to_clip;
    float  u_size_scale;
    float  u_zoom;
    float  u_zoom_t;
    float  u_world_per_px;
    float  u_rot_sin;
    float  u_rot_cos;
    float4 u_color;
    float2 u_anchor_px;
    float2 u_cell_px;
    float4 u_clip_rect;
};

// A tile's triangles paint their own tile. The geometry keeps the buffered
// overhang a line's joins are built from, and the draw trims it
// (scene.CLIP_NONE). A draw with no tile of its own is set to CLIP_NONE and
// pays one compare.
bool clipped(float2 world) {
    return world.x < u_clip_rect.x || world.y < u_clip_rect.y ||
           world.x > u_clip_rect.z || world.y > u_clip_rect.w;
}

struct PSIn {
    float4 pos    : SV_Position;
    float2 anchor : TEXCOORD0;
    float2 cell   : TEXCOORD1;
    float2 world  : TEXCOORD2;
};

float4 main(PSIn i) : SV_Target {
    if (clipped(i.world)) discard;
    float2 sz = max(i.cell, float2(1.0, 1.0));
    float2 uv = frac((i.pos.xy - i.anchor) / sz);
    float4 c = cell_tex.Sample(cell_smp, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    return c;
}

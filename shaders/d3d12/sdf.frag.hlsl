// SDF text: sample the signed-distance field (.r), antialias with the
// screen-space derivative, tint by the paint stream. `weight` is the halo
// width in SDF field units (0 = none); the halo renders in the color the
// host stamped on the draw (u_color) -- the style's text-halo-color, or the
// frame's effective background -- so night text is not trapped inside a
// glaring light outline.
//
// SDF_EDGE is where fontnik puts the glyph outline: byte 191 of 255 (cutoff
// 0.25), with distance running 255/8 per px of a 24-px em. Thresholding at
// 0.5 instead dilates every glyph by 2 em-px on each side.

Texture2D    atlas     : register(t0);
SamplerState atlas_smp : register(s0);

cbuffer U : register(b1) {
    column_major float4x4 u_mvp;
    float2 u_px_to_clip;
    float  u_size_scale;
    float  u_zoom;
    float  u_zoom_t;
    float  u_wrap_x;
    float  u_rot_sin;
    float  u_rot_cos;
    float4 u_color;      // the SDF halo color for this draw
    float2 u_anchor_px;
    float2 u_cell_px;
};

struct PSIn {
    float4 pos    : SV_Position;
    float2 uv     : TEXCOORD0;
    float4 color  : TEXCOORD1;
    float  weight : TEXCOORD2;
};

static const float SDF_EDGE = 191.0 / 255.0;

float4 main(PSIn i) : SV_Target {
    float d = atlas.Sample(atlas_smp, i.uv).r;
    float w = fwidth(d);
    float a = smoothstep(SDF_EDGE - w, SDF_EDGE + w, d);
    if (i.weight > 0.0) {
        float halo_a = smoothstep(SDF_EDGE - i.weight - w, SDF_EDGE - i.weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard;
        float3 col = lerp(u_color.rgb, i.color.rgb, a);
        return float4(col, cov * i.color.a);
    }
    if (a <= 0.0) discard;
    return float4(i.color.rgb, i.color.a * a);
}

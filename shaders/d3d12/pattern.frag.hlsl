// Phase = (fragment - world origin) / cell, both in framebuffer px: a pan
// moves both by the same amount, so the pattern is fixed to the map and not
// to the screen. SV_Position in a pixel shader is the framebuffer position
// with its origin at the top-left corner, which is the frame u_anchor_px is
// stated in.

Texture2D    cell_tex : register(t0);
SamplerState cell_smp : register(s0);

struct PSIn {
    float4 pos    : SV_Position;
    float2 anchor : TEXCOORD0;
    float2 cell   : TEXCOORD1;
};

float4 main(PSIn i) : SV_Target {
    float2 sz = max(i.cell, float2(1.0, 1.0));
    float2 uv = frac((i.pos.xy - i.anchor) / sz);
    float4 c = cell_tex.Sample(cell_smp, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    return c;
}

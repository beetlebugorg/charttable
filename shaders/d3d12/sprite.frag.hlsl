// Authored colors MODULATED by the paint stream: every symbol bakes white
// there, so a sprite keeps its texels, while a raster tile mid cross-fade
// rides its ramping alpha (map_object.tickFade). Fully transparent
// fragments are DISCARDED: no quad pipeline writes depth, but a faded-out
// tile's pixels would still blend for nothing, and the discard removes a
// fully faded tile outright.

Texture2D    atlas     : register(t0);
SamplerState atlas_smp : register(s0);

struct PSIn {
    float4 pos    : SV_Position;
    float2 uv     : TEXCOORD0;
    float4 color  : TEXCOORD1;
    float  weight : TEXCOORD2;
};

float4 main(PSIn i) : SV_Target {
    float4 c = atlas.Sample(atlas_smp, i.uv) * i.color;
    if (c.a < (1.0 / 255.0)) discard;
    return c;
}

// A sprite keeps its authored colors: the paint stream is ignored here. A
// fully transparent fragment must not reach the depth buffer -- a raster tile
// drawn through this pipeline WITH depth write is transparent outside its
// coverage, and those pixels would otherwise cut holes in what is underneath.

Texture2D    atlas     : register(t0);
SamplerState atlas_smp : register(s0);

struct PSIn {
    float4 pos    : SV_Position;
    float2 uv     : TEXCOORD0;
    float4 color  : TEXCOORD1;
    float  weight : TEXCOORD2;
};

float4 main(PSIn i) : SV_Target {
    float4 c = atlas.Sample(atlas_smp, i.uv);
    if (c.a < (1.0 / 255.0)) discard;
    return c;
}

// Host-overlay fragment shader: the vertex colour, straight out. The overlay
// store resolved the palette token to RGBA at build time, and the pipeline's
// blend state does the alpha.

struct PSIn {
    float4 pos   : SV_Position;
    float4 color : TEXCOORD0;
};

float4 main(PSIn i) : SV_Target {
    return i.color;
}

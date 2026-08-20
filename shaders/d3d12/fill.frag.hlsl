// Flat color straight from stream B, blended in paint order by the
// fixed-function blend state.

struct PSIn {
    float4 pos   : SV_Position;
    float4 color : TEXCOORD0;
};

float4 main(PSIn i) : SV_Target {
    return i.color;
}

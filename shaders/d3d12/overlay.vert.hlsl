// Host-overlay vertex shader. The chart's geometry comes from the layout
// stages; the overlay is the host's own content (scene.OverlayVertex, 24 B:
// world f2@0, colour f4@8), drawn after the scene in the same command list.

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
    float2 a_world : TEXCOORD0; // web-mercator, RELATIVE to the frame origin
    float4 a_color : TEXCOORD1; // straight-alpha RGBA, token already resolved
};

struct VSOut {
    float4 pos   : SV_Position;
    float4 color : TEXCOORD0;
};

VSOut main(VSIn i) {
    VSOut o;
    // The chart shader's antimeridian wrap: draw at the world instance nearest
    // the camera. A whole world width is 1.0 in the relative frame too.
    float2 world = float2(i.a_world.x + round(u_wrap_x - i.a_world.x), i.a_world.y);
    float4 clip = mul(u_mvp, float4(world, 0.0, 1.0));
    // z = 0 is the near plane. The chart's paint-order depths are all in (0,1)
    // and this pass writes no depth, so host content is never hidden by the
    // chart and never hides it from a later pass.
    clip.z = 0.0;
    o.pos = clip;
    o.color = i.a_color;
    return o;
}

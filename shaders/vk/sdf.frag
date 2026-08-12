#version 450
// SDF text: sample the signed-distance field (.r), antialias with the
// screen-space derivative, tint by the paint stream. `v_weight` is the halo
// width in SDF field units (0 = none); the halo renders in the colour the
// host stamped on the draw (u.color) -- the style's text-halo-color, or the
// frame's effective background -- so night text is not trapped inside a
// glaring light outline. Matches metal.metal sdf_frag.
//
// SDF_EDGE is where fontnik puts the glyph outline: byte 191 of 255 (cutoff
// 0.25), with distance running 255/8 per px of a 24-px em. Thresholding at
// 0.5 instead dilates every glyph by 2 em-px on each side.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(set = 3, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float zoom;
    float zoom_t;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;      // the SDF halo colour for this draw
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) in  vec2  v_uv;
layout(location = 1) in  vec4  v_color;
layout(location = 2) in  float v_weight;
layout(location = 0) out vec4  o_color;

const float SDF_EDGE = 191.0 / 255.0;

void main() {
    float d = texture(atlas, v_uv).r;
    float w = fwidth(d);
    float a = smoothstep(SDF_EDGE - w, SDF_EDGE + w, d);
    if (v_weight > 0.0) {
        float halo_a = smoothstep(SDF_EDGE - v_weight - w, SDF_EDGE - v_weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard;
        vec3 col = mix(u.color.rgb, v_color.rgb, a);
        o_color = vec4(col, cov * v_color.a);
        return;
    }
    if (a <= 0.0) discard;
    o_color = vec4(v_color.rgb, v_color.a * a);
}

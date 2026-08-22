#version 450
// Authored colors MODULATED by the paint stream: every symbol bakes white
// there, so a sprite keeps its texels, while a raster tile mid cross-fade
// rides its ramping alpha (map_object.tickFade). Fully transparent
// fragments are DISCARDED: no quad pipeline writes depth, but a faded-out
// tile's pixels would still blend for nothing, and the discard removes a
// fully faded tile outright.
// Matches metal.metal sprite_frag.
layout(set = 2, binding = 0) uniform sampler2D atlas;

layout(location = 0) in  vec2  v_uv;
layout(location = 1) in  vec4  v_color;
layout(location = 2) in  float v_weight;
layout(location = 0) out vec4  o_color;

void main() {
    vec4 c = texture(atlas, v_uv) * v_color;
    if (c.a < (1.0 / 255.0)) discard;
    o_color = c;
}

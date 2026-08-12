#version 450
// A sprite keeps its authored colors: the paint stream is ignored here. A
// fully transparent fragment must not reach the depth buffer -- a raster tile
// drawn through this pipeline WITH depth write is transparent outside its
// coverage, and those pixels would otherwise cut holes in what is underneath.
// Matches metal.metal sprite_frag.
layout(set = 2, binding = 0) uniform sampler2D atlas;

layout(location = 0) in  vec2  v_uv;
layout(location = 1) in  vec4  v_color;
layout(location = 2) in  float v_weight;
layout(location = 0) out vec4  o_color;

void main() {
    vec4 c = texture(atlas, v_uv);
    if (c.a < (1.0 / 255.0)) discard;
    o_color = c;
}

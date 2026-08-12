#version 450
// Phase = (fragment - world origin) / cell, both in framebuffer px: a pan
// moves both by the same amount, so the pattern is fixed to the map and not
// to the screen. Matches metal.metal pattern_frag.
layout(set = 2, binding = 0) uniform sampler2D cell;

layout(location = 0) in  vec2 v_anchor;
layout(location = 1) in  vec2 v_cell;
layout(location = 0) out vec4 o_color;

void main() {
    vec2 sz = max(v_cell, vec2(1.0));
    vec2 uv = fract((gl_FragCoord.xy - v_anchor) / sz);
    vec4 c = texture(cell, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    o_color = c;
}

#version 450
// Phase = (fragment - world origin) / cell, both in framebuffer px: a pan
// moves both by the same amount, so the pattern is fixed to the map and not
// to the screen. Matches metal.metal pattern_frag.
layout(set = 2, binding = 0) uniform sampler2D cell;

layout(location = 0) in  vec2 v_anchor;
layout(location = 1) in  vec2 v_cell;
layout(location = 2) in  vec2 v_world;
layout(location = 0) out vec4 o_color;

layout(set = 3, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float zoom;
    float zoom_t;
    float world_per_px;
    float rot_sin;
    float rot_cos;
    vec4  color;
    vec2  anchor_px;
    vec2  cell_px;
    vec4  clip_rect;
} u;

// See fill.frag: a tile's triangles paint their own tile and no more.
bool clipped(vec2 world) {
    return world.x < u.clip_rect.x || world.y < u.clip_rect.y ||
           world.x > u.clip_rect.z || world.y > u.clip_rect.w;
}

void main() {
    if (clipped(v_world)) discard;
    vec2 sz = max(v_cell, vec2(1.0));
    vec2 uv = fract((gl_FragCoord.xy - v_anchor) / sz);
    vec4 c = texture(cell, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    o_color = c;
}

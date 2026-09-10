#version 450
// Flat color straight from stream B, blended in paint order by the
// fixed-function blend state. Matches metal.metal fill_frag.
layout(location = 0) in  vec4 v_color;
layout(location = 1) in  vec2 v_world;
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

// A tile's triangles paint their own tile. The geometry keeps the buffered
// overhang a line's joins are built from, and the draw trims it
// (scene.CLIP_NONE). A draw with no tile of its own is set to CLIP_NONE and
// pays one compare.
bool clipped(vec2 world) {
    return world.x < u.clip_rect.x || world.y < u.clip_rect.y ||
           world.x > u.clip_rect.z || world.y > u.clip_rect.w;
}

void main() {
    if (clipped(v_world)) discard;
    o_color = v_color;
}

#version 450
// Area fills tiled from a pattern cell. Same geometry stream as fill.vert and
// the same projection; the tiling itself is per-fragment so the cell keeps a
// constant screen size and stays ANCHORED TO THE WORLD under a pan instead of
// swimming with the screen. No paint stream: the cell's own texels are the
// colour. Matches metal.metal pattern_vert.

layout(location = 0) in vec2  a_pos;
layout(location = 1) in vec2  a_off;
layout(location = 2) in uint  a_zwin;
layout(location = 3) in uint  a_flags;
layout(location = 4) in float a_depth;

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float zoom;
    float zoom_t;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) out vec2 v_anchor;
layout(location = 1) out vec2 v_cell;

void main() {
    vec2 world = vec2(a_pos.x + round(u.wrap_x - a_pos.x), a_pos.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);
    vec2 off = a_off;
    if ((a_flags & 1u) != 0u) {
        off = vec2(off.x * u.rot_cos - off.y * u.rot_sin,
                   off.x * u.rot_sin + off.y * u.rot_cos);
    }
    clip.xy += off * u.px_to_clip * u.size_scale * clip.w;
    clip.z = a_depth * clip.w; // patterns depth-test with the fills

    float zmin = float(a_zwin & 0xFFFFu);
    float zmax = float(a_zwin >> 16);
    bool vis = zmin <= u.zoom && u.zoom <= zmax;
    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0);
    v_anchor = u.anchor_px;
    v_cell = u.cell_px;
}

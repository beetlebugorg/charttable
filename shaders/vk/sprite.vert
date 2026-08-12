#version 450
// Textured-quad vertex shader: sprite symbols, SDF text, and raster tiles.
// One quad per symbol/glyph/tile, 6 verts, non-indexed. Same anchor +
// screen-offset model as fill.vert plus a UV, an SDF weight, and the upright
// flip. Matches metal.metal sprite_vert.
//
// Binding 0 is scene.Quad (40 B); binding 1 is the paint stream. A sprite
// ignores the paint stream (its texels carry the colour); an SDF glyph tints
// by it.

layout(location = 0) in vec2  a_pos;    // tile-local anchor
layout(location = 1) in vec2  a_off;    // corner offset, reference px
layout(location = 2) in vec2  a_uv;
layout(location = 3) in float a_weight; // SDF halo width, 0 for a sprite
layout(location = 4) in uint  a_zwin;   // zmin | zmax<<16
layout(location = 5) in uint  a_pack;   // flags | flip<<8 | tangent_q<<16
layout(location = 6) in float a_depth;
layout(location = 7) in vec4  a_color;  // stream B

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

layout(location = 0) out vec2  v_uv;
layout(location = 1) out vec4  v_color;
layout(location = 2) out float v_weight;

void main() {
    uint flags = a_pack & 0xFFu;
    bool flip  = ((a_pack >> 8) & 0xFFu) != 0u;
    float tangent = float((a_pack >> 16) & 0xFFu) / 256.0 * 6.2831853071795864;

    vec2 world = vec2(a_pos.x + round(u.wrap_x - a_pos.x), a_pos.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);

    vec2 off = a_off;
    // Keep a tangent-rotated run (line-following text) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180 degrees about the anchor.
    if (flip && (cos(tangent) * u.rot_cos - sin(tangent) * u.rot_sin) < 0.0) {
        off = -off;
    }
    if ((flags & 1u) != 0u) {
        off = vec2(off.x * u.rot_cos - off.y * u.rot_sin,
                   off.x * u.rot_sin + off.y * u.rot_cos);
    }
    clip.xy += off * u.px_to_clip * u.size_scale * clip.w;
    clip.z = a_depth * clip.w;

    float zmin = float(a_zwin & 0xFFFFu);
    float zmax = float(a_zwin >> 16);
    bool vis = zmin <= u.zoom && u.zoom <= zmax;
    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0);
    v_uv = a_uv;
    v_color = a_color;
    v_weight = a_weight;
}

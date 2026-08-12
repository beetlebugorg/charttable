#version 450
// charttable fill vertex shader (Vulkan / SDL_GPU): flat-colour triangles —
// area fills and line work. The contract is src/scene/types.zig;
// shaders/metal.metal is its reference statement and this must match it.
//
// TWO streams: geometry in binding 0 (scene.Vertex, 28 B), evaluated paint in
// binding 1 (scene.PaintVertex, 4 B), fetched by the same vertex index. A
// paint-only restyle re-uploads binding 1 and never touches geometry.

layout(location = 0) in vec2  a_pos;    // tile-local world units
layout(location = 1) in vec2  a_off;    // screen offset, reference px
layout(location = 2) in uint  a_zwin;   // zmin | zmax<<16
layout(location = 3) in uint  a_flags;  // bit 0: map_align (low byte)
layout(location = 4) in float a_depth;  // paint-order depth (0,1)
layout(location = 5) in vec4  a_color;  // stream B, UNORM8x4 straight alpha

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float zoom;       // fractional zoom * 256
    float zoom_t;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) out vec4 v_color;

// Longitude is cyclic: draw each vertex at the world instance nearest the
// camera, so a view straddling the antimeridian is seamless. The world period
// is exactly 1.0 in ANY translated frame, so this works on tile-local
// coordinates as long as u.wrap_x is stated in the same frame.
vec4 project(vec2 p) {
    vec2 world = vec2(p.x + round(u.wrap_x - p.x), p.y);
    return u.mvp * vec4(world, 0.0, 1.0);
}

// The per-vertex zoom visibility window, quantized to 1/256 zoom steps and
// inclusive at both ends. This replaces lookout's scamin / cat_mask gates.
bool gate(uint zwin) {
    float zmin = float(zwin & 0xFFFFu);
    float zmax = float(zwin >> 16);
    return zmin <= u.zoom && u.zoom <= zmax;
}

// (ox, oy) is added AFTER projection, in reference px. map_align means it is
// stated in the MAP frame: a rotated view must turn it, or the pen shears to
// |cos(rotation)| of its width.
vec2 screen_offset(vec2 off, uint flags) {
    if ((flags & 1u) != 0u) {
        off = vec2(off.x * u.rot_cos - off.y * u.rot_sin,
                   off.x * u.rot_sin + off.y * u.rot_cos);
    }
    return off;
}

void main() {
    vec4 clip = project(a_pos);
    clip.xy += screen_offset(a_off, a_flags) * u.px_to_clip * u.size_scale * clip.w;
    clip.z = a_depth * clip.w; // paint-order depth (ortho: w = 1)
    gl_Position = gate(a_zwin) ? clip : vec4(0.0, 0.0, 2.0, 1.0); // z=2 -> clipped
    v_color = a_color;
}

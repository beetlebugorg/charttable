#version 450
// Flat color straight from stream B, blended in paint order by the
// fixed-function blend state. Matches metal.metal fill_frag.
layout(location = 0) in  vec4 v_color;
layout(location = 0) out vec4 o_color;
void main() { o_color = v_color; }

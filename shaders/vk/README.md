# GLSL shaders (Vulkan / SDL_GPU)

charttable's scene contract (src/scene/types.zig) stated in GLSL, and the
`.spv` artifacts a backend embeds. There is no build-time shader step — the
same convention lookout uses: edit the source, recompile by hand, commit both.

```sh
cd shaders/vk
for f in fill.vert fill.frag pattern.vert pattern.frag \
         sprite.vert sprite.frag sdf.frag; do
    glslangValidator -V "$f" -o "$f.spv" || exit 1
    spirv-val "$f.spv" || exit 1
done
```

`shaders/metal.metal` is the reference statement of the contract; these must
stay in lock-step with it.

## The vertex layout a backend must declare

Two vertex bindings, matching the two streams. Attribute formats and offsets
are not negotiable — they are the struct layouts in scene/types.zig.

**Binding 0 — `scene.Vertex`, stride 28** (fill and pattern pipelines):

| loc | name | format | offset |
|---|---|---|---|
| 0 | a_pos | R32G32_SFLOAT | 0 |
| 1 | a_off | R32G32_SFLOAT | 8 |
| 2 | a_zwin | R32_UINT | 16 | zmin \| zmax<<16 |
| 3 | a_flags | R32_UINT | 20 | flags low byte, wscale_q byte 1 |
| 4 | a_depth | R32_SFLOAT | 24 |

**Binding 0 — `scene.Quad`, stride 40** (sprite and sdf pipelines):

| loc | name | format | offset |
|---|---|---|---|
| 0 | a_pos | R32G32_SFLOAT | 0 |
| 1 | a_off | R32G32_SFLOAT | 8 |
| 2 | a_uv | R32G32_SFLOAT | 16 |
| 3 | a_weight | R32_SFLOAT | 24 |
| 4 | a_zwin | R32_UINT | 28 | zmin \| zmax<<16 |
| 5 | a_pack | R32_UINT | 32 | flags \| flip<<8 \| tangent_q<<16 |
| 6 | a_depth | R32_SFLOAT | 36 |

**Binding 1 — `scene.PaintVertex`, stride 4**, one entry per stream-0 vertex:
`a_color` as R8G8B8A8_UNORM at offset 0 (location 5 for fill, 7 for quads).

## Descriptor sets

lookout's SDL_GPU convention, kept so a port lands on familiar ground:
set 1 binding 0 = the vertex-stage uniform block, set 2 binding 0 = the
fragment sampler, set 3 binding 0 = the fragment-stage uniform block. The
block is `scene.Uniforms`, 128 bytes, std140-compatible in this field order.

## Two contract changes from lookout, called out

1. **Indexed triangles.** lookout's Vulkan/SDL de-index at upload, where
   `index_count` means "vertices in vbuf" — a documented wart there. Here
   triangle ranges index the index buffer. Port the upload accordingly and
   delete the de-index path.
2. **The zoom window replaces the S-52 gates.** `zmin <= u.zoom <= zmax`
   against the frame's quantized fractional zoom, instead of scamin and
   cat_mask. Culled vertices exit through clip z = 2.

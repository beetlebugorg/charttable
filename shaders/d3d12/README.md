# HLSL shaders (Direct3D 12)

charttable's scene contract (src/scene/types.zig) stated in HLSL. There is no
build-time shader step: gpu_d3d12.zig embeds these files and compiles them with
`D3DCompile` from d3dcompiler_47.dll at open, entry point `main`, targets
`vs_5_0` and `ps_5_0`.

## The vertex layout the backend declares

Semantic names are `TEXCOORD<n>`, numbered in the order the attributes appear.
Formats and offsets are the struct layouts in scene/types.zig.

**Slot 0 — `scene.Vertex`, stride 28** (fill and pattern pipelines):

| semantic | name | format | offset |
|---|---|---|---|
| TEXCOORD0 | a_pos | R32G32_FLOAT | 0 |
| TEXCOORD1 | a_off | R32G32_FLOAT | 8 |
| TEXCOORD2 | a_zwin | R32_UINT | 16 | zmin \| zmax<<16 |
| TEXCOORD3 | a_flags | R32_UINT | 20 | flags low byte, wscale_q byte 1 |
| TEXCOORD4 | a_depth | R32_FLOAT | 24 |

**Slot 0 — `scene.Quad`, stride 40** (sprite and sdf pipelines):

| semantic | name | format | offset |
|---|---|---|---|
| TEXCOORD0 | a_pos | R32G32_FLOAT | 0 |
| TEXCOORD1 | a_off | R32G32_FLOAT | 8 |
| TEXCOORD2 | a_uv | R32G32_FLOAT | 16 |
| TEXCOORD3 | a_weight | R32_FLOAT | 24 |
| TEXCOORD4 | a_zwin | R32_UINT | 28 | zmin \| zmax<<16 |
| TEXCOORD5 | a_pack | R32_UINT | 32 | flags \| flip<<8 \| tangent_q<<16 |
| TEXCOORD6 | a_depth | R32_FLOAT | 36 |

**Slots 1 and 2 — `scene.PaintVertex`, stride 4**, one entry per slot-0 vertex:
`R8G8B8A8_UNORM` at offset 0. Slot 1 is the paint evaluated at the build zoom,
slot 2 the same property one integer zoom up; the shader mixes by `u_zoom_t`.
A scene with no zoom-interpolated paint binds slot 1 into both, collapsing the
mix.

**Slot 0 — `scene.OverlayVertex`, stride 24** (overlay pipeline): world
`R32G32_FLOAT` at 0, colour `R32G32B32A32_FLOAT` at 8.

## Root signature

Three root parameters and one static sampler, shared by all five pipelines:

| slot | binding | visibility |
|---|---|---|
| 0 | CBV `b0` — the vertex-stage uniform block | all |
| 1 | descriptor table, SRV `t0` — the atlas or pattern cell | pixel |
| 2 | CBV `b1` — the fragment-stage uniform block (SDF halo only) | pixel |
| — | static sampler `s0`, linear, clamp | pixel |

Both CBVs are root descriptors pointed at a per-draw slice of one upload-heap
ring, so a draw costs one address write and no descriptor allocation. The block
is `scene.Uniforms`, 128 bytes; HLSL's constant-buffer packing lands every field
at the offset the struct declares.

## Conventions this backend does not have to correct for

- D3D12 clip space is Y-up and its depth range is [0, 1], so the shared MVP and
  the paint-order depths need no adjustment; the viewport is the plain one.
- Texture space has its origin at the top-left corner, which is the frame the
  atlas UVs and `SV_Position` are already stated in.
- Matrices are declared `column_major`, matching the column-major
  `scene.Uniforms.mvp` the camera writes.

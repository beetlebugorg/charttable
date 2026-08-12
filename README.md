<h1 align="center">charttable</h1>

<p align="center">
  <b>🗺️ A native map renderer for the MapLibre style spec.</b><br>
  charttable takes a MapLibre style and vector tiles and draws them straight
  to the GPU — Metal, Vulkan, Direct3D 12 or SDL — holding 60 fps through
  pan, pinch-zoom and rotation. One Zig library with a C ABI.
</p>

---

> [!NOTE]
> Extracted from the [Lookout Marine](https://github.com/beetlebugorg/lookout-core)
> rendering engine and generalized: where Lookout renders one hard-wired
> nautical portrayal, charttable renders whatever the style says. It is a
> **clean-room** implementation of the published
> [MapLibre Style Specification](https://maplibre.org/maplibre-style-spec/) —
> see THIRD-PARTY-NOTICES.md for provenance.

## Why it is different

- **Tessellate once, transform per frame.** Tiles lay out into resident GPU
  buckets; a pan, zoom or rotation is a matrix change, never a rebuild. An
  idle map uses no CPU time.
- **Restyling is a buffer refill, not a re-layout.** Geometry and evaluated
  paint live in separate vertex streams: a palette flip or a
  `setPaintProperty` re-evaluates paint and re-uploads one stream.
- **Filters evaluate at fractional zoom.** Zoom gates bake into the resident
  scene as per-vertex visibility windows, so features appear at their exact
  zoom, not the next integer step.
- **Native everywhere the engine goes.** The same scene contract drives
  Metal, Vulkan, D3D12 and SDL backends.

## Status

Early extraction. See DESIGN.md for the architecture, the conformance tiers,
and the milestone plan. Building: `zig build test` (Zig 0.16.0).

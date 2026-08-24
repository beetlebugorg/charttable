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

## Install

macOS and Linux, through Homebrew:

```
brew install beetlebugorg/tap/charttable
```

That puts `charttable.h` under `include/` and the static and shared libraries
under `lib/`.

Every `vX.Y.Z` tag also publishes an archive per target on
[Releases](https://github.com/beetlebugorg/charttable/releases). Each archive
holds the C header, the static library and the shared library:

| Target | Static | Shared |
| --- | --- | --- |
| macOS, arm64 and x86_64 | `libcharttable.a` | `libcharttable.dylib` |
| Linux, arm64 and x86_64 | `libcharttable.a` | `libcharttable.so` |
| Windows, arm64 and x86_64 | `charttable.lib` | `charttable.dll` + `charttable.dll.lib` |

Linux also gets a Debian package:
`apt install ./libcharttable-dev_<version>_<arch>.deb`.

The released libraries carry their own libwebp and libpng. They leave the
Vulkan loader to the program that links them.

## Build

Zig 0.16.0. `zig build test` runs the suite. `zig build lib` writes
`libcharttable.a` and the header into `zig-out`; `zig build shared` writes the
shared library beside them. Add `-Dcodec-source` to compile libwebp and libpng
in instead of linking the platform copies — a cross build needs it.

## Status

Early extraction. See DESIGN.md for the architecture, the conformance tiers,
and the milestone plan.

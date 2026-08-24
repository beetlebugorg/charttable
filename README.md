<h1 align="center">charttable</h1>

<p align="center">
  <b>🗺️ A native map renderer for the MapLibre style spec.</b><br>
  charttable draws a MapLibre style and vector tiles on the GPU. It holds 60 fps through pan, pinch-zoom and rotation.
</p>

<p align="center">
  <a href="https://github.com/beetlebugorg/charttable/actions/workflows/ci.yml">
    <img src="https://github.com/beetlebugorg/charttable/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

---

charttable is one Zig library behind a C ABI. It draws through Metal, Vulkan or Direct3D 12, so the same library serves macOS, iOS, Linux, Windows and Android. It does no networking. Tiles come from a local pmtiles archive, or from your code through a resource callback.

## Install

```
brew install beetlebugorg/tap/charttable
```

Every tag also publishes an archive per target on [Releases](https://github.com/beetlebugorg/charttable/releases). Each one holds the C header, a static library and a shared library.

| Target | Static | Shared |
| --- | --- | --- |
| macOS, arm64 and x86_64 | `libcharttable.a` | `libcharttable.dylib` |
| Linux, arm64 and x86_64 | `libcharttable.a` | `libcharttable.so` |
| Windows, arm64 and x86_64 | `charttable.lib` | `charttable.dll` |

Linux also gets a Debian package. The released libraries carry their own libwebp and libpng, so nothing else has to be installed first.

## Use

```c
#include <charttable.h>

charttable *ct = charttable_open(NULL);
charttable_set_style_json(ct, style_json, strlen(style_json));
charttable_add_source_pmtiles(ct, "basemap", "/maps/planet.pmtiles");
charttable_attach_surface(ct, CHARTTABLE_NATIVE_METAL_LAYER, layer, w, h);

charttable_view v = { .lon = -76.48, .lat = 38.98, .zoom = 12 };
charttable_set_view(ct, &v);

/* once per frame */
charttable_tick(ct, dt_ms);
if (charttable_needs_redraw(ct)) charttable_render(ct);
```

The API is one opaque handle and about forty functions. A mutex inside the handle serializes them, so every call is safe from any thread. The three functions that touch the surface must be called from the thread that owns it, because the platform requires that.

## What it renders

The target is the whole [MapLibre Style Specification](https://maplibre.org/maplibre-style-spec/). What MapLibre draws from a style, charttable should draw from the same style. There is no charttable dialect and no porting step. The official conformance fixtures are vendored and run as the oracle, so the coverage is measured. 575 of the 577 expression fixtures pass today.

charttable now draws `background`, `fill`, `line`, `symbol`, `raster`, `hillshade` and `color-relief` layers, from `vector`, `raster` and `raster-dem` sources. `circle`, `geojson` and `fill-extrusion` are next.

A layer or property charttable does not support yet is skipped, and the reason goes into `charttable_style_diagnostics()`. Read that after you load a style.

## Why it is fast

- **A tile is turned into triangles once.** After that, a pan, zoom or rotation draws the same geometry with a new matrix. A map sitting still uses no CPU.
- **Restyling touches the paint stream only.** Geometry and evaluated paint sit in separate vertex streams. Changing a color, an opacity or a whole palette re-uploads the paint and leaves the geometry alone, so a day-to-night switch lands in one frame.
- **Features appear at the zoom the style names.** Each vertex carries the zoom range it is visible in, so a feature fades in at 12.4 if the style says 12.4, not at 13.
- **One scene, three backends.** Metal, Vulkan and D3D12 draw from the same prepared scene, so a fix in the renderer reaches all three.

## Build

Zig 0.16.0.

```
zig build test      # run the suite
zig build lib       # libcharttable.a and the header, into zig-out
zig build shared    # the shared library, beside it
```

Add `-Dcodec-source` to compile libwebp and libpng in rather than link the platform copies. A cross build needs it. `-Dgpu=vk` picks the Vulkan backend on Windows, where D3D12 is the default. `-Dversion` sets what `charttable_version()` reports and what the shared library stamps into its soname. A release passes the tag, and a source build reports `0.0.0-dev`.

## Status

charttable is early. The engine draws, and the spec coverage above is the current work. See DESIGN.md for the architecture, the conformance tiers and the milestone plan.

> [!NOTE]
> Extracted from the [Lookout Marine](https://github.com/beetlebugorg/lookout-core) rendering engine and generalized. Where Lookout renders one hard-wired nautical portrayal, charttable renders whatever the style says. It is a **clean-room** implementation of the published spec. See THIRD-PARTY-NOTICES.md for provenance.

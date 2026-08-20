# charttable — design

**A native map renderer that implements the MapLibre style spec.** One Zig
library with a C ABI. Style JSON + vector tiles in; 60 fps Metal / Vulkan /
D3D12 / SDL frames out. Extracted from the lookout-core engine and
generalized: where lookout renders one hard-wired portrayal, charttable
renders whatever the style says.

> Clean room. charttable implements the *published* MapLibre Style
> Specification (https://maplibre.org/maplibre-style-spec/). Its code comes
> from lookout-core and tile57 (same author) or is written new. No MapLibre
> source is consulted. See THIRD-PARTY-NOTICES.md for the one disclosed
> pre-policy exception and the standing rule.

## Where it sits

```
tile57                      charttable                    shells
S-57/S-101 charts   ──►     style JSON + tiles    ──►     SwiftUI / GTK4 /
→ PMTiles (MVT/MLT)         + sprites + glyphs            WinUI3 / Compose
→ MapLibre style            → camera, layout,             (lookout keeps its
→ sprites, glyphs           tessellation, GPU             own C ABI, backed
                            → pixels                      by charttable)
```

tile57's emitted style is the first style charttable must render perfectly,
but nothing in charttable may know it is drawing a nautical chart. The test
for every API decision: would it make sense rendering OpenStreetMap tiles?

## What the surveys established

- lookout-core's `src/` is a **scene consumer**: camera, four GPU backends,
  atlases, raster underlay, overlay — ~14k lines of generic engine. All
  tessellation lives in tile57 behind `tile57_chart_gpu_scene`.
- charttable therefore = the extracted back half **plus a net-new front
  half**: style parser, expression engine, tile sources, tessellators
  (fill/line/symbol/text + collision), and the batcher (today inside tile57).
- The `feat/maplibre` branch (MapLibre Native behind lookout's ABI) left a
  measured record of what a style renderer must not get wrong; its lessons
  are folded in below as performance invariants.
- The geometric kernels charttable needs already exist in-house: tile57 owns
  triangulation, line stroking, dash geometry, label layout, SDF glyph and
  sprite baking; lookout's `overlay.zig` owns a second stroke/dash/canvas
  tessellator. Port, don't rewrite.

## Module map

```
charttable/
  build.zig, build.zig.zon        Zig 0.16.0
  include/charttable.h            the C ABI (see sketch below)
  shaders/                        chart/pattern/sprite/sdf per backend,
                                  ported from tile57 + lookout src/shaders
  src/
    root.zig                      public Zig surface + test collector
    capi.zig                      C ABI over map.zig
    map.zig                       orchestrator: style+sources+camera+frame
    camera.zig                    from lookout, near-verbatim
    style/
      style.zig                   style JSON → typed Style (root, sources,
                                  layers, sprite, glyphs, metadata)
      properties.zig              per-layer-type paint/layout tables, from
                                  the published spec (defaults, types,
                                  data-driven allowed?, transitionable?)
      expr.zig                    expression parse + typecheck + const fold
      eval.zig                    evaluator (zoom, feature, feature-state)
      filter.zig                  filter application (expression syntax
                                  first; legacy operators tier 2)
      color.zig                   CSS colors: named/#hex/rgb[a]/hsl[a]
    source/
      coord.zig                   tile ids, xyz↔mercator, wrap
      mvt.zig                     MVT decode          (port: tile57)
      mlt.zig                     MLT v1 decode       (port: tile57)
      pmtiles.zig                 PMTiles reader      (port: tile57)
      geojson.zig                 tier 2
      cache.zig                   tile LRU + worker pool (model: raster.zig)
    layout/
      fill.zig                    polygon triangulation   (port: tile57)
      line.zig                    joins/caps/dash stroking (port: tile57 +
                                  overlay.zig dash geometry)
      symbol.zig                  icon/text placement, per-tile layout
      collide.zig                 global placement/collision pass
      glyphs.zig                  glyph PBF decode (fields 5/6 zigzag
                                  sint32!) + SDF atlas
      sprite.zig                  sprite index/sheet + runtime images +
                                  missing-image hook
    scene/
      types.zig                   Vertex/Quad/Range/Draw/Uniforms — ours,
                                  informed by the battle-tested tile57
                                  layouts (anchor+offset split, map_align)
      batch.zig                   range merge → draw list (reimplement)
    gpu/
      gpu.zig                     comptime backend selector (from lookout)
      gpu_metal.zig + metal_shim.m/.h
      gpu_vk.zig    + c_vk.zig
      gpu_d3d12.zig + c_d3d12.zig
      gpu_sdl.zig   + c_sdl.zig
    raster.zig                    raster sources/layers (rework of
                                  lookout raster.zig — spec "raster" type)
    util/ png.zig, lock.zig, clock.zig   (from lookout, verbatim)
```

Left behind in lookout: plugin host, library.zig (S-57 exchange sets),
pick.zig (S-52 pick ranking), mariner state, own-ship/follow, markers,
overlay (returns later via a geojson source + spec layers).

## The scene model

**Per-tile buckets, tile-local coordinates, global symbol placement.**

lookout builds one whole-view scene and rebuilds when the camera leaves a
25%-overscan coverage box. That is the right shape when one producer owns the
whole view, but a style-spec renderer consumes tiles that arrive
independently, so the unit of tessellation is the tile:

- **Layout** runs per (tile × style-layer) on worker threads: decode →
  filter → evaluate data-driven properties → tessellate into *buckets*.
  A bucket's vertices are **tile-local f32** (origin at tile corner); each
  tile draws with its own tile→clip matrix (lookout's origin-relative rule:
  absolute world f32 quantizes visibly at depth; `overlay.zig` proved the
  fix).
- **Fills and lines** draw straight from resident buckets — pan/zoom/rotate
  never re-tessellates; a zoom change is a matrix change until the tile set
  itself changes (then new tiles lay out async while old ones keep drawing —
  never block a frame on layout).
- **Symbols** lay out per tile (glyph runs, anchors, geometry) but *place*
  globally: a collision pass over resident tiles picks winners at the
  current zoom/rotation, throttled and off the render thread. Fractional
  zoom throughout.
- **Two vertex streams per bucket.** Stream A: geometry (position, extrude
  normal, tex coords). Stream B: evaluated paint (color, width, opacity,
  halo…). A paint-only change (palette flip, setPaintProperty) re-evaluates
  and re-uploads stream B without touching geometry — the "day/night for the
  price of a buffer refill" answer. Zoom-interpolated data-driven paint
  bakes (value@zmin, value@zmax) pairs and mixes in the shader with a per-
  frame `t` uniform; non-data-driven paint is a plain uniform.
- **Kept from lookout verbatim**: the anchor+screen-offset vertex split and
  `map_align` flag (offsets stated in map frame rotate with the view — what
  makes rotation free); per-range paint keys; the two-phase opaque-first
  depth pass; the 128-byte uniform block discipline; honest damage tracking
  (`needs_redraw`), no timers, idle means idle.

Draw order is style order: layer index → bucket sort keys within a layer
(`*-sort-key`), with the opaque-fill front-to-back pre-pass preserved as a
pure optimization (it must never change the image).

## Style-spec conformance tiers

**The end state is 100% of the published spec**, proven against the
official conformance suite: the maplibre-style-spec repository's
integration-test fixtures are vendored under `test/spec/` (test data, with
license — see THIRD-PARTY-NOTICES.md) and run as the oracle. A harness
walks every fixture, compares outputs (values within numeric tolerance,
error-for-error without matching message text, compile-time
feature/zoom-constancy flags against expr.Deps), and emits a conformance
scoreboard; unimplemented features live on an explicit shrinking skip
list, never silently. Render-level fixtures join once the raster path
exists (perceptual diff, like the tile57 PNG parity gate).

Tiers below are the *order of work*, not the scope. Tier 1 is what
tile57's emitted styles exercise, plus the spec core no generic style
survives without. Tiers are cumulative; each ships behind tests before
the next starts.

**Tier 1 — root**: `version: 8`, `name`, `sources`, `layers`, `sprite`
(string form), `glyphs` template, `metadata` (opaque passthrough).
**Sources**: `vector` with `tiles` templates or `pmtiles://` file URLs
(charttable never does networking: `file://` and pmtiles built in,
everything else through the host resource provider), `minzoom`/`maxzoom`,
XYZ scheme, overzoom past maxzoom, plus the `encoding: "mlt"` extension
tile57 emits. **Layers**: `background`, `fill`, `line`, `symbol`, `raster`
— with the paint/layout properties the spec defines for them (fill: color/
opacity/antialias/pattern/sort-key; line: color/width/opacity/dasharray/
cap/join/sort-key; symbol: the icon-*/text-*/symbol-* set tile57 uses plus
placement/anchor/offset/overlap/optional/max-angle/spacing/rotation-
alignment/visibility; raster: opacity). `minzoom`/`maxzoom`/`filter`/
`visibility` on every layer.
**Expressions**: the full operator set tile57 emits (`get coalesce zoom
match literal case has all any ! == != < <= > >= in concat let var at
slice index-of to-color to-rgba rgba to-number to-string + - * / round
floor`) **plus** `interpolate` (linear/exponential) and `step`, because no
generic style omits them. Spec semantics throughout: typed evaluation,
`get` of an absent property is null, an evaluation error falls back to the
property default (tile57's styles contain dead branches that *depend* on
graceful null handling — a strict-error evaluator blanks the whole
point_symbols layer).
**Sprites**: index + sheet, 1x/@2x, non-SDF; runtime images via
`add_image`; **missing-image callback** (mandatory — tile57 soundings and
contour labels only exist through it). **Glyphs**: fontnik SDF PBF ranges;
fields 5/6 are zigzag sint32.

**Tier 2**: `circle` layers; `geojson` sources (feeds lookout's overlay/
markers/AIS story); legacy filter syntax; `feature-state`; `format`/
`image` expressions; `line-pattern`/`fill-extrusion?`; sprite JSON object
form; `raster` sources over HTTP via provider; style `transition`s;
`queryRenderedFeatures`.

**Tier 3**: `raster-dem` + `hillshade`, `heatmap`, `terrain`, `sky`,
`projection`/globe, video/image sources.

Out of scope at any tier: networking inside the library, disk caches
(hosts own persistence; the ambient-cache lesson), UI chrome.

## Expression engine

Parse once per style into a typed tree; evaluate per feature at layout.
The maplibre-branch profile (C32: ~730/1395 worker samples in expression
evaluation; 85 layers × every `lines` feature) dictates the design:

1. **Constant-fold at parse.** A `match` on palette tokens with literal
   arms folds to a token→RGBA table; `["/",["get","scale"],CONST]` folds
   its divisor; expressions with no `get`/`zoom`/`var` reduce to values.
2. **Index layers by source-layer.** A tile's features touch only the
   style layers whose `source-layer` matches — never the full layer list.
3. **Split filter by zoom dependence.** The zoom-only conjuncts of a
   filter (`vz`/`oz` gates) evaluate per frame against fractional zoom on
   the *resident* bucket (a per-feature zoom threshold baked at layout →
   compare in shader or a cheap CPU mask), so SCAMIN-style gates never
   re-run layout and never snap to integer zooms. Feature-only conjuncts
   run once at layout.
4. **Interned property keys.** Feature attribute lookup by pre-resolved
   index into the tile's key table, not string hashing per evaluation.
5. **Evaluation errors are values.** Fall back to the property default,
   count them, expose a diagnostics channel — never throw mid-tile.

## Style compilation

The style never reaches the render loop as an expression tree. It compiles
in stages, each stage hoisting work out of the hotter loop below it:

1. **Parse time — fold.** Constant subtrees collapse to literals
   (implemented in style/expr.zig). A palette `match` with literal arms and
   a feature-driven input keeps its shape but every arm is a value.
2. **Layer programs.** Per (layer × property), classify: *constant* →
   pipeline state or uniform, set once; *zoom-only* → evaluated per frame
   into a per-layer uniform (a scalar curve walk, nothing per feature);
   *data-driven* → compiled to a flat bytecode program over **interned
   property slots** (the tile layer's key table is resolved once per tile,
   then the program never hashes a string or chases a tree pointer);
   *zoom × data* → the program runs at layout against the tile's two
   covering zoom stops and bakes a (v0, v1) pair per vertex; the shader
   mixes by the frame's `zoom_t` uniform.
3. **LUT compilation — the palette fast path.** A data-driven color whose
   program reduces to "small discrete input → color" (a `match`/`case` over
   ≤256 values — exactly tile57's `color_token` shape) compiles further:
   the vertex carries the input's palette INDEX and the color table becomes
   a uniform LUT. A scheme flip or `setPaintProperty` on such a layer
   rewrites a ≤4 KB LUT — no re-layout, no buffer refill, not even a paint-
   stream upload. This is how day/night gets cheaper than lookout's own
   engine (which re-tessellates on scheme change today).
4. **Zoom gates are already shader-side.** Per-feature zoom windows bake
   into vertices (zmin/zmax) and compare against a uniform — a zoom ease
   re-evaluates nothing.
5. **Tier 3 — expression → shader codegen.** For expression shapes that
   survive per-fragment/per-vertex evaluation profitably, emit shader
   source at style load: MSL first (the Metal backend already compiles
   source at runtime; a generated function slots into the same pipeline
   set), SPIR-V emitter later for Vulkan. This is an optimization tier on
   top of the layer programs, never a correctness requirement — every
   compiled form must produce pixels identical to the interpreter, and the
   interpreter stays as the reference oracle in tests.

## C ABI sketch (`include/charttable.h`)

House rules from lookout.h: opaque handle, every entry point under one
mutex, borrowed pointers valid until the next call of their kind, SI units,
logical points in, `charttable_` prefix, no wall-clock reads (host passes
time).

```c
typedef struct charttable charttable;
typedef struct { double lon, lat, zoom, bearing_deg; } charttable_view;
/* zoom: MapLibre convention (512px world tile) — lookout converts at its edge */

/* lifecycle */
charttable *charttable_open(const charttable_options *opts);
int  charttable_attach_surface(charttable*, charttable_native_kind, void *handle,
                               uint32_t w_px, uint32_t h_px);
void charttable_detach_surface(charttable*);
int  charttable_resize(charttable*, uint32_t w_pt, uint32_t h_pt);
void charttable_set_pixel_density(charttable*, float);
void charttable_close(charttable*);

/* style */
int  charttable_set_style_json(charttable*, const char *json, size_t len);
const char *charttable_style_diagnostics(charttable*, size_t *out_len);
int  charttable_set_paint_property (charttable*, const char *layer,
                                    const char *prop, const char *json_value);
int  charttable_set_layout_property(charttable*, const char *layer,
                                    const char *prop, const char *json_value);
int  charttable_set_filter(charttable*, const char *layer, const char *json);
int  charttable_set_layer_visibility(charttable*, const char *layer, int on);

/* resources: host supplies bytes for anything that is not a local file.
   kinds: tile, sprite_json, sprite_image, glyphs, style, image */
void charttable_set_resource_provider(charttable*,
        const charttable_resource_provider *cb, void *user);
void charttable_resource_respond(charttable*, uint64_t req_id,
        const uint8_t *bytes, size_t len, int status);

/* images (sprite additions + missing-image answers) */
int  charttable_add_image(charttable*, const char *name, const uint8_t *rgba,
        uint32_t w, uint32_t h, float pixel_ratio, int sdf);
void charttable_remove_image(charttable*, const char *name);
/* missing-image: callback on provider vtable; host answers via add_image */

/* camera + input (logical points) */
void charttable_set_view(charttable*, const charttable_view*);
void charttable_get_view(charttable*, charttable_view*);
void charttable_pan(charttable*, float dx_pt, float dy_pt);
void charttable_zoom_at(charttable*, double dzoom, float x_pt, float y_pt);
void charttable_rotate_drag(charttable*, float x0, float y0, float x1, float y1);
void charttable_fling(charttable*, double vx, double vy);
void charttable_screen_to_geo(charttable*, float x_pt, float y_pt,
                              double *lon, double *lat);
void charttable_geo_to_screen(charttable*, double lon, double lat,
                              float *x_pt, float *y_pt);

/* frame loop */
int  charttable_render(charttable*);          /* draws if dirty; returns drew? */
int  charttable_needs_redraw(charttable*);    /* animation/layout pending */
int  charttable_idle(charttable*);            /* honest: tiles+placement settled */
int  charttable_snapshot_rgba(charttable*, uint8_t *dst, size_t len);
```

Deliberate differences from the maplibre-native experience, each traceable
to a concern: thread contract documented and enforced by us, not
discovered (C12); scale factor changeable after open; set_filter replaces
the whole filter *and the docs say so loudly* (C13); zoom is spec-
convention with exactly one conversion at lookout's edge (C14); tile
requests park until their source is ready — an unanswerable request is
never cached as empty (C33); `idle()` means placed, not "style loaded"
(C12); no ambient cache (C28).

## What ports from where

| charttable target | source | motion |
|---|---|---|
| camera.zig, util/{png,lock,clock}.zig, gpu.zig, c_*.zig | lookout src/ | verbatim |
| gpu_{metal,vk,d3d12,sdl}.zig + shims | lookout src/ | rename tile57_gpu_* → scene/types.zig; unify Metal-indexed vs Vulkan/SDL-deindexed; one pipeline enum |
| shaders (chart/pattern/sprite/sdf + overlay) | tile57 shaders/ + lookout src/shaders | carry; regenerate .spv by hand as documented |
| scene/types.zig | new, informed by tile57.h:844-1079 layouts | ours to own |
| scene/batch.zig | reimplement (today tile57_gpu_batch) | ~small |
| source/{mvt,mlt,pmtiles}.zig | tile57 src/tiles/ | port, strip chart-isms |
| source/cache.zig | model on lookout raster.zig LRU/worker pool | rework |
| layout/{fill,line}.zig | tile57 tessellators + overlay.zig dash/stroke | port the geometry, drop the portrayal |
| layout/{symbol,collide,glyphs,sprite}.zig | tile57 sprite/glyph code + new placement | port + new |
| raster.zig | lookout raster.zig | rework reader behind source API |
| style/*, map.zig, capi.zig | new | spec-driven |

## Milestones

- **M0 scaffold** — repo builds; util+camera ported with their tests;
  `zig build test` green.
- **M1 style core** — parse + expressions + filters; expression test
  corpus written from the spec pages; tile57's emitted style parses with
  zero diagnostics.
- **M2 tiles** — pmtiles + MVT (then MLT) decode; source cache; tile
  pipeline visible in a debug dump.
- **M3 first light** — background/fill/line end-to-end: render
  US5MD1MC.pmtiles + tile57 style to PNG headless; compare against
  `tile57_chart_png` reference output. *The parity check the maplibre
  branch skipped, first.*
- **M4 symbols** — sprite + glyphs + placement/collision + missing-image
  hook; soundings and labels correct at fractional zooms.
- **M5 live style** — paint-stream refills, visibility diffs, palette
  flip timing target: no re-tessellation, one frame.
- **M6 integration** — lookout backend swap behind lookout.h; day-run bar
  passes on charttable; Metal first, then Vulkan/SDL, D3D12 last.

## Performance invariants (the concerns.md inheritance)

- Idle means idle: no repaint without damage, placement settles and stops.
- Paint changes never re-layout; layout changes re-layout only the tiles
  whose buckets they touch.
- Filters evaluate at fractional zoom; zoom-gates live in the resident
  scene, not in re-layout.
- A frame never allocates on the render thread; staging happens on
  workers; the render thread swaps pointers (lookout's async_stage rule).
- Never trust "loaded" — completeness is measured (tiles resident and
  placed), not asserted.
- Diagnostics are library options, not getenv reads.

## Open questions (running list)

1. MLT decode scope — tile57's encoder subset first, or full MLT v1?
2. Collision data structure — grid (lookout has one in tile57's declutter)
   vs. something new; measure before choosing.
3. `charttable_options`: backend choice, MSAA, colorspace — finalize when
   the backends port.
4. Does lookout's overlay become a charttable geojson source in M6, or
   stay lookout-side until Tier 2? (Leaning: stay, then migrate.)

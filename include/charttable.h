/* charttable — a native map renderer implementing the MapLibre style spec.
 *
 * One opaque handle, one mutex behind it. Every function here is safe to call
 * from any thread and is serialized internally, with ONE exception that is a
 * platform rule rather than ours: charttable_attach_surface, _render and
 * _snapshot_rgba must be called from the thread that owns the surface.
 *
 * Conventions:
 *   - Sizes and positions are LOGICAL POINTS; the library scales by the
 *     pixel density the host declares (charttable_set_pixel_density), which
 *     may change after open.
 *   - Returned pointers are BORROWED and valid until the next call of the
 *     same function. Copy anything you need to keep.
 *   - Zoom is the MapLibre convention (a 512 px world tile at z0).
 *   - Nothing reads a wall clock: the host passes elapsed time to
 *     charttable_tick.
 *   - Every function is null-safe on the handle.
 *
 * Return codes: CHARTTABLE_OK (0) on success, a negative CHARTTABLE_ERR_* on
 * failure, except where documented otherwise.
 */
#ifndef CHARTTABLE_H
#define CHARTTABLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CHARTTABLE_OK 0
#define CHARTTABLE_ERR_HANDLE (-1)
#define CHARTTABLE_ERR_ARG (-2)
#define CHARTTABLE_ERR_STYLE (-3)
#define CHARTTABLE_ERR_SOURCE (-4)
#define CHARTTABLE_ERR_SURFACE (-5)
#define CHARTTABLE_ERR_MEMORY (-6)
#define CHARTTABLE_ERR_UNSUPPORTED (-7)

typedef struct charttable charttable;

typedef struct {
    uint32_t workers;     /* tile decode threads; 0 = default */
    uint64_t cache_bytes; /* resident decoded-tile budget; 0 = default */
} charttable_options;

typedef struct {
    double lon;
    double lat;
    double zoom;
    double bearing_deg;
} charttable_view;

/* Called once per image name the style asks for and the sprite cannot
 * resolve. `name` is borrowed for the call. Answer with charttable_add_image;
 * calling it from inside this callback is supported. */
typedef void (*charttable_missing_image_fn)(const char *name, void *user);

/* ---- lifecycle ---------------------------------------------------------- */

charttable *charttable_open(const charttable_options *opts);
void charttable_close(charttable *);

/* How to interpret the `native` handle passed to charttable_attach_surface. */
typedef enum {
    CHARTTABLE_NATIVE_NONE = 0,            /* offscreen only (snapshot) */
    CHARTTABLE_NATIVE_METAL_LAYER = 1,     /* CAMetalLayer*  (metal backend) */
    CHARTTABLE_NATIVE_WIN32_HWND = 4,      /* charttable_win32_window* (vk, d3d12) */
    CHARTTABLE_NATIVE_X11_WINDOW = 5,      /* charttable_x11_window*     (vk) */
    CHARTTABLE_NATIVE_ANDROID_WINDOW = 7,  /* ANativeWindow*             (vk) */
    CHARTTABLE_NATIVE_WAYLAND_SURFACE = 8, /* charttable_wayland_surface* (vk) */
    CHARTTABLE_NATIVE_D3D12_PANEL = 10     /* no handle (d3d12 backend): the
                                            * renderer makes a composition
                                            * swapchain and the host composes
                                            * it; fetch it with
                                            * charttable_d3d12_swapchain */
} charttable_native_kind;

/* Create the render surface. `native` is a CAMetalLayer* when kind is
 * CHARTTABLE_NATIVE_METAL_LAYER, NULL for CHARTTABLE_NATIVE_D3D12_PANEL and
 * for offscreen-only rendering. */
int charttable_attach_surface(charttable *, int kind, void *native,
                              uint32_t w_px, uint32_t h_px);
void charttable_detach_surface(charttable *);

/* D3D12-panel mode only. The renderer-owned IDXGISwapChain* for
 * ISwapChainPanelNative::SetSwapChain; NULL on any other kind or backend. The
 * renderer keeps ownership and rebuilds its buffers on charttable_resize, so
 * drop your reference before charttable_detach_surface. */
void *charttable_d3d12_swapchain(charttable *);
int charttable_resize(charttable *, uint32_t w_pt, uint32_t h_pt);
void charttable_set_pixel_density(charttable *, float density);

/* The physical size multiplier for symbols, text and line widths. S-52
 * specifies symbol sizes in millimeters and the sprite is rasterized at the
 * catalogue's own px-per-mm, so a host that wants those physical sizes on ITS
 * display passes the ratio here. 1.0 (default) draws sprite cells at their
 * logical size. Uniform-only: no relayout, no re-upload. */
void charttable_set_size_scale(charttable *, float scale);

/* The zoom band the camera may move in (default 0..24). A chart library has
 * a natural floor -- below it every tile in the world is wanted and the data
 * is a smear -- and only the host knows what it is. */
void charttable_set_zoom_range(charttable *, double min_zoom, double max_zoom);

/* The scene contract's struct-layout guard. Compare against the value your
 * build expects: a mismatch means header and library disagree about the
 * vertex/uniform layout, which shades wrong rather than failing. */
uint32_t charttable_abi_layout(void);

/* The version this library was built as ("0.4.1"), NUL-terminated. The string
 * is static: do not free it, and it needs no handle. */
const char *charttable_version(void);

/* ---- style and sources -------------------------------------------------- */

int charttable_set_style_json(charttable *, const char *json, size_t len);

/* Every degradation the style parse recorded, one per line, NUL-terminated.
 * Borrowed until the next call to this function. Never NULL for a live
 * handle. */
const char *charttable_style_diagnostics(charttable *, size_t *out_len);

/* Point a style source name at a local pmtiles archive. The decoder follows
 * the style's `encoding` field, falling back to the archive's declared tile
 * type, so MVT and MLT archives both just work. */
int charttable_add_source_pmtiles(charttable *, const char *name,
                                  const char *path);

/* Set one paint property from a JSON fragment ("#ff0000", 0.5, or a whole
 * expression). A color or opacity the layer applies uniformly refills the
 * paint stream and never re-lays-out: returns 1 when it was served that way,
 * 0 when it needed a rebuild, negative on error. */
int charttable_set_paint_property(charttable *, const char *layer,
                                  const char *name, const char *json_value,
                                  size_t len);

/* Layout is geometry, so this always rebuilds. */
int charttable_set_layout_property(charttable *, const char *layer,
                                   const char *name, const char *json_value,
                                   size_t len);

/* Replace a layer's filter WHOLESALE; NULL clears it. There is no merge and
 * no partial update -- whatever you pass becomes the ENTIRE filter, and a
 * host that assumes otherwise silently widens what draws. */
int charttable_set_filter(charttable *, const char *layer,
                          const char *json_filter, size_t len);

int charttable_set_layer_visibility(charttable *, const char *layer, int on);

/* ---- host-supplied resources -------------------------------------------- */

/* Called when charttable needs tile bytes it cannot fetch itself. Answer with
 * charttable_resource_respond, at any time and from any thread: the request
 * PARKS until you do, and a slow answer never becomes a permanently missing
 * tile. Answering from inside this callback is supported. */
typedef void (*charttable_resource_fn)(uint64_t req_id, const char *source,
                                       uint32_t z, uint32_t x, uint32_t y,
                                       void *user);

void charttable_set_resource_provider(charttable *, charttable_resource_fn cb,
                                      void *user);

/* Route a style source name through the host: every tile of that source
 * becomes a callback. Vector MVT over z0-22. */
int charttable_add_source_provided(charttable *, const char *name);

/* The same, saying what the source actually serves. A source that stops at
 * z12 must say so: the build zoom is clamped by the shallowest maxzoom, and
 * the default 22 makes the map ask for tiles you can only 404. */
typedef struct {
    uint32_t kind;     /* 0 vector, 1 raster (PNG/JPEG bytes) */
    uint32_t encoding; /* 0 MVT, 1 MLT */
    uint32_t minzoom, maxzoom;
} charttable_provided_opts;

int charttable_add_source_provided_opts(charttable *, const char *name,
                                        const charttable_provided_opts *);

/* Answer one request. status 0 = bytes attached, 1 = no tile there, 2 = tried
 * and failed. Only status 0 reads `bytes`, which is copied before this
 * returns. Statuses 1 and 2 are remembered; a DELAY never is. An unknown or
 * already-answered id is ignored. */
#define CHARTTABLE_RESOURCE_OK 0
#define CHARTTABLE_RESOURCE_EMPTY 1
#define CHARTTABLE_RESOURCE_FAILED 2
void charttable_resource_respond(charttable *, uint64_t req_id,
                                 const uint8_t *bytes, size_t len, int status);

/* ---- images ------------------------------------------------------------- */

/* The style's sprite sheet: MapLibre sprite index JSON + its PNG. Replaces
 * any sheet already loaded, along with runtime images added before it. */
int charttable_set_sprite(charttable *, const char *index_json,
                          size_t json_len, const uint8_t *png, size_t png_len);

/* A host-baked SDF glyph sheet: an RGBA atlas plus an index naming each
 * glyph's UVs and its metrics in EM units:
 *
 *   {"em_px": 32, "pad": 6,
 *    "glyphs": {"65": [u0, v0, u1, v1, off_x, off_y, w, h, advance]}}
 *
 * For a host whose text engine bakes its own atlas (tile57_bake_glyph_sdf
 * emits exactly this), so it need not also produce fontnik PBFs. */
int charttable_set_glyph_sheet(charttable *, const char *index_json, size_t json_len,
                               const uint8_t *rgba, uint32_t w, uint32_t h);

/* One fontnik glyph-PBF range into the SDF text atlas. */
int charttable_add_glyphs(charttable *, const uint8_t *pbf, size_t len);

void charttable_set_missing_image_callback(charttable *,
                                           charttable_missing_image_fn cb,
                                           void *user);

/* Straight-alpha RGBA8, w*h*4 bytes, copied before this returns. Works with
 * or without a style sprite. */
int charttable_add_image(charttable *, const char *name, const uint8_t *rgba,
                         uint32_t w, uint32_t h, float pixel_ratio);
void charttable_remove_image(charttable *, const char *name);

/* ---- camera ------------------------------------------------------------- */

void charttable_set_view(charttable *, const charttable_view *);
void charttable_get_view(charttable *, charttable_view *);
void charttable_pan(charttable *, float dx_pt, float dy_pt);
void charttable_zoom_at(charttable *, double dzoom, float x_pt, float y_pt);

/* Zoom about a screen point, EASED over the next frames, with the world point
 * under the cursor held fixed the whole way. What a wheel, pinch or zoom
 * button should call; _zoom_at is the instant form. */
void charttable_zoom_toward(charttable *, double dzoom, float x_pt, float y_pt);

/* Start a fling at vx, vy LOGICAL POINTS PER SECOND; (0,0) stops one. It
 * decays inside charttable_tick and keeps needs_redraw true until it
 * settles. */
void charttable_fling(charttable *, double vx, double vy);
void charttable_screen_to_geo(charttable *, float x_pt, float y_pt,
                              double *lon, double *lat);
void charttable_geo_to_screen(charttable *, double lon, double lat,
                              float *x_pt, float *y_pt);

/* ---- the frame loop ----------------------------------------------------- */

/* Advance animation and tile loading. `dt_ms` is the host's elapsed time. */
int charttable_tick(charttable *, double dt_ms);

/* Is there a FRAME TO DRAW? Anything pending -- loading, an animation, a
 * rebuild owed -- plus a camera that has moved since the last frame reached
 * the screen. Panning or zooming inside the built coverage rebuilds nothing
 * and is still damage, because the matrix changed. */
int charttable_needs_redraw(charttable *);

/* Honest completeness: every tile this view asked for has an answer, the
 * scene covers the view, and nothing is animating. Not "the style loaded",
 * and deliberately NOT the negation of needs_redraw: a camera that moved but
 * whose tiles are all resident is COMPLETE, it just owes a frame. */
int charttable_idle(charttable *);

/* Tiles this view is still waiting on, for a progress readout. */
uint32_t charttable_pending_tiles(charttable *);

/* Draw into the attached surface. Returns 1 if it drew, 0 if there was
 * nothing to draw, negative on error. */
int charttable_render(charttable *);

/* Render offscreen and copy RGBA8 (top-down, w*h*4) into dst. */
int charttable_snapshot_rgba(charttable *, uint8_t *dst, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* CHARTTABLE_H */

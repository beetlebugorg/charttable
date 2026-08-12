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

/* How to interpret the pointer passed to charttable_attach_surface. */
#define CHARTTABLE_NATIVE_NONE 0        /* offscreen only (snapshots)      */
#define CHARTTABLE_NATIVE_METAL_LAYER 1 /* CAMetalLayer* (macOS and iOS)   */

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

/* Create the render surface. `native` is a CAMetalLayer* when kind is
 * CHARTTABLE_NATIVE_METAL_LAYER, or NULL for offscreen-only rendering. */
int charttable_attach_surface(charttable *, int kind, void *native,
                              uint32_t w_px, uint32_t h_px);
void charttable_detach_surface(charttable *);
int charttable_resize(charttable *, uint32_t w_pt, uint32_t h_pt);
void charttable_set_pixel_density(charttable *, float density);

/* The scene contract's struct-layout guard. Compare against the value your
 * build expects: a mismatch means header and library disagree about the
 * vertex/uniform layout, which shades wrong rather than failing. */
uint32_t charttable_abi_layout(void);

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

/* ---- images ------------------------------------------------------------- */

/* The style's sprite sheet: MapLibre sprite index JSON + its PNG. Replaces
 * any sheet already loaded, along with runtime images added before it. */
int charttable_set_sprite(charttable *, const char *index_json,
                          size_t json_len, const uint8_t *png, size_t png_len);

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
void charttable_screen_to_geo(charttable *, float x_pt, float y_pt,
                              double *lon, double *lat);
void charttable_geo_to_screen(charttable *, double lon, double lat,
                              float *x_pt, float *y_pt);

/* ---- the frame loop ----------------------------------------------------- */

/* Advance animation and tile loading. `dt_ms` is the host's elapsed time. */
int charttable_tick(charttable *, double dt_ms);

/* Is there anything left to do — animation, loading, or a pending rebuild? */
int charttable_needs_redraw(charttable *);

/* Honest completeness: every tile this view asked for has an answer, the
 * scene covers the view, and nothing is animating. Not "the style loaded". */
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

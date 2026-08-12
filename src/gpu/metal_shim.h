/* metal_shim.h — the C face of the Metal transport (metal_shim.m).
 *
 * Ported from lookout-marine src/metal_shim.h and adapted to charttable's
 * scene contract: TWO vertex streams (geometry at [[buffer(0)]], paint at
 * [[buffer(1)]]), uniforms at vertex [[buffer(2)]] / fragment [[buffer(1)]],
 * and no overlay pipeline (charttable's overlay story is a style layer).
 *
 * gpu_metal.zig drives rendering exclusively through these calls; all
 * ObjC/Metal lives behind them. One context owns the device, queue, the
 * runtime-compiled shader library, the pipelines and the sampler. Frames
 * encode one render pass each — either into a CAMetalLayer drawable (window
 * path) or into an offscreen texture that can be read back (snapshot path).
 *
 * Threading: resource creation (buffers, textures) may run on any thread —
 * that is what lets a build worker STAGE a scene off the render thread —
 * but frames must be begun/recorded/ended from one thread at a time.
 * Errors land in the caller's err buffer.
 */
#ifndef CHARTTABLE_METAL_SHIM_H
#define CHARTTABLE_METAL_SHIM_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ctm_ctx ctm_ctx;
typedef struct ctm_frame ctm_frame;
typedef struct ctm_buf ctm_buf;
typedef struct ctm_tex ctm_tex;

/* The pipelines, matching scene/types.zig Pipeline. `raster` folds into
 * sprite on Metal (a raster tile IS a textured quad) — the backend maps it. */
enum {
    CTM_PIPE_FILL = 0,    /* fill_vert / fill_frag       */
    CTM_PIPE_SPRITE = 1,  /* sprite_vert / sprite_frag   */
    CTM_PIPE_SDF = 2,     /* sprite_vert / sdf_frag      */
    CTM_PIPE_PATTERN = 3, /* pattern_vert / pattern_frag */
    CTM_PIPE_COUNT = 4,
};

#define CTM_ERR_LEN 256

/* Create the device/queue/pipelines. `metal_layer` is a CAMetalLayer* to
 * present into, or NULL for offscreen-only. `msl_source` is the shader library
 * source (shaders/metal.metal, compiled here at runtime). Returns NULL with
 * `err` filled on failure. `want_msaa` requests 4x (granted whenever the
 * device supports it; *msaa_out reports the decision). */
ctm_ctx *ctm_create(void *metal_layer, const char *msl_source, int want_msaa,
                    int *msaa_out, char err[CTM_ERR_LEN]);
void ctm_destroy(ctm_ctx *c);

/* Layer geometry. ctm_layer_sync sizes the layer's drawableSize from its
 * bounds × contentsScale and reports the resulting pixel size; no-ops (and
 * reports 0×0) without a layer. */
void ctm_layer_sync(ctm_ctx *c, uint32_t *w_px, uint32_t *h_px);

/* Immutable GPU resources. Buffers are shared-storage copies of `bytes`;
 * textures are RGBA8 sampler textures (the SDF atlas uploads as RGBA too —
 * the shader samples .r). */
ctm_buf *ctm_new_buffer(ctm_ctx *c, const void *bytes, size_t len);
void ctm_free_buffer(ctm_buf *b);
/* Overwrite an existing buffer's contents in place (shared storage, so this
 * is a memcpy). Returns 0 when `len` exceeds the buffer. The paint stream
 * uses it: a zoom-only colour change refills stream B without touching
 * geometry or rebuilding the scene. */
int ctm_write_buffer(ctm_buf *b, const void *bytes, size_t len);
ctm_tex *ctm_new_texture_rgba(ctm_ctx *c, const void *rgba, uint32_t w, uint32_t h);
void ctm_free_texture(ctm_tex *t);

/* One frame = one render pass, cleared to `clear` (rgba 0..1). The window
 * variant acquires the layer's next drawable (NULL when none is available —
 * skip the frame); the offscreen variant renders into a readback texture of
 * the given pixel size. MSAA resolve is internal to both. */
ctm_frame *ctm_begin_frame(ctm_ctx *c, const float clear[4]);
ctm_frame *ctm_begin_offscreen(ctm_ctx *c, uint32_t w_px, uint32_t h_px, const float clear[4]);

void ctm_set_pipeline(ctm_frame *f, int which);
/* 1 = opaque pass (depth LESS + write, draw front-to-back); 0 = blended pass
 * (LESS, no write, draw in paint order). Default per frame is 0. */
void ctm_set_depth_mode(ctm_frame *f, int opaque);
/* Stream A: geometry (scene.Vertex or scene.Quad) at [[buffer(0)]]. */
void ctm_bind_vbuf(ctm_frame *f, ctm_buf *b);
/* Stream B: evaluated paint (scene.PaintVertex) at [[buffer(1)]], one entry
 * per stream-A vertex of the CURRENTLY bound geometry buffer. */
void ctm_bind_paint(ctm_frame *f, ctm_buf *b);
void ctm_bind_texture(ctm_frame *f, ctm_tex *t);
/* The 128-byte scene.Uniforms block: vertex [[buffer(2)]] + fragment
 * [[buffer(1)]] (the SDF fragment stage reads the halo colour). */
void ctm_set_uniforms(ctm_frame *f, const void *bytes, size_t len);
void ctm_draw(ctm_frame *f, uint32_t first, uint32_t count);
/* Indexed triangles against the bound vertex buffer; `first` in u32-index units. */
void ctm_draw_indexed(ctm_frame *f, ctm_buf *ib, uint32_t first, uint32_t count);

/* End the pass. The window variant presents and returns immediately; the
 * offscreen variant waits for completion and writes w*h*4 bytes of top-down
 * BGRA8 into out_bgra (the caller swizzles). Both destroy the frame. */
void ctm_end_frame(ctm_frame *f);
/* GPU time (ms) of the most recently COMPLETED window frame; 0 until one lands. */
double ctm_last_gpu_ms(ctm_ctx *c);
int ctm_end_offscreen_read(ctm_frame *f, void *out_bgra);

#ifdef __cplusplus
}
#endif
#endif

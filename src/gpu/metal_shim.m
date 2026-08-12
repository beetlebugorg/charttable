// metal_shim.m — Metal transport for the charttable renderer (see metal_shim.h).
//
// Ported from lookout-marine src/metal_shim.m. Differences for charttable:
//   * TWO vertex streams — geometry at [[buffer(0)]], paint at [[buffer(1)]]
//     (ctm_bind_paint) — so the uniform block moves to vertex [[buffer(2)]].
//   * Four pipelines (fill/sprite/sdf/pattern); no overlay pipeline and no
//     embedded overlay MSL — charttable's overlay story is a style layer.
// Everything else carries over: runtime MSL compilation, BGRA8 target, 4x
// MSAA resolve, memoryless depth/MSAA on TBDR GPUs, the in-flight drawable
// gate, and the offscreen readback path.
//
// Compiled WITHOUT ARC (-fno-objc-arc): objects live in plain C structs, so
// ownership is explicit retain/release, and every entry point that touches
// autoreleased objects runs its own pool — the callers are Zig/C with no pool
// of their own.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>
#include "metal_shim.h"

#if __has_feature(objc_arc)
#error "metal_shim.m must be compiled with -fno-objc-arc"
#endif

struct ctm_ctx {
    id<MTLDevice> device;          // retained
    id<MTLCommandQueue> queue;     // retained
    id<MTLRenderPipelineState> pipes[CTM_PIPE_COUNT]; // retained
    id<MTLSamplerState> sampler;   // retained
    CAMetalLayer *layer;           // NOT retained — the host view owns it
    id<MTLTexture> msaa;           // retained; lazily (re)sized 4x color target
    uint32_t msaa_w, msaa_h;
    int msaa_on;
    id<MTLTexture> depth;          // retained; lazily (re)sized depth target
    uint32_t depth_w, depth_h;
    id<MTLDepthStencilState> ds_opaque; // LESS + write (front-to-back opaque pass)
    id<MTLDepthStencilState> ds_blend;  // LESS, no write (paint-order blended pass)
    double last_gpu_ms;            // GPU time of the last COMPLETED frame (async;
                                   // written on the completion queue, read racily
                                   // for diagnostics only)
    // In-flight window-frame gate. nextDrawable BLOCKS the calling thread for
    // tens of ms when presents outpace the compositor; instead of stalling the
    // render thread there, ctm_begin_frame returns NULL when the pool is
    // saturated and the host simply skips the frame — the display link
    // retries next tick with input processing never starved.
    // A COUNTER, not a semaphore: permits return via drawable handlers, and a
    // handler can silently never fire (drawables dropped in a swapchain resize,
    // occlusion, backgrounding). The counter self-heals: no permit back within
    // 500ms of saturation means the outstanding presents are gone, not slow.
    _Atomic int inflight_n;
    _Atomic long inflight_ret_ms; // monotonic ms of the last permit return
};

static long ctm_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void ctm_inflight_return(ctm_ctx *c) {
    atomic_fetch_sub_explicit(&c->inflight_n, 1, memory_order_relaxed);
    atomic_store_explicit(&c->inflight_ret_ms, ctm_now_ms(), memory_order_relaxed);
}

struct ctm_frame {
    ctm_ctx *ctx;
    id<MTLCommandBuffer> cmd;      // retained for the frame
    id<MTLRenderCommandEncoder> enc; // retained for the frame
    id<CAMetalDrawable> drawable;  // retained for the frame (window path)
    id<MTLTexture> readback;       // retained for the frame (offscreen path)
    uint32_t w, h;
    // Redundant-state elision: a frame walks many paint-ordered draws that
    // mostly share pipeline/buffers/texture; skipping the repeat encoder
    // calls is a large CPU-side win at high range counts.
    int cur_pipe;                  // -1 = none bound yet
    ctm_buf *cur_vbuf;
    ctm_buf *cur_pbuf;
    ctm_tex *cur_tex;
};

struct ctm_buf {
    id<MTLBuffer> buf; // retained
};
struct ctm_tex {
    id<MTLTexture> tex; // retained
};

static void set_err(char err[CTM_ERR_LEN], NSString *msg) {
    if (err) strlcpy(err, msg.UTF8String ?: "unknown", CTM_ERR_LEN);
}

static id<MTLRenderPipelineState> make_pipe(id<MTLDevice> dev, id<MTLLibrary> lib,
                                            NSString *vfn, NSString *ffn,
                                            int samples, char err[CTM_ERR_LEN]) {
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    id<MTLFunction> vf = [lib newFunctionWithName:vfn];
    id<MTLFunction> ff = [lib newFunctionWithName:ffn];
    d.vertexFunction = vf;
    d.fragmentFunction = ff;
    id<MTLRenderPipelineState> p = nil;
    if (vf && ff) {
        d.rasterSampleCount = samples;
        d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[0];
        ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // Straight-alpha over, alpha accumulates.
        ca.blendingEnabled = YES;
        ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ca.rgbBlendOperation = MTLBlendOperationAdd;
        ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
        ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ca.alphaBlendOperation = MTLBlendOperationAdd;
        NSError *e = nil;
        p = [dev newRenderPipelineStateWithDescriptor:d error:&e]; // +1
        if (!p) set_err(err, e.localizedDescription);
    } else {
        set_err(err, [NSString stringWithFormat:@"missing shader %@/%@", vfn, ffn]);
    }
    [vf release];
    [ff release];
    [d release];
    return p;
}

ctm_ctx *ctm_create(void *metal_layer, const char *msl_source, int want_msaa,
                    int *msaa_out, char err[CTM_ERR_LEN]) {
    ctm_ctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    int ok = 0;
    @autoreleasepool {
        do {
            c->device = MTLCreateSystemDefaultDevice(); // +1 (Create rule)
            if (!c->device) {
                set_err(err, @"no Metal device");
                break;
            }
            c->queue = [c->device newCommandQueue]; // +1

            NSError *e = nil;
            id<MTLLibrary> lib = [c->device newLibraryWithSource:[NSString stringWithUTF8String:msl_source]
                                                         options:nil
                                                           error:&e]; // +1
            if (!lib) {
                set_err(err, e.localizedDescription);
                break;
            }

            c->msaa_on = want_msaa && [c->device supportsTextureSampleCount:4];
            atomic_store_explicit(&c->inflight_n, 0, memory_order_relaxed);
            atomic_store_explicit(&c->inflight_ret_ms, ctm_now_ms(), memory_order_relaxed);
            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionLess;
            dd.depthWriteEnabled = YES;
            c->ds_opaque = [c->device newDepthStencilStateWithDescriptor:dd]; // +1
            dd.depthWriteEnabled = NO;
            c->ds_blend = [c->device newDepthStencilStateWithDescriptor:dd]; // +1
            [dd release];
            int samples = c->msaa_on ? 4 : 1;
            if (msaa_out) *msaa_out = c->msaa_on;

            struct { NSString *v, *f; } fns[CTM_PIPE_COUNT] = {
                [CTM_PIPE_FILL] = { @"fill_vert", @"fill_frag" },
                [CTM_PIPE_SPRITE] = { @"sprite_vert", @"sprite_frag" },
                [CTM_PIPE_SDF] = { @"sprite_vert", @"sdf_frag" },
                [CTM_PIPE_PATTERN] = { @"pattern_vert", @"pattern_frag" },
            };
            int built = 1;
            for (int i = 0; i < CTM_PIPE_COUNT; i++) {
                c->pipes[i] = make_pipe(c->device, lib, fns[i].v, fns[i].f, samples, err); // +1
                if (!c->pipes[i]) {
                    built = 0;
                    break;
                }
            }
            [lib release];
            if (!built) break;

            MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
            sd.minFilter = MTLSamplerMinMagFilterLinear;
            sd.magFilter = MTLSamplerMinMagFilterLinear;
            sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
            sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
            c->sampler = [c->device newSamplerStateWithDescriptor:sd]; // +1
            [sd release];

            if (metal_layer) {
                c->layer = (CAMetalLayer *)metal_layer; // host-owned; not retained
                c->layer.device = c->device;
                c->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                c->layer.framebufferOnly = YES;
                c->layer.opaque = YES;
            }
            ok = 1;
        } while (0);
    }
    if (!ok) {
        ctm_destroy(c);
        return NULL;
    }
    return c;
}

void ctm_destroy(ctm_ctx *c) {
    if (!c) return;
    @autoreleasepool {
        if (c->layer && c->layer.device == c->device) c->layer.device = nil;
        [c->device release];
        [c->queue release];
        for (int i = 0; i < CTM_PIPE_COUNT; i++) [c->pipes[i] release];
        [c->sampler release];
        [c->msaa release];
        [c->depth release];
        [c->ds_opaque release];
        [c->ds_blend release];
    }
    free(c);
}

void ctm_layer_sync(ctm_ctx *c, uint32_t *w_px, uint32_t *h_px) {
    if (!c || !c->layer) {
        if (w_px) *w_px = 0;
        if (h_px) *h_px = 0;
        return;
    }
    @autoreleasepool {
        CGFloat scale = c->layer.contentsScale > 0 ? c->layer.contentsScale : 1.0;
        CGSize pt = c->layer.bounds.size;
        CGSize px = CGSizeMake(MAX(1.0, round(pt.width * scale)), MAX(1.0, round(pt.height * scale)));
        if (!CGSizeEqualToSize(c->layer.drawableSize, px)) c->layer.drawableSize = px;
        if (w_px) *w_px = (uint32_t)px.width;
        if (h_px) *h_px = (uint32_t)px.height;
    }
}

ctm_buf *ctm_new_buffer(ctm_ctx *c, const void *bytes, size_t len) {
    if (!c || !bytes || len == 0) return NULL;
    @autoreleasepool {
        id<MTLBuffer> b = [c->device newBufferWithBytes:bytes length:len options:MTLResourceStorageModeShared]; // +1
        if (!b) return NULL;
        ctm_buf *out = calloc(1, sizeof(*out));
        out->buf = b;
        return out;
    }
}

void ctm_free_buffer(ctm_buf *b) {
    if (!b) return;
    [b->buf release];
    free(b);
}

ctm_tex *ctm_new_texture_rgba(ctm_ctx *c, const void *rgba, uint32_t w, uint32_t h) {
    if (!c || !rgba || w == 0 || h == 0) return NULL;
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:w
                                                                                    height:h
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [c->device newTextureWithDescriptor:d]; // +1
        if (!t) return NULL;
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba bytesPerRow:(NSUInteger)w * 4];
        ctm_tex *out = calloc(1, sizeof(*out));
        out->tex = t;
        return out;
    }
}

void ctm_free_texture(ctm_tex *t) {
    if (!t) return;
    [t->tex release];
    free(t);
}

static void ensure_depth(ctm_ctx *c, uint32_t w, uint32_t h) {
    if (c->depth && c->depth_w == w && c->depth_h == h) return;
    [c->depth release];
    c->depth = nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    if (c->msaa_on) {
        d.textureType = MTLTextureType2DMultisample;
        d.sampleCount = 4;
    }
    d.usage = MTLTextureUsageRenderTarget;
    // Cleared on load, never stored — on TBDR GPUs the depth samples live only
    // in tile memory. Memoryless saves the full-frame allocation; Intel Macs
    // need Private.
    if ([c->device supportsFamily:MTLGPUFamilyApple2])
        d.storageMode = MTLStorageModeMemoryless;
    else
        d.storageMode = MTLStorageModePrivate;
    c->depth = [c->device newTextureWithDescriptor:d]; // +1
    c->depth_w = w;
    c->depth_h = h;
}

static void ensure_msaa(ctm_ctx *c, uint32_t w, uint32_t h) {
    if (!c->msaa_on) return;
    if (c->msaa && c->msaa_w == w && c->msaa_h == h) return;
    [c->msaa release];
    c->msaa = nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    d.textureType = MTLTextureType2DMultisample;
    d.sampleCount = 4;
    d.usage = MTLTextureUsageRenderTarget;
    // TBDR GPUs never need this texture backed: cleared on load, resolved on
    // store, so the samples live only in tile memory.
    if ([c->device supportsFamily:MTLGPUFamilyApple2])
        d.storageMode = MTLStorageModeMemoryless;
    else
        d.storageMode = MTLStorageModePrivate;
    c->msaa = [c->device newTextureWithDescriptor:d]; // +1
    c->msaa_w = w;
    c->msaa_h = h;
}

// Retains cmd/enc/drawable/readback into the frame (callers run no pool).
static ctm_frame *begin_pass(ctm_ctx *c, id<MTLTexture> target, id<CAMetalDrawable> drawable,
                             id<MTLTexture> readback, uint32_t w, uint32_t h, const float clear[4]) {
    ensure_msaa(c, w, h);
    ensure_depth(c, w, h);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = c->depth;
    rp.depthAttachment.clearDepth = 1.0; // farthest; paint-order depths are < 1
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    MTLRenderPassColorAttachmentDescriptor *ca = rp.colorAttachments[0];
    ca.clearColor = MTLClearColorMake(clear[0], clear[1], clear[2], clear[3]);
    ca.loadAction = MTLLoadActionClear;
    if (c->msaa_on) {
        ca.texture = c->msaa;
        ca.resolveTexture = target;
        ca.storeAction = MTLStoreActionMultisampleResolve;
    } else {
        ca.texture = target;
        ca.storeAction = MTLStoreActionStore;
    }
    id<MTLCommandBuffer> cmd = [c->queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) return NULL;
    [enc setFragmentSamplerState:c->sampler atIndex:0];
    [enc setDepthStencilState:c->ds_blend]; // default: test only — a host that
                                            // never draws an opaque pass gets
                                            // exactly painter's order
    ctm_frame *f = calloc(1, sizeof(*f));
    f->ctx = c;
    f->cur_pipe = -1;
    f->cmd = [cmd retain];
    f->enc = [enc retain];
    f->drawable = [drawable retain];
    f->readback = [readback retain];
    f->w = w;
    f->h = h;
    return f;
}

ctm_frame *ctm_begin_frame(ctm_ctx *c, const float clear[4]) {
    if (!c || !c->layer) return NULL;
    @autoreleasepool {
        uint32_t w = 0, h = 0;
        ctm_layer_sync(c, &w, &h);
        if (w == 0 || h == 0) return NULL;
        int n = atomic_load_explicit(&c->inflight_n, memory_order_relaxed);
        if (n < 0) { // late returns after a self-heal reset: clamp
            atomic_store_explicit(&c->inflight_n, 0, memory_order_relaxed);
            n = 0;
        }
        // Cap at 2, one BELOW the drawable pool of 3: a drawable whose
        // presented-handler has fired is still on glass until the next frame
        // supersedes it, so at 3-in-flight the gate opens while the pool is
        // still empty and nextDrawable blocks ~a full vsync anyway. At
        // 2-in-flight there is always a free drawable and acquire is ~0.
        if (n >= 2) {
            long since = ctm_now_ms() - atomic_load_explicit(&c->inflight_ret_ms, memory_order_relaxed);
            if (since < 500) return NULL; // healthy backpressure: skip, don't stall
            // No permit back in 500ms: those presents are lost (resize,
            // occlusion), not queued. Reset rather than freeze forever.
            atomic_store_explicit(&c->inflight_n, 0, memory_order_relaxed);
        }
        atomic_fetch_add_explicit(&c->inflight_n, 1, memory_order_relaxed);
        id<CAMetalDrawable> drawable = [c->layer nextDrawable];
        if (!drawable) {
            ctm_inflight_return(c);
            return NULL;
        }
        ctm_frame *f = begin_pass(c, drawable.texture, drawable, nil, w, h, clear);
        if (!f) ctm_inflight_return(c);
        return f;
    }
}

ctm_frame *ctm_begin_offscreen(ctm_ctx *c, uint32_t w, uint32_t h, const float clear[4]) {
    if (!c || w == 0 || h == 0) return NULL;
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w
                                                                                    height:h
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModeShared; // Apple Silicon: CPU-readable render target
        id<MTLTexture> t = [c->device newTextureWithDescriptor:d]; // +1
        if (!t) return NULL;
        ctm_frame *f = begin_pass(c, t, nil, t, w, h, clear);
        [t release]; // begin_pass retained it as f->readback
        return f;
    }
}

void ctm_set_depth_mode(ctm_frame *f, int opaque) {
    if (!f) return;
    [f->enc setDepthStencilState:opaque ? f->ctx->ds_opaque : f->ctx->ds_blend];
}

void ctm_set_pipeline(ctm_frame *f, int which) {
    if (!f || which < 0 || which >= CTM_PIPE_COUNT || f->cur_pipe == which) return;
    f->cur_pipe = which;
    [f->enc setRenderPipelineState:f->ctx->pipes[which]];
}

void ctm_bind_vbuf(ctm_frame *f, ctm_buf *b) {
    if (!f || !b || f->cur_vbuf == b) return;
    f->cur_vbuf = b;
    [f->enc setVertexBuffer:b->buf offset:0 atIndex:0];
}

void ctm_bind_paint(ctm_frame *f, ctm_buf *b) {
    if (!f || !b || f->cur_pbuf == b) return;
    f->cur_pbuf = b;
    [f->enc setVertexBuffer:b->buf offset:0 atIndex:1];
}

void ctm_bind_texture(ctm_frame *f, ctm_tex *t) {
    if (!f || !t || f->cur_tex == t) return;
    f->cur_tex = t;
    [f->enc setFragmentTexture:t->tex atIndex:0];
}

void ctm_set_uniforms(ctm_frame *f, const void *bytes, size_t len) {
    if (!f) return;
    [f->enc setVertexBytes:bytes length:len atIndex:2];
    // The SDF text fragment stage reads the uniform too (halo colour).
    [f->enc setFragmentBytes:bytes length:len atIndex:1];
}

void ctm_draw(ctm_frame *f, uint32_t first, uint32_t count) {
    if (!f) return;
    [f->enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:first vertexCount:count];
}

// Indexed draw against the bound vertex buffer. `first` is in INDEX units
// (u32). The shaders fetch via [[vertex_id]], which for an indexed draw is the
// fetched index value — so the same shaders serve both draw paths, and the
// paint stream stays parallel to the VERTEX buffer, not the index buffer.
void ctm_draw_indexed(ctm_frame *f, ctm_buf *ib, uint32_t first, uint32_t count) {
    if (!f || !ib) return;
    [f->enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                       indexCount:count
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:ib->buf
                indexBufferOffset:(NSUInteger)first * 4];
}

void ctm_end_frame(ctm_frame *f) {
    if (!f) return;
    @autoreleasepool {
        [f->enc endEncoding];
        ctm_ctx *c = f->ctx;
        // The inflight permit returns when the drawable is ON GLASS — not at
        // GPU completion, which lands tens of ms earlier when the compositor is
        // the bottleneck. Handlers must be registered BEFORE the present is
        // scheduled.
        int presented_gate = 0;
        if (f->drawable) {
            // The SIMULATOR's CAMetalDrawable does not implement
            // addPresentedHandler: (unrecognized selector) — probe first. On
            // hardware the permit returns when the frame is ON GLASS; in the
            // sim it falls back to GPU completion below.
            if ([(id)f->drawable respondsToSelector:@selector(addPresentedHandler:)]) {
                presented_gate = 1;
                [f->drawable addPresentedHandler:^(id<MTLDrawable> d) {
                    ctm_inflight_return(c);
                }];
            }
            [f->cmd presentDrawable:f->drawable];
        }
        int gated_on_complete = (f->drawable != nil) && !presented_gate;
        [f->cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            // Diagnostics only (racy read is fine): how long the GPU actually
            // spent on the frame — the CPU-vs-GPU-bound discriminator.
            c->last_gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
            if (gated_on_complete) ctm_inflight_return(c);
        }];
        [f->cmd commit];
        [f->enc release];
        [f->cmd release];
        [f->drawable release];
        [f->readback release];
    }
    free(f);
}

double ctm_last_gpu_ms(ctm_ctx *c) {
    return c ? c->last_gpu_ms : 0;
}

int ctm_end_offscreen_read(ctm_frame *f, void *out_bgra) {
    if (!f) return 0;
    int ok = 0;
    @autoreleasepool {
        [f->enc endEncoding];
        [f->cmd commit];
        [f->cmd waitUntilCompleted];
        if (f->readback && out_bgra) {
            [f->readback getBytes:out_bgra
                      bytesPerRow:(NSUInteger)f->w * 4
                       fromRegion:MTLRegionMake2D(0, 0, f->w, f->h)
                      mipmapLevel:0];
            ok = 1;
        }
        [f->enc release];
        [f->cmd release];
        [f->drawable release];
        [f->readback release];
    }
    free(f);
    return ok;
}

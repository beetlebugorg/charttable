//! Metal transport: device, the pipelines, persistent buffers, and a per-frame
//! render (present into the host's CAMetalLayer OR headless offscreen
//! readback). All vector work happened upstream (layout + batch) — the frame
//! phase here only updates a uniform and issues draws.
//!
//! Ported from lookout-marine src/gpu_metal.zig and adapted to charttable's
//! scene contract (src/scene/types.zig):
//!   * TWO vertex streams: geometry (scene.Vertex / scene.Quad) at buffer 0,
//!     evaluated paint (scene.PaintVertex) at buffer 1. A paint-only restyle
//!     re-uploads stream B and never touches geometry.
//!   * The per-vertex zoom window [zmin, zmax] replaces lookout's
//!     cat_mask/scamin gates; the shader compares against Uniforms.zoom.
//!   * Triangles stay INDEXED (ranges' first/count are u32-index units).
//!   * The two-phase opaque-first depth pass, per-draw uniform delta with
//!     byte-compare suppression, staging on the caller thread with
//!     pointer-swap adoption, and the offscreen RGBA readback all carry over.
//!
//! Apple-only by design: the ObjC lives in metal_shim.m, the shaders in
//! shaders/metal.metal (embedded here, compiled by the shim at runtime).
const std = @import("std");
const builtin = @import("builtin");
const mc = @import("c_metal.zig").c;
const scene = @import("../scene/types.zig");
const batch = @import("../scene/batch.zig");
const png = @import("../util/png.zig");
const msl_source = @embedFile("metal_msl");

/// The per-draw uniform block (128 bytes). THE SCENE CONTRACT OWNS THIS
/// LAYOUT (scene/types.zig Uniforms, offsets asserted there); the shader's
/// `struct U` static_asserts the same size at pipeline build.
pub const Uniforms = scene.Uniforms;

/// RGBA colour 0..1.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// Monotonic milliseconds from an arbitrary epoch.
pub fn ticksMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// How to interpret Options.native_handle. Apple-only: the host hands us its
/// CAMetalLayer (an NSView's backing layer on macOS, a UIView's layerClass on
/// iOS) and keeps its own toolkit and event loop.
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1, // CAMetalLayer* (macOS & iOS)
};

pub const Options = struct {
    width: u32,
    height: u32,
    want_msaa: bool = false,
    /// Without a layer, rendering is offscreen (snapshot) only.
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Gpu = struct {
    ctx: *mc.ctm_ctx,
    has_layer: bool,
    msaa_used: bool,
    width: u32,
    height: u32,
    /// Host view's LOGICAL size from its latest resize() call — the pixel
    /// density denominator.
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    /// ticksMs() when the drawable last changed size — scenes built mid-resize
    /// are rebuilt by the host while this is recent.
    size_changed_ms: i64 = -100000,
    /// pixels per logical point (Retina/HiDPI = 2.0/3.0).
    pixel_density: f32 = 1.0,
    /// Non-zero once the host DECLARED its scale factor (setPixelDensity); it
    /// then wins over the drawable/point ratio derived per frame.
    host_density: f32 = 0,

    /// Frame clear = the style's effective background (host sets it). Also
    /// the SDF halo colour the batcher stamps on text draws.
    clear: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },

    /// The opaque front-to-back depth pre-pass (phase A). A pure optimization
    /// that must never change the image; turn it off to diff against plain
    /// painter's order when a depth-pass artifact is suspected.
    opaque_pass: bool = true,

    /// The current draw-ready scene. Uploaded per rebuild (makeScene on a
    /// worker + adoptScene on the render thread); a frame only pushes
    /// uniforms + draws.
    scene: ?Scene = null,

    sprite_tex: ?*mc.ctm_tex = null,
    glyph_tex: ?*mc.ctm_tex = null,
    glyph_bold_tex: ?*mc.ctm_tex = null,
    glyph_italic_tex: ?*mc.ctm_tex = null,

    // One pattern cell as its own sampler texture, plus its device-px size
    // (the on-screen tiling period — scene.PatternCell.w/h ARE that period).
    const PatternTex = struct { tex: ?*mc.ctm_tex = null, w: f32 = 1, h: f32 = 1 };

    /// Everything one scene rebuild hands the backend. All slices are
    /// borrowed — copied into GPU buffers (or duped) before makeScene
    /// returns, so the caller may free them immediately after.
    pub const SceneData = struct {
        vertices: []const scene.Vertex = &.{},
        /// Stream B for `vertices`: one entry per vertex.
        paint: []const scene.PaintVertex = &.{},
        /// u32 triangle indices; triangle ranges' first/count index HERE.
        indices: []const u32 = &.{},
        /// Quad vertices (6 per quad); quad ranges' first/count index HERE.
        quads: []const scene.Quad = &.{},
        /// Stream B for `quads`: one entry per quad vertex.
        quad_paint: []const scene.PaintVertex = &.{},
        ranges: []const scene.Range = &.{},
        patterns: []const scene.PatternCell = &.{},
    };

    /// GPU-resident scene: the two triangle streams + index buffer, the two
    /// quad streams, the paint-ordered ranges (host-owned copy), and one
    /// texture per pattern cell.
    pub const Scene = struct {
        vbuf: ?*mc.ctm_buf = null, // scene.Vertex stream, indexed by ibuf
        pbuf: ?*mc.ctm_buf = null, // scene.PaintVertex stream, parallel to vbuf
        ibuf: ?*mc.ctm_buf = null, // u32 indices; triangle ranges index HERE
        qbuf: ?*mc.ctm_buf = null, // scene.Quad stream (6 verts per quad)
        qpbuf: ?*mc.ctm_buf = null, // scene.PaintVertex stream, parallel to qbuf
        index_count: u32 = 0,
        quad_vert_count: u32 = 0,
        ranges: []scene.Range = &.{},
        patterns: []PatternTex = &.{},
        /// Scratch for scene/batch.zig. Sized to the range count, which is
        /// the ceiling — draws only ever merge, never split — so a frame
        /// never allocates and a batch never truncates.
        draws: []scene.Draw = &.{},
        alloc: std.mem.Allocator,
    };

    pub fn init(opts: Options) !Gpu {
        const layer: ?*anyopaque = if (opts.native_kind == .metal_layer) opts.native_handle else null;
        var err: [mc.CTM_ERR_LEN]u8 = undefined;
        err[0] = 0;
        var msaa_out: c_int = 0;
        const ctx = mc.ctm_create(layer, msl_source, @intFromBool(opts.want_msaa), &msaa_out, &err) orelse {
            std.log.err("Metal init failed: {s}", .{std.mem.sliceTo(&err, 0)});
            return error.MetalFailure;
        };

        var g = Gpu{
            .ctx = ctx,
            .has_layer = layer != null,
            .msaa_used = msaa_out != 0,
            .width = opts.width,
            .height = opts.height,
        };
        if (layer != null) {
            var pw: u32 = 0;
            var ph: u32 = 0;
            mc.ctm_layer_sync(ctx, &pw, &ph);
            if (pw > 0 and ph > 0) {
                g.width = pw;
                g.height = ph;
                g.host_pt_w = @floatFromInt(opts.width);
                g.host_pt_h = @floatFromInt(opts.height);
                if (opts.width > 0) {
                    const d = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(opts.width));
                    if (d > 0.25 and d < 8) g.pixel_density = d;
                }
            }
        }
        return g;
    }

    pub fn deinit(self: *Gpu) void {
        self.freeScene();
        if (self.sprite_tex) |t| mc.ctm_free_texture(t);
        if (self.glyph_tex) |t| mc.ctm_free_texture(t);
        if (self.glyph_bold_tex) |t| mc.ctm_free_texture(t);
        if (self.glyph_italic_tex) |t| mc.ctm_free_texture(t);
        mc.ctm_destroy(self.ctx);
    }

    /// The host's own scale factor, declared rather than derived. A declared
    /// value wins over the per-frame drawable/point ratio.
    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        if (d > 0.2 and d < 8.0) {
            self.host_density = d;
            self.pixel_density = d;
        }
    }

    /// Resize the render surface. width/height are in logical points. With a
    /// layer, only the logical size is recorded — pixels follow the layer's
    /// bounds x contentsScale each frame (renderWindow adopts them).
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) void {
        if (self.has_layer) {
            self.host_pt_w = @floatFromInt(width_pts);
            self.host_pt_h = @floatFromInt(height_pts);
            return;
        }
        self.width = width_pts;
        self.height = height_pts;
    }

    // ---- atlas textures ------------------------------------------------------
    // All RGBA8, matching lookout's atlas upload — the SDF glyph atlas too
    // (the shader samples .r of it). Replacing one frees the old texture; an
    // in-flight frame is safe because the encoder retains what it bound.

    pub fn uploadSpriteAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        if (self.sprite_tex) |t| mc.ctm_free_texture(t);
        self.sprite_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        if (self.glyph_tex) |t| mc.ctm_free_texture(t);
        self.glyph_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasBold(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        if (self.glyph_bold_tex) |t| mc.ctm_free_texture(t);
        self.glyph_bold_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasItalic(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        if (self.glyph_italic_tex) |t| mc.ctm_free_texture(t);
        self.glyph_italic_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    fn makeAtlasTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !*mc.ctm_tex {
        if (rgba.len < @as(usize, w) * h * 4) return error.MetalFailure;
        return mc.ctm_new_texture_rgba(self.ctx, rgba.ptr, w, h) orelse error.MetalFailure;
    }

    /// Which atlases we actually uploaded, as the bitmask the batcher wants.
    /// The bold/italic -> glyph fallback happens there.
    fn atlasHave(self: *const Gpu) u8 {
        var m: u8 = 0;
        if (self.sprite_tex != null) m |= scene.AtlasBit.bit(.sprite);
        if (self.glyph_tex != null) m |= scene.AtlasBit.bit(.glyph);
        if (self.glyph_bold_tex != null) m |= scene.AtlasBit.bit(.glyph_bold);
        if (self.glyph_italic_tex != null) m |= scene.AtlasBit.bit(.glyph_italic);
        return m;
    }

    /// `atlas` arrives AFTER the batcher's fallback. Untextured quads (.none)
    /// ride the sprite pipeline and sample the sprite atlas.
    fn atlasTexture(self: *const Gpu, atlas: scene.Atlas) ?*mc.ctm_tex {
        return switch (atlas) {
            .glyph => self.glyph_tex,
            .glyph_bold => self.glyph_bold_tex,
            .glyph_italic => self.glyph_italic_tex,
            .sprite, .none => self.sprite_tex,
        };
    }

    // ---- the draw-ready scene ------------------------------------------------

    /// Upload `data` into GPU buffers + pattern textures and adopt it as the
    /// current scene (freeing any previous one).
    pub fn uploadScene(self: *Gpu, alloc: std.mem.Allocator, data: SceneData) !void {
        self.adoptScene(try self.makeScene(alloc, data));
    }

    /// Swap the staged scene in as current (frees the previous one). This is
    /// the ONLY mutation a concurrent frame can race with, so it must run on
    /// the render thread; everything expensive lives in makeScene.
    pub fn adoptScene(self: *Gpu, sc: Scene) void {
        self.freeScene();
        self.scene = sc;
    }

    /// Free a staged Scene that was never adopted (e.g. superseded build).
    pub fn freeStagedScene(self: *Gpu, sc: *Scene) void {
        self.freeSceneValue(sc);
    }

    /// Build a GPU-resident Scene from `data` WITHOUT installing it.
    /// Thread-safe: Metal resource creation may run on ANY thread, and this
    /// is where the whole scene's bytes get copied into MTLBuffers — the
    /// build worker stages here; the render thread adopts.
    pub fn makeScene(self: *Gpu, alloc: std.mem.Allocator, data: SceneData) !Scene {
        // The two streams are parallel by contract: one paint entry per
        // stream-A vertex. A skew here would shade every vertex after the
        // mismatch with someone else's paint.
        if (data.paint.len != data.vertices.len) return error.PaintStreamMismatch;
        if (data.quad_paint.len != data.quads.len) return error.PaintStreamMismatch;
        // BOUNDS AUDIT (from lookout, promoted to a hard error): a range
        // pointing past its buffer draws undefined memory — recycled heap on
        // one platform (often coincidentally correct), fresh zero pages on
        // another (tile-shaped nothing).
        for (data.ranges) |r| {
            const first: u64 = r.first;
            const count: u64 = r.count;
            const limit: u64 = switch (r.prim) {
                .triangles => data.indices.len,
                .quads => data.quads.len,
            };
            if (first + count > limit) return error.SceneBounds;
        }
        for (data.indices) |ix| {
            if (ix >= data.vertices.len) return error.SceneBounds;
        }

        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);

        if (data.vertices.len > 0 and data.indices.len > 0) {
            out.vbuf = try self.newBuffer(std.mem.sliceAsBytes(data.vertices));
            out.pbuf = try self.newBuffer(std.mem.sliceAsBytes(data.paint));
            out.ibuf = try self.newBuffer(std.mem.sliceAsBytes(data.indices));
            out.index_count = @intCast(data.indices.len);
        }
        if (data.quads.len > 0) {
            out.qbuf = try self.newBuffer(std.mem.sliceAsBytes(data.quads));
            out.qpbuf = try self.newBuffer(std.mem.sliceAsBytes(data.quad_paint));
            out.quad_vert_count = @intCast(data.quads.len);
        }
        if (data.ranges.len > 0) {
            out.ranges = try alloc.dupe(scene.Range, data.ranges);
            out.draws = try alloc.alloc(scene.Draw, data.ranges.len);
        }
        if (data.patterns.len > 0) {
            out.patterns = try alloc.alloc(PatternTex, data.patterns.len);
            for (out.patterns) |*p| p.* = .{};
            for (data.patterns, out.patterns) |cell, *p| {
                p.w = @floatFromInt(cell.w);
                p.h = @floatFromInt(cell.h);
                const need = @as(usize, cell.w) * cell.h * 4;
                if (cell.w > 0 and cell.h > 0 and cell.w <= 4096 and cell.h <= 4096 and cell.rgba.len >= need)
                    p.tex = mc.ctm_new_texture_rgba(self.ctx, cell.rgba.ptr, cell.w, cell.h);
            }
        }
        return out;
    }

    fn newBuffer(self: *Gpu, bytes: []const u8) !*mc.ctm_buf {
        return mc.ctm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse error.MetalFailure;
    }

    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        _ = self;
        if (s.vbuf) |b| mc.ctm_free_buffer(b);
        if (s.pbuf) |b| mc.ctm_free_buffer(b);
        if (s.ibuf) |b| mc.ctm_free_buffer(b);
        if (s.qbuf) |b| mc.ctm_free_buffer(b);
        if (s.qpbuf) |b| mc.ctm_free_buffer(b);
        for (s.patterns) |p| if (p.tex) |t| mc.ctm_free_texture(t);
        if (s.ranges.len > 0) s.alloc.free(s.ranges);
        if (s.draws.len > 0) s.alloc.free(s.draws);
        if (s.patterns.len > 0) s.alloc.free(s.patterns);
        s.* = .{ .alloc = s.alloc };
    }

    pub fn freeScene(self: *Gpu) void {
        if (self.scene) |*s| {
            self.freeSceneValue(s);
            self.scene = null;
        }
    }

    // ---- record one frame's draws into an open frame ---------------------------

    /// Send the uniform block only when its bytes changed since the last send
    /// this frame — a chart frame's draws overwhelmingly share one block.
    fn sendUniforms(f: *mc.ctm_frame, last: *?Uniforms, u: *const Uniforms) void {
        if (last.*) |*prev| {
            if (std.mem.eql(u8, std.mem.asBytes(prev), std.mem.asBytes(u))) return;
        }
        mc.ctm_set_uniforms(f, u, @sizeOf(Uniforms));
        last.* = u.*;
    }

    // One merged front-to-back run of the opaque pre-pass.
    const OpaqueRun = struct { first: u32, count: u32, pattern: u32 };

    fn flushOpaque(f: *mc.ctm_frame, s: *const Scene, run: OpaqueRun, last_u: *?Uniforms, u: *const Uniforms) void {
        if (run.pattern == scene.NO_PATTERN) {
            mc.ctm_set_pipeline(f, mc.CTM_PIPE_FILL);
            mc.ctm_bind_vbuf(f, s.vbuf.?);
            mc.ctm_bind_paint(f, s.pbuf.?);
            sendUniforms(f, last_u, u);
        } else {
            // The batcher excludes ALL opaque triangle ranges from phase B,
            // pattern ones included, so phase A must draw them or they vanish.
            // Whether a cell rasterized is ours to know; without one the fill
            // under it already drew, so this draws nothing.
            if (run.pattern >= s.patterns.len) return;
            const pt = s.patterns[run.pattern];
            const tex = pt.tex orelse return;
            mc.ctm_set_pipeline(f, mc.CTM_PIPE_PATTERN);
            mc.ctm_bind_vbuf(f, s.vbuf.?);
            mc.ctm_bind_texture(f, tex);
            var uu = u.*;
            uu.cell_px = .{ pt.w, pt.h };
            sendUniforms(f, last_u, &uu);
        }
        mc.ctm_draw_indexed(f, s.ibuf.?, run.first, run.count);
    }

    /// Walk the scene in paint order, switching pipeline per draw.
    ///
    /// PHASE A — OPAQUE triangles, front-to-back, depth write ON: every
    /// fragment that loses the depth test never shades, so stacked fills cost
    /// ~one shade per pixel instead of one per layer. Walked in REVERSE paint
    /// order (front first); contiguous ranges merge. Correctness leans on
    /// per-range depth, not draw order — order here is purely early-z.
    ///
    /// PHASE B — everything else in paint order, depth test only: content
    /// UNDER an opaque surface is culled by the phase-A depth, everything
    /// else blends exactly as painter's order always did. scene/batch.zig
    /// decides what each range draws and merges contiguous ranges sharing a
    /// spec; phase A's ranges are excluded there rather than re-skipped here.
    fn recordScene(self: *Gpu, f: *mc.ctm_frame, u: Uniforms) void {
        const s = if (self.scene) |*sc| sc else return;
        var last_u: ?Uniforms = null;

        const tris_ready = s.vbuf != null and s.ibuf != null and s.pbuf != null;

        if (self.opaque_pass and tris_ready) {
            mc.ctm_set_depth_mode(f, 1);
            var run: ?OpaqueRun = null;
            var i: usize = s.ranges.len;
            while (i > 0) {
                i -= 1;
                const r = s.ranges[i];
                if (r.count == 0 or r.prim != .triangles or (r.flags & scene.Range.FLAG_OPAQUE) == 0) continue;
                if (run) |*a| {
                    if (a.pattern == r.pattern and r.first + r.count == a.first) {
                        a.first = r.first;
                        a.count += r.count;
                        continue;
                    }
                    flushOpaque(f, s, a.*, &last_u, &u);
                }
                run = .{ .first = r.first, .count = r.count, .pattern = r.pattern };
            }
            if (run) |a| flushOpaque(f, s, a, &last_u, &u);
        }

        mc.ctm_set_depth_mode(f, 0);
        const opts = scene.BatchOpts{
            .exclude_opaque_tris = self.opaque_pass and tris_ready,
            .atlas_have = self.atlasHave(),
            .halo = .{ self.clear.r, self.clear.g, self.clear.b, 1 },
        };
        const n = batch.batch(s.ranges, opts, s.draws);
        // A batch past capacity is missing content, not merely slow — draw
        // nothing from it (cannot happen while draws.len == ranges.len).
        const draws: []const scene.Draw = if (n > s.draws.len) &.{} else s.draws[0..n];
        for (draws) |d| {
            var uu = u;
            switch (d.prim) {
                .triangles => {
                    if (!tris_ready) continue;
                    if (d.pipeline == .pattern) {
                        if (d.pattern >= s.patterns.len) continue;
                        const pt = s.patterns[d.pattern];
                        const tex = pt.tex orelse continue;
                        uu.cell_px = .{ pt.w, pt.h };
                        mc.ctm_set_pipeline(f, mc.CTM_PIPE_PATTERN);
                        mc.ctm_bind_vbuf(f, s.vbuf.?);
                        mc.ctm_bind_texture(f, tex);
                    } else {
                        mc.ctm_set_pipeline(f, mc.CTM_PIPE_FILL);
                        mc.ctm_bind_vbuf(f, s.vbuf.?);
                        mc.ctm_bind_paint(f, s.pbuf.?);
                    }
                    sendUniforms(f, &last_u, &uu);
                    mc.ctm_draw_indexed(f, s.ibuf.?, d.first, d.count);
                },
                .quads => {
                    if (s.qbuf == null or s.qpbuf == null) continue;
                    // A raster range samples the image the scene carries for
                    // it, not an atlas — but it still rides the sprite
                    // pipeline: a raster tile IS a textured world-space quad
                    // with the antimeridian wrap and paint-order depth the
                    // sprite shader already does (lookout raster.zig).
                    const tex = if (d.pipeline == .raster) blk: {
                        if (d.pattern >= s.patterns.len) continue;
                        break :blk s.patterns[d.pattern].tex orelse continue;
                    } else self.atlasTexture(d.atlas) orelse continue;
                    const is_sdf = d.pipeline == .sdf;
                    // Text halos render in the effective background colour
                    // (batch stamps it on the draw): night text must not glare
                    // inside a hardcoded light halo.
                    if (is_sdf) uu.color = d.color;
                    mc.ctm_set_pipeline(f, if (is_sdf) mc.CTM_PIPE_SDF else mc.CTM_PIPE_SPRITE);
                    mc.ctm_bind_vbuf(f, s.qbuf.?);
                    mc.ctm_bind_paint(f, s.qpbuf.?);
                    mc.ctm_bind_texture(f, tex);
                    sendUniforms(f, &last_u, &uu);
                    mc.ctm_draw(f, d.first, d.count);
                },
            }
        }
    }

    // ---- frames ---------------------------------------------------------------

    /// Render one frame into the host's layer and present. Returns false when
    /// there is no layer to present into or the swapchain is saturated (skip
    /// the frame and retry next tick — the skipped content still lands).
    pub fn renderWindow(self: *Gpu, u: Uniforms) bool {
        if (!self.has_layer) return false;
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const f = mc.ctm_begin_frame(self.ctx, &clear) orelse return false;
        // The drawable is the ground truth for the frame's size: viewport and
        // camera follow it, so the picture and the cursor math stay
        // consistent across host transitions.
        var w: u32 = 0;
        var h: u32 = 0;
        mc.ctm_layer_sync(self.ctx, &w, &h);
        if (w != self.width or h != self.height) {
            self.size_changed_ms = ticksMs();
            self.width = w;
            self.height = h;
        }
        // Density is recomputed every frame: during an animated transition the
        // point size briefly lags the drawable, and a ratio captured at that
        // moment would otherwise stick forever.
        if (self.host_density == 0 and self.host_pt_w > 0) {
            const d = @as(f32, @floatFromInt(w)) / self.host_pt_w;
            if (d > 0.25 and d < 8) self.pixel_density = d;
        }
        self.recordScene(f, u);
        mc.ctm_end_frame(f);
        return true;
    }

    /// GPU time (ms) of the most recently completed window frame.
    pub fn lastGpuMs(self: *const Gpu) f64 {
        return mc.ctm_last_gpu_ms(self.ctx);
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms) ![]u8 {
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const f = mc.ctm_begin_offscreen(self.ctx, self.width, self.height, &clear) orelse return error.MetalFailure;
        self.recordScene(f, u);
        const n = @as(usize, self.width) * self.height * 4;
        const pixels = try alloc.alloc(u8, n);
        errdefer alloc.free(pixels);
        if (mc.ctm_end_offscreen_read(f, pixels.ptr) == 0) return error.MetalFailure;
        // The render target is the layer-native BGRA8 — swizzle to the RGBA
        // the snapshot API promises.
        var i: usize = 0;
        while (i < n) : (i += 4) {
            const b = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = b;
        }
        return pixels;
    }

    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms) !void {
        const pixels = try self.renderOffscreen(alloc, u);
        defer alloc.free(pixels);
        try png.write(alloc, path, pixels, self.width, self.height);
    }
};

// ---- headless smoke test -----------------------------------------------------
// The whole contract end to end: two vertex streams uploaded, an opaque
// triangle drawn through the phase-A depth pre-pass in its PAINT colour, a
// blended triangle through phase B, and a range whose zmax sits below the
// frame's zoom culled by the shader gate. macOS-only (needs a Metal device).

test "metal offscreen smoke: paint stream draws, zoom gate culls" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var g = try Gpu.init(.{ .width = 256, .height = 256 });
    defer g.deinit();
    g.clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 };

    // Staging validation: skewed paint streams and out-of-range ranges are
    // refused before anything reaches the GPU.
    try std.testing.expectError(error.PaintStreamMismatch, g.makeScene(alloc, .{
        .vertices = &.{std.mem.zeroes(scene.Vertex)},
        .paint = &.{},
    }));
    try std.testing.expectError(error.SceneBounds, g.makeScene(alloc, .{
        .ranges = &.{.{ .first = 0, .count = 3, .paint_key = 0, .kind = .area, .prim = .triangles }},
    }));

    const Z: u16 = scene.zq(10.0); // 2560: the frame's quantized zoom
    const V = struct {
        fn at(x: f32, y: f32, zmin: u16, zmax: u16, depth: f32) scene.Vertex {
            return .{ .x = x, .y = y, .ox = 0, .oy = 0, .zmin = zmin, .zmax = zmax, .flags = 0, .depth = depth };
        }
    };
    // A: opaque red, visible (zmin == u.zoom proves the gate is inclusive).
    // B: green, gate-culled (zmax 1000 < u.zoom 2560); same triangle as A and
    //    nearer in depth, so if the gate broke it WOULD win the centre pixel.
    // C: blue, blended phase-B triangle to A's right, over bare background.
    const verts = [_]scene.Vertex{
        V.at(-0.4, -0.4, Z, scene.ZMAX_ALL, 0.75), V.at(0.4, -0.4, Z, scene.ZMAX_ALL, 0.75),  V.at(0.0, 0.4, Z, scene.ZMAX_ALL, 0.75),
        V.at(-0.4, -0.4, 0, 1000, 0.5),            V.at(0.4, -0.4, 0, 1000, 0.5),             V.at(0.0, 0.4, 0, 1000, 0.5),
        V.at(0.1, -0.4, 0, scene.ZMAX_ALL, 0.25),  V.at(0.45, -0.4, 0, scene.ZMAX_ALL, 0.25), V.at(0.45, 0.4, 0, scene.ZMAX_ALL, 0.25),
    };
    const red = scene.PaintVertex{ .color = .{ 255, 0, 0, 255 } };
    const green = scene.PaintVertex{ .color = .{ 0, 255, 0, 255 } };
    const blue = scene.PaintVertex{ .color = .{ 0, 0, 255, 255 } };
    const paint = [_]scene.PaintVertex{ red, red, red, green, green, green, blue, blue, blue };
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const ranges = [_]scene.Range{
        .{ .first = 0, .count = 3, .paint_key = 0, .kind = .area, .prim = .triangles, .flags = scene.Range.FLAG_OPAQUE },
        .{ .first = 3, .count = 3, .paint_key = 1, .kind = .area, .prim = .triangles },
        .{ .first = 6, .count = 3, .paint_key = 2, .kind = .area, .prim = .triangles },
    };
    try g.uploadScene(alloc, .{
        .vertices = &verts,
        .paint = &paint,
        .indices = &indices,
        .ranges = &ranges,
    });

    var u = std.mem.zeroes(Uniforms);
    u.mvp[0] = 2; // scale x2 into clip; verts stay within the wrap-stable half-world
    u.mvp[5] = 2;
    u.mvp[15] = 1;
    u.px_to_clip = .{ 2.0 / 256.0, -2.0 / 256.0 };
    u.size_scale = 1;
    u.zoom = @floatFromInt(Z);
    u.rot_cos = 1;

    const px = try g.renderOffscreen(alloc, u);
    defer alloc.free(px);
    try std.testing.expectEqual(@as(usize, 256 * 256 * 4), px.len);

    const P = struct {
        fn at(buf: []const u8, x: usize, y: usize) [4]u8 {
            const i = (y * 256 + x) * 4;
            return .{ buf[i], buf[i + 1], buf[i + 2], buf[i + 3] };
        }
    };
    // Centre: the opaque triangle's PAINT colour — and NOT green, which is
    // the zoom gate holding (B passes the depth test if it draws at all).
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, P.at(px, 128, 128));
    // Inside C only: the blended phase-B triangle over the clear colour.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, P.at(px, 230, 128));
    // Outside everything: the clear colour.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, P.at(px, 5, 5));
}

// The other half of the offset contract: map_align. A rotated view turns a
// map-aligned symbol's offsets by (rot_sin, rot_cos) and leaves a
// viewport-aligned one alone — the paired layers tile57 emits (point_symbols
// viewport-aligned, point_symbols-north map-aligned) rely on exactly this.
test "metal offscreen: a rotated view turns map-aligned offsets only" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var g = try Gpu.init(.{ .width = 256, .height = 256 });
    defer g.deinit();
    g.clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    // A 1x1 opaque atlas: the sprite pipeline paints whatever it samples, so
    // every mark is white and only its POSITION carries the answer.
    try g.uploadSpriteAtlas(&.{ 255, 255, 255, 255 }, 1, 1);

    // Two marks, each 12 px square sitting 40 px to the right of its anchor:
    // A anchored at clip x -0.5 and map-aligned, B at the origin and not.
    const Q = struct {
        fn mark(anchor_x: f32, map_align: bool, out: *[6]scene.Quad) void {
            const corners = [4][2]f32{ .{ 34, -6 }, .{ 46, -6 }, .{ 46, 6 }, .{ 34, 6 } };
            const order = [6]u8{ 0, 1, 2, 0, 2, 3 };
            for (order, 0..) |ci, i| out[i] = .{
                .x = anchor_x,
                .y = 0,
                .ox = corners[ci][0],
                .oy = corners[ci][1],
                .u = 0.5,
                .v = 0.5,
                .weight = 0,
                .zmin = scene.ZMIN_ALL,
                .zmax = scene.ZMAX_ALL,
                .flags = if (map_align) scene.Flags.map_align else 0,
                .flip = 0,
                .tangent_q = 0,
                .depth = 0.5,
            };
        }
    };
    var quads: [12]scene.Quad = undefined;
    Q.mark(-0.5, true, quads[0..6]);
    Q.mark(0.0, false, quads[6..12]);
    const paint: [12]scene.PaintVertex = @splat(.{ .color = .{ 255, 255, 255, 255 } });
    const ranges = [_]scene.Range{
        .{ .first = 0, .count = 12, .paint_key = 0, .kind = .symbol, .prim = .quads, .atlas = .sprite },
    };
    try g.uploadScene(alloc, .{ .quads = &quads, .quad_paint = &paint, .ranges = &ranges });

    var u = std.mem.zeroes(Uniforms);
    u.mvp[0] = 1;
    u.mvp[5] = 1;
    u.mvp[15] = 1;
    u.px_to_clip = .{ 2.0 / 256.0, -2.0 / 256.0 };
    u.size_scale = 1;
    u.rot_cos = 1; // unrotated

    const P = struct {
        fn at(buf: []const u8, x: usize, y: usize) [4]u8 {
            const i = (y * 256 + x) * 4;
            return .{ buf[i], buf[i + 1], buf[i + 2], buf[i + 3] };
        }
    };
    const white = [4]u8{ 255, 255, 255, 255 };
    const black = [4]u8{ 0, 0, 0, 255 };

    // Anchors project to (64, 128) and (128, 128); both marks sit 40 px right.
    const flat = try g.renderOffscreen(alloc, u);
    defer alloc.free(flat);
    try std.testing.expectEqual(white, P.at(flat, 104, 128));
    try std.testing.expectEqual(white, P.at(flat, 168, 128));
    try std.testing.expectEqual(black, P.at(flat, 64, 168));

    // Turn the view a quarter turn: the map-aligned offset (40, 0) becomes
    // (0, 40) — straight down the screen — while the viewport one holds.
    u.rot_sin = 1;
    u.rot_cos = 0;
    const turned = try g.renderOffscreen(alloc, u);
    defer alloc.free(turned);
    try std.testing.expectEqual(white, P.at(turned, 64, 168));
    try std.testing.expectEqual(white, P.at(turned, 168, 128));
    try std.testing.expectEqual(black, P.at(turned, 104, 128));
}

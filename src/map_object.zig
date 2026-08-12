//! The retained Map: the object a host drives, wrapped around buildScene.
//!
//! `map.buildScene` is a one-shot kernel — hand it decoded tiles, get one
//! merged scene. A real map needs the machinery around it: pick the tiles the
//! camera can see, fetch and decode them off-thread, rebuild the scene only
//! when the tile set or a layout property actually changes, and answer
//! honestly whether the picture is finished.
//!
//! The rebuild discipline is lookout-marine's, ported from src/root.zig
//! (`// ---- build + render`): a scene OVERSCANS the viewport by 25%, and
//! panning inside that coverage is a uniform change — no rebuild, no upload,
//! no re-tessellation. Zoom is compared against the zoom the NEXT build would
//! use (the camera's target, not its still-easing value), or a continuous
//! pinch re-spawns identical builds all the way through the ease.
//!
//! PER-TILE BUCKETS (DESIGN.md's model). A tile's GEOMETRY is built against
//! that tile's own corner and cached by (tile, style generation), so a pan
//! that brings in two new tiles re-tessellates two tiles, not the nine that
//! are visible. SYMBOLS are deliberately not cached that way: collision is
//! global across the resident set, and a per-tile collider would let labels
//! overlap at every seam. So symbols are laid out once over all tiles and
//! concatenated with the cached geometry (DESIGN.md: "lay out per tile but
//! PLACE globally").
//!
//! Still on the owner thread: the build does not yet run on a worker with a
//! pointer-swap adopt, so a coverage break costs a frame. Per-tile caching
//! shrinks that cost; it does not remove it.
//!
//! THREADING. Everything here runs on the owner thread. The only work that
//! leaves it is tile fetch + decode, inside source/cache.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const styles = @import("style/style.zig");
const map = @import("map.zig");
const caches = @import("source/cache.zig");
const providers = @import("source/provider.zig");
const coord = @import("source/coord.zig");
const cameras = @import("camera.zig");
const types = @import("scene/types.zig");
const gpu = @import("gpu/gpu.zig");

pub const Built = map.Built;
pub const Assets = map.Assets;

/// How far past the viewport a scene is built, as a fraction of the view.
/// The margin is what makes a pan free: the camera has to leave it before
/// anything is rebuilt.
pub const OVERSCAN: f64 = 1.25;

/// Zoom drift that forces a fresh build. 2^0.3 < OVERSCAN, so the scene's
/// coverage still contains the view when this trips.
pub const ZOOM_REBUILD: f64 = 0.3;

/// Tiles one build may pull in. A pathological viewport (a whole world at
/// z14) must not queue a million tiles; the picture degrades to the tiles
/// that fit, which is what a coarser zoom would have shown anyway.
pub const MAX_TILES: usize = 256;

pub const Options = struct {
    cache: caches.Options = .{},
    overscan: f64 = OVERSCAN,
    zoom_rebuild: f64 = ZOOM_REBUILD,
};

/// What one `update` did — the frame's damage report.
pub const Tick = struct {
    /// The scene was rebuilt this tick (buffers changed, re-upload needed).
    rebuilt: bool = false,
    /// Tiles landed in the cache this tick.
    tiles_landed: bool = false,
    /// Tiles still loading.
    pending: usize = 0,
    /// Stream B was refilled for a zoom-only paint change (no re-layout).
    paint_refilled: bool = false,
};

/// One tile's cached geometry: everything the tile contributes to a scene
/// except symbols, built against its own corner and reusable until the style
/// or the build zoom changes.
const Bucket = struct {
    arena: std.heap.ArenaAllocator,
    built: map.Built,
    style_generation: u64,
    zoom: f64,
};

/// A style source bound to somewhere tiles actually come from. The style
/// names sources; what answers for them is the host's to say (a pmtiles
/// archive, a resource provider), so binding is explicit.
const Bound = struct {
    name: []const u8,
    index: usize,
};

pub const Map = struct {
    gpa: Allocator,
    opts: Options,
    cache: caches.Cache,
    cam: cameras.Camera,
    assets: Assets = .{},

    style: ?styles.Style = null,
    /// Bumped by anything that invalidates layout: a new style, a changed
    /// layout property, a new image. Paint-only changes must NOT bump it.
    style_generation: u64 = 0,
    bound: std.ArrayListUnmanaged(Bound) = .empty,

    /// The current scene and the arena that owns it. Two arenas alternate so
    /// a rebuild can run while the previous scene is still being drawn from.
    arenas: [2]std.heap.ArenaAllocator,
    live: usize = 0,
    built: ?Built = null,
    /// Bumps once per rebuild. A host that has uploaded generation N knows a
    /// frame at generation N needs no upload — the "pan changed no buffers"
    /// probe the acceptance test asserts on.
    scene_generation: u64 = 0,
    /// Bumps when stream B alone is refilled (a zoom-only color moved).
    /// Separate from scene_generation so a host re-uploads ONE buffer
    /// instead of the whole scene — that separation is the reason paint is
    /// its own stream.
    paint_generation: u64 = 0,
    rebuilds: u64 = 0,
    paint_refills: u64 = 0,

    /// Coverage of the scene as built, in world units around its origin.
    cov_origin: cameras.Vec2 = .{ .x = 0, .y = 0 },
    cov_zoom: f64 = 0,
    cov_hw: f64 = 0,
    cov_hh: f64 = 0,
    has_coverage: bool = false,
    /// Set by anything that must force a rebuild regardless of coverage.
    dirty: bool = true,

    /// Tiles the last build used, so a tick can tell a tile LANDING from a
    /// mere camera move.
    resident: std.ArrayListUnmanaged(u64) = .empty,
    /// Cached per-tile geometry, keyed by cache key. Each entry owns its
    /// arena and remembers the style generation it was built for.
    buckets: std.AutoHashMapUnmanaged(u64, Bucket) = .empty,
    /// Tiles re-tessellated across the Map's life, and tiles served from the
    /// bucket cache — the ratio is what per-tile caching buys.
    tiles_built: u64 = 0,
    tiles_reused: u64 = 0,

    /// The tile set the current coverage asks for. Chosen when a rebuild is
    /// triggered and then held: re-deriving it from the live camera every
    /// frame would make any pan at all change the set, and the overscan that
    /// exists to make panning free would buy nothing.
    wanted: std.ArrayListUnmanaged(u64) = .empty,

    pub fn init(gpa: Allocator, opts: Options) Map {
        return .{
            .gpa = gpa,
            .opts = opts,
            .cache = caches.Cache.init(gpa, opts.cache),
            .cam = .{
                .origin = .{ .x = 0.5, .y = 0.5 },
                .center = .{ .x = 0.5, .y = 0.5 },
                .zoom = 0,
                .target_zoom = 0,
                .vw = 1,
                .vh = 1,
            },
            .arenas = .{
                std.heap.ArenaAllocator.init(gpa),
                std.heap.ArenaAllocator.init(gpa),
            },
        };
    }

    pub fn deinit(self: *Map) void {
        self.dropBuckets();
        self.buckets.deinit(self.gpa);
        self.cache.deinit();
        if (self.style) |*s| s.deinit();
        for (&self.arenas) |*a| a.deinit();
        for (self.bound.items) |b| self.gpa.free(b.name);
        self.bound.deinit(self.gpa);
        self.resident.deinit(self.gpa);
        self.wanted.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- style ---------------------------------------------------------------

    /// Replace the style. Every tile stays resident — decoded tiles do not
    /// depend on the style — but the scene is rebuilt from scratch.
    pub fn setStyleJson(self: *Map, json: []const u8) !void {
        var parsed = try styles.parse(self.gpa, json);
        errdefer parsed.deinit();
        if (self.style) |*s| s.deinit();
        self.style = parsed;
        self.style_generation += 1;
        self.dirty = true;
    }

    pub fn styleDiagnostics(self: *const Map) []const styles.Diagnostic {
        const s = self.style orelse return &.{};
        return s.diagnostics;
    }

    /// Point a style source name at a place tiles come from. Returns the
    /// cache's source index. Re-binding a name replaces it.
    pub fn bindSource(self: *Map, name: []const u8, src: caches.Source) !usize {
        for (self.bound.items) |*b| {
            if (std.mem.eql(u8, b.name, name)) {
                self.cache.sources.items[b.index] = src;
                self.dirty = true;
                return b.index;
            }
        }
        const idx = try self.cache.addSource(src);
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.bound.append(self.gpa, .{ .name = owned, .index = idx });
        self.dirty = true;
        return idx;
    }

    /// Bind a pmtiles archive to a style source name, taking the decoder and
    /// the zoom band from the STYLE rather than the caller: the spec's
    /// `encoding` field ("mlt" | "mvt", default mvt) picks mlt.decode or
    /// mvt.decode, and the source's maxzoom bounds the tiles asked for.
    /// The archive's own header narrows both further.
    ///
    /// `archive` must outlive the Map.
    pub fn bindPmtiles(self: *Map, name: []const u8, archive: *caches.PmtilesSource) !usize {
        // The archive's declared tile type is the fallback, not the default:
        // a style that says `encoding` means it.
        var encoding: caches.Encoding = archive.headerEncoding() orelse .mvt;
        var maxzoom: u8 = 22;
        if (self.style) |*s| {
            if (s.sources.get(name)) |src| switch (src) {
                .vector => |v| {
                    if (v.encoding) |e| encoding = caches.Encoding.parse(e);
                    maxzoom = @intFromFloat(std.math.clamp(v.maxzoom, 0, 22));
                },
                .raster => |r| maxzoom = @intFromFloat(std.math.clamp(r.maxzoom, 0, 22)),
            };
        }
        return self.bindSource(name, archive.source(encoding, maxzoom));
    }

    /// Bind a pmtiles archive of RASTER tiles (PNG) to a style source name.
    /// Its tiles draw as world-space quads wherever the style puts the
    /// matching `raster` layer.
    pub fn bindRasterPmtiles(self: *Map, name: []const u8, archive: *caches.PmtilesSource) !usize {
        var maxzoom: u8 = 22;
        if (self.style) |*s| {
            if (s.sources.get(name)) |src| switch (src) {
                .raster => |r| maxzoom = @intFromFloat(std.math.clamp(r.maxzoom, 0, 22)),
                .vector => |v| maxzoom = @intFromFloat(std.math.clamp(v.maxzoom, 0, 22)),
            };
        }
        return self.bindSource(name, archive.rasterSource(maxzoom));
    }

    /// Set one paint property. A color or opacity the layer applies
    /// uniformly refills stream B and never re-lays-out (DESIGN.md's
    /// invariant); anything else — a per-feature color, a line width, a
    /// property on a layer with no resident geometry — falls back to a
    /// rebuild, which is correct either way.
    ///
    /// Returns true when it was served as a paint-only change.
    pub fn setPaintProperty(
        self: *Map,
        layer_id: []const u8,
        name: []const u8,
        json_value: std.json.Value,
    ) !bool {
        const style = if (self.style) |*s| s else return error.NoStyle;
        try style.setProperty(layer_id, name, json_value);
        const idx = self.layerIndex(layer_id) orelse {
            self.dirty = true;
            return false;
        };
        const b = if (self.built) |*bb| bb else {
            self.dirty = true;
            return false;
        };
        const a = self.arenas[self.live].allocator();
        if (map.refillLayerPaint(a, style, b, self.cam.zoom, idx)) {
            self.paint_generation += 1;
            self.paint_refills += 1;
            return true;
        }
        // A paint change a refill cannot serve rebuilds -- and the cached
        // per-tile buckets hold that layer's evaluated paint, so they are
        // stale too. Invalidating them is what style_generation is for.
        self.style_generation += 1;
        self.dirty = true;
        return false;
    }

    /// Set one layout property. Layout is geometry, so this always rebuilds.
    pub fn setLayoutProperty(
        self: *Map,
        layer_id: []const u8,
        name: []const u8,
        json_value: std.json.Value,
    ) !void {
        const style = if (self.style) |*s| s else return error.NoStyle;
        try style.setProperty(layer_id, name, json_value);
        self.style_generation += 1;
        self.dirty = true;
    }

    /// Replace a layer's filter WHOLESALE (or clear it with null). There is
    /// no merge and no partial update — a host that assumes otherwise
    /// silently widens what draws.
    pub fn setFilter(self: *Map, layer_id: []const u8, json_filter: ?std.json.Value) !void {
        const style = if (self.style) |*s| s else return error.NoStyle;
        try style.setFilter(layer_id, json_filter);
        self.style_generation += 1;
        self.dirty = true;
    }

    pub fn setLayerVisibility(self: *Map, layer_id: []const u8, on: bool) !void {
        const style = if (self.style) |*s| s else return error.NoStyle;
        try style.setVisibility(layer_id, on);
        self.style_generation += 1;
        self.dirty = true;
    }

    fn layerIndex(self: *const Map, layer_id: []const u8) ?u32 {
        const style = self.style orelse return null;
        for (style.layers, 0..) |*l, i| {
            if (std.mem.eql(u8, l.id, layer_id)) return @intCast(i);
        }
        return null;
    }

    /// Bind a style source name to a host-supplied resource provider. The
    /// provider must outlive the Map; its tiles arrive asynchronously and
    /// park until they do.
    pub fn bindProvider(self: *Map, name: []const u8, p: *providers.Provider) !usize {
        if (self.style) |*s| {
            if (s.sources.get(name)) |src| switch (src) {
                .vector => |v| {
                    p.encoding = caches.Encoding.parse(v.encoding);
                    p.kind = .vector;
                    p.maxzoom = @intFromFloat(std.math.clamp(v.maxzoom, 0, 22));
                },
                .raster => |r| {
                    p.kind = .raster;
                    p.maxzoom = @intFromFloat(std.math.clamp(r.maxzoom, 0, 22));
                },
            };
        }
        return self.bindSource(name, p.source());
    }

    /// Symbol assets. Changing them re-lays-out (an icon that was missing may
    /// now resolve), so this bumps the style generation.
    pub fn setAssets(self: *Map, assets: Assets) void {
        self.assets = assets;
        self.style_generation += 1;
        self.dirty = true;
    }

    // ---- camera --------------------------------------------------------------

    pub fn setViewport(self: *Map, w_px: f32, h_px: f32) void {
        if (self.cam.vw == w_px and self.cam.vh == h_px) return;
        self.cam.vw = w_px;
        self.cam.vh = h_px;
        // A bigger viewport can outrun the built coverage; needsRebuild sees
        // it through halfExtents, so no forced dirty here.
    }

    pub fn setView(self: *Map, lon: f64, lat: f64, zoom: f64) void {
        const w = coord.lonLatToWorld(lon, lat);
        self.cam.center = .{ .x = w[0], .y = w[1] };
        self.cam.zoom = zoom;
        self.cam.setTarget();
        self.cam.clampY();
    }

    pub fn camera(self: *Map) *cameras.Camera {
        return &self.cam;
    }

    // ---- the frame -----------------------------------------------------------

    /// One frame's worth of map work: ask for the tiles the camera can see,
    /// adopt whatever finished decoding, and rebuild the scene if the view
    /// has left the built coverage or the tile set changed under it.
    ///
    /// Never blocks. A tile that has not arrived is simply not in the scene;
    /// the frame draws what is resident, which is the whole point of the
    /// "never block a frame on layout" invariant.
    pub fn update(self: *Map) !Tick {
        var tick = Tick{};
        tick.tiles_landed = self.cache.tick();

        // A style with no bound source still builds: its background layer is
        // a real scene, and a map that never builds never reports idle.
        const style = self.style orelse return tick;

        // The tile set is re-chosen only when the view has left the built
        // coverage (or something forced a rebuild). Inside coverage the set
        // is frozen, which is what makes a pan cost nothing.
        const coverage_broke = self.dirty or self.needsRebuild();
        if (coverage_broke) {
            self.wanted.clearRetainingCapacity();
            try self.visibleTiles(&self.wanted);
        }
        // Asking every frame is also what holds the set against eviction.
        for (self.wanted.items) |k| _ = self.cache.want(@bitCast(k));
        tick.pending = self.pendingWanted();

        // Which of those are actually here. A tile that came back empty or
        // failed is ANSWERED but has no geometry, so it is simply absent from
        // the build; only a tile LANDING changes this list.
        var have: std.ArrayListUnmanaged(u64) = .empty;
        defer have.deinit(self.gpa);
        for (self.wanted.items) |k| {
            if (self.cache.isResident(@bitCast(k))) try have.append(self.gpa, k);
        }

        if (!coverage_broke and self.sameResident(have.items)) {
            tick.paint_refilled = self.refillPaintIfMoved(&style);
            return tick;
        }

        try self.rebuild(&style, have.items);
        tick.rebuilt = true;
        return tick;
    }

    /// Tiles THIS view is waiting on. The cache may still be finishing tiles
    /// from a coverage the camera has already left; those must not keep the
    /// map from reporting idle.
    pub fn pendingWanted(self: *const Map) usize {
        var n: usize = 0;
        for (self.wanted.items) |k| {
            const st = self.cache.state(@bitCast(k)) orelse {
                n += 1; // never asked, or parked and dropped: still outstanding
                continue;
            };
            if (st == .loading) n += 1;
        }
        return n;
    }

    /// A zoom-only color follows the camera, so when the camera moves
    /// inside its coverage the scene's paint is stale even though its
    /// geometry is not. Refill stream B and leave everything else alone.
    ///
    /// Quantized to the same 1/256 zoom steps the vertex zoom window uses:
    /// below that the color change is not representable in the frame, and
    /// the quantization is what stops a continuous pinch refilling every
    /// frame for nothing.
    fn refillPaintIfMoved(self: *Map, style: *const styles.Style) bool {
        const b = if (self.built) |*bb| bb else return false;
        if (b.paint_spans.len == 0) return false;
        const zoom = self.cam.zoom;
        if (types.zq(zoom) == types.zq(b.paint_zoom)) return false;
        const a = self.arenas[self.live].allocator();
        if (!map.refillPaint(a, style, b, zoom)) return false;
        self.paint_generation += 1;
        self.paint_refills += 1;
        return true;
    }

    /// True when the view has panned or zoomed out of the built coverage. The
    /// x distance WRAPS: crossing the antimeridian is a short hop, not a
    /// world-width jump.
    pub fn needsRebuild(self: *Map) bool {
        if (self.style == null) return false;
        if (!self.has_coverage) return true;
        if (@abs(self.buildTargetZoom() - self.cov_zoom) > self.opts.zoom_rebuild) return true;
        // A zoom-interpolated paint pair brackets one integer zoom. Drift
        // across that boundary and the two halves no longer bracket the
        // camera, so the shader would mix the wrong pair.
        if (self.built) |b| {
            if (b.paint_hi.len > 0 and @floor(self.buildTargetZoom()) != b.paint_zoom_floor) return true;
        }
        const he = self.cam.halfExtents();
        return @abs(cameras.wrapDx(self.cam.center.x, self.cov_origin.x)) + he.x > self.cov_hw or
            @abs(self.cam.center.y - self.cov_origin.y) + he.y > self.cov_hh;
    }

    /// The zoom the NEXT scene should be built for: where the camera is
    /// HEADING, clamped to the deepest zoom any bound source serves.
    pub fn buildTargetZoom(self: *const Map) f64 {
        var maxz: f64 = 24;
        for (self.cache.sources.items) |s| maxz = @min(maxz, @as(f64, @floatFromInt(s.maxzoom)));
        const target = if (self.cam.target_zoom > 0) self.cam.target_zoom else self.cam.zoom;
        return @min(target, maxz);
    }

    /// Honest damage: is there anything left to do?
    pub fn needsRedraw(self: *Map) bool {
        return self.dirty or self.cam.animating() or self.needsRebuild() or
            self.pendingWanted() > 0;
    }

    /// Honest completeness (concerns C12: "placed", not "style loaded"). True
    /// when every tile the view asked for has an answer, the scene covers the
    /// view, and the camera has stopped moving.
    pub fn idle(self: *Map) bool {
        return !self.needsRedraw();
    }

    pub fn scene(self: *const Map) ?*const Built {
        return if (self.built) |*b| b else null;
    }

    /// The uniform block for the current camera and scene origin.
    pub fn uniforms(self: *const Map) types.Uniforms {
        const origin = if (self.has_coverage) self.cov_origin else self.cam.center;
        const rs = self.cam.rotSinCos();
        const anchor = self.cam.worldToScreen(origin);
        const bg = if (self.built) |b| b.background else map.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
        _ = bg;
        return .{
            .mvp = self.cam.mvpOrigin(origin),
            .px_to_clip = self.cam.pxToClip(),
            .size_scale = 1,
            .zoom = @floatFromInt(types.zq(self.cam.zoom)),
            .zoom_t = @floatCast(self.cam.zoom - @floor(self.cam.zoom)),
            .wrap_x = @floatCast(cameras.wrapDx(self.cam.center.x, origin.x)),
            .rot_sin = rs[0],
            .rot_cos = rs[1],
            .color = .{ 0, 0, 0, 0 },
            .anchor_px = .{ @floatCast(anchor.x), @floatCast(anchor.y) },
            .cell_px = .{ 1, 1 },
        };
    }

    /// What a host has already uploaded. Two counters, because the two
    /// streams change independently: a rebuild replaces everything, a
    /// zoom-only color change replaces stream B alone.
    pub const Uploaded = struct {
        scene: u64 = 0,
        paint: u64 = 0,
    };

    /// Bring `g` up to date with the current scene and report whether
    /// anything was sent. Split from drawing so a host can upload on a
    /// worker-fed frame boundary and draw whenever it likes.
    pub fn uploadIfChanged(self: *Map, g: *gpu.Gpu, state: *Uploaded) !bool {
        const b = self.built orelse return false;
        if (state.scene == self.scene_generation) {
            // Geometry is current; only the paint stream may have moved.
            if (state.paint == self.paint_generation) return false;
            try g.updatePaint(b.paint);
            state.paint = self.paint_generation;
            return true;
        }
        g.clear = .{ .r = b.background.r, .g = b.background.g, .b = b.background.b, .a = b.background.a };
        try g.uploadScene(self.gpa, .{
            .vertices = b.vertices,
            .paint = b.paint,
            .paint_hi = b.paint_hi,
            .indices = b.indices,
            .quads = b.quads,
            .quad_paint = b.quad_paint,
            .ranges = b.ranges,
            .patterns = b.patterns,
        });
        state.scene = self.scene_generation;
        state.paint = self.paint_generation;
        return true;
    }

    // ---- internals -----------------------------------------------------------

    /// The style source name a cache source index was bound to. A raster
    /// layer draws only its own source's tiles, so the name has to travel
    /// with the image.
    fn sourceName(self: *const Map, index: u3) []const u8 {
        for (self.bound.items) |b| {
            if (b.index == index) return b.name;
        }
        return "";
    }

    fn dropBuckets(self: *Map) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |b| b.arena.deinit();
        self.buckets.clearRetainingCapacity();
    }

    /// The cached geometry for one tile, building it if the cache has none
    /// for this style generation. Built against the TILE'S OWN corner, so it
    /// stays valid however the camera moves.
    fn bucketFor(
        self: *Map,
        style: *const styles.Style,
        key: caches.Key,
        zoom: f64,
    ) !?*Bucket {
        const k = key.pack();
        if (self.buckets.getPtr(k)) |b| {
            if (b.style_generation == self.style_generation and b.zoom == zoom) {
                self.tiles_reused += 1;
                return b;
            }
            b.arena.deinit();
            _ = self.buckets.remove(k);
        }
        const tile = self.cache.get(key) orelse return null;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const rect = key.tileId().worldRect();
        var one: [1]map.SourcedTile = .{.{ .id = key.tileId(), .tile = tile }};
        const built = try map.buildScene(arena.allocator(), style, &one, .{
            .zoom = zoom,
            .origin = .{ .x = rect.x0, .y = rect.y0 },
            .layers = .tile_local,
        }, self.assets);
        try self.buckets.put(self.gpa, k, .{
            .arena = arena,
            .built = built,
            .style_generation = self.style_generation,
            .zoom = zoom,
        });
        self.tiles_built += 1;
        return self.buckets.getPtr(k);
    }

    /// Drop cached geometry for tiles the current coverage no longer wants.
    fn evictBuckets(self: *Map, keep: []const u64) void {
        var stale: [MAX_TILES]u64 = undefined;
        var n: usize = 0;
        var it = self.buckets.iterator();
        while (it.next()) |kv| {
            if (std.mem.indexOfScalar(u64, keep, kv.key_ptr.*) != null) continue;
            if (n == stale.len) break;
            stale[n] = kv.key_ptr.*;
            n += 1;
        }
        for (stale[0..n]) |k| {
            if (self.buckets.fetchRemove(k)) |kv| {
                var b = kv.value;
                b.arena.deinit();
            }
        }
    }

    fn sameResident(self: *const Map, have: []const u64) bool {
        if (have.len != self.resident.items.len) return false;
        for (have, self.resident.items) |a, b| {
            if (a != b) return false;
        }
        return true;
    }

    /// The tiles covering the overscanned viewport, per bound source, at the
    /// integer zoom nearest the build target and inside that source's band.
    /// Keys come out sorted so `sameResident` is an ordered compare.
    fn visibleTiles(self: *Map, out: *std.ArrayListUnmanaged(u64)) !void {
        const zoom = self.buildTargetZoom();
        const he = self.cam.halfExtents();
        const hw = he.x * self.opts.overscan;
        const hh = he.y * self.opts.overscan;
        const cx = self.cam.center.x;
        const cy = self.cam.center.y;

        for (self.cache.sources.items, 0..) |src, si| {
            const tz: u8 = @intCast(std.math.clamp(
                @as(i64, @intFromFloat(@round(zoom))),
                @as(i64, src.minzoom),
                @as(i64, src.maxzoom),
            ));
            const n: i64 = @as(i64, 1) << @intCast(tz);
            const nf: f64 = @floatFromInt(n);
            const x0: i64 = @intFromFloat(@floor((cx - hw) * nf));
            const x1: i64 = @intFromFloat(@floor((cx + hw) * nf));
            const y0: i64 = @max(0, @as(i64, @intFromFloat(@floor((cy - hh) * nf))));
            const y1: i64 = @min(n - 1, @as(i64, @intFromFloat(@floor((cy + hh) * nf))));

            var ty = y0;
            while (ty <= y1) : (ty += 1) {
                var tx = x0;
                while (tx <= x1) : (tx += 1) {
                    if (out.items.len >= MAX_TILES) return;
                    // Longitude is cyclic: a view over the antimeridian asks
                    // for the wrapped column, not a negative one.
                    const wx = @mod(@mod(tx, n) + n, n);
                    try out.append(self.gpa, caches.Key.of(si, .{
                        .z = tz,
                        .x = @intCast(wx),
                        .y = @intCast(ty),
                    }).pack());
                }
            }
        }
        std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    }

    fn rebuild(self: *Map, style: *const styles.Style, have: []const u64) !void {
        // Build into the arena the current scene is NOT using, so the old
        // scene stays valid until the new one replaces it.
        const next = (self.live + 1) % 2;
        _ = self.arenas[next].reset(.retain_capacity);
        const a = self.arenas[next].allocator();

        const origin = self.cam.center;
        const zoom = self.buildTargetZoom();

        // Geometry: one cached bucket per tile, rebased at concatenation.
        // Rasters ride the merged pass with the symbols — they carry
        // borrowed image memory the cache owns, so caching them per tile
        // would outlive the eviction that frees it.
        var parts: std.ArrayListUnmanaged(map.ScenePart) = .empty;
        defer parts.deinit(self.gpa);
        var vector_tiles: std.ArrayListUnmanaged(map.SourcedTile) = .empty;
        var rasters: std.ArrayListUnmanaged(map.RasterTile) = .empty;
        for (have) |k| {
            const key: caches.Key = @bitCast(k);
            switch (self.cache.sourceKind(key)) {
                .vector => {
                    const tile = self.cache.get(key) orelse continue;
                    try vector_tiles.append(a, .{ .id = key.tileId(), .tile = tile });
                    const bucket = (try self.bucketFor(style, key, zoom)) orelse continue;
                    const rect = key.tileId().worldRect();
                    try parts.append(self.gpa, .{
                        .built = bucket.built,
                        .dx = @floatCast(rect.x0 - origin.x),
                        .dy = @floatCast(rect.y0 - origin.y),
                    });
                },
                .raster => {
                    const img = self.cache.getRaster(key) orelse continue;
                    try rasters.append(a, .{
                        .id = key.tileId(),
                        .source = self.sourceName(key.source),
                        .w = img.w,
                        .h = img.h,
                        .rgba = img.rgba,
                    });
                },
            }
        }

        // Symbols and rasters once over every tile: collision stays global,
        // and raster images stay borrowed from the tile cache rather than
        // cached past their owner's lifetime.
        try parts.append(self.gpa, .{
            .built = try map.buildSceneWithRasters(a, style, vector_tiles.items, rasters.items, .{
                .zoom = zoom,
                .origin = origin,
                .layers = .global,
            }, self.assets),
            .dx = 0,
            .dy = 0,
        });

        self.built = try map.concatScenes(a, parts.items);
        self.live = next;
        self.scene_generation += 1;
        self.paint_generation += 1;
        self.rebuilds += 1;
        self.dirty = false;

        self.resident.clearRetainingCapacity();
        try self.resident.appendSlice(self.gpa, have);
        self.evictBuckets(self.wanted.items);
        self.recordCoverage(origin, zoom);
    }

    /// Record what the scene just built actually covers, so needsRebuild can
    /// tell when the view has left it.
    fn recordCoverage(self: *Map, origin: cameras.Vec2, zoom: f64) void {
        const he = self.cam.halfExtents();
        self.cov_origin = origin;
        self.cov_zoom = zoom;
        self.cov_hw = he.x * self.opts.overscan;
        self.cov_hh = he.y * self.opts.overscan;
        self.has_coverage = true;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const test_style =
    \\{"version": 8,
    \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
    \\ "layers": [
    \\   {"id": "bg", "type": "background", "paint": {"background-color": "#112233"}},
    \\   {"id": "areas", "type": "fill", "source": "chart", "source-layer": "areas",
    \\    "paint": {"fill-color": "#00ff00"}}]}
;

/// A source that answers every tile with the same one-polygon tile, and
/// counts what was asked for.
const StubSource = struct {
    bytes: []const u8,
    asked: std.atomic.Value(u32) = .init(0),

    fn fetch(ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) caches.Fetch {
        const self: *StubSource = @ptrCast(@alignCast(ptr.?));
        _ = id;
        _ = self.asked.fetchAdd(1, .monotonic);
        return .{ .bytes = gpa.dupe(u8, self.bytes) catch return .failed };
    }

    fn source(self: *StubSource, maxzoom: u8) caches.Source {
        return .{ .ptr = self, .fetch = fetch, .encoding = .mvt, .maxzoom = maxzoom };
    }
};

/// One MVT layer "areas" holding a single square polygon over the whole tile.
fn stubTileBytes(a: Allocator) ![]const u8 {
    var geom: std.ArrayListUnmanaged(u8) = .empty;
    // MoveTo(1) 0,0; LineTo(3) +4096,0 0,+4096 -4096,0; ClosePath
    try geom.appendSlice(a, &.{ (1 << 3) | 1, 0, 0 });
    try geom.appendSlice(a, &.{ (3 << 3) | 2, 0x80, 0x40, 0, 0, 0x80, 0x40, 0xFF, 0x3F, 0 });
    try geom.appendSlice(a, &.{(1 << 3) | 7});

    var feat: std.ArrayListUnmanaged(u8) = .empty;
    try feat.appendSlice(a, &.{ 3 << 3 | 0, 3 }); // type = POLYGON
    try feat.appendSlice(a, &.{ 4 << 3 | 2, @intCast(geom.items.len) });
    try feat.appendSlice(a, geom.items);

    var layer: std.ArrayListUnmanaged(u8) = .empty;
    try layer.appendSlice(a, &.{ 15 << 3 | 0, 2 }); // version
    try layer.appendSlice(a, &.{ 1 << 3 | 2, 5 });
    try layer.appendSlice(a, "areas");
    try layer.appendSlice(a, &.{ 2 << 3 | 2, @intCast(feat.items.len) });
    try layer.appendSlice(a, feat.items);
    try layer.appendSlice(a, &.{ 5 << 3 | 0, 0x80, 0x20 }); // extent = 4096

    var tile: std.ArrayListUnmanaged(u8) = .empty;
    try tile.appendSlice(a, &.{ 3 << 3 | 2, @intCast(layer.items.len) });
    try tile.appendSlice(a, layer.items);
    return tile.items;
}

fn settle(m: *Map) !void {
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) {
        _ = try m.update();
        if (m.idle()) return;
        @import("util/lock.zig").sleepMs(1);
    }
    return error.NeverSettled;
}

test "Map: tiles load, the scene builds once, and idle settles true" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);

    try testing.expect(!m.idle()); // nothing built yet
    try settle(&m);

    const b = m.scene() orelse return error.NoScene;
    try testing.expect(b.ranges.len > 0);
    try testing.expectApproxEqAbs(@as(f32, 0x11) / 255.0, b.background.r, 1e-3);
    try testing.expectEqual(@as(usize, 0), m.cache.pending());
    // A 512px view at z14 spans one tile; the 1.25 overscan reaches its
    // neighbors, so a 2x2 or 3x3 block loads — never the whole world.
    try testing.expect(m.resident.items.len >= 4);
    try testing.expect(m.resident.items.len <= 16);

    // Settled means settled: another tick changes nothing.
    const gen = m.scene_generation;
    const rebuilds = m.rebuilds;
    for (0..5) |_| _ = try m.update();
    try testing.expectEqual(gen, m.scene_generation);
    try testing.expectEqual(rebuilds, m.rebuilds);
    try testing.expect(m.idle());
}

test "Map: panning inside coverage changes no buffers; leaving it rebuilds" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    const gen = m.scene_generation;
    const rebuilds = m.rebuilds;

    // A few px of pan: well inside the 25% margin. The camera moves, the
    // scene does not — this is the invariant the whole overscan exists for.
    m.cam.panPx(8, 8);
    _ = try m.update();
    try testing.expectEqual(gen, m.scene_generation);
    try testing.expectEqual(rebuilds, m.rebuilds);
    try testing.expect(!m.needsRebuild());

    // The free margin is 25% of the HALF extent -- 64 px at a 512 px
    // viewport -- so 8 + 40 px of pan is still inside it.
    m.cam.panPx(40, 0);
    _ = try m.update();
    try testing.expectEqual(rebuilds, m.rebuilds);
    try testing.expectEqual(gen, m.scene_generation);

    // Now leave it: a full viewport of pan is past the margin.
    m.cam.panPx(700, 0);
    try testing.expect(m.needsRebuild());
    try settle(&m);
    try testing.expect(m.rebuilds > rebuilds);
    try testing.expect(m.scene_generation > gen);
}

test "Map: a zoom inside the band holds the scene; a big one rebuilds" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);
    const rebuilds = m.rebuilds;

    // Inside ZOOM_REBUILD and inside coverage: uniforms only.
    m.cam.zoom = 14.2;
    m.cam.setTarget();
    _ = try m.update();
    try testing.expectEqual(rebuilds, m.rebuilds);

    // Past it.
    m.cam.zoom = 13.0;
    m.cam.setTarget();
    try testing.expect(m.needsRebuild());
    try settle(&m);
    try testing.expect(m.rebuilds > rebuilds);
    // The build clamps to the source's deepest zoom, so an overscaled view
    // keeps asking for the tiles that exist.
    m.cam.zoom = 18;
    m.cam.setTarget();
    try settle(&m);
    try testing.expectEqual(@as(f64, 14), m.buildTargetZoom());
}

test "Map: a style swap rebuilds without refetching tiles" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);
    const fetched = stub.asked.load(.monotonic);
    const rebuilds = m.rebuilds;

    const other =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "bg", "type": "background",
        \\   "paint": {"background-color": "#ff0000"}}]}
    ;
    try m.setStyleJson(other);
    try settle(&m);
    try testing.expect(m.rebuilds > rebuilds);
    try testing.expectApproxEqAbs(@as(f32, 1), m.scene().?.background.r, 1e-3);
    // Decoded tiles do not depend on the style, so nothing was re-fetched.
    try testing.expectEqual(fetched, stub.asked.load(.monotonic));
}

// The acceptance run: a real archive behind a real Map, panned across
// Annapolis. Asserts the three things the object exists to get right —
// rebuilds happen only when coverage breaks, a pan inside coverage touches
// no buffers, and idle() settles — and then checks the Map's picture against
// a direct buildScene render of the same view, pixel for pixel.
test "Map: pan across Annapolis rebuilds only on coverage breaks" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pmtiles = @import("source/pmtiles.zig");
    const mlt = @import("source/mlt.zig");
    const mvt = @import("source/mvt.zig");
    const ct_build = @import("ct_build");
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = testing.allocator;

    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    var reader = pmtiles.Reader.open(gpa, io, std.mem.span(chart_env)) catch
        return error.SkipZigTest;
    defer reader.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const style_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/chart-day-style.json", .{ct_build.assets_dir}),
        a,
        .limited(4 * 1024 * 1024),
    );

    var src = caches.PmtilesSource{ .reader = &reader };
    var m = Map.init(gpa, .{ .cache = .{ .workers = 3 } });
    defer m.deinit();
    try m.setStyleJson(style_json);
    // No decoder named here: the style's `encoding` (absent in tile57's
    // generated style) falls back to the archive's own declared tile type.
    try testing.expectEqual(caches.Encoding.mlt, src.headerEncoding().?);
    _ = try m.bindPmtiles("chart", &src);
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);

    try settle(&m);
    const first_rebuilds = m.rebuilds;
    try testing.expect(first_rebuilds > 0);
    try testing.expect(m.scene().?.ranges.len > 10);
    try testing.expect(m.idle());

    // A pan inside the margin: the camera moves, the buffers do not.
    const gen_before = m.scene_generation;
    for (0..8) |_| {
        m.cam.panPx(6, 0);
        _ = try m.update();
    }
    try testing.expectEqual(gen_before, m.scene_generation);
    try testing.expectEqual(first_rebuilds, m.rebuilds);
    try testing.expect(m.idle());

    // Snapshot stop one, and the same view built directly. Same tiles, same
    // order, same origin and zoom, so the two renders must be identical.
    var g = gpu.Gpu.init(.{ .width = 512, .height = 512 }) catch return error.SkipZigTest;
    defer g.deinit();

    const StopCheck = struct {
        fn compare(
            m2: *Map,
            g2: *gpu.Gpu,
            a2: Allocator,
            rd: *pmtiles.Reader,
            style_src: []const u8,
        ) !void {
            var uploaded: Map.Uploaded = .{};
            _ = try m2.uploadIfChanged(g2, &uploaded);
            const mine = try g2.renderOffscreen(a2, m2.uniforms());

            // The direct build: the SAME tiles in the SAME order the Map
            // used, so range order (and therefore blend order) matches.
            var tiles: std.ArrayListUnmanaged(map.SourcedTile) = .empty;
            for (m2.resident.items) |k| {
                const key: caches.Key = @bitCast(k);
                const id = key.tileId();
                const bytes = (rd.getTile(a2, id.z, id.x, id.y) catch continue) orelse continue;
                const tile = try a2.create(mvt.Tile);
                tile.* = mlt.decode(a2, bytes) catch continue;
                try tiles.append(a2, .{ .id = id, .tile = tile });
            }
            var style2 = try styles.parse(testing.allocator, style_src);
            defer style2.deinit();
            const direct = try map.buildScene(a2, &style2, tiles.items, .{
                .zoom = m2.cov_zoom,
                .origin = m2.cov_origin,
            }, .{});
            try testing.expectEqual(m2.scene().?.ranges.len, direct.ranges.len);
            try testing.expectEqual(m2.scene().?.vertices.len, direct.vertices.len);

            g2.clear = .{
                .r = direct.background.r,
                .g = direct.background.g,
                .b = direct.background.b,
                .a = direct.background.a,
            };
            try g2.uploadScene(a2, .{
                .vertices = direct.vertices,
                .paint = direct.paint,
                .indices = direct.indices,
                .quads = direct.quads,
                .quad_paint = direct.quad_paint,
                .ranges = direct.ranges,
                .patterns = direct.patterns,
            });
            const reference = try g2.renderOffscreen(a2, m2.uniforms());
            try testing.expectEqualSlices(u8, reference, mine);
        }
    };
    try StopCheck.compare(&m, &g, a, &reader, style_json);

    // Stop two: pan clear of the coverage box. That must rebuild, and the
    // rebuilt scene must again match a direct build of where we landed.
    m.cam.panPx(900, 300);
    try testing.expect(m.needsRebuild());
    try settle(&m);
    try testing.expect(m.rebuilds > first_rebuilds);
    const after_second = m.rebuilds;
    try StopCheck.compare(&m, &g, a, &reader, style_json);

    // And settled again: no rebuild churn once the camera stops.
    for (0..5) |_| _ = try m.update();
    try testing.expectEqual(after_second, m.rebuilds);
    try testing.expect(m.idle());

    std.debug.print(
        "\nmap pan: {d} rebuilds over the path, {d} tiles resident, {d} KB cached\n",
        .{ m.rebuilds, m.resident.items.len, m.cache.residentBytes() / 1024 },
    );
}

// DESIGN.md's invariant, stated as a test: "Paint changes never re-layout."
// A zoom-only color follows the camera, so moving the camera inside the
// built coverage MUST move the color — and must do it by refilling stream B,
// not by rebuilding.
test "Map: a zoom-only color refills stream B without re-laying-out" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    // Green at z14, red at z16, interpolated between: zoom-only, so it is
    // paint, not geometry.
    const style =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "areas", "type": "fill", "source": "chart",
        \\   "source-layer": "areas",
        \\   "paint": {"fill-color": ["interpolate", ["linear"], ["zoom"],
        \\      14, "#00ff00", 16, "#ff0000"]}}]}
    ;
    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    const b = m.scene() orelse return error.NoScene;
    try testing.expect(b.paint_spans.len > 0); // the layer was recognized
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, b.paint[0].color);

    const rebuilds = m.rebuilds;
    const scene_gen = m.scene_generation;
    const paint_gen = m.paint_generation;
    const verts = b.vertices.len;

    // Zoom a little, still well inside the coverage box and inside
    // ZOOM_REBUILD. The color must move; nothing else may.
    m.cam.zoom = 14.5;
    m.cam.setTarget();
    const tick = try m.update();
    try testing.expect(tick.paint_refilled);
    try testing.expect(!tick.rebuilt);
    try testing.expectEqual(rebuilds, m.rebuilds);
    try testing.expectEqual(scene_gen, m.scene_generation);
    try testing.expect(m.paint_generation > paint_gen);

    const b2 = m.scene().?;
    try testing.expectEqual(verts, b2.vertices.len); // no re-tessellation
    const mid = b2.paint[0].color;
    try testing.expect(mid[0] > 0 and mid[1] > 0); // partway from green to red
    try testing.expect(mid[0] < 255 and mid[1] < 255);

    // Same zoom again: nothing to do. Idle means idle.
    const gen2 = m.paint_generation;
    const again = try m.update();
    try testing.expect(!again.paint_refilled);
    try testing.expectEqual(gen2, m.paint_generation);

    // And a PAN, which changes no zoom, must not touch paint either.
    m.cam.panPx(4, 0);
    const panned = try m.update();
    try testing.expect(!panned.paint_refilled);
    try testing.expectEqual(gen2, m.paint_generation);
}

test "Map: setPaintProperty refills; setLayoutProperty and setFilter rebuild" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    const style =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "areas", "type": "fill", "source": "chart",
        \\   "source-layer": "areas", "paint": {"fill-color": "#00ff00"}}]}
    ;
    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, m.scene().?.paint[0].color);
    const rebuilds = m.rebuilds;
    const scene_gen = m.scene_generation;

    // A uniform color: paint only. No rebuild, no new geometry.
    var doc = std.heap.ArenaAllocator.init(a);
    defer doc.deinit();
    const red = try std.json.parseFromSliceLeaky(std.json.Value, doc.allocator(), "\"#ff0000\"", .{});
    try testing.expect(try m.setPaintProperty("areas", "fill-color", red));
    try testing.expectEqual(rebuilds, m.rebuilds);
    try testing.expectEqual(scene_gen, m.scene_generation);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, m.scene().?.paint[0].color);

    // An expression is fine too, as long as it is not per-feature.
    const zoomy = try std.json.parseFromSliceLeaky(std.json.Value, doc.allocator(),
        \\["interpolate", ["linear"], ["zoom"], 10, "#0000ff", 20, "#0000ff"]
    , .{});
    try testing.expect(try m.setPaintProperty("areas", "fill-color", zoomy));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, m.scene().?.paint[0].color);
    try testing.expectEqual(rebuilds, m.rebuilds);

    // A per-feature color cannot be refilled: it must rebuild.
    const ddriven = try std.json.parseFromSliceLeaky(std.json.Value, doc.allocator(),
        \\["match", ["get", "kind"], "water", "#101010", "#202020"]
    , .{});
    try testing.expect(!try m.setPaintProperty("areas", "fill-color", ddriven));
    try testing.expect(m.dirty);
    try settle(&m);
    try testing.expect(m.rebuilds > rebuilds);
    try testing.expectEqual([4]u8{ 32, 32, 32, 255 }, m.scene().?.paint[0].color);

    // Layout and filter changes always rebuild.
    const after = m.rebuilds;
    const none = try std.json.parseFromSliceLeaky(std.json.Value, doc.allocator(), "\"none\"", .{});
    try m.setLayoutProperty("areas", "visibility", none);
    try testing.expect(m.dirty);
    try settle(&m);
    try testing.expect(m.rebuilds > after);

    const filt = try std.json.parseFromSliceLeaky(std.json.Value, doc.allocator(),
        \\["==", ["get", "kind"], "nothing-matches-this"]
    , .{});
    const before_filter = m.rebuilds;
    try m.setFilter("areas", filt);
    try settle(&m);
    try testing.expect(m.rebuilds > before_filter);
    // The filter admits nothing, so the layer draws nothing.
    try testing.expectEqual(@as(usize, 0), m.scene().?.ranges.len);

    // Clearing it brings the features back.
    try m.setFilter("areas", null);
    try settle(&m);
    try testing.expect(m.scene().?.ranges.len > 0);

    // An unknown layer or property is refused, not guessed at.
    try testing.expectError(error.UnknownLayer, m.setLayoutProperty("nope", "visibility", none));
    try testing.expectError(error.UnknownProperty, m.setLayoutProperty("areas", "not-a-prop", none));
}

test "Map: a feature-driven color records no paint span" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    // Data-driven, not zoom-driven: a refill could not serve it (each
    // feature has its own value), so no span may be recorded.
    const style =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "areas", "type": "fill", "source": "chart",
        \\   "source-layer": "areas",
        \\   "paint": {"fill-color": ["match", ["get", "kind"],
        \\      "water", "#0000ff", "#00ff00"]}}]}
    ;
    var m = Map.init(a, .{ .cache = .{ .workers = 1 } });
    defer m.deinit();
    try m.setStyleJson(style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);
    try testing.expectEqual(@as(usize, 0), m.scene().?.paint_spans.len);

    m.cam.zoom = 14.5;
    m.cam.setTarget();
    const tick = try m.update();
    try testing.expect(!tick.paint_refilled);
}

test "Map: a pan re-tessellates only the tiles that arrived" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    _ = try m.bindSource("chart", stub.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    const built_first = m.tiles_built;
    try testing.expect(built_first > 0);
    try testing.expectEqual(m.resident.items.len, m.buckets.count());

    // Pan clear of the coverage box. The new tile set overlaps the old, so
    // the tiles that were already resident must come from the bucket cache
    // rather than being tessellated again.
    const reused_before = m.tiles_reused;
    m.cam.panPx(300, 0);
    try testing.expect(m.needsRebuild());
    try settle(&m);
    try testing.expect(m.tiles_reused > reused_before);
    // And it did not rebuild the world: fewer fresh builds than tiles drawn.
    try testing.expect(m.tiles_built - built_first < m.resident.items.len);

    // A style change invalidates every bucket, because a bucket holds that
    // style's evaluated paint as well as its geometry.
    const built_before_style = m.tiles_built;
    const other =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [
        \\   {"id": "bg", "type": "background", "paint": {"background-color": "#ff0000"}},
        \\   {"id": "areas", "type": "fill", "source": "chart", "source-layer": "areas",
        \\    "paint": {"fill-color": "#123456"}}]}
    ;
    try m.setStyleJson(other);
    try settle(&m);
    try testing.expect(m.tiles_built > built_before_style);
    try testing.expectEqual([4]u8{ 0x12, 0x34, 0x56, 255 }, m.scene().?.paint[0].color);
    try testing.expectApproxEqAbs(@as(f32, 1), m.scene().?.background.r, 1e-3);

    // Buckets never outlive the coverage that wants them.
    try testing.expect(m.buckets.count() <= m.wanted.items.len);
}

test "Map: a raster source draws as world-space quads in style order" {
    const a = testing.allocator;
    const png = @import("util/png.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    // A 4x4 solid-orange tile image.
    const px = try ar.alloc(u8, 4 * 4 * 4);
    for (0..16) |i| px[i * 4 ..][0..4].* = .{ 255, 128, 0, 255 };
    var stub = StubSource{ .bytes = try png.encode(ar, px, 4, 4) };

    // The raster layer sits UNDER the fill in style order, which is the
    // whole reason it is a layer and not a hardcoded underlay.
    const style =
        \\{"version": 8,
        \\ "sources": {"photo": {"type": "raster", "tiles": ["x/{z}/{x}/{y}"], "maxzoom": 14}},
        \\ "layers": [
        \\   {"id": "bg", "type": "background", "paint": {"background-color": "#000000"}},
        \\   {"id": "picture", "type": "raster", "source": "photo"}]}
    ;
    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(style);
    _ = try m.bindSource("photo", .{
        .ptr = &stub,
        .fetch = StubSource.fetch,
        .kind = .raster,
        .maxzoom = 14,
    });
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    const b = m.scene() orelse return error.NoScene;
    try testing.expect(b.ranges.len > 0);
    var raster_ranges: usize = 0;
    for (b.ranges) |r| {
        if (r.kind != .raster) continue;
        raster_ranges += 1;
        try testing.expectEqual(types.Prim.quads, r.prim);
        try testing.expectEqual(@as(u32, 6), r.count);
        // Each tile brings its OWN image; no atlas has to be resident.
        try testing.expect(r.pattern != types.NO_PATTERN);
        try testing.expect(r.pattern < b.patterns.len);
        try testing.expectEqual(types.Atlas.none, r.atlas);
    }
    try testing.expect(raster_ranges >= 4);
    try testing.expectEqual(raster_ranges, b.patterns.len);
    try testing.expectEqual(@as(u32, 4), b.patterns[0].w);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, b.patterns[0].rgba[0..4]);

    // A raster quad scales WITH the map: no screen-space offsets at all.
    for (b.quads) |q| try testing.expectEqual(@as(f32, 0), q.ox);

    // And the batcher turns them into raster draws without any atlas.
    const batch = @import("scene/batch.zig");
    var draws: [64]types.Draw = undefined;
    const n = batch.batch(b.ranges, .{ .atlas_have = 0, .halo = .{ 0, 0, 0, 1 } }, &draws);
    try testing.expect(n > 0);
    var saw_raster = false;
    for (draws[0..@min(n, draws.len)]) |d| {
        if (d.pipeline == .raster) saw_raster = true;
    }
    try testing.expect(saw_raster);
}

test "Map: the wanted set wraps at the antimeridian" {
    const a = testing.allocator;
    var m = Map.init(a, .{ .cache = .{ .workers = 1 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    var stub = StubSource{ .bytes = &.{} };
    _ = try m.bindSource("chart", stub.source(4));
    m.setViewport(512, 512);
    m.setView(179.9, 0, 4);

    var keys: std.ArrayListUnmanaged(u64) = .empty;
    defer keys.deinit(a);
    try m.visibleTiles(&keys);
    try testing.expect(keys.items.len > 0);
    // Every column is a real tile index at z4, both sides of the seam.
    var saw_low = false;
    var saw_high = false;
    for (keys.items) |k| {
        const key: caches.Key = @bitCast(k);
        try testing.expect(key.x < 16);
        try testing.expect(key.y < 16);
        if (key.x == 0) saw_low = true;
        if (key.x == 15) saw_high = true;
    }
    try testing.expect(saw_low and saw_high);
}

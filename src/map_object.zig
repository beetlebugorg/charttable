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

/// How many updates after the host's last camera input the map still counts
/// as mid-gesture. Long enough to bridge the gaps between pinch events (at
/// 60 Hz this is a quarter second), short enough that letting go feels
/// immediate. A slower host holds proportionally longer in wall-clock terms,
/// which is what a slower host wants.
pub const GESTURE_HOLD: u32 = 15;

pub const Options = struct {
    cache: caches.Options = .{},
    overscan: f64 = OVERSCAN,
    zoom_rebuild: f64 = ZOOM_REBUILD,
    /// The build zoom's quantum: the rebuild trigger and the bucket key.
    zoom_quantum: f64 = 0.25,
    /// How many tiles one rebuild may TESSELLATE. Cached buckets are free
    /// and do not count, so this bounds only new work.
    ///
    /// A whole viewport of misses -- what landing a four-level pinch
    /// produces -- is one long frame if it is done at once.
    ///
    /// Swept on the real chart library (paced pinch, z12->z16, worst frame
    /// in ms over 3-4 runs each):
    ///
    ///     budget    1        2        3        4     unbounded
    ///     worst   33-36    37-41    40-56    61-63    60-122
    ///     total  298-318  214-286  197-305  205-247  227-335
    ///
    /// Lower is not simply better: the global symbol pass is rebuilt every
    /// pass whatever the budget, so budget 1 pays it most often and turns a
    /// short stall into a steady 9-12 ms p95. 2 takes nearly all of the peak
    /// reduction without that. Set it very high to restore all-at-once.
    tiles_per_build: usize = 2,
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

/// Everything a drawn frame depended on: the camera AND which scene it drew.
/// Both have to be here. Watching only the camera misses the case that
/// actually matters during load — a tile lands, `update` rebuilds, and the
/// camera has not moved, so a host that draws on damage never draws the new
/// scene and the map stops half-loaded.
const DrawnView = struct {
    center: cameras.Vec2,
    zoom: f64,
    rotation: f64,
    vw: f32,
    vh: f32,
    scene_generation: u64,
    paint_generation: u64,

    fn of(m: *const Map) DrawnView {
        const c = m.cam;
        return .{
            .center = c.center,
            .zoom = c.zoom,
            .rotation = c.rotation,
            .vw = c.vw,
            .vh = c.vh,
            .scene_generation = m.scene_generation,
            .paint_generation = m.paint_generation,
        };
    }

    fn eql(a: DrawnView, b: DrawnView) bool {
        return a.center.x == b.center.x and a.center.y == b.center.y and
            a.zoom == b.zoom and a.rotation == b.rotation and
            a.vw == b.vw and a.vh == b.vh and
            a.scene_generation == b.scene_generation and
            a.paint_generation == b.paint_generation;
    }
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
    /// The physical size multiplier for symbols, text and line widths — what
    /// tile57's style Options calls size_scale: "the host's _featureSizeScale
    /// from its calibrated CSS-pixel pitch". The sprite is rasterized at the
    /// catalogue's own px-per-mm, so a host that wants S-52's PHYSICAL sizes
    /// on ITS display has to say so; 1.0 draws the sprite cells verbatim.
    ///
    /// It rides the uniform, so changing it costs a frame, not a rebuild.
    /// The collision pass runs at layout in unscaled px, so a large scale
    /// packs symbols tighter than the collider assumed — the chart layers
    /// that matter set icon-allow-overlap, and a placement pass that knows
    /// the scale is later work.
    size_scale: f32 = 1.0,

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

    /// Tiles being fetched ahead of a rebuild, for the zoom the camera is
    /// heading to. Never drawn from directly -- `wanted` is what the scene
    /// is built from -- but held against eviction just the same.
    ahead: std.ArrayListUnmanaged(u64) = .empty,

    /// The last rebuild ran out of tessellation budget and left tiles out of
    /// the scene. Not an error state: the next update picks them up.
    partial: bool = false,
    /// How many tiles' geometry the live scene actually holds.
    scene_tiles: usize = 0,
    /// Whether the LIVE scene went on screen with tiles missing. Only ever
    /// true when there was nothing better to show; a covering scene is never
    /// replaced by an incomplete one.
    scene_partial: bool = false,

    /// Updates since the host last moved the camera.
    ///
    /// A pinch is a rapid burst of INSTANT zooms, not an eased one, so
    /// `cam.animating()` is false throughout and every quantum crossing
    /// would rebuild. This is what makes a pinch behave like the eased path:
    /// hold the layout while the fingers move, catch up when they rest.
    ///
    /// Counted in UPDATES, not seconds. charttable reads no clock, and
    /// timing this off the dt a host passes would hold the layout forever
    /// for a host that moves the camera and renders without ever ticking.
    /// Every host calls update, so every host ages the window.
    updates_since_input: u32 = std.math.maxInt(u32),

    /// What the last drawn frame depended on. A pan or zoom inside the built
    /// coverage rebuilds nothing and is still damage (the matrix changed);
    /// so is a rebuild the camera did not cause. Without this, honest damage
    /// tracking reports "nothing to do" and the view freezes -- mid-gesture,
    /// or worse, half-loaded.
    drawn: ?DrawnView = null,

    /// Tiles the last build used, so a tick can tell a tile LANDING from a
    /// mere camera move.
    resident: std.ArrayListUnmanaged(u64) = .empty,
    /// Cached per-tile geometry, keyed by cache key. Each entry owns its
    /// arena and remembers the style generation it was built for.
    buckets: std.AutoHashMapUnmanaged(u64, Bucket) = .empty,

    /// The build in flight, if any. `building` is owner-only; `build_done`
    /// is how the worker says it is finished.
    building: bool = false,
    build_thread: ?std.Thread = null,
    build_done: std.atomic.Value(bool) = .init(false),
    build_have: std.ArrayListUnmanaged(u64) = .empty,
    build_style: ?*const styles.Style = null,
    build_in: BuildInputs = .{ .origin = .{ .x = 0, .y = 0 }, .zoom = 0, .budget = 0, .blank = true },
    staged: Staged = .{},

    /// Compiled property programs, shared by every build. Reset lazily when
    /// the style generation moves rather than at each mutation site, so no
    /// future setter can forget to invalidate it.
    progs: map.ProgCache,
    progs_generation: u64 = 0,
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
            .progs = map.ProgCache.init(gpa),
        };
    }

    /// The program cache, emptied if the style has changed since it was
    /// filled. Every build goes through here.
    fn progCache(self: *Map) *map.ProgCache {
        if (self.progs_generation != self.style_generation) {
            self.progs.reset();
            self.progs_generation = self.style_generation;
        }
        return &self.progs;
    }

    pub fn deinit(self: *Map) void {
        self.waitForBuild();
        self.build_have.deinit(self.gpa);
        self.ahead.deinit(self.gpa);
        self.progs.deinit(self.gpa);
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
        self.waitForBuild(); // the worker holds this style
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
        self.waitForBuild(); // the worker reads cache.sources
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

    /// Bind a whole pmtiles LIBRARY to a style source name: many archives,
    /// one source, finest cell first. The library and its readers must
    /// outlive the Map.
    pub fn bindPmtilesLibrary(self: *Map, name: []const u8, lib: *caches.PmtilesLibrary) !usize {
        var src = lib.source();
        if (self.style) |*s| {
            if (s.sources.get(name)) |ssrc| switch (ssrc) {
                .vector => |v| {
                    if (v.encoding) |e| src.encoding = caches.Encoding.parse(e);
                    src.maxzoom = @min(src.maxzoom, @as(u8, @intFromFloat(std.math.clamp(v.maxzoom, 0, 22))));
                },
                .raster => |r| src.maxzoom = @min(src.maxzoom, @as(u8, @intFromFloat(std.math.clamp(r.maxzoom, 0, 22)))),
            };
        }
        return self.bindSource(name, src);
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
        self.waitForBuild();
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
        self.waitForBuild();
        const style = if (self.style) |*s| s else return error.NoStyle;
        try style.setFilter(layer_id, json_filter);
        self.style_generation += 1;
        self.dirty = true;
    }

    pub fn setLayerVisibility(self: *Map, layer_id: []const u8, on: bool) !void {
        self.waitForBuild();
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
                    p.tile_size = @intFromFloat(std.math.clamp(r.tile_size, 64, 4096));
                },
            };
        }
        return self.bindSource(name, p.source());
    }

    /// Symbol assets. Changing them re-lays-out (an icon that was missing may
    /// now resolve), so this bumps the style generation.
    pub fn setAssets(self: *Map, assets: Assets) void {
        self.waitForBuild(); // the worker reads the atlases
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
        // Inside the band, like every other way of moving the camera. The
        // gesture paths clamp in the camera itself; this one assigns.
        self.cam.zoom = std.math.clamp(zoom, self.cam.min_zoom, self.cam.max_zoom);
        self.cam.setTarget();
        self.cam.clampY();
    }

    /// Set the physical size multiplier. Uniform-only: no rebuild.
    pub fn setSizeScale(self: *Map, scale: f32) void {
        self.waitForBuild();
        if (!(scale > 0) or scale == self.size_scale) return;
        self.size_scale = scale;
        // Symbol placement is measured in DRAWN px, so a new scale changes
        // which labels win: this is a layout change, not a uniform tweak.
        self.style_generation += 1;
        self.dirty = true;
        self.drawn = null;
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
        if (self.updates_since_input < std.math.maxInt(u32)) self.updates_since_input += 1;

        // A build in flight owns the tile cache, the bucket cache, the style
        // and the assets for its duration. cache.tick() adopts decoded tiles
        // AND evicts, both of which free memory the worker is reading, so
        // this frame does nothing but wait -- and draw the scene already up,
        // which the worker never touches.
        if (self.building) {
            if (!self.build_done.load(.acquire)) return tick;
            try self.finishBuild();
            tick.rebuilt = true;
            return tick;
        }

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

        // Fetch what the camera is zooming TOWARD, before the rebuild that
        // will need it.
        //
        // `wanted` is only re-chosen when a rebuild is due, and a rebuild is
        // deliberately deferred for the length of a gesture -- so nothing
        // asked for the new level's tiles until the gesture was already
        // over, and only then did the fetch, the host's compose and the
        // decode begin. That wait is the whole reason a zoom sits on a stale
        // or half-empty scene: not the tessellation, the supply.
        //
        // This asks early and changes nothing about what is drawn. The set
        // is not adopted, the scene is not rebuilt; the tiles are merely on
        // their way, so the rebuild that follows finds them already there.
        if (!coverage_broke and self.buildZoom() != self.cov_zoom) {
            self.ahead.clearRetainingCapacity();
            try self.visibleTiles(&self.ahead);
            for (self.ahead.items) |k| _ = self.cache.want(@bitCast(k));
        } else self.ahead.clearRetainingCapacity();

        tick.pending = self.pendingWanted();

        // Which of those are actually here. A tile that came back empty or
        // failed is ANSWERED but has no geometry, so it is simply absent from
        // the build; only a tile LANDING changes this list.
        var have: std.ArrayListUnmanaged(u64) = .empty;
        defer have.deinit(self.gpa);
        for (self.wanted.items) |k| {
            if (self.cache.isResident(@bitCast(k))) try have.append(self.gpa, k);
        }

        // A partial scene rebuilds even when nothing else changed -- that is
        // the budget's next batch -- but against the SAME wanted set, which
        // `coverage_broke` being false leaves untouched.
        if (!coverage_broke and !self.partial and self.sameResident(have.items)) {
            tick.paint_refilled = self.refillPaintIfMoved(&style);
            return tick;
        }

        // Build only when the whole tile set is in hand.
        //
        // Rebuilding through a gesture is what keeps the chart sharp, but
        // the tiles for a new level arrive over many frames, and adopting a
        // scene at each arrival shows the chart assembling itself: a few
        // tiles, then more, then more. That is the flicker. Waiting for a
        // complete set means one swap per level instead of a dozen, and the
        // scene already on screen keeps projecting correctly meanwhile.
        //
        // A tile that came back empty or failed is ANSWERED and is not
        // pending, so a view over open water is never held back.
        if (self.built != null and self.pendingWanted() > 0) return tick;

        // &self.style.?, NOT &style: the local is a COPY of the optional's
        // payload living on update's stack, and a worker outlives the frame
        // that started it.
        try self.startBuild(&self.style.?, have.items);
        tick.rebuilt = !self.building; // an inline fallback build is already done
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
    /// Whether the scene already built still reaches every screen edge.
    /// A scene that does can keep being drawn: a camera move inside its box
    /// is a matrix change, not a layout change.
    fn coverageHolds(self: *const Map) bool {
        if (!self.has_coverage) return false;
        const he = self.cam.halfExtents();
        return @abs(cameras.wrapDx(self.cam.center.x, self.cov_origin.x)) + he.x <= self.cov_hw and
            @abs(self.cam.center.y - self.cov_origin.y) + he.y <= self.cov_hh;
    }

    pub fn needsRebuild(self: *Map) bool {
        if (self.style == null) return false;
        if (!self.has_coverage) return true;
        // The build zoom is quantized, so this fires when the quantum
        // changes -- which is exactly when the cached geometry is stale.
        //
        // But NOT mid-gesture. A zoom is a matrix change: the scene still
        // projects correctly the whole way, and only its layout-time detail
        // (dash periods, symbol spacing, which features the zoom filters
        // admit) drifts. Rebuilding at every quantum of an eased pinch
        // spends the gesture re-tessellating scenes nobody looks at for more
        // than a frame. Let the camera land, then rebuild once. Leaving the
        // coverage box is different -- that shows blank edges, and is
        // handled above, before this.
        const drift = @abs(self.buildZoom() - self.cov_zoom);

        // Leaving the coverage box shows blank edges, so it normally forces
        // a rebuild at once -- but WHY the view left it decides whether that
        // is affordable.
        //
        // A pan leaves it at an unchanged build zoom, where every bucket is
        // still valid and the rebuild is a concatenation. Do it immediately.
        //
        // A zoom-out leaves it by growing, and there every bucket is stale
        // at once. Rebuilding per frame through a gesture re-tessellates a
        // fresh set at every quantum and throws each one away when the next
        // arrives -- measured at 3.2 s of frame time and a 272 ms worst
        // frame across a four-level zoom-out. So a zoom waits for the same
        // one-level staleness budget as everything else, while the tiles it
        // will need are already being fetched (see `ahead` in update).
        if (!self.coverageHolds() and (drift == 0 or !self.gesturing())) return true;

        // Deliberately NO special case for "mid-gesture" any more.
        //
        // While the build ran on the owner thread, rebuilding through a
        // gesture meant re-tessellating scenes nobody looked at for more
        // than a frame, so the scene was held and allowed to drift a whole
        // zoom level. That is what makes lines and symbols look jagged until
        // the gesture stops: they are drawn at the detail of where the
        // camera was, scaled.
        //
        // The build is off-thread now and only one runs at a time, so a
        // rebuild during a gesture costs the frame nothing and the chart
        // sharpens as it goes.
        if (drift != 0) return true;
        // A zoom-interpolated paint pair brackets one integer zoom. Drift
        // across that boundary and the two halves no longer bracket the
        // camera, so the shader would mix the wrong pair.
        if (self.built) |b| {
            if (b.paint_hi.len > 0 and @floor(self.buildZoom()) != b.paint_zoom_floor) return true;
        }
        return false;
    }

    /// The zoom a scene is built for: QUANTIZED, and clamped to the deepest
    /// zoom any bound source serves.
    ///
    /// While the camera eases OUTWARD this is the target, not where the camera
    /// is now. A build takes longer than a quantum of a real gesture and only
    /// one runs at a time, so building for the current zoom lets the camera
    /// outrun every build and each one lands stale: the chart holds one layout
    /// the whole way and snaps when the gesture stops. Labels collide at the
    /// zoom they were laid out for, so they pile up as the view grows and only
    /// declutter at the end.
    ///
    /// Only outward, because `buildExtents` derives the ground extent from
    /// this. Outward the destination extent contains what is on screen, so the
    /// scene is safe to show at any point in the ease. Inward it is contained
    /// BY it, and showing it early leaves the margins blank.
    ///
    /// Quantized because it is the rebuild trigger AND the bucket key. A
    /// continuously varying build zoom invalidates every cached tile on
    /// every frame of a gesture; on a quantum, a rebuild only happens when
    /// the quantum changes, and that is exactly when the cached geometry
    /// really has gone stale. 1/4 of a zoom holds dash periods and line
    /// widths within 2^(1/8) = 9% of true.
    pub fn buildZoom(self: *const Map) f64 {
        // Capped by the DEEPEST source, not the shallowest. Each source
        // already picks its own tile level inside its own band (see
        // visibleTiles), so a style whose overlay stops at z8 must not pin
        // the whole map to z8 -- which is what taking the minimum did, and
        // what a real MapLibre style with a low-zoom overlay source hits
        // immediately.
        var maxz: f64 = 0;
        for (self.cache.sources.items) |s| maxz = @max(maxz, @as(f64, @floatFromInt(s.maxzoom)));
        if (self.cache.sources.items.len == 0) maxz = 24;
        const q = self.opts.zoom_quantum;
        // Lead the eased target only OUTWARD. `buildExtents` derives the
        // ground extent from this zoom, so a lead outward builds a WIDER
        // extent -- a superset of what is on screen, which is safe to show at
        // any point in the ease and is what stops the blank edges as the view
        // grows past its coverage.
        //
        // Inward, the destination extent is a SUBSET: showing it while the
        // camera is still wide leaves the margins empty. So the build tracks
        // the camera in, one quantum at a time, and the picture sharpens as it
        // goes rather than arriving all at once at the end.
        const target = self.cam.target_zoom;
        const lead = if (self.cam.animating() and target < self.cam.zoom) target else self.cam.zoom;
        const quantized = @round(lead / q) * q;
        return @min(quantized, maxz);
    }

    /// Deprecated spelling kept for callers that meant "what will the next
    /// build use".
    pub fn buildTargetZoom(self: *const Map) f64 {
        return self.buildZoom();
    }

    /// Viewport half-extents in world units AT THE BUILD ZOOM, overscanned.
    /// Taking them from the camera's current zoom while choosing tiles at the
    /// build zoom is the mismatch that made a zoom-in ask for the deep tiles
    /// covering a wide view -- hundreds of them, every one thrown away.
    fn buildExtents(self: *const Map) cameras.Vec2 {
        return self.extentsAt(self.buildZoom());
    }

    fn extentsAt(self: *const Map, zoom: f64) cameras.Vec2 {
        const wp = 512.0 * std.math.pow(f64, 2.0, zoom);
        return .{
            .x = @as(f64, self.cam.vw) * 0.5 / wp * self.opts.overscan,
            .y = @as(f64, self.cam.vh) * 0.5 / wp * self.opts.overscan,
        };
    }

    /// Is there a frame to draw? Anything pending, plus a camera that has
    /// moved since the last one reached the screen.
    pub fn needsRedraw(self: *Map) bool {
        return self.frameStale() or self.busy();
    }

    /// Work outstanding, ignoring whether the current camera has been drawn:
    /// loading, an animation, a rebuild owed.
    fn busy(self: *Map) bool {
        return self.building or self.dirty or self.partial or self.cam.animating() or
            self.needsRebuild() or self.pendingWanted() > 0;
    }

    /// True when anything the last drawn frame depended on has changed: the
    /// camera moved, the scene was rebuilt, or the paint stream was refilled.
    pub fn frameStale(self: *const Map) bool {
        const then = self.drawn orelse return true;
        return !DrawnView.of(self).eql(then);
    }

    /// The host calls this after a frame actually reaches the screen, so the
    /// next `needsRedraw` can tell a moved camera from a still one.
    pub fn markDrawn(self: *Map) void {
        self.drawn = DrawnView.of(self);
    }

    /// The zoom band the camera may move in. A chart library has a natural
    /// floor -- below it the data is a smear and every tile in the world is
    /// wanted -- and no renderer can guess it, so the host says.
    pub fn setZoomRange(self: *Map, min_zoom: f64, max_zoom: f64) void {
        self.cam.min_zoom = @min(min_zoom, max_zoom);
        self.cam.max_zoom = @max(min_zoom, max_zoom);
        const clamped = std.math.clamp(self.cam.zoom, self.cam.min_zoom, self.cam.max_zoom);
        if (clamped != self.cam.zoom) {
            self.cam.zoom = clamped;
            self.cam.setTarget();
            self.dirty = true;
        }
    }

    /// Zoom about a screen point, keeping the build target in step. Setting
    /// `zoom` alone leaves `target_zoom` behind, and the Map builds for where
    /// the camera WAS -- so zooming in would keep serving the old tiles.
    pub fn zoomAt(self: *Map, dz: f64, x_pt: f32, y_pt: f32) void {
        self.cam.zoomAbout(dz, x_pt, y_pt);
        self.cam.setTarget();
        self.updates_since_input = 0;
    }

    /// Pan by a screen delta. Goes through the Map rather than the camera so
    /// a drag counts as input for the gesture window.
    pub fn pan(self: *Map, dx_pt: f32, dy_pt: f32) void {
        self.cam.panPx(dx_pt, dy_pt);
        self.updates_since_input = 0;
    }

    /// Advance animation by `dt` seconds.
    pub fn advance(self: *Map, dt: f64) void {
        if (dt > 0) self.cam.tick(dt);
    }

    /// True while the host is still working the camera: an easing animation,
    /// or input within the last few updates.
    fn gesturing(self: *const Map) bool {
        return self.cam.animating() or self.updates_since_input < GESTURE_HOLD;
    }

    /// Ask for a zoom of `dz` about a screen point and EASE there over the
    /// next frames, holding the world point under the cursor the whole way.
    /// The build target leads the eased zoom, which is the point: a scene
    /// built for where the camera is going lands useful, one built for where
    /// it was arrives stale (lookout's buildTargetZoom note).
    pub fn zoomToward(self: *Map, dz: f64, x_pt: f32, y_pt: f32) void {
        self.cam.zoomToward(dz, x_pt, y_pt);
        self.updates_since_input = 0;
    }

    /// Start a fling at `vx`, `vy` logical px/sec; (0,0) stops one. The
    /// camera decays it in tick(), and `animating()` keeps frames coming
    /// until it settles -- no timer, no polling.
    pub fn fling(self: *Map, vx: f64, vy: f64) void {
        self.cam.flingStart(vx, vy);
        self.updates_since_input = 0;
    }

    /// Honest completeness (concerns C12: "placed", not "style loaded"). True
    /// when every tile the view asked for has an answer, the scene covers the
    /// view, and the camera has stopped moving.
    ///
    /// Deliberately NOT `!needsRedraw()`: a camera that moved but whose tiles
    /// are all resident is COMPLETE, it just owes a frame. Conflating the two
    /// makes a headless caller — or a host that only draws on damage — wait
    /// forever for a map that is already finished.
    pub fn idle(self: *Map) bool {
        return !self.busy();
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
            .size_scale = self.size_scale,
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
        // Deliberately does NOT wait for a build in flight. It uploads the
        // LIVE scene, which the worker never touches -- it writes the other
        // arena and stages its result. Waiting here handed the frame thread
        // the whole build and put the hitch straight back: 213 ms frames,
        // all of it inside this call.
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

    /// Whether `bucketFor` would return without tessellating. Same validity
    /// test as bucketFor itself, so the budget cannot be spent on a tile that
    /// was going to be a cache hit.
    fn bucketReady(self: *const Map, key: caches.Key, zoom: f64) bool {
        const b = self.buckets.getPtr(key.pack()) orelse return false;
        return b.style_generation == self.style_generation and b.zoom == zoom;
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
        var one: [1]map.SourcedTile = .{.{
            .id = key.tileId(),
            .tile = tile,
            .source = self.sourceName(key.source),
        }};
        const built = try map.buildScene(arena.allocator(), style, &one, .{
            .zoom = zoom,
            .origin = .{ .x = rect.x0, .y = rect.y0 },
            .layers = .tile_local,
            .size_scale = self.size_scale,
            .progs = self.progCache(),
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
        const zoom = self.buildZoom();
        const he = self.buildExtents();
        const hw = he.x;
        const hh = he.y;
        const cx = self.cam.center.x;
        const cy = self.cam.center.y;

        for (self.cache.sources.items, 0..) |src, si| {
            // A 256-px source is sampled a level deeper so its pixels land
            // at the same density as a 512-px one (see Source.tile_size).
            const tz: u8 = @intCast(std.math.clamp(
                @as(i64, @intFromFloat(@round(zoom))) + src.zoomOffset(),
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

    /// Start a build on a worker thread and return immediately. The caller
    /// must not touch the tile cache, the style, the assets or the bucket
    /// cache until it finishes: the worker reads all of them.
    fn startBuild(self: *Map, style: *const styles.Style, have: []const u64) !void {
        self.build_have.clearRetainingCapacity();
        try self.build_have.appendSlice(self.gpa, have);
        self.build_style = style;
        self.build_in = self.buildInputs();
        self.staged = .{};
        self.build_done.store(false, .release);
        self.building = true;
        self.build_thread = std.Thread.spawn(.{}, buildWorker, .{self}) catch {
            // No thread to be had: do it inline. Slower, never wrong.
            self.building = false;
            const st = self.buildStaged(style, self.build_have.items, self.build_in) catch
                return error.OutOfMemory;
            try self.adopt(st, self.build_have.items);
            return;
        };
    }

    fn buildWorker(self: *Map) void {
        self.staged = self.buildStaged(self.build_style.?, self.build_have.items, self.build_in) catch
            Staged{ .failed = true };
        self.build_done.store(true, .release);
    }

    /// Adopt a finished build. Owner thread.
    fn finishBuild(self: *Map) !void {
        if (self.build_thread) |t| t.join();
        self.build_thread = null;
        self.building = false;
        const st = self.staged;
        self.staged = .{};
        if (st.failed) {
            // The scene on screen stays; try again next update.
            self.dirty = true;
            return;
        }
        try self.adopt(st, self.build_have.items);
    }

    /// Whether a build is running right now. A host that would otherwise
    /// have to block on `waitForBuild` can use this to defer its work
    /// instead.
    pub fn buildInFlight(self: *const Map) bool {
        return self.building;
    }

    /// Block until any build in flight is done and adopted. Every mutator
    /// that touches what a build READS -- the style, the sources, the
    /// assets, the size scale -- calls this FIRST, because the worker holds
    /// pointers into all of them.
    pub fn waitForBuild(self: *Map) void {
        if (!self.building) return;
        self.finishBuild() catch {
            self.dirty = true;
        };
    }

    /// What a build produced, before it goes on screen. The worker fills
    /// this; the owner thread adopts it. Nothing the owner reads while
    /// drawing is written by the worker, which is what lets the build run
    /// off-thread at all.
    const Staged = struct {
        built: ?Built = null,
        arena: usize = 0,
        scene_tiles: usize = 0,
        partial: bool = false,
        /// The budget ran out and the result was not worth showing, so
        /// there is nothing to adopt -- just come back next update.
        held: bool = false,
        failed: bool = false,
        origin: cameras.Vec2 = .{ .x = 0, .y = 0 },
        zoom: f64 = 0,
    };

    /// Everything a build needs from the CAMERA, read once on the owner
    /// thread when the build is decided. The worker must not touch the
    /// camera: it moves every frame, and a build that samples it midway
    /// produces a scene whose geometry, extents and tile level disagree.
    const BuildInputs = struct {
        origin: cameras.Vec2,
        zoom: f64,
        budget: usize,
        /// Whether anything is on screen at all.
        ///
        /// This alone decides whether a scene with tiles missing may be
        /// shown: with a blank window it is the progressive fill of a cold
        /// start; with a chart already drawn it is a chart that sprouts
        /// holes for a few frames, and no rule about "covers enough" or "at
        /// least as many tiles" makes that acceptable. Both were tried; the
        /// test caught both, zooming out.
        blank: bool,
    };

    fn buildInputs(self: *const Map) BuildInputs {
        return .{
            .origin = self.cam.center,
            .zoom = self.buildZoom(),
            // The budget paces a CATCH-UP: the scene on screen is right for
            // this zoom and is filling in detail, so spreading the work costs
            // nobody anything. It must not pace a scene that is stale, and
            // there are three ways to be stale.
            //
            // Nothing up, or blank edges: the user is already looking at the
            // problem, and finishing beats pacing.
            //
            // A different build zoom is the third, and leaving it out is what
            // made zooming IN behave unlike zooming out. Zooming out grows
            // the view past the coverage box, so it takes the unbounded
            // branch and lands each level as it goes. Zooming in SHRINKS the
            // view, coverage still holds, and the paced branch gives a build
            // that needs a viewport of finer tiles a budget of two -- so it
            // defers the rest, and a deferred build is HELD rather than
            // shown. The camera then re-picks the tile set before the
            // catch-up ever converges, and the chart sits at the old level
            // until the gesture stops.
            //
            // Pacing bought a shorter worst frame when the build ran on the
            // frame thread. It runs off-thread now, so a bigger build makes
            // the next scene land later and costs the frame nothing.
            .budget = if (self.built == null or !self.coverageHolds() or
                self.buildZoom() != self.cov_zoom)
                MAX_TILES
            else
                self.opts.tiles_per_build,
            .blank = self.built == null,
        };
    }

    fn buildStaged(self: *Map, style: *const styles.Style, have: []const u64, in: BuildInputs) !Staged {
        // Build into the arena the current scene is NOT using, so the old
        // scene stays valid until the new one replaces it.
        const next = (self.live + 1) % 2;
        _ = self.arenas[next].reset(.retain_capacity);
        const a = self.arenas[next].allocator();

        const origin = in.origin;
        const zoom = in.zoom;

        // Geometry: one cached bucket per tile, rebased at concatenation.
        // Rasters ride the merged pass with the symbols — they carry
        // borrowed image memory the cache owns, so caching them per tile
        // would outlive the eviction that frees it.
        var parts: std.ArrayListUnmanaged(map.ScenePart) = .empty;
        defer parts.deinit(self.gpa);
        var vector_tiles: std.ArrayListUnmanaged(map.SourcedTile) = .empty;
        var rasters: std.ArrayListUnmanaged(map.RasterTile) = .empty;
        // How many tiles this pass may TESSELLATE. Cached buckets are free
        // and never counted; only misses spend the budget.
        //
        // Landing four zoom levels at once means every tile is a miss, and
        // doing them all in one update is the 60-110 ms hitch a pinch ends
        // on. Geometry is ~18 ms per 6 tiles against 4 ms for the global
        // pass, so spreading the misses over frames keeps each one inside a
        // frame while the uncacheable part is paid once per frame regardless.
        var budget: usize = in.budget;
        var deferred: usize = 0;
        for (have) |k| {
            const key: caches.Key = @bitCast(k);
            switch (self.cache.sourceKind(key)) {
                .vector => {
                    const tile = self.cache.get(key) orelse continue;
                    try vector_tiles.append(a, .{
                        .id = key.tileId(),
                        .tile = tile,
                        .source = self.sourceName(key.source),
                    });
                    if (!self.bucketReady(key, zoom)) {
                        if (budget == 0) {
                            deferred += 1;
                            continue;
                        }
                        budget -= 1;
                    }
                    const bucket = (try self.bucketFor(style, key, zoom)) orelse continue;
                    const rect = key.tileId().worldRect();
                    try parts.append(self.gpa, .{
                        .built = bucket.built,
                        // The nearest world copy: see the note in map.zig.
                        .dx = @floatCast(cameras.wrapDx(rect.x0, origin.x)),
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

        // A scene with tiles missing must not push a better one off the
        // screen. Doing that swaps a whole chart for a two-tile fragment
        // which then fills back in over the following frames, and that is
        // the flicker: the budget exists to spread the WORK across frames,
        // not to put half-built scenes in front of anyone. Tessellation
        // already done is held in the bucket cache, so the next update
        // resumes instead of repeating.
        if (deferred > 0 and !in.blank) {
            return .{ .held = true, .origin = origin, .zoom = zoom };
        }

        // Symbols and rasters once over every tile: collision stays global,
        // and raster images stay borrowed from the tile cache rather than
        // cached past their owner's lifetime.
        try parts.append(self.gpa, .{
            .built = try map.buildSceneWithRasters(a, style, vector_tiles.items, rasters.items, .{
                .zoom = zoom,
                .origin = origin,
                .layers = .global,
                .size_scale = self.size_scale,
                .progs = self.progCache(),
            }, self.assets),
            .dx = 0,
            .dy = 0,
        });

        return .{
            .built = try map.concatScenes(a, parts.items),
            .arena = next,
            // Tiles whose geometry is actually IN the scene: `have` less
            // whatever the budget deferred. The gap is what a test can watch
            // to catch the scene silently losing ground.
            .scene_tiles = parts.items.len - 1, // less the global pass
            .partial = deferred > 0,
            .origin = origin,
            .zoom = zoom,
        };
    }

    /// Put a staged scene on screen. Owner thread only: everything here is
    /// read by drawing.
    fn adopt(self: *Map, st: Staged, have: []const u64) !void {
        self.dirty = false;
        if (st.held) {
            self.partial = true;
            return;
        }
        self.built = st.built;
        self.live = st.arena;
        self.scene_generation += 1;
        self.paint_generation += 1;
        self.rebuilds += 1;
        self.scene_partial = st.partial;
        // Tiles left untessellated by the budget: come back next update and
        // take the next batch. Their buckets are cached now, so the work
        // already done is not repeated.
        //
        // Deliberately NOT `dirty`. Dirty means "re-choose the coverage AND
        // rebuild", so using it here made every catch-up update re-pick the
        // tile set at whatever zoom the camera had reached -- a level whose
        // tiles had not loaded -- and build a scene out of nothing. That is
        // a map that blanks whenever you zoom. `partial` means the narrower
        // thing it should: finish tessellating the set already chosen.
        self.partial = st.partial;
        self.scene_tiles = st.scene_tiles;
        self.resident.clearRetainingCapacity();
        try self.resident.appendSlice(self.gpa, have);
        self.evictBuckets(self.wanted.items);
        self.recordCoverage(st.origin, st.zoom);
    }

    /// Record what the scene just built actually covers, so needsRebuild can
    /// tell when the view has left it.
    fn recordCoverage(self: *Map, origin: cameras.Vec2, zoom: f64) void {
        // At the zoom the scene was BUILT at. A build now finishes some
        // frames after it started, and the camera has usually moved on --
        // describing its coverage with the current zoom is how the extents
        // and the tile level come apart.
        const he = self.extentsAt(zoom);
        self.cov_origin = origin;
        self.cov_zoom = zoom;
        self.cov_hw = he.x;
        self.cov_hh = he.y;
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
    // And it actually takes effect: "none" means the layer does not draw.
    try testing.expectEqual(@as(usize, 0), m.scene().?.ranges.len);

    const visible = try std.json.parseFromSliceLeaky(std.json.Value, doc.allocator(), "\"visible\"", .{});
    try m.setLayoutProperty("areas", "visibility", visible);
    try settle(&m);
    try testing.expect(m.scene().?.ranges.len > 0);

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

// A host that draws on damage must be told about damage it did not cause.
// This is the load path: tiles land, update() rebuilds, the camera never
// moved — and if needsRedraw only watched the camera, the window would sit
// there half-loaded forever.
test "Map: a rebuild the camera did not cause still asks for a frame" {
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

    // Drive the loop the way a host does: tick, and draw when told to.
    var drew: usize = 0;
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) {
        _ = try m.update();
        if (m.needsRedraw()) {
            m.markDrawn();
            drew += 1;
        }
        if (m.idle() and !m.needsRedraw()) break;
        @import("util/lock.zig").sleepMs(1);
    }
    try testing.expect(m.idle());
    try testing.expect(!m.needsRedraw());
    // It drew as tiles arrived, not once.
    try testing.expect(drew > 1);
    // And the frame it settled on is the CURRENT scene.
    try testing.expectEqual(m.scene_generation, m.drawn.?.scene_generation);

    // A camera move is damage even with nothing loading.
    m.cam.panPx(3, 0);
    try testing.expect(m.needsRedraw());
    m.markDrawn();
    try testing.expect(!m.needsRedraw());

    // So is a paint refill the camera did cause but the scene did not.
    const gen = m.paint_generation;
    m.paint_generation += 1; // stand in for a refill
    try testing.expect(m.needsRedraw());
    m.paint_generation = gen;
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

// What a continuous zoom actually costs. Prints a breakdown rather than
// asserting a time: a timing assertion on shared hardware is a flake
// generator, but the COUNTS are stable and are what the optimization is
// about — how many tiles get re-tessellated to move the camera.
test "Map: the cost of a zoom sweep" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pmtiles = @import("source/pmtiles.zig");
    const ct_build = @import("ct_build");
    const clock = @import("util/clock.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = testing.allocator;

    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    var reader = pmtiles.Reader.open(gpa, io, std.mem.span(chart_env)) catch return error.SkipZigTest;
    defer reader.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
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
    _ = try m.bindPmtiles("chart", &src);
    m.setViewport(1024, 768);
    m.setView(-76.4767, 38.9763, 12);
    try settle(&m);

    const rebuilds0 = m.rebuilds;
    const built0 = m.tiles_built;
    const reused0 = m.tiles_reused;
    const t0 = clock.wallMs();

    // The EASED path, which is what a wheel or a pinch drives: ask once,
    // then tick frames while the camera glides there. The build target is
    // the destination from the first frame, so the scene is laid out for
    // where the gesture is going -- not re-laid-out at every step of it.
    m.zoomToward(4.0, 512, 384);
    var frames: usize = 0;
    while (frames < 400 and !m.idle()) : (frames += 1) {
        m.cam.tick(1.0 / 60.0);
        _ = try m.update();
        m.markDrawn();
        @import("util/lock.zig").sleepMs(1);
    }
    const eased_ms = clock.wallMs() - t0;
    const eased_rebuilds = m.rebuilds - rebuilds0;
    const eased_built = m.tiles_built - built0;

    // Back to the start. Without this the stepped path below would begin
    // where the eased one ended and zoom PAST the source's maxzoom, where
    // buildZoom clamps and nothing rebuilds at all -- a sweep that measures
    // an idle map and flatters itself.
    m.setView(-76.4767, 38.9763, 12);
    try settle(&m);

    // And the INSTANT path for contrast: every step is its own destination,
    // so every step is a fresh build target.
    const r1 = m.rebuilds;
    const b1 = m.tiles_built;
    const t1 = clock.wallMs();
    // A live pinch: a burst of INSTANT zooms with frames between them.
    var steps: usize = 0;
    while (steps < 80) : (steps += 1) {
        m.zoomAt(0.05, 512, 384);
        _ = try m.update();
    }
    // Fingers up: the gesture window ages out and the map catches up.
    var settle_frames: usize = 0;
    while (settle_frames < 60) : (settle_frames += 1) _ = try m.update();
    try settle(&m);
    const step_ms = clock.wallMs() - t1;

    std.debug.print(
        "\nzoom z12->z16 EASED:   {d} ms, {d} rebuilds, {d} tiles tessellated ({d} frames)\n" ++
            "zoom z12->z16 STEPPED: {d} ms, {d} rebuilds, {d} tiles tessellated\n" ++
            "  buckets reused overall: {d}\n",
        .{ eased_ms, eased_rebuilds, eased_built, frames, step_ms, m.rebuilds - r1, m.tiles_built - b1, m.tiles_reused - reused0 },
    );
    try testing.expect(m.rebuilds > rebuilds0);
}

// Where a rebuild's time actually goes, split the way rebuild() splits it:
// per-tile geometry (cacheable), the global symbol + raster pass (not), and
// the concatenation. Prints; asserts nothing but that it ran.
test "Map: rebuild phase profile" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pmtiles = @import("source/pmtiles.zig");
    const ct_build = @import("ct_build");
    const clock = @import("util/clock.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = testing.allocator;

    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    var reader = pmtiles.Reader.open(gpa, io, std.mem.span(chart_env)) catch return error.SkipZigTest;
    defer reader.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var src = caches.PmtilesSource{ .reader = &reader };
    var m = Map.init(gpa, .{ .cache = .{ .workers = 3 } });
    defer m.deinit();

    // Load the real sprite sheet and glyphs when the environment has them.
    // Without assets every symbol layer is skipped, and the global pass --
    // the half of a rebuild that CANNOT be cached per tile -- profiles as
    // 0 ms, which is not a result, it is an absence.
    const sprites = @import("symbol/sprite.zig");
    const glyphs = @import("symbol/glyphs.zig");
    var sprite_store: ?sprites.Sprite = null;
    defer if (sprite_store) |*sp| sp.deinit();
    var glyph_atlas: ?glyphs.GlyphAtlas = null;
    defer if (glyph_atlas) |*ga| ga.deinit();
    var assets = map.Assets{};
    if (std.c.getenv("CHARTTABLE_TEST_SPRITE_DIR")) |sd| load_sprite: {
        const dir = std.mem.span(sd);
        const idx = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/sprite-mln.json", .{dir}), a, .limited(64 << 20)) catch break :load_sprite;
        const sheet = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/sprite-mln.png", .{dir}), a, .limited(256 << 20)) catch break :load_sprite;
        sprite_store = sprites.Sprite.load(gpa, idx, sheet) catch break :load_sprite;
        assets.sprite = &sprite_store.?;
    }
    if (std.c.getenv("CHARTTABLE_TEST_GLYPHS_DIR")) |gd| load_glyphs: {
        const dir = std.mem.span(gd);
        var ga = glyphs.GlyphAtlas.init(gpa, glyphs.default_width) catch break :load_glyphs;
        var loaded = false;
        for ([_][]const u8{ "0-255", "256-511" }) |range| {
            const pbf = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/Noto Sans Regular/{s}.pbf", .{ dir, range }), a, .limited(16 << 20)) catch continue;
            _ = ga.addRange(pbf) catch continue;
            loaded = true;
        }
        if (!loaded) {
            ga.deinit();
            break :load_glyphs;
        }
        glyph_atlas = ga;
        assets.glyph_atlas = &glyph_atlas.?;
    }
    m.setAssets(assets);

    // The symbol-enabled style only when there are atlases to draw it with:
    // the other variant has no symbol layers at all, so profiling it would
    // report the global pass as free no matter how much it costs.
    const style_name: []const u8 = if (assets.sprite != null)
        "chart-day-style-symbols.json"
    else
        "chart-day-style.json";
    const style_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/{s}", .{ ct_build.assets_dir, style_name }),
        a,
        .limited(4 * 1024 * 1024),
    );
    try m.setStyleJson(style_json);
    _ = try m.bindPmtiles("chart", &src);
    m.setViewport(1024, 768);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    const style = &m.style.?;
    const zoom = m.buildZoom();
    const origin = m.cam.center;

    // Per-tile geometry, uncached.
    var tiles: std.ArrayListUnmanaged(map.SourcedTile) = .empty;
    var geom_ms: i64 = 0;
    for (m.resident.items) |k| {
        const key: caches.Key = @bitCast(k);
        const tile = m.cache.get(key) orelse continue;
        try tiles.append(a, .{ .id = key.tileId(), .tile = tile });
        const rect = key.tileId().worldRect();
        var one: [1]map.SourcedTile = .{.{ .id = key.tileId(), .tile = tile }};
        const t = clock.wallMs();
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        _ = try map.buildScene(scratch.allocator(), style, &one, .{
            .zoom = zoom,
            .origin = .{ .x = rect.x0, .y = rect.y0 },
            .layers = .tile_local,
        }, m.assets);
        geom_ms += clock.wallMs() - t;
    }

    // The same geometry again, but with programs kept across builds -- the
    // difference is the compile bill a per-tile build used to pay per tile.
    var pc = map.ProgCache.init(gpa);
    defer pc.deinit(gpa);
    var cached_ms: i64 = 0;
    for (m.resident.items) |k| {
        const key: caches.Key = @bitCast(k);
        const tile = m.cache.get(key) orelse continue;
        const rect = key.tileId().worldRect();
        var one: [1]map.SourcedTile = .{.{ .id = key.tileId(), .tile = tile }};
        const tc = clock.wallMs();
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        _ = try map.buildScene(scratch.allocator(), style, &one, .{
            .zoom = zoom,
            .origin = .{ .x = rect.x0, .y = rect.y0 },
            .layers = .tile_local,
            .progs = &pc,
        }, m.assets);
        cached_ms += clock.wallMs() - tc;
    }

    // The global pass: symbols, their collision, and rasters.
    var t = clock.wallMs();
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        _ = try map.buildScene(scratch.allocator(), style, tiles.items, .{
            .zoom = zoom,
            .origin = origin,
            .layers = .global,
        }, m.assets);
    }
    const global_ms = clock.wallMs() - t;

    // And everything at once, for scale.
    t = clock.wallMs();
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        _ = try map.buildScene(scratch.allocator(), style, tiles.items, .{
            .zoom = zoom,
            .origin = origin,
        }, m.assets);
    }
    const whole_ms = clock.wallMs() - t;

    std.debug.print(
        "\nrebuild profile ({d} tiles @ z{d}): geometry {d} ms, {d} ms with programs " ++
            "kept, global symbol pass {d} ms, monolithic {d} ms\n",
        .{ tiles.items.len, zoom, geom_ms, cached_ms, global_ms, whole_ms },
    );
    try testing.expect(tiles.items.len > 0);
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

// Crossing a zoom quantum invalidates every bucket at once, because the
// build zoom is part of the bucket key. If the tessellation budget answers
// that by leaving tiles OUT of the scene, a zoom blanks the map -- the exact
// symptom this test exists to prevent. Tiles are always resident here (the
// stub answers instantly), so any loss of coverage is the budget's doing.
test "Map: a zoom never empties the scene" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stub = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    // maxzoom well above the start, or buildZoom clamps and the bucket key
    // never moves -- which makes this test pass without testing anything.
    _ = try m.bindSource("chart", stub.source(16));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    try testing.expect(m.scene().?.vertices.len > 0);
    try testing.expect(m.resident.items.len > 2); // or the budget never bites
    // A settled map draws every tile it holds -- the budget defers, never drops.
    try testing.expectEqual(m.resident.items.len, m.scene_tiles);

    // Vertex count is NOT the measure: zooming in puts fewer tiles on
    // screen, so a smaller scene can still be a complete one. The invariant
    // is simply that there is always something to draw -- this stub answers
    // every tile, so no frame of this zoom has an honest reason to be empty.
    //
    // Comparing against `resident` would be worthless: a rebuild that drops
    // everything empties resident too, so the two agree at zero and the
    // check passes on exactly the frame it exists to catch.
    const Check = struct {
        fn scene(map_ptr: *Map, where: []const u8) !void {
            if (map_ptr.scene().?.vertices.len == 0) {
                std.debug.print(
                    "\nblanked {s} at z{d} ({d} tiles resident)\n",
                    .{ where, map_ptr.cam.zoom, map_ptr.resident.items.len },
                );
                return error.SceneBlanked;
            }
            // Flicker: a scene that was covering the screen has been
            // replaced by one with tiles missing, so the chart drops to a
            // fragment and fills back in over the next few frames.
            if (map_ptr.scene_partial) {
                std.debug.print(
                    "\nflickered {s} at z{d}: showing {d} of {d} tiles\n",
                    .{ where, map_ptr.cam.zoom, map_ptr.scene_tiles, map_ptr.resident.items.len },
                );
                return error.ScenePartialOnScreen;
            }
        }
    };

    // Step across quantum after quantum, the way a pinch does, and look at
    // the scene the host would actually draw on each frame.
    var steps: usize = 0;
    while (steps < 20) : (steps += 1) {
        m.zoomAt(0.05, 256, 256);
        _ = try m.update();
        try Check.scene(&m, "mid-gesture");
    }

    // Fingers up. The deferred rebuild lands here, and the catch-up runs
    // over several updates -- every one of which the host draws.
    var frames: usize = 0;
    while (frames < 40) : (frames += 1) {
        _ = try m.update();
        try Check.scene(&m, "on catch-up");
        @import("util/lock.zig").sleepMs(1);
    }

    // And once it settles, the scene is whole again at the new zoom.
    try settle(&m);
    try testing.expectEqual(m.resident.items.len, m.scene_tiles);
    try testing.expect(m.scene().?.vertices.len > 0);

    // Zooming OUT is the harder direction: the view grows past the built
    // coverage box, so the scene genuinely stops reaching the screen edges
    // and the "it still covers" guard cannot apply. It must still never go
    // empty -- blank edges are the price of zooming out, a blank screen is
    // not.
    steps = 0;
    while (steps < 24) : (steps += 1) {
        m.zoomAt(-0.05, 256, 256);
        _ = try m.update();
        try Check.scene(&m, "zooming out");
        @import("util/lock.zig").sleepMs(1);
    }
    frames = 0;
    while (frames < 40) : (frames += 1) {
        _ = try m.update();
        try Check.scene(&m, "out, on catch-up");
        @import("util/lock.zig").sleepMs(1);
    }
    try settle(&m);
    try testing.expect(m.scene().?.vertices.len > 0);
}

test "Map: a layer draws only from the source it names" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // Two sources carrying the SAME source-layer name and the same geometry.
    var main_src = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };
    var other_src = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    const two_source_style =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["a/{z}/{x}/{y}"]},
        \\             "overlay": {"type": "vector", "tiles": ["b/{z}/{x}/{y}"]}},
        \\ "layers": [
        \\   {"id": "areas", "type": "fill", "source": "chart", "source-layer": "areas",
        \\    "paint": {"fill-color": "#123456"}}]}
    ;

    var one = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer one.deinit();
    try one.setStyleJson(two_source_style);
    _ = try one.bindSource("chart", main_src.source(14));
    one.setViewport(512, 512);
    one.setView(-76.4767, 38.9763, 14);
    try settle(&one);
    const alone = one.scene().?.vertices.len;
    try testing.expect(alone > 0);

    // Binding a SECOND source the layer does not name must change nothing.
    // Tiles used to be matched on source-layer alone, so both sources drew
    // the layer and the map drew the same ground twice.
    var both = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer both.deinit();
    try both.setStyleJson(two_source_style);
    _ = try both.bindSource("chart", main_src.source(14));
    _ = try both.bindSource("overlay", other_src.source(14));
    both.setViewport(512, 512);
    both.setView(-76.4767, 38.9763, 14);
    try settle(&both);
    try testing.expectEqual(alone, both.scene().?.vertices.len);
}

test "Map: a shallow source does not cap the build zoom" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var deep = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };
    var shallow = StubSource{ .bytes = try stubTileBytes(arena.allocator()) };

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(test_style);
    _ = try m.bindSource("chart", deep.source(14));
    _ = try m.bindSource("overlay", shallow.source(8));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 13);
    try settle(&m);

    // The overlay stopping at z8 must not drag the layout down with it.
    try testing.expectEqual(@as(f64, 13), m.buildZoom());

    // And each source is still asked at a level it actually has.
    var levels = [_]bool{false} ** 25;
    for (m.resident.items) |k| levels[@as(caches.Key, @bitCast(k)).tileId().z] = true;
    try testing.expect(levels[13]); // the deep source, at the build zoom
    try testing.expect(levels[8]); // the overlay, overzoomed from its own max
}

test "Map: a raster source alongside a vector one does not blank the scene" {
    const a = testing.allocator;
    const png = @import("util/png.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var vec = StubSource{ .bytes = try stubTileBytes(ar) };
    const px = try ar.alloc(u8, 4 * 4 * 4);
    for (0..16) |i| px[i * 4 ..][0..4].* = .{ 255, 128, 0, 255 };
    var img = StubSource{ .bytes = try png.encode(ar, px, 4, 4) };

    const style =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["a/{z}/{x}/{y}"]},
        \\             "photo": {"type": "raster", "tiles": ["b/{z}/{x}/{y}"], "maxzoom": 14}},
        \\ "layers": [
        \\   {"id": "picture", "type": "raster", "source": "photo"},
        \\   {"id": "areas", "type": "fill", "source": "chart", "source-layer": "areas",
        \\    "paint": {"fill-color": "#123456"}}]}
    ;

    var m = Map.init(a, .{ .cache = .{ .workers = 2 } });
    defer m.deinit();
    try m.setStyleJson(style);
    // The RASTER source bound first, which is what a real style does when
    // its basemap sits under everything.
    _ = try m.bindSource("photo", .{ .ptr = &img, .fetch = StubSource.fetch, .kind = .raster, .maxzoom = 14 });
    _ = try m.bindSource("chart", vec.source(14));
    m.setViewport(512, 512);
    m.setView(-76.4767, 38.9763, 14);
    try settle(&m);

    const b = m.scene() orelse return error.NoScene;
    var fills: usize = 0;
    var rasters: usize = 0;
    for (b.ranges) |r| {
        if (r.kind == .raster) rasters += 1 else fills += 1;
    }
    try testing.expect(rasters > 0); // the basemap
    try testing.expect(fills > 0); // and the vector layer over it
    try testing.expect(b.vertices.len > 0);
}

test "Map: the scene builds off the owner thread" {
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

    // Drive updates until one hands the work to a worker and returns with
    // the build still running. That IS the contract: update never blocks on
    // layout, so the frame it was called from can go on and draw.
    var saw_in_flight = false;
    var spins: usize = 0;
    while (spins < 2000 and !saw_in_flight) : (spins += 1) {
        _ = try m.update();
        if (m.buildInFlight()) saw_in_flight = true;
        @import("util/lock.zig").sleepMs(1);
    }
    try testing.expect(saw_in_flight);

    // A build in flight must not stop the map from drawing what it has, and
    // must not report the map as settled.
    try testing.expect(!m.idle());

    try settle(&m);
    try testing.expect(!m.buildInFlight());
    try testing.expect(m.scene().?.vertices.len > 0);

    // The camera can move while a build runs; the result still describes the
    // zoom it was STARTED at, so its coverage and its tiles agree.
    const before = m.cov_zoom;
    try testing.expectEqual(m.buildZoom(), before);
}

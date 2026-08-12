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
//! What is deliberately NOT here yet, and why it is safe to defer: per-tile
//! buckets (DESIGN.md's model). buildScene merges every visible tile into one
//! single-origin scene, so a tile set change re-tessellates all of them. That
//! is correct, just wasteful; the fix is to cache `Built` per (tile, style
//! generation) and concatenate + rebase, which needs buildScene split at the
//! rebase step. The scene contract already keeps geometry tile-local up to
//! that point.
//!
//! THREADING. Everything here runs on the owner thread. The only work that
//! leaves it is tile fetch + decode, inside source/cache.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const styles = @import("style/style.zig");
const map = @import("map.zig");
const caches = @import("source/cache.zig");
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
    rebuilds: u64 = 0,

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

        const style = self.style orelse return tick;
        if (self.cache.sources.items.len == 0) return tick;

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
            if (self.cache.get(@bitCast(k)) != null) try have.append(self.gpa, k);
        }

        if (!coverage_broke and self.sameResident(have.items)) return tick;

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

    /// True when the view has panned or zoomed out of the built coverage. The
    /// x distance WRAPS: crossing the antimeridian is a short hop, not a
    /// world-width jump.
    pub fn needsRebuild(self: *Map) bool {
        if (self.style == null) return false;
        if (!self.has_coverage) return true;
        if (@abs(self.buildTargetZoom() - self.cov_zoom) > self.opts.zoom_rebuild) return true;
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

    /// Upload the current scene into `g` if it has changed since the last
    /// call, and report whether it did. Split from drawing so a host can
    /// upload on a worker-fed frame boundary and draw whenever it likes.
    pub fn uploadIfChanged(self: *Map, g: *gpu.Gpu, uploaded: *u64) !bool {
        const b = self.built orelse return false;
        if (uploaded.* == self.scene_generation) return false;
        g.clear = .{ .r = b.background.r, .g = b.background.g, .b = b.background.b, .a = b.background.a };
        try g.uploadScene(self.gpa, .{
            .vertices = b.vertices,
            .paint = b.paint,
            .indices = b.indices,
            .quads = b.quads,
            .quad_paint = b.quad_paint,
            .ranges = b.ranges,
            .patterns = b.patterns,
        });
        uploaded.* = self.scene_generation;
        return true;
    }

    // ---- internals -----------------------------------------------------------

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

        var tiles: std.ArrayListUnmanaged(map.SourcedTile) = .empty;
        for (have) |k| {
            const key: caches.Key = @bitCast(k);
            const tile = self.cache.get(key) orelse continue;
            try tiles.append(a, .{ .id = key.tileId(), .tile = tile });
        }

        const origin = self.cam.center;
        const zoom = self.buildTargetZoom();
        self.built = try map.buildScene(a, style, tiles.items, .{
            .zoom = zoom,
            .origin = origin,
        }, self.assets);
        self.live = next;
        self.scene_generation += 1;
        self.rebuilds += 1;
        self.dirty = false;

        self.resident.clearRetainingCapacity();
        try self.resident.appendSlice(self.gpa, have);
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
    _ = try m.bindSource("chart", src.source(.mlt, 14));
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
            var uploaded: u64 = 0;
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

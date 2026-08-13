//! The tile cache: what a retained Map keeps resident, and the worker pool
//! that fills it. Decode never runs on the render thread — the Map asks for
//! a tile set, workers fetch and decode off-thread, and the Map adopts
//! finished tiles at a frame boundary (DESIGN.md, Performance invariants:
//! "a frame never allocates on the render thread").
//!
//! Shape ported from lookout-marine src/raster.zig (Layer's request queue,
//! polled workers with backoff, coarse age-bucket eviction, and the rule that
//! a request the queue refuses must leave NO trace in the cache or the tile is
//! lost for good). Polled rather than condition-waited for the reason recorded
//! there: Zig 0.16's std.Thread.Condition lives behind an Io this layer does
//! not take, and a queue that fills during a pan and empties at anchor does
//! not justify hand-rolling one per platform.
//!
//! THE PARKING RULE (lookout-maplibre concerns.md C33, and why `not_ready`
//! exists): a tile request a source cannot answer YET — an archive still
//! opening, a host resource provider that has not responded — must never be
//! remembered as "this tile is empty". maplibre-native's cache did exactly
//! that and the missing tiles stayed missing for the session. Here the slot
//! is dropped instead, so the next frame asks again.
//!
//! THREADING. The cache's slot table belongs to the OWNER thread: `want`,
//! `get`, `tick` and eviction all run there and take no lock. Workers touch
//! only the request and result queues, under `mu`. The allocator must be
//! thread-safe (workers decode into their own arenas from it).

const std = @import("std");
const Allocator = std.mem.Allocator;
const coord = @import("coord.zig");
const mvt = @import("mvt.zig");
const mlt = @import("mlt.zig");
const pmtiles = @import("pmtiles.zig");
const png = @import("../util/png.zig");
const webp = @import("../util/webp.zig");
const libpng = @import("../util/libpng.zig");
const Lock = @import("../util/lock.zig").Lock;
const sleepMs = @import("../util/lock.zig").sleepMs;

/// The spec's `encoding` hint on a vector source: "mvt" (default) or the
/// "mlt" tile57 bakes.
pub const Encoding = enum {
    mvt,
    mlt,

    pub fn parse(s: ?[]const u8) Encoding {
        const name = s orelse return .mvt;
        return if (std.mem.eql(u8, name, "mlt")) .mlt else .mvt;
    }
};

/// What a source says about one tile.
pub const Fetch = union(enum) {
    /// Decompressed tile bytes, owned by the allocator the fetch was given.
    bytes: []u8,
    /// The source genuinely has no tile here. Cacheable.
    empty,
    /// Not answerable yet — ask again. NEVER cacheable (the parking rule).
    not_ready,
    /// The source has a tile but could not produce it. Cacheable: retrying a
    /// corrupt tile every frame is a busy loop, not resilience.
    failed,
};

/// What a source's tiles decode INTO. A vector source yields a decoded
/// mvt.Tile; a raster source yields an RGBA image drawn as world-space quads
/// (lookout's rationale, raster.zig: a raster tile IS a textured quad, so it
/// needs no pipeline of its own).
pub const Kind = enum { vector, raster };

/// A place tiles come from. `fetch` runs on a WORKER thread and may block.
pub const Source = struct {
    ptr: ?*anyopaque = null,
    fetch: *const fn (ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) Fetch,
    kind: Kind = .vector,
    encoding: Encoding = .mvt,
    minzoom: u8 = 0,
    maxzoom: u8 = 22,
};

/// A decoded raster tile: RGBA8, w*h*4, owned by the slot's arena and valid
/// while the tile is resident.
pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []const u8,
};

/// What a resident slot holds.
pub const Payload = union(enum) {
    none,
    vector: *mvt.Tile,
    raster: Image,
};

/// Adapter: a pmtiles archive as a Source. `Reader.getCompressed` guards its
/// own lazy directory state, so one reader serves every worker.
pub const PmtilesSource = struct {
    reader: *pmtiles.Reader,

    fn fetch(ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) Fetch {
        const self: *PmtilesSource = @ptrCast(@alignCast(ptr.?));
        const bytes = self.reader.getTile(gpa, id.z, id.x, id.y) catch return .failed;
        return if (bytes) |b| .{ .bytes = b } else .empty;
    }

    /// The decoder the ARCHIVE declares, when it declares one. A pmtiles
    /// header names its tile type, which is more authoritative than a style
    /// that simply omits `encoding` (tile57's generated styles do).
    pub fn headerEncoding(self: *const PmtilesSource) ?Encoding {
        return switch (self.reader.header.tile_type) {
            .mlt => .mlt,
            .mvt => .mvt,
            else => null,
        };
    }

    pub fn source(self: *PmtilesSource, encoding: Encoding, maxzoom: u8) Source {
        return .{
            .ptr = self,
            .fetch = fetch,
            .kind = .vector,
            .encoding = encoding,
            .minzoom = self.reader.header.min_zoom,
            .maxzoom = @min(maxzoom, self.reader.header.max_zoom),
        };
    }

    /// The same archive read as a RASTER source: its tiles are PNG images
    /// (pmtiles TileType.png), decoded by util/png.zig.
    pub fn rasterSource(self: *PmtilesSource, maxzoom: u8) Source {
        return .{
            .ptr = self,
            .fetch = fetch,
            .kind = .raster,
            .minzoom = self.reader.header.min_zoom,
            .maxzoom = @min(maxzoom, self.reader.header.max_zoom),
        };
    }
};

/// Many pmtiles archives behind ONE source: a whole chart library, which is
/// what a plotter actually opens. `Key.source` is three bits, so a library
/// cannot be one source per archive — and should not be anyway, since the
/// style names a single source and every layer draws from it.
///
/// Two things make this cheap over thousands of archives:
///   * the reader memory-maps and decodes its directories lazily, so an
///     untouched archive costs address space and nothing else;
///   * every probe is culled by the archive's own header bounds and zoom
///     band first, so a tile asks the handful of cells that could hold it.
///
/// Ordering is FINEST FIRST (deepest max_zoom, then narrowest bounds), and
/// the first archive with the tile wins. That is a crude stand-in for real
/// multi-cell compositing: tile57 solves overlap with a baked ownership
/// partition, and without one two cells covering the same water will show
/// a seam wherever the finer one stops. Good enough to fly a library
/// around; not the answer for a chart plotter.
pub const PmtilesLibrary = struct {
    gpa: Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    kind: Kind = .vector,
    encoding: ?Encoding = null,

    pub const Entry = struct {
        reader: *pmtiles.Reader,
        min_lon_e7: i32,
        min_lat_e7: i32,
        max_lon_e7: i32,
        max_lat_e7: i32,
        min_zoom: u8,
        max_zoom: u8,
    };

    pub fn init(gpa: Allocator) PmtilesLibrary {
        return .{ .gpa = gpa };
    }

    /// The library does NOT own the readers; the caller opened them and must
    /// keep them alive and close them.
    pub fn deinit(self: *PmtilesLibrary) void {
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn add(self: *PmtilesLibrary, reader: *pmtiles.Reader) Allocator.Error!void {
        const h = reader.header;
        try self.entries.append(self.gpa, .{
            .reader = reader,
            .min_lon_e7 = h.min_lon_e7,
            .min_lat_e7 = h.min_lat_e7,
            .max_lon_e7 = h.max_lon_e7,
            .max_lat_e7 = h.max_lat_e7,
            .min_zoom = h.min_zoom,
            .max_zoom = h.max_zoom,
        });
        // Finest first: the deepest archive that covers a tile answers it.
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.max_zoom != b.max_zoom) return a.max_zoom > b.max_zoom;
                return area(a) < area(b); // a tighter cell is the larger scale
            }
            fn area(e: Entry) i64 {
                const w: i64 = @as(i64, e.max_lon_e7) - e.min_lon_e7;
                const h2: i64 = @as(i64, e.max_lat_e7) - e.min_lat_e7;
                return @max(0, w) * @max(0, h2);
            }
        }.lt);
    }

    pub fn count(self: *const PmtilesLibrary) usize {
        return self.entries.items.len;
    }

    /// The decoder every archive agrees on, from their headers. Mixed
    /// libraries fall back to mvt, which is the spec default.
    pub fn headerEncoding(self: *const PmtilesLibrary) ?Encoding {
        var seen: ?Encoding = null;
        for (self.entries.items) |e| {
            const enc: Encoding = switch (e.reader.header.tile_type) {
                .mlt => .mlt,
                .mvt => .mvt,
                else => continue,
            };
            if (seen) |s| {
                if (s != enc) return null;
            } else seen = enc;
        }
        return seen;
    }

    pub fn deepestZoom(self: *const PmtilesLibrary) u8 {
        var z: u8 = 0;
        for (self.entries.items) |e| z = @max(z, e.max_zoom);
        return z;
    }

    /// Does the archive's box overlap the tile's at all?
    fn overlaps(e: Entry, id: coord.TileId) bool {
        if (id.z < e.min_zoom or id.z > e.max_zoom) return false;
        const rect = id.worldRect();
        const nw = coord.worldToLonLat(.{ rect.x0, rect.y0 });
        const se = coord.worldToLonLat(.{ rect.x1, rect.y1 });
        const t_min_lon: i32 = @intFromFloat(@floor(nw[0] * 1e7));
        const t_max_lon: i32 = @intFromFloat(@ceil(se[0] * 1e7));
        // worldToLonLat is y-down, so the NW corner is the HIGHER latitude.
        const t_max_lat: i32 = @intFromFloat(@ceil(nw[1] * 1e7));
        const t_min_lat: i32 = @intFromFloat(@floor(se[1] * 1e7));
        return t_min_lon <= e.max_lon_e7 and t_max_lon >= e.min_lon_e7 and
            t_min_lat <= e.max_lat_e7 and t_max_lat >= e.min_lat_e7;
    }

    const Box = struct { min_lon: i32, min_lat: i32, max_lon: i32, max_lat: i32 };

    fn tileBox(id: coord.TileId) Box {
        const rect = id.worldRect();
        const nw = coord.worldToLonLat(.{ rect.x0, rect.y0 });
        const se = coord.worldToLonLat(.{ rect.x1, rect.y1 });
        // worldToLonLat is y-down, so the NW corner is the HIGHER latitude.
        return .{
            .min_lon = @intFromFloat(@floor(nw[0] * 1e7)),
            .max_lon = @intFromFloat(@ceil(se[0] * 1e7)),
            .min_lat = @intFromFloat(@floor(se[1] * 1e7)),
            .max_lat = @intFromFloat(@ceil(nw[1] * 1e7)),
        };
    }

    /// Can this archive FILL the tile — is the whole tile inside its bounds?
    /// This is the test that makes quilting work. A harbor cell holds z8
    /// tiles too, but each covers only that harbor, so letting it answer a
    /// zoomed-out tile paints one small rectangle of chart in an ocean of
    /// nothing. Only a cell that spans the tile can serve it; scale then
    /// falls out on its own, because at a coarse zoom the cells that span a
    /// tile ARE the overview charts.
    fn containsTile(e: Entry, id: coord.TileId) bool {
        if (id.z < e.min_zoom or id.z > e.max_zoom) return false;
        const t = tileBox(id);
        return t.min_lon >= e.min_lon_e7 and t.max_lon <= e.max_lon_e7 and
            t.min_lat >= e.min_lat_e7 and t.max_lat <= e.max_lat_e7;
    }

    /// Does it hold the tile's CENTER? The fallback for a tile that straddles
    /// a cell boundary and so fits inside none of them.
    fn holdsCenter(e: Entry, id: coord.TileId) bool {
        if (id.z < e.min_zoom or id.z > e.max_zoom) return false;
        const rect = id.worldRect();
        const c = coord.worldToLonLat(.{ (rect.x0 + rect.x1) * 0.5, (rect.y0 + rect.y1) * 0.5 });
        const lon: i32 = @intFromFloat(c[0] * 1e7);
        const lat: i32 = @intFromFloat(c[1] * 1e7);
        return lon >= e.min_lon_e7 and lon <= e.max_lon_e7 and
            lat >= e.min_lat_e7 and lat <= e.max_lat_e7;
    }

    const Pass = enum { fills, center, touches };

    fn admits(e: Entry, id: coord.TileId, pass: Pass) bool {
        return switch (pass) {
            .fills => containsTile(e, id),
            .center => holdsCenter(e, id) and !containsTile(e, id),
            .touches => overlaps(e, id) and !holdsCenter(e, id),
        };
    }

    /// Candidates a single tile may draw from. Far more than a real tile
    /// ever needs after the bounds filter; a library that somehow exceeds it
    /// just tries the first this many.
    const MAX_CANDIDATES = 64;

    /// How well an archive's COMPILATION SCALE suits this zoom. A cell's
    /// max_zoom is its scale: tile57 bakes native scale only, so an overview
    /// (US1) tops out around z7 and a harbor cell (US5) around z16.
    ///
    /// The right chart for a zoom is the one COMPILED for it — the smallest
    /// max_zoom that still reaches this zoom. Taking the finest available
    /// instead is what broke the zoomed-out view: a harbor cell answered a
    /// z8 tile and painted one small rectangle of chart into an empty ocean,
    /// because its data covers a fifteenth of a degree and the tile spans
    /// one and a half.
    fn scaleFit(e: Entry, z: u8) u32 {
        return @as(u32, e.max_zoom) - @as(u32, z); // admits() already gated z <= max_zoom
    }

    fn fetch(ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) Fetch {
        const self: *PmtilesLibrary = @ptrCast(@alignCast(ptr.?));
        // Cells that can FILL the tile first, then the one holding its
        // center, then anything that merely reaches it. Within a pass, the
        // chart compiled closest to this zoom wins, ties going to the
        // tighter cell.
        for ([3]Pass{ .fills, .center, .touches }) |pass| {
            var cand: [MAX_CANDIDATES]Entry = undefined;
            var n: usize = 0;
            for (self.entries.items) |e| {
                if (!admits(e, id, pass)) continue;
                cand[n] = e;
                n += 1;
                if (n == cand.len) break;
            }
            const list = cand[0..n];
            std.mem.sort(Entry, list, id.z, struct {
                fn lt(z: u8, a: Entry, b: Entry) bool {
                    const fa = scaleFit(a, z);
                    const fb = scaleFit(b, z);
                    if (fa != fb) return fa < fb;
                    return boxArea(a) < boxArea(b);
                }
            }.lt);
            for (list) |e| {
                const bytes = e.reader.getTile(gpa, id.z, id.x, id.y) catch continue;
                if (bytes) |b| {
                    if (b.len > 0) return .{ .bytes = b };
                    gpa.free(b);
                }
            }
        }
        return .empty;
    }

    fn boxArea(e: Entry) i64 {
        const w: i64 = @as(i64, e.max_lon_e7) - e.min_lon_e7;
        const h: i64 = @as(i64, e.max_lat_e7) - e.min_lat_e7;
        return @max(0, w) * @max(0, h);
    }

    pub fn source(self: *PmtilesLibrary) Source {
        return .{
            .ptr = self,
            .fetch = fetch,
            .kind = self.kind,
            .encoding = self.headerEncoding() orelse .mvt,
            .minzoom = 0,
            .maxzoom = self.deepestZoom(),
        };
    }
};

/// One cached tile, addressed by source index and tile id. 64 bits so the
/// slot table keys on a scalar.
pub const Key = packed struct(u64) {
    x: u28,
    y: u28,
    z: u5,
    source: u3,

    pub fn of(source: usize, id: coord.TileId) Key {
        return .{
            .source = @intCast(source),
            .z = @intCast(id.z),
            .x = @intCast(id.x),
            .y = @intCast(id.y),
        };
    }

    pub fn tileId(self: Key) coord.TileId {
        return .{ .z = self.z, .x = self.x, .y = self.y };
    }

    pub fn pack(self: Key) u64 {
        return @bitCast(self);
    }
};

pub const State = enum {
    /// Queued or in a worker's hands.
    loading,
    /// Decoded and resident.
    ready,
    /// The source has nothing here.
    empty,
    /// The source had bytes that would not decode.
    failed,
};

const Slot = struct {
    state: State,
    payload: Payload = .none,
    arena: ?*std.heap.ArenaAllocator = null,
    bytes: usize = 0,
    /// `tick` count at last `want`, for the eviction sweep.
    used: u64 = 0,
};

const Result = struct {
    key: u64,
    state: State,
    payload: Payload = .none,
    arena: ?*std.heap.ArenaAllocator = null,
    bytes: usize = 0,
};

pub const Options = struct {
    /// Resident decoded bytes to keep. A z14 ENC tile decodes to a few
    /// hundred KB; this holds a screenful plus a pan's worth of history.
    budget_bytes: usize = 96 * 1024 * 1024,
    /// Decode threads. Fetch blocks on I/O, so more than a couple pays.
    workers: usize = 3,
    /// Requests queued or in flight at once. A bound keeps a fast pan from
    /// queueing thousands of tiles the view has already left.
    max_inflight: usize = 64,
};

pub const Cache = struct {
    gpa: Allocator,
    opts: Options,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    /// Owner-thread only.
    slots: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    resident: usize = 0,
    ticks: u64 = 0,
    /// Bumps whenever the resident set changes, so a Map can tell "something
    /// landed" from "nothing happened" without walking the table.
    generation: u64 = 0,

    mu: Lock = .{},
    reqs: std.ArrayListUnmanaged(u64) = .empty,
    results: std.ArrayListUnmanaged(Result) = .empty,
    inflight: usize = 0,
    stop: bool = false,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,

    pub fn init(gpa: Allocator, opts: Options) Cache {
        return .{ .gpa = gpa, .opts = opts };
    }

    /// Stops the workers, then frees every resident tile. Safe with workers
    /// mid-flight: their results are drained and released.
    pub fn deinit(self: *Cache) void {
        self.mu.lock();
        self.stop = true;
        self.mu.unlock();
        for (self.threads.items) |t| t.join();
        self.threads.deinit(self.gpa);

        for (self.results.items) |r| self.freeResult(r);
        self.results.deinit(self.gpa);
        self.reqs.deinit(self.gpa);

        var it = self.slots.valueIterator();
        while (it.next()) |s| self.freeSlot(s);
        self.slots.deinit(self.gpa);
        self.sources.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeSlot(self: *Cache, s: *Slot) void {
        if (s.arena) |ar| {
            ar.deinit();
            self.gpa.destroy(ar);
        }
        if (s.payload == .vector) self.gpa.destroy(s.payload.vector);
        s.arena = null;
        s.payload = .none;
    }

    fn freeResult(self: *Cache, r: Result) void {
        if (r.arena) |ar| {
            ar.deinit();
            self.gpa.destroy(ar);
        }
        if (r.payload == .vector) self.gpa.destroy(r.payload.vector);
    }

    pub fn addSource(self: *Cache, src: Source) Allocator.Error!usize {
        const i = self.sources.items.len;
        std.debug.assert(i < 8); // Key.source is 3 bits
        try self.sources.append(self.gpa, src);
        return i;
    }

    /// Ask for a tile. Returns its state now: `.loading` covers both "just
    /// queued" and "a worker has it". A request the queue refuses leaves no
    /// slot behind, so the next frame asks again.
    pub fn want(self: *Cache, key: Key) State {
        const k = key.pack();
        if (self.slots.getPtr(k)) |s| {
            s.used = self.ticks;
            return s.state;
        }
        if (!self.enqueue(k)) return .loading;
        self.slots.put(self.gpa, k, .{ .state = .loading, .used = self.ticks }) catch {
            return .loading;
        };
        self.ensureWorkers();
        return .loading;
    }

    /// The decoded VECTOR tile, or null while it is loading, empty, failed,
    /// or a raster.
    pub fn get(self: *Cache, key: Key) ?*const mvt.Tile {
        const s = self.slots.getPtr(key.pack()) orelse return null;
        s.used = self.ticks;
        return switch (s.payload) {
            .vector => |t| t,
            else => null,
        };
    }

    /// True when the slot holds decoded content of either kind.
    pub fn isResident(self: *Cache, key: Key) bool {
        const s = self.slots.getPtr(key.pack()) orelse return false;
        s.used = self.ticks;
        return s.payload != .none;
    }

    /// What KIND of content a key's source yields, for a caller sorting
    /// resident tiles into vector and raster.
    pub fn sourceKind(self: *const Cache, key: Key) Kind {
        if (key.source >= self.sources.items.len) return .vector;
        return self.sources.items[key.source].kind;
    }

    /// The decoded RASTER image. Borrowed: valid until the tile is evicted.
    pub fn getRaster(self: *Cache, key: Key) ?Image {
        const s = self.slots.getPtr(key.pack()) orelse return null;
        s.used = self.ticks;
        return switch (s.payload) {
            .raster => |img| img,
            else => null,
        };
    }

    pub fn state(self: *const Cache, key: Key) ?State {
        const s = self.slots.getPtr(key.pack()) orelse return null;
        return s.state;
    }

    /// Tiles still loading. Zero means every tile asked for this frame has an
    /// answer — the honest half of `idle()`.
    pub fn pending(self: *const Cache) usize {
        var n: usize = 0;
        var it = self.slots.valueIterator();
        while (it.next()) |s| {
            if (s.state == .loading) n += 1;
        }
        return n;
    }

    pub fn residentBytes(self: *const Cache) usize {
        return self.resident;
    }

    /// Adopt finished tiles and evict down to budget. Owner thread, once a
    /// frame. Returns true when anything landed (the frame has new content).
    pub fn tick(self: *Cache) bool {
        self.ticks += 1;
        var landed = false;
        while (true) {
            self.mu.lock();
            const maybe = self.results.pop();
            if (maybe != null) self.inflight -|= 1;
            self.mu.unlock();
            const r = maybe orelse break;

            const s = self.slots.getPtr(r.key) orelse {
                // Evicted while in flight: drop what came back.
                self.freeResult(r);
                continue;
            };
            if (r.state == .loading) {
                // The parking rule: an unanswerable request is forgotten, not
                // remembered as empty, so the next frame asks again.
                self.freeResult(r);
                _ = self.slots.remove(r.key);
                continue;
            }
            self.freeSlot(s);
            s.state = r.state;
            s.payload = r.payload;
            s.arena = r.arena;
            s.bytes = r.bytes;
            s.used = self.ticks;
            self.resident += r.bytes;
            landed = true;
        }
        if (landed) self.generation += 1;
        self.evict();
        return landed;
    }

    /// Drop least-recently-wanted tiles until the cache is back under budget.
    /// Tiles wanted THIS tick are never dropped — evicting one would just
    /// re-request it next frame, forever.
    fn evict(self: *Cache) void {
        if (self.resident <= self.opts.budget_bytes) return;
        var freed = false;
        var age: u64 = 2;
        while (self.resident > self.opts.budget_bytes and age < 4096) : (age *= 2) {
            // Removing invalidates the iterator, so each pass takes one
            // victim and rescans. A widening age bucket beats a full sort:
            // the table holds a screenful, not a library.
            while (self.resident > self.opts.budget_bytes) {
                var victim: ?u64 = null;
                var it = self.slots.iterator();
                while (it.next()) |kv| {
                    const s = kv.value_ptr;
                    if (s.state != .ready) continue;
                    if (self.ticks -| s.used < age) continue;
                    victim = kv.key_ptr.*;
                    break;
                }
                const k = victim orelse break;
                // The whole slot goes, not just its tile: one left behind
                // would answer "empty" forever and the tile never returns.
                const kv = self.slots.fetchRemove(k) orelse break;
                var slot = kv.value;
                self.resident -|= slot.bytes;
                self.freeSlot(&slot);
                freed = true;
            }
        }
        if (freed) self.generation += 1;
    }

    /// Forget everything resident (a style change invalidates decodes only if
    /// the source list changed; this is the source-level reset).
    pub fn clear(self: *Cache) void {
        var it = self.slots.valueIterator();
        while (it.next()) |s| self.freeSlot(s);
        self.slots.clearRetainingCapacity();
        self.resident = 0;
        self.generation += 1;
    }

    fn enqueue(self: *Cache, k: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.inflight + self.reqs.items.len >= self.opts.max_inflight) return false;
        self.reqs.append(self.gpa, k) catch return false;
        return true;
    }

    fn ensureWorkers(self: *Cache) void {
        if (self.threads.items.len >= self.opts.workers) return;
        while (self.threads.items.len < self.opts.workers) {
            const t = std.Thread.spawn(.{}, workerMain, .{self}) catch |e| {
                // Without a worker no tile ever lands and the map silently
                // stays blank — say so rather than leaving an empty view to
                // explain itself.
                std.log.warn("tile cache: worker spawn failed ({t})", .{e});
                return;
            };
            self.threads.append(self.gpa, t) catch {
                self.mu.lock();
                self.stop = true;
                self.mu.unlock();
                t.join();
                return;
            };
        }
    }

    fn workerMain(self: *Cache) void {
        var idle_ms: u32 = 1;
        while (true) {
            self.mu.lock();
            if (self.stop) {
                self.mu.unlock();
                return;
            }
            const maybe = self.reqs.pop();
            if (maybe) |_| self.inflight += 1;
            self.mu.unlock();
            const k = maybe orelse {
                sleepMs(idle_ms);
                if (idle_ms < 32) idle_ms *= 2;
                continue;
            };
            idle_ms = 1;

            const res = self.load(k);
            self.mu.lock();
            const posted = if (self.results.append(self.gpa, res)) true else |_| false;
            // `tick` decrements inflight for every result it drains, so a
            // result that never got posted must decrement here instead.
            if (!posted) self.inflight -|= 1;
            self.mu.unlock();
            if (!posted) self.freeResult(res);
        }
    }

    /// Fetch + decode one tile on a worker. Everything the decode allocates
    /// lives in the tile's own arena, so adopting is a pointer move and
    /// eviction is one `arena.deinit`.
    fn load(self: *Cache, k: u64) Result {
        const key: Key = @bitCast(k);
        if (key.source >= self.sources.items.len) return .{ .key = k, .state = .failed };
        const src = self.sources.items[key.source];

        const ar = self.gpa.create(std.heap.ArenaAllocator) catch
            return .{ .key = k, .state = .failed };
        ar.* = std.heap.ArenaAllocator.init(self.gpa);
        var keep = false;
        defer if (!keep) {
            ar.deinit();
            self.gpa.destroy(ar);
        };
        const a = ar.allocator();

        const got = src.fetch(src.ptr, a, key.tileId());
        switch (got) {
            .empty => return .{ .key = k, .state = .empty },
            .failed => return .{ .key = k, .state = .failed },
            // `.loading` is how a parked request reaches `tick`, which drops
            // the slot rather than caching it.
            .not_ready => return .{ .key = k, .state = .loading },
            .bytes => {},
        }
        if (src.kind == .raster) {
            // PNG is decoded here; WebP goes to libwebp when the build has
            // it. Elevation tiles in particular are usually WebP.
            const img: png.Image = if (webp.looksLikeWebp(got.bytes)) blk: {
                const wi = webp.decode(a, got.bytes) catch
                    return .{ .key = k, .state = .failed };
                break :blk .{ .w = wi.w, .h = wi.h, .rgba = wi.rgba };
            } else if (libpng.have) blk: {
                // Measured about 1.6x our own reader on a real palette tile,
                // and it reads the shapes ours declines.
                const pi = libpng.decode(a, got.bytes) catch
                    return .{ .key = k, .state = .failed };
                break :blk .{ .w = pi.w, .h = pi.h, .rgba = pi.rgba };
            } else png.read(a, got.bytes) catch return .{ .key = k, .state = .failed };
            keep = true;
            return .{
                .key = k,
                .state = .ready,
                .payload = .{ .raster = .{ .w = img.w, .h = img.h, .rgba = img.rgba } },
                .arena = ar,
                .bytes = ar.queryCapacity(),
            };
        }

        const tile = self.gpa.create(mvt.Tile) catch
            return .{ .key = k, .state = .failed };
        var keep_tile = false;
        defer if (!keep_tile) self.gpa.destroy(tile);

        tile.* = switch (src.encoding) {
            .mvt => mvt.decode(a, got.bytes) catch return .{ .key = k, .state = .failed },
            .mlt => mlt.decode(a, got.bytes) catch return .{ .key = k, .state = .failed },
        };
        keep = true;
        keep_tile = true;
        return .{
            .key = k,
            .state = .ready,
            .payload = .{ .vector = tile },
            .arena = ar,
            .bytes = ar.queryCapacity(),
        };
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

// A source backed by a fixed table of encoded tiles, so the cache's own
// behavior is under test rather than a decoder's.
const FakeSource = struct {
    tiles: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// While set, every fetch parks instead of answering.
    park: bool = false,
    fetches: std.atomic.Value(u32) = .init(0),

    fn fetch(ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) Fetch {
        const self: *FakeSource = @ptrCast(@alignCast(ptr.?));
        _ = self.fetches.fetchAdd(1, .monotonic);
        if (self.park) return .not_ready;
        const bytes = self.tiles.get(coord.zxyToTileId(id.z, id.x, id.y)) orelse return .empty;
        return .{ .bytes = gpa.dupe(u8, bytes) catch return .failed };
    }

    fn source(self: *FakeSource) Source {
        return .{ .ptr = self, .fetch = fetch, .encoding = .mvt };
    }
};

/// The smallest MVT that decodes: one layer, no features.
fn emptyLayerTile(a: Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    // layer 3 (length-delimited): { version=15:2, name=1:name, extent=5:4096 }
    var layer: std.ArrayListUnmanaged(u8) = .empty;
    defer layer.deinit(a);
    try layer.appendSlice(a, &.{ 15 << 3 | 0, 2 }); // version = 2
    try layer.appendSlice(a, &.{ 1 << 3 | 2, @intCast(name.len) });
    try layer.appendSlice(a, name);
    try layer.appendSlice(a, &.{ 5 << 3 | 0, 0x80, 0x20 }); // extent = 4096
    try buf.appendSlice(a, &.{ 3 << 3 | 2, @intCast(layer.items.len) });
    try buf.appendSlice(a, layer.items);
    return buf.items;
}

/// Spin the owner side until `pred` holds or the budget runs out.
fn settle(cache: *Cache, pred: *const fn (*Cache) bool) bool {
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) {
        _ = cache.tick();
        if (pred(cache)) return true;
        sleepMs(1);
    }
    return false;
}

test "cache: a wanted tile decodes off-thread and lands resident" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var fake = FakeSource{};
    defer fake.tiles.deinit(a);
    const bytes = try emptyLayerTile(arena.allocator(), "areas");
    try fake.tiles.put(a, coord.zxyToTileId(3, 4, 2), bytes);

    var cache = Cache.init(a, .{ .workers = 2 });
    defer cache.deinit();
    const si = try cache.addSource(fake.source());

    const key = Key.of(si, .{ .z = 3, .x = 4, .y = 2 });
    try testing.expectEqual(State.loading, cache.want(key));
    try testing.expectEqual(@as(usize, 1), cache.pending());

    const Pred = struct {
        fn ready(c: *Cache) bool {
            return c.pending() == 0;
        }
    };
    try testing.expect(settle(&cache, Pred.ready));
    try testing.expectEqual(State.ready, cache.state(key).?);
    const tile = cache.get(key).?;
    try testing.expectEqual(@as(usize, 1), tile.layers.len);
    try testing.expectEqualStrings("areas", tile.layers[0].name);
    try testing.expect(cache.residentBytes() > 0);
    try testing.expect(cache.generation > 0);

    // A tile the source does not have caches as empty: asking again is free,
    // and never turns into a fetch.
    const gone = Key.of(si, .{ .z = 3, .x = 0, .y = 0 });
    _ = cache.want(gone);
    try testing.expect(settle(&cache, Pred.ready));
    try testing.expectEqual(State.empty, cache.state(gone).?);
    const after = fake.fetches.load(.monotonic);
    _ = cache.want(gone);
    _ = cache.tick();
    try testing.expectEqual(after, fake.fetches.load(.monotonic));
}

test "cache: a parked request is never remembered as empty" {
    const a = testing.allocator;
    var fake = FakeSource{ .park = true };
    defer fake.tiles.deinit(a);

    var cache = Cache.init(a, .{ .workers = 1 });
    defer cache.deinit();
    const si = try cache.addSource(fake.source());
    const key = Key.of(si, .{ .z = 3, .x = 4, .y = 2 });

    _ = cache.want(key);
    const Pred = struct {
        fn forgotten(c: *Cache) bool {
            return c.slots.count() == 0;
        }
    };
    // The slot is dropped, not cached: the source said "not yet".
    try testing.expect(settle(&cache, Pred.forgotten));
    try testing.expect(cache.state(key) == null);

    // So the next frame asks again — this is the whole point of the rule.
    const before = fake.fetches.load(.monotonic);
    _ = cache.want(key);
    var spins: usize = 0;
    while (spins < 500 and fake.fetches.load(.monotonic) == before) : (spins += 1) {
        _ = cache.tick();
        sleepMs(1);
    }
    try testing.expect(fake.fetches.load(.monotonic) > before);
}

test "cache: eviction drops the least recently wanted and keeps this tick's" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var fake = FakeSource{};
    defer fake.tiles.deinit(a);
    for (0..8) |i| {
        const bytes = try emptyLayerTile(arena.allocator(), "areas");
        try fake.tiles.put(a, coord.zxyToTileId(3, @intCast(i), 0), bytes);
    }

    // A budget of one byte: every tick evicts everything not wanted right now.
    var cache = Cache.init(a, .{ .workers = 2, .budget_bytes = 1 });
    defer cache.deinit();
    const si = try cache.addSource(fake.source());

    const Pred = struct {
        fn ready(c: *Cache) bool {
            return c.pending() == 0;
        }
    };
    for (0..8) |i| {
        _ = cache.want(Key.of(si, .{ .z = 3, .x = @intCast(i), .y = 0 }));
    }
    try testing.expect(settle(&cache, Pred.ready));
    // Everything landed, then aged out: the cache holds nothing over budget.
    var spins: usize = 0;
    while (spins < 100 and cache.residentBytes() > cache.opts.budget_bytes) : (spins += 1) {
        _ = cache.tick();
    }
    try testing.expect(cache.residentBytes() <= cache.opts.budget_bytes);
}

test "Key round-trips a tile id through 64 bits" {
    const id = coord.TileId{ .z = 22, .x = 1234567, .y = 7654321 };
    const k = Key.of(5, id);
    try testing.expectEqual(id.z, k.tileId().z);
    try testing.expectEqual(id.x, k.tileId().x);
    try testing.expectEqual(id.y, k.tileId().y);
    try testing.expectEqual(@as(u3, 5), k.source);
    try testing.expectEqual(@as(usize, 8), @sizeOf(Key));
}

test "Encoding follows the source's spec hint" {
    try testing.expectEqual(Encoding.mvt, Encoding.parse(null));
    try testing.expectEqual(Encoding.mvt, Encoding.parse("mvt"));
    try testing.expectEqual(Encoding.mlt, Encoding.parse("mlt"));
    try testing.expectEqual(Encoding.mvt, Encoding.parse("something else"));
}

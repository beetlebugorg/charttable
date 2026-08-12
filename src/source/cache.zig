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

/// A place tiles come from. `fetch` runs on a WORKER thread and may block.
pub const Source = struct {
    ptr: ?*anyopaque = null,
    fetch: *const fn (ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) Fetch,
    encoding: Encoding = .mvt,
    minzoom: u8 = 0,
    maxzoom: u8 = 22,
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

    pub fn source(self: *PmtilesSource, encoding: Encoding, maxzoom: u8) Source {
        return .{
            .ptr = self,
            .fetch = fetch,
            .encoding = encoding,
            .minzoom = self.reader.header.min_zoom,
            .maxzoom = @min(maxzoom, self.reader.header.max_zoom),
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
    tile: ?*mvt.Tile = null,
    arena: ?*std.heap.ArenaAllocator = null,
    bytes: usize = 0,
    /// `tick` count at last `want`, for the eviction sweep.
    used: u64 = 0,
};

const Result = struct {
    key: u64,
    state: State,
    tile: ?*mvt.Tile = null,
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
        if (s.tile) |t| self.gpa.destroy(t);
        s.arena = null;
        s.tile = null;
    }

    fn freeResult(self: *Cache, r: Result) void {
        if (r.arena) |ar| {
            ar.deinit();
            self.gpa.destroy(ar);
        }
        if (r.tile) |t| self.gpa.destroy(t);
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

    /// The decoded tile, or null while it is loading, empty or failed.
    pub fn get(self: *Cache, key: Key) ?*const mvt.Tile {
        const s = self.slots.getPtr(key.pack()) orelse return null;
        s.used = self.ticks;
        return s.tile;
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
            s.tile = r.tile;
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
            .tile = tile,
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

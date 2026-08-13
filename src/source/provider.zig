//! The host-supplied resource provider: a tile source whose answers arrive
//! asynchronously, from wherever the host gets bytes (a network stack, an
//! app bundle, a database).
//!
//! This is the other half of the cache's parking rule. A worker asking for a
//! tile the host has not answered yet gets `not_ready`, the cache drops the
//! slot rather than caching an empty, and the next frame asks again — so a
//! request that is merely SLOW never becomes a tile that is permanently
//! missing (lookout-maplibre concerns.md C33, the defect that made
//! maplibre-native lose tiles for a whole session).
//!
//! THREADING. `fetch` runs on cache workers; `drain` and `respond` run
//! wherever the host drives them. Everything below `mu` is shared between
//! them, and the host's callback is invoked OUTSIDE the lock so answering
//! from inside it is allowed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const coord = @import("coord.zig");
const caches = @import("cache.zig");
const Lock = @import("../util/lock.zig").Lock;

/// One outstanding ask, as the host sees it.
pub const Request = struct {
    id: u64,
    z: u8,
    x: u32,
    y: u32,
};

pub const Status = enum {
    /// Bytes attached.
    ok,
    /// The host genuinely has no tile there — cacheable, unlike a delay.
    empty,
    /// The host tried and failed. Cacheable: retrying a broken tile every
    /// frame is a busy loop, not resilience.
    failed,
};

pub const Provider = struct {
    gpa: Allocator,
    encoding: caches.Encoding = .mvt,
    kind: caches.Kind = .vector,
    minzoom: u8 = 0,
    maxzoom: u8 = 22,
    /// The style's `tileSize`; see caches.Source.tile_size.
    tile_size: u32 = 512,

    mu: Lock = .{},
    next_id: u64 = 1,
    /// Added to every request id this provider hands out. A host with more
    /// than one provided source answers them all through one entry point, so
    /// the ids have to be unique ACROSS providers -- numbering each from 1
    /// means source A's bytes can be delivered to source B's tile.
    id_bias: u64 = 0,
    /// Tile id -> what we know about it.
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// Request id -> tile id, so a response finds its slot.
    by_id: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Asks the host has not been told about yet.
    pending: std.ArrayListUnmanaged(Request) = .empty,

    const Entry = union(enum) {
        /// Asked, waiting. Carries the request id so a duplicate ask is not
        /// raised for the same tile.
        asked: u64,
        ready: []u8,
        empty,
        failed,
    };

    pub fn init(gpa: Allocator) Provider {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Provider) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (e.* == .ready) self.gpa.free(e.ready);
        }
        self.entries.deinit(self.gpa);
        self.by_id.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn source(self: *Provider) caches.Source {
        return .{
            .ptr = self,
            .fetch = fetch,
            .kind = self.kind,
            .encoding = self.encoding,
            .minzoom = self.minzoom,
            .maxzoom = self.maxzoom,
            .tile_size = self.tile_size,
        };
    }

    fn fetch(ptr: ?*anyopaque, gpa: Allocator, id: coord.TileId) caches.Fetch {
        const self: *Provider = @ptrCast(@alignCast(ptr.?));
        const key = coord.zxyToTileId(id.z, id.x, id.y);
        self.mu.lock();
        defer self.mu.unlock();

        const gop = self.entries.getOrPut(self.gpa, key) catch return .failed;
        if (!gop.found_existing) {
            // First ask for this tile: raise a request and park.
            const rid = self.id_bias + self.next_id;
            self.next_id += 1;
            gop.value_ptr.* = .{ .asked = rid };
            self.by_id.put(self.gpa, rid, key) catch {};
            self.pending.append(self.gpa, .{
                .id = rid,
                .z = id.z,
                .x = id.x,
                .y = id.y,
            }) catch {};
            return .not_ready;
        }
        switch (gop.value_ptr.*) {
            // Already asked and still waiting: park again, no duplicate ask.
            .asked => return .not_ready,
            .empty => {
                // Consumed: the cache remembers it now, and a later eviction
                // must be free to ask the host again.
                _ = self.entries.remove(key);
                return .empty;
            },
            .failed => {
                _ = self.entries.remove(key);
                return .failed;
            },
            .ready => |bytes| {
                defer {
                    self.gpa.free(bytes);
                    _ = self.entries.remove(key);
                }
                // Into the WORKER's arena, so the decoded tile and its source
                // bytes share one lifetime.
                const copy = gpa.dupe(u8, bytes) catch return .failed;
                return .{ .bytes = copy };
            },
        }
    }

    /// Take the asks the host has not seen. The caller owns the returned
    /// slice's memory only until the next call; copy what you keep.
    pub fn drain(self: *Provider, out: *std.ArrayListUnmanaged(Request), gpa: Allocator) void {
        self.mu.lock();
        defer self.mu.unlock();
        out.appendSlice(gpa, self.pending.items) catch return;
        self.pending.clearRetainingCapacity();
    }

    pub fn pendingCount(self: *Provider) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.pending.items.len;
    }

    /// The host's answer. `bytes` is copied. An id that is unknown (or already
    /// answered) is ignored rather than treated as an error: a host racing a
    /// close, or answering twice, must not corrupt anything.
    pub fn respond(self: *Provider, req_id: u64, bytes: []const u8, status: Status) void {
        self.mu.lock();
        defer self.mu.unlock();
        const key = self.by_id.get(req_id) orelse return;
        _ = self.by_id.remove(req_id);
        const e = self.entries.getPtr(key) orelse return;
        if (e.* != .asked) return;
        switch (status) {
            .empty => e.* = .empty,
            .failed => e.* = .failed,
            .ok => {
                const copy = self.gpa.dupe(u8, bytes) catch {
                    e.* = .failed;
                    return;
                };
                e.* = .{ .ready = copy };
            },
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "provider: a tile parks until the host answers, then decodes" {
    const a = testing.allocator;
    var p = Provider.init(a);
    defer p.deinit();
    const src = p.source();
    const id = coord.TileId{ .z = 3, .x = 4, .y = 2 };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // First ask: parked, and the host is told once.
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    try testing.expectEqual(@as(usize, 1), p.pendingCount());
    // Asking again while it is outstanding raises no second request.
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    try testing.expectEqual(@as(usize, 1), p.pendingCount());

    var reqs: std.ArrayListUnmanaged(Request) = .empty;
    defer reqs.deinit(a);
    p.drain(&reqs, a);
    try testing.expectEqual(@as(usize, 1), reqs.items.len);
    try testing.expectEqual(@as(u8, 3), reqs.items[0].z);
    try testing.expectEqual(@as(u32, 4), reqs.items[0].x);
    try testing.expectEqual(@as(usize, 0), p.pendingCount()); // drained

    p.respond(reqs.items[0].id, "tile bytes", .ok);
    const got = src.fetch(src.ptr, arena.allocator(), id);
    try testing.expect(got == .bytes);
    try testing.expectEqualStrings("tile bytes", got.bytes);

    // Consumed: a later eviction is free to ask the host again.
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    try testing.expectEqual(@as(usize, 1), p.pendingCount());
}

test "provider: empty and failed are cacheable, a delay is not" {
    const a = testing.allocator;
    var p = Provider.init(a);
    defer p.deinit();
    const src = p.source();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const gone = coord.TileId{ .z = 3, .x = 0, .y = 0 };
    try testing.expect(src.fetch(src.ptr, arena.allocator(), gone) == .not_ready);
    var reqs: std.ArrayListUnmanaged(Request) = .empty;
    defer reqs.deinit(a);
    p.drain(&reqs, a);
    p.respond(reqs.items[0].id, "", .empty);
    try testing.expect(src.fetch(src.ptr, arena.allocator(), gone) == .empty);

    const broken = coord.TileId{ .z = 3, .x = 1, .y = 0 };
    try testing.expect(src.fetch(src.ptr, arena.allocator(), broken) == .not_ready);
    reqs.clearRetainingCapacity();
    p.drain(&reqs, a);
    p.respond(reqs.items[0].id, "", .failed);
    try testing.expect(src.fetch(src.ptr, arena.allocator(), broken) == .failed);
}

test "provider: a stray or doubled response is ignored, not fatal" {
    const a = testing.allocator;
    var p = Provider.init(a);
    defer p.deinit();
    const src = p.source();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    p.respond(999, "nobody asked", .ok); // unknown id
    const id = coord.TileId{ .z = 5, .x = 1, .y = 1 };
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    var reqs: std.ArrayListUnmanaged(Request) = .empty;
    defer reqs.deinit(a);
    p.drain(&reqs, a);
    p.respond(reqs.items[0].id, "first", .ok);
    p.respond(reqs.items[0].id, "second", .ok); // already answered
    const got = src.fetch(src.ptr, arena.allocator(), id);
    try testing.expectEqualStrings("first", got.bytes);
}

test "provider: a real tile round-trips through the cache's workers" {
    const a = testing.allocator;
    var p = Provider.init(a);
    defer p.deinit();

    var cache = caches.Cache.init(a, .{ .workers = 2 });
    defer cache.deinit();
    const si = try cache.addSource(p.source());
    const key = caches.Key.of(si, .{ .z = 3, .x = 4, .y = 2 });

    // The map keeps asking; the tile stays outstanding and is NEVER cached
    // as empty, which is the entire point of the parking rule.
    var reqs: std.ArrayListUnmanaged(Request) = .empty;
    defer reqs.deinit(a);
    var spins: usize = 0;
    while (spins < 500 and reqs.items.len == 0) : (spins += 1) {
        _ = cache.want(key);
        _ = cache.tick();
        p.drain(&reqs, a);
        @import("../util/lock.zig").sleepMs(1);
    }
    try testing.expectEqual(@as(usize, 1), reqs.items.len);
    try testing.expect(cache.state(key) == null or cache.state(key).? == .loading);

    // One layer, no features — the smallest MVT that decodes.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, &.{ 3 << 3 | 2, 12 });
    try buf.appendSlice(a, &.{ 15 << 3 | 0, 2 });
    try buf.appendSlice(a, &.{ 1 << 3 | 2, 5 });
    try buf.appendSlice(a, "areas");
    try buf.appendSlice(a, &.{ 5 << 3 | 0, 0x80, 0x20 });
    p.respond(reqs.items[0].id, buf.items, .ok);

    spins = 0;
    while (spins < 1000) : (spins += 1) {
        _ = cache.want(key);
        _ = cache.tick();
        if (cache.get(key) != null) break;
        @import("../util/lock.zig").sleepMs(1);
    }
    const tile = cache.get(key) orelse return error.NeverArrived;
    try testing.expectEqual(@as(usize, 1), tile.layers.len);
    try testing.expectEqualStrings("areas", tile.layers[0].name);
}

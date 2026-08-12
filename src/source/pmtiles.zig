//! PMTiles v3 archive reader.
//! Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
//!
//! Reading side only — tile57 owns the writer this was ported from. Opens
//! from caller-supplied bytes or memory-maps a file path; it NEVER reads a
//! whole archive into memory (lookout maps 1,700-cell chart libraries —
//! open must cost pages, not megabytes). Parses root + leaf directories
//! (large archives from the Go reference shard entries into leaves) and
//! gunzips tiles/directories/metadata when the header says so.
//!
//! Hardened relative to tile57's reader for foreign archives: directory and
//! tile offsets are bounds-checked against the archive and varints against
//! their buffers, so a truncated or hostile file is error.Malformed, never
//! a crash.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const coord = @import("coord.zig");
const lock = @import("../util/lock.zig");

pub const HEADER_LEN = 127;
const MAGIC = "PMTiles";

// Non-exhaustive: a corrupt or future archive byte must parse (and then fail
// as UnsupportedCompression at use), not trap in @enumFromInt.
pub const Compression = enum(u8) { unknown = 0, none = 1, gzip = 2, brotli = 3, zstd = 4, _ };
pub const TileType = enum(u8) { unknown = 0, mvt = 1, png = 2, jpeg = 3, webp = 4, avif = 5, mlt = 6, _ };

pub const Header = struct {
    root_dir_offset: u64 = 0,
    root_dir_length: u64 = 0,
    metadata_offset: u64 = 0,
    metadata_length: u64 = 0,
    leaf_dir_offset: u64 = 0,
    leaf_dir_length: u64 = 0,
    tile_data_offset: u64 = 0,
    tile_data_length: u64 = 0,
    num_addressed_tiles: u64 = 0,
    num_tile_entries: u64 = 0,
    num_tile_contents: u64 = 0,
    clustered: u8 = 1,
    internal_compression: Compression = .none,
    tile_compression: Compression = .gzip,
    tile_type: TileType = .mvt,
    min_zoom: u8 = 0,
    max_zoom: u8 = 0,
    min_lon_e7: i32 = 0,
    min_lat_e7: i32 = 0,
    max_lon_e7: i32 = 0,
    max_lat_e7: i32 = 0,
    center_zoom: u8 = 0,
    center_lon_e7: i32 = 0,
    center_lat_e7: i32 = 0,

    pub fn parse(buf: []const u8) !Header {
        if (buf.len < HEADER_LEN) return error.ShortHeader;
        if (!std.mem.eql(u8, buf[0..7], MAGIC)) return error.BadMagic;
        if (buf[7] != 3) return error.UnsupportedVersion;
        const rd = struct {
            fn u64le(b: []const u8, o: usize) u64 {
                return std.mem.readInt(u64, b[o..][0..8], .little);
            }
            fn i32le(b: []const u8, o: usize) i32 {
                return std.mem.readInt(i32, b[o..][0..4], .little);
            }
        };
        return .{
            .root_dir_offset = rd.u64le(buf, 8),
            .root_dir_length = rd.u64le(buf, 16),
            .metadata_offset = rd.u64le(buf, 24),
            .metadata_length = rd.u64le(buf, 32),
            .leaf_dir_offset = rd.u64le(buf, 40),
            .leaf_dir_length = rd.u64le(buf, 48),
            .tile_data_offset = rd.u64le(buf, 56),
            .tile_data_length = rd.u64le(buf, 64),
            .num_addressed_tiles = rd.u64le(buf, 72),
            .num_tile_entries = rd.u64le(buf, 80),
            .num_tile_contents = rd.u64le(buf, 88),
            .clustered = buf[96],
            .internal_compression = @enumFromInt(buf[97]),
            .tile_compression = @enumFromInt(buf[98]),
            .tile_type = @enumFromInt(buf[99]),
            .min_zoom = buf[100],
            .max_zoom = buf[101],
            .min_lon_e7 = rd.i32le(buf, 102),
            .min_lat_e7 = rd.i32le(buf, 106),
            .max_lon_e7 = rd.i32le(buf, 110),
            .max_lat_e7 = rd.i32le(buf, 114),
            .center_zoom = buf[118],
            .center_lon_e7 = rd.i32le(buf, 119),
            .center_lat_e7 = rd.i32le(buf, 123),
        };
    }
};

// ---- varint ---------------------------------------------------------------

const VarReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn read(r: *VarReader) error{Malformed}!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (r.pos >= r.buf.len) return error.Malformed;
            const b = r.buf[r.pos];
            r.pos += 1;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) return result;
            if (shift == 63) return error.Malformed; // > 10 bytes: not a u64
            shift = @min(shift + 7, 63);
        }
    }
};

// ---- directory --------------------------------------------------------------

pub const Entry = struct {
    tile_id: u64,
    offset: u64,
    length: u32,
    /// Number of consecutive tile ids this entry serves; 0 marks a pointer
    /// to a leaf directory instead of tile data.
    run_length: u32,
};

/// Decode a directory: entry count, tile-id deltas, run lengths, lengths,
/// then offsets (0 = contiguous with the previous entry).
fn deserializeDir(a: Allocator, buf: []const u8) ![]Entry {
    var r = VarReader{ .buf = buf };
    const n64 = try r.read();
    // Four varints of >= 1 byte per entry: a count past len/4 is corrupt, and
    // this guard keeps a hostile count from becoming a giant allocation.
    if (n64 > buf.len / 4) return error.Malformed;
    const entries = try a.alloc(Entry, @intCast(n64));
    var last: u64 = 0;
    for (entries) |*e| {
        last +%= try r.read();
        e.tile_id = last;
    }
    for (entries) |*e| e.run_length = std.math.cast(u32, try r.read()) orelse return error.Malformed;
    for (entries) |*e| e.length = std.math.cast(u32, try r.read()) orelse return error.Malformed;
    for (entries, 0..) |*e, i| {
        const v = try r.read();
        if (v == 0) {
            // tile57's reader underflowed on a leading 0 here; reject it.
            if (i == 0) return error.Malformed;
            e.offset = entries[i - 1].offset + entries[i - 1].length;
        } else {
            e.offset = v - 1;
        }
    }
    return entries;
}

/// Largest entry whose tile_id <= tid (binary search; dir is sorted).
fn findEntry(dir: []const Entry, tid: u64) ?usize {
    var lo: usize = 0;
    var hi: usize = dir.len;
    var result: ?usize = null;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (dir[mid].tile_id <= tid) {
            result = mid;
            lo = mid + 1;
        } else hi = mid;
    }
    return result;
}

// ---- gzip -------------------------------------------------------------------

/// gzip-decompress `data`; caller owns the result. Decompress only — the
/// compress side stayed in tile57 (charttable never writes archives).
fn gunzip(gpa: Allocator, data: []const u8) ![]u8 {
    var in = std.Io.Reader.fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&in, .gzip, &window);
    return d.reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed, // truncated or corrupt gzip stream
    };
}

fn maybeDecompress(a: Allocator, data: []const u8, comp: Compression) ![]const u8 {
    return switch (comp) {
        .none => data,
        .gzip => try gunzip(a, data),
        else => error.UnsupportedCompression,
    };
}

// ---- file mapping -----------------------------------------------------------
// Port of tile57 filemap.zig. Zig std has no portable mmap: std.posix.mmap is
// POSIX-only (its flag types are `void` on Windows, so it won't compile there)
// and std.os.windows doesn't bind the file-mapping calls. Map via posix mmap
// or CreateFileMapping/MapViewOfFile — the SAME lazily paged, page-cache-
// shared view on both. The mapping outlives the file handle.

const page = std.heap.page_size_min;

const PAGE_READONLY: std.os.windows.DWORD = 0x02;
const FILE_MAP_READ: std.os.windows.DWORD = 0x0004;
extern "kernel32" fn CreateFileMappingW(
    hFile: std.os.windows.HANDLE,
    lpAttributes: ?*anyopaque,
    flProtect: std.os.windows.DWORD,
    dwMaximumSizeHigh: std.os.windows.DWORD,
    dwMaximumSizeLow: std.os.windows.DWORD,
    lpName: ?std.os.windows.LPCWSTR,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: std.os.windows.HANDLE,
    dwDesiredAccess: std.os.windows.DWORD,
    dwFileOffsetHigh: std.os.windows.DWORD,
    dwFileOffsetLow: std.os.windows.DWORD,
    dwNumberOfBytesToMap: usize,
) callconv(.winapi) ?std.os.windows.LPVOID;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: std.os.windows.LPCVOID) callconv(.winapi) std.os.windows.BOOL;

/// Map the first `len` bytes of `handle` read-only (`len` > 0). The file
/// handle may be closed once this returns — the view keeps the data alive.
fn mapReadonly(handle: std.posix.fd_t, len: usize) error{IoFailed}![]align(page) const u8 {
    if (builtin.os.tag == .windows) {
        const h = CreateFileMappingW(handle, null, PAGE_READONLY, 0, 0, null) orelse return error.IoFailed;
        defer std.os.windows.CloseHandle(h); // the mapped view keeps the section alive
        const p = MapViewOfFile(h, FILE_MAP_READ, 0, 0, 0) orelse return error.IoFailed;
        // MapViewOfFile aligns to the 64 KB allocation granularity, >= page.
        const base: [*]align(page) const u8 = @ptrCast(@alignCast(p));
        return base[0..len];
    }
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, handle, 0) catch
        return error.IoFailed;
}

fn unmap(m: []align(page) const u8) void {
    if (builtin.os.tag == .windows) {
        _ = UnmapViewOfFile(@ptrCast(m.ptr));
    } else {
        std.posix.munmap(m);
    }
}

// ---- reader -------------------------------------------------------------

pub const Reader = struct {
    bytes: []const u8,
    header: Header,
    // Decoded lazily on the first tile probe: a host opens whole libraries
    // of archives, most never touched in a session — in lookout an eager
    // root decode cost ~80MB and seconds of open time across a full ENC
    // library. Until first use the arena has no chunks at all.
    root: []Entry = &.{},
    root_done: bool = false,
    arena: std.heap.ArenaAllocator,
    // Deserialized leaf directories by leaf offset. A consumer probes a
    // reader once per (tile, pass); re-deserializing the same leaf into the
    // arena on EVERY probe grew it without bound on directory-heavy
    // archives, so each leaf is decoded once and reused. Arena-backed
    // (freed wholesale by deinit).
    leaves: std.AutoHashMapUnmanaged(u64, []Entry) = .empty,
    /// Guards the LAZY directory state above (`root`/`root_done`, `leaves`,
    /// and the arena they come from): tile workers reach one reader from
    /// several threads, and without this the first probe of a cold archive
    /// races on the hashmap and the arena. Held only across directory
    /// decode — the tile bytes it yields point into the read-only mapping,
    /// and the tile's gunzip runs unlocked.
    dir_mu: lock.Lock = .{},
    /// Set when `open` created the view; deinit releases it. `init` callers
    /// own their bytes.
    mapping: ?[]align(page) const u8 = null,

    /// Wrap caller-owned bytes (which must outlive the Reader).
    pub fn init(gpa: Allocator, bytes: []const u8) !Reader {
        const header = try Header.parse(bytes);
        return .{ .bytes = bytes, .header = header, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Open an archive from a file path, memory-mapped rather than copied —
    /// a whole chart library can be open without being resident (the page
    /// cache holds the working set). The mapping is released in deinit; the
    /// file must stay in place for the Reader's lifetime.
    pub fn open(gpa: Allocator, io: std.Io, path: []const u8) !Reader {
        var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.NotFound;
        defer f.close(io);
        const st = f.stat(io) catch return error.IoFailed;
        const len = std.math.cast(usize, st.size) orelse return error.IoFailed;
        if (len < HEADER_LEN) return error.ShortHeader;
        const map = try mapReadonly(f.handle, len);
        errdefer unmap(map);
        var r = try Reader.init(gpa, map);
        r.mapping = map;
        return r;
    }

    pub fn deinit(r: *Reader) void {
        r.arena.deinit();
        if (r.mapping) |m| unmap(m);
    }

    /// A bounds-checked view into the archive.
    fn slice(r: *const Reader, off: u64, len: u64) error{Malformed}![]const u8 {
        if (off > r.bytes.len or r.bytes.len - off < len) return error.Malformed;
        return r.bytes[@intCast(off)..][0..@intCast(len)];
    }

    // Decompress with the arena's CHILD allocator and free after decode, so
    // the arena retains only the Entry slices — an arena'd gzip output would
    // sit as dead weight in every touched reader for the life of the process.
    fn decodeDir(r: *Reader, off: u64, len: u64) ![]Entry {
        const scratch = r.arena.child_allocator;
        const comp = r.header.internal_compression;
        const raw = try maybeDecompress(scratch, try r.slice(off, len), comp);
        defer if (comp != .none) scratch.free(@constCast(raw));
        return deserializeDir(r.arena.allocator(), raw);
    }

    fn ensureRoot(r: *Reader) ![]Entry {
        if (!r.root_done) {
            r.root = try r.decodeDir(r.header.root_dir_offset, r.header.root_dir_length);
            r.root_done = true;
        }
        return r.root;
    }

    /// Raw (still tile-compressed) bytes for tile (z,x,y), or null if the
    /// archive has no such tile. The slice points into the archive.
    pub fn getCompressed(r: *Reader, z: u8, x: u32, y: u32) !?[]const u8 {
        const tid = coord.zxyToTileId(z, x, y);
        r.dir_mu.lock();
        defer r.dir_mu.unlock();
        var dir = try r.ensureRoot();
        var depth: u8 = 0;
        while (depth < 4) : (depth += 1) {
            const idx = findEntry(dir, tid) orelse return null;
            const e = dir[idx];
            if (e.run_length == 0) {
                // Leaf directory pointer — decoded once per distinct leaf, then cached.
                const a = r.arena.allocator();
                const gop = try r.leaves.getOrPut(a, e.offset);
                if (!gop.found_existing) {
                    errdefer _ = r.leaves.remove(e.offset);
                    gop.value_ptr.* = try r.decodeDir(r.header.leaf_dir_offset + e.offset, e.length);
                }
                dir = gop.value_ptr.*;
                continue;
            }
            if (tid < e.tile_id + e.run_length) {
                return try r.slice(r.header.tile_data_offset + e.offset, e.length);
            }
            return null;
        }
        return null;
    }

    /// Decompressed tile bytes (gunzipped MVT/MLT), or null. Caller owns.
    pub fn getTile(r: *Reader, gpa: Allocator, z: u8, x: u32, y: u32) !?[]u8 {
        const comp = (try r.getCompressed(z, x, y)) orelse return null;
        return switch (r.header.tile_compression) {
            .none => try gpa.dupe(u8, comp),
            .gzip => try gunzip(gpa, comp),
            else => error.UnsupportedCompression,
        };
    }

    /// The archive's metadata JSON, decompressed per the header. Caller owns
    /// (a copy even when stored uncompressed, so ownership is uniform).
    pub fn metadata(r: *const Reader, gpa: Allocator) ![]u8 {
        if (r.header.metadata_length == 0) return gpa.alloc(u8, 0);
        const raw = try r.slice(r.header.metadata_offset, r.header.metadata_length);
        return switch (r.header.internal_compression) {
            .none => try gpa.dupe(u8, raw),
            .gzip => try gunzip(gpa, raw),
            else => error.UnsupportedCompression,
        };
    }
};

// ---- tests --------------------------------------------------------------
//
// The helpers below hand-assemble fixture archives: a varint writer, the v3
// directory serialization, a header writer and a gzip compressor (ports of
// tile57's writer/gzip internals, fixture-only). None of it is pub —
// charttable never emits PMTiles; tile57 owns that.

fn testAppendVarint(list: *std.ArrayList(u8), a: Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try list.append(a, @intCast((v & 0x7F) | 0x80));
    try list.append(a, @intCast(v));
}

fn testSerializeDir(a: Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try testAppendVarint(&out, a, entries.len);
    var last: u64 = 0;
    for (entries) |e| {
        try testAppendVarint(&out, a, e.tile_id - last);
        last = e.tile_id;
    }
    for (entries) |e| try testAppendVarint(&out, a, e.run_length);
    for (entries) |e| try testAppendVarint(&out, a, e.length);
    for (entries, 0..) |e, i| {
        if (i > 0 and e.offset == entries[i - 1].offset + entries[i - 1].length) {
            try testAppendVarint(&out, a, 0);
        } else {
            try testAppendVarint(&out, a, e.offset + 1);
        }
    }
    return out.items; // arena-owned
}

fn testGzip(a: Allocator, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(a, @max(64, data.len / 2));
    defer out.deinit();
    var work: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &work, .gzip, flate.Compress.Options.default);
    try c.writer.writeAll(data);
    try c.finish();
    return try out.toOwnedSlice();
}

fn testMaybeGzip(a: Allocator, data: []const u8, comp: Compression) ![]const u8 {
    return switch (comp) {
        .none => data,
        .gzip => try testGzip(a, data),
        else => unreachable,
    };
}

fn testWriteHeader(h: Header, buf: *[HEADER_LEN]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..7], MAGIC);
    buf[7] = 3;
    const wr = struct {
        fn u64le(b: []u8, o: usize, v: u64) void {
            std.mem.writeInt(u64, b[o..][0..8], v, .little);
        }
        fn i32le(b: []u8, o: usize, v: i32) void {
            std.mem.writeInt(i32, b[o..][0..4], v, .little);
        }
    };
    wr.u64le(buf, 8, h.root_dir_offset);
    wr.u64le(buf, 16, h.root_dir_length);
    wr.u64le(buf, 24, h.metadata_offset);
    wr.u64le(buf, 32, h.metadata_length);
    wr.u64le(buf, 40, h.leaf_dir_offset);
    wr.u64le(buf, 48, h.leaf_dir_length);
    wr.u64le(buf, 56, h.tile_data_offset);
    wr.u64le(buf, 64, h.tile_data_length);
    wr.u64le(buf, 72, h.num_addressed_tiles);
    wr.u64le(buf, 80, h.num_tile_entries);
    wr.u64le(buf, 88, h.num_tile_contents);
    buf[96] = h.clustered;
    buf[97] = @intFromEnum(h.internal_compression);
    buf[98] = @intFromEnum(h.tile_compression);
    buf[99] = @intFromEnum(h.tile_type);
    buf[100] = h.min_zoom;
    buf[101] = h.max_zoom;
    wr.i32le(buf, 102, h.min_lon_e7);
    wr.i32le(buf, 106, h.min_lat_e7);
    wr.i32le(buf, 110, h.max_lon_e7);
    wr.i32le(buf, 114, h.max_lat_e7);
    buf[118] = h.center_zoom;
    wr.i32le(buf, 119, h.center_lon_e7);
    wr.i32le(buf, 123, h.center_lat_e7);
}

const TestTile = struct { z: u8, x: u32, y: u32, payload: []const u8 };

const TestOpts = struct {
    internal: Compression = .none,
    tile_comp: Compression = .none,
    leaf: bool = false,
    metadata_json: []const u8 = "{\"name\":\"fixture\"}",
};

/// Assemble a whole archive in memory. Tiles must arrive in ascending
/// Hilbert-id order; identical adjacent payloads merge into run-length
/// entries (as a clustered writer would emit them).
fn testBuildArchive(a: Allocator, tiles_in: []const TestTile, opts: TestOpts) ![]u8 {
    var data = std.ArrayList(u8).empty;
    var entries = std.ArrayList(Entry).empty;
    var min_z: u8 = 255;
    var max_z: u8 = 0;
    var prev_payload: ?[]const u8 = null;
    for (tiles_in) |t| {
        min_z = @min(min_z, t.z);
        max_z = @max(max_z, t.z);
        const tid = coord.zxyToTileId(t.z, t.x, t.y);
        if (prev_payload) |pp| {
            const prev = &entries.items[entries.items.len - 1];
            if (std.mem.eql(u8, pp, t.payload) and prev.tile_id + prev.run_length == tid) {
                prev.run_length += 1;
                continue;
            }
        }
        const comp = try testMaybeGzip(a, t.payload, opts.tile_comp);
        try entries.append(a, .{
            .tile_id = tid,
            .offset = data.items.len,
            .length = @intCast(comp.len),
            .run_length = 1,
        });
        try data.appendSlice(a, comp);
        prev_payload = t.payload;
    }

    const flat = try testSerializeDir(a, entries.items);
    var root: []const u8 = undefined;
    var leaves: []const u8 = &.{};
    if (opts.leaf) {
        leaves = try testMaybeGzip(a, flat, opts.internal);
        const root_entries = [_]Entry{.{
            .tile_id = if (entries.items.len > 0) entries.items[0].tile_id else 0,
            .offset = 0, // relative to the leaf section
            .length = @intCast(leaves.len),
            .run_length = 0, // 0 => points at a leaf directory
        }};
        root = try testMaybeGzip(a, try testSerializeDir(a, &root_entries), opts.internal);
    } else {
        root = try testMaybeGzip(a, flat, opts.internal);
    }
    const meta = try testMaybeGzip(a, opts.metadata_json, opts.internal);

    const root_off: u64 = HEADER_LEN;
    const meta_off: u64 = root_off + root.len;
    const leaf_off: u64 = meta_off + meta.len;
    const data_off: u64 = leaf_off + leaves.len;
    var hbuf: [HEADER_LEN]u8 = undefined;
    testWriteHeader(.{
        .root_dir_offset = root_off,
        .root_dir_length = root.len,
        .metadata_offset = meta_off,
        .metadata_length = meta.len,
        .leaf_dir_offset = leaf_off,
        .leaf_dir_length = leaves.len,
        .tile_data_offset = data_off,
        .tile_data_length = data.items.len,
        .internal_compression = opts.internal,
        .tile_compression = opts.tile_comp,
        .tile_type = .mvt,
        .min_zoom = if (tiles_in.len == 0) 0 else min_z,
        .max_zoom = max_z,
    }, &hbuf);

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &hbuf);
    try out.appendSlice(a, root);
    try out.appendSlice(a, meta);
    try out.appendSlice(a, leaves);
    try out.appendSlice(a, data.items);
    return out.items; // arena-owned
}

// z1 fixture tiles, ascending Hilbert id: (1,0,0)=1, (1,0,1)=2, (1,1,1)=3.
// The first two share a payload and contiguous ids, so they merge into one
// run-length-2 entry; (1,1,0)=4 is deliberately absent.
const test_tiles = [_]TestTile{
    .{ .z = 1, .x = 0, .y = 0, .payload = "tile-A" },
    .{ .z = 1, .x = 0, .y = 1, .payload = "tile-A" },
    .{ .z = 1, .x = 1, .y = 1, .payload = "tile-B" },
};

test "header parse round-trips and rejects bad magic/version" {
    const h = Header{
        .root_dir_offset = 127,
        .root_dir_length = 50,
        .tile_data_offset = 300,
        .min_zoom = 9,
        .max_zoom = 16,
        .num_addressed_tiles = 765,
        .tile_compression = .gzip,
        .internal_compression = .none,
        .tile_type = .mvt,
    };
    var buf: [HEADER_LEN]u8 = undefined;
    testWriteHeader(h, &buf);
    const back = try Header.parse(&buf);
    try std.testing.expectEqual(h.root_dir_offset, back.root_dir_offset);
    try std.testing.expectEqual(h.num_addressed_tiles, back.num_addressed_tiles);
    try std.testing.expectEqual(h.max_zoom, back.max_zoom);
    try std.testing.expectEqual(Compression.gzip, back.tile_compression);

    try std.testing.expectError(error.ShortHeader, Header.parse(buf[0..100]));
    var bad = buf;
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, Header.parse(&bad));
    bad = buf;
    bad[7] = 2;
    try std.testing.expectError(error.UnsupportedVersion, Header.parse(&bad));
}

test "tile lookup: present, absent, and run-length ranges (uncompressed)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const archive = try testBuildArchive(arena.allocator(), &test_tiles, .{});

    var r = try Reader.init(gpa, archive);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.header.min_zoom);

    // Both tiles of the run resolve to the same content; getCompressed
    // borrows from the archive, getTile copies.
    const raw = (try r.getCompressed(1, 0, 0)).?;
    try std.testing.expectEqualStrings("tile-A", raw);
    const t2 = (try r.getTile(gpa, 1, 0, 1)).?;
    defer gpa.free(t2);
    try std.testing.expectEqualStrings("tile-A", t2);
    const t3 = (try r.getTile(gpa, 1, 1, 1)).?;
    defer gpa.free(t3);
    try std.testing.expectEqualStrings("tile-B", t3);

    // Absent: past the run (tid 4), before the first entry (tid 0), and at
    // another zoom entirely.
    try std.testing.expect((try r.getTile(gpa, 1, 1, 0)) == null);
    try std.testing.expect((try r.getTile(gpa, 0, 0, 0)) == null);
    try std.testing.expect((try r.getTile(gpa, 5, 17, 3)) == null);

    // Metadata (uncompressed path) round-trips.
    const meta = try r.metadata(gpa);
    defer gpa.free(meta);
    try std.testing.expectEqualStrings("{\"name\":\"fixture\"}", meta);
}

test "gzipped tiles, directories, and metadata decode" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const archive = try testBuildArchive(arena.allocator(), &test_tiles, .{
        .internal = .gzip,
        .tile_comp = .gzip,
    });

    var r = try Reader.init(gpa, archive);
    defer r.deinit();

    // The stored bytes are gzip (magic 1f 8b); getTile gunzips them.
    const raw = (try r.getCompressed(1, 1, 1)).?;
    try std.testing.expectEqual(@as(u8, 0x1f), raw[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), raw[1]);
    const t = (try r.getTile(gpa, 1, 1, 1)).?;
    defer gpa.free(t);
    try std.testing.expectEqualStrings("tile-B", t);

    const meta = try r.metadata(gpa);
    defer gpa.free(meta);
    try std.testing.expectEqualStrings("{\"name\":\"fixture\"}", meta);
}

test "leaf directories resolve, and each leaf is decoded exactly once" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const archive = try testBuildArchive(arena.allocator(), &test_tiles, .{ .leaf = true });

    var r = try Reader.init(gpa, archive);
    defer r.deinit();
    try std.testing.expect(r.header.leaf_dir_length > 0);

    const probes = [_][3]u32{ .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 } };
    const expect_hit = [_]bool{ true, true, true, false };
    for (probes, expect_hit) |p, hit| {
        const got = try r.getCompressed(@intCast(p[0]), p[1], p[2]);
        try std.testing.expectEqual(hit, got != null);
    }
    // Repeated probes reuse the cached leaf decode — the arena must not grow
    // once every touched leaf is resident (re-deserializing a leaf per probe
    // was unbounded growth in a compositor that probes per (tile, pass)).
    const cap_before = r.arena.queryCapacity();
    for (0..100) |_| {
        for (probes) |p| _ = try r.getCompressed(@intCast(p[0]), p[1], p[2]);
    }
    try std.testing.expectEqual(cap_before, r.arena.queryCapacity());
}

test "malformed archives error instead of crashing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const archive = try testBuildArchive(a, &test_tiles, .{});

    // Garbage root directory: a huge entry count must be rejected, not
    // allocated.
    const garbled = try a.dupe(u8, archive);
    garbled[HEADER_LEN] = 0xFF;
    garbled[HEADER_LEN + 1] = 0xFF;
    garbled[HEADER_LEN + 2] = 0x7F;
    var r1 = try Reader.init(gpa, garbled);
    defer r1.deinit();
    try std.testing.expectError(error.Malformed, r1.getCompressed(1, 0, 0));

    // Archive truncated mid tile data: the directory parses but the entry
    // points past the end.
    var r2 = try Reader.init(gpa, archive[0 .. archive.len - 4]);
    defer r2.deinit();
    try std.testing.expectError(error.Malformed, r2.getCompressed(1, 1, 1));

    // Directory truncated: root length says more bytes than exist.
    var r3 = try Reader.init(gpa, archive[0..HEADER_LEN]);
    defer r3.deinit();
    try std.testing.expectError(error.Malformed, r3.getCompressed(1, 0, 0));
}

test "open() maps a real ENC archive when present (integration; skipped without chart data)" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // The M3 reference cell (DESIGN.md); machines without chart data skip.
    const path = "/Users/claude/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles";
    var r = Reader.open(gpa, io, path) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };
    defer r.deinit();

    try std.testing.expect(r.header.max_zoom >= r.header.min_zoom);
    const meta = try r.metadata(gpa);
    defer gpa.free(meta);
    try std.testing.expect(meta.len > 0 and meta[0] == '{');

    // Walk the min-zoom tile range of the header's bbox until a tile hits;
    // a baked archive must serve at least one tile there.
    const z = r.header.min_zoom;
    const nw = coord.lonLatToWorld(
        @as(f64, @floatFromInt(r.header.min_lon_e7)) / 1e7,
        @as(f64, @floatFromInt(r.header.max_lat_e7)) / 1e7,
    );
    const se = coord.lonLatToWorld(
        @as(f64, @floatFromInt(r.header.max_lon_e7)) / 1e7,
        @as(f64, @floatFromInt(r.header.min_lat_e7)) / 1e7,
    );
    const t0 = coord.fromWorld(nw, z);
    const t1 = coord.fromWorld(se, z);
    var found = false;
    var probes: usize = 0;
    var ty = t0.y;
    outer: while (ty <= t1.y) : (ty += 1) {
        var tx = t0.x;
        while (tx <= t1.x) : (tx += 1) {
            probes += 1;
            if (probes > 4096) break :outer;
            const tile_bytes = (try r.getTile(gpa, z, tx, ty)) orelse continue;
            defer gpa.free(tile_bytes);
            try std.testing.expect(tile_bytes.len > 0);
            if (r.header.tile_type == .mvt) {
                const mvt = @import("mvt.zig");
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const tile = try mvt.decode(arena.allocator(), tile_bytes);
                try std.testing.expect(tile.layers.len > 0);
            }
            found = true;
            break :outer;
        }
    }
    try std.testing.expect(found);
}

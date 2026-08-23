//! The C ABI: `include/charttable.h`, implemented.
//!
//! House rules, inherited from lookout's capi.zig because they were learned
//! the hard way there and restated in DESIGN.md:
//!   * ONE opaque handle; every entry point takes it and runs under ONE
//!     mutex, taken by `locked()` so no path can forget it.
//!   * Borrowed pointers are valid until the NEXT call of their kind. The
//!     host copies or uses them before calling again; nothing here hands out
//!     ownership.
//!   * Logical points in, pixels internal. The host declares its scale
//!     factor and may change it after open.
//!   * No wall-clock reads: the host passes elapsed time to `tick`.
//!   * Every function is null-safe on the handle, so a host that closed early
//!     gets an error code rather than a crash.
//!
//! The thread contract is DOCUMENTED AND ENFORCED, which is the whole point
//! of writing it out (concerns C12 — maplibre-native's had to be discovered):
//! all of these are safe to call from any thread, serialized by the mutex,
//! EXCEPT that `attach_surface`, `render` and `snapshot` must come from the
//! thread that owns the surface, because that is a platform requirement, not
//! ours.

const std = @import("std");
const map_object = @import("map_object.zig");
const caches = @import("source/cache.zig");
const pmtiles = @import("source/pmtiles.zig");
const providers = @import("source/provider.zig");
const sprites = @import("symbol/sprite.zig");
const glyphs = @import("symbol/glyphs.zig");
const cameras = @import("camera.zig");
const coord = @import("source/coord.zig");
const gpu = @import("gpu/gpu.zig");
const Lock = @import("util/lock.zig").Lock;
const jsondepth = @import("util/jsondepth.zig");

/// Status codes. 0 is success; everything else is negative so `if (rc)` in C
/// reads as "something went wrong".
pub const OK: c_int = 0;
pub const ERR_HANDLE: c_int = -1;
pub const ERR_ARG: c_int = -2;
pub const ERR_STYLE: c_int = -3;
pub const ERR_SOURCE: c_int = -4;
pub const ERR_SURFACE: c_int = -5;
pub const ERR_MEMORY: c_int = -6;
pub const ERR_UNSUPPORTED: c_int = -7;

// ---- input ceilings ---------------------------------------------------------
//
// The host is in this address space and can already read any byte it likes,
// so these are NOT a defence against a hostile host. They are a defence
// against the bytes the host RELAYS: a tile body, a sprite sheet or a style
// document that arrived over the network and that the host passed straight
// through. Each one bounds work that would otherwise scale with whatever a
// tile server chose to send.

/// Largest side of an image handed to charttable_add_image or
/// charttable_set_glyph_sheet. Bounds `w * h_px * 4` well inside usize, and
/// matches sprites.max_height / glyphs.max_height / png.max_dim so the C
/// entry point is no stricter than the decoders behind it.
const max_image_dim: u32 = 16384;

/// Largest body accepted for one resource answer. This is the ingest point
/// for every network tile, so it is the single place that bounds MVT decode
/// work: layer, feature, key and point counts are all bounded by the bytes
/// that encode them, and this bounds the bytes.
const max_resource_bytes: usize = 32 << 20;

/// Largest style document. A real style is tens of kilobytes; the cap is a
/// sanity ceiling, not a budget.
const max_style_bytes: usize = 16 << 20;

/// Largest JSON accepted for ONE paint or layout property value. A property
/// value is an expression, not a document.
const max_property_json_bytes: usize = 1 << 20;

pub const NativeKind = enum(c_int) {
    none = 0, // offscreen only (snapshot)
    metal_layer = 1, // CAMetalLayer*        (metal backend)
    win32_hwnd = 4, // charttable_win32_window*   (vk + d3d12 backends)
    x11_window = 5, // charttable_x11_window*     (vk backend)
    android_window = 7, // ANativeWindow*        (vk backend)
    wayland_surface = 8, // charttable_wayland_surface* (vk backend)
    d3d12_panel = 10, // no handle (d3d12 backend); see charttable_d3d12_swapchain
};

pub const Options = extern struct {
    /// Decode threads. 0 takes the default.
    workers: u32 = 0,
    /// Resident decoded-tile budget. 0 takes the default.
    cache_bytes: u64 = 0,
};

pub const View = extern struct {
    lon: f64 = 0,
    lat: f64 = 0,
    /// MapLibre convention: a 512 px world tile at z0.
    zoom: f64 = 0,
    bearing_deg: f64 = 0,
};

/// Called when the style asks for an image the sprite cannot resolve. The
/// name is borrowed for the duration of the call; the host answers by calling
/// charttable_add_image (from inside the callback is fine — the mutex is
/// recursive-safe here because the callback runs OUTSIDE the lock).
pub const MissingImageFn = *const fn (name: [*:0]const u8, user: ?*anyopaque) callconv(.c) void;

/// Called when charttable needs tile bytes it cannot get itself. Answer with
/// charttable_resource_respond, at any time and from any thread — the
/// request PARKS until you do, and a slow answer never becomes a permanently
/// missing tile. Answering from inside the callback is supported (it runs
/// outside the handle's lock).
pub const ResourceFn = *const fn (
    req_id: u64,
    source: [*:0]const u8,
    z: u32,
    x: u32,
    y: u32,
    user: ?*anyopaque,
) callconv(.c) void;

const Handle = struct {
    gpa: std.mem.Allocator,
    mu: Lock = .{},
    m: map_object.Map,

    g: ?gpu.Gpu = null,
    uploaded: map_object.Map.Uploaded = .{},

    /// Archives the handle opened and therefore owns.
    archives: std.ArrayListUnmanaged(*Archive) = .empty,
    /// Host-backed sources, likewise owned. The name travels with each one
    /// so a request can tell the host WHICH source it is for.
    provided: std.ArrayListUnmanaged(*Provided) = .empty,
    libraries: std.ArrayListUnmanaged(*Library) = .empty,
    on_resource: ?ResourceFn = null,
    resource_user: ?*anyopaque = null,
    /// Scratch for draining asks, so a tick allocates nothing new.
    asks: std.ArrayListUnmanaged(providers.Request) = .empty,

    sprite: ?sprites.Sprite = null,
    glyph_atlas: ?glyphs.GlyphAtlas = null,
    /// Atlas pixels the SURFACE currently holds. The Map's assets and the
    /// GPU's textures are two different things: loading a sprite tells the
    /// layout what an icon looks like, uploading it is what lets the batcher
    /// draw the range at all.
    sprite_uploaded: u32 = 0,
    glyphs_dirty: bool = false,

    on_missing: ?MissingImageFn = null,
    missing_user: ?*anyopaque = null,
    /// Names already handed to the host, so the callback fires once per name
    /// rather than once per frame.
    reported: std.StringHashMapUnmanaged(void) = .empty,
    /// Names collected during the last render, to report after the lock drops.
    pending_missing: std.ArrayListUnmanaged([:0]u8) = .empty,

    /// Images the host handed over while a build was reading the atlases.
    /// Applied as soon as it lands.
    pending_images: std.ArrayListUnmanaged(PendingImage) = .empty,

    /// Scratch for borrowed strings (diagnostics), valid until the next call
    /// of the same kind.
    scratch: std.ArrayListUnmanaged(u8) = .empty,

    const Archive = struct {
        reader: pmtiles.Reader,
        src: caches.PmtilesSource,
    };

    const PendingImage = struct {
        name: []u8,
        rgba: []u8,
        w: u32,
        h: u32,
        ratio: f32,
    };

    const Provided = struct {
        provider: providers.Provider,
        name: [:0]u8,
    };

    /// A style source name backed by a LIBRARY of archives. Calling
    /// charttable_add_source_pmtiles again with the same name adds to it.
    const Library = struct {
        lib: caches.PmtilesLibrary,
        name: [:0]u8,
    };
};

const State = struct {
    var gpa_impl: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
};

/// The allocator every handle and its map run on.
///
/// DebugAllocator earns its keep in a safety build -- it catches the leaks
/// and double-frees a C host would otherwise blame on charttable -- but leak
/// tracking is a development tool, and a shipped library should not impose it
/// on every host. An optimized build takes the fast general-purpose allocator,
/// which is thread-safe as the tile workers require.
///
/// Measured, so the claim is not overstated: over 6 paced-pinch runs the
/// medians were 257 ms (smp) against 268 ms (debug) of total frame time --
/// inside the run-to-run noise. Allocation is not this renderer's bottleneck;
/// this change is for correctness of packaging, not speed.
fn generalAllocator() std.mem.Allocator {
    return switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => State.gpa_impl.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };
}

fn handle(h: ?*anyopaque) ?*Handle {
    return @ptrCast(@alignCast(h orelse return null));
}

/// Take the lock and hand back the handle, or null. Every entry point starts
/// with this and `defer self.mu.unlock()`, so the lock can't be skipped.
fn locked(h: ?*anyopaque) ?*Handle {
    const self = handle(h) orelse return null;
    self.mu.lock();
    return self;
}

// ---- lifecycle -------------------------------------------------------------

export fn charttable_open(opts: ?*const Options) callconv(.c) ?*anyopaque {
    const gpa = generalAllocator();
    const self = gpa.create(Handle) catch return null;
    var copts = map_object.Options{};
    if (opts) |o| {
        if (o.workers > 0) copts.cache.workers = @min(o.workers, 16);
        if (o.cache_bytes > 0) copts.cache.budget_bytes = @intCast(o.cache_bytes);
    }
    self.* = .{ .gpa = gpa, .m = map_object.Map.init(gpa, copts) };
    return self;
}

export fn charttable_close(h: ?*anyopaque) callconv(.c) void {
    const self = handle(h) orelse return;
    self.mu.lock();
    if (self.g) |*g| g.deinit();
    self.m.deinit();
    for (self.archives.items) |ar| {
        ar.reader.deinit();
        self.gpa.destroy(ar);
    }
    self.archives.deinit(self.gpa);
    for (self.provided.items) |pr| {
        pr.provider.deinit();
        self.gpa.free(pr.name);
        self.gpa.destroy(pr);
    }
    self.provided.deinit(self.gpa);
    for (self.libraries.items) |lb| {
        lb.lib.deinit();
        self.gpa.free(lb.name);
        self.gpa.destroy(lb);
    }
    self.libraries.deinit(self.gpa);
    self.asks.deinit(self.gpa);
    if (self.sprite) |*s| s.deinit();
    if (self.glyph_atlas) |*a| a.deinit();
    var it = self.reported.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.reported.deinit(self.gpa);
    for (self.pending_missing.items) |n| self.gpa.free(n);
    self.pending_missing.deinit(self.gpa);
    for (self.pending_images.items) |img| {
        self.gpa.free(img.name);
        self.gpa.free(img.rgba);
    }
    self.pending_images.deinit(self.gpa);
    self.scratch.deinit(self.gpa);
    const gpa = self.gpa;
    self.mu.unlock();
    gpa.destroy(self);
}

export fn charttable_attach_surface(
    h: ?*anyopaque,
    kind: c_int,
    native: ?*anyopaque,
    w_px: u32,
    h_px: u32,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    if (w_px == 0 or h_px == 0) return ERR_ARG;
    if (self.g) |*g| g.deinit();
    self.g = gpu.Gpu.init(.{
        .width = w_px,
        .height = h_px,
        .native_handle = native,
        .native_kind = @enumFromInt(kind),
    }) catch {
        self.g = null;
        return ERR_SURFACE;
    };
    self.uploaded = .{};
    // A fresh surface holds no textures.
    self.sprite_uploaded = 0;
    self.glyphs_dirty = self.glyph_atlas != null;
    self.m.setViewport(@floatFromInt(w_px), @floatFromInt(h_px));
    return OK;
}

/// The renderer-owned IDXGISwapChain* to compose, for a surface attached with
/// kind d3d12_panel (ISwapChainPanelNative::SetSwapChain). NULL on every other
/// kind and on every other backend.
///
/// The renderer keeps ownership: charttable_resize rebuilds its buffers and
/// charttable_detach_surface releases it, so a host must drop its own
/// reference before detaching.
export fn charttable_d3d12_swapchain(h: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self = locked(h) orelse return null;
    defer self.mu.unlock();
    const g = if (self.g) |*x| x else return null;
    return g.swapchainPtr();
}

export fn charttable_detach_surface(h: ?*anyopaque) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    if (self.g) |*g| g.deinit();
    self.g = null;
    self.uploaded = .{};
}

export fn charttable_resize(h: ?*anyopaque, w_pt: u32, h_pt: u32) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    if (w_pt == 0 or h_pt == 0) return ERR_ARG;
    if (self.g) |*g| g.resize(w_pt, h_pt);
    self.m.setViewport(@floatFromInt(w_pt), @floatFromInt(h_pt));
    return OK;
}

/// The physical size multiplier for symbols, text and line widths. S-52
/// specifies symbol sizes in millimeters; the sprite is rasterized at the
/// catalogue's own px-per-mm, so a host that wants those physical sizes on
/// ITS display passes the ratio here. 1.0 (the default) draws sprite cells
/// at their logical size. Uniform-only: no relayout, no re-upload.
/// The zoom band the camera may move in. A chart library has a natural
/// floor; below it every tile in the world is wanted and the data is a
/// smear. Defaults to 0..24, i.e. no limit worth speaking of.
export fn charttable_set_zoom_range(h: ?*anyopaque, min_zoom: f64, max_zoom: f64) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.setZoomRange(min_zoom, max_zoom);
}

export fn charttable_set_size_scale(h: ?*anyopaque, scale: f32) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.setSizeScale(scale);
}

export fn charttable_set_pixel_density(h: ?*anyopaque, d: f32) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    if (self.g) |*g| g.setPixelDensity(d);
}

/// The scene contract's layout guard. A host that links against a header from
/// a different build gets a loud mismatch instead of a wrong picture.
export fn charttable_abi_layout() callconv(.c) u32 {
    return @import("scene/types.zig").abiLayout();
}

// ---- style + sources -------------------------------------------------------

export fn charttable_set_style_json(h: ?*anyopaque, json: [*]const u8, len: usize) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    if (len > max_style_bytes) return ERR_STYLE;
    self.m.setStyleJson(json[0..len]) catch return ERR_STYLE;
    self.uploaded = .{};
    return OK;
}

/// The style's degradation log, as one NUL-terminated block of lines.
/// Borrowed until the next call of this function.
export fn charttable_style_diagnostics(h: ?*anyopaque, out_len: ?*usize) callconv(.c) ?[*:0]const u8 {
    const self = locked(h) orelse return null;
    defer self.mu.unlock();
    self.scratch.clearRetainingCapacity();
    for (self.m.styleDiagnostics()) |d| {
        self.scratch.appendSlice(self.gpa, d.layer) catch return null;
        self.scratch.appendSlice(self.gpa, ": ") catch return null;
        self.scratch.appendSlice(self.gpa, d.property) catch return null;
        self.scratch.appendSlice(self.gpa, ": ") catch return null;
        self.scratch.appendSlice(self.gpa, d.message) catch return null;
        self.scratch.append(self.gpa, '\n') catch return null;
    }
    self.scratch.append(self.gpa, 0) catch return null;
    if (out_len) |p| p.* = self.scratch.items.len - 1;
    return @ptrCast(self.scratch.items.ptr);
}

/// Bind a style source name to a local pmtiles archive. The decoder comes
/// from the style's `encoding`, falling back to the archive's declared tile
/// type — the host never has to say "this one is MLT".
export fn charttable_add_source_pmtiles(
    h: ?*anyopaque,
    name: [*:0]const u8,
    path: [*:0]const u8,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    const io = std.Io.Threaded.global_single_threaded.io();
    const want = std.mem.span(name);

    const ar = self.gpa.create(Handle.Archive) catch return ERR_MEMORY;
    errdefer self.gpa.destroy(ar);
    ar.reader = pmtiles.Reader.open(self.gpa, io, std.mem.span(path)) catch return ERR_SOURCE;
    ar.src = .{ .reader = &ar.reader };
    self.archives.append(self.gpa, ar) catch {
        ar.reader.deinit();
        return ERR_MEMORY;
    };

    // Repeat calls for one source name build a LIBRARY: many archives, one
    // source, finest cell first. That is how a chart plotter opens a folder.
    for (self.libraries.items) |lb| {
        if (!std.mem.eql(u8, lb.name, want)) continue;
        lb.lib.add(&ar.reader) catch return ERR_MEMORY;
        _ = self.m.bindPmtilesLibrary(want, &lb.lib) catch |e| return bindErr(e);
        return OK;
    }
    const lb = self.gpa.create(Handle.Library) catch return ERR_MEMORY;
    lb.name = self.gpa.dupeZ(u8, want) catch {
        self.gpa.destroy(lb);
        return ERR_MEMORY;
    };
    lb.lib = caches.PmtilesLibrary.init(self.gpa);
    lb.lib.add(&ar.reader) catch return ERR_MEMORY;
    self.libraries.append(self.gpa, lb) catch return ERR_MEMORY;
    _ = self.m.bindPmtilesLibrary(want, &lb.lib) catch |e| return bindErr(e);
    return OK;
}

/// How many archives a source name currently has, for a host that wants to
/// report "opened N charts".
export fn charttable_source_archive_count(h: ?*anyopaque, name: [*:0]const u8) callconv(.c) u32 {
    const self = locked(h) orelse return 0;
    defer self.mu.unlock();
    const want = std.mem.span(name);
    for (self.libraries.items) |lb| {
        if (std.mem.eql(u8, lb.name, want)) return @intCast(lb.lib.count());
    }
    return 0;
}

/// Set one paint property from a JSON fragment (`"#ff0000"`, `0.5`, or a
/// whole expression). A uniform color or opacity refills the paint stream
/// and never re-lays-out; returns 1 when it was served that way, 0 when it
/// needed a rebuild, negative on error.
export fn charttable_set_paint_property(
    h: ?*anyopaque,
    layer: [*:0]const u8,
    name: [*:0]const u8,
    json_value: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    if (len > max_property_json_bytes or !jsondepth.ok(json_value[0..len])) return ERR_ARG;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_value[0..len], .{}) catch
        return ERR_ARG;
    const paint_only = self.m.setPaintProperty(std.mem.span(layer), std.mem.span(name), v) catch |e|
        return setErr(e);
    return if (paint_only) 1 else 0;
}

export fn charttable_set_layout_property(
    h: ?*anyopaque,
    layer: [*:0]const u8,
    name: [*:0]const u8,
    json_value: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    if (len > max_property_json_bytes or !jsondepth.ok(json_value[0..len])) return ERR_ARG;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_value[0..len], .{}) catch
        return ERR_ARG;
    self.m.setLayoutProperty(std.mem.span(layer), std.mem.span(name), v) catch |e| return setErr(e);
    return OK;
}

/// Replace a layer's filter WHOLESALE. Passing NULL clears it. There is no
/// merge and no partial update: whatever you pass becomes the entire filter,
/// and a host that assumes otherwise silently widens what draws.
export fn charttable_set_filter(
    h: ?*anyopaque,
    layer: [*:0]const u8,
    json_filter: ?[*]const u8,
    len: usize,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var v: ?std.json.Value = null;
    if (json_filter) |bytes| {
        if (len > max_property_json_bytes or !jsondepth.ok(bytes[0..len])) return ERR_ARG;
        v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes[0..len], .{}) catch
            return ERR_ARG;
    }
    self.m.setFilter(std.mem.span(layer), v) catch |e| return setErr(e);
    return OK;
}

export fn charttable_set_layer_visibility(h: ?*anyopaque, layer: [*:0]const u8, on: c_int) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    self.m.setLayerVisibility(std.mem.span(layer), on != 0) catch |e| return setErr(e);
    return OK;
}

fn setErr(e: anyerror) c_int {
    return switch (e) {
        error.UnknownLayer, error.UnknownProperty => ERR_ARG,
        error.BadValue => ERR_ARG,
        error.NoStyle => ERR_STYLE,
        else => ERR_MEMORY,
    };
}

/// Route a style source name through the host. Every tile of that source
/// becomes a callback, answered by charttable_resource_respond.
/// What a host-provided source serves. A zeroed struct is what
/// charttable_add_source_provided gives: vector MVT over z0-22.
pub const ProvidedOpts = extern struct {
    kind: u32 = 0, // 0 vector, 1 raster
    encoding: u32 = 0, // 0 mvt, 1 mlt
    minzoom: u32 = 0,
    maxzoom: u32 = 22,
};

export fn charttable_add_source_provided(h: ?*anyopaque, name: [*:0]const u8) callconv(.c) c_int {
    return charttable_add_source_provided_opts(h, name, null);
}

export fn charttable_add_source_provided_opts(
    h: ?*anyopaque,
    name: [*:0]const u8,
    opts: ?*const ProvidedOpts,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    const o: ProvidedOpts = if (opts) |p| p.* else .{};
    const pr = self.gpa.create(Handle.Provided) catch return ERR_MEMORY;
    errdefer self.gpa.destroy(pr);
    pr.name = self.gpa.dupeZ(u8, std.mem.span(name)) catch return ERR_MEMORY;
    pr.provider = providers.Provider.init(self.gpa);
    // Request ids must be unique across ALL provided sources: one callback
    // and one respond() serve every source, so two providers numbering from
    // 1 would answer each other's requests.
    pr.provider.id_bias = @as(u64, self.provided.items.len + 1) << 48;
    pr.provider.kind = if (o.kind == 1) .raster else .vector;
    pr.provider.encoding = if (o.encoding == 1) .mlt else .mvt;
    // A source that stops at z12 must SAY so: the build zoom is clamped by
    // the shallowest maxzoom bound, and a default of 22 sends the map asking
    // for tiles the host has to answer 404 to, forever.
    pr.provider.minzoom = @intCast(@min(o.minzoom, 22));
    pr.provider.maxzoom = @intCast(@min(@max(o.maxzoom, o.minzoom), 22));
    self.provided.append(self.gpa, pr) catch {
        pr.provider.deinit();
        self.gpa.free(pr.name);
        self.gpa.destroy(pr);
        return ERR_MEMORY;
    };
    // A refused bind leaves nothing behind: keeping the entry would shift
    // id_bias for every source added after it, and the provider is unusable.
    // Freed exactly the way charttable_close frees one.
    _ = self.m.bindProvider(std.mem.span(name), &pr.provider) catch |e| {
        _ = self.provided.pop();
        pr.provider.deinit();
        self.gpa.free(pr.name);
        self.gpa.destroy(pr);
        return bindErr(e);
    };
    return OK;
}

export fn charttable_set_resource_provider(
    h: ?*anyopaque,
    cb: ?ResourceFn,
    user: ?*anyopaque,
) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.on_resource = cb;
    self.resource_user = user;
}

/// Answer one request. `status` is 0 for bytes, 1 for "no tile there", 2 for
/// "I tried and failed". Only 0 reads `bytes`, which is copied before this
/// returns. An unknown or already-answered id is ignored.
export fn charttable_resource_respond(
    h: ?*anyopaque,
    req_id: u64,
    bytes: ?[*]const u8,
    len: usize,
    status: c_int,
) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    const st: providers.Status = switch (status) {
        0 => .ok,
        1 => .empty,
        else => .failed,
    };
    // Every network tile enters here. A body past the ceiling is treated as
    // a failed fetch rather than decoded: the decoders downstream allocate in
    // proportion to their input, so bounding the input is what bounds them.
    if (st == .ok and len > max_resource_bytes) {
        const slice: []const u8 = &.{};
        respondTo(self, req_id, slice, .failed);
        return;
    }
    const slice: []const u8 = if (st == .ok and bytes != null) bytes.?[0..len] else &.{};
    respondTo(self, req_id, slice, st);
}

/// Map a source-binding failure to a status code. A Cache holds at most
/// caches.max_sources sources, because the tile-cache key spends three bits
/// naming one; the ninth bind is refused rather than silently aliased onto
/// the first.
fn bindErr(e: anyerror) c_int {
    return switch (e) {
        error.TooManySources => ERR_SOURCE,
        error.OutOfMemory => ERR_MEMORY,
        else => ERR_SOURCE,
    };
}

/// Route one answer to the provider that asked for it. Caller holds the lock.
///
/// The id says which source asked (see id_bias); only that provider is
/// offered the answer. Broadcasting it was how a raster tile's PNG ended up
/// being decoded as someone else's vector tile.
fn respondTo(self: *Handle, req_id: u64, slice: []const u8, st: providers.Status) void {
    const which = req_id >> 48;
    if (which >= 1 and which <= self.provided.items.len) {
        self.provided.items[which - 1].provider.respond(req_id, slice, st);
        return;
    }
    for (self.provided.items) |pr| pr.provider.respond(req_id, slice, st);
}

/// Apply images queued while a build was reading the atlases.
fn flushPendingImages(self: *Handle) void {
    if (self.pending_images.items.len == 0 or self.m.buildInFlight()) return;
    for (self.pending_images.items) |img| {
        _ = applyImage(self, img.name, img.rgba, img.w, img.h, img.ratio);
        self.gpa.free(img.name);
        self.gpa.free(img.rgba);
    }
    self.pending_images.clearRetainingCapacity();
}

/// Hand the host every ask raised since the last call. Runs OUTSIDE the
/// lock so the callback may answer immediately.
///
/// The callback may also ADD a source, and charttable_add_source_provided
/// appends to `self.provided`. An append that reallocates frees the buffer
/// a `for (self.provided.items)` loop is in the middle of reading, so this
/// walks by index and re-reads `self.provided.items` on every step. The
/// elements are heap pointers and only charttable_close destroys them, so
/// `pr` itself stays good across the unlock.
///
/// Today the reallocation cannot happen: std.ArrayList's first allocation
/// holds 17 pointers and caches.max_sources is 8. The index walk costs
/// nothing and stops that coincidence from being load-bearing.
fn pumpResources(self: *Handle) void {
    const cb = self.on_resource orelse return;
    const user = self.resource_user;
    var i: usize = 0;
    while (i < self.provided.items.len) : (i += 1) {
        const pr = self.provided.items[i];
        self.asks.clearRetainingCapacity();
        pr.provider.drain(&self.asks, self.gpa);
        if (self.asks.items.len == 0) continue;
        const batch = self.asks.toOwnedSlice(self.gpa) catch continue;
        defer self.gpa.free(batch);
        const name = pr.name;
        self.mu.unlock();
        for (batch) |r| cb(r.id, name.ptr, r.z, r.x, r.y, user);
        self.mu.lock();
    }
}

// ---- images ----------------------------------------------------------------

export fn charttable_set_missing_image_callback(
    h: ?*anyopaque,
    cb: ?MissingImageFn,
    user: ?*anyopaque,
) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.on_missing = cb;
    self.missing_user = user;
}

/// Add (or replace) a runtime image. Straight-alpha RGBA8, w*h*4 bytes,
/// copied before this returns. Answers the missing-image callback.
export fn charttable_add_image(
    h: ?*anyopaque,
    name: [*:0]const u8,
    rgba: [*]const u8,
    w: u32,
    h_px: u32,
    pixel_ratio: f32,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    if (w == 0 or h_px == 0) return ERR_ARG;
    // w and h_px are u32 straight from the caller, and `w * h_px * 4` is a
    // usize multiply: 2^31 x 2^31 overflows 64 bits, which panics under
    // ReleaseSafe and silently wraps under ReleaseFast into a SHORT slice of
    // a buffer the host said was huge. Reject the dimensions instead. The
    // cap matches sprites.max_height and png.max_dim, so the C entry point
    // is no stricter than the decoders behind it.
    if (w > max_image_dim or h_px > max_image_dim) return ERR_ARG;
    // A build in flight is reading the atlases, and this is the ONE asset
    // call a host makes at frame rate: answering missing images. Blocking
    // here would hand the frame thread the rest of the build -- measured at
    // a 190 ms frame across a zoom-out. Queue the pixels and apply them when
    // the build lands; a symbol that appears one frame later is invisible
    // next to a stall.
    if (self.m.buildInFlight()) {
        const n = @as(usize, w) * h_px * 4;
        const img = Handle.PendingImage{
            .name = self.gpa.dupe(u8, std.mem.span(name)) catch return ERR_MEMORY,
            .rgba = self.gpa.dupe(u8, rgba[0..n]) catch return ERR_MEMORY,
            .w = w,
            .h = h_px,
            .ratio = pixel_ratio,
        };
        self.pending_images.append(self.gpa, img) catch return ERR_MEMORY;
        return OK;
    }
    return applyImage(self, std.mem.span(name), rgba[0 .. @as(usize, w) * h_px * 4], w, h_px, pixel_ratio);
}

/// Put one image into the sprite atlas. Caller holds the lock and has
/// already made sure no build is reading it.
fn applyImage(
    self: *Handle,
    name: []const u8,
    rgba: []const u8,
    w: u32,
    h_px: u32,
    pixel_ratio: f32,
) c_int {
    if (self.sprite == null) {
        // A style with no sprite still has to accept runtime images.
        self.sprite = sprites.Sprite.initEmpty(self.gpa, 512) catch return ERR_MEMORY;
        self.m.setAssets(.{ .sprite = &self.sprite.?, .glyph_atlas = if (self.glyph_atlas) |*a| a else null });
    }
    self.sprite.?.addImage(name, rgba, w, h_px, pixel_ratio) catch return ERR_ARG;
    // New pixels mean an icon that was missing may now resolve: re-lay-out.
    self.m.setAssets(.{ .sprite = &self.sprite.?, .glyph_atlas = if (self.glyph_atlas) |*a| a else null });
    self.uploaded = .{};
    return OK;
}

export fn charttable_remove_image(h: ?*anyopaque, name: [*:0]const u8) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    // A build in flight is reading these atlases.
    self.m.waitForBuild();
    if (self.sprite) |*s| s.removeImage(std.mem.span(name));
}

/// Load the style's sprite sheet (MapLibre sprite JSON + PNG). Replaces any
/// sheet already loaded; runtime images added before this are lost with it.
export fn charttable_set_sprite(
    h: ?*anyopaque,
    index_json: [*]const u8,
    json_len: usize,
    png_bytes: [*]const u8,
    png_len: usize,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    // A build in flight is reading these atlases.
    self.m.waitForBuild();
    var loaded = sprites.Sprite.load(self.gpa, index_json[0..json_len], png_bytes[0..png_len]) catch
        return ERR_ARG;
    if (self.sprite) |*s| s.deinit();
    self.sprite = loaded;
    errdefer loaded.deinit();
    self.m.setAssets(.{ .sprite = &self.sprite.?, .glyph_atlas = if (self.glyph_atlas) |*a| a else null });
    self.uploaded = .{};
    return OK;
}

/// Add one fontstack range (a fontnik glyph PBF) to the SDF atlas.
/// A host-baked SDF glyph sheet: RGBA atlas + an index of UVs and EM-unit
/// metrics (see glyphs.addSdfSheet). For a host whose text engine already
/// bakes one, so it need not also produce fontnik PBFs.
export fn charttable_set_glyph_sheet(
    h: ?*anyopaque,
    index_json: [*]const u8,
    json_len: usize,
    rgba: [*]const u8,
    w: u32,
    h_px: u32,
) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    // Same overflow guard as charttable_add_image.
    if (w == 0 or h_px == 0) return ERR_ARG;
    if (w > max_image_dim or h_px > max_image_dim) return ERR_ARG;
    self.m.waitForBuild();
    if (self.glyph_atlas == null) {
        self.glyph_atlas = glyphs.GlyphAtlas.init(self.gpa, glyphs.default_width) catch
            return ERR_MEMORY;
    }
    const n = @as(usize, w) * h_px * 4;
    const added = self.glyph_atlas.?.addSdfSheet(index_json[0..json_len], rgba[0..n], w, h_px) catch
        return ERR_ARG;
    if (added == 0) return ERR_ARG;
    self.glyphs_dirty = true;
    self.m.setAssets(.{
        .sprite = if (self.sprite) |*sp| sp else null,
        .glyph_atlas = if (self.glyph_atlas) |*ga| ga else null,
    });
    return OK;
}

export fn charttable_add_glyphs(h: ?*anyopaque, pbf: [*]const u8, len: usize) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    // A build in flight is reading these atlases.
    self.m.waitForBuild();
    if (self.glyph_atlas == null) {
        self.glyph_atlas = glyphs.GlyphAtlas.init(self.gpa, glyphs.default_width) catch
            return ERR_MEMORY;
    }
    _ = self.glyph_atlas.?.addRange(pbf[0..len]) catch return ERR_ARG;
    self.glyphs_dirty = true;
    self.m.setAssets(.{
        .sprite = if (self.sprite) |*s| s else null,
        .glyph_atlas = &self.glyph_atlas.?,
    });
    self.uploaded = .{};
    return OK;
}

// ---- camera ----------------------------------------------------------------

export fn charttable_set_view(h: ?*anyopaque, v: ?*const View) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    const view = v orelse return;
    self.m.setView(view.lon, view.lat, view.zoom);
    self.m.cam.rotation = view.bearing_deg * std.math.pi / 180.0;
}

export fn charttable_get_view(h: ?*anyopaque, v: ?*View) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    const out = v orelse return;
    const ll = coord.worldToLonLat(.{ self.m.cam.center.x, self.m.cam.center.y });
    out.* = .{
        .lon = ll[0],
        .lat = ll[1],
        .zoom = self.m.cam.zoom,
        .bearing_deg = self.m.cam.rotation * 180.0 / std.math.pi,
    };
}

export fn charttable_pan(h: ?*anyopaque, dx_pt: f32, dy_pt: f32) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.pan(dx_pt, dy_pt);
}

export fn charttable_zoom_at(h: ?*anyopaque, dzoom: f64, x_pt: f32, y_pt: f32) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.zoomAt(dzoom, x_pt, y_pt);
}

/// Zoom about a screen point, EASED over the next frames (the cursor's world
/// point stays put). This is what a wheel, a pinch or a zoom button should
/// call; charttable_zoom_at is the instant form.
export fn charttable_zoom_toward(h: ?*anyopaque, dzoom: f64, x_pt: f32, y_pt: f32) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.zoomToward(dzoom, x_pt, y_pt);
}

/// Start a fling at `vx`, `vy` LOGICAL POINTS PER SECOND; (0, 0) stops one.
/// It decays in charttable_tick and keeps needs_redraw true until it settles.
export fn charttable_fling(h: ?*anyopaque, vx: f64, vy: f64) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.fling(vx, vy);
}

export fn charttable_screen_to_geo(
    h: ?*anyopaque,
    x_pt: f32,
    y_pt: f32,
    lon: ?*f64,
    lat: ?*f64,
) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    const w = self.m.cam.screenToWorld(x_pt, y_pt);
    const ll = coord.worldToLonLat(.{ w.x, w.y });
    if (lon) |p| p.* = ll[0];
    if (lat) |p| p.* = ll[1];
}

export fn charttable_geo_to_screen(
    h: ?*anyopaque,
    lon: f64,
    lat: f64,
    x_pt: ?*f32,
    y_pt: ?*f32,
) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    const w = coord.lonLatToWorld(lon, lat);
    const s = self.m.cam.worldToScreen(.{ .x = w[0], .y = w[1] });
    if (x_pt) |p| p.* = @floatCast(s.x);
    if (y_pt) |p| p.* = @floatCast(s.y);
}

// ---- the frame loop --------------------------------------------------------

/// Advance animation and tile loading by `dt_ms`. The host owns the clock —
/// nothing here reads a wall clock.
export fn charttable_tick(h: ?*anyopaque, dt_ms: f64) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    self.m.advance(dt_ms / 1000.0);
    _ = self.m.update() catch return ERR_MEMORY;
    collectMissing(self);
    pumpResources(self);
    return OK;
}

export fn charttable_needs_redraw(h: ?*anyopaque) callconv(.c) c_int {
    const self = locked(h) orelse return 0;
    defer self.mu.unlock();
    return if (self.m.needsRedraw()) 1 else 0;
}

/// Honest completeness: every tile this view asked for has an answer, the
/// scene covers the view, and nothing is animating.
export fn charttable_idle(h: ?*anyopaque) callconv(.c) c_int {
    const self = locked(h) orelse return 0;
    defer self.mu.unlock();
    return if (self.m.idle()) 1 else 0;
}

/// Draw a frame into the attached surface. Returns 1 if it drew, 0 if there
/// was nothing to do, negative on error.
export fn charttable_render(h: ?*anyopaque) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    const g = if (self.g) |*g| g else return ERR_SURFACE;
    _ = self.m.update() catch return ERR_MEMORY;
    collectMissing(self);
    pumpResources(self);
    syncAtlases(self);
    _ = self.m.uploadIfChanged(g, &self.uploaded) catch return ERR_MEMORY;
    const drew = g.renderWindow(self.m.uniforms());
    if (drew) self.m.markDrawn();
    return if (drew) 1 else 0;
}

/// Render offscreen and copy RGBA8 (top-down, w*h*4) into `dst`.
export fn charttable_snapshot_rgba(h: ?*anyopaque, dst: [*]u8, len: usize) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    const g = if (self.g) |*g| g else return ERR_SURFACE;
    const need = @as(usize, g.width) * g.height * 4;
    if (len < need) return ERR_ARG;
    _ = self.m.update() catch return ERR_MEMORY;
    collectMissing(self);
    syncAtlases(self);
    _ = self.m.uploadIfChanged(g, &self.uploaded) catch return ERR_MEMORY;
    const px = g.renderOffscreen(self.gpa, self.m.uniforms()) catch return ERR_SURFACE;
    defer self.gpa.free(px);
    self.m.markDrawn();
    @memcpy(dst[0..need], px[0..need]);
    return OK;
}

/// How many tiles this view is still waiting on — for a host that wants a
/// progress readout rather than a boolean.
export fn charttable_pending_tiles(h: ?*anyopaque) callconv(.c) u32 {
    const self = locked(h) orelse return 0;
    defer self.mu.unlock();
    return @intCast(self.m.pendingWanted());
}

/// Push atlas pixels to the surface when they have changed. Sprite growth
/// bumps Sprite.generation (the host's re-upload signal), glyph ranges set a
/// dirty flag, and a re-attached surface starts empty.
///
/// Without this the batcher sees no atlases and DROPS every quads range: the
/// map draws its fills and patterns and silently loses every icon and label.
fn syncAtlases(self: *Handle) void {
    const g = if (self.g) |*gg| gg else return;
    if (self.sprite) |*sp| {
        if (self.sprite_uploaded != sp.generation) {
            g.uploadSpriteAtlas(sp.rgba, sp.width, sp.height) catch return;
            self.sprite_uploaded = sp.generation;
        }
    }
    if (self.glyph_atlas) |*ga| {
        if (self.glyphs_dirty) {
            const rgba = ga.toRgba(self.gpa) catch return;
            defer self.gpa.free(rgba);
            g.uploadGlyphAtlas(rgba, ga.width, ga.height) catch return;
            self.glyphs_dirty = false;
        }
    }
}

/// Names the scene could not resolve are reported ONCE each, and the
/// callback runs outside the lock so the host may answer with add_image
/// from inside it.
fn collectMissing(self: *Handle) void {
    const b = self.m.scene() orelse return;
    if (self.on_missing == null) return;
    for (b.missing_images) |name| {
        if (self.reported.contains(name)) continue;
        const owned = self.gpa.dupe(u8, name) catch continue;
        self.reported.put(self.gpa, owned, {}) catch {
            self.gpa.free(owned);
            continue;
        };
        const z = self.gpa.dupeZ(u8, name) catch continue;
        self.pending_missing.append(self.gpa, z) catch self.gpa.free(z);
    }
    if (self.pending_missing.items.len == 0) return;
    const cb = self.on_missing.?;
    const user = self.missing_user;
    const names = self.pending_missing.toOwnedSlice(self.gpa) catch return;
    self.mu.unlock();
    for (names) |n| cb(n.ptr, user);
    self.mu.lock();
    for (names) |n| self.gpa.free(n);
    self.gpa.free(names);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const smoke_style =
    \\{"version": 8,
    \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
    \\ "layers": [{"id": "bg", "type": "background",
    \\   "paint": {"background-color": "#204060"}}]}
;

test "capi: a handle opens, takes a style, moves the camera, and closes" {
    const h = charttable_open(&.{ .workers = 1, .cache_bytes = 1 << 20 }) orelse
        return error.OpenFailed;
    defer charttable_close(h);

    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));

    var v = View{ .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
    charttable_set_view(h, &v);
    var back = View{};
    charttable_get_view(h, &back);
    try testing.expectApproxEqAbs(@as(f64, -76.4767), back.lon, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 38.9763), back.lat, 1e-6);
    try testing.expectEqual(@as(f64, 14), back.zoom);

    // Round-trip a screen point through the projection.
    try testing.expectEqual(OK, charttable_resize(h, 512, 512));
    var lon: f64 = 0;
    var lat: f64 = 0;
    charttable_screen_to_geo(h, 256, 256, &lon, &lat);
    var sx: f32 = 0;
    var sy: f32 = 0;
    charttable_geo_to_screen(h, lon, lat, &sx, &sy);
    try testing.expectApproxEqAbs(@as(f32, 256), sx, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 256), sy, 0.5);

    // A style with no bound source has nothing to wait for.
    try testing.expectEqual(OK, charttable_tick(h, 16));
    try testing.expectEqual(@as(u32, 0), charttable_pending_tiles(h));

    // Runtime images work without a style sprite.
    const px = [_]u8{ 255, 0, 255, 255 } ** 4;
    try testing.expectEqual(OK, charttable_add_image(h, "marker", &px, 2, 2, 1.0));
    charttable_remove_image(h, "marker");

    // Diagnostics are borrowed, NUL-terminated, and never null.
    var dlen: usize = 0;
    const diags = charttable_style_diagnostics(h, &dlen) orelse return error.NoDiagnostics;
    try testing.expectEqual(@as(u8, 0), diags[dlen]);

    // The layout guard is the scene contract's, not a second copy.
    try testing.expectEqual(@import("scene/types.zig").abiLayout(), charttable_abi_layout());
}

test "capi: every entry point is null-safe" {
    try testing.expectEqual(ERR_HANDLE, charttable_set_style_json(null, smoke_style.ptr, smoke_style.len));
    try testing.expectEqual(ERR_HANDLE, charttable_tick(null, 16));
    try testing.expectEqual(ERR_HANDLE, charttable_render(null));
    try testing.expectEqual(@as(c_int, 0), charttable_needs_redraw(null));
    try testing.expectEqual(@as(c_int, 0), charttable_idle(null));
    try testing.expectEqual(@as(u32, 0), charttable_pending_tiles(null));
    try testing.expect(charttable_style_diagnostics(null, null) == null);
    charttable_close(null);
    charttable_pan(null, 1, 1);
    charttable_set_view(null, null);
}

// The host-provided source, end to end through the ABI: the map asks, the
// host answers late, and the tile lands. A slow answer must never become a
// permanently missing tile.
const ResourceProbe = struct {
    var map_handle: ?*anyopaque = null;
    var seen: usize = 0;
    var last_source: [64]u8 = @splat(0);
    var tile_bytes: []const u8 = &.{};

    fn onResource(req_id: u64, source: [*:0]const u8, z: u32, x: u32, y: u32, user: ?*anyopaque) callconv(.c) void {
        _ = user;
        _ = z;
        _ = x;
        _ = y;
        seen += 1;
        const name = std.mem.span(source);
        @memcpy(last_source[0..@min(name.len, last_source.len)], name[0..@min(name.len, last_source.len)]);
        // Answering from inside the callback is supported: the handle's lock
        // is released around it.
        charttable_resource_respond(map_handle, req_id, tile_bytes.ptr, tile_bytes.len, 0);
    }
};

test "capi: a provided source parks, then lands when the host answers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The smallest MVT that decodes: one layer, no features.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, &.{ 3 << 3 | 2, 12 });
    try buf.appendSlice(a, &.{ 15 << 3 | 0, 2 });
    try buf.appendSlice(a, &.{ 1 << 3 | 2, 5 });
    try buf.appendSlice(a, "areas");
    try buf.appendSlice(a, &.{ 5 << 3 | 0, 0x80, 0x20 });

    const style =
        \\{"version": 8,
        \\ "sources": {"remote": {"type": "vector", "tiles": ["https://x/{z}/{x}/{y}"], "maxzoom": 14}},
        \\ "layers": [{"id": "bg", "type": "background",
        \\   "paint": {"background-color": "#000000"}}]}
    ;
    const h = charttable_open(&.{ .workers = 2 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    ResourceProbe.map_handle = h;
    ResourceProbe.seen = 0;
    ResourceProbe.tile_bytes = buf.items;

    try testing.expectEqual(OK, charttable_set_style_json(h, style.ptr, style.len));
    charttable_set_resource_provider(h, ResourceProbe.onResource, null);
    try testing.expectEqual(OK, charttable_add_source_provided(h, "remote"));
    try testing.expectEqual(OK, charttable_resize(h, 512, 512));
    var v = View{ .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
    charttable_set_view(h, &v);

    var spins: usize = 0;
    while (spins < 3000 and charttable_idle(h) == 0) : (spins += 1) {
        _ = charttable_tick(h, 16);
        @import("util/lock.zig").sleepMs(1);
    }
    try testing.expectEqual(@as(c_int, 1), charttable_idle(h));
    try testing.expect(ResourceProbe.seen > 0);
    try testing.expectEqualStrings("remote", std.mem.sliceTo(&ResourceProbe.last_source, 0));
    try testing.expectEqual(@as(u32, 0), charttable_pending_tiles(h));

    // A stray response is ignored rather than fatal.
    charttable_resource_respond(h, 999999, null, 0, 1);
    try testing.expectEqual(OK, charttable_tick(h, 16));
}

// Symbols through the ABI. The library can hold a sprite the SURFACE has
// never seen: loading one tells the layout what an icon looks like, uploading
// it is what lets the batcher draw the range at all. Miss the upload and the
// map renders its fills and patterns and silently loses every icon and label
// — which is exactly what the example app showed.
test "capi: a loaded sprite and glyph atlas actually reach the surface" {
    if (!gpu.renders) return error.SkipZigTest;
    const ct_build = @import("ct_build");
    const io = std.Io.Threaded.global_single_threaded.io();
    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    const sprite_env = std.c.getenv("CHARTTABLE_TEST_SPRITE_DIR") orelse return error.SkipZigTest;
    const glyph_env = std.c.getenv("CHARTTABLE_TEST_GLYPHS_DIR") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sdir = std.mem.span(sprite_env);
    const gdir = std.mem.span(glyph_env);

    const style_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/chart-day-style-symbols.json", .{ct_build.assets_dir}),
        a,
        .limited(8 * 1024 * 1024),
    );
    const sprite_json = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/sprite-mln.json", .{sdir}), a, .limited(64 << 20)) catch return error.SkipZigTest;
    const sprite_png = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/sprite-mln.png", .{sdir}), a, .limited(256 << 20)) catch return error.SkipZigTest;

    const h = charttable_open(&.{ .workers = 3 }) orelse return error.OpenFailed;
    defer charttable_close(h);

    try testing.expectEqual(OK, charttable_set_sprite(h, sprite_json.ptr, sprite_json.len, sprite_png.ptr, sprite_png.len));
    for ([_][]const u8{ "0-255", "256-511" }) |range| {
        const pbf = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/Noto Sans Regular/{s}.pbf", .{ gdir, range }), a, .limited(16 << 20)) catch continue;
        _ = charttable_add_glyphs(h, pbf.ptr, pbf.len);
    }
    try testing.expectEqual(OK, charttable_set_style_json(h, style_json.ptr, style_json.len));
    const path = try a.dupeZ(u8, std.mem.span(chart_env));
    try testing.expectEqual(OK, charttable_add_source_pmtiles(h, "chart", path.ptr));
    try testing.expectEqual(OK, charttable_attach_surface(h, 0, null, 512, 512));
    try testing.expectEqual(OK, charttable_resize(h, 512, 512));
    var v = View{ .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
    charttable_set_view(h, &v);

    var spins: usize = 0;
    while (spins < 3000 and charttable_idle(h) == 0) : (spins += 1) {
        _ = charttable_tick(h, 16);
        @import("util/lock.zig").sleepMs(1);
    }
    try testing.expectEqual(@as(c_int, 1), charttable_idle(h));

    const n = 512 * 512 * 4;
    const dst = try a.alloc(u8, n);
    try testing.expectEqual(OK, charttable_snapshot_rgba(h, dst.ptr, n));

    // The scene has symbol quads to draw...
    const scene = @import("map_object.zig");
    _ = scene;
    const built = handle(h).?.m.scene() orelse return error.NoScene;
    var quad_ranges: usize = 0;
    for (built.ranges) |r| {
        if (r.prim == .quads) quad_ranges += 1;
    }
    std.debug.print("\ncapi symbols: {d} quad ranges, {d} quad verts\n", .{ quad_ranges, built.quads.len });
    try testing.expect(quad_ranges > 0);
    try testing.expect(built.quads.len > 600);

    // ...and they reached the frame. Chart labels and symbol ink are dark
    // against the S-52 day palette, which has no near-black fill.
    var dark: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (dst[i] < 60 and dst[i + 1] < 60 and dst[i + 2] < 60) dark += 1;
    }
    std.debug.print("  dark pixels (symbol + label ink): {d}\n", .{dark});
    try testing.expect(dark > 500);
}

test "capi: a bad style is refused and the old one stands" {
    const h = charttable_open(null) orelse return error.OpenFailed;
    defer charttable_close(h);
    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));
    const bad = "{\"version\": 7}";
    try testing.expectEqual(ERR_STYLE, charttable_set_style_json(h, bad.ptr, bad.len));
    // Still usable: the rejected style never replaced the good one.
    try testing.expectEqual(OK, charttable_tick(h, 0));
}

test "capi: an archive binds by name and the map loads through it" {
    if (!gpu.renders) return error.SkipZigTest;
    const ct_build = @import("ct_build");
    const io = std.Io.Threaded.global_single_threaded.io();
    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const style_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/chart-day-style.json", .{ct_build.assets_dir}),
        a,
        .limited(4 * 1024 * 1024),
    );

    const h = charttable_open(&.{ .workers = 2 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    try testing.expectEqual(OK, charttable_set_style_json(h, style_json.ptr, style_json.len));

    const path = try a.dupeZ(u8, std.mem.span(chart_env));
    try testing.expectEqual(OK, charttable_add_source_pmtiles(h, "chart", path.ptr));
    try testing.expectEqual(ERR_SOURCE, charttable_add_source_pmtiles(h, "chart", "/nope/missing.pmtiles"));

    try testing.expectEqual(OK, charttable_resize(h, 512, 512));
    var v = View{ .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
    charttable_set_view(h, &v);

    // Tick until the map says it is finished, then trust it.
    var spins: usize = 0;
    while (spins < 2000 and charttable_idle(h) == 0) : (spins += 1) {
        _ = charttable_tick(h, 16);
        @import("util/lock.zig").sleepMs(1);
    }
    try testing.expectEqual(@as(c_int, 1), charttable_idle(h));
    try testing.expectEqual(@as(u32, 0), charttable_pending_tiles(h));
    // Complete, but a frame is still OWED: nothing has drawn this camera
    // yet. The two questions are deliberately different.
    try testing.expectEqual(@as(c_int, 1), charttable_needs_redraw(h));

    // Offscreen render through the ABI: a snapshot with the chart's own
    // shallow-water blue in it.
    const n = 512 * 512 * 4;
    const dst = try a.alloc(u8, n);
    try testing.expectEqual(ERR_SURFACE, charttable_snapshot_rgba(h, dst.ptr, n));
    try testing.expectEqual(OK, charttable_attach_surface(h, 0, null, 512, 512));
    try testing.expectEqual(ERR_ARG, charttable_snapshot_rgba(h, dst.ptr, 4));
    try testing.expectEqual(OK, charttable_snapshot_rgba(h, dst.ptr, n));
    // Drawn: now there is nothing to do at all.
    try testing.expectEqual(@as(c_int, 0), charttable_needs_redraw(h));
    // ...until the camera moves, which is damage even though the tiles and
    // the scene are untouched.
    charttable_pan(h, 3, 0);
    try testing.expectEqual(@as(c_int, 1), charttable_needs_redraw(h));
    try testing.expectEqual(@as(c_int, 1), charttable_idle(h));
    var water: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (dst[i] == 130 and dst[i + 1] == 202 and dst[i + 2] == 255) water += 1;
    }
    try testing.expect(water > (512 * 512) / 20);
}

/// Records every ask without answering, so a test can answer them by hand.
const TwoSourceProbe = struct {
    var ids: [32]u64 = @splat(0);
    var names: [32][24]u8 = @splat(@splat(0));
    var seen: usize = 0;

    /// Whether both sources have raised at least one ask.
    fn sawBoth() bool {
        var a = false;
        var b = false;
        for (names[0..seen]) |n| {
            if (n[0] == 'a') a = true;
            if (n[0] == 'b') b = true;
        }
        return a and b;
    }

    fn onResource(req_id: u64, source: [*:0]const u8, z: u32, x: u32, y: u32, user: ?*anyopaque) callconv(.c) void {
        _ = .{ user, z, x, y };
        if (seen >= ids.len) return;
        const name = std.mem.span(source);
        ids[seen] = req_id;
        @memcpy(names[seen][0..@min(name.len, 24)], name[0..@min(name.len, 24)]);
        seen += 1;
    }
};

test "capi: two provided sources do not answer each other's requests" {
    const style =
        \\{"version": 8,
        \\ "sources": {"a": {"type": "vector", "tiles": ["https://a/{z}/{x}/{y}"], "maxzoom": 14},
        \\             "b": {"type": "vector", "tiles": ["https://b/{z}/{x}/{y}"], "maxzoom": 14}},
        \\ "layers": [{"id": "bg", "type": "background",
        \\   "paint": {"background-color": "#000000"}}]}
    ;
    const h = charttable_open(&.{ .workers = 2 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    TwoSourceProbe.seen = 0;
    try testing.expectEqual(OK, charttable_set_style_json(h, style.ptr, style.len));
    charttable_set_resource_provider(h, TwoSourceProbe.onResource, null);
    try testing.expectEqual(OK, charttable_add_source_provided(h, "a"));
    try testing.expectEqual(OK, charttable_add_source_provided(h, "b"));
    try testing.expectEqual(OK, charttable_resize(h, 512, 512));
    var v = View{ .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
    charttable_set_view(h, &v);

    // Asks are raised by cache workers, so this waits on thread scheduling.
    // Wait for the CONDITION being tested -- one ask from each source --
    // rather than for a count, which arrives in whatever order the workers
    // happen to run in.
    var spins: usize = 0;
    while (spins < 3000) : (spins += 1) {
        _ = charttable_tick(h, 16);
        if (TwoSourceProbe.sawBoth()) break;
        @import("util/lock.zig").sleepMs(1);
    }
    if (!TwoSourceProbe.sawBoth()) {
        std.debug.print("\nonly saw {d} asks: ", .{TwoSourceProbe.seen});
        for (TwoSourceProbe.names[0..TwoSourceProbe.seen]) |n| std.debug.print("{s} ", .{n[0..1]});
        std.debug.print("\n", .{});
        return error.NotEnoughAsks;
    }

    // Every id is distinct. They used to be numbered from 1 per provider, so
    // source b's first request had the same id as source a's -- and respond()
    // handed the answer to both.
    for (TwoSourceProbe.ids[0..TwoSourceProbe.seen], 0..) |id, i| {
        for (TwoSourceProbe.ids[0..TwoSourceProbe.seen], 0..) |other, j| {
            if (i == j) continue;
            try testing.expect(id != other);
        }
    }
}

// ---- input-ceiling regressions ---------------------------------------------

/// The resource callback ADDS a source while pumpResources is walking the
/// provider list. That is legal: the pump drops the lock around the callback
/// precisely so the host may call back in.
///
/// Reaching the reallocation this guards against takes 18 providers, because
/// std.ArrayList sizes its first allocation to a cache line — 17 pointers —
/// and the source ceiling is 8. So this test exercises the reentrancy, not
/// the move; the index walk in pumpResources is what keeps the two facts
/// independent, and the ceiling test below is what keeps the count at 8.
const GrowProbe = struct {
    var map_handle: ?*anyopaque = null;
    var seen: usize = 0;
    var grown: usize = 0;
    var extra_names: [4][8:0]u8 = @splat(@splat(0));

    fn onResource(req_id: u64, source: [*:0]const u8, z: u32, x: u32, y: u32, user: ?*anyopaque) callconv(.c) void {
        _ = .{ source, z, x, y, user };
        seen += 1;
        // Grow the list from inside the callback, exactly when the caller is
        // iterating it. Several appends, so at least one crosses a capacity
        // boundary whatever the starting capacity is.
        if (grown < GrowProbe.extra_names.len) {
            const slot = &GrowProbe.extra_names[grown];
            slot.* = @splat(0);
            _ = std.fmt.bufPrint(slot, "grow{d}", .{grown}) catch {};
            grown += 1;
            _ = charttable_add_source_provided(map_handle, @ptrCast(slot));
        }
        charttable_resource_respond(map_handle, req_id, null, 0, 1);
    }
};

test "capi: a callback may add a source while the pump is walking the list" {
    const style =
        \\{"version": 8,
        \\ "sources": {
        \\   "a": {"type": "vector", "tiles": ["https://x/a/{z}/{x}/{y}"], "maxzoom": 14},
        \\   "b": {"type": "vector", "tiles": ["https://x/b/{z}/{x}/{y}"], "maxzoom": 14},
        \\   "c": {"type": "vector", "tiles": ["https://x/c/{z}/{x}/{y}"], "maxzoom": 14},
        \\   "d": {"type": "vector", "tiles": ["https://x/d/{z}/{x}/{y}"], "maxzoom": 14}},
        \\ "layers": [{"id": "bg", "type": "background",
        \\   "paint": {"background-color": "#000000"}}]}
    ;
    const h = charttable_open(&.{ .workers = 1 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    GrowProbe.map_handle = h;
    GrowProbe.seen = 0;
    GrowProbe.grown = 0;

    try testing.expectEqual(OK, charttable_set_style_json(h, style.ptr, style.len));
    charttable_set_resource_provider(h, GrowProbe.onResource, null);
    for ([_][*:0]const u8{ "a", "b", "c", "d" }) |n| {
        try testing.expectEqual(OK, charttable_add_source_provided(h, n));
    }
    try testing.expectEqual(OK, charttable_resize(h, 512, 512));
    var v = View{ .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
    charttable_set_view(h, &v);

    var spins: usize = 0;
    while (spins < 2000 and charttable_idle(h) == 0) : (spins += 1) {
        _ = charttable_tick(h, 16);
        @import("util/lock.zig").sleepMs(1);
    }
    // Every provider in the list was still served after the list grew.
    try testing.expect(GrowProbe.seen > 0);
    try testing.expect(GrowProbe.grown > 0);
    try testing.expectEqual(OK, charttable_tick(h, 16));
}

test "capi: a body over the resource ceiling is refused without reading it" {
    const h = charttable_open(&.{ .workers = 1 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));

    // A one-byte buffer with a length past the ceiling. The check runs before
    // the slice is formed, so nothing dereferences past the byte that exists.
    var one: [1]u8 = .{0};
    charttable_resource_respond(h, 1, &one, max_resource_bytes + 1, 0);
    charttable_resource_respond(h, 1, &one, std.math.maxInt(usize), 0);
    try testing.expectEqual(OK, charttable_tick(h, 16));
}

test "capi: image dimensions that would overflow w*h*4 are rejected" {
    const h = charttable_open(&.{ .workers = 1 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));

    var px: [4]u8 = .{ 255, 0, 0, 255 };
    // 2^31 x 2^31 x 4 does not fit in a usize. Neither operand is read.
    try testing.expectEqual(ERR_ARG, charttable_add_image(h, "big", &px, 1 << 31, 1 << 31, 1.0));
    try testing.expectEqual(ERR_ARG, charttable_add_image(h, "big", &px, max_image_dim + 1, 1, 1.0));
    try testing.expectEqual(ERR_ARG, charttable_add_image(h, "big", &px, 1, max_image_dim + 1, 1.0));
    // A 1x1 image is still accepted.
    try testing.expectEqual(OK, charttable_add_image(h, "ok", &px, 1, 1, 1.0));

    var idx: [2]u8 = .{ '{', '}' };
    try testing.expectEqual(ERR_ARG, charttable_set_glyph_sheet(h, &idx, idx.len, &px, 1 << 31, 1 << 31));
    try testing.expectEqual(ERR_ARG, charttable_set_glyph_sheet(h, &idx, idx.len, &px, 0, 0));
}

test "capi: deeply nested JSON is refused instead of overflowing the stack" {
    const a = testing.allocator;
    const h = charttable_open(&.{ .workers = 1 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));

    // 100k open brackets. std.json builds its value tree by recursion, so
    // without the pre-scan this kills the process rather than erroring.
    const deep = try a.alloc(u8, 100_000);
    defer a.free(deep);
    @memset(deep, '[');
    try testing.expectEqual(ERR_STYLE, charttable_set_style_json(h, deep.ptr, deep.len));
    try testing.expectEqual(ERR_ARG, charttable_set_paint_property(h, "bg", "background-color", deep.ptr, deep.len));
    try testing.expectEqual(ERR_ARG, charttable_set_layout_property(h, "bg", "visibility", deep.ptr, deep.len));
    try testing.expectEqual(ERR_ARG, charttable_set_filter(h, "bg", deep.ptr, deep.len));

    // The handle is still usable afterwards.
    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));
}

test "capi: the ninth source is refused, not aliased onto the first" {
    const h = charttable_open(&.{ .workers = 1 }) orelse return error.OpenFailed;
    defer charttable_close(h);
    try testing.expectEqual(OK, charttable_set_style_json(h, smoke_style.ptr, smoke_style.len));

    // The tile cache key spends three bits naming a source, so eight fit.
    // The ninth used to trip a std.debug.assert -- a panic under ReleaseSafe,
    // and under ReleaseFast no check at all: the index truncated and source 8
    // shared every cache key with source 0.
    var name: [8:0]u8 = @splat(0);
    for (0..caches.max_sources) |i| {
        name = @splat(0);
        _ = try std.fmt.bufPrint(&name, "s{d}", .{i});
        try testing.expectEqual(OK, charttable_add_source_provided(h, &name));
    }
    name = @splat(0);
    _ = try std.fmt.bufPrint(&name, "s{d}", .{caches.max_sources});
    try testing.expectEqual(ERR_SOURCE, charttable_add_source_provided(h, &name));

    // Re-binding a name already present still works: it replaces, and takes
    // no new slot.
    try testing.expectEqual(OK, charttable_add_source_provided(h, "s0"));
    try testing.expectEqual(OK, charttable_tick(h, 16));
}

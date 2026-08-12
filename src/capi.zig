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
const builtin = @import("builtin");
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

pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1,
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
    on_resource: ?ResourceFn = null,
    resource_user: ?*anyopaque = null,
    /// Scratch for draining asks, so a tick allocates nothing new.
    asks: std.ArrayListUnmanaged(providers.Request) = .empty,

    sprite: ?sprites.Sprite = null,
    glyph_atlas: ?glyphs.GlyphAtlas = null,

    on_missing: ?MissingImageFn = null,
    missing_user: ?*anyopaque = null,
    /// Names already handed to the host, so the callback fires once per name
    /// rather than once per frame.
    reported: std.StringHashMapUnmanaged(void) = .empty,
    /// Names collected during the last render, to report after the lock drops.
    pending_missing: std.ArrayListUnmanaged([:0]u8) = .empty,

    /// Scratch for borrowed strings (diagnostics), valid until the next call
    /// of the same kind.
    scratch: std.ArrayListUnmanaged(u8) = .empty,

    const Archive = struct {
        reader: pmtiles.Reader,
        src: caches.PmtilesSource,
    };

    const Provided = struct {
        provider: providers.Provider,
        name: [:0]u8,
    };
};

const State = struct {
    var gpa_impl: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
};

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
    const gpa = State.gpa_impl.allocator();
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
    self.asks.deinit(self.gpa);
    if (self.sprite) |*s| s.deinit();
    if (self.glyph_atlas) |*a| a.deinit();
    var it = self.reported.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.reported.deinit(self.gpa);
    for (self.pending_missing.items) |n| self.gpa.free(n);
    self.pending_missing.deinit(self.gpa);
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
    self.m.setViewport(@floatFromInt(w_px), @floatFromInt(h_px));
    return OK;
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
    const ar = self.gpa.create(Handle.Archive) catch return ERR_MEMORY;
    errdefer self.gpa.destroy(ar);
    ar.reader = pmtiles.Reader.open(self.gpa, io, std.mem.span(path)) catch return ERR_SOURCE;
    ar.src = .{ .reader = &ar.reader };
    self.archives.append(self.gpa, ar) catch {
        ar.reader.deinit();
        return ERR_MEMORY;
    };
    _ = self.m.bindPmtiles(std.mem.span(name), &ar.src) catch return ERR_MEMORY;
    return OK;
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
export fn charttable_add_source_provided(h: ?*anyopaque, name: [*:0]const u8) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    const pr = self.gpa.create(Handle.Provided) catch return ERR_MEMORY;
    errdefer self.gpa.destroy(pr);
    pr.name = self.gpa.dupeZ(u8, std.mem.span(name)) catch return ERR_MEMORY;
    pr.provider = providers.Provider.init(self.gpa);
    self.provided.append(self.gpa, pr) catch {
        self.gpa.free(pr.name);
        return ERR_MEMORY;
    };
    _ = self.m.bindProvider(std.mem.span(name), &pr.provider) catch return ERR_MEMORY;
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
    const slice: []const u8 = if (st == .ok and bytes != null) bytes.?[0..len] else &.{};
    for (self.provided.items) |pr| pr.provider.respond(req_id, slice, st);
}

/// Hand the host every ask raised since the last call. Runs OUTSIDE the
/// lock so the callback may answer immediately.
fn pumpResources(self: *Handle) void {
    const cb = self.on_resource orelse return;
    const user = self.resource_user;
    for (self.provided.items) |pr| {
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
    if (self.sprite == null) {
        // A style with no sprite still has to accept runtime images.
        self.sprite = sprites.Sprite.initEmpty(self.gpa, 512) catch return ERR_MEMORY;
        self.m.setAssets(.{ .sprite = &self.sprite.?, .glyph_atlas = if (self.glyph_atlas) |*a| a else null });
    }
    const n = @as(usize, w) * h_px * 4;
    self.sprite.?.addImage(std.mem.span(name), rgba[0..n], w, h_px, pixel_ratio) catch return ERR_ARG;
    // New pixels mean an icon that was missing may now resolve: re-lay-out.
    self.m.setAssets(.{ .sprite = &self.sprite.?, .glyph_atlas = if (self.glyph_atlas) |*a| a else null });
    self.uploaded = .{};
    return OK;
}

export fn charttable_remove_image(h: ?*anyopaque, name: [*:0]const u8) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
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
export fn charttable_add_glyphs(h: ?*anyopaque, pbf: [*]const u8, len: usize) callconv(.c) c_int {
    const self = locked(h) orelse return ERR_HANDLE;
    defer self.mu.unlock();
    if (self.glyph_atlas == null) {
        self.glyph_atlas = glyphs.GlyphAtlas.init(self.gpa, glyphs.default_width) catch
            return ERR_MEMORY;
    }
    _ = self.glyph_atlas.?.addRange(pbf[0..len]) catch return ERR_ARG;
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
    self.m.cam.panPx(dx_pt, dy_pt);
}

export fn charttable_zoom_at(h: ?*anyopaque, dzoom: f64, x_pt: f32, y_pt: f32) callconv(.c) void {
    const self = locked(h) orelse return;
    defer self.mu.unlock();
    self.m.cam.zoomAbout(dzoom, x_pt, y_pt);
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
    if (dt_ms > 0) self.m.cam.tick(dt_ms / 1000.0);
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
    _ = self.m.uploadIfChanged(g, &self.uploaded) catch return ERR_MEMORY;
    return if (g.renderWindow(self.m.uniforms())) 1 else 0;
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
    _ = self.m.uploadIfChanged(g, &self.uploaded) catch return ERR_MEMORY;
    const px = g.renderOffscreen(self.gpa, self.m.uniforms()) catch return ERR_SURFACE;
    defer self.gpa.free(px);
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
    try testing.expectEqual(@as(c_int, 0), charttable_needs_redraw(h));
    try testing.expectEqual(@as(u32, 0), charttable_pending_tiles(h));

    // Offscreen render through the ABI: a snapshot with the chart's own
    // shallow-water blue in it.
    const n = 512 * 512 * 4;
    const dst = try a.alloc(u8, n);
    try testing.expectEqual(ERR_SURFACE, charttable_snapshot_rgba(h, dst.ptr, n));
    try testing.expectEqual(OK, charttable_attach_surface(h, 0, null, 512, 512));
    try testing.expectEqual(ERR_ARG, charttable_snapshot_rgba(h, dst.ptr, 4));
    try testing.expectEqual(OK, charttable_snapshot_rgba(h, dst.ptr, n));
    var water: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (dst[i] == 130 and dst[i + 1] == 202 and dst[i + 2] == 255) water += 1;
    }
    try testing.expect(water > (512 * 512) / 20);
}

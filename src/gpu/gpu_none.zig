//! The `none` backend: the selector's fallback on a target with no window
//! system to draw into (freestanding, wasi). It carries the same API surface
//! as the real backends so platform-independent code compiles everywhere;
//! init reports Unsupported, so no Gpu value ever exists on these platforms.
const std = @import("std");
const scene = @import("../scene/types.zig");

pub const Uniforms = scene.Uniforms;

pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// Nothing here draws, so a test that renders skips outright.
pub const renders = false;

pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1,
};

pub const Options = struct {
    width: u32,
    height: u32,
    want_msaa: bool = false,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Gpu = struct {
    width: u32 = 0,
    height: u32 = 0,
    pixel_density: f32 = 1.0,
    clear: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    opaque_pass: bool = true,
    scene: ?Scene = null,

    pub const SceneData = struct {
        vertices: []const scene.Vertex = &.{},
        paint: []const scene.PaintVertex = &.{},
        paint_hi: []const scene.PaintVertex = &.{},
        indices: []const u32 = &.{},
        quads: []const scene.Quad = &.{},
        quad_paint: []const scene.PaintVertex = &.{},
        ranges: []const scene.Range = &.{},
        patterns: []const scene.PatternCell = &.{},
    };

    pub const Scene = struct {
        alloc: std.mem.Allocator,
    };

    pub fn init(opts: Options) error{Unsupported}!Gpu {
        _ = opts;
        return error.Unsupported;
    }
    pub fn deinit(self: *Gpu) void {
        _ = self;
    }
    pub fn updatePaint(self: *Gpu, paint: []const scene.PaintVertex) !void {
        _ = self;
        _ = paint;
        return error.Unsupported;
    }
    /// Only the D3D12 backend hands a swapchain to its host to compose.
    pub fn swapchainPtr(self: *Gpu) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        _ = self;
        _ = d;
    }
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) void {
        self.width = width_pts;
        self.height = height_pts;
    }
    pub fn uploadSpriteAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) error{Unsupported}!void {
        _ = self;
        _ = rgba;
        _ = w;
        _ = h;
        return error.Unsupported;
    }
    pub const uploadGlyphAtlas = uploadSpriteAtlas;
    pub const uploadGlyphAtlasBold = uploadSpriteAtlas;
    pub const uploadGlyphAtlasItalic = uploadSpriteAtlas;
    pub fn updateSpriteAtlasRows(self: *Gpu, rgba: []const u8, w: u32, h: u32, y0: u32, rows: u32) bool {
        _ = self;
        _ = rgba;
        _ = w;
        _ = h;
        _ = y0;
        _ = rows;
        return false;
    }
    pub fn uploadScene(self: *Gpu, alloc: std.mem.Allocator, data: SceneData) error{Unsupported}!void {
        _ = self;
        _ = alloc;
        _ = data;
        return error.Unsupported;
    }
    pub fn makeScene(self: *Gpu, alloc: std.mem.Allocator, data: SceneData) error{Unsupported}!Scene {
        _ = self;
        _ = data;
        _ = alloc;
        return error.Unsupported;
    }
    pub fn adoptScene(self: *Gpu, sc: Scene) void {
        _ = self;
        _ = sc;
    }
    pub fn freeStagedScene(self: *Gpu, sc: *Scene) void {
        _ = self;
        _ = sc;
    }
    pub fn freeScene(self: *Gpu) void {
        self.scene = null;
    }
    pub fn renderWindow(self: *Gpu, u: Uniforms) bool {
        _ = self;
        _ = u;
        return false;
    }
    pub fn renderTexture(
        self: *Gpu,
        u: Uniforms,
        tex: ?*anyopaque,
        done: ?*const fn (?*anyopaque) callconv(.c) void,
        user: ?*anyopaque,
    ) bool {
        _ = self;
        _ = u;
        _ = tex;
        _ = done;
        _ = user;
        return false;
    }
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms) error{Unsupported}![]u8 {
        _ = self;
        _ = alloc;
        _ = u;
        return error.Unsupported;
    }
    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms) error{Unsupported}!void {
        _ = self;
        _ = alloc;
        _ = path;
        _ = u;
        return error.Unsupported;
    }
};

test "none backend reports Unsupported" {
    try std.testing.expectError(error.Unsupported, Gpu.init(.{ .width = 1, .height = 1 }));
}

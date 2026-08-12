//! MapLibre sprite: index JSON + sheet PNG -> one RGBA atlas with a
//! name -> cell map.
//!
//! Format per the published style spec (maplibre.org/maplibre-style-spec/sprite):
//! a sprite is two files fetched by appending extensions to the style's base
//! URL — `.json` (the index) and `.png` (the sheet) — with `@2x` inserted
//! before the extension on high-DPI displays. The index maps image name to
//! {x, y, width, height, pixelRatio} in sheet pixels (plus optional fields —
//! sdf, content, stretchX/Y — ignored at this tier). The sheet PNG IS the
//! atlas: it is decoded once and kept as a single RGBA plane, never repacked.
//!
//! Runtime images (`add_image`, the missing-image hook — DESIGN.md Tier 1)
//! append below the sheet with a grow-downward shelf packer. Limits, by
//! design (keep it simple):
//!   - the atlas width is fixed at the sheet's width; an image wider than
//!     that is error.Unsupported;
//!   - cells are never reclaimed — removing or replacing an image orphans
//!     its pixels (the entry goes away, the pixels stay until deinit);
//!   - growth reallocates the plane and bumps `generation`; the host
//!     re-uploads the texture when the generation it uploaded is stale.
//! Lookups return UVs computed against the CURRENT atlas size, so a grown
//! atlas never leaves stale [0,1] rects behind.
//!
//! Loader shape follows lookout-marine src/atlas.zig loadSprite (stbi there,
//! util/png.zig here); the packer is tile57 src/sprite/sprite.zig packMlnOpts
//! grown downward instead of packed once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const png = @import("../util/png.zig");

pub const Error = error{ Malformed, Unsupported, AtlasFull, OutOfMemory };

/// One resolved icon: the cell's UV rect in the CURRENT atlas, its size in
/// atlas pixels, and the pixel ratio it was rasterized at (size / ratio =
/// logical size). UVs are the exact cell edges; sampling insets are the
/// tessellator's business.
pub const Icon = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    w: u32,
    h: u32,
    pixel_ratio: f32,
};

/// A cell in atlas pixels. Kept in pixels (not UV) so atlas growth cannot
/// stale-out stored rects.
const Cell = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    pixel_ratio: f32,
};

const pad: u32 = 1; // gap between packed runtime cells
pub const max_height: u32 = 16384; // grown-atlas cap (common GPU texture limit)

pub const Sprite = struct {
    alloc: Allocator,
    /// The atlas plane: RGBA8, `width * height * 4`. Rows [0, sheet_height)
    /// are the decoded sheet; the region below is the runtime-image area.
    rgba: []u8,
    width: u32,
    height: u32,
    entries: std.StringHashMapUnmanaged(Cell) = .empty,
    /// Bumped whenever atlas pixels change (load counts as generation 1).
    /// A host compares against the generation it last uploaded.
    generation: u32 = 0,
    // Grow-downward shelf packer state.
    pen_x: u32 = 0,
    pen_y: u32 = 0,
    row_h: u32 = 0,

    /// Parse the sprite index JSON + sheet PNG. The sheet becomes the atlas
    /// verbatim. Entry names are copied; `index_json` and `sheet_png` may be
    /// freed after this returns.
    pub fn load(alloc: Allocator, index_json: []const u8, sheet_png: []const u8) Error!Sprite {
        var tmp = std.heap.ArenaAllocator.init(alloc);
        defer tmp.deinit();
        const ta = tmp.allocator();

        const img = try png.read(ta, sheet_png);
        var self = Sprite{
            .alloc = alloc,
            .rgba = try alloc.dupe(u8, img.rgba),
            .width = img.w,
            .height = img.h,
            .pen_y = img.h,
            .generation = 1,
        };
        errdefer self.deinit();

        const doc = std.json.parseFromSliceLeaky(std.json.Value, ta, index_json, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        if (doc != .object) return error.Malformed;
        var it = doc.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) return error.Malformed;
            const o = e.value_ptr.object;
            const x = uintField(o, "x") orelse return error.Malformed;
            const y = uintField(o, "y") orelse return error.Malformed;
            const w = uintField(o, "width") orelse return error.Malformed;
            const h = uintField(o, "height") orelse return error.Malformed;
            const ratio = ratioField(o) orelse return error.Malformed;
            // The cell must lie inside the sheet.
            if (x > img.w or w > img.w - x or y > img.h or h > img.h - y)
                return error.Malformed;
            try self.putEntry(e.key_ptr.*, .{ .x = x, .y = y, .w = w, .h = h, .pixel_ratio = ratio });
        }
        return self;
    }

    /// An empty sprite (style without a `sprite` root property) that still
    /// accepts runtime images — charttable_add_image must work either way.
    pub fn initEmpty(alloc: Allocator, width: u32) Error!Sprite {
        if (width == 0 or width > max_height) return error.Unsupported;
        return .{ .alloc = alloc, .rgba = &.{}, .width = width, .height = 0 };
    }

    pub fn deinit(self: *Sprite) void {
        self.alloc.free(self.rgba);
        var it = self.entries.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    /// Resolve an image name. UVs are computed against the current atlas
    /// dimensions, so they stay valid across growth.
    pub fn lookup(self: *const Sprite, name: []const u8) ?Icon {
        const c = self.entries.get(name) orelse return null;
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        return .{
            .u0 = @as(f32, @floatFromInt(c.x)) / fw,
            .v0 = @as(f32, @floatFromInt(c.y)) / fh,
            .u1 = @as(f32, @floatFromInt(c.x + c.w)) / fw,
            .v1 = @as(f32, @floatFromInt(c.y + c.h)) / fh,
            .w = c.w,
            .h = c.h,
            .pixel_ratio = c.pixel_ratio,
        };
    }

    /// A cell's rect in ATLAS PIXELS. `lookup` answers the quad tessellator
    /// (UVs); this answers whoever needs the pixels themselves — the area-fill
    /// pattern path copies its cell out of the sheet and rescales it by
    /// `pixel_ratio` to the on-screen tiling period.
    pub const Rect = struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        pixel_ratio: f32,
    };

    pub fn cell(self: *const Sprite, name: []const u8) ?Rect {
        const c = self.entries.get(name) orelse return null;
        return .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h, .pixel_ratio = c.pixel_ratio };
    }

    pub fn count(self: *const Sprite) usize {
        return self.entries.count();
    }

    /// Add (or replace) a runtime image: straight-alpha RGBA8, `w * h * 4`.
    /// Backs charttable_add_image and the missing-image hook. Packs into the
    /// grow-downward region; replacing a name orphans the old cell's pixels.
    pub fn addImage(self: *Sprite, name: []const u8, rgba: []const u8, w: u32, h: u32, pixel_ratio: f32) Error!void {
        if (w == 0 or h == 0 or !(pixel_ratio > 0)) return error.Malformed;
        if (w > self.width - pad) return error.Unsupported; // wider than the atlas
        if (h > max_height) return error.AtlasFull;
        // w and h are bounded now, so the product cannot overflow.
        if (rgba.len < @as(usize, w) * h * 4) return error.Malformed;

        // Shelf placement (tile57 packMln's walk, grown downward).
        if (self.pen_x + w + pad > self.width) {
            self.pen_x = 0;
            self.pen_y += self.row_h + pad;
            self.row_h = 0;
        }
        const need = self.pen_y + h + pad;
        if (need > self.height) try self.grow(need);

        const x = self.pen_x;
        const y = self.pen_y;
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const src = rgba[@as(usize, row) * w * 4 ..][0 .. @as(usize, w) * 4];
            const dst = self.rgba[(@as(usize, y + row) * self.width + x) * 4 ..][0 .. @as(usize, w) * 4];
            @memcpy(dst, src);
        }
        self.pen_x += w + pad;
        self.row_h = @max(self.row_h, h);
        self.generation +%= 1;

        try self.putEntry(name, .{ .x = x, .y = y, .w = w, .h = h, .pixel_ratio = pixel_ratio });
    }

    /// Drop an image name. The cell's pixels are NOT reclaimed (documented
    /// limit); a re-added name packs a fresh cell.
    pub fn removeImage(self: *Sprite, name: []const u8) void {
        if (self.entries.fetchRemove(name)) |kv| self.alloc.free(kv.key);
    }

    fn putEntry(self: *Sprite, name: []const u8, entry: Cell) Error!void {
        const gop = try self.entries.getOrPut(self.alloc, name);
        if (!gop.found_existing) {
            errdefer _ = self.entries.remove(name);
            gop.key_ptr.* = try self.alloc.dupe(u8, name);
        }
        gop.value_ptr.* = entry;
    }

    // Extend the plane downward; old pixels keep their coordinates, the new
    // region is transparent. Over-grows by half the current height so a
    // missing-image burst does not reallocate per icon.
    fn grow(self: *Sprite, need: u32) Error!void {
        if (need > max_height) return error.AtlasFull;
        const new_h: u32 = @min(max_height, @max(need, self.height + self.height / 2));
        const plane = try self.alloc.alloc(u8, @as(usize, self.width) * new_h * 4);
        @memcpy(plane[0..self.rgba.len], self.rgba);
        @memset(plane[self.rgba.len..], 0);
        self.alloc.free(self.rgba);
        self.rgba = plane;
        self.height = new_h;
    }
};

/// The spec's high-DPI naming convention: `{base}.{ext}` at ratio 1,
/// `{base}@2x.{ext}` on high-DPI displays (integer ratios above 2 follow the
/// same pattern). Callers round: a 1.5x display conventionally requests @2x
/// and scales down — that choice is the host's, this just formats.
pub const Ext = enum { json, png };
pub fn assetName(a: Allocator, base: []const u8, pixel_ratio: u32, ext: Ext) Allocator.Error![]u8 {
    if (pixel_ratio <= 1)
        return std.fmt.allocPrint(a, "{s}.{s}", .{ base, @tagName(ext) });
    return std.fmt.allocPrint(a, "{s}@{d}x.{s}", .{ base, pixel_ratio, @tagName(ext) });
}

fn uintField(o: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= std.math.maxInt(u32) and @floor(f) == f) @intFromFloat(f) else null,
        else => null,
    };
}

// pixelRatio: spec-required, but absent tolerates to 1 (a lenient reader
// keeps a hand-written index usable; garbage values still reject).
fn ratioField(o: std.json.ObjectMap) ?f32 {
    const v = o.get("pixelRatio") orelse return 1;
    const r: f32 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => return null,
    };
    return if (r > 0 and r <= 16) r else null;
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

// A 8x4 sheet: left 4x4 solid red "dot", then 2x2 solid blue "sq" at (4,0).
fn testSheet(a: Allocator) ![]u8 {
    const w = 8;
    const h = 4;
    const px = try a.alloc(u8, w * h * 4);
    defer a.free(px);
    @memset(px, 0);
    for (0..4) |y| for (0..4) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    };
    for (0..2) |y| for (4..6) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ 0, 0, 255, 255 };
    };
    return png.encode(a, px, w, h);
}

const test_index =
    \\{"dot": {"x": 0, "y": 0, "width": 4, "height": 4, "pixelRatio": 1},
    \\ "sq":  {"x": 4, "y": 0, "width": 2, "height": 2, "pixelRatio": 2, "sdf": false}}
;

test "load: index + sheet, UV math, pixelRatio" {
    const a = testing.allocator;
    const sheet = try testSheet(a);
    defer a.free(sheet);
    var s = try Sprite.load(a, test_index, sheet);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expectEqual(@as(u32, 8), s.width);
    try testing.expectEqual(@as(u32, 4), s.height);

    const dot = s.lookup("dot").?;
    try testing.expectEqual(@as(f32, 0), dot.u0);
    try testing.expectEqual(@as(f32, 0), dot.v0);
    try testing.expectEqual(@as(f32, 0.5), dot.u1);
    try testing.expectEqual(@as(f32, 1.0), dot.v1);
    try testing.expectEqual(@as(u32, 4), dot.w);
    try testing.expectEqual(@as(f32, 1), dot.pixel_ratio);

    const sq = s.lookup("sq").?;
    try testing.expectEqual(@as(f32, 0.5), sq.u0);
    try testing.expectEqual(@as(f32, 0.75), sq.u1);
    try testing.expectEqual(@as(f32, 0.5), sq.v1);
    try testing.expectEqual(@as(f32, 2), sq.pixel_ratio);
    // The atlas really is the sheet: the blue cell's first texel is blue.
    const off = (@as(usize, 0) * s.width + 4) * 4;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, s.rgba[off .. off + 4]);

    try testing.expect(s.lookup("absent") == null);
}

test "load rejects malformed indexes" {
    const a = testing.allocator;
    const sheet = try testSheet(a);
    defer a.free(sheet);

    const bad = [_][]const u8{
        "[1,2,3]", // not an object
        "{\"i\": 4}", // entry not an object
        "{\"i\": {\"x\": 0, \"y\": 0, \"height\": 4}}", // width missing
        "{\"i\": {\"x\": -1, \"y\": 0, \"width\": 2, \"height\": 2}}", // negative
        "{\"i\": {\"x\": 7, \"y\": 0, \"width\": 2, \"height\": 2}}", // out of sheet
        "{\"i\": {\"x\": 0, \"y\": 0, \"width\": 2, \"height\": 2, \"pixelRatio\": 0}}",
        "not json at all",
    };
    for (bad) |idx| {
        try testing.expectError(error.Malformed, Sprite.load(a, idx, sheet));
    }
    // And a malformed sheet under a good index.
    try testing.expectError(error.Malformed, Sprite.load(a, test_index, "not a png"));
}

test "assetName follows the @2x convention" {
    const a = testing.allocator;
    const cases = [_]struct { ratio: u32, ext: Ext, want: []const u8 }{
        .{ .ratio = 1, .ext = .json, .want = "https://x/sprite.json" },
        .{ .ratio = 1, .ext = .png, .want = "https://x/sprite.png" },
        .{ .ratio = 2, .ext = .json, .want = "https://x/sprite@2x.json" },
        .{ .ratio = 2, .ext = .png, .want = "https://x/sprite@2x.png" },
        .{ .ratio = 3, .ext = .png, .want = "https://x/sprite@3x.png" },
    };
    for (cases) |c| {
        const got = try assetName(a, "https://x/sprite", c.ratio, c.ext);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "addImage packs below the sheet, grows, and keeps everything valid" {
    const a = testing.allocator;
    const sheet = try testSheet(a);
    defer a.free(sheet);
    var s = try Sprite.load(a, test_index, sheet);
    defer s.deinit();
    const gen0 = s.generation;

    // A 3x2 solid green runtime image (the missing-image answer shape).
    const green = [_]u8{ 0, 255, 0, 255 } ** 6;
    try s.addImage("run:1", &green, 3, 2, 2.0);
    try testing.expect(s.generation != gen0);
    try testing.expect(s.height > 4); // grew below the 4-row sheet

    const icon = s.lookup("run:1").?;
    try testing.expectEqual(@as(u32, 3), icon.w);
    try testing.expectEqual(@as(u32, 2), icon.h);
    try testing.expectEqual(@as(f32, 2.0), icon.pixel_ratio);
    // UV rect maps back to the cell that actually holds the pixels.
    const cx: u32 = @intFromFloat(icon.u0 * @as(f32, @floatFromInt(s.width)));
    const cy: u32 = @intFromFloat(icon.v0 * @as(f32, @floatFromInt(s.height)));
    const off = (@as(usize, cy) * s.width + cx) * 4;
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, s.rgba[off .. off + 4]);
    try testing.expect(cy >= 4); // runtime region, never the sheet

    // The sheet's own pixels survived the growth, and UVs still resolve.
    const dot = s.lookup("dot").?;
    try testing.expectEqual(@as(f32, 0), dot.u0);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, s.rgba[0..4]);
    try testing.expect(dot.v1 < 1.0); // atlas is taller than the sheet now

    // Fill several rows to force a shelf newline + another growth.
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "run:{d}", .{i + 2});
        try s.addImage(name, &green, 3, 2, 1.0);
    }
    try testing.expectEqual(@as(usize, 2 + 13), s.count());
    // First runtime image still lands on green pixels after all growth.
    const again = s.lookup("run:1").?;
    const ax: u32 = @intFromFloat(again.u0 * @as(f32, @floatFromInt(s.width)));
    const ay: u32 = @intFromFloat(again.v0 * @as(f32, @floatFromInt(s.height)));
    const aoff = (@as(usize, ay) * s.width + ax) * 4;
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, s.rgba[aoff .. aoff + 4]);

    // Replacing a name re-packs; the entry follows the new cell.
    const red = [_]u8{ 255, 0, 0, 255 };
    try s.addImage("run:1", &red, 1, 1, 1.0);
    try testing.expectEqual(@as(u32, 1), s.lookup("run:1").?.w);
    try testing.expectEqual(@as(usize, 2 + 13), s.count()); // replaced, not added

    // Remove drops the entry (pixels orphaned by design).
    s.removeImage("run:1");
    try testing.expect(s.lookup("run:1") == null);

    // Degenerate inputs reject.
    try testing.expectError(error.Unsupported, s.addImage("wide", &green, s.width + 1, 1, 1.0));
    try testing.expectError(error.Malformed, s.addImage("short", green[0..4], 3, 2, 1.0));
    try testing.expectError(error.Malformed, s.addImage("zero", &green, 0, 2, 1.0));
}

test "initEmpty supports add_image without a style sprite" {
    const a = testing.allocator;
    var s = try Sprite.initEmpty(a, 64);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.count());
    const px = [_]u8{ 1, 2, 3, 4 } ** 4;
    try s.addImage("only", &px, 2, 2, 1.0);
    const icon = s.lookup("only").?;
    try testing.expectEqual(@as(u32, 2), icon.w);
    try testing.expect(s.height >= 3);
    const off = (@as(usize, 0) * s.width + 0) * 4;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, s.rgba[off .. off + 4]);
}

test "loads a real baked sprite when the fixture dir is present (integration)" {
    // Optional: point CHARTTABLE_TEST_SPRITE_DIR at a directory holding a
    // MapLibre sprite pair (tile57's `sprite-mln.{json,png}`, or plain
    // `sprite.{json,png}`). Machines without one skip.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    const dir_env = std.c.getenv("CHARTTABLE_TEST_SPRITE_DIR") orelse return error.SkipZigTest;
    const dir = std.mem.span(dir_env);
    const stems = [_][]const u8{ "sprite-mln", "sprite" };
    for (stems) |stem| {
        const jpath = try std.fmt.allocPrint(ar, "{s}/{s}.json", .{ dir, stem });
        const ppath = try std.fmt.allocPrint(ar, "{s}/{s}.png", .{ dir, stem });
        const jbytes = std.Io.Dir.cwd().readFileAlloc(io, jpath, ar, .unlimited) catch continue;
        const pbytes = std.Io.Dir.cwd().readFileAlloc(io, ppath, ar, .unlimited) catch continue;

        var s = try Sprite.load(a, jbytes, pbytes);
        defer s.deinit();
        try testing.expect(s.count() > 0);
        try testing.expect(s.width > 0 and s.height > 0);
        var it = s.entries.iterator();
        while (it.next()) |e| {
            const icon = s.lookup(e.key_ptr.*).?;
            try testing.expect(icon.u0 >= 0 and icon.u1 <= 1 and icon.u0 <= icon.u1);
            try testing.expect(icon.v0 >= 0 and icon.v1 <= 1 and icon.v0 <= icon.v1);
            try testing.expect(icon.pixel_ratio > 0);
        }
        return;
    }
    return error.SkipZigTest; // dir set but no sprite pair found
}

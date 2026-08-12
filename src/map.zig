//! The style-driven scene build: decoded tiles × style layers → one
//! draw-ready SceneData. This is M3 "first light" scope — background, fill
//! and line layers, constant or data-driven paint, filters at fractional
//! zoom. Symbols, patterns, per-tile buckets and the compiled property
//! programs come after (DESIGN.md); today every visible tile builds into
//! ONE scene against a single origin, matching the current Gpu API.
//!
//! Draw order is style order: ranges carry paint_key = layer index and a
//! depth that later layers win. Paint evaluates once per feature into
//! stream B; geometry never re-tessellates for a paint change.

const std = @import("std");
const styles = @import("style/style.zig");
const properties = @import("style/properties.zig");
const exprs = @import("style/expr.zig");
const eval_mod = @import("style/eval.zig");
const vals = @import("style/value.zig");
const mvt = @import("source/mvt.zig");
const coord = @import("source/coord.zig");
const fill = @import("layout/fill.zig");
const line = @import("layout/line.zig");
const types = @import("scene/types.zig");
const cameras = @import("camera.zig");

pub const Value = vals.Value;
pub const Color = vals.Color;

/// One decoded tile offered to the build.
pub const SourcedTile = struct {
    id: coord.TileId,
    tile: *const mvt.Tile,
};

/// The build's output: everything Gpu.SceneData borrows, plus the effective
/// background. Slices live in the arena the caller passed.
pub const Built = struct {
    vertices: []const types.Vertex = &.{},
    paint: []const types.PaintVertex = &.{},
    indices: []const u32 = &.{},
    ranges: []const types.Range = &.{},
    background: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    /// Features that failed a paint evaluation and fell to defaults.
    eval_errors: usize = 0,
};

/// Adapter: an MVT feature seen through the evaluator's Feature interface.
/// Name lookups resolve through the layer's interned key table (linear over
/// a handful of keys; the compiled property programs will pre-resolve).
const MvtFeature = struct {
    layer: *const mvt.Layer,
    feature: *const mvt.Feature,

    fn toValue(v: mvt.Value) Value {
        return switch (v) {
            .string => |s| .{ .string = s },
            .double => |d| .{ .number = d },
            .int => |i| .{ .number = @floatFromInt(i) },
            .uint => |u| .{ .number = @floatFromInt(u) },
            .boolean => |b| .{ .boolean = b },
        };
    }

    fn get(ptr: ?*const anyopaque, key: []const u8) Value {
        const self: *const MvtFeature = @ptrCast(@alignCast(ptr.?));
        const ki = self.layer.keyIndex(key) orelse return .null;
        const v = self.layer.property(self.feature, ki) orelse return .null;
        return toValue(v);
    }

    fn ref(self: *const MvtFeature) eval_mod.Feature {
        return .{
            .ptr = self,
            .get_fn = get,
            .geom = switch (self.feature.geom_type) {
                .point => .point,
                .linestring => .line,
                .polygon => .polygon,
                .unknown => .unknown,
            },
            .id = if (self.feature.id) |id| .{ .number = @floatFromInt(id) } else .null,
        };
    }
};

pub const View = struct {
    zoom: f64,
    /// World point the scene's vertex coordinates are relative to. Use the
    /// camera origin so Camera.mvpOrigin(origin) draws it directly.
    origin: cameras.Vec2,
};

fn resolveProp(l: *const styles.Layer, name: []const u8) ?styles.PropValue {
    return l.resolved(name);
}

/// Evaluate a property for one feature: constants pass through,
/// expressions run; an evaluation error falls back to the spec default.
fn evalProp(
    arena: std.mem.Allocator,
    pv: styles.PropValue,
    ctx: *eval_mod.Context,
    default: Value,
    errors: *usize,
) Value {
    switch (pv) {
        .constant => |v| return v,
        .expression => |p| {
            const v = eval_mod.eval(arena, p.root, ctx) catch {
                errors.* += 1;
                return default;
            };
            if (v == .null) return default;
            return v;
        },
    }
}

fn asColor(v: Value) ?Color {
    return switch (v) {
        .color => |c| c,
        .string => |s| @import("style/color.zig").parse(s),
        else => null,
    };
}

fn asNum(v: Value, fallback: f64) f64 {
    return switch (v) {
        .number => |n| n,
        else => fallback,
    };
}

/// Paint-order depth for style layer `i` of `n`: later paint = smaller,
/// never 0 (0 always passes the depth test regardless of order).
fn layerDepth(i: usize, n: usize) f32 {
    const nf: f32 = @floatFromInt(n + 1);
    return 1.0 - @as(f32, @floatFromInt(i + 1)) / nf;
}

const OPAQUE_ALPHA: u8 = 255;

/// Build one scene from the style and the offered tiles.
///
/// `arena` owns the output (reset it per rebuild). Tiles the style never
/// references are skipped; a style layer whose source-layer is absent from
/// a tile draws nothing there — both are normal, not errors.
pub fn buildScene(
    arena: std.mem.Allocator,
    style: *const styles.Style,
    tiles: []const SourcedTile,
    view: View,
) !Built {
    var out = Built{};
    var verts: std.ArrayList(types.Vertex) = .empty;
    var paint: std.ArrayList(types.PaintVertex) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    var ranges: std.ArrayList(types.Range) = .empty;

    var ctx = eval_mod.Context{ .zoom = view.zoom };

    const n_layers = style.layers.len;
    for (style.layers, 0..) |*sl, layer_i| {
        if (sl.minzoom) |mz| {
            if (view.zoom < mz) continue;
        }
        if (sl.maxzoom) |mz| {
            if (view.zoom >= mz) continue;
        }
        switch (sl.kind) {
            .background => {
                if (resolveProp(sl, "background-color")) |pv| {
                    const v = evalProp(arena, pv, &ctx, .null, &out.eval_errors);
                    if (asColor(v)) |c| out.background = c;
                }
                continue;
            },
            .fill, .line => {},
            .symbol, .raster => continue, // M4+
        }
        const source_layer = sl.source_layer orelse continue;
        const depth = layerDepth(layer_i, n_layers);

        for (tiles) |st| {
            const tl = st.tile.layer(source_layer) orelse continue;
            const rect = st.id.worldRect();
            const tile_span = rect.x1 - rect.x0;
            // Reference px per world unit at the view zoom (dash cutting).
            const px_per_unit = 512.0 * std.math.pow(f64, 2.0, view.zoom);

            const first_index: u32 = @intCast(indices.items.len);
            const first_vert: u32 = @intCast(verts.items.len);
            var all_opaque = true;

            for (tl.features) |*f| {
                var mf = MvtFeature{ .layer = tl, .feature = f };
                ctx.feature = mf.ref();
                if (sl.filter) |flt| {
                    if (!eval_mod.evalFilter(arena, flt.root, &ctx)) continue;
                }

                const before: u32 = @intCast(verts.items.len);
                var color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
                switch (sl.kind) {
                    .fill => {
                        if (f.geom_type != .polygon) continue;
                        const cv = evalProp(arena, resolveProp(sl, "fill-color").?, &ctx, .null, &out.eval_errors);
                        color = asColor(cv) orelse continue;
                        const ov = evalProp(arena, resolveProp(sl, "fill-opacity").?, &ctx, .{ .number = 1 }, &out.eval_errors);
                        color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
                        try fill.layoutPolygon(arena, f.parts, tl.extent, tile_span, .{
                            .depth = depth,
                        }, &verts, &indices);
                    },
                    .line => {
                        if (f.geom_type != .linestring and f.geom_type != .polygon) continue;
                        const cv = evalProp(arena, resolveProp(sl, "line-color").?, &ctx, .null, &out.eval_errors);
                        color = asColor(cv) orelse continue;
                        const ov = evalProp(arena, resolveProp(sl, "line-opacity").?, &ctx, .{ .number = 1 }, &out.eval_errors);
                        color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
                        const wv = evalProp(arena, resolveProp(sl, "line-width").?, &ctx, .{ .number = 1 }, &out.eval_errors);
                        const dash = dashArray(arena, resolveProp(sl, "line-dasharray"), &ctx, &out.eval_errors);
                        try line.layoutLine(arena, f.parts, tl.extent, tile_span, px_per_unit, .{
                            .width_px = @floatCast(asNum(wv, 1)),
                            .cap = capOf(sl, arena, &ctx, &out.eval_errors),
                            .join = joinOf(sl, arena, &ctx, &out.eval_errors),
                            .dasharray = dash,
                            .closed = f.geom_type == .polygon,
                            .depth = depth,
                        }, &verts, &indices);
                    },
                    else => unreachable,
                }

                // Stream B + single-origin rebase for the new vertices.
                const added = verts.items.len - before;
                if (added == 0) continue;
                const rgba = color.rgba8();
                if (rgba[3] != OPAQUE_ALPHA) all_opaque = false;
                try paint.ensureUnusedCapacity(arena, added);
                for (0..added) |_| paint.appendAssumeCapacity(.{ .color = rgba });
                const dx: f32 = @floatCast(rect.x0 - view.origin.x);
                const dy: f32 = @floatCast(rect.y0 - view.origin.y);
                for (verts.items[before..]) |*v| {
                    v.x += dx;
                    v.y += dy;
                }
            }

            const count: u32 = @intCast(indices.items.len - first_index);
            _ = first_vert;
            if (count == 0) continue;
            try ranges.append(arena, .{
                .first = first_index,
                .count = count,
                .paint_key = @intCast(layer_i),
                .kind = if (sl.kind == .fill) .area else .line,
                .prim = .triangles,
                .flags = if (sl.kind == .fill and all_opaque) types.Range.FLAG_OPAQUE else 0,
            });
        }
    }

    out.vertices = verts.items;
    out.paint = paint.items;
    out.indices = indices.items;
    out.ranges = ranges.items;
    return out;
}

fn dashArray(
    arena: std.mem.Allocator,
    pv: ?styles.PropValue,
    ctx: *eval_mod.Context,
    errors: *usize,
) []const f32 {
    const v = evalProp(arena, pv orelse return &.{}, ctx, .null, errors);
    const items = switch (v) {
        .array => |items| items,
        else => return &.{},
    };
    const dashes = arena.alloc(f32, items.len) catch return &.{};
    for (items, 0..) |it, i| {
        dashes[i] = switch (it) {
            .number => |n| @floatCast(n),
            else => return &.{},
        };
    }
    return dashes;
}

fn capOf(sl: *const styles.Layer, arena: std.mem.Allocator, ctx: *eval_mod.Context, errors: *usize) line.Cap {
    const v = evalProp(arena, resolveProp(sl, "line-cap") orelse return .butt, ctx, .null, errors);
    const s = switch (v) {
        .string => |s| s,
        else => return .butt,
    };
    if (std.mem.eql(u8, s, "round")) return .round;
    if (std.mem.eql(u8, s, "square")) return .square;
    return .butt;
}

fn joinOf(sl: *const styles.Layer, arena: std.mem.Allocator, ctx: *eval_mod.Context, errors: *usize) line.Join {
    const v = evalProp(arena, resolveProp(sl, "line-join") orelse return .miter, ctx, .null, errors);
    const s = switch (v) {
        .string => |s| s,
        else => return .miter,
    };
    if (std.mem.eql(u8, s, "round")) return .round;
    if (std.mem.eql(u8, s, "bevel")) return .bevel;
    return .miter;
}

// ---- tests -----------------------------------------------------------------

const test_style_json =
    \\{
    \\  "version": 8,
    \\  "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
    \\  "layers": [
    \\    {"id": "bg", "type": "background",
    \\     "paint": {"background-color": "#112233"}},
    \\    {"id": "water", "type": "fill", "source": "chart", "source-layer": "areas",
    \\     "filter": ["==", ["get", "kind"], "water"],
    \\     "paint": {"fill-color": ["match", ["get", "depth_band"],
    \\                "deep", "#0000ff", "shallow", "#8888ff", "#ff00ff"]}},
    \\    {"id": "edges", "type": "line", "source": "chart", "source-layer": "lines",
    \\     "paint": {"line-color": "#00ff00", "line-width": 2}}
    \\  ]
    \\}
;

fn testTile(a: std.mem.Allocator) !mvt.Tile {
    // areas: one water polygon (deep), one land polygon (filtered out);
    // lines: one 2-point linestring.
    // Clockwise in y-down coords = positive ringArea2 = an exterior ring.
    const square = try a.dupe(mvt.Point, &.{
        .{ .x = 0, .y = 0 }, .{ .x = 4096, .y = 0 }, .{ .x = 4096, .y = 4096 }, .{ .x = 0, .y = 4096 },
    });
    const tri = try a.dupe(mvt.Point, &.{
        .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 300 }, .{ .x = 300, .y = 100 },
    });
    const seg = try a.dupe(mvt.Point, &.{ .{ .x = 0, .y = 0 }, .{ .x = 4096, .y = 4096 } });

    const area_layer = mvt.Layer{
        .name = "areas",
        .keys = try a.dupe([]const u8, &.{ "kind", "depth_band" }),
        .values = try a.dupe(mvt.Value, &.{ .{ .string = "water" }, .{ .string = "deep" }, .{ .string = "land" } }),
        .features = try a.dupe(mvt.Feature, &.{
            .{ .geom_type = .polygon, .parts = try a.dupe([]const mvt.Point, &.{square}), .tags = try a.dupe(u32, &.{ 0, 0, 1, 1 }) },
            .{ .geom_type = .polygon, .parts = try a.dupe([]const mvt.Point, &.{tri}), .tags = try a.dupe(u32, &.{ 0, 2 }) },
        }),
    };
    const line_layer = mvt.Layer{
        .name = "lines",
        .features = try a.dupe(mvt.Feature, &.{
            .{ .geom_type = .linestring, .parts = try a.dupe([]const mvt.Point, &.{seg}) },
        }),
    };
    return .{ .layers = try a.dupe(mvt.Layer, &.{ area_layer, line_layer }) };
}

test "buildScene: background, filtered fill, data-driven color, line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var style = try styles.parse(std.testing.allocator, test_style_json);
    defer style.deinit();
    const tile = try testTile(a);
    const id = coord.TileId{ .z = 3, .x = 4, .y = 2 };
    const rect = id.worldRect();

    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 3,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    });

    // background resolved
    try std.testing.expectApproxEqAbs(@as(f32, 0x11) / 255.0, built.background.r, 1e-3);
    // two ranges: water fill (land filtered out) + one line
    try std.testing.expectEqual(@as(usize, 2), built.ranges.len);
    try std.testing.expectEqual(types.Kind.area, built.ranges[0].kind);
    try std.testing.expectEqual(types.Kind.line, built.ranges[1].kind);
    // the fill is one square = 2 triangles = 6 indices, all deep blue
    try std.testing.expectEqual(@as(u32, 6), built.ranges[0].count);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, built.paint[0].color);
    // paint stream parallels the vertex stream
    try std.testing.expectEqual(built.vertices.len, built.paint.len);
    // fill is opaque -> eligible for the depth pre-pass; line range is later
    // paint (higher paint_key, smaller depth)
    try std.testing.expect(built.ranges[0].flags & types.Range.FLAG_OPAQUE != 0);
    try std.testing.expect(built.ranges[0].paint_key < built.ranges[1].paint_key);
    try std.testing.expect(built.vertices[0].depth > built.vertices[built.vertices.len - 1].depth);
    // draw order sorted already
    try std.testing.expectEqual(@as(usize, 0), built.eval_errors);
}

// First light: the full pipeline — style JSON → filter/evaluate →
// tessellate → two-stream upload → Metal offscreen → pixel assertions.
// The synthetic tile is a deep-blue water square with a 2px green diagonal.
test "first light: style to pixels through the Metal backend" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpu = @import("gpu/gpu.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var style = try styles.parse(std.testing.allocator, test_style_json);
    defer style.deinit();
    const tile = try testTile(a);
    const id = coord.TileId{ .z = 3, .x = 4, .y = 2 };
    const rect = id.worldRect();
    const origin = cameras.Vec2{ .x = rect.x0, .y = rect.y0 };

    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 3,
        .origin = origin,
    });

    var g = gpu.Gpu.init(.{ .width = 256, .height = 256 }) catch return error.SkipZigTest;
    defer g.deinit();
    g.clear = .{
        .r = built.background.r,
        .g = built.background.g,
        .b = built.background.b,
        .a = built.background.a,
    };
    try g.uploadScene(a, .{
        .vertices = built.vertices,
        .paint = built.paint,
        .indices = built.indices,
        .ranges = built.ranges,
    });

    // A 256px view centered on the tile: at z3 the world is 4096 px, the
    // tile 512 px, so the view sees the tile's middle half. The diagonal
    // runs exactly through screen x == y.
    var cam = cameras.Camera{
        .origin = origin,
        .center = .{ .x = (rect.x0 + rect.x1) * 0.5, .y = (rect.y0 + rect.y1) * 0.5 },
        .zoom = 3,
        .vw = 256,
        .vh = 256,
    };
    _ = &cam;
    const u = types.Uniforms{
        .mvp = cam.mvpOrigin(origin),
        .px_to_clip = cam.pxToClip(),
        .size_scale = 1,
        .zoom = @floatFromInt(types.zq(cam.zoom)),
        .zoom_t = 0,
        .wrap_x = @floatCast(cam.center.x - origin.x),
        .rot_sin = 0,
        .rot_cos = 1,
        .color = .{ 0, 0, 0, 0 },
        .anchor_px = .{ 0, 0 },
        .cell_px = .{ 1, 1 },
    };
    const rgba = try g.renderOffscreen(a, u);
    try std.testing.expectEqual(@as(usize, 256 * 256 * 4), rgba.len);

    const px = struct {
        fn at(buf: []const u8, x: usize, y: usize) [4]u8 {
            const i = (y * 256 + x) * 4;
            return .{ buf[i], buf[i + 1], buf[i + 2], buf[i + 3] };
        }
    };
    // Off-diagonal: the deep-blue fill.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px.at(rgba, 128, 40));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px.at(rgba, 40, 200));
    // On the diagonal: the green line wins (later layer, smaller depth).
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px.at(rgba, 128, 128));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px.at(rgba, 64, 64));
}

test "buildScene: layer zoom bounds gate at fractional zoom" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "edges", "type": "line", "source": "chart",
        \\   "source-layer": "lines", "minzoom": 10.5,
        \\   "paint": {"line-color": "#00ff00"}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();
    const tile = try testTile(a);
    const id = coord.TileId{ .z = 10, .x = 0, .y = 0 };
    const rect = id.worldRect();
    const view_lo = View{ .zoom = 10.4, .origin = .{ .x = rect.x0, .y = rect.y0 } };
    const view_hi = View{ .zoom = 10.6, .origin = .{ .x = rect.x0, .y = rect.y0 } };
    const lo = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, view_lo);
    const hi = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, view_hi);
    try std.testing.expectEqual(@as(usize, 0), lo.ranges.len);
    try std.testing.expectEqual(@as(usize, 1), hi.ranges.len);
}

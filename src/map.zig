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
const symbol = @import("layout/symbol.zig");
const sprites = @import("symbol/sprite.zig");
const glyphs = @import("symbol/glyphs.zig");
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
    quads: []const types.Quad = &.{},
    quad_paint: []const types.PaintVertex = &.{},
    ranges: []const types.Range = &.{},
    background: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    /// icon-image names the sprite could not resolve, deduplicated — the
    /// missing-image hook: the host renders them (tile57_render_symbol_run
    /// for sounding digit runs), calls Sprite.addImage, and rebuilds.
    missing_images: []const []const u8 = &.{},
    /// Features that failed a paint evaluation and fell to defaults.
    eval_errors: usize = 0,
};

/// Symbol assets for the build; without them symbol layers are skipped.
pub const Assets = struct {
    sprite: ?*const sprites.Sprite = null,
    glyph_atlas: ?*const glyphs.GlyphAtlas = null,
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
    assets: Assets,
) !Built {
    var out = Built{};
    var verts: std.ArrayList(types.Vertex) = .empty;
    var paint: std.ArrayList(types.PaintVertex) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    var quads: std.ArrayList(types.Quad) = .empty;
    var quad_paint: std.ArrayList(types.PaintVertex) = .empty;
    var ranges: std.ArrayList(types.Range) = .empty;
    var missing: std.StringArrayHashMapUnmanaged(void) = .empty;
    var collider = symbol.Collider.init(arena);
    // Projection of a world anchor to reference px for collision boxes; the
    // view origin stands in for the screen center (they coincide for a
    // centered build; a live Map passes its camera center here).
    const world_to_px = 512.0 * std.math.pow(f64, 2.0, view.zoom);

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
            .symbol => if (assets.sprite == null and assets.glyph_atlas == null) continue,
            .raster => continue, // raster sources: later
        }
        const source_layer = sl.source_layer orelse continue;
        const depth = layerDepth(layer_i, n_layers);
        const band = 1.0 / @as(f32, @floatFromInt(n_layers + 1));
        const sort_prop = resolveProp(sl, if (sl.kind == .fill) "fill-sort-key" else "line-sort-key");

        for (tiles) |st| {
            const tl = st.tile.layer(source_layer) orelse continue;
            const rect = st.id.worldRect();
            const tile_span = rect.x1 - rect.x0;
            const dx: f32 = @floatCast(rect.x0 - view.origin.x);
            const dy: f32 = @floatCast(rect.y0 - view.origin.y);
            const tile_quads_first: u32 = @intCast(quads.items.len);
            var text_scratch: std.ArrayList(types.Quad) = .empty;
            var text_paint_scratch: std.ArrayList(types.PaintVertex) = .empty;
            // Reference px per world unit at the view zoom (dash cutting).
            const px_per_unit = 512.0 * std.math.pow(f64, 2.0, view.zoom);

            const first_index: u32 = @intCast(indices.items.len);
            const first_vert: u32 = @intCast(verts.items.len);
            var all_opaque = true;

            // Admit features (filter + geometry), evaluating the layer's
            // sort key; draw order within the layer is ascending key, and
            // each feature gets its own slice of the layer's depth band so
            // the opaque pre-pass preserves the same order.
            const Admitted = struct { f: *const mvt.Feature, key: f64, seq: u32 };
            var admitted: std.ArrayList(Admitted) = .empty;
            for (tl.features) |*f| {
                switch (sl.kind) {
                    .fill => if (f.geom_type != .polygon) continue,
                    .line => if (f.geom_type != .linestring and f.geom_type != .polygon) continue,
                    // point placement; symbol-placement line decoration is later work
                    .symbol => if (f.geom_type != .point) continue,
                    else => unreachable,
                }
                var mf = MvtFeature{ .layer = tl, .feature = f };
                ctx.feature = mf.ref();
                if (sl.filter) |flt| {
                    if (!eval_mod.evalFilter(arena, flt.root, &ctx)) continue;
                }
                var key: f64 = 0;
                if (sort_prop) |sp| {
                    key = asNum(evalProp(arena, sp, &ctx, .{ .number = 0 }, &out.eval_errors), 0);
                }
                try admitted.append(arena, .{ .f = f, .key = key, .seq = @intCast(admitted.items.len) });
            }
            std.mem.sort(Admitted, admitted.items, {}, struct {
                fn lt(_: void, x: Admitted, y: Admitted) bool {
                    if (x.key != y.key) return x.key < y.key;
                    return x.seq < y.seq; // stable: SENC order breaks ties
                }
            }.lt);

            const n_feat: f32 = @floatFromInt(admitted.items.len + 1);
            for (admitted.items, 0..) |adm, rank| {
                const f = adm.f;
                var mf = MvtFeature{ .layer = tl, .feature = f };
                ctx.feature = mf.ref();
                // Higher sort key draws on top: smaller depth, still inside
                // this layer's band.
                const feat_depth = depth - band * @as(f32, @floatFromInt(rank + 1)) / (n_feat + 1.0);

                const before: u32 = @intCast(verts.items.len);
                var color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
                switch (sl.kind) {
                    .symbol => {
                        try layoutSymbolFeature(arena, sl, &ctx, assets, f, .{
                            .rect = rect,
                            .dx = dx,
                            .dy = dy,
                            .tile_extent = tl.extent,
                            .world_to_px = world_to_px,
                            .view = view,
                            .depth = feat_depth,
                        }, &quads, &quad_paint, &text_scratch, &text_paint_scratch, &collider, &missing, &out.eval_errors);
                        continue;
                    },
                    .fill => {
                        // A pattern fill draws its cell texture, not a flat
                        // color; until the pattern pipeline is wired into
                        // the build, emitting it as flat color would bury
                        // the layers beneath. Skip.
                        if (sl.get("fill-pattern") != null) continue;
                        const cv = evalProp(arena, resolveProp(sl, "fill-color").?, &ctx, .null, &out.eval_errors);
                        color = asColor(cv) orelse continue;
                        const ov = evalProp(arena, resolveProp(sl, "fill-opacity").?, &ctx, .{ .number = 1 }, &out.eval_errors);
                        color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
                        try fill.layoutPolygon(arena, f.parts, tl.extent, tile_span, .{
                            .depth = feat_depth,
                        }, &verts, &indices);
                    },
                    .line => {
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
                            .depth = feat_depth,
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
                for (verts.items[before..]) |*v| {
                    v.x += dx;
                    v.y += dy;
                }
            }

            if (sl.kind == .symbol) {
                const icon_count: u32 = @intCast(quads.items.len - tile_quads_first);
                if (icon_count > 0) {
                    try ranges.append(arena, .{
                        .first = tile_quads_first,
                        .count = icon_count,
                        .paint_key = @intCast(layer_i),
                        .kind = .symbol,
                        .prim = .quads,
                        .atlas = .sprite,
                    });
                }
                if (text_scratch.items.len > 0) {
                    const text_first: u32 = @intCast(quads.items.len);
                    try quads.appendSlice(arena, text_scratch.items);
                    try quad_paint.appendSlice(arena, text_paint_scratch.items);
                    try ranges.append(arena, .{
                        .first = text_first,
                        .count = @intCast(text_scratch.items.len),
                        .paint_key = @intCast(layer_i),
                        .kind = .text,
                        .prim = .quads,
                        .atlas = .glyph,
                    });
                }
                continue;
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
    out.quads = quads.items;
    out.quad_paint = quad_paint.items;
    out.ranges = ranges.items;
    out.missing_images = missing.keys();
    return out;
}

const SymbolCtx = struct {
    rect: coord.WorldRect,
    dx: f32,
    dy: f32,
    tile_extent: u32,
    world_to_px: f64,
    view: View,
    depth: f32,
};

/// One symbol feature: resolve icon and text, collide, emit quads (already
/// rebased to the scene origin). Icons go straight to `quads`; text goes to
/// the per-tile scratch so each (layer × tile) yields one sprite range and
/// one glyph range.
fn layoutSymbolFeature(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    ctx: *eval_mod.Context,
    assets: Assets,
    f: *const mvt.Feature,
    sc: SymbolCtx,
    quads: *std.ArrayList(types.Quad),
    quad_paint: *std.ArrayList(types.PaintVertex),
    text_scratch: *std.ArrayList(types.Quad),
    text_paint_scratch: *std.ArrayList(types.PaintVertex),
    collider: *symbol.Collider,
    missing: *std.StringArrayHashMapUnmanaged(void),
    errors: *usize,
) error{OutOfMemory}!void {
    if (f.parts.len == 0 or f.parts[0].len == 0) return;
    const ext: f32 = @floatFromInt(sc.tile_extent);
    const span: f32 = @floatCast(sc.rect.x1 - sc.rect.x0);

    const allow_overlap = boolProp(sl, "icon-allow-overlap", arena, ctx, errors) or
        boolProp(sl, "text-allow-overlap", arena, ctx, errors);
    const ignore_placement = boolProp(sl, "icon-ignore-placement", arena, ctx, errors);

    for (f.parts[0]) |pt| {
        // Tile-local anchor, rebased to the scene origin.
        const ax = @as(f32, @floatFromInt(pt.x)) / ext * span + sc.dx;
        const ay = @as(f32, @floatFromInt(pt.y)) / ext * span + sc.dy;
        // Projected px for collision (view.origin is the screen center).
        const px: f32 = @floatCast(@as(f64, ax) * sc.world_to_px);
        const py: f32 = @floatCast(@as(f64, ay) * sc.world_to_px);

        var common = symbol.Common{ .x = ax, .y = ay, .depth = sc.depth };

        // ---- icon
        if (assets.sprite) |sp| icon: {
            const nv = evalProp(arena, resolveProp(sl, "icon-image") orelse break :icon, ctx, .null, errors);
            const name = switch (nv) {
                .string => |n| n,
                else => break :icon,
            };
            if (name.len == 0) break :icon;
            const icon = sp.lookup(name) orelse {
                try missing.put(arena, try arena.dupe(u8, name), {});
                break :icon;
            };
            const size: f32 = @floatCast(asNum(evalProp(arena, resolveProp(sl, "icon-size").?, ctx, .{ .number = 1 }, errors), 1));
            common.rotate_deg = @floatCast(asNum(evalProp(arena, resolveProp(sl, "icon-rotate").?, ctx, .{ .number = 0 }, errors), 0));
            if (resolveProp(sl, "icon-rotation-alignment")) |rap| {
                const rav = evalProp(arena, rap, ctx, .null, errors);
                common.map_align = rav == .string and std.mem.eql(u8, rav.string, "map");
            }
            const box = try symbol.layoutIcon(arena, icon, size, common, quads);
            const placed = try collider.place(.{
                .x0 = px + box.x0,
                .y0 = py + box.y0,
                .x1 = px + box.x1,
                .y1 = py + box.y1,
            }, allow_overlap, ignore_placement);
            if (!placed) {
                quads.shrinkRetainingCapacity(quads.items.len - 6);
            } else {
                try quad_paint.ensureUnusedCapacity(arena, 6);
                for (0..6) |_| quad_paint.appendAssumeCapacity(.{ .color = .{ 255, 255, 255, 255 } });
            }
        }

        // ---- text
        if (assets.glyph_atlas) |ga| text: {
            const tv = evalProp(arena, resolveProp(sl, "text-field") orelse break :text, ctx, .null, errors);
            const text = switch (tv) {
                .string => |t| t,
                else => break :text,
            };
            if (text.len == 0) break :text;
            const size: f32 = @floatCast(asNum(evalProp(arena, resolveProp(sl, "text-size").?, ctx, .{ .number = 16 }, errors), 16));
            var topts = symbol.TextOpts{ .size_px = size };
            if (resolveProp(sl, "text-anchor")) |apv| {
                const av = evalProp(arena, apv, ctx, .null, errors);
                if (av == .string) {
                    if (symbol.Anchor.parse(av.string)) |anch| topts.anchor = anch;
                }
            }
            if (resolveProp(sl, "text-offset")) |opv| {
                const ov = evalProp(arena, opv, ctx, .null, errors);
                if (ov == .array and ov.array.len == 2 and ov.array[0] == .number and ov.array[1] == .number) {
                    topts.offset_em = .{ @floatCast(ov.array[0].number), @floatCast(ov.array[1].number) };
                }
            }
            var tcolor: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
            if (resolveProp(sl, "text-color")) |cpv| {
                if (asColor(evalProp(arena, cpv, ctx, .null, errors))) |c| tcolor = c;
            }
            var tcommon = common;
            tcommon.rotate_deg = 0;
            tcommon.map_align = false;
            const scratch_before = text_scratch.items.len;
            const box = (try symbol.layoutText(arena, text, ga, topts, tcommon, text_scratch)) orelse break :text;
            const text_allow = boolProp(sl, "text-allow-overlap", arena, ctx, errors);
            const placed = try collider.place(.{
                .x0 = px + box.x0,
                .y0 = py + box.y0,
                .x1 = px + box.x1,
                .y1 = py + box.y1,
            }, text_allow, false);
            if (!placed) {
                text_scratch.shrinkRetainingCapacity(scratch_before);
            } else {
                const added = text_scratch.items.len - scratch_before;
                const rgba = tcolor.rgba8();
                try text_paint_scratch.ensureUnusedCapacity(arena, added);
                for (0..added) |_| text_paint_scratch.appendAssumeCapacity(.{ .color = rgba });
            }
        }
    }
}

fn boolProp(sl: *const styles.Layer, name: []const u8, arena: std.mem.Allocator, ctx: *eval_mod.Context, errors: *usize) bool {
    const pv = resolveProp(sl, name) orelse return false;
    const v = evalProp(arena, pv, ctx, .null, errors);
    return v == .boolean and v.boolean;
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
    }, .{});

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
    }, .{});

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

// The real thing: the Annapolis harbor chart (US5MD1MC) through the whole
// stack — PMTiles → MLT decode → tile57's own day style → buildScene →
// Metal — asserting the S-52 day palette's land and shallow-water fills
// dominate the frame exactly as tile57's reference render has them.
// Skips when the chart library or a GPU is absent.
test "real chart: Annapolis first light" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpu = @import("gpu/gpu.zig");
    const pmtiles = @import("source/pmtiles.zig");
    const mlt = @import("source/mlt.zig");
    const ct_build = @import("ct_build");
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;

    // The chart archive comes from the environment, never a hardcoded path.
    const chart_env = std.c.getenv("CHARTTABLE_TEST_CHART") orelse return error.SkipZigTest;
    var reader = pmtiles.Reader.open(gpa, io, std.mem.span(chart_env)) catch
        return error.SkipZigTest;
    defer reader.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // With sprite/glyph assets in the environment, use the symbol-enabled
    // style variant and load the atlases; otherwise fills and lines only.
    var assets = Assets{};
    var sprite_store: ?sprites.Sprite = null;
    defer if (sprite_store) |*sp| sp.deinit();
    var glyph_atlas: ?glyphs.GlyphAtlas = null;
    defer if (glyph_atlas) |*ga| ga.deinit();
    if (std.c.getenv("CHARTTABLE_TEST_SPRITE_DIR")) |sd| load_sprite: {
        const dir = std.mem.span(sd);
        const idx = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/sprite-mln.json", .{dir}), a, .limited(64 << 20)) catch break :load_sprite;
        const sheet = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/sprite-mln.png", .{dir}), a, .limited(256 << 20)) catch break :load_sprite;
        sprite_store = sprites.Sprite.load(gpa, idx, sheet) catch break :load_sprite;
        assets.sprite = &sprite_store.?;
    }
    if (std.c.getenv("CHARTTABLE_TEST_GLYPHS_DIR")) |gd| load_glyphs: {
        const dir = std.mem.span(gd);
        var ga = glyphs.GlyphAtlas.init(gpa, glyphs.default_width) catch break :load_glyphs;
        var loaded = false;
        for ([_][]const u8{ "0-255", "256-511" }) |range| {
            const pbf = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/Noto Sans Regular/{s}.pbf", .{ dir, range }), a, .limited(16 << 20)) catch continue;
            _ = ga.addRange(pbf) catch continue;
            loaded = true;
        }
        if (!loaded) {
            ga.deinit();
            break :load_glyphs;
        }
        glyph_atlas = ga;
        assets.glyph_atlas = &glyph_atlas.?;
    }
    const style_name: []const u8 = if (assets.sprite != null) "chart-day-style-symbols.json" else "chart-day-style.json";
    const style_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/{s}", .{ ct_build.assets_dir, style_name }),
        a,
        .limited(4 * 1024 * 1024),
    );
    var style = try styles.parse(gpa, style_json);
    defer style.deinit();

    // Annapolis harbor at z14; a 512px view spans exactly one tile width,
    // so a 3x3 neighborhood covers it with margin.
    const z: u8 = 14;
    const center_w = coord.lonLatToWorld(-76.4767, 38.9763);
    const center_tile = coord.fromWorld(center_w, z);
    var tiles: std.ArrayList(SourcedTile) = .empty;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const tx: i64 = @as(i64, center_tile.x) + dx;
            const ty: i64 = @as(i64, center_tile.y) + dy;
            if (tx < 0 or ty < 0) continue;
            const bytes = reader.getTile(a, z, @intCast(tx), @intCast(ty)) catch continue orelse continue;
            const tile = try a.create(mvt.Tile);
            tile.* = mlt.decode(a, bytes) catch continue;
            try tiles.append(a, .{
                .id = .{ .z = z, .x = @intCast(tx), .y = @intCast(ty) },
                .tile = tile,
            });
        }
    }
    try std.testing.expect(tiles.items.len >= 4); // harbor coverage exists

    const origin = cameras.Vec2{ .x = center_w[0], .y = center_w[1] };
    const built = try buildScene(a, &style, tiles.items, .{ .zoom = z, .origin = origin }, assets);
    try std.testing.expect(built.ranges.len > 10); // many styled layers drew

    var g = gpu.Gpu.init(.{ .width = 512, .height = 512 }) catch return error.SkipZigTest;
    defer g.deinit();
    g.clear = .{
        .r = built.background.r,
        .g = built.background.g,
        .b = built.background.b,
        .a = built.background.a,
    };
    if (assets.sprite) |sp| try g.uploadSpriteAtlas(sp.rgba, sp.width, sp.height);
    if (assets.glyph_atlas) |ga| {
        const rgba_atlas = try ga.toRgba(a);
        try g.uploadGlyphAtlas(rgba_atlas, ga.width, ga.height);
    }
    try g.uploadScene(a, .{
        .vertices = built.vertices,
        .paint = built.paint,
        .indices = built.indices,
        .quads = built.quads,
        .quad_paint = built.quad_paint,
        .ranges = built.ranges,
    });
    var cam = cameras.Camera{
        .origin = origin,
        .center = origin,
        .zoom = z,
        .vw = 512,
        .vh = 512,
    };
    _ = &cam;
    const u = types.Uniforms{
        .mvp = cam.mvpOrigin(origin),
        .px_to_clip = cam.pxToClip(),
        .size_scale = 1,
        .zoom = @floatFromInt(types.zq(cam.zoom)),
        .zoom_t = 0,
        .wrap_x = 0,
        .rot_sin = 0,
        .rot_cos = 1,
        .color = .{ 0, 0, 0, 0 },
        .anchor_px = .{ 0, 0 },
        .cell_px = .{ 1, 1 },
    };
    const rgba = try g.renderOffscreen(a, u);

    // The S-52 day palette colors sampled from tile57's reference render of
    // the same view: LNDARE tan and DEPVS shallow-water blue. Fills resolve
    // through the same style expressions, so matches are exact.
    var land: usize = 0;
    var water: usize = 0;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        const p = rgba[i .. i + 4];
        if (p[0] == 161 and p[1] == 150 and p[2] == 83) land += 1;
        if (p[0] == 130 and p[1] == 202 and p[2] == 255) water += 1;
    }
    const total: usize = 512 * 512;
    std.debug.print(
        "\nannapolis first light: {d} tiles, {d} ranges, {d} quad verts, {d} missing images, land {d}/{d} px, water {d}/{d} px\n",
        .{ tiles.items.len, built.ranges.len, built.quads.len, built.missing_images.len, land, total, water, total },
    );
    if (assets.sprite != null) {
        // Symbols drew, and the sounding digit runs surfaced through the
        // missing-image hook (composed at runtime by the host).
        try std.testing.expect(built.quads.len > 600);
        var saw_run = false;
        for (built.missing_images) |name| {
            if (std.mem.indexOfScalar(u8, name, ',') != null) saw_run = true;
        }
        try std.testing.expect(saw_run);
    }
    // top-colors histogram while first light stabilizes
    var hist = std.AutoHashMap(u32, u32).init(gpa);
    defer hist.deinit();
    var hi: usize = 0;
    while (hi < rgba.len) : (hi += 4) {
        const key: u32 = @as(u32, rgba[hi]) << 16 | @as(u32, rgba[hi + 1]) << 8 | rgba[hi + 2];
        const gop = try hist.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var it = hist.iterator();
    var top: [6]struct { k: u32, n: u32 } = @splat(.{ .k = 0, .n = 0 });
    while (it.next()) |kv| {
        var j: usize = 0;
        while (j < top.len) : (j += 1) {
            if (kv.value_ptr.* > top[j].n) {
                var m: usize = top.len - 1;
                while (m > j) : (m -= 1) top[m] = top[m - 1];
                top[j] = .{ .k = kv.key_ptr.*, .n = kv.value_ptr.* };
                break;
            }
        }
    }
    for (top) |t2| std.debug.print("  color #{x:0>6} x{d}\n", .{ t2.k, t2.n });
    std.Io.Dir.cwd().createDirPath(io, ct_build.out_dir) catch {};
    g.savePng(a, try std.fmt.allocPrint(a, "{s}/annapolis-charttable.png", .{ct_build.out_dir}), u) catch |e| {
        std.debug.print("savePng failed: {t}\n", .{e});
    };
    try std.testing.expect(water > total / 20); // >5% shallow-water blue
    try std.testing.expect(land > total / 50); // >2% land tan
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
    const lo = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, view_lo, .{});
    const hi = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, view_hi, .{});
    try std.testing.expectEqual(@as(usize, 0), lo.ranges.len);
    try std.testing.expectEqual(@as(usize, 1), hi.ranges.len);
}

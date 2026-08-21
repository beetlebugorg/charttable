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
const compile = @import("style/compile.zig");
const vals = @import("style/value.zig");
const mvt = @import("source/mvt.zig");
const coord = @import("source/coord.zig");
const fill = @import("layout/fill.zig");
const line = @import("layout/line.zig");
const symbol = @import("layout/symbol.zig");
const sprites = @import("symbol/sprite.zig");
const glyphs = @import("symbol/glyphs.zig");
const dem = @import("layout/dem.zig");
const types = @import("scene/types.zig");
const cameras = @import("camera.zig");

pub const Value = vals.Value;
pub const Color = vals.Color;

/// One decoded tile offered to the build.
pub const SourcedTile = struct {
    id: coord.TileId,
    tile: *const mvt.Tile,
    /// Which style source this tile came from. A layer only draws from the
    /// source it names -- without this, two vector sources that both have a
    /// layer called "contours" both render it, and the map draws the same
    /// ground twice at two resolutions.
    ///
    /// Empty means unlabeled, which matches any layer: a caller with one
    /// source has nothing to disambiguate.
    source: []const u8 = "",
};

/// The build's output: everything Gpu.SceneData borrows, plus the effective
/// background. Slices live in the arena the caller passed.
/// Where one (layer x tile) bucket's vertices sit in stream B. A zoom-only
/// paint property is the SAME value for every feature in the layer, so a
/// refill needs nothing per feature — just the span and the layer to
/// re-evaluate. Recorded only for layers that actually have one.
pub const PaintSpan = struct {
    first: u32,
    count: u32,
    layer: u32,
    /// Whether this layer's color moves with the camera. A zoom change
    /// refills only these; a setPaintProperty refills whichever layer it
    /// touched, zoom-dependent or not.
    zoom_dependent: bool,
};

pub const Built = struct {
    vertices: []const types.Vertex = &.{},
    /// MUTABLE by design: `refillPaint` rewrites it in place when the camera
    /// moves a zoom-only color, which is the whole point of keeping paint in
    /// its own stream (DESIGN.md: paint changes never re-layout).
    paint: []types.PaintVertex = &.{},
    /// The upper half of a zoom-interpolated pair: the same properties
    /// evaluated one integer zoom higher, mixed in the shader by
    /// Uniforms.zoom_t. EMPTY unless some layer's paint depends on both zoom
    /// and the feature — the only case that can be served no other way.
    paint_hi: []types.PaintVertex = &.{},
    /// The integer zoom `paint`/`paint_hi` bracket. Crossing it invalidates
    /// the pair, so the Map rebuilds.
    paint_zoom_floor: f64 = 0,
    indices: []const u32 = &.{},
    quads: []const types.Quad = &.{},
    /// MUTABLE like `paint`: a raster cross-fade rewrites the alphas of the
    /// spans in `fades` in place, frame by frame, through the same stream-B
    /// re-upload a palette flip uses.
    quad_paint: []types.PaintVertex = &.{},
    /// Quad spans a raster cross-fade animates (see RasterTile.fade). Empty
    /// on a scene with no level swap to hide.
    fades: []const QuadFade = &.{},
    ranges: []const types.Range = &.{},
    /// Area-fill pattern cells, indexed by Range.pattern.
    patterns: []const types.PatternCell = &.{},
    background: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    /// Whether a background layer actually resolved one. A build that
    /// covers only some layers (a symbols-only pass) leaves the default,
    /// and concatenation must not let that default win.
    background_set: bool = false,
    /// icon-image names the sprite could not resolve, deduplicated — the
    /// missing-image hook: the host renders them (tile57_render_symbol_run
    /// for sounding digit runs), calls Sprite.addImage, and rebuilds.
    missing_images: []const []const u8 = &.{},
    /// Features that failed a paint evaluation and fell to defaults.
    eval_errors: usize = 0,
    /// Per-layer properties the compiled tier claimed. The rest keep
    /// running through the interpreter, which is always correct.
    compiled_props: usize = 0,
    /// Spans a zoom-only paint change can refill. Empty when no layer has
    /// one, which is the common case and costs nothing to check.
    paint_spans: []const PaintSpan = &.{},
    /// The zoom `paint` currently holds values for.
    paint_zoom: f64 = 0,
    /// Some line layer's width is a zoom curve, so its offsets carry a baked
    /// slope (Vertex.wscale_q) bracketed on paint_zoom_floor — the scene
    /// goes stale when the camera's integer zoom leaves that bracket, the
    /// same staleness paint_hi has.
    width_zoom: bool = false,
};

const PaintKind = struct {
    /// The color is the same for every feature in the layer, so a refill
    /// can serve a change to it without re-running the feature loop.
    refillable: bool,
    /// ...and it moves with the camera, so a zoom change must.
    zoom_dependent: bool,
};

/// True when this line layer's width follows the camera — the case whose
/// baked offsets need a width slope (Vertex.wscale_q) so the drawn width
/// keeps following the camera BETWEEN rebuilds. Without it the width holds
/// what the build evaluated and snaps on adoption, which is the width half
/// of the zoom shake (specs/zoom-shake.md).
fn widthZoomy(sl: *const styles.Layer) bool {
    const lp = sl.get("line-width") orelse return false;
    return lp.class == .zoom_only or lp.class == .zoom_and_data;
}

/// True when this layer's color or opacity varies with BOTH zoom and the
/// feature — the case that needs the interpolated pair.
fn hasZoomAndData(sl: *const styles.Layer) bool {
    const names: [2][]const u8 = switch (sl.kind) {
        .fill => .{ "fill-color", "fill-opacity" },
        .line => .{ "line-color", "line-opacity" },
        else => return false,
    };
    for (names) |n| {
        const lp = sl.get(n) orelse continue;
        if (lp.class == .zoom_and_data) return true;
    }
    return false;
}

/// This layer's color x opacity for the feature in `ctx`, at whatever zoom
/// `ctx` carries. Used to evaluate the upper half of a zoom pair.
fn evalPaintAt(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    ctx: *eval_mod.Context,
    errors: *usize,
) ?Color {
    const color_name: []const u8 = if (sl.kind == .fill) "fill-color" else "line-color";
    const opacity_name: []const u8 = if (sl.kind == .fill) "fill-opacity" else "line-opacity";
    const cv = evalProp(arena, resolveProp(sl, color_name) orelse return null, ctx, .null, errors);
    var color = asColor(cv) orelse return null;
    const ov = evalProp(arena, resolveProp(sl, opacity_name) orelse return null, ctx, .{ .number = 1 }, errors);
    color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
    return color;
}

/// How this layer's COLOR and OPACITY behave. A feature-driven color is
/// NOT refillable: each feature has its own value, and a refill has no
/// feature to evaluate against.
///
/// line-WIDTH is deliberately not considered: width is baked into the vertex
/// offsets at layout, so it is geometry, and changing it needs a rebuild
/// like any other layout property.
fn paintKindOf(sl: *const styles.Layer) PaintKind {
    const names: [2][]const u8 = switch (sl.kind) {
        .fill => .{ "fill-color", "fill-opacity" },
        .line => .{ "line-color", "line-opacity" },
        else => return .{ .refillable = false, .zoom_dependent = false },
    };
    var zoomy = false;
    for (names) |n| {
        const lp = sl.get(n) orelse continue;
        switch (lp.class) {
            .constant => {},
            .zoom_only => zoomy = true,
            // Per-feature: a refill cannot reproduce it.
            .data_driven, .zoom_and_data => return .{ .refillable = false, .zoom_dependent = false },
        }
    }
    return .{ .refillable = true, .zoom_dependent = zoomy };
}

/// Re-evaluate the zoom-only paint of every recorded span at `zoom` and
/// rewrite stream B in place. Geometry, indices and ranges are untouched, so
/// the host re-uploads one buffer and draws — no re-tessellation, no rebuild.
///
/// Returns true when anything changed. A zoom-AND-data property is not
/// handled here: that one needs the (v@z0, v@z1) pair the shader mixes,
/// which is the paint-stream growth the style-compiler spec calls stage 4.
pub fn refillPaint(
    arena: std.mem.Allocator,
    style: *const styles.Style,
    built: *Built,
    zoom: f64,
) bool {
    return refillSpans(arena, style, built, zoom, .zoom_moved);
}

/// Refill the spans belonging to ONE layer, whatever its zoom behavior —
/// what a host's setPaintProperty needs. Returns false when that layer's
/// color is per-feature, in which case the caller must rebuild.
pub fn refillLayerPaint(
    arena: std.mem.Allocator,
    style: *const styles.Style,
    built: *Built,
    zoom: f64,
    layer: u32,
) bool {
    // The span says WHERE the layer's vertices are; whether a refill can
    // reproduce its color depends on the style as it is NOW. A host that
    // just replaced a flat color with a per-feature one has a stale span
    // claiming refillable, and honoring it would paint every feature the
    // same wrong color.
    if (layer >= style.layers.len) return false;
    if (!paintKindOf(&style.layers[layer]).refillable) return false;
    return refillSpans(arena, style, built, zoom, .{ .layer = layer });
}

const RefillWhich = union(enum) {
    zoom_moved,
    layer: u32,
};

fn refillSpans(
    arena: std.mem.Allocator,
    style: *const styles.Style,
    built: *Built,
    zoom: f64,
    which: RefillWhich,
) bool {
    if (built.paint_spans.len == 0) return false;
    if (which == .zoom_moved and zoom == built.paint_zoom) return false;
    var ctx = eval_mod.Context{ .zoom = zoom };
    var errors: usize = 0;
    var touched = false;
    for (built.paint_spans) |span| {
        switch (which) {
            .zoom_moved => if (!span.zoom_dependent) continue,
            .layer => |want| if (span.layer != want) continue,
        }
        if (span.layer >= style.layers.len) continue;
        const sl = &style.layers[span.layer];
        if (!paintKindOf(sl).refillable) continue;
        const color_name: []const u8 = if (sl.kind == .fill) "fill-color" else "line-color";
        const opacity_name: []const u8 = if (sl.kind == .fill) "fill-opacity" else "line-opacity";
        const cv = evalProp(arena, resolveProp(sl, color_name) orelse continue, &ctx, .null, &errors);
        var color = asColor(cv) orelse continue;
        const ov = evalProp(arena, resolveProp(sl, opacity_name) orelse continue, &ctx, .{ .number = 1 }, &errors);
        color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
        const rgba = color.rgba8();
        const end = @min(built.paint.len, span.first + span.count);
        for (built.paint[span.first..end]) |*pv| pv.color = rgba;
        touched = true;
    }
    if (which == .zoom_moved) built.paint_zoom = zoom;
    return touched;
}

/// One decoded raster tile offered to the build. `rgba` is borrowed for the
/// duration of the build (the tile cache owns it), and the scene borrows it
/// on through Built.patterns, so the caller must not evict it before the
/// backend has uploaded the scene.
pub const RasterTile = struct {
    id: coord.TileId,
    /// Which style source this came from, so a layer draws only its own.
    source: []const u8,
    w: u32,
    h: u32,
    rgba: []const u8,
    /// Cross-fade role for this tile's quads (specs/zoom-shake.md): when a
    /// gesture swaps a raster source's tile level, the outgoing level rides
    /// one more scene fading OUT underneath while the incoming one fades IN,
    /// instead of the whole picture snapping at adoption. The layout bakes
    /// the starting alpha (in: 0, out: opaque) and records the quad span in
    /// Built.fades; the Map animates it through the quad paint stream.
    fade: Fade = .none,

    pub const Fade = enum(u2) { none, in, out };
};

/// One quad span of Built.quads that a raster cross-fade animates, recorded
/// by the raster/DEM layout. first/count index QUAD VERTICES (6 per tile).
pub const QuadFade = struct {
    first: u32,
    count: u32,
    dir: RasterTile.Fade,
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

/// An MVT feature seen through the COMPILED tier's field interface: values
/// by pre-resolved key index, no string hashing per read. `resolve` runs
/// once per (program x tile layer); `field` runs per feature.
const MvtFields = struct {
    layer: *const mvt.Layer,
    feature: *const mvt.Feature,

    fn resolve(ctx: ?*const anyopaque, key: []const u8) u32 {
        const layer: *const mvt.Layer = @ptrCast(@alignCast(ctx.?));
        return layer.keyIndex(key) orelse compile.NO_HANDLE;
    }

    fn field(ptr: ?*const anyopaque, handle: u32) Value {
        const self: *const MvtFields = @ptrCast(@alignCast(ptr.?));
        const v = self.layer.property(self.feature, handle) orelse return .null;
        return MvtFeature.toValue(v);
    }

    fn hasField(ptr: ?*const anyopaque, handle: u32) bool {
        const self: *const MvtFields = @ptrCast(@alignCast(ptr.?));
        return self.layer.property(self.feature, handle) != null;
    }
};

/// One expression compiled for this build, plus the key handles it was last
/// bound with. Binding is per tile layer, not per feature.
const Prog = struct {
    program: compile.Program,
    handles: []u32,
    regs: []Value,
    bound: ?*const mvt.Layer = null,

    fn init(arena: std.mem.Allocator, root: *const exprs.Expr) ?Prog {
        const p = compile.compile(arena, root) catch return null;
        const handles = arena.alloc(u32, p.keyCount()) catch return null;
        const regs = arena.alloc(Value, @max(1, p.regCount())) catch return null;
        return .{ .program = p, .handles = handles, .regs = regs };
    }

    fn bind(self: *Prog, layer: *const mvt.Layer) void {
        if (self.bound == layer) return;
        self.program.bind(MvtFields.resolve, layer, self.handles);
        self.bound = layer;
    }

    fn run(self: *Prog, arena: std.mem.Allocator, fields: *const MvtFields, zoom: f64) ?Value {
        var st = compile.Run{
            .zoom = zoom,
            .fields = .{
                .ptr = fields,
                .get = MvtFields.field,
                .has = MvtFields.hasField,
                .geom = switch (fields.feature.geom_type) {
                    .point => .point,
                    .linestring => .line,
                    .polygon => .polygon,
                    .unknown => .unknown,
                },
                .id = if (fields.feature.id) |id| .{ .number = @floatFromInt(id) } else .null,
            },
            .handles = self.handles,
            .regs = self.regs,
        };
        return compile.run(arena, &self.program, &st) catch null;
    }
};

/// The compiled programs one style layer uses in the per-feature loop. Only
/// the properties that are actually hot get one; everything else keeps going
/// through the interpreter, which is always correct.
const LayerProgs = struct {
    filter: ?Prog = null,
    color: ?Prog = null,
    opacity: ?Prog = null,
    width: ?Prog = null,

    fn compileProp(arena: std.mem.Allocator, sl: *const styles.Layer, name: []const u8) ?Prog {
        const pv = resolveProp(sl, name) orelse return null;
        return switch (pv) {
            .constant => null, // already a value; nothing to run
            .expression => |p| Prog.init(arena, p.root),
        };
    }

    fn of(arena: std.mem.Allocator, sl: *const styles.Layer) LayerProgs {
        var lp = LayerProgs{};
        if (sl.filter) |f| lp.filter = Prog.init(arena, f.root);
        switch (sl.kind) {
            .fill => {
                lp.color = compileProp(arena, sl, "fill-color");
                lp.opacity = compileProp(arena, sl, "fill-opacity");
            },
            .line => {
                lp.color = compileProp(arena, sl, "line-color");
                lp.opacity = compileProp(arena, sl, "line-opacity");
                lp.width = compileProp(arena, sl, "line-width");
            },
            else => {},
        }
        return lp;
    }

    fn bind(self: *LayerProgs, layer: *const mvt.Layer) void {
        inline for (.{ "filter", "color", "opacity", "width" }) |name| {
            if (@field(self, name)) |*p| p.bind(layer);
        }
    }
};

/// Compiled property programs, kept across builds.
///
/// Compiling is not free. Profiling a pinch put 27% of layout inside
/// Prog.init/compileInto, because every build recompiled every layer -- and
/// once tile-local geometry became a PER-TILE build, that bill was paid once
/// per tile per rebuild rather than once per frame. A program depends only on
/// the style, so it belongs to the style's lifetime, not the build's.
///
/// NOT thread-safe, and it cannot be made so cheaply: `bind` writes each
/// program's key handles for the tile layer being read. One builder enters a
/// cache at a time; an async build gives each worker its own.
pub const ProgCache = struct {
    arena: std.heap.ArenaAllocator,
    /// Indexed by style-layer index. null = not compiled yet, which is
    /// distinct from compiled-to-nothing (a layer whose properties are all
    /// constants yields an empty LayerProgs, and that is worth remembering).
    entries: std.ArrayListUnmanaged(?LayerProgs) = .empty,
    /// Holds the one program the OOM path hands back unremembered.
    scratch: LayerProgs = .{},

    pub fn init(gpa: std.mem.Allocator) ProgCache {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *ProgCache, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.arena.deinit();
    }

    /// Drop everything: the programs point into the arena and the style they
    /// were compiled from is gone.
    pub fn reset(self: *ProgCache) void {
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    fn forLayer(self: *ProgCache, layer_i: usize, sl: *const styles.Layer) *LayerProgs {
        if (self.entries.items.len <= layer_i) {
            self.entries.ensureTotalCapacity(self.arena.child_allocator, layer_i + 1) catch
                return self.uncached(sl);
            while (self.entries.items.len <= layer_i) self.entries.appendAssumeCapacity(null);
        }
        const slot = &self.entries.items[layer_i];
        if (slot.* == null) slot.* = LayerProgs.of(self.arena.allocator(), sl);
        return &slot.*.?;
    }

    /// Out of memory for the cache itself: compile into the arena anyway and
    /// hand back a program that simply is not remembered. Slower, never wrong.
    fn uncached(self: *ProgCache, sl: *const styles.Layer) *LayerProgs {
        self.scratch = LayerProgs.of(self.arena.allocator(), sl);
        return &self.scratch;
    }
};

pub const LayerFilter = enum {
    all,
    /// fill, line and background: layers whose layout depends on ONE tile
    /// and nothing else, so a build of them caches per tile.
    tile_local,
    /// symbol and raster. Symbols collide against the whole resident set, so
    /// a per-tile collider would let labels overlap at every seam; raster
    /// tiles borrow image memory the tile cache owns, so caching them per
    /// tile would outlive the eviction that frees it. Both are built once
    /// over everything.
    global,

    fn admits(self: LayerFilter, kind: properties.LayerType) bool {
        const is_global = kind == .symbol or kind == .raster or
            kind == .hillshade or kind == .color_relief;
        return switch (self) {
            .all => true,
            .tile_local => !is_global,
            .global => is_global,
        };
    }
};

pub const View = struct {
    zoom: f64,
    /// World point the scene's vertex coordinates are relative to. Use the
    /// camera origin so Camera.mvpOrigin(origin) draws it directly.
    origin: cameras.Vec2,
    /// Which layers this build covers, so tile-local geometry can be built
    /// (and cached) per tile while symbols and rasters are built once over
    /// the whole resident set (DESIGN.md: "lay out per tile but PLACE
    /// globally").
    layers: LayerFilter = .all,
    /// The physical size multiplier the FRAME will draw symbols and text at
    /// (scene.Uniforms.size_scale). Layout keeps offsets unscaled — the
    /// shader applies it — but collision has to know, because a label
    /// occupies its drawn size on screen, not its authored one. Leave it at
    /// 1 and a scaled-up chart collides as if everything were small, so
    /// every label survives and they pile on top of each other.
    size_scale: f32 = 1,
    /// Run the compiled expression tier (style/compile.zig) for the
    /// properties it can claim, falling back to the interpreter for the
    /// rest. Turning it OFF must not change a single pixel; that is what
    /// the flag is for.
    compiled: bool = true,
    /// Where compiled programs live across builds. Leave it null and each
    /// build compiles its own into the build arena, which is correct and is
    /// what a one-shot render wants; a Map passes its own so a rebuild does
    /// not recompile the whole style once per tile.
    progs: ?*ProgCache = null,
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

/// Evaluate one property: through its compiled program when the compiler
/// claimed it, else through the interpreter. Both paths land on the same
/// Value (the conformance harness proves it fixture by fixture), so this is
/// a speed choice, never a semantic one.
fn runProp(
    arena: std.mem.Allocator,
    prog: *?Prog,
    fields: *const MvtFields,
    zoom: f64,
    sl: *const styles.Layer,
    name: []const u8,
    ctx: *eval_mod.Context,
    default: Value,
    errors: *usize,
) Value {
    if (prog.*) |*p| {
        if (p.run(arena, fields, zoom)) |v| {
            if (v != .null) return v;
            return default;
        }
        errors.* += 1;
        return default;
    }
    return evalProp(arena, resolveProp(sl, name).?, ctx, default, errors);
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

fn strProp(sl: *const styles.Layer, name: []const u8, arena: std.mem.Allocator, ctx: *eval_mod.Context, errors: *usize) ?[]const u8 {
    const v = evalProp(arena, resolveProp(sl, name) orelse return null, ctx, .null, errors);
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Spec symbol-placement.
const Placement = enum {
    point,
    line,
    line_center,

    fn parse(s: []const u8) Placement {
        if (std.mem.eql(u8, s, "line")) return .line;
        if (std.mem.eql(u8, s, "line-center")) return .line_center;
        return .point;
    }

    fn isLine(self: Placement) bool {
        return self != .point;
    }
};

/// Spec icon/text-rotation-alignment, with "auto" resolved: "When
/// symbol-placement is set to point, this is equivalent to viewport. When
/// set to line or line-center, this is equivalent to map."
fn mapAligned(sl: *const styles.Layer, name: []const u8, placement: Placement, arena: std.mem.Allocator, ctx: *eval_mod.Context, errors: *usize) bool {
    const s = strProp(sl, name, arena, ctx, errors) orelse "auto";
    if (std.mem.eql(u8, s, "map")) return true;
    if (std.mem.eql(u8, s, "viewport")) return false;
    return placement.isLine();
}

/// Copy one sprite cell out of the sheet as an area-fill pattern cell,
/// rescaled from atlas px to its ON-SCREEN period (scene.PatternCell: w and
/// h ARE that period). Chart pattern cells are baked at ~2.8x, so the
/// downscale is a box filter over the source footprint — a nearest-neighbor
/// pick drops whole hatch strokes at that ratio.
fn patternCell(arena: std.mem.Allocator, sp: *const sprites.Sprite, name: []const u8) ?types.PatternCell {
    const rect = sp.cell(name) orelse return null;
    if (rect.w == 0 or rect.h == 0 or !(rect.pixel_ratio > 0)) return null;
    const ratio: f64 = rect.pixel_ratio;
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(rect.w)) / ratio))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(rect.h)) / ratio))));
    const out = arena.alloc(u8, @as(usize, dw) * dh * 4) catch return null;

    for (0..dh) |dy| {
        // Source rows this destination row averages over.
        const sy0: u32 = @intFromFloat(@floor(@as(f64, @floatFromInt(dy)) * @as(f64, @floatFromInt(rect.h)) / @as(f64, @floatFromInt(dh))));
        const sy1: u32 = @max(sy0 + 1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(dy + 1)) * @as(f64, @floatFromInt(rect.h)) / @as(f64, @floatFromInt(dh))))));
        for (0..dw) |dx| {
            const sx0: u32 = @intFromFloat(@floor(@as(f64, @floatFromInt(dx)) * @as(f64, @floatFromInt(rect.w)) / @as(f64, @floatFromInt(dw))));
            const sx1: u32 = @max(sx0 + 1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(dx + 1)) * @as(f64, @floatFromInt(rect.w)) / @as(f64, @floatFromInt(dw))))));
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            var n: u32 = 0;
            var sy = sy0;
            while (sy < @min(sy1, rect.h)) : (sy += 1) {
                var sx = sx0;
                while (sx < @min(sx1, rect.w)) : (sx += 1) {
                    const off = (@as(usize, rect.y + sy) * sp.width + rect.x + sx) * 4;
                    if (off + 4 > sp.rgba.len) continue;
                    inline for (0..4) |c| acc[c] += sp.rgba[off + c];
                    n += 1;
                }
            }
            const dst = (@as(usize, dy) * dw + dx) * 4;
            if (n == 0) {
                out[dst..][0..4].* = .{ 0, 0, 0, 0 };
            } else {
                inline for (0..4) |c| out[dst + c] = @intCast(acc[c] / n);
            }
        }
    }
    return .{ .w = dw, .h = dh, .rgba = out };
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
    return buildSceneWithRasters(arena, style, tiles, &.{}, view, assets);
}

/// buildScene plus raster-source tiles. Raster layers draw in style order
/// like everything else — the style decides whether the picture sits under
/// the chart or over it, which is the whole reason it is a layer.
pub fn buildSceneWithRasters(
    arena: std.mem.Allocator,
    style: *const styles.Style,
    tiles: []const SourcedTile,
    rasters: []const RasterTile,
    view: View,
    assets: Assets,
) !Built {
    var out = Built{};
    var verts: std.ArrayList(types.Vertex) = .empty;
    var paint: std.ArrayList(types.PaintVertex) = .empty;
    var paint_hi: std.ArrayList(types.PaintVertex) = .empty;
    var any_zoom_data = false;
    const zoom_floor = @floor(view.zoom);
    var indices: std.ArrayList(u32) = .empty;
    var quads: std.ArrayList(types.Quad) = .empty;
    var quad_paint: std.ArrayList(types.PaintVertex) = .empty;
    var fades: std.ArrayList(QuadFade) = .empty;
    var ranges: std.ArrayList(types.Range) = .empty;
    var paint_spans: std.ArrayList(PaintSpan) = .empty;
    var patterns: std.ArrayList(types.PatternCell) = .empty;
    // Pattern image name -> index into `patterns`; a name that resolved to no
    // cell is remembered as NO_PATTERN so the sheet is walked once per name.
    var pattern_ids: std.StringHashMapUnmanaged(u32) = .empty;
    var missing: std.StringArrayHashMapUnmanaged(void) = .empty;
    var collider = symbol.Collider.init(arena);
    // Projection of a world anchor to reference px for collision boxes; the
    // view origin stands in for the screen center (they coincide for a
    // centered build; a live Map passes its camera center here).
    const world_to_px = 512.0 * std.math.pow(f64, 2.0, view.zoom);

    var ctx = eval_mod.Context{ .zoom = view.zoom };

    const n_layers = style.layers.len;
    for (style.layers, 0..) |*sl, layer_i| {
        if (!view.layers.admits(sl.kind)) continue;
        if (sl.minzoom) |mz| {
            if (view.zoom < mz) continue;
        }
        if (sl.maxzoom) |mz| {
            if (view.zoom >= mz) continue;
        }
        // `visibility: none` means the layer does not draw. The property was
        // parsed and stored from the start, and setVisibility wrote it, but
        // nothing read it -- so a style that switched a layer off got it
        // anyway, and charttable_set_layer_visibility did nothing at all.
        if (resolveProp(sl, "visibility")) |vis| {
            const v = evalProp(arena, vis, &ctx, .{ .string = "visible" }, &out.eval_errors);
            switch (v) {
                .string => |name| if (std.mem.eql(u8, name, "none")) continue,
                else => {},
            }
        }
        switch (sl.kind) {
            .background => {
                if (resolveProp(sl, "background-color")) |pv| {
                    const v = evalProp(arena, pv, &ctx, .null, &out.eval_errors);
                    if (asColor(v)) |c| {
                        out.background = c;
                        out.background_set = true;
                    }
                }
                continue;
            },
            .fill, .line => {},
            .symbol => if (assets.sprite == null and assets.glyph_atlas == null) continue,
            .hillshade, .color_relief => {
                try layoutDemLayer(arena, style, sl, layer_i, rasters, view, &ctx, layerDepth(layer_i, n_layers), &quads, &quad_paint, &fades, &patterns, &ranges, &out.eval_errors);
                continue;
            },
            .raster => {
                try layoutRasterLayer(arena, sl, layer_i, rasters, view, layerDepth(layer_i, n_layers), &quads, &quad_paint, &fades, &patterns, &ranges);
                continue;
            },
        }
        const source_layer = sl.source_layer orelse continue;
        const depth = layerDepth(layer_i, n_layers);
        const band = 1.0 / @as(f32, @floatFromInt(n_layers + 1));
        const sort_prop = resolveProp(sl, switch (sl.kind) {
            .fill => "fill-sort-key",
            .line => "line-sort-key",
            else => "symbol-sort-key",
        });

        // Layer-wide symbol settings: none of these are data-driven, so they
        // resolve once per layer instead of once per feature.
        var placement: Placement = .point;
        var sym: SymbolLayer = undefined;
        if (sl.kind == .symbol) {
            if (strProp(sl, "symbol-placement", arena, &ctx, &out.eval_errors)) |p| placement = Placement.parse(p);
            sym = .{
                .placement = placement,
                .spacing_px = asNum(evalProp(arena, resolveProp(sl, "symbol-spacing").?, &ctx, .{ .number = 250 }, &out.eval_errors), 250),
                .max_angle_deg = @floatCast(asNum(evalProp(arena, resolveProp(sl, "text-max-angle").?, &ctx, .{ .number = 45 }, &out.eval_errors), 45)),
                .icon_map_align = mapAligned(sl, "icon-rotation-alignment", placement, arena, &ctx, &out.eval_errors),
                .text_map_align = mapAligned(sl, "text-rotation-alignment", placement, arena, &ctx, &out.eval_errors),
                .allow_overlap = boolProp(sl, "icon-allow-overlap", arena, &ctx, &out.eval_errors) or
                    boolProp(sl, "text-allow-overlap", arena, &ctx, &out.eval_errors),
                .ignore_placement = boolProp(sl, "icon-ignore-placement", arena, &ctx, &out.eval_errors),
                .text_allow_overlap = boolProp(sl, "text-allow-overlap", arena, &ctx, &out.eval_errors),
                .halo = null,
            };
            if (sl.get("text-halo-color") != null) {
                if (asColor(evalProp(arena, resolveProp(sl, "text-halo-color").?, &ctx, .null, &out.eval_errors))) |c| sym.halo = c;
            }
        }
        // The compiled tier for this layer's hot properties. Cached across
        // builds when the caller keeps a ProgCache, because a per-tile build
        // otherwise recompiles the whole style for every tile.
        var own_progs: LayerProgs = .{};
        const progs: *LayerProgs = if (!view.compiled) &own_progs else if (view.progs) |pc|
            pc.forLayer(layer_i, sl)
        else blk: {
            own_progs = LayerProgs.of(arena, sl);
            break :blk &own_progs;
        };
        if (view.compiled) {
            inline for (.{ "filter", "color", "opacity", "width" }) |nm| {
                if (@field(progs.*, nm) != null) out.compiled_props += 1;
            }
        }

        // A pattern fill resolves its cell per feature (fill-pattern is
        // data-driven: tile57 concats "pat:" onto a feature property), so the
        // layer's triangles split into one range per distinct cell.
        const is_pattern = sl.kind == .fill and sl.get("fill-pattern") != null;
        // Only layers whose color or opacity moves with the camera alone
        // need a span; everything else is baked correctly at layout.
        const paint_kind = if (is_pattern)
            PaintKind{ .refillable = false, .zoom_dependent = false }
        else
            paintKindOf(sl);
        // A property that varies with BOTH zoom and the feature is baked as
        // a pair the shader mixes; nothing else can serve it.
        const zoom_data = !is_pattern and hasZoomAndData(sl);
        if (zoom_data) any_zoom_data = true;
        // A zoom-curve line width bakes a slope instead of a still offset,
        // and the slope is bracketed on zoom_floor like the paint pair.
        const width_zoomy = sl.kind == .line and widthZoomy(sl);
        if (width_zoomy) out.width_zoom = true;

        for (tiles) |st| {
            if (sl.source) |want| {
                if (st.source.len > 0 and !std.mem.eql(u8, want, st.source)) continue;
            }
            const tl = st.tile.layer(source_layer) orelse continue;
            // Resolve every program's key slots against THIS layer's key
            // table, once -- the whole point of compiling.
            progs.bind(tl);
            const rect = st.id.worldRect();
            const tile_span = rect.x1 - rect.x0;
            // Nearest world copy, not the canonical one. Longitude is
            // cyclic, so a tile the view wants off its left edge is fetched
            // as the wrapped column near the far right -- and placing it at
            // that column's own world position puts it on the wrong side of
            // the map. Harmless while the viewport is a sliver of the world;
            // at low zoom it scrambles the geography.
            const dx: f32 = @floatCast(cameras.wrapDx(rect.x0, view.origin.x));
            const dy: f32 = @floatCast(rect.y0 - view.origin.y);
            const tile_quads_first: u32 = @intCast(quads.items.len);
            var text_scratch: std.ArrayList(types.Quad) = .empty;
            var text_paint_scratch: std.ArrayList(types.PaintVertex) = .empty;
            // Reference px per world unit at the view zoom (dash cutting).
            const px_per_unit = 512.0 * std.math.pow(f64, 2.0, view.zoom);

            const first_index: u32 = @intCast(indices.items.len);
            const first_paint: u32 = @intCast(paint.items.len);
            var all_opaque = true;
            // Pattern-fill run state: the layer's triangles split into one
            // range per distinct cell (a draw binds exactly one cell texture).
            var run_first: u32 = first_index;
            var run_pattern: u32 = types.NO_PATTERN;

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
                    .symbol => if (placement.isLine()) {
                        if (f.geom_type != .linestring and f.geom_type != .polygon) continue;
                    } else if (f.geom_type != .point) continue,
                    else => unreachable,
                }
                var mf = MvtFeature{ .layer = tl, .feature = f };
                ctx.feature = mf.ref();
                if (sl.filter) |flt| {
                    const fields = MvtFields{ .layer = tl, .feature = f };
                    const keep = if (progs.filter) |*fp|
                        // A filter is a boolean expression; anything else is
                        // a reject, exactly as evalFilter treats it.
                        (fp.run(arena, &fields, view.zoom) orelse Value.false_).truthy()
                    else
                        eval_mod.evalFilter(arena, flt.root, &ctx);
                    if (!keep) continue;
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
                            .tile_span = tile_span,
                            .world_to_px = world_to_px,
                            .px_per_unit = px_per_unit,
                            .sym = sym,
                            .depth = feat_depth,
                            .size_scale = view.size_scale,
                            .zoom = view.zoom,
                        }, &quads, &quad_paint, &text_scratch, &text_paint_scratch, &collider, &missing, &out.eval_errors);
                        continue;
                    },
                    .fill => {
                        if (is_pattern) {
                            // The cell this feature names, resolved once per
                            // name. An unresolvable name draws NOTHING: a
                            // flat polygon would bury the fills the hatch was
                            // meant to overlay (the bug the old skip hid).
                            const want = patternFor(arena, sl, &ctx, assets, &patterns, &pattern_ids, &missing, &out.eval_errors);
                            if (want == types.NO_PATTERN) continue;
                            if (want != run_pattern and indices.items.len > run_first) {
                                try ranges.append(arena, .{
                                    .first = run_first,
                                    .count = @intCast(indices.items.len - run_first),
                                    .paint_key = @intCast(layer_i),
                                    .pattern = run_pattern,
                                    .kind = .pattern,
                                    .prim = .triangles,
                                });
                                run_first = @intCast(indices.items.len);
                            }
                            run_pattern = want;
                            // Stream B rides along to keep the two streams
                            // parallel; the pattern pipeline ignores it.
                            color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
                        } else {
                            const fields = MvtFields{ .layer = tl, .feature = f };
                            const cv = runProp(arena, &progs.color, &fields, view.zoom, sl, "fill-color", &ctx, .null, &out.eval_errors);
                            color = asColor(cv) orelse continue;
                            const ov = runProp(arena, &progs.opacity, &fields, view.zoom, sl, "fill-opacity", &ctx, .{ .number = 1 }, &out.eval_errors);
                            color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
                        }
                        try fill.layoutPolygon(arena, f.parts, tl.extent, tile_span, .{
                            .depth = feat_depth,
                        }, &verts, &indices);
                    },
                    .line => {
                        const fields = MvtFields{ .layer = tl, .feature = f };
                        const cv = runProp(arena, &progs.color, &fields, view.zoom, sl, "line-color", &ctx, .null, &out.eval_errors);
                        color = asColor(cv) orelse continue;
                        const ov = runProp(arena, &progs.opacity, &fields, view.zoom, sl, "line-opacity", &ctx, .{ .number = 1 }, &out.eval_errors);
                        color.a *= @floatCast(std.math.clamp(asNum(ov, 1), 0, 1));
                        const wv = runProp(arena, &progs.width, &fields, view.zoom, sl, "line-width", &ctx, .{ .number = 1 }, &out.eval_errors);
                        const dash = dashArray(arena, resolveProp(sl, "line-dasharray"), &ctx, &out.eval_errors);
                        const width_px = asNum(wv, 1);
                        var baked_px = width_px;
                        var wscale_q: u8 = types.WSCALE_FLAT;
                        if (width_zoomy) {
                            // The slope over the same integer bracket the
                            // paint pair uses, per feature (the curve may be
                            // data-driven too). Baked so that
                            // drawn = baked * 2^(slope * zoom_t) passes
                            // through the TRUE width at the build zoom and
                            // keeps following the camera from there.
                            const pv = resolveProp(sl, "line-width").?;
                            var lo_ctx = eval_mod.Context{ .zoom = zoom_floor };
                            lo_ctx.feature = mf.ref();
                            var hi_ctx = eval_mod.Context{ .zoom = zoom_floor + 1 };
                            hi_ctx.feature = mf.ref();
                            const w_lo = asNum(evalProp(arena, pv, &lo_ctx, .{ .number = 1 }, &out.eval_errors), 1);
                            const w_hi = asNum(evalProp(arena, pv, &hi_ctx, .{ .number = 1 }, &out.eval_errors), 1);
                            if (w_lo > 0 and w_hi > 0) {
                                wscale_q = types.wscaleQ(std.math.log2(w_hi / w_lo));
                                const s = types.wscaleS(wscale_q);
                                baked_px = width_px * std.math.exp2(-s * (view.zoom - zoom_floor));
                            }
                        }
                        try line.layoutLine(arena, f.parts, tl.extent, tile_span, px_per_unit, .{
                            .width_px = @floatCast(baked_px),
                            .wscale_q = wscale_q,
                            // The dash pattern keeps measuring the style's
                            // width: the baked correction is the shader's
                            // business, not the pattern's.
                            .dash_width_px = if (width_zoomy) @floatCast(width_px) else 0,
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
                // The pair's upper half: the same property one integer zoom
                // up. Identical to the lower half unless it is zoom-and-data,
                // so the shader's mix is a no-op for everything else.
                var rgba_hi = rgba;
                if (zoom_data) {
                    var hi_ctx = eval_mod.Context{ .zoom = zoom_floor + 1 };
                    hi_ctx.feature = mf.ref();
                    if (evalPaintAt(arena, sl, &hi_ctx, &out.eval_errors)) |c| rgba_hi = c.rgba8();
                }
                try paint.ensureUnusedCapacity(arena, added);
                try paint_hi.ensureUnusedCapacity(arena, added);
                for (0..added) |_| {
                    paint.appendAssumeCapacity(.{ .color = rgba });
                    paint_hi.appendAssumeCapacity(.{ .color = rgba_hi });
                }
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
                        .flags = if (sym.halo != null) types.Range.FLAG_HALO else 0,
                        .halo = if (sym.halo) |h| h.rgba8() else .{ 0, 0, 0, 0 },
                    });
                }
                continue;
            }
            if (paint_kind.refillable and paint.items.len > first_paint) {
                try paint_spans.append(arena, .{
                    .first = first_paint,
                    .count = @intCast(paint.items.len - first_paint),
                    .layer = @intCast(layer_i),
                    .zoom_dependent = paint_kind.zoom_dependent,
                });
            }
            const count: u32 = @intCast(indices.items.len - run_first);
            if (count == 0) continue;
            try ranges.append(arena, .{
                .first = run_first,
                .count = count,
                .paint_key = @intCast(layer_i),
                .pattern = run_pattern,
                .kind = if (is_pattern) .pattern else if (sl.kind == .fill) .area else .line,
                .prim = .triangles,
                // A pattern cell is mostly transparent: it must blend over
                // what it decorates, never join the opaque pre-pass.
                .flags = if (sl.kind == .fill and !is_pattern and all_opaque) types.Range.FLAG_OPAQUE else 0,
            });
        }
    }

    out.vertices = verts.items;
    out.paint = paint.items;
    out.paint_hi = if (any_zoom_data) paint_hi.items else &.{};
    out.paint_zoom_floor = zoom_floor;
    out.indices = indices.items;
    out.quads = quads.items;
    out.quad_paint = quad_paint.items;
    out.fades = fades.items;
    out.ranges = ranges.items;
    out.paint_spans = paint_spans.items;
    out.paint_zoom = view.zoom;
    out.patterns = patterns.items;
    out.missing_images = missing.keys();
    return out;
}

/// One raster layer: every tile of its source becomes a world-space quad
/// covering that tile's rect, sampling the tile's own image.
///
/// No new pipeline and no new vertex stream — a raster tile IS a textured
/// quad, and the sprite path already carries the antimeridian wrap and the
/// paint-order depth (lookout raster.zig's rationale). The corner offsets are
/// zero: unlike a symbol, a raster tile scales WITH the map.
///
/// Known cost: the scene borrows each image and the backend makes a texture
/// per scene rebuild, so a rebuild re-uploads every visible raster tile. The
/// fix is a texture cache keyed by tile id in the backend; until raster is
/// load-bearing, correctness first.
/// A hillshade or color-relief layer: read the DEM tiles of this layer's
/// source, turn each into an RGBA image, and hand it to the raster path as
/// though it had arrived that way. Everything a terrain layer needs is a
/// picture per tile, so nothing below the scene contract has to know that
/// terrain exists.
fn layoutDemLayer(
    arena: std.mem.Allocator,
    style: *const styles.Style,
    sl: *const styles.Layer,
    layer_i: usize,
    rasters: []const RasterTile,
    view: View,
    ctx: *eval_mod.Context,
    depth: f32,
    quads: *std.ArrayList(types.Quad),
    quad_paint: *std.ArrayList(types.PaintVertex),
    fades: *std.ArrayList(QuadFade),
    patterns: *std.ArrayList(types.PatternCell),
    ranges: *std.ArrayList(types.Range),
    errors: *usize,
) !void {
    const want_source = sl.source orelse return;
    // The encoding is a property of the SOURCE: the layer only says which
    // source to read.
    const enc = switch (style.sources.get(want_source) orelse return) {
        .raster => |r| dem.Encoding.parse(r.encoding),
        else => return,
    };

    for (rasters) |rt| {
        if (!std.mem.eql(u8, rt.source, want_source)) continue;
        if (rt.w == 0 or rt.h == 0) continue;
        if (rt.rgba.len < @as(usize, rt.w) * rt.h * 4) continue;

        const grid = dem.decode(arena, enc, rt.rgba, rt.w, rt.h) catch continue;
        const img = try arena.alloc(u8, @as(usize, rt.w) * rt.h * 4);

        switch (sl.kind) {
            .hillshade => {
                const shade = dem.HillshadeOpts{
                    .illumination_direction = @floatCast(numProp(arena, sl, "hillshade-illumination-direction", ctx, 335, errors)),
                    .exaggeration = @floatCast(numProp(arena, sl, "hillshade-exaggeration", ctx, 0.5, errors)),
                    .shadow = rgbaOf(arena, sl, "hillshade-shadow-color", ctx, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, errors),
                    .highlight = rgbaOf(arena, sl, "hillshade-highlight-color", ctx, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, errors),
                    .accent = rgbaOf(arena, sl, "hillshade-accent-color", ctx, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, errors),
                    // Slope is height over DISTANCE, so the shading needs to
                    // know what a pixel is worth on the ground.
                    .meters_per_px = dem.metersPerPixel(rt.id.z, rt.id.y, rt.w),
                };
                dem.hillshade(arena, grid, shade, img) catch continue;
            },
            .color_relief => {
                const ramp = try reliefRamp(arena, sl, ctx, errors);
                const opacity: f32 = @floatCast(numProp(arena, sl, "color-relief-opacity", ctx, 1, errors));
                dem.colorRelief(grid, ramp, opacity, img) catch continue;
            },
            else => continue,
        }

        const rect = rt.id.worldRect();
        const x0: f32 = @floatCast(cameras.wrapDx(rect.x0, view.origin.x));
        const y0: f32 = @floatCast(rect.y0 - view.origin.y);
        const x1: f32 = x0 + @as(f32, @floatCast(rect.x1 - rect.x0));
        const y1: f32 = @floatCast(rect.y1 - view.origin.y);

        const image: u32 = @intCast(patterns.items.len);
        try patterns.append(arena, .{ .w = rt.w, .h = rt.h, .rgba = img });

        const first: u32 = @intCast(quads.items.len);
        const corners = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        const uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        const order = [6]u8{ 0, 1, 2, 0, 2, 3 };
        // A fading-in tile STARTS invisible: the frame that adopts this
        // scene must look like the one before it, and only then ramp.
        const alpha: u8 = if (rt.fade == .in) 0 else 255;
        try quads.ensureUnusedCapacity(arena, 6);
        try quad_paint.ensureUnusedCapacity(arena, 6);
        for (order) |ci| {
            quads.appendAssumeCapacity(.{
                .x = corners[ci][0],
                .y = corners[ci][1],
                .ox = 0,
                .oy = 0,
                .u = uvs[ci][0],
                .v = uvs[ci][1],
                .weight = 0,
                .zmin = types.ZMIN_ALL,
                .zmax = types.ZMAX_ALL,
                .flags = 0,
                .flip = 0,
                .tangent_q = 0,
                .depth = depth,
            });
            quad_paint.appendAssumeCapacity(.{ .color = .{ 255, 255, 255, alpha } });
        }
        if (rt.fade != .none) try fades.append(arena, .{ .first = first, .count = 6, .dir = rt.fade });
        try ranges.append(arena, .{
            .first = first,
            .count = 6,
            .paint_key = @intCast(layer_i),
            .pattern = image,
            .kind = .raster,
            .prim = .quads,
            .atlas = .none,
        });
    }
}

/// Turn `color-relief-color` into a ramp. The property is an expression over
/// ELEVATION, which the expression language already exposes, so the ramp is
/// built by evaluating it at elevations chosen by the ramp builder.
const ReliefCtx = struct {
    arena: std.mem.Allocator,
    pv: ?styles.PropValue,
    ctx: *eval_mod.Context,
    errors: *usize,

    fn colorAt(self: *const ReliefCtx, z: f32) [4]u8 {
        self.ctx.elevation = z;
        const pv = self.pv orelse return .{ 0, 0, 0, 0 };
        const c = asColor(evalProp(self.arena, pv, self.ctx, .null, self.errors)) orelse
            return .{ 0, 0, 0, 0 };
        return .{
            @intFromFloat(std.math.clamp(c.r, 0, 1) * 255 + 0.5),
            @intFromFloat(std.math.clamp(c.g, 0, 1) * 255 + 0.5),
            @intFromFloat(std.math.clamp(c.b, 0, 1) * 255 + 0.5),
            @intFromFloat(std.math.clamp(c.a, 0, 1) * 255 + 0.5),
        };
    }
};

fn reliefRamp(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    ctx: *eval_mod.Context,
    errors: *usize,
) !dem.Ramp {
    const rc = ReliefCtx{
        .arena = arena,
        .pv = resolveProp(sl, "color-relief-color"),
        .ctx = ctx,
        .errors = errors,
    };
    const saved = ctx.elevation;
    defer ctx.elevation = saved;
    // The deepest ocean to the highest ground.
    return dem.buildRamp(arena, -11000, 9000, &rc, ReliefCtx.colorAt);
}

fn numProp(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    name: []const u8,
    ctx: *eval_mod.Context,
    dflt: f64,
    errors: *usize,
) f64 {
    const pv = resolveProp(sl, name) orelse return dflt;
    return asNum(evalProp(arena, pv, ctx, .{ .number = dflt }, errors), dflt);
}

fn rgbaOf(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    name: []const u8,
    ctx: *eval_mod.Context,
    dflt: dem.Rgba,
    errors: *usize,
) dem.Rgba {
    const pv = resolveProp(sl, name) orelse return dflt;
    const c = asColor(evalProp(arena, pv, ctx, .null, errors)) orelse return dflt;
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

fn layoutRasterLayer(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    layer_i: usize,
    rasters: []const RasterTile,
    view: View,
    depth: f32,
    quads: *std.ArrayList(types.Quad),
    quad_paint: *std.ArrayList(types.PaintVertex),
    fades: *std.ArrayList(QuadFade),
    patterns: *std.ArrayList(types.PatternCell),
    ranges: *std.ArrayList(types.Range),
) !void {
    const want_source = sl.source orelse return;
    for (rasters) |rt| {
        if (!std.mem.eql(u8, rt.source, want_source)) continue;
        if (rt.w == 0 or rt.h == 0) continue;
        if (rt.rgba.len < @as(usize, rt.w) * rt.h * 4) continue;

        const rect = rt.id.worldRect();
        const x0: f32 = @floatCast(cameras.wrapDx(rect.x0, view.origin.x));
        const y0: f32 = @floatCast(rect.y0 - view.origin.y);
        const x1: f32 = x0 + @as(f32, @floatCast(rect.x1 - rect.x0));
        const y1: f32 = @floatCast(rect.y1 - view.origin.y);

        const image: u32 = @intCast(patterns.items.len);
        try patterns.append(arena, .{ .w = rt.w, .h = rt.h, .rgba = rt.rgba });

        const first: u32 = @intCast(quads.items.len);
        const corners = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        const uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        const order = [6]u8{ 0, 1, 2, 0, 2, 3 };
        // A fading-in tile STARTS invisible (see layoutDemLayer).
        const alpha: u8 = if (rt.fade == .in) 0 else 255;
        try quads.ensureUnusedCapacity(arena, 6);
        try quad_paint.ensureUnusedCapacity(arena, 6);
        for (order) |ci| {
            quads.appendAssumeCapacity(.{
                .x = corners[ci][0],
                .y = corners[ci][1],
                .ox = 0,
                .oy = 0,
                .u = uvs[ci][0],
                .v = uvs[ci][1],
                .weight = 0,
                .zmin = types.ZMIN_ALL,
                .zmax = types.ZMAX_ALL,
                .flags = 0,
                .flip = 0,
                .tangent_q = 0,
                .depth = depth,
            });
            quad_paint.appendAssumeCapacity(.{ .color = .{ 255, 255, 255, alpha } });
        }
        if (rt.fade != .none) try fades.append(arena, .{ .first = first, .count = 6, .dir = rt.fade });
        try ranges.append(arena, .{
            .first = first,
            .count = 6,
            .paint_key = @intCast(layer_i),
            .pattern = image,
            .kind = .raster,
            .prim = .quads,
        });
    }
}

/// One already-built piece of a scene, plus where it belongs relative to the
/// scene's origin. A per-tile geometry build is made with the tile's own NW
/// corner as its origin, so it is reusable at any camera position; the offset
/// is applied here, at concatenation.
pub const ScenePart = struct {
    built: Built,
    dx: f32,
    dy: f32,
};

/// Stitch pre-built parts into one scene: rebase each part's positions,
/// offset its indices and range starts, re-intern its pattern cells, then
/// STABLE-SORT the ranges by paint_key.
///
/// The sort is the whole trick. Parts come out tile-major, and draw order is
/// layer-major; sorting by paint_key restores style order, and keeping it
/// stable keeps tiles in a deterministic order within each layer so two
/// builds of the same set are byte-identical.
pub fn concatScenes(arena: std.mem.Allocator, parts: []const ScenePart) !Built {
    var out = Built{};
    var verts: std.ArrayList(types.Vertex) = .empty;
    var paint: std.ArrayList(types.PaintVertex) = .empty;
    var paint_hi: std.ArrayList(types.PaintVertex) = .empty;
    var any_hi = false;
    var indices: std.ArrayList(u32) = .empty;
    var quads: std.ArrayList(types.Quad) = .empty;
    var quad_paint: std.ArrayList(types.PaintVertex) = .empty;
    var fades: std.ArrayList(QuadFade) = .empty;
    var ranges: std.ArrayList(types.Range) = .empty;
    var patterns: std.ArrayList(types.PatternCell) = .empty;
    var spans: std.ArrayList(PaintSpan) = .empty;
    var missing: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (parts) |part| {
        const b = part.built;
        const vbase: u32 = @intCast(verts.items.len);
        const ibase: u32 = @intCast(indices.items.len);
        const qbase: u32 = @intCast(quads.items.len);
        const pbase: u32 = @intCast(patterns.items.len);
        const paint_base: u32 = @intCast(paint.items.len);

        try verts.ensureUnusedCapacity(arena, b.vertices.len);
        for (b.vertices) |v| {
            var moved = v;
            moved.x += part.dx;
            moved.y += part.dy;
            verts.appendAssumeCapacity(moved);
        }
        try quads.ensureUnusedCapacity(arena, b.quads.len);
        for (b.quads) |q| {
            var moved = q;
            moved.x += part.dx;
            moved.y += part.dy;
            quads.appendAssumeCapacity(moved);
        }
        try paint.appendSlice(arena, b.paint);
        // Parts without a pair still need their rows in the hi stream, or
        // the two streams desynchronize and every later vertex mixes with
        // someone else's color. Only a part with a REAL pair makes the
        // stream worth keeping: an empty part matching 0 == 0 must not — it
        // made every concatenated scene carry (and upload) a full duplicate
        // of stream B, and claim the integer-zoom bracket staleness that
        // pair exists to track.
        if (b.paint_hi.len > 0 and b.paint_hi.len == b.paint.len) {
            try paint_hi.appendSlice(arena, b.paint_hi);
            any_hi = true;
        } else {
            try paint_hi.appendSlice(arena, b.paint);
        }
        try quad_paint.appendSlice(arena, b.quad_paint);
        try fades.ensureUnusedCapacity(arena, b.fades.len);
        for (b.fades) |fd| {
            var moved = fd;
            moved.first += qbase;
            fades.appendAssumeCapacity(moved);
        }
        try indices.ensureUnusedCapacity(arena, b.indices.len);
        for (b.indices) |ix| indices.appendAssumeCapacity(ix + vbase);
        // The cell's PIXELS are copied, not borrowed. A part's pattern
        // cells live in that tile's bucket arena, and a bucket is freed the
        // moment its geometry goes stale -- while the scene built from it
        // may still be the one on screen, waiting for its replacement to be
        // complete. Borrowing here is a use-after-free the GPU finds first,
        // inside replaceRegion, which is a crash with no Zig frame in it.
        // Cells are a few KB at most; copying them is not worth being clever
        // about.
        try patterns.ensureUnusedCapacity(arena, b.patterns.len);
        for (b.patterns) |cell| {
            patterns.appendAssumeCapacity(.{
                .w = cell.w,
                .h = cell.h,
                .rgba = try arena.dupe(u8, cell.rgba),
            });
        }

        try ranges.ensureUnusedCapacity(arena, b.ranges.len);
        for (b.ranges) |r| {
            var moved = r;
            moved.first += switch (r.prim) {
                .triangles => ibase,
                .quads => qbase,
            };
            if (r.pattern != types.NO_PATTERN) moved.pattern = r.pattern + pbase;
            ranges.appendAssumeCapacity(moved);
        }
        try spans.ensureUnusedCapacity(arena, b.paint_spans.len);
        for (b.paint_spans) |sp| {
            var moved = sp;
            moved.first += paint_base;
            spans.appendAssumeCapacity(moved);
        }
        for (b.missing_images) |name| try missing.put(arena, name, {});
        if (b.background_set) {
            out.background = b.background;
            out.background_set = true;
        }
        out.eval_errors += b.eval_errors;
        out.compiled_props += b.compiled_props;
        out.paint_zoom = b.paint_zoom;
        out.paint_zoom_floor = b.paint_zoom_floor;
        if (b.width_zoom) out.width_zoom = true;
    }

    std.mem.sort(types.Range, ranges.items, {}, struct {
        fn lt(_: void, x: types.Range, y: types.Range) bool {
            return x.paint_key < y.paint_key;
        }
    }.lt);

    out.vertices = verts.items;
    out.paint = paint.items;
    out.paint_hi = if (any_hi) paint_hi.items else &.{};
    out.indices = indices.items;
    out.quads = quads.items;
    out.quad_paint = quad_paint.items;
    out.fades = fades.items;
    out.ranges = ranges.items;
    out.patterns = patterns.items;
    out.paint_spans = spans.items;
    out.missing_images = missing.keys();
    return out;
}

/// Resolve a pattern-fill layer's cell for the current feature, interning it
/// in the scene's pattern list. Returns NO_PATTERN when the name is empty or
/// the sprite has no such cell (the name goes to `missing` so the host's
/// missing-image hook can bake it and rebuild).
fn patternFor(
    arena: std.mem.Allocator,
    sl: *const styles.Layer,
    ctx: *eval_mod.Context,
    assets: Assets,
    patterns: *std.ArrayList(types.PatternCell),
    ids: *std.StringHashMapUnmanaged(u32),
    missing: *std.StringArrayHashMapUnmanaged(void),
    errors: *usize,
) u32 {
    const sp = assets.sprite orelse return types.NO_PATTERN;
    const name = strProp(sl, "fill-pattern", arena, ctx, errors) orelse return types.NO_PATTERN;
    if (name.len == 0) return types.NO_PATTERN;
    if (ids.get(name)) |id| return id;

    const owned = arena.dupe(u8, name) catch return types.NO_PATTERN;
    const cell = patternCell(arena, sp, name) orelse {
        missing.put(arena, owned, {}) catch {};
        ids.put(arena, owned, types.NO_PATTERN) catch {};
        return types.NO_PATTERN;
    };
    const id: u32 = @intCast(patterns.items.len);
    patterns.append(arena, cell) catch return types.NO_PATTERN;
    ids.put(arena, owned, id) catch {};
    return id;
}

/// The layer-wide symbol settings, resolved once per layer (none of these
/// are data-driven per the spec).
const SymbolLayer = struct {
    placement: Placement,
    spacing_px: f64,
    max_angle_deg: f32,
    icon_map_align: bool,
    text_map_align: bool,
    allow_overlap: bool,
    ignore_placement: bool,
    text_allow_overlap: bool,
    /// The style's text-halo-color, or null to keep the scene background.
    halo: ?Color,
};

const SymbolCtx = struct {
    rect: coord.WorldRect,
    dx: f32,
    dy: f32,
    tile_extent: u32,
    tile_span: f64,
    world_to_px: f64,
    px_per_unit: f64,
    sym: SymbolLayer,
    depth: f32,
    /// What the frame will scale symbol/text offsets by; collision boxes are
    /// measured in those drawn px.
    size_scale: f32,
    /// The build zoom: collision boxes are projected at it, and the zoom-out
    /// text gate is stated relative to it.
    zoom: f64,
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
    const allow_overlap = sc.sym.allow_overlap;
    const ignore_placement = sc.sym.ignore_placement;

    // Where this feature puts its symbols, in tile-local world units plus the
    // local tangent: one per geometry point for "point" placement, an
    // arc-length walk for "line" / "line-center".
    var anchors: std.ArrayList(symbol.Placement) = .empty;
    if (sc.sym.placement.isLine()) {
        try symbol.placeAlongLine(arena, f.parts, sc.tile_extent, sc.tile_span, .{
            .spacing_px = sc.sym.spacing_px,
            .px_per_unit = sc.px_per_unit,
            .center = sc.sym.placement == .line_center,
            .max_angle_deg = sc.sym.max_angle_deg,
            .tile_span = sc.tile_span,
        }, &anchors);
    } else {
        try anchors.ensureUnusedCapacity(arena, f.parts[0].len);
        for (f.parts[0]) |pt| anchors.appendAssumeCapacity(.{
            .x = @as(f64, @floatFromInt(pt.x)) / ext * span,
            .y = @as(f64, @floatFromInt(pt.y)) / ext * span,
            .angle = 0,
        });
    }

    for (anchors.items) |anchor| {
        // Tile-local anchor, rebased to the scene origin.
        const ax: f32 = @as(f32, @floatCast(anchor.x)) + sc.dx;
        const ay: f32 = @as(f32, @floatCast(anchor.y)) + sc.dy;
        // Projected px for collision (view.origin is the screen center).
        const px: f32 = @floatCast(@as(f64, ax) * sc.world_to_px);
        const py: f32 = @floatCast(@as(f64, ay) * sc.world_to_px);
        const tangent_deg: f32 = anchor.angle * 180.0 / std.math.pi;

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
            // A line-placed icon turns with its segment; icon-rotate is the
            // spec's extra turn on top of that.
            common.rotate_deg = tangent_deg +
                @as(f32, @floatCast(asNum(evalProp(arena, resolveProp(sl, "icon-rotate").?, ctx, .{ .number = 0 }, errors), 0)));
            common.map_align = sc.sym.icon_map_align;
            const box = try symbol.layoutIcon(arena, icon, size, common, quads);
            const placed = try collider.place(scaledBox(box, px, py, sc.size_scale), allow_overlap, ignore_placement);
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
            topts.max_width_em = @floatCast(asNum(evalProp(arena, resolveProp(sl, "text-max-width").?, ctx, .{ .number = 10 }, errors), 10));
            // text-halo-width is px; the SDF field measures distance in em-24
            // px at 1/8 per px (fontnik's radius-8, cutoff-0.25 encoding), so
            // one halo px is 24/(size*8) of the field. Clamped short of the
            // 0.5 that would flood the whole glyph cell.
            const halo_px = asNum(evalProp(arena, resolveProp(sl, "text-halo-width").?, ctx, .{ .number = 0 }, errors), 0);
            if (halo_px > 0 and size > 0) {
                topts.weight = @floatCast(@min(0.45, halo_px * 3.0 / @as(f64, size)));
            }
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
            tcommon.map_align = sc.sym.text_map_align;
            if (sc.sym.placement.isLine()) {
                // Line-following text rides its tangent, and the shader keeps
                // it upright through view rotation (the Quad.flip contract).
                tcommon.rotate_deg = tangent_deg;
                tcommon.flip = true;
                tcommon.tangent_q = symbol.tangentQ(anchor.angle);
            } else {
                tcommon.rotate_deg = 0;
            }
            const scratch_before = text_scratch.items.len;
            const box = (try symbol.layoutText(arena, text, ga, topts, tcommon, text_scratch)) orelse break :text;
            const text_allow = sc.sym.text_allow_overlap;
            const sbox = scaledBox(box, px, py, sc.size_scale);
            // An allow-overlap label always draws and is never gated; a
            // collided one also learns its zoom-out slack.
            const res = if (text_allow)
                symbol.Collider.PlaceResult{ .placed = try collider.place(sbox, true, false) }
            else
                try collider.placeWithSlack(sbox, false, false);
            if (!res.placed) {
                text_scratch.shrinkRetainingCapacity(scratch_before);
            } else {
                if (res.slack) |slack| {
                    // Collision ran at the build zoom, but the scene draws at
                    // the live zoom: zooming out converges anchors on screen
                    // while each label holds its size, so labels that cleared
                    // here can overlap before the next build lands. Raise the
                    // label's zmin to the zoom where it would first touch a
                    // neighbor; the shader hides it per frame from there.
                    // Narrow only: a window the feature already carries stays
                    // in force.
                    const zmin = types.zq(sc.zoom - slack);
                    for (text_scratch.items[scratch_before..]) |*q| q.zmin = @max(q.zmin, zmin);
                }
                const added = text_scratch.items.len - scratch_before;
                const rgba = tcolor.rgba8();
                try text_paint_scratch.ensureUnusedCapacity(arena, added);
                for (0..added) |_| text_paint_scratch.appendAssumeCapacity(.{ .color = rgba });
            }
        }
    }
}

/// A symbol's screen box: authored offsets scaled the way the frame will
/// draw them, around the projected anchor.
fn scaledBox(box: symbol.Box, px: f32, py: f32, scale: f32) symbol.Box {
    return .{
        .x0 = px + box.x0 * scale,
        .y0 = py + box.y0 * scale,
        .x1 = px + box.x1 * scale,
        .y1 = py + box.y1 * scale,
    };
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
// tessellate → two-stream upload → offscreen render → pixel assertions.
// The synthetic tile is a deep-blue water square with a 2px green diagonal.
test "first light: style to pixels through the GPU backend" {
    const gpu = @import("gpu/gpu.zig");
    if (!gpu.renders) return error.SkipZigTest;

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

/// Test helper: decode the (2*radius+1)^2 tile neighborhood around `center`
/// at zoom `z`, skipping what the archive does not hold.
fn loadTileNeighborhood(
    a: std.mem.Allocator,
    reader: *@import("source/pmtiles.zig").Reader,
    z: u8,
    center: coord.TileId,
    radius: i32,
    out: *std.ArrayList(SourcedTile),
) !void {
    const mlt = @import("source/mlt.zig");
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            const tx: i64 = @as(i64, center.x) + dx;
            const ty: i64 = @as(i64, center.y) + dy;
            if (tx < 0 or ty < 0) continue;
            const bytes = reader.getTile(a, z, @intCast(tx), @intCast(ty)) catch continue orelse continue;
            const tile = try a.create(mvt.Tile);
            tile.* = mlt.decode(a, bytes) catch continue;
            try out.append(a, .{ .id = .{ .z = z, .x = @intCast(tx), .y = @intCast(ty) }, .tile = tile });
        }
    }
}

// The real thing: the Annapolis harbor chart (US5MD1MC) through the whole
// stack — PMTiles → MLT decode → tile57's own day style → buildScene →
// the GPU — asserting the S-52 day palette's land and shallow-water fills
// dominate the frame exactly as tile57's reference render has them.
// Skips when the chart library or a GPU is absent.
test "real chart: Annapolis first light" {
    const gpu = @import("gpu/gpu.zig");
    if (!gpu.renders) return error.SkipZigTest;
    const pmtiles = @import("source/pmtiles.zig");
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
    try loadTileNeighborhood(a, &reader, z, center_tile, 1, &tiles);
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
        .patterns = built.patterns,
    });
    var cam = cameras.Camera{
        .origin = origin,
        .center = origin,
        .zoom = z,
        .vw = 512,
        .vh = 512,
    };
    _ = &cam;
    // Pattern phase: the scene origin's own screen position, so a cell tiles
    // from a fixed WORLD point and rides the map under a pan.
    const anchor = cam.worldToScreen(origin);
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
        .anchor_px = .{ @floatCast(anchor.x), @floatCast(anchor.y) },
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
        "\nannapolis first light: {d} tiles, {d} ranges, {d} quad verts, {d} patterns, {d} missing images, {d} compiled props, land {d}/{d} px, water {d}/{d} px\n",
        .{ tiles.items.len, built.ranges.len, built.quads.len, built.patterns.len, built.missing_images.len, built.compiled_props, land, total, water, total },
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

    // ---- the compiled tier is a SPEED choice, never a semantic one --------
    // The style compiler must produce the same scene as the interpreter,
    // down to the pixel. Build the same view both ways and compare the
    // buffers, then the frame.
    {
        const interp_built = try buildScene(a, &style, tiles.items, .{
            .zoom = z,
            .origin = origin,
            .compiled = false,
        }, assets);
        try std.testing.expectEqual(built.ranges.len, interp_built.ranges.len);
        try std.testing.expectEqual(built.vertices.len, interp_built.vertices.len);
        try std.testing.expectEqual(built.eval_errors, interp_built.eval_errors);
        try std.testing.expectEqualSlices(
            types.PaintVertex,
            built.paint,
            interp_built.paint,
        );
        try std.testing.expectEqualSlices(u32, built.indices, interp_built.indices);

        try g.uploadScene(a, .{
            .vertices = interp_built.vertices,
            .paint = interp_built.paint,
            .indices = interp_built.indices,
            .quads = interp_built.quads,
            .quad_paint = interp_built.quad_paint,
            .ranges = interp_built.ranges,
            .patterns = interp_built.patterns,
        });
        const interp_rgba = try g.renderOffscreen(a, u);
        try std.testing.expectEqualSlices(u8, interp_rgba, rgba);

        // And what it bought. DESIGN.md says not to start the MSL codegen
        // tier until this one is measured, so measure it: same view, same
        // tiles, layout only (no GPU), both ways.
        const clock = @import("util/clock.zig");
        const reps = 3;
        var t0 = clock.wallMs();
        for (0..reps) |_| {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            _ = try buildScene(scratch.allocator(), &style, tiles.items, .{ .zoom = z, .origin = origin, .compiled = false }, assets);
        }
        const interp_ms = clock.wallMs() - t0;
        t0 = clock.wallMs();
        for (0..reps) |_| {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            _ = try buildScene(scratch.allocator(), &style, tiles.items, .{ .zoom = z, .origin = origin, .compiled = true }, assets);
        }
        const compiled_ms = clock.wallMs() - t0;
        std.debug.print(
            "  compiled tier: {d} ranges, frame identical to the interpreter's; layout {d} ms -> {d} ms over {d} builds\n",
            .{ built.ranges.len, interp_ms, compiled_ms, reps },
        );

        // Put the compiled scene back for the rest of the test.
        try g.uploadScene(a, .{
            .vertices = built.vertices,
            .paint = built.paint,
            .indices = built.indices,
            .quads = built.quads,
            .quad_paint = built.quad_paint,
            .ranges = built.ranges,
            .patterns = built.patterns,
        });
    }

    // ---- the missing-image round trip ------------------------------------
    // What a host does with Built.missing_images: rasterize each name (the
    // real answer for a sounding run is tile57's composer, which needs
    // lookout's link — out of scope here, so every name gets the same stub
    // marker), hand it to Sprite.addImage, and rebuild. The names must then
    // resolve, the scene must grow the quads they were missing from, and the
    // sprite's generation must have moved so the host knows to re-upload.
    if (sprite_store) |*sp| {
        const gen0 = sp.generation;
        const marker = [_]u8{ 255, 0, 255, 255 } ** (16 * 16);
        var added: usize = 0;
        for (built.missing_images) |name| {
            sp.addImage(name, &marker, 16, 16, 1.0) catch continue;
            added += 1;
        }
        try std.testing.expect(added > 0);
        try std.testing.expect(sp.generation != gen0);

        const rebuilt = try buildScene(a, &style, tiles.items, .{ .zoom = z, .origin = origin }, assets);
        std.debug.print(
            "  add_image round trip: {d} names baked, missing {d} -> {d}, quads {d} -> {d}\n",
            .{ added, built.missing_images.len, rebuilt.missing_images.len, built.quads.len, rebuilt.quads.len },
        );
        try std.testing.expectEqual(@as(usize, 0), rebuilt.missing_images.len);
        try std.testing.expect(rebuilt.quads.len > built.quads.len);

        // And it renders: the grown atlas re-uploads, the scene rebuilds, and
        // the markers land where the unresolvable names used to draw nothing.
        try g.uploadSpriteAtlas(sp.rgba, sp.width, sp.height);
        try g.uploadScene(a, .{
            .vertices = rebuilt.vertices,
            .paint = rebuilt.paint,
            .indices = rebuilt.indices,
            .quads = rebuilt.quads,
            .quad_paint = rebuilt.quad_paint,
            .ranges = rebuilt.ranges,
            .patterns = rebuilt.patterns,
        });
        const rgba2 = try g.renderOffscreen(a, u);
        var markers: usize = 0;
        var mi: usize = 0;
        while (mi < rgba2.len) : (mi += 4) {
            if (rgba2[mi] == 255 and rgba2[mi + 1] == 0 and rgba2[mi + 2] == 255) markers += 1;
        }
        try std.testing.expect(markers > 0);
        g.savePng(a, try std.fmt.allocPrint(a, "{s}/annapolis-addimage.png", .{ct_build.out_dir}), u) catch {};
    }

    // ---- pattern fills over the depth areas -------------------------------
    // The sandwich the S-52 patterns need: fill-areas#oscl UNDER the hatch
    // UNDER fill-areas. A pattern layer must draw OVER the depth areas and
    // still let them through — the thing a flat-color fallback would bury,
    // which is why buildScene used to skip fill-pattern layers entirely.
    //
    // AP(OVERSC01) itself needs a MULTI-CELL bundle: tile57's baker emits the
    // OVERSC01 coverage only where a strictly finer cell also rides the tile
    // (scene/bake_enc.zig — whole-view overscale is the HUD readout's job, not
    // the hatch's), and US5MD1MC is one cell. So the assertion below covers
    // the seabed-quality patterns this archive does carry, and the OVERSC01
    // layer check arms itself automatically on a bundle that has them.
    if (assets.sprite != null) {
        const over_z: u8 = 16;
        const over_zoom: f64 = 16.0;
        var over_tiles: std.ArrayList(SourcedTile) = .empty;
        try loadTileNeighborhood(a, &reader, over_z, coord.fromWorld(center_w, over_z), 1, &over_tiles);
        try std.testing.expect(over_tiles.items.len >= 4);
        const over = try buildScene(a, &style, over_tiles.items, .{ .zoom = over_zoom, .origin = origin }, assets);

        var oscl_layer: ?u32 = null;
        for (style.layers, 0..) |*sl, li| {
            if (std.mem.eql(u8, sl.id, "overscale")) oscl_layer = @intCast(li);
        }
        var has_oscl_data = false;
        for (over_tiles.items) |st| {
            const tl = st.tile.layer("area_patterns") orelse continue;
            const ki = tl.keyIndex("pattern_name") orelse continue;
            for (tl.features) |*ft| {
                const v = tl.property(ft, ki) orelse continue;
                if (v == .string and std.mem.eql(u8, v.string, "OVERSC01")) has_oscl_data = true;
            }
        }
        var hatch_ranges: usize = 0;
        var oscl_ranges: usize = 0;
        for (over.ranges) |r| {
            if (r.kind != .pattern) continue;
            hatch_ranges += 1;
            if (oscl_layer != null and r.paint_key == oscl_layer.?) oscl_ranges += 1;
        }
        std.debug.print(
            "  z{d} patterns: {d} ranges, {d} of them pattern ({d} overscale, data {}), {d} cells\n",
            .{ over_zoom, over.ranges.len, hatch_ranges, oscl_ranges, has_oscl_data, over.patterns.len },
        );
        try std.testing.expect(hatch_ranges > 0);
        if (has_oscl_data) try std.testing.expect(oscl_ranges > 0);

        try g.uploadScene(a, .{
            .vertices = over.vertices,
            .paint = over.paint,
            .indices = over.indices,
            .quads = over.quads,
            .quad_paint = over.quad_paint,
            .ranges = over.ranges,
            .patterns = over.patterns,
        });
        var over_cam = cameras.Camera{
            .origin = origin,
            .center = origin,
            .zoom = over_zoom,
            .vw = 512,
            .vh = 512,
        };
        _ = &over_cam;
        const over_anchor = over_cam.worldToScreen(origin);
        var ou = u;
        ou.mvp = over_cam.mvpOrigin(origin);
        ou.px_to_clip = over_cam.pxToClip();
        ou.zoom = @floatFromInt(types.zq(over_zoom));
        ou.anchor_px = .{ @floatCast(over_anchor.x), @floatCast(over_anchor.y) };
        const over_rgba = try g.renderOffscreen(a, ou);
        var over_water: usize = 0;
        for (0..total) |pi| {
            const p = over_rgba[pi * 4 ..][0..4];
            if (p[0] == 130 and p[1] == 202 and p[2] == 255) over_water += 1;
        }
        // The hatch is on top of the water, not instead of it.
        try std.testing.expect(over_water > total / 10);
        g.savePng(a, try std.fmt.allocPrint(a, "{s}/annapolis-overscale.png", .{ct_build.out_dir}), ou) catch {};
    }
}

// Per-tile buckets, proven equivalent. Geometry built one tile at a time
// against the tile's OWN origin, symbols built once over all tiles (so
// collision stays global), then concatenated — must land exactly where a
// single monolithic build does.
// A property depending on BOTH zoom and the feature cannot be baked (it has
// to follow the camera) and cannot be refilled (every feature has its own
// curve). The layout brackets it at the two integer zooms and the shader
// mixes by zoom_t.
test "buildScene: a zoom-and-data color bakes the pair the shader mixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Per-feature endpoints, so it is zoom-and-data rather than zoom-only:
    // at z10 the feature's own color, at z11 black.
    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "water", "type": "fill", "source": "chart",
        \\   "source-layer": "areas",
        \\   "filter": ["==", ["get", "kind"], "water"],
        \\   "paint": {"fill-color": ["interpolate", ["linear"], ["zoom"],
        \\      10, ["match", ["get", "depth_band"], "deep", "#ffffff", "#888888"],
        \\      11, "#000000"]}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();
    try std.testing.expectEqual(
        @import("style/compile.zig").Class.zoom_and_data,
        style.layer("water").?.get("fill-color").?.class,
    );

    const tile = try testTile(a);
    const id = coord.TileId{ .z = 10, .x = 0, .y = 0 };
    const rect = id.worldRect();
    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10.0,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{});

    // The pair is present and brackets the build zoom.
    try std.testing.expectEqual(built.paint.len, built.paint_hi.len);
    try std.testing.expect(built.paint_hi.len > 0);
    try std.testing.expectEqual(@as(f64, 10), built.paint_zoom_floor);
    // Lower half: the feature's own color at z10. Upper half: black at z11.
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, built.paint[0].color);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, built.paint_hi[0].color);

    // A style with no such property carries no second stream at all — the
    // whole point of keeping it parallel instead of widening PaintVertex.
    const plain =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "water", "type": "fill", "source": "chart",
        \\   "source-layer": "areas", "paint": {"fill-color": "#00ff00"}}]}
    ;
    var style2 = try styles.parse(std.testing.allocator, plain);
    defer style2.deinit();
    const b2 = try buildScene(a, &style2, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10.0,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{});
    try std.testing.expect(b2.paint.len > 0);
    try std.testing.expectEqual(@as(usize, 0), b2.paint_hi.len);
}

// A zoom-curve line width cannot be baked still: the camera drifts from the
// build zoom for the length of a gesture, and re-baking on adoption is the
// width snap of specs/zoom-shake.md. The layout bakes a SLOPE instead
// (Vertex.wscale_q), corrected so drawn = baked * 2^(slope * zoom_t) passes
// through the true width at the build zoom.
test "buildScene: a zoom-curve line width bakes a slope through the true width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Exponential base 2 with stops 8 -> 1, 16 -> 256 is exactly w = 2^(z-8):
    // the width doubles per level, so the slope is exactly one doubling.
    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "edges", "type": "line", "source": "chart",
        \\   "source-layer": "lines",
        \\   "paint": {"line-color": "#00ff00",
        \\     "line-width": ["interpolate", ["exponential", 2], ["zoom"], 8, 1, 16, 256]}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();

    const tile = try testTile(a);
    const id = coord.TileId{ .z = 10, .x = 0, .y = 0 };
    const rect = id.worldRect();
    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10.5,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{});

    try std.testing.expect(built.width_zoom);
    try std.testing.expect(built.vertices.len >= 4);
    const v = built.vertices[0]; // the straight segment's first quad vertex
    try std.testing.expect(v.flags & types.Flags.map_align != 0);
    // Slope: log2(w(11)/w(10)) = log2(8/4) = 1 -> 128 + 32.
    try std.testing.expectEqual(types.wscaleQ(1), v.wscale_q);
    // Baked half-width: w(10.5) = 2^2.5, corrected by 2^(-1 * 0.5) -> 4 px
    // wide, 2 px half-width.
    const hw = @sqrt(@as(f64, v.ox) * v.ox + @as(f64, v.oy) * v.oy);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), hw, 1e-5);
    // ...so the width the shader draws at the build zoom is the true one.
    const t_build = 0.5;
    try std.testing.expectApproxEqAbs(
        std.math.pow(f64, 2.0, 2.5),
        2.0 * hw * std.math.exp2(types.wscaleS(v.wscale_q) * t_build),
        1e-5,
    );

    // A constant width bakes flat and claims no bracket.
    const plain =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "edges", "type": "line", "source": "chart",
        \\   "source-layer": "lines",
        \\   "paint": {"line-color": "#00ff00", "line-width": 3}}]}
    ;
    var style2 = try styles.parse(std.testing.allocator, plain);
    defer style2.deinit();
    const b2 = try buildScene(a, &style2, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10.5,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{});
    try std.testing.expect(!b2.width_zoom);
    try std.testing.expectEqual(types.WSCALE_FLAT, b2.vertices[0].wscale_q);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.5),
        @sqrt(@as(f64, b2.vertices[0].ox) * b2.vertices[0].ox + @as(f64, b2.vertices[0].oy) * b2.vertices[0].oy),
        1e-6,
    );
}

// A raster tile's cross-fade role bakes its starting alpha and records the
// quad span the Map animates: fading-in starts invisible, fading-out starts
// opaque, and the outgoing tile is listed first so it draws underneath.
test "buildSceneWithRasters: fade roles bake start alphas and record spans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const json =
        \\{"version": 8,
        \\ "sources": {"photo": {"type": "raster", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "picture", "type": "raster", "source": "photo"}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();

    const img = try a.alloc(u8, 4 * 4 * 4);
    @memset(img, 200);
    const rect = (coord.TileId{ .z = 13, .x = 100, .y = 200 }).worldRect();
    const rasters = [_]RasterTile{
        .{ .id = .{ .z = 13, .x = 100, .y = 200 }, .source = "photo", .w = 4, .h = 4, .rgba = img, .fade = .out },
        .{ .id = .{ .z = 14, .x = 200, .y = 400 }, .source = "photo", .w = 4, .h = 4, .rgba = img, .fade = .in },
        .{ .id = .{ .z = 14, .x = 201, .y = 400 }, .source = "photo", .w = 4, .h = 4, .rgba = img },
    };
    const b = try buildSceneWithRasters(a, &style, &.{}, &rasters, .{
        .zoom = 14,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{});

    try std.testing.expectEqual(@as(usize, 3 * 6), b.quads.len);
    try std.testing.expectEqual(@as(usize, 2), b.fades.len);
    // The outgoing tile came first: under the incoming one in draw order.
    try std.testing.expectEqual(RasterTile.Fade.out, b.fades[0].dir);
    try std.testing.expectEqual(@as(u32, 0), b.fades[0].first);
    try std.testing.expectEqual(@as(u32, 6), b.fades[0].count);
    try std.testing.expectEqual(@as(u8, 255), b.quad_paint[0].color[3]);
    try std.testing.expectEqual(RasterTile.Fade.in, b.fades[1].dir);
    try std.testing.expectEqual(@as(u32, 6), b.fades[1].first);
    try std.testing.expectEqual(@as(u8, 0), b.quad_paint[6].color[3]);
    // The unmarked tile is plain opaque and in no span.
    try std.testing.expectEqual(@as(u8, 255), b.quad_paint[12].color[3]);
}

test "concatScenes: per-tile geometry plus a global symbol pass equals one build" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [
        \\   {"id": "bg", "type": "background", "paint": {"background-color": "#112233"}},
        \\   {"id": "water", "type": "fill", "source": "chart", "source-layer": "areas",
        \\    "filter": ["==", ["get", "kind"], "water"],
        \\    "paint": {"fill-color": "#0000ff"}},
        \\   {"id": "edges", "type": "line", "source": "chart", "source-layer": "lines",
        \\    "paint": {"line-color": "#00ff00", "line-width": 2}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();

    const tile = try testTile(a);
    const ids = [_]coord.TileId{
        .{ .z = 10, .x = 300, .y = 400 },
        .{ .z = 10, .x = 301, .y = 400 },
        .{ .z = 10, .x = 300, .y = 401 },
    };
    var tiles: std.ArrayList(SourcedTile) = .empty;
    for (ids) |id| try tiles.append(a, .{ .id = id, .tile = &tile });

    const origin = ids[0].worldRect();
    const view = View{ .zoom = 10, .origin = .{ .x = origin.x0, .y = origin.y0 } };
    const whole = try buildScene(a, &style, tiles.items, view, .{});

    // The split build: each tile's geometry against its OWN corner, so the
    // result is reusable at any camera position.
    var parts: std.ArrayList(ScenePart) = .empty;
    for (ids) |id| {
        const rect = id.worldRect();
        var one: [1]SourcedTile = .{.{ .id = id, .tile = &tile }};
        const part = try buildScene(a, &style, &one, .{
            .zoom = 10,
            .origin = .{ .x = rect.x0, .y = rect.y0 },
            .layers = .tile_local,
        }, .{});
        try parts.append(a, .{
            .built = part,
            .dx = @floatCast(cameras.wrapDx(rect.x0, view.origin.x)),
            .dy = @floatCast(rect.y0 - view.origin.y),
        });
    }
    // Symbols once over everything, keeping one collider for the whole set.
    try parts.append(a, .{
        .built = try buildScene(a, &style, tiles.items, .{
            .zoom = 10,
            .origin = view.origin,
            .layers = .global,
        }, .{}),
        .dx = 0,
        .dy = 0,
    });
    const stitched = try concatScenes(a, parts.items);

    try std.testing.expectEqual(whole.vertices.len, stitched.vertices.len);
    try std.testing.expectEqual(whole.indices.len, stitched.indices.len);
    try std.testing.expectEqual(whole.ranges.len, stitched.ranges.len);
    try std.testing.expectEqual(whole.background.r, stitched.background.r);

    // The buffers themselves are NOT byte-identical, and must not be
    // expected to be: a monolithic build lays vertices out layer-major, a
    // stitched one tile-major. What has to match is what gets DRAWN — the
    // ranges in order, and the vertex+paint each one walks.
    const drawn = try drawSequence(a, whole);
    const drawn2 = try drawSequence(a, stitched);
    try std.testing.expectEqualSlices(u8, drawn, drawn2);

    // Ranges came out tile-major and were sorted back into style order.
    for (stitched.ranges[1..], 0..) |r, i| {
        try std.testing.expect(r.paint_key >= stitched.ranges[i].paint_key);
    }
}

/// Everything a scene draws, in order, as bytes: per range its spec, then
/// each vertex it walks paired with that vertex's paint. Two scenes with the
/// same sequence render identically however their buffers are laid out.
fn drawSequence(a: std.mem.Allocator, b: Built) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (b.ranges) |r| {
        try out.appendSlice(a, &.{ @intFromEnum(r.kind), @intFromEnum(r.prim), @intFromEnum(r.atlas), r.flags });
        try out.appendSlice(a, std.mem.asBytes(&r.paint_key));
        try out.appendSlice(a, std.mem.asBytes(&r.count));
        switch (r.prim) {
            .triangles => for (r.first..r.first + r.count) |i| {
                const ix = b.indices[i];
                try out.appendSlice(a, std.mem.asBytes(&b.vertices[ix]));
                try out.appendSlice(a, std.mem.asBytes(&b.paint[ix]));
            },
            .quads => for (r.first..r.first + r.count) |i| {
                try out.appendSlice(a, std.mem.asBytes(&b.quads[i]));
                try out.appendSlice(a, std.mem.asBytes(&b.quad_paint[i]));
            },
        }
    }
    return out.items;
}

test "buildScene: a pattern fill splits into one range per cell" {
    const png = @import("util/png.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // An 8x4 sheet holding two pattern cells: "pat:water" is the left 4x4 at
    // ratio 1 (a 4x4 on-screen period), "pat:land" the 2x2 at (4,0) at ratio
    // 2 (a 1x1 period after the rescale to screen px).
    const sheet_px = try a.alloc(u8, 8 * 4 * 4);
    @memset(sheet_px, 0);
    for (0..4) |y| for (0..4) |x| {
        sheet_px[(y * 8 + x) * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    };
    for (0..2) |y| for (4..6) |x| {
        sheet_px[(y * 8 + x) * 4 ..][0..4].* = .{ 0, 0, 255, 255 };
    };
    const sheet = try png.encode(a, sheet_px, 8, 4);
    const index =
        \\{"pat:water": {"x": 0, "y": 0, "width": 4, "height": 4, "pixelRatio": 1},
        \\ "pat:land":  {"x": 4, "y": 0, "width": 2, "height": 2, "pixelRatio": 2}}
    ;
    var sprite = try sprites.Sprite.load(std.testing.allocator, index, sheet);
    defer sprite.deinit();

    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "hatch", "type": "fill", "source": "chart",
        \\   "source-layer": "areas",
        \\   "paint": {"fill-pattern": ["concat", "pat:", ["get", "kind"]]}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();
    // Two exterior rings (clockwise in y-down), one per pattern name.
    const left = try a.dupe(mvt.Point, &.{
        .{ .x = 0, .y = 0 }, .{ .x = 2048, .y = 0 }, .{ .x = 2048, .y = 4096 }, .{ .x = 0, .y = 4096 },
    });
    const right = try a.dupe(mvt.Point, &.{
        .{ .x = 2048, .y = 0 }, .{ .x = 4096, .y = 0 }, .{ .x = 4096, .y = 4096 }, .{ .x = 2048, .y = 4096 },
    });
    const tile = mvt.Tile{ .layers = try a.dupe(mvt.Layer, &.{.{
        .name = "areas",
        .keys = try a.dupe([]const u8, &.{"kind"}),
        .values = try a.dupe(mvt.Value, &.{ .{ .string = "water" }, .{ .string = "land" } }),
        .features = try a.dupe(mvt.Feature, &.{
            .{ .geom_type = .polygon, .parts = try a.dupe([]const mvt.Point, &.{left}), .tags = try a.dupe(u32, &.{ 0, 0 }) },
            .{ .geom_type = .polygon, .parts = try a.dupe([]const mvt.Point, &.{right}), .tags = try a.dupe(u32, &.{ 0, 1 }) },
        }),
    }}) };
    const id = coord.TileId{ .z = 3, .x = 4, .y = 2 };
    const rect = id.worldRect();
    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 3,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{ .sprite = &sprite });

    // The two polygons name different cells, so the layer's triangles cannot
    // share a draw: one range each, in feature order.
    try std.testing.expectEqual(@as(usize, 2), built.patterns.len);
    try std.testing.expectEqual(@as(usize, 2), built.ranges.len);
    for (built.ranges) |r| {
        try std.testing.expectEqual(types.Kind.pattern, r.kind);
        try std.testing.expect(r.pattern != types.NO_PATTERN);
        // Mostly-transparent cells must blend, never join the opaque pre-pass.
        try std.testing.expectEqual(@as(u8, 0), r.flags & types.Range.FLAG_OPAQUE);
    }
    try std.testing.expectEqual(@as(u32, 0), built.ranges[0].pattern);
    try std.testing.expectEqual(@as(u32, 1), built.ranges[1].pattern);
    // A cell's w/h ARE its on-screen period: the ratio-2 cell halves.
    try std.testing.expectEqual(@as(u32, 4), built.patterns[0].w);
    try std.testing.expectEqual(@as(u32, 1), built.patterns[1].w);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), built.patterns[0].rgba.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, built.patterns[0].rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, built.patterns[1].rgba[0..4]);

    // An unresolvable name draws NOTHING rather than a flat polygon over the
    // fills the hatch was meant to decorate; the name surfaces for the host.
    const json_missing =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "hatch", "type": "fill", "source": "chart",
        \\   "source-layer": "areas", "paint": {"fill-pattern": "pat:absent"}}]}
    ;
    var style2 = try styles.parse(std.testing.allocator, json_missing);
    defer style2.deinit();
    const b2 = try buildScene(a, &style2, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 3,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{ .sprite = &sprite });
    try std.testing.expectEqual(@as(usize, 0), b2.ranges.len);
    try std.testing.expectEqual(@as(usize, 1), b2.missing_images.len);
    try std.testing.expectEqualStrings("pat:absent", b2.missing_images[0]);
}

// The overscale hatch, AP(OVERSC01), on charttable's side of the line.
//
// A real archive cannot exercise this: tile57's baker emits the OVERSC01
// coverage only where a strictly finer cell rides the same tile
// (scene/bake_enc.zig), and a merged multi-cell archive is not something it
// produces — a bundle is per-cell PMTiles plus a partition served by a
// runtime compositor. WHEN the feature appears is tile57's decision and is
// tested there; what charttable owns is that a feature carrying it draws as
// a pattern over the fills. So the feature is synthesized here and the
// style clause is the real one from tile57's generated style.
test "buildScene: the overscale hatch draws over the fills, not instead of them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const png = @import("util/png.zig");
    // A 4x4 cell that is mostly transparent, like a real hatch.
    const sheet_px = try a.alloc(u8, 4 * 4 * 4);
    @memset(sheet_px, 0);
    sheet_px[0..4].* = .{ 255, 0, 255, 255 };
    const sheet = try png.encode(a, sheet_px, 4, 4);
    var sprite = try sprites.Sprite.load(
        std.testing.allocator,
        "{\"pat:OVERSC01\": {\"x\": 0, \"y\": 0, \"width\": 4, \"height\": 4, \"pixelRatio\": 1}}",
        sheet,
    );
    defer sprite.deinit();

    const square = try a.dupe(mvt.Point, &.{
        .{ .x = 0, .y = 0 }, .{ .x = 4096, .y = 0 }, .{ .x = 4096, .y = 4096 }, .{ .x = 0, .y = 4096 },
    });
    const tile = mvt.Tile{ .layers = try a.dupe(mvt.Layer, &.{
        .{
            .name = "areas",
            .features = try a.dupe(mvt.Feature, &.{
                .{ .geom_type = .polygon, .parts = try a.dupe([]const mvt.Point, &.{square}) },
            }),
        },
        .{
            .name = "area_patterns",
            .keys = try a.dupe([]const u8, &.{ "pattern_name", "oz" }),
            .values = try a.dupe(mvt.Value, &.{ .{ .string = "OVERSC01" }, .{ .double = 15.23 } }),
            .features = try a.dupe(mvt.Feature, &.{
                .{
                    .geom_type = .polygon,
                    .parts = try a.dupe([]const mvt.Point, &.{square}),
                    .tags = try a.dupe(u32, &.{ 0, 0, 1, 1 }),
                },
            }),
        },
    }) };

    // The water fill under the hatch, then the overscale layer with the
    // filter tile57 generates: pattern_name == OVERSC01 AND zoom > oz.
    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [
        \\   {"id": "fill-areas", "type": "fill", "source": "chart",
        \\    "source-layer": "areas", "paint": {"fill-color": "#82caff"}},
        \\   {"id": "overscale", "type": "fill", "source": "chart",
        \\    "source-layer": "area_patterns",
        \\    "filter": ["all", ["==", ["get", "pattern_name"], "OVERSC01"],
        \\               [">", ["zoom"], ["coalesce", ["get", "oz"], 99]]],
        \\    "paint": {"fill-pattern": "pat:OVERSC01"}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();
    const id = coord.TileId{ .z = 16, .x = 0, .y = 0 };
    const rect = id.worldRect();
    const origin = cameras.Vec2{ .x = rect.x0, .y = rect.y0 };

    // Below the cell's own oz: the hatch stays off and only the fill draws.
    const under = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 15,
        .origin = origin,
    }, .{ .sprite = &sprite });
    try std.testing.expectEqual(@as(usize, 1), under.ranges.len);
    try std.testing.expectEqual(types.Kind.area, under.ranges[0].kind);

    // Past it: the hatch draws OVER the fill, and the fill is still there.
    const over = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 16,
        .origin = origin,
    }, .{ .sprite = &sprite });
    try std.testing.expectEqual(@as(usize, 2), over.ranges.len);
    try std.testing.expectEqual(types.Kind.area, over.ranges[0].kind);
    try std.testing.expectEqual(types.Kind.pattern, over.ranges[1].kind);
    // Later paint key, so it draws after the fill...
    try std.testing.expect(over.ranges[1].paint_key > over.ranges[0].paint_key);
    // ...and it must blend rather than join the opaque pre-pass, or a
    // mostly-transparent cell would bury what it decorates.
    try std.testing.expectEqual(@as(u8, 0), over.ranges[1].flags & types.Range.FLAG_OPAQUE);
    try std.testing.expect(over.ranges[0].flags & types.Range.FLAG_OPAQUE != 0);
    try std.testing.expectEqual(@as(usize, 1), over.patterns.len);
}

// A point symbol's anchor must land exactly on the feature's world
// position, with the sprite cell centered on it (the spec's default
// icon-anchor). Checked numerically rather than against tile57's `png`
// output: that tool renders tile57's OWN S-52 portrayal and takes no
// --style, so it is an oracle for fill colors (same palette, same
// expressions) and never was one for symbol geometry.
test "buildScene: a point symbol anchors exactly on its feature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const png = @import("util/png.zig");
    const sheet_px = try a.alloc(u8, 8 * 8 * 4);
    @memset(sheet_px, 255);
    const sheet = try png.encode(a, sheet_px, 8, 8);
    var sprite = try sprites.Sprite.load(
        std.testing.allocator,
        "{\"dot\": {\"x\": 0, \"y\": 0, \"width\": 8, \"height\": 8, \"pixelRatio\": 2}}",
        sheet,
    );
    defer sprite.deinit();

    // One point at a quarter across the tile, three quarters down.
    const pt = try a.dupe(mvt.Point, &.{.{ .x = 1024, .y = 3072 }});
    const tile = mvt.Tile{ .layers = try a.dupe(mvt.Layer, &.{.{
        .name = "marks",
        .features = try a.dupe(mvt.Feature, &.{
            .{ .geom_type = .point, .parts = try a.dupe([]const mvt.Point, &.{pt}) },
        }),
    }}) };

    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "marks", "type": "symbol", "source": "chart",
        \\   "source-layer": "marks",
        \\   "layout": {"icon-image": "dot", "icon-allow-overlap": true}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();

    const id = coord.TileId{ .z = 10, .x = 300, .y = 400 };
    const rect = id.worldRect();
    const span = rect.x1 - rect.x0;
    // Build against the tile's own corner so the expected anchor is exact.
    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{ .sprite = &sprite });

    try std.testing.expectEqual(@as(usize, 6), built.quads.len);
    const want_x: f32 = @floatCast(1024.0 / 4096.0 * span);
    const want_y: f32 = @floatCast(3072.0 / 4096.0 * span);
    for (built.quads) |q| {
        // Every corner shares the anchor; only the offsets differ.
        try std.testing.expectApproxEqAbs(want_x, q.x, 1e-9);
        try std.testing.expectApproxEqAbs(want_y, q.y, 1e-9);
    }
    // 8 px at pixelRatio 2 is 4 logical px, centered: offsets span -2..+2.
    var min_ox: f32 = std.math.floatMax(f32);
    var max_ox: f32 = -std.math.floatMax(f32);
    var min_oy: f32 = std.math.floatMax(f32);
    var max_oy: f32 = -std.math.floatMax(f32);
    for (built.quads) |q| {
        min_ox = @min(min_ox, q.ox);
        max_ox = @max(max_ox, q.ox);
        min_oy = @min(min_oy, q.oy);
        max_oy = @max(max_oy, q.oy);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -2), min_ox, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), max_ox, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -2), min_oy, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), max_oy, 1e-5);
    // A point placement is viewport-aligned by default (rotation-alignment
    // "auto"), so a turning view must NOT turn it.
    for (built.quads) |q| try std.testing.expectEqual(@as(u8, 0), q.flags & types.Flags.map_align);
}

test "buildScene: line-placed symbols follow the line, point layers do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A 4x4 sheet with one 2x2 icon, so layoutIcon has something to resolve.
    const png = @import("util/png.zig");
    const sheet_px = try a.alloc(u8, 4 * 4 * 4);
    @memset(sheet_px, 255);
    const sheet = try png.encode(a, sheet_px, 4, 4);
    var sprite = try sprites.Sprite.load(
        std.testing.allocator,
        "{\"tick\": {\"x\": 0, \"y\": 0, \"width\": 2, \"height\": 2, \"pixelRatio\": 1}}",
        sheet,
    );
    defer sprite.deinit();

    // The tile's line runs corner to corner: 4096 units diagonally, which at
    // z10 is far more than one 64 px spacing, so the walk places many.
    const json =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "deco", "type": "symbol", "source": "chart",
        \\   "source-layer": "lines",
        \\   "layout": {"symbol-placement": "line", "symbol-spacing": 64,
        \\              "icon-image": "tick", "icon-allow-overlap": true,
        \\              "icon-ignore-placement": true}}]}
    ;
    var style = try styles.parse(std.testing.allocator, json);
    defer style.deinit();
    const tile = try testTile(a);
    const id = coord.TileId{ .z = 10, .x = 0, .y = 0 };
    const rect = id.worldRect();
    const built = try buildScene(a, &style, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{ .sprite = &sprite });

    try std.testing.expectEqual(@as(usize, 1), built.ranges.len);
    try std.testing.expectEqual(types.Kind.symbol, built.ranges[0].kind);
    const n_icons = built.quads.len / 6;
    try std.testing.expect(n_icons > 4);
    // Every icon is map-aligned (rotation-alignment "auto" on a line
    // placement means "map") and turned onto the 45-degree diagonal: a
    // corner offset that was (±1, ±1) unrotated has |ox| ~ 0 or ~ 1.414.
    for (built.quads) |q| {
        try std.testing.expect(q.flags & types.Flags.map_align != 0);
        try std.testing.expect(@abs(q.ox) < 1e-3 or @abs(@abs(q.ox) - std.math.sqrt2) < 1e-3);
    }
    // Anchors march along the diagonal, x == y in tile-local units.
    for (built.quads) |q| try std.testing.expectApproxEqAbs(q.x, q.y, 1e-4);

    // The same layer with point placement finds no point features here.
    const json_point =
        \\{"version": 8,
        \\ "sources": {"chart": {"type": "vector", "tiles": ["x/{z}/{x}/{y}"]}},
        \\ "layers": [{"id": "deco", "type": "symbol", "source": "chart",
        \\   "source-layer": "lines", "layout": {"icon-image": "tick"}}]}
    ;
    var style2 = try styles.parse(std.testing.allocator, json_point);
    defer style2.deinit();
    const b2 = try buildScene(a, &style2, &.{.{ .id = id, .tile = &tile }}, .{
        .zoom = 10,
        .origin = .{ .x = rect.x0, .y = rect.y0 },
    }, .{ .sprite = &sprite });
    try std.testing.expectEqual(@as(usize, 0), b2.quads.len);
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

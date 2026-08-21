//! Style-document parsing: style JSON in, typed `Style` out. Semantics per
//! the published MapLibre Style Specification (root, sources, layers pages).
//!
//! Failure policy (the graceful-degradation contract): only malformed JSON,
//! a missing/wrong `version` (the spec: "must be 8"), and a duplicate layer
//! id are hard errors. Everything else — an unknown property, an unknown
//! layer or source type, an invalid expression, a mistyped constant —
//! records a `Diagnostic` and degrades to the spec default, because
//! machine-generated styles (tile57's reference ~160 source-layers that no
//! tile carries and contain dead expression branches) must render, not
//! reject.
//!
//! Property values follow the spec's expression-detection rule: a JSON
//! array whose first element is a string naming an expression operator IS
//! an expression; every other value — including bare arrays like a
//! dasharray `[4,3]` or a font stack `["Noto Sans Regular"]` — is a
//! constant, validated against the property's tier-1 type
//! (style/properties.zig). `["literal", …]` therefore round-trips: it
//! parses as an expression and immediately folds back to a typed constant.
//! Expressions keep their parse-time `Deps`, so later compilation stages
//! classify constant / zoom-only / data-driven without re-walking trees.
//!
//! Everything a `Style` returns lives in one arena the `Style` owns;
//! `deinit` frees the lot. A parsed Style is immutable and shares freely
//! across threads.

const std = @import("std");
const exprs = @import("expr.zig");
const properties = @import("properties.zig");
const compile = @import("compile.zig");
const vals = @import("value.zig");

pub const Value = vals.Value;
pub const LayerType = properties.LayerType;

pub const Error = error{
    /// The document is not JSON, or its root is not an object.
    InvalidJson,
    /// `version` is missing or is not the number 8 (spec: "must be 8").
    WrongVersion,
    /// Two layers share an id (spec: id is a "unique layer name").
    DuplicateLayerId,
    OutOfMemory,
};

/// One degradation event. `layer` is the owning layer id ("" for root- and
/// source-scoped diagnostics), `property` the property/field involved (""
/// when not property-scoped). Messages are complete sentences fit for a
/// diagnostics channel (charttable_style_diagnostics).
pub const Diagnostic = struct {
    layer: []const u8 = "",
    property: []const u8 = "",
    message: []const u8,
};

/// Spec `vector` source (sources page). Tier 1 keeps the fields the tile
/// pipeline consumes: `url` (TileJSON/pmtiles indirection) or inline
/// `tiles` templates, the zoom window, and the spec's `encoding` hint
/// ("mvt" | "mlt") that tile57 emits.
pub const VectorSource = struct {
    url: ?[]const u8 = null,
    tiles: []const []const u8 = &.{},
    minzoom: f64 = 0, // "Defaults to 0"
    maxzoom: f64 = 22, // "Defaults to 22"
    encoding: ?[]const u8 = null, // "Defaults to \"mvt\"" when absent
};

/// Spec `raster` source. Parsed but unused until the raster pipeline lands.
pub const RasterSource = struct {
    url: ?[]const u8 = null,
    tiles: []const []const u8 = &.{},
    minzoom: f64 = 0,
    maxzoom: f64 = 22,
    tile_size: f64 = 512, // "Defaults to 512"
    /// raster-dem: the pixels are elevation, not color. Fetched and decoded
    /// exactly like a raster; only the layers reading it differ.
    dem: bool = false,
    /// How that elevation is packed ("mapbox" or "terrarium").
    encoding: ?[]const u8 = null,
};

pub const Source = union(enum) {
    vector: VectorSource,
    raster: RasterSource,
};

/// A property's value as the style set it: a typed constant (already
/// coerced — colors are Color, enums canonical) or a parsed expression
/// with its dependency set.
pub const PropValue = union(enum) {
    constant: Value,
    expression: exprs.Parsed,
};

pub const LayerProp = struct {
    /// The table entry (static lifetime): name, scope, type, default,
    /// data-driven allowance.
    prop: *const properties.Prop,
    value: PropValue,
    /// What this value varies with, from the expression's parse-time deps.
    /// Decided once here so no later stage re-walks the tree to ask: it says
    /// whether a change re-lays-out, refills the paint stream, or moves a
    /// uniform (style/compile.zig Class).
    class: compile.Class = .constant,
};

pub const Layer = struct {
    id: []const u8,
    kind: LayerType,
    source: ?[]const u8 = null,
    source_layer: ?[]const u8 = null,
    /// Fractional per the spec (tile57 emits fractional SCAMIN minzooms).
    minzoom: ?f64 = null,
    maxzoom: ?f64 = null,
    filter: ?exprs.Parsed = null,
    /// The properties the style actually set (layout + paint together;
    /// each entry's `prop.scope` says which section it came from).
    props: []const LayerProp = &.{},

    /// The style's setting for `name`, or null if unset.
    pub fn get(self: *const Layer, name: []const u8) ?*const LayerProp {
        for (self.props) |*lp| {
            if (std.mem.eql(u8, lp.prop.name, name)) return lp;
        }
        return null;
    }

    /// The effective value of `name` on this layer: the style's setting
    /// when present, else the spec default from the property table (a
    /// `.null` constant when the spec defines no default). Null only when
    /// `name` is not a tier-1 property of this layer type.
    pub fn resolved(self: *const Layer, name: []const u8) ?PropValue {
        if (self.get(name)) |lp| return lp.value;
        const p = properties.find(self.kind, name) orelse return null;
        return .{ .constant = p.default };
    }
};

pub const Style = struct {
    /// Owns every slice, node, and map below.
    arena: std.heap.ArenaAllocator,
    name: ?[]const u8 = null,
    /// Sprite base URL (string form; the array form is tier 2).
    sprite: ?[]const u8 = null,
    /// Glyph URL template with {fontstack} and {range} tokens.
    glyphs: ?[]const u8 = null,
    /// Root `metadata`, kept as raw JSON (opaque passthrough).
    metadata: ?std.json.Value = null,
    sources: std.StringArrayHashMapUnmanaged(Source) = .empty,
    /// In style order — draw order IS this order.
    layers: []const Layer = &.{},
    diagnostics: []const Diagnostic = &.{},

    pub fn deinit(self: *Style) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn layer(self: *const Style, id: []const u8) ?*const Layer {
        for (self.layers) |*l| {
            if (std.mem.eql(u8, l.id, id)) return l;
        }
        return null;
    }

    fn layerMut(self: *Style, id: []const u8) ?*Layer {
        const mutable = @constCast(self.layers);
        for (mutable) |*l| {
            if (std.mem.eql(u8, l.id, id)) return l;
        }
        return null;
    }

    pub const SetError = error{ UnknownLayer, UnknownProperty, BadValue, OutOfMemory };

    /// Replace one property's value from a JSON fragment, as the host's
    /// setPaintProperty / setLayoutProperty do. The new value is parsed the
    /// same way the document's own section was, so an expression, a legacy
    /// function and a constant all behave identically to having been written
    /// in the style file.
    ///
    /// Everything allocates in the Style's arena and the old value is
    /// ORPHANED, not freed — a host that re-sets a property thousands of
    /// times grows the arena. That is the same trade the sprite atlas makes,
    /// and it keeps every borrowed slice a caller holds valid.
    pub fn setProperty(
        self: *Style,
        layer_id: []const u8,
        name: []const u8,
        json_value: std.json.Value,
    ) SetError!void {
        const l = self.layerMut(layer_id) orelse return error.UnknownLayer;
        const prop = properties.find(l.kind, name) orelse return error.UnknownProperty;
        const a = self.arena.allocator();
        var p = P{ .a = a, .diags = .empty };
        const pv = (parsePropValue(&p, prop, layer_id, json_value) catch
            return error.OutOfMemory) orelse return error.BadValue;
        const entry = LayerProp{
            .prop = prop,
            .value = pv,
            .class = switch (pv) {
                .constant => .constant,
                .expression => |parsed| compile.Class.of(parsed.deps),
            },
        };
        // In place when the layer already set it, appended otherwise.
        for (@constCast(l.props)) |*lp| {
            if (std.mem.eql(u8, lp.prop.name, name)) {
                lp.* = entry;
                return;
            }
        }
        var grown = a.alloc(LayerProp, l.props.len + 1) catch return error.OutOfMemory;
        @memcpy(grown[0..l.props.len], l.props);
        grown[l.props.len] = entry;
        l.props = grown;
    }

    /// Replace a layer's filter wholesale, or clear it with null. THE WHOLE
    /// FILTER: there is no merge, no partial update, and no way to add one
    /// clause — say so loudly, because a host that assumes otherwise silently
    /// widens what draws (concerns C13).
    pub fn setFilter(self: *Style, layer_id: []const u8, json_filter: ?std.json.Value) SetError!void {
        const l = self.layerMut(layer_id) orelse return error.UnknownLayer;
        const j = json_filter orelse {
            l.filter = null;
            return;
        };
        const a = self.arena.allocator();
        l.filter = exprs.parse(a, j) catch return error.BadValue;
    }

    /// The spec's `visibility` layout property, which every layer type has.
    pub fn setVisibility(self: *Style, layer_id: []const u8, on: bool) SetError!void {
        return self.setProperty(layer_id, "visibility", .{
            .string = if (on) "visible" else "none",
        });
    }
};

// ---- expression detection ---------------------------------------------------

/// The spec's expression operator vocabulary (expressions page), which is
/// what makes a bare JSON array an expression rather than an array constant.
/// Deliberately the FULL published set, not just what expr.zig implements:
/// a style using ["format", …] must diagnose as an unsupported expression,
/// never silently mis-read as a constant array.
const expr_operators = std.StaticStringMap(void).initComptime(.{
    // types
    .{"array"},           .{"boolean"},       .{"collator"},    .{"format"},
    .{"image"},           .{"literal"},       .{"number"},      .{"number-format"},
    .{"object"},          .{"string"},        .{"to-boolean"},  .{"to-color"},
    .{"to-number"},       .{"to-string"},     .{"typeof"},
    // feature data
         .{"accumulated"},
    .{"feature-state"},   .{"geometry-type"}, .{"id"},          .{"line-progress"},
    .{"properties"},      .{"get"},           .{"has"},
    // lookup
            .{"at"},
    .{"in"},              .{"index-of"},      .{"slice"},       .{"length"},
    .{"global-state"},
    // decision
       .{"case"},          .{"match"},       .{"coalesce"},
    .{"=="},              .{"!="},            .{">"},           .{">="},
    .{"<"},               .{"<="},            .{"all"},         .{"any"},
    .{"!"},               .{"within"},
    // ramps, scales, curves
           .{"interpolate"}, .{"interpolate-hcl"},
    .{"interpolate-lab"}, .{"step"},
    // variable binding
             .{"let"},         .{"var"},
    // string
    .{"concat"},          .{"downcase"},      .{"upcase"},      .{"is-supported-script"},
    .{"resolved-locale"},
    // color
    .{"rgb"},           .{"rgba"},        .{"to-rgba"},
    // math
    .{"+"},               .{"-"},             .{"*"},           .{"/"},
    .{"%"},               .{"^"},             .{"abs"},         .{"acos"},
    .{"asin"},            .{"atan"},          .{"ceil"},        .{"cos"},
    .{"distance"},        .{"e"},             .{"floor"},       .{"ln"},
    .{"ln2"},             .{"log10"},         .{"log2"},        .{"max"},
    .{"min"},             .{"pi"},            .{"round"},       .{"sin"},
    .{"sqrt"},            .{"tan"},
    // camera / special
              .{"zoom"},        .{"heatmap-density"},
    .{"elevation"},
});

fn isExpressionJson(j: std.json.Value) bool {
    if (j != .array) return false;
    const items = j.array.items;
    if (items.len == 0 or items[0] != .string) return false;
    return expr_operators.get(items[0].string) != null;
}

// ---- parser ------------------------------------------------------------------

const P = struct {
    a: std.mem.Allocator,
    diags: std.ArrayList(Diagnostic) = .empty,

    fn diag(p: *P, layer_id: []const u8, property: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try p.diags.append(p.a, .{
            .layer = layer_id,
            .property = property,
            .message = try std.fmt.allocPrint(p.a, fmt, args),
        });
    }
};

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn numField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// The string items of an array field (non-string items are dropped).
fn strArrayField(p: *P, obj: std.json.ObjectMap, key: []const u8) Error![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item == .string) try out.append(p.a, item.string);
    }
    return out.items;
}

/// Convert parsed JSON to a constant Value (arrays recurse). Objects and
/// unparseable big-number strings become .null, which no property type
/// coerces — the caller diagnoses.
fn jsonToValue(a: std.mem.Allocator, j: std.json.Value) Error!Value {
    return switch (j) {
        .null, .object => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .number = @floatFromInt(i) },
        .float => |f| .{ .number = f },
        .number_string => |s| .{ .number = std.fmt.parseFloat(f64, s) catch return .null },
        .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const items = try a.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i| items[i] = try jsonToValue(a, item);
            break :blk .{ .array = items };
        },
    };
}

fn constantOrDiag(p: *P, prop: *const properties.Prop, layer_id: []const u8, v: Value) Error!?PropValue {
    if (properties.coerce(prop.value_type, v)) |c| return .{ .constant = c };
    try p.diag(layer_id, prop.name, "constant {s} does not match the property's {s} type — default applies", .{
        v.typeName(), @tagName(prop.value_type),
    });
    return null;
}

/// Classify and parse one property value per the spec's detection rule
/// (see the module doc). Null = degraded (diagnostic recorded, default
/// applies).
fn expectedType(prop: *const properties.Prop) ?@import("typecheck.zig").Type {
    const tc = @import("typecheck.zig");
    return switch (prop.value_type) {
        .number => tc.Type.number,
        .color => tc.Type.color,
        .boolean => tc.Type.boolean,
        .string => tc.Type.string,
        .enumeration => tc.Type.string,
        .number_array => |len| .{ .array = .{ .item = .number, .len = if (len) |l| l else null } },
        .string_array => .{ .array = .{ .item = .string, .len = null } },
    };
}

fn parsePropValue(p: *P, prop: *const properties.Prop, layer_id: []const u8, j: std.json.Value) Error!?PropValue {
    if (isExpressionJson(j)) {
        // Parse with the property's expected type: the typechecker then
        // applies the spec's coercion contexts (a constant hex string in a
        // color hole is a color literal) and rejects real mismatches.
        const parsed = exprs.parseWithType(p.a, j, expectedType(prop)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidExpression => {
                try p.diag(layer_id, prop.name, "invalid or unsupported expression — default applies", .{});
                return null;
            },
        };
        // A dependency-free expression folds all the way down at parse
        // (expr.zig): to every later stage it IS a constant, so type-check
        // it like one (["literal",[4,3]] lands here).
        if (!parsed.deps.any() and parsed.root.* == .literal) {
            return constantOrDiag(p, prop, layer_id, parsed.root.literal);
        }
        if (parsed.deps.feature and !prop.data_driven) {
            try p.diag(layer_id, prop.name, "feature-driven expression on a property without data-driven support — default applies", .{});
            return null;
        }
        return .{ .expression = parsed };
    }
    return constantOrDiag(p, prop, layer_id, try jsonToValue(p.a, j));
}

/// One layout/paint section: every known property parses, every unknown or
/// misplaced one diagnoses and is skipped.
fn parseSection(p: *P, list: *std.ArrayList(LayerProp), kind: LayerType, layer_id: []const u8, jv: ?std.json.Value, scope: properties.Scope) Error!void {
    const j = jv orelse return;
    if (j != .object) {
        try p.diag(layer_id, @tagName(scope), "{s} is not an object — ignored", .{@tagName(scope)});
        return;
    }
    var it = j.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const prop = properties.find(kind, key) orelse {
            try p.diag(layer_id, key, "unknown {s} property for a {s} layer — ignored", .{ @tagName(scope), @tagName(kind) });
            continue;
        };
        if (prop.scope != scope) {
            try p.diag(layer_id, key, "\"{s}\" is a {s} property (found under {s}) — ignored", .{ key, @tagName(prop.scope), @tagName(scope) });
            continue;
        }
        if (try parsePropValue(p, prop, layer_id, e.value_ptr.*)) |pv| {
            try list.append(p.a, .{
                .prop = prop,
                .value = pv,
                .class = switch (pv) {
                    .constant => .constant,
                    .expression => |parsed| compile.Class.of(parsed.deps),
                },
            });
        }
    }
}

fn parseLayer(p: *P, j: std.json.Value, index: usize, seen: *std.StringArrayHashMapUnmanaged(void)) Error!?Layer {
    if (j != .object) {
        try p.diag("", "", "layers[{d}] is not an object — skipped", .{index});
        return null;
    }
    const obj = j.object;
    const id = strField(obj, "id") orelse {
        try p.diag("", "", "layers[{d}] has no id — skipped", .{index});
        return null;
    };
    // The spec calls id a "unique layer name"; a collision is one of the
    // three hard errors (a duplicate silently shadowing would corrupt
    // set_paint_property/set_filter addressing forever after).
    if ((try seen.getOrPut(p.a, id)).found_existing) return error.DuplicateLayerId;

    const type_name = strField(obj, "type") orelse {
        try p.diag(id, "type", "layer has no type — skipped", .{});
        return null;
    };
    const kind = LayerType.parse(type_name) orelse {
        try p.diag(id, "type", "unsupported layer type \"{s}\" (tier 1: background/fill/line/symbol/raster/hillshade/color-relief) — skipped", .{type_name});
        return null;
    };

    var out = Layer{
        .id = id,
        .kind = kind,
        .source = strField(obj, "source"),
        .source_layer = strField(obj, "source-layer"),
        .minzoom = numField(obj, "minzoom"),
        .maxzoom = numField(obj, "maxzoom"),
    };

    if (obj.get("filter")) |fj| {
        out.filter = exprs.parse(p.a, fj) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidExpression => {
                // The LAYER goes, not the filter. A missing filter admits
                // everything by spec, but a BROKEN one meant to admit a few
                // features would blanket the map with the many — a
                // restricted-areas fill drawn over every polygon in its
                // source is far worse than that overlay missing.
                try p.diag(id, "filter", "invalid filter expression — layer dropped", .{});
                return null;
            },
        };
    }

    var props: std.ArrayList(LayerProp) = .empty;
    try parseSection(p, &props, kind, id, obj.get("layout"), .layout);
    try parseSection(p, &props, kind, id, obj.get("paint"), .paint);
    out.props = props.items;
    return out;
}

fn parseSource(p: *P, name: []const u8, j: std.json.Value) Error!?Source {
    if (j != .object) {
        try p.diag("", name, "source \"{s}\" is not an object — skipped", .{name});
        return null;
    }
    const obj = j.object;
    const kind = strField(obj, "type") orelse {
        try p.diag("", name, "source \"{s}\" has no type — skipped", .{name});
        return null;
    };
    if (std.mem.eql(u8, kind, "vector")) {
        var src = VectorSource{
            .url = strField(obj, "url"),
            .tiles = try strArrayField(p, obj, "tiles"),
            .encoding = strField(obj, "encoding"),
        };
        if (numField(obj, "minzoom")) |z| src.minzoom = z;
        if (numField(obj, "maxzoom")) |z| src.maxzoom = z;
        if (src.url == null and src.tiles.len == 0) {
            try p.diag("", name, "vector source \"{s}\" has neither url nor tiles — no tiles will load", .{name});
        }
        return .{ .vector = src };
    }
    if (std.mem.eql(u8, kind, "raster") or std.mem.eql(u8, kind, "raster-dem")) {
        var src = RasterSource{
            .url = strField(obj, "url"),
            .tiles = try strArrayField(p, obj, "tiles"),
            // "mapbox" unless it says otherwise, which is the spec default.
            .dem = std.mem.eql(u8, kind, "raster-dem"),
            .encoding = strField(obj, "encoding"),
        };
        if (numField(obj, "minzoom")) |z| src.minzoom = z;
        if (numField(obj, "maxzoom")) |z| src.maxzoom = z;
        if (numField(obj, "tileSize")) |ts| src.tile_size = ts;
        return .{ .raster = src };
    }
    try p.diag("", name, "unsupported source type \"{s}\" (tier 1: vector/raster/raster-dem) — skipped", .{kind});
    return null;
}

/// Parse a style document. On success the returned Style owns its arena;
/// free with `Style.deinit`. On error nothing is retained.
pub fn parse(gpa: std.mem.Allocator, json_text: []const u8) Error!Style {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Keep a private copy of the text: std.json.Value slices may point
    // into it, and the Style must outlive the caller's buffer.
    const text = try a.dupe(u8, json_text);
    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (doc != .object) return error.InvalidJson;
    const root = doc.object;

    // Root: "version — Required enum. Must be 8." The one field whose
    // absence or mismatch rejects the document.
    const ok_version = switch (root.get("version") orelse return error.WrongVersion) {
        .integer => |i| i == 8,
        .float => |f| f == 8.0,
        else => false,
    };
    if (!ok_version) return error.WrongVersion;

    var p = P{ .a = a };

    var sprite: ?[]const u8 = null;
    if (root.get("sprite")) |sv| switch (sv) {
        .string => |s| sprite = s,
        else => try p.diag("", "sprite", "sprite must be a string at tier 1 (the array form is tier 2) — ignored", .{}),
    };
    var glyphs: ?[]const u8 = null;
    if (root.get("glyphs")) |gv| switch (gv) {
        .string => |s| glyphs = s,
        else => try p.diag("", "glyphs", "glyphs must be a URL template string — ignored", .{}),
    };

    var sources: std.StringArrayHashMapUnmanaged(Source) = .empty;
    if (root.get("sources")) |sv| {
        if (sv == .object) {
            var it = sv.object.iterator();
            while (it.next()) |e| {
                if (try parseSource(&p, e.key_ptr.*, e.value_ptr.*)) |src| {
                    try sources.put(a, e.key_ptr.*, src);
                }
            }
        } else {
            try p.diag("", "sources", "sources must be an object — none loaded", .{});
        }
    } else {
        try p.diag("", "sources", "missing required sources object — none loaded", .{});
    }

    var layers: std.ArrayList(Layer) = .empty;
    var seen_ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (root.get("layers")) |lv| {
        if (lv == .array) {
            for (lv.array.items, 0..) |lj, i| {
                if (try parseLayer(&p, lj, i, &seen_ids)) |l| try layers.append(a, l);
            }
        } else {
            try p.diag("", "layers", "layers must be an array — none loaded", .{});
        }
    } else {
        try p.diag("", "layers", "missing required layers array — none loaded", .{});
    }

    return .{
        .arena = arena,
        .name = strField(root, "name"),
        .sprite = sprite,
        .glyphs = glyphs,
        .metadata = root.get("metadata"),
        .sources = sources,
        .layers = layers.items,
        .diagnostics = p.diags.items,
    };
}

// ---- tests -----------------------------------------------------------------

const t = std.testing;
const expect = t.expect;
const expectEqual = t.expectEqual;
const expectEqualStrings = t.expectEqualStrings;
const expectError = t.expectError;

test "minimal valid style parses clean" {
    var st = try parse(t.allocator,
        \\{"version":8,"name":"x","sources":{},"layers":[]}
    );
    defer st.deinit();
    try expectEqualStrings("x", st.name.?);
    try expectEqual(@as(usize, 0), st.layers.len);
    try expectEqual(@as(usize, 0), st.sources.count());
    try expectEqual(@as(usize, 0), st.diagnostics.len);
    try expect(st.sprite == null and st.glyphs == null and st.metadata == null);
}

test "wrong/missing version and malformed JSON are hard errors" {
    try expectError(error.WrongVersion, parse(t.allocator,
        \\{"version":7,"sources":{},"layers":[]}
    ));
    try expectError(error.WrongVersion, parse(t.allocator,
        \\{"sources":{},"layers":[]}
    ));
    try expectError(error.WrongVersion, parse(t.allocator,
        \\{"version":"8","sources":{},"layers":[]}
    ));
    try expectError(error.InvalidJson, parse(t.allocator, "{\"version\":8,"));
    try expectError(error.InvalidJson, parse(t.allocator, "[8]"));
}

test "duplicate layer id is a hard error" {
    try expectError(error.DuplicateLayerId, parse(t.allocator,
        \\{"version":8,"sources":{},"layers":[
        \\ {"id":"a","type":"background"},
        \\ {"id":"a","type":"background"}]}
    ));
}

test "property constants type-check and defaults apply" {
    var st = try parse(t.allocator,
        \\{"version":8,"sources":{},"layers":[
        \\ {"id":"bg","type":"background","paint":{
        \\   "background-color":"#ff0000",
        \\   "background-opacity":"solid"}}]}
    );
    defer st.deinit();
    const bg = st.layer("bg").?;
    // valid color constant, coerced to a Color
    const c = bg.resolved("background-color").?.constant.color;
    try expect(c.eql(.{ .r = 1, .g = 0, .b = 0, .a = 1 }));
    // mistyped constant: one diagnostic, spec default (1) applies
    try expectEqual(@as(usize, 1), st.diagnostics.len);
    try expectEqualStrings("background-opacity", st.diagnostics[0].property);
    try expectEqualStrings("bg", st.diagnostics[0].layer);
    try expectEqual(@as(f64, 1), bg.resolved("background-opacity").?.constant.number);
    // unset property resolves to the spec default
    try expectEqualStrings("visible", bg.resolved("visibility").?.constant.string);
    // a name foreign to the layer type resolves to null
    try expect(bg.resolved("line-width") == null);
}

test "bare arrays are constants unless the head names an operator" {
    var st = try parse(t.allocator,
        \\{"version":8,"sources":{},"layers":[
        \\ {"id":"l","type":"line","source":"s","paint":{"line-dasharray":[4,3]}},
        \\ {"id":"s1","type":"symbol","source":"s","layout":{
        \\   "text-font":["Noto Sans Regular"],
        \\   "text-offset":["literal",[1,2]],
        \\   "text-anchor":["match",["get","valign"],"top","top","center"]}}]}
    );
    defer st.deinit();
    try expectEqual(@as(usize, 0), st.diagnostics.len);
    // dasharray: bare number array => constant
    const dash = st.layer("l").?.get("line-dasharray").?.value.constant.array;
    try expectEqual(@as(usize, 2), dash.len);
    try expectEqual(@as(f64, 4), dash[0].number);
    // font stack: first element is a string, but not an operator => constant
    const font = st.layer("s1").?.get("text-font").?.value.constant.array;
    try expectEqualStrings("Noto Sans Regular", font[0].string);
    // ["literal",[...]] is an expression that folds straight back to a
    // typed constant
    const off = st.layer("s1").?.get("text-offset").?.value.constant.array;
    try expectEqual(@as(f64, 2), off[1].number);
    // a match expression stays an expression and carries its Deps
    const anchor = st.layer("s1").?.get("text-anchor").?.value.expression;
    try expect(anchor.deps.feature);
    try expect(!anchor.deps.zoom);
}

test "filter parses through expr and surfaces Deps" {
    var st = try parse(t.allocator,
        \\{"version":8,"sources":{},"layers":[
        \\ {"id":"l","type":"line","source":"s","source-layer":"lines",
        \\  "filter":["all",["==",["get","dash"],"dashed"],["<=",["coalesce",["get","vz"],0],["zoom"]]],
        \\  "minzoom":5.5}]}
    );
    defer st.deinit();
    const l = st.layer("l").?;
    try expectEqualStrings("lines", l.source_layer.?);
    try expectEqual(@as(f64, 5.5), l.minzoom.?);
    const f = l.filter.?;
    try expect(f.deps.feature);
    try expect(f.deps.zoom);
    try expect(!f.deps.binding);
}

test "unknown props, unknown layer types, bad expressions: diagnostics, not failure" {
    var st = try parse(t.allocator,
        \\{"version":8,"sources":{},"layers":[
        \\ {"id":"c","type":"circle","source":"s"},
        \\ {"id":"f","type":"fill","source":"s",
        \\  "layout":{"fill-color":"#fff"},
        \\  "paint":{"fill-fancy":1,"fill-color":["match"]}}]}
    );
    defer st.deinit();
    // circle layer skipped; fill layer kept
    try expectEqual(@as(usize, 1), st.layers.len);
    try expect(st.layer("c") == null);
    const f = st.layer("f").?;
    // four degradations: unsupported type, misplaced fill-color (paint prop
    // under layout), unknown fill-fancy, invalid ["match"] expression
    try expectEqual(@as(usize, 4), st.diagnostics.len);
    try expectEqualStrings("c", st.diagnostics[0].layer);
    try expectEqualStrings("type", st.diagnostics[0].property);
    // the broken fill-color degraded to the spec default (#000000)
    try expect(f.get("fill-color") == null);
    try expect(f.resolved("fill-color").?.constant.color.eql(.{ .r = 0, .g = 0, .b = 0, .a = 1 }));
}

test "feature expression on a non-data-driven property degrades to default" {
    var st = try parse(t.allocator,
        \\{"version":8,"sources":{},"layers":[
        \\ {"id":"s1","type":"symbol","source":"s","layout":{
        \\   "symbol-spacing":["get","gap"],
        \\   "text-size":["get","font_size_px"]}}]}
    );
    defer st.deinit();
    // symbol-spacing has no data-driven support: diagnostic + default 250.
    // text-size IS data-driven: kept as an expression.
    try expectEqual(@as(usize, 1), st.diagnostics.len);
    try expectEqualStrings("symbol-spacing", st.diagnostics[0].property);
    const s1 = st.layer("s1").?;
    try expectEqual(@as(f64, 250), s1.resolved("symbol-spacing").?.constant.number);
    try expect(s1.get("text-size").?.value.expression.deps.feature);
}

test "vector and raster sources parse; unknown source types degrade" {
    var st = try parse(t.allocator,
        \\{"version":8,"sources":{
        \\ "v":{"type":"vector","tiles":["tile57://{z}/{x}/{y}"],"minzoom":5,"maxzoom":16,"encoding":"mlt"},
        \\ "u":{"type":"vector","url":"pmtiles://tiles/chart.pmtiles"},
        \\ "r":{"type":"raster","tiles":["r/{z}/{x}/{y}.png"],"tileSize":256},
        \\ "g":{"type":"geojson","data":{}}},"layers":[]}
    );
    defer st.deinit();
    try expectEqual(@as(usize, 3), st.sources.count());
    const v = st.sources.get("v").?.vector;
    try expectEqualStrings("tile57://{z}/{x}/{y}", v.tiles[0]);
    try expectEqual(@as(f64, 5), v.minzoom);
    try expectEqual(@as(f64, 16), v.maxzoom);
    try expectEqualStrings("mlt", v.encoding.?);
    const u = st.sources.get("u").?.vector;
    try expectEqualStrings("pmtiles://tiles/chart.pmtiles", u.url.?);
    try expectEqual(@as(f64, 22), u.maxzoom); // spec default
    const r = st.sources.get("r").?.raster;
    try expectEqual(@as(f64, 256), r.tile_size);
    // geojson: tier 2 — one diagnostic, source skipped
    try expectEqual(@as(usize, 1), st.diagnostics.len);
    try expectEqualStrings("g", st.diagnostics[0].property);
}

// A representative excerpt of tile57's emitted style: the background, an
// area fill carrying the mariner nested-let color expression (the alpha-
// suffix `"TOKEN,0.5"` fold), a dashed line layer, and a text layer with
// the data-driven text-anchor match and per-feature font stack — the exact
// shapes tile57/src/style/{maplibre,mariner}.zig emit.
const tile57_excerpt =
    \\{
    \\  "version": 8,
    \\  "name": "tile57 (day)",
    \\  "glyphs": "glyphs/{fontstack}/{range}.pbf",
    \\  "sprite": "sprite",
    \\  "sources": {
    \\    "chart": {"type":"vector","tiles":["tile57://{z}/{x}/{y}"],"minzoom":5,"maxzoom":16,"encoding":"mlt"}
    \\  },
    \\  "layers": [
    \\    {"id":"background","type":"background","paint":{"background-color":"#c9edff"}},
    \\    {"id":"fill-areas","type":"fill","source":"chart","source-layer":"areas",
    \\     "layout":{"fill-sort-key":["-",["*",["coalesce",["get","display_priority"],0],1000],["coalesce",["get","drval1"],0]]},
    \\     "paint":{
    \\       "fill-color":["let","ct",["coalesce",["get","color_token"],""],
    \\         ["let","ci",["index-of",",",["var","ct"]],
    \\           ["case",["<",["var","ci"],0],
    \\             ["to-color",["match",["var","ct"],"CHBLK","#000000","DEPDW","#c9edff","#ff00ff"]],
    \\             ["let","c",["to-color",["match",["slice",["var","ct"],0,["var","ci"]],"CHBLK","#000000","DEPDW","#c9edff","#ff00ff"]],
    \\               ["rgba",
    \\                 ["at",0,["to-rgba",["var","c"]]],
    \\                 ["at",1,["to-rgba",["var","c"]]],
    \\                 ["at",2,["to-rgba",["var","c"]]],
    \\                 ["to-number",["slice",["var","ct"],["+",["var","ci"],1]]]]]]]],
    \\       "fill-antialias":true}},
    \\    {"id":"lines-dashed","type":"line","source":"chart","source-layer":"lines",
    \\     "filter":["all",["==",["coalesce",["get","dash"],"solid"],"dashed"],["<=",["coalesce",["get","vz"],0],["zoom"]]],
    \\     "layout":{"line-sort-key":["coalesce",["get","lsk"],0]},
    \\     "paint":{
    \\       "line-color":["match",["coalesce",["get","color_token"],""],"CHBLK","#000000","CSTLN","#4c5b63","#ff00ff"],
    \\       "line-width":["coalesce",["get","width_px"],1],
    \\       "line-dasharray":[4,3]}},
    \\    {"id":"text","type":"symbol","source":"chart","source-layer":"text",
    \\     "layout":{
    \\       "text-field":["coalesce",["get","text"],""],
    \\       "text-font":["case",["==",["get","font_weight"],"bold"],["literal",["Noto Sans Bold"]],["literal",["Noto Sans Regular"]]],
    \\       "text-size":["coalesce",["get","font_size_px"],11],
    \\       "text-anchor":["match",["concat",["match",["coalesce",["get","valign"],"middle"],"top","top","bottom","bottom","center"],"|",["coalesce",["get","halign"],"center"]],
    \\         "center|left","left","top|center","top","center"],
    \\       "text-offset":[0,0.4],
    \\       "text-allow-overlap":false,
    \\       "text-optional":true},
    \\     "paint":{
    \\       "text-color":"#000000",
    \\       "text-halo-color":"rgba(255,255,255,0.9)",
    \\       "text-halo-width":1.4,
    \\       "text-halo-blur":0.5}}
    \\  ]
    \\}
;

test "integration: a representative tile57-shaped style parses with zero diagnostics" {
    var st = try parse(t.allocator, tile57_excerpt);
    defer st.deinit();
    for (st.diagnostics) |d| std.debug.print("unexpected diagnostic: {s}/{s}: {s}\n", .{ d.layer, d.property, d.message });
    try expectEqual(@as(usize, 0), st.diagnostics.len);
    try expectEqual(@as(usize, 4), st.layers.len);
    try expectEqualStrings("glyphs/{fontstack}/{range}.pbf", st.glyphs.?);
    try expectEqualStrings("sprite", st.sprite.?);
    try expectEqualStrings("mlt", st.sources.get("chart").?.vector.encoding.?);

    // the nested-let color: data-driven, never folded. Its `binding` dep is
    // false OUTSIDE the expression — a closed let resolves its own bindings
    // (expr.zig strips the flag at the let node), so classification sees a
    // plain data-driven property.
    const fill = st.layer("fill-areas").?;
    const fc = fill.get("fill-color").?.value.expression;
    try expect(fc.deps.feature and !fc.deps.binding and !fc.deps.zoom);
    // fill-antialias constant true
    try expect(fill.resolved("fill-antialias").?.constant.boolean);

    // dashed line: filter deps carry both feature and zoom; dasharray is a
    // bare-array constant next to sibling expressions
    const line = st.layer("lines-dashed").?;
    try expect(line.filter.?.deps.feature and line.filter.?.deps.zoom);
    try expectEqual(@as(usize, 2), line.get("line-dasharray").?.value.constant.array.len);
    try expect(line.get("line-color").?.value == .expression);

    // symbol: anchor match is data-driven; the case-wrapped font stacks are
    // expressions whose ["literal",…] arms wrap the arrays
    const text = st.layer("text").?;
    try expect(text.get("text-anchor").?.value.expression.deps.feature);
    try expect(text.get("text-font").?.value.expression.deps.feature);
    try expectEqual(@as(f64, 0.4), text.get("text-offset").?.value.constant.array[1].number);
    // halo color parsed from its rgba() string form
    const halo = text.get("text-halo-color").?.value.constant.color;
    try expect(halo.a > 0.89 and halo.a < 0.91);
}

test "integration: tile57's checked-in template.json parses (when present)" {
    // The stale-but-valid style tile57 ships for its wasm demo. Machines
    // without a tile57 checkout skip (same convention as source/mvt.zig's
    // fixture test).
    const io = std.Io.Threaded.global_single_threaded.io();
    const tile57_env = std.c.getenv("CHARTTABLE_TILE57_DIR") orelse return error.SkipZigTest;
    const path = try std.fmt.allocPrint(t.allocator, "{s}/bindings/wasm/assets/template.json", .{std.mem.span(tile57_env)});
    defer t.allocator.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, t.allocator, .limited(16 << 20)) catch
        return error.SkipZigTest;
    defer t.allocator.free(data);

    var st = try parse(t.allocator, data);
    defer st.deinit();
    // Every layer survives; the one degradation the stale template carries
    // is `text-justify` (outside the tier-1 property scope) on its two
    // light-description layers.
    try expectEqual(@as(usize, 27), st.layers.len);
    try expectEqual(@as(usize, 1), st.sources.count());
    try expect(st.sources.get("chart").? == .vector);
    for (st.diagnostics) |d| {
        try expectEqualStrings("text-justify", d.property);
    }
    // spot checks on real layers
    const bg = st.layer("background").?;
    try expect(bg.resolved("background-color").?.constant.color.a == 1);
    const fill = st.layer("fill-areas").?;
    try expect(fill.get("fill-color").?.value.expression.deps.feature);
    try expect(fill.get("fill-sort-key").?.value.expression.deps.feature);
}

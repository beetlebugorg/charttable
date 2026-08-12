//! Tier-1 paint/layout property tables, transcribed from the published
//! MapLibre Style Specification (https://maplibre.org/maplibre-style-spec/layers/,
//! fetched 2026-08-12). One comptime table per layer type: spec name, value
//! type, the spec's printed default, paint-or-layout scope, and whether the
//! spec's SDK-support matrix lists "data-driven styling" for it.
//!
//! Scope is DESIGN.md tier 1 — the properties tile57's emitted styles
//! exercise, plus the layer-wide `visibility`. style.zig turns an unknown
//! property into a diagnostic, never an error, so growing these tables IS
//! the upgrade path to broader conformance.
//!
//! Every default cites the page's exact "Defaults to …" wording in a
//! comment; a `.null` default means the spec prints none (unset then means
//! "feature off": no pattern, no dash rhythm, no sort key, no icon).

const std = @import("std");
const vals = @import("value.zig");
const colors = @import("color.zig");

pub const Value = vals.Value;
pub const Color = vals.Color;

/// The five tier-1 layer types (spec `layers` § type). `circle`, `heatmap`,
/// `fill-extrusion`, `hillshade`, `color-relief` are tier 2+.
pub const LayerType = enum { background, fill, line, symbol, raster };

/// Which section of the layer object carries the property.
pub const Scope = enum { paint, layout };

pub const ValueType = union(enum) {
    number,
    color,
    boolean,
    /// Free-form string. The spec's `formatted` (text-field) and
    /// `resolvedImage` (icon-image, fill-pattern) collapse to plain strings
    /// at tier 1 — `format`/`image` expressions are tier 2.
    string,
    /// Closed variant set; a constant must match one exactly.
    enumeration: []const []const u8,
    /// Array of numbers. A fixed length pins the arity (text-offset is
    /// [x, y]); null admits any length (line-dasharray).
    number_array: ?u8,
    /// Array of strings (text-font).
    string_array,
};

pub const Prop = struct {
    name: []const u8,
    scope: Scope,
    value_type: ValueType,
    /// The spec's printed default; `.null` where the spec prints none.
    default: Value,
    /// True when the published SDK-support table for the property carries a
    /// "data-driven styling" row (feature expressions allowed). Zoom-only
    /// `interpolate`/`step` expressions are legal on every property.
    data_driven: bool,
};

// ---- shared value fragments -------------------------------------------------

/// "#000000" — the default of background-color, fill-color, line-color,
/// text-color.
const black: Value = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
/// "rgba(0, 0, 0, 0)" — the default of text-halo-color.
const transparent: Value = .{ .color = Color.transparent };

const visibility_variants = [_][]const u8{ "visible", "none" };
const line_cap_variants = [_][]const u8{ "butt", "round", "square" };
const line_join_variants = [_][]const u8{ "bevel", "round", "miter" };
const placement_variants = [_][]const u8{ "point", "line", "line-center" };
const z_order_variants = [_][]const u8{ "auto", "viewport-y", "source" };
const alignment_variants = [_][]const u8{ "map", "viewport", "auto" };
const anchor_variants = [_][]const u8{
    "center",   "left",      "right",       "top",          "bottom",
    "top-left", "top-right", "bottom-left", "bottom-right",
};

const zero_pair = [_]Value{ .{ .number = 0 }, .{ .number = 0 } };
// "Defaults to ["Open Sans Regular","Arial Unicode MS Regular"]".
const font_default = [_]Value{
    .{ .string = "Open Sans Regular" },
    .{ .string = "Arial Unicode MS Regular" },
};

/// Every layer type carries `visibility`. "Defaults to \"visible\"".
const visibility_prop = Prop{
    .name = "visibility",
    .scope = .layout,
    .value_type = .{ .enumeration = &visibility_variants },
    .default = .{ .string = "visible" },
    .data_driven = false,
};

// ---- per-layer-type tables --------------------------------------------------

pub const background_props = [_]Prop{
    visibility_prop,
    // "Defaults to \"#000000\"". No data-driven row (interpolate only).
    .{ .name = "background-color", .scope = .paint, .value_type = .color, .default = black, .data_driven = false },
    // "Defaults to 1", range [0, 1].
    .{ .name = "background-opacity", .scope = .paint, .value_type = .number, .default = .{ .number = 1 }, .data_driven = false },
};

pub const fill_props = [_]Prop{
    // No printed default; data-driven (1.2.0).
    .{ .name = "fill-sort-key", .scope = .layout, .value_type = .number, .default = .null, .data_driven = true },
    visibility_prop,
    // "Defaults to true". No data-driven row.
    .{ .name = "fill-antialias", .scope = .paint, .value_type = .boolean, .default = .{ .boolean = true }, .data_driven = false },
    // "Defaults to 1", range [0, 1]; data-driven (0.21.0).
    .{ .name = "fill-opacity", .scope = .paint, .value_type = .number, .default = .{ .number = 1 }, .data_driven = true },
    // "Defaults to \"#000000\""; disabled by fill-pattern; data-driven (0.19.0).
    .{ .name = "fill-color", .scope = .paint, .value_type = .color, .default = black, .data_driven = true },
    // resolvedImage, no printed default; data-driven (0.49.0).
    .{ .name = "fill-pattern", .scope = .paint, .value_type = .string, .default = .null, .data_driven = true },
};

pub const line_props = [_]Prop{
    // "Defaults to \"butt\""; data-driven (5.22.0).
    .{ .name = "line-cap", .scope = .layout, .value_type = .{ .enumeration = &line_cap_variants }, .default = .{ .string = "butt" }, .data_driven = true },
    // "Defaults to \"miter\""; data-driven (0.40.0).
    .{ .name = "line-join", .scope = .layout, .value_type = .{ .enumeration = &line_join_variants }, .default = .{ .string = "miter" }, .data_driven = true },
    // No printed default; data-driven (1.2.0).
    .{ .name = "line-sort-key", .scope = .layout, .value_type = .number, .default = .null, .data_driven = true },
    visibility_prop,
    // "Defaults to 1", range [0, 1]; data-driven (0.29.0).
    .{ .name = "line-opacity", .scope = .paint, .value_type = .number, .default = .{ .number = 1 }, .data_driven = true },
    // "Defaults to \"#000000\""; data-driven (0.23.0).
    .{ .name = "line-color", .scope = .paint, .value_type = .color, .default = black, .data_driven = true },
    // "Defaults to 1", pixels; data-driven (0.39.0).
    .{ .name = "line-width", .scope = .paint, .value_type = .number, .default = .{ .number = 1 }, .data_driven = true },
    // Units in line widths; no printed default (unset = solid). Data-driven
    // (5.8.0), but "the only way to create an array value is using
    // ["literal", [...]]" — arrays never derive from feature properties.
    .{ .name = "line-dasharray", .scope = .paint, .value_type = .{ .number_array = null }, .default = .null, .data_driven = true },
};

pub const symbol_props = [_]Prop{
    // "Defaults to \"point\"". Not data-driven.
    .{ .name = "symbol-placement", .scope = .layout, .value_type = .{ .enumeration = &placement_variants }, .default = .{ .string = "point" }, .data_driven = false },
    // "Defaults to 250", pixels, range [1, ∞). Not data-driven.
    .{ .name = "symbol-spacing", .scope = .layout, .value_type = .number, .default = .{ .number = 250 }, .data_driven = false },
    // No printed default; data-driven (0.53.0).
    .{ .name = "symbol-sort-key", .scope = .layout, .value_type = .number, .default = .null, .data_driven = true },
    // "Defaults to \"auto\"". Not data-driven.
    .{ .name = "symbol-z-order", .scope = .layout, .value_type = .{ .enumeration = &z_order_variants }, .default = .{ .string = "auto" }, .data_driven = false },
    // resolvedImage, no printed default; data-driven (0.35.0).
    .{ .name = "icon-image", .scope = .layout, .value_type = .string, .default = .null, .data_driven = true },
    // "Defaults to 1", factor of original size, range [0, ∞); data-driven (0.35.0).
    .{ .name = "icon-size", .scope = .layout, .value_type = .number, .default = .{ .number = 1 }, .data_driven = true },
    // "Defaults to 0", degrees clockwise; data-driven (0.21.0).
    .{ .name = "icon-rotate", .scope = .layout, .value_type = .number, .default = .{ .number = 0 }, .data_driven = true },
    // "Defaults to false". Not data-driven.
    .{ .name = "icon-allow-overlap", .scope = .layout, .value_type = .boolean, .default = .{ .boolean = false }, .data_driven = false },
    // "Defaults to false". Not data-driven.
    .{ .name = "icon-ignore-placement", .scope = .layout, .value_type = .boolean, .default = .{ .boolean = false }, .data_driven = false },
    // "Defaults to \"auto\"". Not data-driven.
    .{ .name = "icon-rotation-alignment", .scope = .layout, .value_type = .{ .enumeration = &alignment_variants }, .default = .{ .string = "auto" }, .data_driven = false },
    // formatted; "Defaults to \"\""; data-driven (0.33.0).
    .{ .name = "text-field", .scope = .layout, .value_type = .string, .default = .{ .string = "" }, .data_driven = true },
    // "Defaults to ["Open Sans Regular","Arial Unicode MS Regular"]";
    // data-driven (0.43.0).
    .{ .name = "text-font", .scope = .layout, .value_type = .string_array, .default = .{ .array = &font_default }, .data_driven = true },
    // "Defaults to 16", pixels, range [0, ∞); data-driven (0.35.0).
    .{ .name = "text-size", .scope = .layout, .value_type = .number, .default = .{ .number = 16 }, .data_driven = true },
    // "Defaults to \"center\""; data-driven (0.39.0).
    .{ .name = "text-anchor", .scope = .layout, .value_type = .{ .enumeration = &anchor_variants }, .default = .{ .string = "center" }, .data_driven = true },
    // "Defaults to [0,0]", ems; data-driven (0.35.0).
    .{ .name = "text-offset", .scope = .layout, .value_type = .{ .number_array = 2 }, .default = .{ .array = &zero_pair }, .data_driven = true },
    // "Defaults to 45", degrees. Not data-driven (interpolate only).
    .{ .name = "text-max-angle", .scope = .layout, .value_type = .number, .default = .{ .number = 45 }, .data_driven = false },
    // "Defaults to false". Not data-driven.
    .{ .name = "text-allow-overlap", .scope = .layout, .value_type = .boolean, .default = .{ .boolean = false }, .data_driven = false },
    // "Defaults to false". Not data-driven.
    .{ .name = "text-optional", .scope = .layout, .value_type = .boolean, .default = .{ .boolean = false }, .data_driven = false },
    visibility_prop,
    // "Defaults to \"#000000\""; data-driven (0.33.0).
    .{ .name = "text-color", .scope = .paint, .value_type = .color, .default = black, .data_driven = true },
    // "Defaults to \"rgba(0, 0, 0, 0)\""; data-driven (0.33.0).
    .{ .name = "text-halo-color", .scope = .paint, .value_type = .color, .default = transparent, .data_driven = true },
    // "Defaults to 0", pixels, range [0, ∞); data-driven (0.33.0).
    .{ .name = "text-halo-width", .scope = .paint, .value_type = .number, .default = .{ .number = 0 }, .data_driven = true },
    // "Defaults to 0", pixels, range [0, ∞); data-driven (0.33.0).
    .{ .name = "text-halo-blur", .scope = .paint, .value_type = .number, .default = .{ .number = 0 }, .data_driven = true },
};

pub const raster_props = [_]Prop{
    visibility_prop,
    // "Defaults to 1", range [0, 1]. No data-driven row (interpolate only).
    .{ .name = "raster-opacity", .scope = .paint, .value_type = .number, .default = .{ .number = 1 }, .data_driven = false },
};

/// The tier-1 property table for a layer type.
pub fn table(t: LayerType) []const Prop {
    return switch (t) {
        .background => &background_props,
        .fill => &fill_props,
        .line => &line_props,
        .symbol => &symbol_props,
        .raster => &raster_props,
    };
}

/// Look a property up by its spec name. The returned pointer is into a
/// global comptime table: static lifetime, share freely.
pub fn find(t: LayerType, name: []const u8) ?*const Prop {
    for (table(t)) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Type-check/coerce a constant against `vt`: colors parse from their CSS
/// string form, enum strings canonicalize to the table's static variant
/// slice, arrays check element type and arity. Null = mismatch (style.zig
/// turns that into a diagnostic and the default applies).
pub fn coerce(vt: ValueType, v: Value) ?Value {
    switch (vt) {
        .number => if (v == .number) return v,
        .boolean => if (v == .boolean) return v,
        .string => if (v == .string) return v,
        .color => switch (v) {
            .color => return v,
            .string => |s| if (colors.parse(s)) |c| return .{ .color = c },
            else => {},
        },
        .enumeration => |variants| if (v == .string) {
            for (variants) |s| {
                if (std.mem.eql(u8, s, v.string)) return .{ .string = s };
            }
        },
        .number_array => |arity| if (v == .array) {
            if (arity) |n| {
                if (v.array.len != n) return null;
            }
            for (v.array) |item| {
                if (item != .number) return null;
            }
            return v;
        },
        .string_array => if (v == .array) {
            for (v.array) |item| {
                if (item != .string) return null;
            }
            return v;
        },
    }
    return null;
}

// ---- tests -----------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "every printed default coerces against its own declared type" {
    for (std.enums.values(LayerType)) |t| {
        for (table(t)) |*p| {
            if (p.default == .null) continue; // spec prints no default
            try expect(coerce(p.value_type, p.default) != null);
        }
    }
}

test "names are unique within each table" {
    for (std.enums.values(LayerType)) |t| {
        const props = table(t);
        for (props, 0..) |*p, i| {
            for (props[i + 1 ..]) |*q| {
                try expect(!std.mem.eql(u8, p.name, q.name));
            }
        }
    }
}

test "find resolves spec names, scope, and data-driven flags" {
    const fc = find(.fill, "fill-color").?;
    try expectEqual(Scope.paint, fc.scope);
    try expect(fc.data_driven);
    try expect(find(.fill, "line-color") == null);
    try expect(find(.background, "background-color") != null);
    try expect(!find(.symbol, "symbol-spacing").?.data_driven);
    try expect(find(.symbol, "text-anchor").?.data_driven);
    // every layer type carries layout `visibility`
    for (std.enums.values(LayerType)) |t| {
        try expectEqual(Scope.layout, find(t, "visibility").?.scope);
    }
}

test "spec defaults spot-check (published layers page values)" {
    try expectEqualStrings("butt", find(.line, "line-cap").?.default.string);
    try expectEqualStrings("miter", find(.line, "line-join").?.default.string);
    try expectEqual(@as(f64, 1), find(.line, "line-width").?.default.number);
    try expectEqual(@as(f64, 16), find(.symbol, "text-size").?.default.number);
    try expectEqual(@as(f64, 45), find(.symbol, "text-max-angle").?.default.number);
    try expectEqual(@as(f64, 250), find(.symbol, "symbol-spacing").?.default.number);
    try expectEqualStrings("point", find(.symbol, "symbol-placement").?.default.string);
    try expectEqualStrings("auto", find(.symbol, "symbol-z-order").?.default.string);
    try expectEqualStrings("center", find(.symbol, "text-anchor").?.default.string);
    // colors: "#000000" and "rgba(0, 0, 0, 0)"
    try expect(find(.background, "background-color").?.default.color.eql(.{ .r = 0, .g = 0, .b = 0, .a = 1 }));
    try expect(find(.symbol, "text-halo-color").?.default.color.eql(Color.transparent));
    // the spec prints no default for these: unset means "feature off"
    try expect(find(.fill, "fill-pattern").?.default == .null);
    try expect(find(.line, "line-dasharray").?.default == .null);
    try expect(find(.symbol, "icon-image").?.default == .null);
    try expect(find(.fill, "fill-sort-key").?.default == .null);
    // text-font's printed default pair
    const font = find(.symbol, "text-font").?.default.array;
    try expectEqual(@as(usize, 2), font.len);
    try expectEqualStrings("Open Sans Regular", font[0].string);
}

test "coerce validates and canonicalizes" {
    // color from CSS string
    const c = coerce(.color, .{ .string = "#ff0000" }).?;
    try expect(c.color.eql(.{ .r = 1, .g = 0, .b = 0, .a = 1 }));
    try expect(coerce(.color, .{ .string = "notacolor" }) == null);
    // enum canonicalizes to the table's static slice
    const cap = coerce(.{ .enumeration = &line_cap_variants }, .{ .string = "round" }).?;
    try expect(cap.string.ptr == line_cap_variants[1].ptr);
    try expect(coerce(.{ .enumeration = &line_cap_variants }, .{ .string = "diagonal" }) == null);
    // arrays check element type and arity
    const dash = [_]Value{ .{ .number = 4 }, .{ .number = 3 } };
    try expect(coerce(.{ .number_array = null }, .{ .array = &dash }) != null);
    try expect(coerce(.{ .number_array = 2 }, .{ .array = &dash }) != null);
    try expect(coerce(.{ .number_array = 3 }, .{ .array = &dash }) == null);
    const mixed = [_]Value{ .{ .number = 4 }, .{ .string = "x" } };
    try expect(coerce(.{ .number_array = null }, .{ .array = &mixed }) == null);
    try expect(coerce(.string_array, .{ .array = &font_default }) != null);
    try expect(coerce(.string_array, .{ .array = &dash }) == null);
    // scalars
    try expect(coerce(.number, .{ .number = 2 }) != null);
    try expect(coerce(.number, .{ .string = "2" }) == null);
    try expect(coerce(.boolean, .{ .boolean = true }) != null);
    try expect(coerce(.boolean, .{ .number = 1 }) == null);
}

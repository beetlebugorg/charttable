//! Static expression types: the lattice the parser's typechecker works in.
//!
//! Semantics are derived from the vendored conformance fixtures
//! (test/spec/expression) and the published MapLibre style-spec expression
//! docs — clean-room, no reference implementation source. The fixture
//! observations pinning each rule are cited inline.
//!
//! `value` is the top type (an unknown runtime value: the type of ["get"],
//! ["id"], ...). The reference wraps a value-typed subexpression in a
//! runtime assertion or coercion where a concrete type is expected; this
//! engine is dynamically typed at evaluation, so acceptance alone is
//! enough — a wrong value still errors at eval, exactly where the
//! reference's injected assertion would.

const std = @import("std");
const vals = @import("value.zig");

/// Array item types the spec's `array<T, N>` syntax can name.
pub const Item = enum { value, number, string, boolean };

pub const Type = union(enum) {
    /// Top: any runtime value (feature data, unresolved).
    value,
    number,
    string,
    boolean,
    color,
    object,
    collator,
    formatted,
    resolved_image,
    /// projectionDefinition
    projection,
    /// Property-spec aggregate types (coercion contexts): a padding
    /// shorthand, an array of numbers, an array of colors.
    padding,
    number_array,
    color_array,
    /// The type of a literal `null`.
    null_t,
    /// ["error", ...]: bottom-ish — matches every expectation (the
    /// reference's error type short-circuits checkSubtype).
    err,
    array: Arr,

    pub const Arr = struct { item: Item = .value, len: ?usize = null };

    pub fn arrayOf(item: Item, len: ?usize) Type {
        return .{ .array = .{ .item = item, .len = len } };
    }

    pub fn itemAsType(item: Item) Type {
        return switch (item) {
            .value => .value,
            .number => .number,
            .string => .string,
            .boolean => .boolean,
        };
    }

    /// The array item type an expected element type pins (["at"] with an
    /// outer string expectation reads from an array<string> — fixture
    /// at/infer-array-type).
    pub fn asItem(t: ?Type) Item {
        const ty = t orelse return .value;
        return switch (ty) {
            .number => .number,
            .string => .string,
            .boolean => .boolean,
            else => .value,
        };
    }

    /// Would the reference compile `actual` where `expected` is required?
    /// This folds the reference's subtype check AND its assertion/coercion
    /// wrap points into one acceptance test:
    /// - `value` absorbs in both directions (assertions are runtime here).
    /// - arrays are covariant in item, exact in length when one is asked
    ///   (typecheck/array-wrong-length); an EMPTY literal array matches any
    ///   item type (literal/infer-empty-array-type) but not a length.
    /// - coercion contexts accept their source types: color/formatted/
    ///   resolvedImage from string (interpolate/linear-color,
    ///   format/implicit-coerce), projectionDefinition additionally from
    ///   arrays (step/projection/step-array), the aggregate property types
    ///   from scalars and arrays (interpolate/linear-number-array,
    ///   interpolate-hcl/linear-color-array).
    /// - null unifies only into `value` holes (coalesce/infer-array-type,
    ///   interpolate/uninterpolable-output/null reject it elsewhere).
    pub fn accepts(expected: Type, actual: Type) bool {
        if (actual == .err or expected == .err) return true;
        if (expected == .value or actual == .value) return true;
        switch (expected) {
            .array => |want| switch (actual) {
                .array => |got| {
                    if (want.len) |n| {
                        if (got.len == null or got.len.? != n) return false;
                    }
                    if (got.len == 0 and got.item == .value) return true; // empty literal
                    return want.item == .value or want.item == got.item;
                },
                else => return false,
            },
            .color => return actual == .color or actual == .string,
            .formatted => return actual == .formatted or actual == .string,
            .resolved_image => return actual == .resolved_image or actual == .string,
            .projection => return actual == .projection or actual == .string or actual == .array,
            .padding => return actual == .padding or actual == .number or actual == .array,
            .number_array => return actual == .number_array or actual == .number or actual == .array,
            .color_array => return actual == .color_array or actual == .color or
                actual == .string or actual == .array,
            else => return std.meta.activeTag(expected) == std.meta.activeTag(actual),
        }
    }

    /// Types ["interpolate"] may produce (fixtures: exponential-string-array
    /// and exponential-uninterpolatable-numeric-array reject string arrays
    /// and unknown-length number arrays; projection/linear and
    /// linear-number-array accept projections and aggregates).
    pub fn interpolatable(t: Type) bool {
        return switch (t) {
            .number, .color, .projection, .padding, .number_array, .color_array => true,
            .array => |a| a.item == .number and a.len != null,
            else => false,
        };
    }

    /// The static type of a literal value. Arrays are uniform-item typed
    /// when every element shares a primitive type, array<value, N>
    /// otherwise (fixtures literal/number-array, literal/mixed-primitive-
    /// array, literal/nested-array).
    pub fn ofValue(v: vals.Value) Type {
        return switch (v) {
            .null => .null_t,
            .boolean => .boolean,
            .number => .number,
            .string => .string,
            .color => .color,
            .object => .object,
            .array => |items| arrayOf(uniformItem(items), items.len),
        };
    }

    fn uniformItem(items: []const vals.Value) Item {
        var item: ?Item = null;
        for (items) |it| {
            const k: Item = switch (it) {
                .number => .number,
                .string => .string,
                .boolean => .boolean,
                else => return .value,
            };
            if (item) |prev| {
                if (prev != k) return .value;
            } else item = k;
        }
        return item orelse .value;
    }

    /// Map a property-spec `type` (plus `value`/`length` for arrays) to the
    /// expected expression type, as the conformance harness derives it.
    /// Unknown spec types return null (no static expectation).
    pub fn fromSpecName(name: []const u8, item_name: ?[]const u8, len: ?usize) ?Type {
        const map = std.StaticStringMap(Type).initComptime(.{
            .{ "number", .number },
            .{ "string", .string },
            .{ "boolean", .boolean },
            .{ "color", .color },
            .{ "object", .object },
            .{ "formatted", .formatted },
            .{ "resolvedImage", .resolved_image },
            .{ "projectionDefinition", .projection },
            .{ "padding", .padding },
            .{ "numberArray", .number_array },
            .{ "colorArray", .color_array },
            .{ "enum", .string },
            .{ "null", .null_t },
        });
        if (map.get(name)) |t| return t;
        if (std.mem.eql(u8, name, "array")) {
            var item: Item = .value;
            if (item_name) |n| {
                if (std.mem.eql(u8, n, "number")) item = .number;
                if (std.mem.eql(u8, n, "string")) item = .string;
                if (std.mem.eql(u8, n, "boolean")) item = .boolean;
            }
            return arrayOf(item, len);
        }
        return null;
    }

    /// Render in the fixtures' `compiled.type` notation ("array<string, 2>",
    /// "projectionDefinition", ...). For the harness's informational
    /// inference-vs-oracle counter.
    pub fn toSpecString(t: Type, a: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return switch (t) {
            .value => "value",
            .number => "number",
            .string => "string",
            .boolean => "boolean",
            .color => "color",
            .object => "object",
            .collator => "collator",
            .formatted => "formatted",
            .resolved_image => "resolvedImage",
            .projection => "projectionDefinition",
            .padding => "padding",
            .number_array => "numberArray",
            .color_array => "colorArray",
            .null_t => "null",
            .err => "error",
            .array => |arr| blk: {
                if (arr.len) |n| break :blk try std.fmt.allocPrint(a, "array<{s}, {d}>", .{ @tagName(arr.item), n });
                if (arr.item == .value) break :blk "array";
                break :blk try std.fmt.allocPrint(a, "array<{s}>", .{@tagName(arr.item)});
            },
        };
    }
};

test "value absorbs in both directions" {
    try std.testing.expect(Type.accepts(.value, .{ .array = .{} }));
    try std.testing.expect(Type.accepts(.number, .value));
    try std.testing.expect(Type.accepts(.value, .null_t));
    try std.testing.expect(!Type.accepts(.number, .null_t));
    try std.testing.expect(!Type.accepts(.number, .string));
}

test "array covariance and lengths" {
    const str_any = Type.arrayOf(.string, null);
    try std.testing.expect(str_any.accepts(Type.arrayOf(.string, 2)));
    try std.testing.expect(!str_any.accepts(Type.arrayOf(.number, 3)));
    try std.testing.expect(!str_any.accepts(Type.arrayOf(.value, null))); // format/data-driven-scale
    try std.testing.expect(str_any.accepts(Type.arrayOf(.value, 0))); // empty literal
    const num3 = Type.arrayOf(.number, 3);
    try std.testing.expect(!num3.accepts(Type.arrayOf(.number, 2)));
    try std.testing.expect(!num3.accepts(Type.arrayOf(.number, null)));
    try std.testing.expect(!num3.accepts(Type.arrayOf(.value, 0))); // length still binds
}

test "coercion contexts accept their sources only" {
    try std.testing.expect(Type.accepts(.color, .string));
    try std.testing.expect(!Type.accepts(.color, .number));
    try std.testing.expect(!Type.accepts(.color, Type.arrayOf(.number, 2)));
    try std.testing.expect(Type.accepts(.formatted, .string));
    try std.testing.expect(!Type.accepts(.formatted, .number));
    try std.testing.expect(Type.accepts(.projection, Type.arrayOf(.value, 3)));
    try std.testing.expect(Type.accepts(.color_array, Type.arrayOf(.string, 2)));
    try std.testing.expect(Type.accepts(.number_array, .number));
}

test "interpolatable set" {
    try std.testing.expect(Type.interpolatable(.number));
    try std.testing.expect(Type.interpolatable(.color));
    try std.testing.expect(Type.interpolatable(.projection));
    try std.testing.expect(Type.interpolatable(Type.arrayOf(.number, 2)));
    try std.testing.expect(!Type.interpolatable(Type.arrayOf(.number, null)));
    try std.testing.expect(!Type.interpolatable(Type.arrayOf(.string, 1)));
    try std.testing.expect(!Type.interpolatable(.string));
    try std.testing.expect(!Type.interpolatable(.boolean));
    try std.testing.expect(!Type.interpolatable(.null_t));
}

test "literal typing" {
    const v2 = Type.ofValue(.{ .array = &.{ .{ .number = 1 }, .{ .number = 2 } } });
    try std.testing.expectEqual(Type.arrayOf(.number, 2), v2);
    const mixed = Type.ofValue(.{ .array = &.{ .{ .number = 1 }, .{ .string = "2" } } });
    try std.testing.expectEqual(Type.arrayOf(.value, 2), mixed);
    try std.testing.expectEqual(Type.null_t, Type.ofValue(.null));
}

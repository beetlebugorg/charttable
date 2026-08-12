//! The expression value model: what an expression evaluates to, and the
//! coercion rules between types. Semantics follow the published MapLibre
//! Style Specification (expressions § types); where the spec is silent the
//! choice is documented at the site.

const std = @import("std");

/// Straight-alpha RGBA, components in [0,1].
pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn rgba8(self: Color) [4]u8 {
        return .{
            @intFromFloat(std.math.clamp(self.r, 0, 1) * 255.0 + 0.5),
            @intFromFloat(std.math.clamp(self.g, 0, 1) * 255.0 + 0.5),
            @intFromFloat(std.math.clamp(self.b, 0, 1) * 255.0 + 0.5),
            @intFromFloat(std.math.clamp(self.a, 0, 1) * 255.0 + 0.5),
        };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    color: Color,
    array: []const Value,
    object: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub const true_: Value = .{ .boolean = true };
    pub const false_: Value = .{ .boolean = false };

    pub fn num(n: f64) Value {
        return .{ .number = n };
    }
    pub fn str(s: []const u8) Value {
        return .{ .string = s };
    }

    /// The spec's `typeof` name for this value. Arrays are parameterized
    /// (array<number, 3>, array<value, 2>) by `typeof` in eval.zig, which
    /// has an allocator; this is the bare tag name.
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null => "null",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .color => "color",
            .array => "array",
            .object => "object",
        };
    }

    /// Strict equality (the `==` operator): same type and same value.
    /// Cross-type comparison — including against null — is false, never an
    /// error. tile57 styles depend on `["!=",["get","absent"],1]` being true.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .boolean => |v| v == b.boolean,
            .number => |v| v == b.number,
            .string => |v| std.mem.eql(u8, v, b.string),
            .color => |v| v.eql(b.color),
            .array => |v| blk: {
                if (v.len != b.array.len) break :blk false;
                for (v, b.array) |x, y| {
                    if (!x.eql(y)) break :blk false;
                }
                break :blk true;
            },
            .object => |v| blk: {
                if (v.len != b.object.len) break :blk false;
                for (v, b.object) |x, y| {
                    if (!std.mem.eql(u8, x.key, y.key) or !x.value.eql(y.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// `to-boolean`: "" , 0, NaN, null and false are false; everything else
    /// is true. Never errors.
    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .boolean => |b| b,
            .number => |n| n != 0 and !std.math.isNan(n),
            .string => |s| s.len != 0,
            .color => true,
            .array => true,
            .object => true,
        };
    }

    /// `to-string`: null is "", numbers print shortest-round-trip, a color
    /// prints as its rgba() form with 0-255 rgb and unit alpha, arrays and
    /// objects print as JSON (the reference serializes them JSON-style).
    pub fn toString(self: Value, alloc: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return switch (self) {
            .null => "",
            .boolean => |b| if (b) "true" else "false",
            .string => |s| s,
            .number => |n| blk: {
                if (std.math.isNan(n)) break :blk "NaN";
                if (n == @trunc(n) and @abs(n) < 1e15) {
                    break :blk try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(n))});
                }
                break :blk try std.fmt.allocPrint(alloc, "{d}", .{n});
            },
            .color => |c| blk: {
                const q = c.rgba8();
                break :blk try std.fmt.allocPrint(alloc, "rgba({d},{d},{d},{d})", .{ q[0], q[1], q[2], c.a });
            },
            .array, .object => blk: {
                var out: std.ArrayList(u8) = .empty;
                try self.writeJson(alloc, &out);
                break :blk out.items;
            },
        };
    }

    fn writeJson(self: Value, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
        switch (self) {
            .null => try out.appendSlice(alloc, "null"),
            .string => |s| {
                try out.append(alloc, '"');
                for (s) |c| switch (c) {
                    '"' => try out.appendSlice(alloc, "\\\""),
                    '\\' => try out.appendSlice(alloc, "\\\\"),
                    else => try out.append(alloc, c),
                };
                try out.append(alloc, '"');
            },
            .array => |items| {
                try out.append(alloc, '[');
                for (items, 0..) |it, i| {
                    if (i != 0) try out.append(alloc, ',');
                    try it.writeJson(alloc, out);
                }
                try out.append(alloc, ']');
            },
            .object => |entries| {
                try out.append(alloc, '{');
                for (entries, 0..) |e, i| {
                    if (i != 0) try out.append(alloc, ',');
                    try (Value{ .string = e.key }).writeJson(alloc, out);
                    try out.append(alloc, ':');
                    try e.value.writeJson(alloc, out);
                }
                try out.append(alloc, '}');
            },
            else => try out.appendSlice(alloc, try self.toString(alloc)),
        }
    }

    /// `to-number`: null is 0, booleans are 0/1, strings parse or fail.
    pub fn toNumber(self: Value) error{Coerce}!f64 {
        return switch (self) {
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch error.Coerce,
            else => error.Coerce,
        };
    }
};

test "strict equality is typed and null-safe" {
    try std.testing.expect(Value.eql(.{ .number = 1 }, .{ .number = 1 }));
    try std.testing.expect(!Value.eql(.{ .number = 1 }, .{ .string = "1" }));
    try std.testing.expect(!Value.eql(.null, .{ .number = 1 }));
    try std.testing.expect(Value.eql(.null, .null));
    try std.testing.expect(!Value.eql(.{ .boolean = true }, .{ .number = 1 }));
}

test "to-string of numbers and null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try (@as(Value, .null)).toString(a));
    try std.testing.expectEqualStrings("12", try (Value{ .number = 12.0 }).toString(a));
    try std.testing.expectEqualStrings("12.5", try (Value{ .number = 12.5 }).toString(a));
    try std.testing.expectEqualStrings("true", try (Value{ .boolean = true }).toString(a));
}

test "to-number coercions" {
    try std.testing.expectEqual(@as(f64, 0), try (@as(Value, .null)).toNumber());
    try std.testing.expectEqual(@as(f64, 1), try (Value{ .boolean = true }).toNumber());
    try std.testing.expectEqual(@as(f64, 2.5), try (Value{ .string = "2.5" }).toNumber());
    try std.testing.expectError(error.Coerce, (Value{ .string = "x" }).toNumber());
}

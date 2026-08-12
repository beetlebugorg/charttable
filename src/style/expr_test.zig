//! Expression corpus tests: semantics written against the published spec
//! pages, plus the exact shapes tile57's style generator emits (the first
//! styles charttable must render). Every case goes through JSON text →
//! parse → eval, the same path a real style takes.

const std = @import("std");
const exprs = @import("expr.zig");
const eval_mod = @import("eval.zig");
const Value = exprs.Value;

const TestFeature = struct {
    keys: []const []const u8,
    values: []const Value,

    fn get(ptr: ?*const anyopaque, key: []const u8) Value {
        const self: *const TestFeature = @ptrCast(@alignCast(ptr.?));
        for (self.keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return .null;
    }

    fn ref(self: *const TestFeature, geom: eval_mod.GeomType) eval_mod.Feature {
        return .{ .ptr = self, .get_fn = get, .geom = geom };
    }
};

fn run(arena: std.mem.Allocator, src: []const u8, ctx: *eval_mod.Context) !Value {
    const parsed = try exprs.parseText(arena, src);
    return eval_mod.eval(arena, parsed.root, ctx);
}

fn expectNum(src: []const u8, ctx: *eval_mod.Context, want: f64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try run(arena.allocator(), src, ctx);
    try std.testing.expect(v == .number);
    try std.testing.expectApproxEqAbs(want, v.number, 1e-9);
}

fn expectBool(src: []const u8, ctx: *eval_mod.Context, want: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try run(arena.allocator(), src, ctx);
    try std.testing.expect(v == .boolean);
    try std.testing.expectEqual(want, v.boolean);
}

fn expectStr(src: []const u8, ctx: *eval_mod.Context, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try run(arena.allocator(), src, ctx);
    try std.testing.expect(v == .string);
    try std.testing.expectEqualStrings(want, v.string);
}

var empty_ctx = eval_mod.Context{};

test "arithmetic and constants fold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try exprs.parseText(arena.allocator(),
        \\["+", 1, ["*", 2, 3], ["/", 8, 2]]
    );
    // No context deps: the whole tree must land as a literal.
    try std.testing.expect(p.root.* == .literal);
    try std.testing.expectApproxEqAbs(@as(f64, 11), p.root.literal.number, 1e-9);
    try std.testing.expect(!p.deps.any());
}

test "zoom-dependent trees do not fold and read the context" {
    var ctx = eval_mod.Context{ .zoom = 12.5 };
    try expectNum("[\"+\", [\"zoom\"], 1]", &ctx, 13.5);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try exprs.parseText(arena.allocator(), "[\"+\", [\"zoom\"], 1]");
    try std.testing.expect(p.deps.zoom);
    try std.testing.expect(p.root.* != .literal);
}

test "get/has and null semantics against an absent property" {
    const f = TestFeature{
        .keys = &.{ "color_token", "width_px", "rot_north" },
        .values = &.{ .{ .string = "DEPVS" }, .{ .number = 2 }, .null },
    };
    var ctx = eval_mod.Context{ .feature = f.ref(.line) };
    // the tile57 style's exact null-compare idiom: absent != 1 is TRUE
    try expectBool("[\"!=\", [\"get\", \"rot_north\"], 1]", &ctx, true);
    try expectBool("[\"==\", [\"get\", \"rot_north\"], 1]", &ctx, false);
    try expectBool("[\"has\", \"width_px\"]", &ctx, true);
    try expectBool("[\"has\", \"absent\"]", &ctx, false);
    try expectNum("[\"coalesce\", [\"get\", \"absent\"], 7]", &ctx, 7);
    try expectNum("[\"coalesce\", [\"get\", \"width_px\"], 1]", &ctx, 2);
}

test "the SCAMIN gate shape: <= against coalesced vz" {
    const f = TestFeature{ .keys = &.{"vz"}, .values = &.{.{ .number = 11.25 }} };
    var ctx = eval_mod.Context{ .zoom = 11.0, .feature = f.ref(.polygon) };
    try expectBool("[\"<=\", [\"coalesce\", [\"get\", \"vz\"], 0], [\"zoom\"]]", &ctx, false);
    ctx.zoom = 11.5; // fractional zooms must gate exactly
    try expectBool("[\"<=\", [\"coalesce\", [\"get\", \"vz\"], 0], [\"zoom\"]]", &ctx, true);
}

test "match over palette tokens, single and array labels" {
    const f = TestFeature{ .keys = &.{"tok"}, .values = &.{.{ .string = "DEPMD" }} };
    var ctx = eval_mod.Context{ .feature = f.ref(.polygon) };
    try expectStr(
        \\["match", ["get", "tok"], "DEPDW", "deep", ["DEPMD", "DEPMS"], "mid", "fallback"]
    , &ctx, "mid");
    try expectStr(
        \\["match", ["get", "absent"], "DEPDW", "deep", "fallback"]
    , &ctx, "fallback");
}

test "case with truthiness and fallback" {
    const f = TestFeature{ .keys = &.{"w"}, .values = &.{.{ .string = "bold" }} };
    var ctx = eval_mod.Context{ .feature = f.ref(.point) };
    try expectNum(
        \\["case", ["==", ["get", "w"], "bold"], 1.25, 0]
    , &ctx, 1.25);
    try expectNum(
        \\["case", ["==", ["get", "w"], "italic"], 1.25, 0]
    , &ctx, 0);
}

test "let/var with nested bindings (the fill-color idiom)" {
    const f = TestFeature{ .keys = &.{"ct"}, .values = &.{.{ .string = "TRFCF,0.75" }} };
    var ctx = eval_mod.Context{ .feature = f.ref(.polygon) };
    // nested lets: a binding must not reference a sibling, so tile57 nests
    try expectNum(
        \\["let", "ct", ["coalesce", ["get", "ct"], ""],
        \\  ["let", "ci", ["index-of", ",", ["var", "ct"]],
        \\    ["case", ["<", ["var", "ci"], 0], -1,
        \\      ["to-number", ["slice", ["var", "ct"], ["+", ["var", "ci"], 1]]]]]]
    , &ctx, 0.75);
}

test "string ops: concat coerces, slice and index-of count codepoints" {
    var ctx = eval_mod.Context{};
    try expectStr("[\"concat\", \"pat:\", [\"coalesce\", [\"get\", \"x\"], \"\"]]", &ctx, "pat:");
    try expectStr("[\"concat\", \"n=\", 12]", &ctx, "n=12");
    try expectStr("[\"slice\", \"SOUNDSB1,SOUNDS14\", 0, 8]", &ctx, "SOUNDSB1");
    try expectNum("[\"index-of\", \",\", \"SOUNDSB1,SOUNDS14\"]", &ctx, 8);
    try expectNum("[\"index-of\", \"x\", \"abc\"]", &ctx, -1);
    try expectStr("[\"upcase\", \"depvs\"]", &ctx, "DEPVS");
}

test "in: array membership and substring" {
    const f = TestFeature{ .keys = &.{"class"}, .values = &.{.{ .string = "WRECKS" }} };
    var ctx = eval_mod.Context{ .feature = f.ref(.point) };
    try expectBool(
        \\["in", ["get", "class"], ["literal", ["OBSTRN", "WRECKS", "UWTROC"]]]
    , &ctx, true);
    try expectBool(
        \\["in", ["get", "class"], ["literal", ["OBSTRN", "UWTROC"]]]
    , &ctx, false);
    try expectBool("[\"in\", \"ND\", \"SOUNDG\"]", &ctx, true);
}

test "colors: to-color, rgba, to-rgba round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try run(a, "[\"to-color\", \"#ff00ff\"]", &empty_ctx);
    try std.testing.expect(v == .color);
    try std.testing.expectApproxEqAbs(@as(f32, 1), v.color.r, 1e-5);
    const rt = try run(a,
        \\["at", 3, ["to-rgba", ["rgba", 255, 0, 255, 0.5]]]
    , &empty_ctx);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), rt.number, 1e-6);
    // invalid color string errors (falls to the property default upstream)
    try std.testing.expectError(error.Eval, run(a, "[\"to-color\", \"nope\"]", &empty_ctx));
    // ...unless a fallback argument saves it
    const fb = try run(a, "[\"to-color\", \"nope\", \"#000\"]", &empty_ctx);
    try std.testing.expect(fb == .color);
}

test "interpolate linear, exponential, and color" {
    var ctx = eval_mod.Context{ .zoom = 10 };
    try expectNum(
        \\["interpolate", ["linear"], ["zoom"], 8, 1, 12, 9]
    , &ctx, 5);
    // exponential base 2 over [8,12] at 10: (2^2-1)/(2^4-1) = 3/15 = 0.2
    try expectNum(
        \\["interpolate", ["exponential", 2], ["zoom"], 8, 0, 12, 1]
    , &ctx, 0.2);
    // clamps at the ends
    ctx.zoom = 20;
    try expectNum(
        \\["interpolate", ["linear"], ["zoom"], 8, 1, 12, 9]
    , &ctx, 9);
    // colors lerp componentwise
    ctx.zoom = 10;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try run(arena.allocator(),
        \\["interpolate", ["linear"], ["zoom"], 8, ["to-color", "#000000"], 12, ["to-color", "#ffffff"]]
    , &ctx);
    try std.testing.expect(v == .color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), v.color.g, 1e-5);
}

test "step picks the right band" {
    var ctx = eval_mod.Context{ .zoom = 11 };
    const src =
        \\["step", ["zoom"], "a", 10, "b", 14, "c"]
    ;
    try expectStr(src, &ctx, "b");
    ctx.zoom = 9.9;
    try expectStr(src, &ctx, "a");
    ctx.zoom = 14;
    try expectStr(src, &ctx, "c");
}

test "filters: errors are false, not poison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try exprs.parseText(arena.allocator(),
        \\["<", ["get", "not_a_number"], 5]
    );
    var ctx = eval_mod.Context{};
    try std.testing.expect(!eval_mod.evalFilter(arena.allocator(), p.root, &ctx));
}

test "all/any short-circuit and empty identities" {
    var ctx = eval_mod.Context{};
    // the second clause would error; all must not reach it
    try expectBool("[\"all\", false, [\"<\", \"x\", 1]]", &ctx, false);
    try expectBool("[\"any\", true, [\"<\", \"x\", 1]]", &ctx, true);
    try expectBool("[\"all\"]", &ctx, true);
    try expectBool("[\"any\"]", &ctx, false);
}

test "invalid expressions are parse errors, not crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidExpression, exprs.parseText(a, "[\"nope\", 1]"));
    try std.testing.expectError(error.InvalidExpression, exprs.parseText(a, "[1, 2, 3]")); // bare array
    try std.testing.expectError(error.InvalidExpression, exprs.parseText(a, "[\"var\", \"unbound\"]"));
    try std.testing.expectError(error.InvalidExpression, exprs.parseText(a,
        \\["interpolate", ["linear"], ["zoom"], 12, 1, 8, 2]
    )); // descending stops
}

test "geometry-type" {
    const f = TestFeature{ .keys = &.{}, .values = &.{} };
    var ctx = eval_mod.Context{ .feature = f.ref(.polygon) };
    try expectStr("[\"geometry-type\"]", &ctx, "Polygon");
}

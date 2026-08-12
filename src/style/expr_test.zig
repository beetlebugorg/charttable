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
    // a CONSTANT invalid color string is a compile error (the reference
    // folds the coercion at parse); a feature-driven one errors at eval
    try std.testing.expectError(error.InvalidExpression, exprs.parseText(a, "[\"to-color\", \"nope\"]"));
    try std.testing.expectError(error.Eval, run(a, "[\"to-color\", [\"get\", \"missing\"]]", &empty_ctx));
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
    // the second clause would error at eval; all/any must not reach it
    try expectBool("[\"all\", false, [\"<\", [\"get\", \"x\"], 1]]", &ctx, false);
    try expectBool("[\"any\", true, [\"<\", [\"get\", \"x\"], 1]]", &ctx, true);
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

// ---- static typechecker ----------------------------------------------------

fn expectRejects(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidExpression, exprs.parseText(arena.allocator(), src));
}

fn expectType(src: []const u8, want: exprs.Type) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try exprs.parseText(arena.allocator(), src);
    try std.testing.expectEqual(want, parsed.ty);
}

test "typecheck: comparisons need one comparable shared type" {
    // provable string-vs-number mismatch (both sides concretely typed)
    try expectRejects("[\"==\", [\"string\", [\"get\", \"x\"]], [\"number\", [\"get\", \"y\"]]]");
    try expectRejects("[\"<\", \"x\", 1]");
    // equality exists for null; ordering does not for null/boolean
    try expectRejects("[\"<\", null, null]");
    try expectRejects("[\">\", true, false]");
    // colors, arrays, objects don't equate
    try expectRejects("[\"==\", [\"get\", \"x\"], [\"to-color\", \"red\"]]");
    try expectRejects("[\"==\", [\"get\", \"x\"], [\"literal\", [1]]]");
    // one unknown side is fine — checked at eval
    try expectType("[\"==\", 1, [\"get\", \"x\"]]", .boolean);
    // a collator comparison is string-typed
    try expectRejects("[\"==\", 1, 2, [\"collator\", {}]]");
}

test "typecheck: typed operators reject provably wrong arguments" {
    try expectRejects("[\"upcase\", 1]");
    try expectRejects("[\"length\", 0]");
    try expectRejects("[\"slice\", true, 0]");
    try expectRejects("[\"join\", \"1+2+3\", \"+\"]");
    try expectRejects("[\"join\", [\"literal\", [1, 2]], \"+\"]"); // array<number>, not array<string>
    try expectRejects("[\"image\", 123]");
    try expectRejects("[\"in\", [\"literal\", [\"a\"]], [\"literal\", [[\"a\"]]]]"); // array needle
    try expectRejects("[\"!\", [\"case\", true, \"a\", \"b\"]]");
    // unknowns pass and defer to eval
    try expectType("[\"upcase\", [\"get\", \"name\"]]", .string);
    try expectType("[\"length\", [\"get\", \"xs\"]]", .number);
}

test "typecheck: match labels are uniform, unique, integral" {
    try expectRejects("[\"match\", [\"get\", \"x\"], \"a\", 1, 0, 2, 3]"); // mixed label types
    try expectRejects("[\"match\", 1, 1.5, \"a\", \"b\"]"); // non-integer label
    try expectRejects("[\"match\", 0, 10000000000000000, \"a\", \"b\"]"); // beyond 2^53-1
    try expectRejects("[\"match\", [\"string\", [\"get\", \"x\"]], \"0\", \"a\", \"0\", \"b\", \"c\"]"); // duplicate
    try expectRejects("[\"match\", [\"string\", [\"get\", \"x\"]], 0, \"a\", \"b\"]"); // input/label mismatch
    try expectRejects("[\"match\", [\"string\", [\"get\", \"x\"]], \"0\", \"a\", false]"); // outputs don't unify
    try expectType("[\"match\", [\"get\", \"x\"], [\"a\", \"b\"], \"ab\", \"other\"]", .string);
}

test "typecheck: interpolate needs an interpolatable output" {
    try expectRejects("[\"interpolate\", [\"linear\"], [\"zoom\"], 0, false, 1, true]");
    try expectRejects("[\"interpolate\", [\"linear\"], [\"zoom\"], 0, null, 1, null]");
    try expectRejects( // array<string, 1> does not interpolate
        \\["interpolate", ["exponential", 2], ["number", ["get", "x"]], 1, ["literal", ["a"]], 3, ["literal", ["b"]]]
    );
    try expectRejects( // unknown-length number arrays don't either
        \\["interpolate", ["linear"], ["zoom"], 0, ["array", "number", ["get", "a"]], 1, ["array", "number", ["get", "b"]]]
    );
    // interpolate-hcl outputs are colors: a non-color constant fails to fold
    try expectRejects("[\"interpolate-hcl\", [\"linear\"], [\"zoom\"], 0, \"reddish\", 1, \"blue\"]");
    try expectRejects("[\"interpolate-hcl\", [\"linear\"], [\"zoom\"], 0, 100, 1, 200]");
    // bare strings stay legal WITHOUT a pinned property type: real styles
    // interpolate color names and rely on the property coercion
    try expectType("[\"interpolate\", [\"linear\"], [\"zoom\"], 0, \"#000\", 1, \"#fff\"]", .string);
    // cubic-bezier takes exactly four control coordinates in [0,1]
    try expectRejects("[\"interpolate\", [\"cubic-bezier\", 0, 0, 1, 1, 1], [\"zoom\"], 0, 0, 1, 1]");
    try expectRejects("[\"interpolate\", [\"cubic-bezier\", 0, 1.75, 1, 1], [\"zoom\"], 0, 0, 1, 1]");
}

test "typecheck: array assertion syntax is strict" {
    try expectRejects("[\"array\", 0, [\"literal\", []]]"); // item type must be a name
    try expectRejects("[\"array\", \"value\", [\"literal\", []]]"); // ...one of number/string/boolean
    try expectRejects("[\"array\", \"string\", 0.5, [\"literal\", []]]"); // length must be integral
    try expectRejects("[\"array\", \"string\", [\"literal\", 0], [\"literal\", []]]"); // ...and literal
    try expectType("[\"array\", \"number\", 2, [\"get\", \"x\"]]", exprs.Type.arrayOf(.number, 2));
    try expectType("[\"array\", \"number\", null, [\"get\", \"x\"], [\"literal\", [0]]]", exprs.Type.arrayOf(.number, null));
}

test "typecheck: constant subtrees that fail to evaluate are compile errors" {
    // a missing key in a LITERAL object folds to null; asserting it fails
    try expectRejects("[\"number\", [\"get\", \"x\", [\"literal\", {\"y\": 0}]]]");
    // ...but a barrier (["error"], vars) keeps the failure at runtime
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try exprs.parseText(arena.allocator(), "[\"any\", false, [\"error\"]]");
    var ctx = eval_mod.Context{};
    try std.testing.expectError(error.Eval, eval_mod.eval(arena.allocator(), p.root, &ctx));
}

test "typecheck: let names, within literals" {
    try expectRejects("[\"let\", \"$a\", 1, [\"var\", \"$a\"]]");
    try expectRejects("[\"within\", [\"get\", \"geojson\"]]"); // must be a bare GeoJSON object
}

test "typecheck: var carries its binding's type" {
    try expectRejects("[\"let\", \"a\", \"str\", [\"+\", [\"var\", \"a\"], 1]]");
    try expectType("[\"let\", \"a\", [\"get\", \"x\"], [\"+\", [\"var\", \"a\"], 1]]", .number);
}

test "parseWithType: property expectations flow into the expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = (try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\["step", ["get", "x"], "black", 0, "invalid", 10, "blue"]
    , .{}));
    // under a color property, the constant string outputs must BE colors
    try std.testing.expectError(error.InvalidExpression, exprs.parseWithType(a, doc, .color));
    // with no pinned type the strings pass (the property layer coerces later)
    _ = try exprs.parseWithType(a, doc, null);

    const co = (try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\["coalesce", ["get", "a"], 5]
    , .{}));
    try std.testing.expectError(error.InvalidExpression, exprs.parseWithType(a, co, .string));
    const okc = try exprs.parseWithType(a, co, .number);
    try std.testing.expectEqual(exprs.Type.number, okc.ty);
}

test "parseWithType: zoom feeds one top-level curve only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "[\"+\", [\"zoom\"], 0]",
        "[\"+\", 0.5, [\"interpolate\", [\"linear\"], [\"zoom\"], 0, 0, 1, 1]]",
        "[\"let\", \"x\", [\"interpolate\", [\"linear\"], [\"zoom\"], 0, 0, 1, 1], [\"+\", 0.5, [\"get\", \"x\"]]]",
        "[\"coalesce\", [\"interpolate\", [\"linear\"], [\"zoom\"], 0, 0, 1, 1], [\"interpolate\", [\"linear\"], [\"zoom\"], 0, 0, 1, 1]]",
    };
    for (bad) |src| {
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
        try std.testing.expectError(error.InvalidExpression, exprs.parseWithType(a, doc, null));
    }
    const good = [_][]const u8{
        "[\"interpolate\", [\"linear\"], [\"zoom\"], 0, 0, 30, 30]",
        "[\"coalesce\", [\"interpolate\", [\"linear\"], [\"zoom\"], 0, 0, 30, 30]]",
        "[\"let\", \"x\", 1, [\"step\", [\"zoom\"], 0, 10, [\"var\", \"x\"]]]",
    };
    for (good) |src| {
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
        _ = try exprs.parseWithType(a, doc, null);
    }
    // plain parse (the style.zig path) keeps accepting bare zoom in filters
    _ = try exprs.parseText(a, "[\"<=\", [\"coalesce\", [\"get\", \"vz\"], 0], [\"zoom\"]]");
}

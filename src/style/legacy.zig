//! Legacy property functions: the deprecated pre-expression syntax
//! ({"type": "exponential", "stops": [...], "base": 2, "property": "p",
//! "default": ...}) converted at parse time into the expression AST, so the
//! evaluator and the compiler never know legacy existed.
//!
//! Semantics per the published spec's Function section, pinned by the
//! conformance fixtures:
//! - No "property" = a zoom function; with one, a property function; stop
//!   inputs that are {"zoom": z, "value": v} objects make it composite.
//! - The implicit type is "exponential" for interpolated properties,
//!   "interval" otherwise.
//! - identity asserts the property-spec type strictly (a string property
//!   does NOT to-string coerce here, unlike expression-typed properties).
//! - "default" catches any evaluation failure (absent property, wrong
//!   type, unmatched category).
//! - Duplicate/non-ascending stops keep the first occurrence.
//! - {token} substitution in string outputs applies to ZOOM functions only
//!   (a property function's outputs stay literal), when the property spec
//!   says tokens: true.

const std = @import("std");
const exprs = @import("expr.zig");
const Value = exprs.Value;
const Expr = exprs.Expr;
const Deps = exprs.Deps;
const ParseError = exprs.ParseError;

const Ctx = struct {
    arena: std.mem.Allocator,
    spec_type: []const u8, // "number" | "string" | "boolean" | "color" | "enum" | "array" | ...
    spec_item: ?[]const u8, // array item type
    spec_len: ?usize, // array length
    tokens: bool,
    property: ?[]const u8, // null = zoom function

    fn node(c: Ctx, e: Expr) ParseError!*const Expr {
        const n = try c.arena.create(Expr);
        n.* = e;
        return n;
    }

    fn lit(c: Ctx, v: Value) ParseError!*const Expr {
        return c.node(.{ .literal = v });
    }

    /// The function's input: ["zoom"] or ["get", property].
    fn input(c: Ctx) ParseError!*const Expr {
        if (c.property) |p| return c.node(.{ .get = .{ .key = p } });
        return c.node(.zoom);
    }

    /// The input asserted to a number (interval/exponential need it; a null
    /// or non-number property must fail into the default).
    fn numberInput(c: Ctx) ParseError!*const Expr {
        if (c.property == null) return c.input(); // zoom is always a number
        const args = try c.arena.alloc(*const Expr, 1);
        args[0] = try c.input();
        return c.node(.{ .assert_op = .{ .kind = .number, .args = args } });
    }

    /// A stop's output value as an expression, with token substitution for
    /// zoom functions of token-typed string properties.
    fn output(c: Ctx, v: Value) ParseError!*const Expr {
        if (c.tokens and c.property == null and v == .string) {
            if (try c.substituteTokens(v.string)) |e| return e;
        }
        return c.lit(v);
    }

    /// "0 {a}" -> ["concat", "0 ", ["to-string", ["get", "a"]]]; null when
    /// the string carries no tokens.
    fn substituteTokens(c: Ctx, s: []const u8) ParseError!?*const Expr {
        if (std.mem.indexOfScalar(u8, s, '{') == null) return null;
        var parts: std.ArrayList(*const Expr) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            const open = std.mem.indexOfScalarPos(u8, s, i, '{') orelse {
                try parts.append(c.arena, try c.lit(.{ .string = s[i..] }));
                break;
            };
            const close = std.mem.indexOfScalarPos(u8, s, open, '}') orelse {
                try parts.append(c.arena, try c.lit(.{ .string = s[i..] }));
                break;
            };
            if (open > i) try parts.append(c.arena, try c.lit(.{ .string = s[i..open] }));
            const name = s[open + 1 .. close];
            const get_args = try c.arena.alloc(*const Expr, 1);
            get_args[0] = try c.node(.{ .get = .{ .key = name } });
            try parts.append(c.arena, try c.node(.{ .op = .{ .op = .to_string, .args = get_args } }));
            i = close + 1;
        }
        return try c.node(.{ .op = .{ .op = .concat, .args = parts.items } });
    }

    /// identity: the property value under the spec type's strict assertion.
    fn identity(c: Ctx, has_default: bool, enum_values: ?std.json.Value) ParseError!*const Expr {
        const in = try c.input();
        // numberArray/colorArray/padding accept scalars and arrays; that
        // coercion is the property-spec layer's job, so identity passes the
        // raw value through.
        if (std.mem.eql(u8, c.spec_type, "numberArray") or
            std.mem.eql(u8, c.spec_type, "colorArray") or
            std.mem.eql(u8, c.spec_type, "padding"))
            return in;
        // enum: WITH a default, membership is enforced (a value outside the
        // enum falls to the default); without one, only string-ness is.
        if (std.mem.eql(u8, c.spec_type, "enum") and has_default) {
            if (enum_values) |vj| {
                if (vj == .object) {
                    var conds: std.ArrayList(*const Expr) = .empty;
                    var outs: std.ArrayList(*const Expr) = .empty;
                    var it = vj.object.iterator();
                    while (it.next()) |kv| {
                        const eq_args = try c.arena.alloc(*const Expr, 2);
                        eq_args[0] = in;
                        eq_args[1] = try c.lit(.{ .string = try c.arena.dupe(u8, kv.key_ptr.*) });
                        try conds.append(c.arena, try c.node(.{ .op = .{ .op = .eq, .args = eq_args } }));
                        try outs.append(c.arena, in);
                    }
                    const err_node = try c.node(.{ .op = .{ .op = .err, .args = &.{} } });
                    return c.node(.{ .case_op = .{ .conds = conds.items, .outs = outs.items, .fallback = err_node } });
                }
            }
        }
        if (std.mem.eql(u8, c.spec_type, "color")) {
            const args = try c.arena.alloc(*const Expr, 1);
            args[0] = in;
            return c.node(.{ .op = .{ .op = .to_color, .args = args } });
        }
        if (std.mem.eql(u8, c.spec_type, "array")) {
            var item: @FieldType(Expr.AssertArray, "item") = null;
            if (c.spec_item) |t| {
                if (std.mem.eql(u8, t, "number")) item = .number;
                if (std.mem.eql(u8, t, "string")) item = .string;
                if (std.mem.eql(u8, t, "boolean")) item = .boolean;
            }
            const args = try c.arena.alloc(*const Expr, 1);
            args[0] = in;
            return c.node(.{ .assert_array = .{ .item = item, .len = c.spec_len, .args = args } });
        }
        const kind: @FieldType(Expr.Assert, "kind") =
            if (std.mem.eql(u8, c.spec_type, "number"))
                .number
            else if (std.mem.eql(u8, c.spec_type, "boolean"))
                .boolean
            else
                .string; // string, enum, and anything string-shaped
        const args = try c.arena.alloc(*const Expr, 1);
        args[0] = in;
        return c.node(.{ .assert_op = .{ .kind = kind, .args = args } });
    }
};

const Stop = struct {
    zoom: ?f64, // composite stops carry a zoom level
    in: Value, // number for interval/exponential; any primitive for categorical
    out: Value,
};

fn jsonValue(arena: std.mem.Allocator, j: std.json.Value) ParseError!Value {
    return switch (j) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .number = @floatFromInt(i) },
        .float => |f| .{ .number = f },
        .number_string => |s| .{ .number = std.fmt.parseFloat(f64, s) catch return error.InvalidExpression },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |arr| blk: {
            const items = try arena.alloc(Value, arr.items.len);
            for (arr.items, 0..) |it, i| items[i] = try jsonValue(arena, it);
            break :blk .{ .array = items };
        },
        .object => error.InvalidExpression,
    };
}

fn parseStops(c: Ctx, j: std.json.Value) ParseError![]Stop {
    if (j != .array) return error.InvalidExpression;
    const stops = try c.arena.alloc(Stop, j.array.items.len);
    for (j.array.items, 0..) |item, i| {
        if (item != .array or item.array.items.len != 2) return error.InvalidExpression;
        const in_j = item.array.items[0];
        if (in_j == .object) {
            const z = in_j.object.get("zoom") orelse return error.InvalidExpression;
            const v = in_j.object.get("value") orelse return error.InvalidExpression;
            stops[i] = .{
                .zoom = switch (z) {
                    .integer => |n| @floatFromInt(n),
                    .float => |f| f,
                    else => return error.InvalidExpression,
                },
                .in = try jsonValue(c.arena, v),
                .out = try jsonValue(c.arena, item.array.items[1]),
            };
        } else {
            stops[i] = .{
                .zoom = null,
                .in = try jsonValue(c.arena, in_j),
                .out = try jsonValue(c.arena, item.array.items[1]),
            };
        }
    }
    return stops;
}

const FnType = enum { identity, exponential, interval, categorical };

/// Build the single-dimension function body over `stops` (already one zoom
/// level for composites, or the whole set for simple functions).
fn buildSimple(c: Ctx, ftype: FnType, base: f64, space: exprs.Expr.ColorSpace, stops: []const Stop, input_override: ?*const Expr) ParseError!*const Expr {
    switch (ftype) {
        .identity => unreachable, // handled in convert()
        .categorical => {
            // A case chain of strict equalities; no match ends in error (the
            // default wrapper catches it).
            var conds: std.ArrayList(*const Expr) = .empty;
            var outs: std.ArrayList(*const Expr) = .empty;
            const in = input_override orelse try c.input();
            for (stops) |s| {
                const eq_args = try c.arena.alloc(*const Expr, 2);
                eq_args[0] = in;
                eq_args[1] = try c.lit(s.in);
                try conds.append(c.arena, try c.node(.{ .op = .{ .op = .eq, .args = eq_args } }));
                try outs.append(c.arena, try c.output(s.out));
            }
            const err_node = try c.node(.{ .op = .{ .op = .err, .args = &.{} } });
            return c.node(.{ .case_op = .{ .conds = conds.items, .outs = outs.items, .fallback = err_node } });
        },
        .interval, .exponential => {
            // Numeric stop inputs, first occurrence wins on duplicates.
            var ins: std.ArrayList(f64) = .empty;
            var outs: std.ArrayList(*const Expr) = .empty;
            for (stops) |s| {
                const x = switch (s.in) {
                    .number => |n| n,
                    else => return error.InvalidExpression,
                };
                if (ins.items.len > 0 and x <= ins.items[ins.items.len - 1]) continue;
                try ins.append(c.arena, x);
                try outs.append(c.arena, try c.output(s.out));
            }
            if (ins.items.len == 0) return error.InvalidExpression;
            const in = input_override orelse try c.numberInput();
            if (ftype == .exponential) {
                return c.node(.{ .interp = .{
                    .kind = if (base == 1.0) .linear else .{ .exponential = base },
                    .input = in,
                    .stops = ins.items,
                    .outputs = outs.items,
                    .space = space,
                } });
            }
            // interval: the first stop's output applies from its input up;
            // below it, the first output still applies (clamped), so the
            // step's base output is outs[0] and thresholds start at ins[1].
            return c.node(.{ .step_op = .{
                .input = in,
                .thresholds = ins.items[1..],
                .outputs = outs.items,
            } });
        },
    }
}

/// Convert a legacy function object into a parsed expression.
pub fn convert(arena: std.mem.Allocator, j: std.json.Value, spec: ?std.json.Value) ParseError!exprs.Parsed {
    if (j != .object) return error.InvalidExpression;
    const obj = j.object;

    var spec_type: []const u8 = "number";
    var spec_item: ?[]const u8 = null;
    var spec_len: ?usize = null;
    var tokens = false;
    var interpolated = false;
    if (spec) |sj| {
        if (sj == .object) {
            if (sj.object.get("type")) |t| {
                if (t == .string) spec_type = t.string;
            }
            if (sj.object.get("value")) |v| {
                if (v == .string) spec_item = v.string;
            }
            if (sj.object.get("length")) |l| {
                if (l == .integer and l.integer >= 0) spec_len = @intCast(l.integer);
            }
            if (sj.object.get("tokens")) |t| tokens = t == .bool and t.bool;
            if (sj.object.get("expression")) |e| {
                if (e == .object) {
                    if (e.object.get("interpolated")) |ip| interpolated = ip == .bool and ip.bool;
                }
            }
        }
    }

    const c = Ctx{
        .arena = arena,
        .spec_type = spec_type,
        .spec_item = spec_item,
        .spec_len = spec_len,
        .tokens = tokens,
        .property = if (obj.get("property")) |p| (if (p == .string) p.string else null) else null,
    };

    const ftype: FnType = blk: {
        if (obj.get("type")) |t| {
            if (t == .string) {
                if (std.mem.eql(u8, t.string, "identity")) break :blk .identity;
                if (std.mem.eql(u8, t.string, "exponential")) break :blk .exponential;
                if (std.mem.eql(u8, t.string, "interval")) break :blk .interval;
                if (std.mem.eql(u8, t.string, "categorical")) break :blk .categorical;
                return error.InvalidExpression;
            }
        }
        break :blk if (interpolated) .exponential else .interval;
    };

    const base: f64 = if (obj.get("base")) |b| switch (b) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => 1.0,
    } else 1.0;

    const space: exprs.Expr.ColorSpace = blk: {
        const cs = obj.get("colorSpace") orelse break :blk .rgb;
        if (cs != .string) break :blk .rgb;
        if (std.mem.eql(u8, cs.string, "lab")) break :blk .lab;
        if (std.mem.eql(u8, cs.string, "hcl")) break :blk .hcl;
        break :blk .rgb;
    };

    // The default catches failures; the spec's own default applies when the
    // function has none.
    const default_j: ?std.json.Value = obj.get("default") orelse blk: {
        if (spec) |sj| {
            if (sj == .object) break :blk sj.object.get("default");
        }
        break :blk null;
    };
    const enum_values: ?std.json.Value = if (spec) |sj|
        (if (sj == .object) sj.object.get("values") else null)
    else
        null;

    var core: *const Expr = undefined;
    if (ftype == .identity) {
        core = try c.identity(default_j != null, enum_values);
    } else {
        const stops_j = obj.get("stops") orelse return error.InvalidExpression;
        const stops = try parseStops(c, stops_j);
        if (stops.len > 0 and stops[0].zoom != null) {
            // Composite (zoom-and-property): group stops by zoom level and
            // build the inner property function per level, then join the
            // levels over ["zoom"] — interpolating for exponential,
            // stepping otherwise.
            var level_zooms: std.ArrayList(f64) = .empty;
            var level_exprs: std.ArrayList(*const Expr) = .empty;
            var start: usize = 0;
            while (start < stops.len) {
                const z = stops[start].zoom.?;
                var end = start;
                while (end < stops.len and stops[end].zoom.? == z) end += 1;
                const inner = try buildSimple(c, ftype, base, space, stops[start..end], null);
                if (level_zooms.items.len == 0 or z > level_zooms.items[level_zooms.items.len - 1]) {
                    try level_zooms.append(arena, z);
                    try level_exprs.append(arena, inner);
                }
                start = end;
            }
            const zoom_node = try c.node(.zoom);
            core = if (ftype == .exponential)
                try c.node(.{ .interp = .{
                    .kind = if (base == 1.0) .linear else .{ .exponential = base },
                    .input = zoom_node,
                    .stops = level_zooms.items,
                    .outputs = level_exprs.items,
                    .space = space,
                } })
            else
                try c.node(.{ .step_op = .{
                    .input = zoom_node,
                    .thresholds = level_zooms.items[1..],
                    .outputs = level_exprs.items,
                } });
        } else {
            core = try buildSimple(c, ftype, base, space, stops, null);
        }
    }

    if (default_j) |d| {
        const default_lit = try c.lit(try jsonValue(arena, d));
        core = try c.node(.{ .fallback_try = .{ .attempt = core, .otherwise = default_lit } });
    }

    const deps = Deps{
        .feature = c.property != null or (tokens and c.property == null),
        .zoom = c.property == null or (ftype != .identity and blk: {
            const stops_j = obj.get("stops") orelse break :blk false;
            break :blk stops_j == .array and stops_j.array.items.len > 0 and
                stops_j.array.items[0] == .array and
                stops_j.array.items[0].array.items.len == 2 and
                stops_j.array.items[0].array.items[0] == .object;
        }),
    };
    return .{ .root = core, .deps = deps };
}

test "legacy conversion smoke: exponential zoom function with base" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const eval_mod = @import("eval.zig");
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"type": "exponential", "base": 0.5, "stops": [[0, 0], [1, 1]]}
    , .{});
    const parsed = try convert(arena, doc, null);
    var ctx = eval_mod.Context{ .zoom = 0.5 };
    const v = try eval_mod.eval(arena, parsed.root, &ctx);
    // (0.5^0.5 - 1) / (0.5^1 - 1) = 0.585786...
    try std.testing.expectApproxEqAbs(@as(f64, 0.585786), v.number, 1e-5);
}

test "legacy identity with default catches wrong types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const eval_mod = @import("eval.zig");
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"type": "identity", "property": "p", "default": -1}
    , .{});
    const spec = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"type": "number"}
    , .{});
    const parsed = try convert(arena, doc, spec);
    var ctx = eval_mod.Context{};
    const v = try eval_mod.eval(arena, parsed.root, &ctx); // property absent
    try std.testing.expectApproxEqAbs(@as(f64, -1), v.number, 1e-9);
}

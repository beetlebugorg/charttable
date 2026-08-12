//! Style-spec expression parsing: JSON in, typed AST out, constants folded.
//! Semantics per the published MapLibre Style Specification (expressions).
//!
//! Folding is the first line of the performance budget (the maplibre-branch
//! profile put ~half of all worker time in expression evaluation): any
//! subtree that reads neither the feature, the zoom, nor a binding collapses
//! to a literal at parse. A `match` over literal arms whose input is
//! feature-dependent stays a match, but each arm folds individually.
//!
//! All nodes live in the caller's arena; a parsed expression is immutable
//! and shared freely across threads.

const std = @import("std");
const vals = @import("value.zig");
pub const Value = vals.Value;
pub const Color = vals.Color;

pub const Op = enum {
    // comparison & logic (short-circuit handled in eval)
    eq,
    neq,
    lt,
    le,
    gt,
    ge,
    not,
    all,
    any,
    in,
    // string & array
    concat,
    length,
    at,
    slice,
    index_of,
    upcase,
    downcase,
    split,
    join,
    // arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    sqrt,
    abs,
    round,
    floor,
    ceil,
    min,
    max,
    ln,
    log10,
    log2,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    e_const,
    pi_const,
    ln2_const,
    // types
    to_string,
    to_number,
    to_boolean,
    to_color,
    to_rgba,
    rgba,
    rgb,
    typeof,
    err, // ["error", ...]: compiles, always errors at evaluation
    collator, // minimal: an options object consumed by ==/!= (tier 2: full)
};

pub const InterpKind = union(enum) {
    linear,
    exponential: f64,
    cubic_bezier: [4]f64,
};

pub const Expr = union(enum) {
    literal: Value,
    get: Prop,
    has: Prop,
    zoom,
    geometry_type,
    id,
    var_ref: u32, // index into the runtime binding stack
    global_state: []const u8, // map-level state, set by the host
    feature_state: *const Expr, // key expression; per-feature host state
    elevation,
    heatmap_density,
    line_progress,
    properties, // the feature's full property object
    let_bind: Let,
    op: OpCall,
    match_op: Match,
    case_op: Case,
    coalesce: []const *const Expr,
    interp: Interp,
    step_op: Step,
    assert_op: Assert,
    assert_array: AssertArray,
    /// ["semiliteral", template]: an array template whose elements are
    /// expressions, evaluated into an array (a primitive template folds to
    /// a literal at parse).
    array_of: []const *const Expr,
    /// Internal only (no JSON syntax): evaluate `attempt`; on ANY
    /// evaluation error, evaluate `otherwise`. The legacy property-function
    /// converter uses this for `default` values.
    fallback_try: struct {
        attempt: *const Expr,
        otherwise: *const Expr,
    },

    /// ["get", key] reads the feature; ["get", key, object] reads an object.
    pub const Prop = struct {
        key: []const u8,
        obj: ?*const Expr = null,
    };
    pub const Let = struct {
        values: []const *const Expr,
        body: *const Expr,
    };
    pub const OpCall = struct {
        op: Op,
        args: []const *const Expr,
    };
    pub const Branch = struct {
        label: Value, // string or number literal
        out: *const Expr,
    };
    pub const Match = struct {
        input: *const Expr,
        branches: []const Branch,
        fallback: *const Expr,
    };
    pub const Case = struct {
        conds: []const *const Expr,
        outs: []const *const Expr, // same length as conds
        fallback: *const Expr,
    };
    pub const Interp = struct {
        kind: InterpKind,
        input: *const Expr,
        stops: []const f64, // ascending literal inputs
        outputs: []const *const Expr,
        /// Color interpolation space (interpolate-lab / interpolate-hcl /
        /// legacy colorSpace).
        space: ColorSpace = .rgb,
    };
    pub const ColorSpace = enum { rgb, lab, hcl };
    pub const Step = struct {
        input: *const Expr,
        thresholds: []const f64, // ascending; outputs.len == thresholds.len + 1
        outputs: []const *const Expr,
    };
    /// Type assertion (["number", e, ...], ["string", ...], ["boolean", ...],
    /// ["object", ...]): evaluate each arg until one has the asserted type;
    /// error if none does.
    pub const Assert = struct {
        kind: enum { number, string, boolean, object },
        args: []const *const Expr,
    };
    /// ["array", type?, (N|null)?, value, fallback...]: candidates are
    /// tried in order; the first whose value is an array of the asserted
    /// item type and length wins.
    pub const AssertArray = struct {
        item: ?enum { number, string, boolean },
        len: ?usize,
        args: []const *const Expr,
    };
};

/// What a subtree reads from the evaluation context. No deps => foldable.
pub const Deps = struct {
    feature: bool = false,
    zoom: bool = false,
    binding: bool = false,
    /// Host-set state (global-state, feature-state, elevation, ...): not
    /// zoom- or feature-dependence, but still never foldable.
    global: bool = false,

    pub fn merge(a: Deps, b: Deps) Deps {
        return .{
            .feature = a.feature or b.feature,
            .zoom = a.zoom or b.zoom,
            .binding = a.binding or b.binding,
            .global = a.global or b.global,
        };
    }
    pub fn any(d: Deps) bool {
        return d.feature or d.zoom or d.binding or d.global;
    }
};

pub const Parsed = struct {
    root: *const Expr,
    deps: Deps,
};

pub const ParseError = error{ InvalidExpression, OutOfMemory };

const op_names = std.StaticStringMap(Op).initComptime(.{
    .{ "==", .eq },               .{ "!=", .neq },                .{ "<", .lt },
    .{ "<=", .le },               .{ ">", .gt },                  .{ ">=", .ge },
    .{ "!", .not },               .{ "all", .all },               .{ "any", .any },
    .{ "in", .in },               .{ "concat", .concat },         .{ "length", .length },
    .{ "at", .at },               .{ "slice", .slice },           .{ "index-of", .index_of },
    .{ "upcase", .upcase },       .{ "downcase", .downcase },     .{ "split", .split },
    .{ "join", .join },           .{ "+", .add },                 .{ "-", .sub },
    .{ "*", .mul },               .{ "/", .div },                 .{ "%", .mod },
    .{ "^", .pow },               .{ "sqrt", .sqrt },             .{ "abs", .abs },
    .{ "round", .round },         .{ "floor", .floor },           .{ "ceil", .ceil },
    .{ "min", .min },             .{ "max", .max },               .{ "ln", .ln },
    .{ "log10", .log10 },         .{ "log2", .log2 },             .{ "sin", .sin },
    .{ "cos", .cos },             .{ "tan", .tan },               .{ "asin", .asin },
    .{ "acos", .acos },           .{ "atan", .atan },             .{ "e", .e_const },
    .{ "pi", .pi_const },         .{ "ln2", .ln2_const },         .{ "to-string", .to_string },
    .{ "to-number", .to_number }, .{ "to-boolean", .to_boolean }, .{ "to-color", .to_color },
    .{ "to-rgba", .to_rgba },     .{ "rgba", .rgba },             .{ "rgb", .rgb },
    .{ "typeof", .typeof },       .{ "error", .err },             .{ "collator", .collator },
});

const Binding = struct {
    name: []const u8,
    deps: Deps,
};

const Parser = struct {
    arena: std.mem.Allocator,
    scope: std.ArrayList(Binding),

    const Res = struct { e: *const Expr, deps: Deps };

    fn node(p: *Parser, e: Expr) ParseError!*Expr {
        const n = try p.arena.create(Expr);
        n.* = e;
        return n;
    }

    /// Fold a dependency-free subtree to a literal. An eval error here is
    /// not fatal: the node stays and errors at runtime into the property
    /// default, which is the spec's behaviour for it.
    fn fold(p: *Parser, e: *const Expr, deps: Deps) *const Expr {
        if (deps.any()) return e;
        if (e.* == .literal) return e;
        const eval_mod = @import("eval.zig");
        var ctx = eval_mod.Context{};
        const v = eval_mod.eval(p.arena, e, &ctx) catch return e;
        const lit = p.arena.create(Expr) catch return e;
        lit.* = .{ .literal = v };
        return lit;
    }

    fn parseJson(p: *Parser, j: std.json.Value) ParseError!Res {
        switch (j) {
            .null => return .{ .e = try p.node(.{ .literal = .null }), .deps = .{} },
            .bool => |b| return .{ .e = try p.node(.{ .literal = .{ .boolean = b } }), .deps = .{} },
            .integer => |i| return .{ .e = try p.node(.{ .literal = .{ .number = @floatFromInt(i) } }), .deps = .{} },
            .float => |f| return .{ .e = try p.node(.{ .literal = .{ .number = f } }), .deps = .{} },
            .number_string => |s| {
                const f = std.fmt.parseFloat(f64, s) catch return error.InvalidExpression;
                return .{ .e = try p.node(.{ .literal = .{ .number = f } }), .deps = .{} };
            },
            .string => |s| return .{ .e = try p.node(.{ .literal = .{ .string = try p.arena.dupe(u8, s) } }), .deps = .{} },
            .object => return error.InvalidExpression, // object literals: tier 2
            .array => |arr| return p.parseCall(arr.items),
        }
    }

    fn parseCall(p: *Parser, items: []const std.json.Value) ParseError!Res {
        if (items.len == 0) return error.InvalidExpression;
        const head = switch (items[0]) {
            .string => |s| s,
            // A bare array is NOT an expression; the style layer wraps
            // constants before we ever see them.
            else => return error.InvalidExpression,
        };
        const args = items[1..];

        if (std.mem.eql(u8, head, "literal")) {
            if (args.len != 1) return error.InvalidExpression;
            const v = try p.jsonToValue(args[0]);
            return .{ .e = try p.node(.{ .literal = v }), .deps = .{} };
        }
        if (std.mem.eql(u8, head, "get") or std.mem.eql(u8, head, "has")) {
            if ((args.len != 1 and args.len != 2) or args[0] != .string) return error.InvalidExpression;
            const key = try p.arena.dupe(u8, args[0].string);
            var obj: ?*const Expr = null;
            var deps = Deps{ .feature = true };
            if (args.len == 2) {
                const r = try p.parseJson(args[1]);
                obj = p.fold(r.e, r.deps);
                deps = r.deps; // reading an object, not the feature
            }
            const prop = Expr.Prop{ .key = key, .obj = obj };
            const e = if (head[0] == 'g')
                try p.node(.{ .get = prop })
            else
                try p.node(.{ .has = prop });
            return .{ .e = p.fold(e, deps), .deps = deps };
        }
        if (std.mem.eql(u8, head, "zoom")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.zoom), .deps = .{ .zoom = true } };
        }
        if (std.mem.eql(u8, head, "global-state")) {
            if (args.len != 1 or args[0] != .string) return error.InvalidExpression;
            // Map-level state: never foldable, re-read per frame.
            return .{ .e = try p.node(.{ .global_state = try p.arena.dupe(u8, args[0].string) }), .deps = .{ .global = true } };
        }
        if (std.mem.eql(u8, head, "feature-state")) {
            // The key may be an expression (["feature-state", ["at", ...]]).
            if (args.len != 1) return error.InvalidExpression;
            const r = try p.parseJson(args[0]);
            const deps = r.deps.merge(.{ .feature = true });
            return .{ .e = try p.node(.{ .feature_state = p.fold(r.e, r.deps) }), .deps = deps };
        }
        if (std.mem.eql(u8, head, "elevation")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.elevation), .deps = .{ .global = true } };
        }
        if (std.mem.eql(u8, head, "heatmap-density")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.heatmap_density), .deps = .{ .global = true } };
        }
        if (std.mem.eql(u8, head, "line-progress")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.line_progress), .deps = .{ .global = true } };
        }
        if (std.mem.eql(u8, head, "properties")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.properties), .deps = .{ .feature = true } };
        }
        if (std.mem.eql(u8, head, "geometry-type")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.geometry_type), .deps = .{ .feature = true } };
        }
        if (std.mem.eql(u8, head, "id")) {
            if (args.len != 0) return error.InvalidExpression;
            return .{ .e = try p.node(.id), .deps = .{ .feature = true } };
        }
        if (std.mem.eql(u8, head, "var")) {
            if (args.len != 1 or args[0] != .string) return error.InvalidExpression;
            const name = args[0].string;
            var i = p.scope.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, p.scope.items[i].name, name)) {
                    var d = p.scope.items[i].deps;
                    d.binding = true;
                    return .{ .e = try p.node(.{ .var_ref = @intCast(i) }), .deps = d };
                }
            }
            return error.InvalidExpression;
        }
        if (std.mem.eql(u8, head, "number") or std.mem.eql(u8, head, "string") or
            std.mem.eql(u8, head, "boolean") or std.mem.eql(u8, head, "object"))
            return p.parseAssert(head, args);
        if (std.mem.eql(u8, head, "array")) return p.parseAssertArray(args);
        if (std.mem.eql(u8, head, "semiliteral")) return p.parseSemiliteral(args);
        if (std.mem.eql(u8, head, "let")) return p.parseLet(args);
        if (std.mem.eql(u8, head, "match")) return p.parseMatch(args);
        if (std.mem.eql(u8, head, "case")) return p.parseCase(args);
        if (std.mem.eql(u8, head, "coalesce")) return p.parseCoalesce(args);
        if (std.mem.eql(u8, head, "interpolate")) return p.parseInterpolate(args, .rgb);
        if (std.mem.eql(u8, head, "interpolate-lab")) return p.parseInterpolate(args, .lab);
        if (std.mem.eql(u8, head, "interpolate-hcl")) return p.parseInterpolate(args, .hcl);
        if (std.mem.eql(u8, head, "step")) return p.parseStep(args);

        const op = op_names.get(head) orelse return error.InvalidExpression;
        if (op == .collator) {
            // its single argument is an options OBJECT, not an expression
            if (args.len != 1 or args[0] != .object) return error.InvalidExpression;
            const v = try p.jsonToValue(args[0]);
            const lit = try p.node(.{ .literal = v });
            const call = try p.node(.{ .op = .{ .op = .collator, .args = try p.arena.dupe(*const Expr, &.{lit}) } });
            return .{ .e = call, .deps = .{} };
        }
        var deps = Deps{};
        const list = try p.arena.alloc(*const Expr, args.len);
        for (args, 0..) |a, i| {
            const r = try p.parseJson(a);
            deps = deps.merge(r.deps);
            list[i] = p.fold(r.e, r.deps);
        }
        try checkArity(op, list.len);
        const call = try p.node(.{ .op = .{ .op = op, .args = list } });
        return .{ .e = p.fold(call, deps), .deps = deps };
    }

    fn parseAssert(p: *Parser, head: []const u8, args: []const std.json.Value) ParseError!Res {
        if (args.len < 1) return error.InvalidExpression;
        const kind: @FieldType(Expr.Assert, "kind") =
            if (std.mem.eql(u8, head, "number")) .number else if (std.mem.eql(u8, head, "string")) .string else if (std.mem.eql(u8, head, "boolean")) .boolean else .object;
        const list = try p.arena.alloc(*const Expr, args.len);
        var deps = Deps{};
        for (args, 0..) |a, i| {
            const r = try p.parseJson(a);
            deps = deps.merge(r.deps);
            list[i] = p.fold(r.e, r.deps);
        }
        const e = try p.node(.{ .assert_op = .{ .kind = kind, .args = list } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseAssertArray(p: *Parser, args: []const std.json.Value) ParseError!Res {
        // ["array", type?, (N|null)?, value, fallback...]
        var item: @FieldType(Expr.AssertArray, "item") = null;
        var len: ?usize = null;
        var i: usize = 0;
        if (i < args.len and args[i] == .string) blk: {
            const t = args[i].string;
            if (std.mem.eql(u8, t, "number")) {
                item = .number;
            } else if (std.mem.eql(u8, t, "string")) {
                item = .string;
            } else if (std.mem.eql(u8, t, "boolean")) {
                item = .boolean;
            } else if (std.mem.eql(u8, t, "value")) {
                // "value" = any item type
            } else break :blk; // not a type name: it is the value expression
            i += 1;
            if (i < args.len) switch (args[i]) {
                .integer => |n| {
                    if (n < 0) return error.InvalidExpression;
                    len = @intCast(n);
                    i += 1;
                },
                .null => i += 1, // explicit "no length constraint"
                else => {},
            };
        }
        if (i >= args.len) return error.InvalidExpression;
        const list = try p.arena.alloc(*const Expr, args.len - i);
        var deps = Deps{};
        for (args[i..], 0..) |a, k| {
            const r = try p.parseJson(a);
            deps = deps.merge(r.deps);
            list[k] = p.fold(r.e, r.deps);
        }
        const e = try p.node(.{ .assert_array = .{ .item = item, .len = len, .args = list } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseSemiliteral(p: *Parser, args: []const std.json.Value) ParseError!Res {
        // ["semiliteral", template]: array elements are expressions; a
        // primitive template is just its value.
        if (args.len != 1) return error.InvalidExpression;
        switch (args[0]) {
            .array => |arr| {
                const list = try p.arena.alloc(*const Expr, arr.items.len);
                var deps = Deps{};
                for (arr.items, 0..) |it, i| {
                    const r = try p.parseJson(it);
                    deps = deps.merge(r.deps);
                    list[i] = p.fold(r.e, r.deps);
                }
                const e = try p.node(.{ .array_of = list });
                return .{ .e = p.fold(e, deps), .deps = deps };
            },
            .object => return error.InvalidExpression, // tier 2
            else => {
                const v = try p.jsonToValue(args[0]);
                return .{ .e = try p.node(.{ .literal = v }), .deps = .{} };
            },
        }
    }

    fn parseLet(p: *Parser, args: []const std.json.Value) ParseError!Res {
        // ["let", name1, value1, ..., body] — values parse in the OUTER
        // scope: a binding must not reference a sibling binding.
        if (args.len < 3 or args.len % 2 == 0) return error.InvalidExpression;
        const n_bind = (args.len - 1) / 2;
        const values = try p.arena.alloc(*const Expr, n_bind);
        var value_deps = try p.arena.alloc(Deps, n_bind);
        var deps = Deps{};
        for (0..n_bind) |i| {
            if (args[i * 2] != .string) return error.InvalidExpression;
            const r = try p.parseJson(args[i * 2 + 1]);
            values[i] = p.fold(r.e, r.deps);
            value_deps[i] = r.deps;
            deps = deps.merge(r.deps);
        }
        const scope_base = p.scope.items.len;
        for (0..n_bind) |i| {
            try p.scope.append(p.arena, .{ .name = args[i * 2].string, .deps = value_deps[i] });
        }
        const body = try p.parseJson(args[args.len - 1]);
        p.scope.shrinkRetainingCapacity(scope_base);
        deps = deps.merge(.{ .feature = body.deps.feature, .zoom = body.deps.zoom });
        const e = try p.node(.{ .let_bind = .{ .values = values, .body = p.fold(body.e, body.deps) } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseMatch(p: *Parser, args: []const std.json.Value) ParseError!Res {
        // ["match", input, label1, out1, ..., fallback]
        // args = input + k label/output pairs + fallback: even, at least 4.
        if (args.len < 4 or args.len % 2 != 0) return error.InvalidExpression;
        const input = try p.parseJson(args[0]);
        var deps = input.deps;
        var branches: std.ArrayList(Expr.Branch) = .empty;
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            const out = try p.parseJson(args[i + 1]);
            deps = deps.merge(out.deps);
            const folded = p.fold(out.e, out.deps);
            switch (args[i]) {
                .string => |s| try branches.append(p.arena, .{ .label = .{ .string = try p.arena.dupe(u8, s) }, .out = folded }),
                .integer => |n| try branches.append(p.arena, .{ .label = .{ .number = @floatFromInt(n) }, .out = folded }),
                .float => |f| try branches.append(p.arena, .{ .label = .{ .number = f }, .out = folded }),
                .array => |labels| {
                    if (labels.items.len == 0) return error.InvalidExpression;
                    for (labels.items) |l| switch (l) {
                        .string => |s| try branches.append(p.arena, .{ .label = .{ .string = try p.arena.dupe(u8, s) }, .out = folded }),
                        .integer => |n| try branches.append(p.arena, .{ .label = .{ .number = @floatFromInt(n) }, .out = folded }),
                        .float => |f| try branches.append(p.arena, .{ .label = .{ .number = f }, .out = folded }),
                        else => return error.InvalidExpression,
                    };
                },
                else => return error.InvalidExpression,
            }
        }
        const fb = try p.parseJson(args[args.len - 1]);
        deps = deps.merge(fb.deps);
        const e = try p.node(.{ .match_op = .{
            .input = p.fold(input.e, input.deps),
            .branches = branches.items,
            .fallback = p.fold(fb.e, fb.deps),
        } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseCase(p: *Parser, args: []const std.json.Value) ParseError!Res {
        // ["case", cond1, out1, ..., fallback]
        if (args.len < 3 or args.len % 2 == 0) return error.InvalidExpression;
        const n = (args.len - 1) / 2;
        const conds = try p.arena.alloc(*const Expr, n);
        const outs = try p.arena.alloc(*const Expr, n);
        var deps = Deps{};
        for (0..n) |i| {
            const c = try p.parseJson(args[i * 2]);
            const o = try p.parseJson(args[i * 2 + 1]);
            deps = deps.merge(c.deps).merge(o.deps);
            conds[i] = p.fold(c.e, c.deps);
            outs[i] = p.fold(o.e, o.deps);
        }
        const fb = try p.parseJson(args[args.len - 1]);
        deps = deps.merge(fb.deps);
        const e = try p.node(.{ .case_op = .{ .conds = conds, .outs = outs, .fallback = p.fold(fb.e, fb.deps) } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseCoalesce(p: *Parser, args: []const std.json.Value) ParseError!Res {
        if (args.len == 0) return error.InvalidExpression;
        const list = try p.arena.alloc(*const Expr, args.len);
        var deps = Deps{};
        for (args, 0..) |a, i| {
            const r = try p.parseJson(a);
            deps = deps.merge(r.deps);
            list[i] = p.fold(r.e, r.deps);
        }
        const e = try p.node(.{ .coalesce = list });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseInterpolate(p: *Parser, args: []const std.json.Value, space: Expr.ColorSpace) ParseError!Res {
        // ["interpolate", kind, input, stop1, out1, stop2, out2, ...]
        if (args.len < 4 or args.len % 2 != 0) return error.InvalidExpression;
        const kind = try parseInterpKind(args[0]);
        const input = try p.parseJson(args[1]);
        const n = (args.len - 2) / 2;
        const stops = try p.arena.alloc(f64, n);
        const outs = try p.arena.alloc(*const Expr, n);
        var deps = input.deps;
        for (0..n) |i| {
            stops[i] = switch (args[2 + i * 2]) {
                .integer => |v| @floatFromInt(v),
                .float => |v| v,
                else => return error.InvalidExpression, // stop inputs are literal numbers
            };
            if (i > 0 and stops[i] <= stops[i - 1]) return error.InvalidExpression;
            const r = try p.parseJson(args[3 + i * 2]);
            deps = deps.merge(r.deps);
            outs[i] = p.fold(r.e, r.deps);
        }
        const e = try p.node(.{ .interp = .{
            .kind = kind,
            .input = p.fold(input.e, input.deps),
            .stops = stops,
            .outputs = outs,
            .space = space,
        } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    fn parseStep(p: *Parser, args: []const std.json.Value) ParseError!Res {
        // ["step", input, out0, stop1, out1, stop2, out2, ...]
        if (args.len < 2 or args.len % 2 != 0) return error.InvalidExpression;
        const input = try p.parseJson(args[0]);
        var deps = input.deps;
        const first = try p.parseJson(args[1]);
        deps = deps.merge(first.deps);
        const n = (args.len - 2) / 2;
        const thresholds = try p.arena.alloc(f64, n);
        const outs = try p.arena.alloc(*const Expr, n + 1);
        outs[0] = p.fold(first.e, first.deps);
        for (0..n) |i| {
            thresholds[i] = switch (args[2 + i * 2]) {
                .integer => |v| @floatFromInt(v),
                .float => |v| v,
                else => return error.InvalidExpression,
            };
            if (i > 0 and thresholds[i] <= thresholds[i - 1]) return error.InvalidExpression;
            const r = try p.parseJson(args[3 + i * 2]);
            deps = deps.merge(r.deps);
            outs[i + 1] = p.fold(r.e, r.deps);
        }
        const e = try p.node(.{ .step_op = .{
            .input = p.fold(input.e, input.deps),
            .thresholds = thresholds,
            .outputs = outs,
        } });
        return .{ .e = p.fold(e, deps), .deps = deps };
    }

    /// ["literal", x]: convert a JSON value (with nested arrays) to a Value.
    fn jsonToValue(p: *Parser, j: std.json.Value) ParseError!Value {
        return switch (j) {
            .null => .null,
            .bool => |b| .{ .boolean = b },
            .integer => |i| .{ .number = @floatFromInt(i) },
            .float => |f| .{ .number = f },
            .number_string => |s| .{ .number = std.fmt.parseFloat(f64, s) catch return error.InvalidExpression },
            .string => |s| .{ .string = try p.arena.dupe(u8, s) },
            .array => |arr| blk: {
                const items = try p.arena.alloc(Value, arr.items.len);
                for (arr.items, 0..) |it, i| items[i] = try p.jsonToValue(it);
                break :blk .{ .array = items };
            },
            .object => |map| blk: {
                const entries = try p.arena.alloc(Value.Entry, map.count());
                var it = map.iterator();
                var i: usize = 0;
                while (it.next()) |kv| : (i += 1) {
                    entries[i] = .{
                        .key = try p.arena.dupe(u8, kv.key_ptr.*),
                        .value = try p.jsonToValue(kv.value_ptr.*),
                    };
                }
                break :blk .{ .object = entries };
            },
        };
    }
};

fn parseInterpKind(j: std.json.Value) ParseError!InterpKind {
    if (j != .array or j.array.items.len == 0 or j.array.items[0] != .string)
        return error.InvalidExpression;
    const name = j.array.items[0].string;
    const rest = j.array.items[1..];
    if (std.mem.eql(u8, name, "linear")) {
        return .linear; // extra args are ignored, as the reference does
    }
    if (std.mem.eql(u8, name, "exponential")) {
        if (rest.len < 1) return error.InvalidExpression;
        const base = switch (rest[0]) {
            .integer => |v| @as(f64, @floatFromInt(v)),
            .float => |v| v,
            else => return error.InvalidExpression,
        };
        if (!(base > 0)) return error.InvalidExpression;
        return .{ .exponential = base };
    }
    if (std.mem.eql(u8, name, "cubic-bezier")) {
        if (rest.len < 4) return error.InvalidExpression;
        var c: [4]f64 = undefined;
        for (rest[0..4], 0..) |v, i| c[i] = switch (v) {
            .integer => |x| @floatFromInt(x),
            .float => |x| x,
            else => return error.InvalidExpression,
        };
        return .{ .cubic_bezier = c };
    }
    return error.InvalidExpression;
}

fn checkArity(op: Op, n: usize) ParseError!void {
    const bad = switch (op) {
        .eq, .neq => n != 2 and n != 3, // optional collator argument
        .lt, .le, .gt, .ge => n != 2, // collator arg: tier 2
        .not, .length, .upcase, .downcase, .sqrt, .abs, .round, .floor, .ceil, .ln, .log10, .log2, .sin, .cos, .tan, .asin, .acos, .atan, .to_boolean, .to_rgba, .typeof => n != 1,
        .in, .at, .index_of => n != 2 and (op != .index_of or n != 3),
        .slice => n != 2 and n != 3,
        .div, .mod, .pow, .split, .join => n != 2,
        .sub => n != 1 and n != 2,
        .add, .mul, .min, .max, .all, .any, .concat => false, // zero args = identity
        .to_string => n != 1,
        .to_number, .to_color => n < 1, // fallback chains: try each in turn
        .rgba, .rgb => n != 4 and n != 3,
        .e_const, .pi_const, .ln2_const => n != 0,
        .err => false,
        .collator => n != 1,
    };
    if (bad) return error.InvalidExpression;
}

/// Parse an expression from parsed JSON. Everything lands in `arena`.
pub fn parse(arena: std.mem.Allocator, j: std.json.Value) ParseError!Parsed {
    var p = Parser{ .arena = arena, .scope = .empty };
    const r = try p.parseJson(j);
    return .{ .root = p.fold(r.e, r.deps), .deps = r.deps };
}

/// Parse an expression from JSON text (test/tool convenience).
pub fn parseText(arena: std.mem.Allocator, text: []const u8) !Parsed {
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return parse(arena, doc);
}

test {
    _ = @import("eval.zig");
}

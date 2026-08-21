//! Style-spec expression parsing: JSON in, typed AST out, constants folded.
//! Semantics per the published MapLibre Style Specification (expressions).
//!
//! Folding is the first line of the performance budget (the maplibre-branch
//! profile put ~half of all worker time in expression evaluation): any
//! subtree that reads neither the feature, the zoom, nor a binding collapses
//! to a literal at parse. A `match` over literal arms whose input is
//! feature-dependent stays a match, but each arm folds individually.
//!
//! Parsing also typechecks statically (typecheck.zig): provably wrong
//! argument types, non-unifiable branches, and constant subtrees whose
//! evaluation fails are compile errors, matching the reference's parser as
//! pinned by the conformance fixtures. A `value`-typed subexpression (raw
//! feature data) passes every check and fails at evaluation instead, which
//! is where the reference's injected runtime assertions would fail too.
//!
//! All nodes live in the caller's arena; a parsed expression is immutable
//! and shared freely across threads.

const std = @import("std");
const vals = @import("value.zig");
const geojson = @import("geojson.zig");
const tc = @import("typecheck.zig");
pub const Value = vals.Value;
pub const Color = vals.Color;
pub const Type = tc.Type;

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
    collator, // an options object consumed by the comparison operators
    is_supported_script, // true unless the host reports a missing script
    resolved_locale, // the collator's locale as given (no host locale data)
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
    within: *const Expr, // GeoJSON area the feature must fall inside
    distance: *const geojson.Geoms, // GeoJSON geometry measured against the feature
    number_format: NumberFormat,
    image_op: *const Expr, // name -> {name, available} against host images
    format_op: []const FormatSection,
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

    /// One ["format", ...] section: the content plus its style overrides.
    pub const FormatSection = struct {
        content: *const Expr,
        font_scale: ?*const Expr = null,
        text_font: ?*const Expr = null,
        text_color: ?*const Expr = null,
        vertical_align: ?*const Expr = null,
    };

    /// ["number-format", n, {locale, currency, unit, min/max-fraction-digits}]
    pub const NumberFormat = struct {
        input: *const Expr,
        currency: ?*const Expr = null,
        unit: ?*const Expr = null,
        min_frac: ?*const Expr = null,
        max_frac: ?*const Expr = null,
    };

    /// ["get", key] reads the feature; ["get", key, object] reads an object.
    pub const Prop = struct {
        key: []const u8,
        obj: ?*const Expr = null,
        /// A COMPUTED property name — ["get", ["concat", ...]] — evaluated to
        /// a string per feature. Null for the ordinary literal key; the
        /// reference allows either, and seamap styles build
        /// "seamark:<type>:restriction" this way.
        key_expr: ?*const Expr = null,
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
    /// Statically inferred result type; `value` = unknown-until-runtime.
    ty: tc.Type = .value,
};

pub const ParseError = error{ InvalidExpression, OutOfMemory };

const op_names = std.StaticStringMap(Op).initComptime(.{
    .{ "==", .eq },                                   .{ "!=", .neq },                          .{ "<", .lt },
    .{ "<=", .le },                                   .{ ">", .gt },                            .{ ">=", .ge },
    .{ "!", .not },                                   .{ "all", .all },                         .{ "any", .any },
    .{ "in", .in },                                   .{ "concat", .concat },                   .{ "length", .length },
    .{ "at", .at },                                   .{ "slice", .slice },                     .{ "index-of", .index_of },
    .{ "upcase", .upcase },                           .{ "downcase", .downcase },               .{ "split", .split },
    .{ "join", .join },                               .{ "+", .add },                           .{ "-", .sub },
    .{ "*", .mul },                                   .{ "/", .div },                           .{ "%", .mod },
    .{ "^", .pow },                                   .{ "sqrt", .sqrt },                       .{ "abs", .abs },
    .{ "round", .round },                             .{ "floor", .floor },                     .{ "ceil", .ceil },
    .{ "min", .min },                                 .{ "max", .max },                         .{ "ln", .ln },
    .{ "log10", .log10 },                             .{ "log2", .log2 },                       .{ "sin", .sin },
    .{ "cos", .cos },                                 .{ "tan", .tan },                         .{ "asin", .asin },
    .{ "acos", .acos },                               .{ "atan", .atan },                       .{ "e", .e_const },
    .{ "pi", .pi_const },                             .{ "ln2", .ln2_const },                   .{ "to-string", .to_string },
    .{ "to-number", .to_number },                     .{ "to-boolean", .to_boolean },           .{ "to-color", .to_color },
    .{ "to-rgba", .to_rgba },                         .{ "rgba", .rgba },                       .{ "rgb", .rgb },
    .{ "typeof", .typeof },                           .{ "error", .err },                       .{ "collator", .collator },
    .{ "is-supported-script", .is_supported_script }, .{ "resolved-locale", .resolved_locale },
});

const Binding = struct {
    name: []const u8,
    deps: Deps,
    ty: tc.Type,
};

fn numish(t: tc.Type) bool {
    return t == .number or t == .value or t == .err;
}
fn strish(t: tc.Type) bool {
    return t == .string or t == .value or t == .err;
}
fn boolish(t: tc.Type) bool {
    return t == .boolean or t == .value or t == .err;
}
/// A type the checker can hold against another (not an unknown).
fn concrete(t: tc.Type) bool {
    return t != .value and t != .err;
}

/// Static check of an operator's argument types; returns the result type.
/// Rules mirror the reference's operator signatures as pinned by the
/// fixtures (equal/*, less/*, in/invalid-needle-literal-array, join/*,
/// length/invalid-arg, slice/invalid-input-arg-literal, at/infer-array-type,
/// ...). `want` is the surrounding expectation — only ["at"] consumes it,
/// to pin the array's item type.
fn opType(op: Op, tys: []const tc.Type, want: ?tc.Type) ParseError!tc.Type {
    switch (op) {
        .eq, .neq => {
            if (tys.len == 3) {
                // A collator comparison is string-typed.
                if (!strish(tys[0]) or !strish(tys[1])) return error.InvalidExpression;
                if (concrete(tys[2]) and tys[2] != .collator) return error.InvalidExpression;
            } else {
                for (tys[0..2]) |t| switch (t) {
                    .string, .number, .boolean, .null_t, .value, .err => {},
                    else => return error.InvalidExpression, // color/array/object don't equate
                };
                if (concrete(tys[0]) and concrete(tys[1]) and
                    std.meta.activeTag(tys[0]) != std.meta.activeTag(tys[1]))
                    return error.InvalidExpression;
            }
            return .boolean;
        },
        .lt, .le, .gt, .ge => {
            if (tys.len == 3) {
                if (!strish(tys[0]) or !strish(tys[1])) return error.InvalidExpression;
                if (concrete(tys[2]) and tys[2] != .collator) return error.InvalidExpression;
            } else {
                for (tys[0..2]) |t| switch (t) {
                    .string, .number, .value, .err => {},
                    else => return error.InvalidExpression, // no boolean/null ordering
                };
                if (concrete(tys[0]) and concrete(tys[1]) and
                    std.meta.activeTag(tys[0]) != std.meta.activeTag(tys[1]))
                    return error.InvalidExpression;
            }
            return .boolean;
        },
        .not => {
            if (!boolish(tys[0])) return error.InvalidExpression;
            return .boolean;
        },
        .all, .any => {
            for (tys) |t| if (!boolish(t)) return error.InvalidExpression;
            return .boolean;
        },
        .in, .index_of => {
            switch (tys[0]) {
                .boolean, .string, .number, .null_t, .value, .err => {},
                else => return error.InvalidExpression, // needle must be primitive
            }
            switch (tys[1]) {
                .string, .array, .value, .err => {},
                .null_t => if (op == .index_of) return error.InvalidExpression,
                else => return error.InvalidExpression,
            }
            if (tys.len == 3 and !numish(tys[2])) return error.InvalidExpression;
            return if (op == .in) .boolean else .number;
        },
        .concat => return .string,
        .length => {
            switch (tys[0]) {
                .string, .array, .value, .err => {},
                else => return error.InvalidExpression,
            }
            return .number;
        },
        .at => {
            if (!numish(tys[0])) return error.InvalidExpression;
            const want_arr = tc.Type.arrayOf(tc.Type.asItem(want), null);
            if (!want_arr.accepts(tys[1])) return error.InvalidExpression;
            return switch (tys[1]) {
                .array => |a| tc.Type.itemAsType(a.item),
                else => want orelse .value,
            };
        },
        .slice => {
            switch (tys[0]) {
                .string, .array, .value, .err => {},
                else => return error.InvalidExpression,
            }
            for (tys[1..]) |t| if (!numish(t)) return error.InvalidExpression;
            return switch (tys[0]) {
                .string => .string,
                .array => |a| tc.Type.arrayOf(a.item, null),
                else => .value,
            };
        },
        .upcase, .downcase => {
            if (!strish(tys[0])) return error.InvalidExpression;
            return .string;
        },
        .split => {
            if (!strish(tys[0]) or !strish(tys[1])) return error.InvalidExpression;
            return tc.Type.arrayOf(.string, null);
        },
        .join => {
            if (!tc.Type.arrayOf(.string, null).accepts(tys[0])) return error.InvalidExpression;
            if (!strish(tys[1])) return error.InvalidExpression;
            return .string;
        },
        .add, .sub, .mul, .div, .mod, .pow, .min, .max, .sqrt, .abs, .round, .floor, .ceil, .ln, .log10, .log2, .sin, .cos, .tan, .asin, .acos, .atan => {
            for (tys) |t| if (!numish(t)) return error.InvalidExpression;
            return .number;
        },
        .e_const, .pi_const, .ln2_const => return .number,
        .to_string => return .string,
        .to_boolean => return .boolean,
        .to_number => return .number, // any inputs; failures fall through the chain
        .to_color => return .color,
        .to_rgba => {
            switch (tys[0]) {
                .color, .string, .value, .err => {},
                else => return error.InvalidExpression,
            }
            return tc.Type.arrayOf(.number, 4);
        },
        .rgba, .rgb => {
            for (tys) |t| if (!numish(t)) return error.InvalidExpression;
            return .color;
        },
        .typeof => return .string,
        .err => return .err,
        .collator => unreachable, // normalized before the generic path
        .is_supported_script => {
            if (!strish(tys[0])) return error.InvalidExpression;
            return .boolean;
        },
        .resolved_locale => {
            switch (tys[0]) {
                .collator, .value, .err => {},
                else => return error.InvalidExpression,
            }
            return .string;
        },
    }
}

const Parser = struct {
    arena: std.mem.Allocator,
    scope: std.ArrayList(Binding),

    const Res = struct {
        e: *const Expr,
        deps: Deps,
        ty: tc.Type = .value,
        /// "Reference-constant": the reference implementation would also
        /// fold this node (all children folded to literals; no error/
        /// collator/script/var/host barriers). An evaluation failure while
        /// folding such a node is a COMPILE error there, so it is here too
        /// (fixtures get/from-literal--missing, constant-folding/
        /// evaluation-error).
        rc: bool = false,
    };

    /// What the surrounding context requires of a subexpression.
    const Exp = struct {
        ty: ?tc.Type = null,
        /// Coalesce-argument position: the reference parses these without
        /// the runtime annotation, so a constant string in a color hole is
        /// not coerced (hence not validated) at compile time there.
        omit: bool = false,
    };

    fn node(p: *Parser, e: Expr) ParseError!*Expr {
        const n = try p.arena.create(Expr);
        n.* = e;
        return n;
    }

    /// Fold a dependency-free subtree to a literal. An eval error is fatal
    /// only for reference-constant nodes (see Res.rc); elsewhere the node
    /// stays and errors at runtime into the property default, which is the
    /// spec's behaviour for it.
    fn fold(p: *Parser, e: *const Expr, deps: Deps, fatal: bool) ParseError!*const Expr {
        if (deps.any()) return e;
        if (e.* == .literal) return e;
        const eval_mod = @import("eval.zig");
        var ctx = eval_mod.Context{};
        const v = eval_mod.eval(p.arena, e, &ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Eval => return if (fatal) error.InvalidExpression else e,
        };
        const lit = p.arena.create(Expr) catch return e;
        lit.* = .{ .literal = v };
        return lit;
    }

    /// Apply the context's type expectation to a parsed subexpression.
    fn expect(p: *Parser, r: Res, exp: Exp) ParseError!Res {
        _ = p;
        const want = exp.ty orelse return r;
        if (!want.accepts(r.ty)) return error.InvalidExpression;
        // The reference wraps a string in a color hole in a to-color
        // coercion and constant-folds it, so a CONSTANT string must parse
        // as a color here (fixtures constant-folding/evaluation-error,
        // interpolate-hcl/uninterpolable-output/{string,projection}).
        if (!exp.omit and want == .color and r.e.* == .literal and r.e.literal == .string) {
            const colors = @import("color.zig");
            if (colors.parse(r.e.literal.string) == null) return error.InvalidExpression;
        }
        return r;
    }

    /// Fold + typecheck tail shared by most parse paths.
    fn out(p: *Parser, e: *const Expr, deps: Deps, ty: tc.Type, rc: bool, exp: Exp) ParseError!Res {
        const folded = try p.fold(e, deps, rc);
        return p.expect(.{ .e = folded, .deps = deps, .ty = ty, .rc = rc }, exp);
    }

    fn parseJson(p: *Parser, j: std.json.Value, exp: Exp) ParseError!Res {
        switch (j) {
            .null => return p.expect(.{ .e = try p.node(.{ .literal = .null }), .deps = .{}, .ty = .null_t, .rc = true }, exp),
            .bool => |b| return p.expect(.{ .e = try p.node(.{ .literal = .{ .boolean = b } }), .deps = .{}, .ty = .boolean, .rc = true }, exp),
            .integer => |i| return p.expect(.{ .e = try p.node(.{ .literal = .{ .number = @floatFromInt(i) } }), .deps = .{}, .ty = .number, .rc = true }, exp),
            .float => |f| return p.expect(.{ .e = try p.node(.{ .literal = .{ .number = f } }), .deps = .{}, .ty = .number, .rc = true }, exp),
            .number_string => |s| {
                const f = std.fmt.parseFloat(f64, s) catch return error.InvalidExpression;
                return p.expect(.{ .e = try p.node(.{ .literal = .{ .number = f } }), .deps = .{}, .ty = .number, .rc = true }, exp);
            },
            .string => |s| return p.expect(.{ .e = try p.node(.{ .literal = .{ .string = try p.arena.dupe(u8, s) } }), .deps = .{}, .ty = .string, .rc = true }, exp),
            .object => return error.InvalidExpression, // object literals: tier 2
            .array => |arr| return p.parseCall(arr.items, exp),
        }
    }

    fn parseCall(p: *Parser, items: []const std.json.Value, exp: Exp) ParseError!Res {
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
            return p.expect(.{ .e = try p.node(.{ .literal = v }), .deps = .{}, .ty = tc.Type.ofValue(v), .rc = true }, exp);
        }
        if (std.mem.eql(u8, head, "get") or std.mem.eql(u8, head, "has")) {
            if (args.len != 1 and args.len != 2) return error.InvalidExpression;
            var key: []const u8 = "";
            var key_expr: ?*const Expr = null;
            var key_deps = Deps{};
            if (args[0] == .string) {
                key = try p.arena.dupe(u8, args[0].string);
            } else {
                const rk = try p.parseJson(args[0], .{ .ty = .string });
                const folded = try p.fold(rk.e, rk.deps, rk.rc);
                if (folded.* == .literal and folded.literal == .string) {
                    key = folded.literal.string; // folded to a constant name
                } else {
                    key_expr = folded;
                    key_deps = rk.deps;
                }
            }
            var obj: ?*const Expr = null;
            var deps = Deps{ .feature = true };
            var rc = false;
            if (args.len == 2) {
                const r = try p.parseJson(args[1], .{ .ty = .object });
                obj = try p.fold(r.e, r.deps, r.rc);
                deps = r.deps; // reading an object, not the feature
                rc = obj.?.* == .literal and key_expr == null;
            }
            deps = deps.merge(key_deps);
            const prop = Expr.Prop{ .key = key, .obj = obj, .key_expr = key_expr };
            const e = if (head[0] == 'g')
                try p.node(.{ .get = prop })
            else
                try p.node(.{ .has = prop });
            const ty: tc.Type = if (head[0] == 'g') .value else .boolean;
            return p.out(e, deps, ty, rc, exp);
        }
        if (std.mem.eql(u8, head, "zoom")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.zoom), .deps = .{ .zoom = true }, .ty = .number }, exp);
        }
        if (std.mem.eql(u8, head, "global-state")) {
            if (args.len != 1 or args[0] != .string) return error.InvalidExpression;
            // Map-level state: never foldable, re-read per frame.
            return p.expect(.{ .e = try p.node(.{ .global_state = try p.arena.dupe(u8, args[0].string) }), .deps = .{ .global = true }, .ty = .value }, exp);
        }
        if (std.mem.eql(u8, head, "feature-state")) {
            // The key may be an expression (["feature-state", ["at", ...]]).
            if (args.len != 1) return error.InvalidExpression;
            const r = try p.parseJson(args[0], .{ .ty = .string });
            const deps = r.deps.merge(.{ .feature = true });
            return p.expect(.{ .e = try p.node(.{ .feature_state = try p.fold(r.e, r.deps, r.rc) }), .deps = deps, .ty = .value }, exp);
        }
        if (std.mem.eql(u8, head, "elevation")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.elevation), .deps = .{ .global = true }, .ty = .number }, exp);
        }
        if (std.mem.eql(u8, head, "heatmap-density")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.heatmap_density), .deps = .{ .global = true }, .ty = .number }, exp);
        }
        if (std.mem.eql(u8, head, "line-progress")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.line_progress), .deps = .{ .global = true }, .ty = .number }, exp);
        }
        if (std.mem.eql(u8, head, "properties")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.properties), .deps = .{ .feature = true }, .ty = .object }, exp);
        }
        if (std.mem.eql(u8, head, "image")) {
            if (args.len != 1) return error.InvalidExpression;
            // The name is string-typed (fixtures image/invalid-image-name/*).
            const r = try p.parseJson(args[0], .{ .ty = .string });
            // availability is host state, so an image never folds
            const deps = r.deps.merge(.{ .global = true });
            return p.expect(.{ .e = try p.node(.{ .image_op = try p.fold(r.e, r.deps, r.rc) }), .deps = deps, .ty = .resolved_image }, exp);
        }
        if (std.mem.eql(u8, head, "format")) return p.parseFormat(args, exp);
        if (std.mem.eql(u8, head, "number-format")) {
            if (args.len != 2 or args[1] != .object) return error.InvalidExpression;
            const input = try p.parseJson(args[0], .{ .ty = .number });
            var deps = input.deps;
            var rc = true;
            var nf = Expr.NumberFormat{ .input = try p.fold(input.e, input.deps, input.rc) };
            rc = rc and nf.input.* == .literal;
            const opts = args[1].object;
            if (opts.get("currency") != null and opts.get("unit") != null)
                return error.InvalidExpression; // mutually exclusive
            const fields = [_]struct { name: []const u8, slot: *?*const Expr, want: tc.Type }{
                .{ .name = "currency", .slot = &nf.currency, .want = .string },
                .{ .name = "unit", .slot = &nf.unit, .want = .string },
                .{ .name = "min-fraction-digits", .slot = &nf.min_frac, .want = .number },
                .{ .name = "max-fraction-digits", .slot = &nf.max_frac, .want = .number },
            };
            for (fields) |f| {
                if (opts.get(f.name)) |jv| {
                    const r = try p.parseJson(jv, .{ .ty = f.want });
                    deps = deps.merge(r.deps);
                    f.slot.* = try p.fold(r.e, r.deps, r.rc);
                    rc = rc and f.slot.*.?.* == .literal;
                }
            }
            // locale parses for deps but is otherwise en-US-only for now
            if (opts.get("locale")) |jv| {
                const r = try p.parseJson(jv, .{ .ty = .string });
                deps = deps.merge(r.deps);
                rc = rc and (try p.fold(r.e, r.deps, r.rc)).* == .literal;
            }
            const e = try p.node(.{ .number_format = nf });
            return p.out(e, deps, .string, rc, exp);
        }
        if (std.mem.eql(u8, head, "within")) {
            // The argument is a bare GeoJSON OBJECT (a literal, not an
            // expression) carrying polygon geometry; an expression argument
            // does not compile (fixture: within/expression-geojson).
            if (args.len != 1 or args[0] != .object) return error.InvalidExpression;
            const lit = try p.node(.{ .literal = try p.jsonToValue(args[0]) });
            var polys: std.ArrayList(geojson.Polygon) = .empty;
            geojson.valueToPolygons(p.arena, lit.literal, &polys) catch return error.InvalidExpression;
            if (polys.items.len == 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.{ .within = lit }), .deps = .{ .feature = true }, .ty = .boolean }, exp);
        }
        if (std.mem.eql(u8, head, "distance")) {
            // The single argument is a bare GeoJSON OBJECT carrying at least
            // one geometry; an expression argument does not compile
            // (fixtures: expression-geometry, invalid-geometry).
            if (args.len != 1 or args[0] != .object) return error.InvalidExpression;
            const v = try p.jsonToValue(args[0]);
            const geoms = try p.arena.create(geojson.Geoms);
            geoms.* = geojson.valueToGeoms(p.arena, v) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => return error.InvalidExpression,
            };
            if (geoms.isEmpty()) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.{ .distance = geoms }), .deps = .{ .feature = true }, .ty = .number }, exp);
        }
        if (std.mem.eql(u8, head, "geometry-type")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.geometry_type), .deps = .{ .feature = true }, .ty = .string }, exp);
        }
        if (std.mem.eql(u8, head, "id")) {
            if (args.len != 0) return error.InvalidExpression;
            return p.expect(.{ .e = try p.node(.id), .deps = .{ .feature = true }, .ty = .value }, exp);
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
                    return p.expect(.{ .e = try p.node(.{ .var_ref = @intCast(i) }), .deps = d, .ty = p.scope.items[i].ty }, exp);
                }
            }
            return error.InvalidExpression;
        }
        if (std.mem.eql(u8, head, "number") or std.mem.eql(u8, head, "string") or
            std.mem.eql(u8, head, "boolean") or std.mem.eql(u8, head, "object"))
            return p.parseAssert(head, args, exp);
        if (std.mem.eql(u8, head, "array")) return p.parseAssertArray(args, exp);
        if (std.mem.eql(u8, head, "semiliteral")) return p.parseSemiliteral(args, exp);
        if (std.mem.eql(u8, head, "let")) return p.parseLet(args, exp);
        if (std.mem.eql(u8, head, "match")) return p.parseMatch(args, exp);
        if (std.mem.eql(u8, head, "case")) return p.parseCase(args, exp);
        if (std.mem.eql(u8, head, "coalesce")) return p.parseCoalesce(args, exp);
        if (std.mem.eql(u8, head, "interpolate")) return p.parseInterpolate(args, .rgb, exp);
        if (std.mem.eql(u8, head, "interpolate-lab")) return p.parseInterpolate(args, .lab, exp);
        if (std.mem.eql(u8, head, "interpolate-hcl")) return p.parseInterpolate(args, .hcl, exp);
        if (std.mem.eql(u8, head, "step")) return p.parseStep(args, exp);

        const op = op_names.get(head) orelse return error.InvalidExpression;
        if (op == .collator) {
            // Its single argument is an options OBJECT (not an expression),
            // but each option VALUE is an expression: normalized here to
            // exactly [case-sensitive, diacritic-sensitive, locale] args.
            if (args.len != 1 or args[0] != .object) return error.InvalidExpression;
            const opts = args[0].object;
            var deps = Deps{};
            var slots: [3]*const Expr = undefined;
            const names = [_][]const u8{ "case-sensitive", "diacritic-sensitive", "locale" };
            const wants = [_]tc.Type{ .boolean, .boolean, .string };
            for (names, 0..) |name, i| {
                if (opts.get(name)) |jv| {
                    const r = try p.parseJson(jv, .{ .ty = wants[i] });
                    deps = deps.merge(r.deps);
                    slots[i] = try p.fold(r.e, r.deps, r.rc);
                } else {
                    // sensitivities default to false; the locale to none
                    slots[i] = try p.node(.{ .literal = if (i == 2) .null else Value.false_ });
                }
            }
            const call = try p.node(.{ .op = .{ .op = .collator, .args = try p.arena.dupe(*const Expr, &slots) } });
            // a collator leans on host locale data: never reference-constant
            return p.out(call, deps, .collator, false, exp);
        }
        var deps = Deps{};
        const list = try p.arena.alloc(*const Expr, args.len);
        const tys = try p.arena.alloc(tc.Type, args.len);
        var rc = true;
        for (args, 0..) |a, i| {
            const r = try p.parseJson(a, .{});
            deps = deps.merge(r.deps);
            list[i] = try p.fold(r.e, r.deps, r.rc);
            tys[i] = r.ty;
            if (list[i].* != .literal) rc = false;
        }
        try checkArity(op, list.len);
        const ty = try opType(op, tys, exp.ty);
        switch (op) {
            // ["error"] never folds; script support is host state.
            .err, .is_supported_script => rc = false,
            else => {},
        }
        const call = try p.node(.{ .op = .{ .op = op, .args = list } });
        return p.out(call, deps, ty, rc, exp);
    }

    fn parseAssert(p: *Parser, head: []const u8, args: []const std.json.Value, exp: Exp) ParseError!Res {
        if (args.len < 1) return error.InvalidExpression;
        const kind: @FieldType(Expr.Assert, "kind") =
            if (std.mem.eql(u8, head, "number")) .number else if (std.mem.eql(u8, head, "string")) .string else if (std.mem.eql(u8, head, "boolean")) .boolean else .object;
        const list = try p.arena.alloc(*const Expr, args.len);
        var deps = Deps{};
        var rc = true;
        for (args, 0..) |a, i| {
            const r = try p.parseJson(a, .{});
            deps = deps.merge(r.deps);
            list[i] = try p.fold(r.e, r.deps, r.rc);
            if (list[i].* != .literal) rc = false;
        }
        const ty: tc.Type = switch (kind) {
            .number => .number,
            .string => .string,
            .boolean => .boolean,
            .object => .object,
        };
        const e = try p.node(.{ .assert_op = .{ .kind = kind, .args = list } });
        return p.out(e, deps, ty, rc, exp);
    }

    fn parseAssertArray(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["array", value] | ["array", type, value...] | ["array", type,
        // N|null, value...]. With two or more arguments the FIRST must name
        // an item type, and with three or more the SECOND must be a length
        // or null — the reference does not guess (fixtures array/invalid-
        // item-type/*, array/invalid-length/*, array/invalid-array-input/*).
        var item: @FieldType(Expr.AssertArray, "item") = null;
        var ity: tc.Item = .value;
        var len: ?usize = null;
        var i: usize = 0;
        if (args.len >= 2) {
            if (args[0] != .string) return error.InvalidExpression;
            const t = args[0].string;
            if (std.mem.eql(u8, t, "number")) {
                item = .number;
                ity = .number;
            } else if (std.mem.eql(u8, t, "string")) {
                item = .string;
                ity = .string;
            } else if (std.mem.eql(u8, t, "boolean")) {
                item = .boolean;
                ity = .boolean;
            } else return error.InvalidExpression;
            i = 1;
            if (args.len >= 3) {
                switch (args[1]) {
                    .integer => |n| {
                        if (n < 0) return error.InvalidExpression;
                        len = @intCast(n);
                    },
                    .null => {}, // explicit "no length constraint"
                    else => return error.InvalidExpression,
                }
                i = 2;
            }
        }
        if (i >= args.len) return error.InvalidExpression;
        const list = try p.arena.alloc(*const Expr, args.len - i);
        var deps = Deps{};
        var rc = true;
        for (args[i..], 0..) |a, k| {
            const r = try p.parseJson(a, .{});
            deps = deps.merge(r.deps);
            list[k] = try p.fold(r.e, r.deps, r.rc);
            if (list[k].* != .literal) rc = false;
        }
        const e = try p.node(.{ .assert_array = .{ .item = item, .len = len, .args = list } });
        return p.out(e, deps, tc.Type.arrayOf(ity, len), rc, exp);
    }

    fn parseSemiliteral(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["semiliteral", template]: array elements are expressions; a
        // primitive template is just its value.
        if (args.len != 1) return error.InvalidExpression;
        switch (args[0]) {
            .array => |arr| {
                const list = try p.arena.alloc(*const Expr, arr.items.len);
                var deps = Deps{};
                var rc = true;
                var item: ?tc.Item = null;
                var uniform = true;
                for (arr.items, 0..) |it, i| {
                    const r = try p.parseJson(it, .{});
                    deps = deps.merge(r.deps);
                    list[i] = try p.fold(r.e, r.deps, r.rc);
                    if (list[i].* != .literal) rc = false;
                    const k: ?tc.Item = switch (r.ty) {
                        .number => .number,
                        .string => .string,
                        .boolean => .boolean,
                        else => null,
                    };
                    if (k == null) {
                        uniform = false;
                    } else if (item) |prev| {
                        if (prev != k.?) uniform = false;
                    } else item = k;
                }
                const ity: tc.Item = if (uniform and item != null) item.? else .value;
                const e = try p.node(.{ .array_of = list });
                return p.out(e, deps, tc.Type.arrayOf(ity, arr.items.len), rc, exp);
            },
            .object => return error.InvalidExpression, // tier 2
            else => {
                const v = try p.jsonToValue(args[0]);
                return p.expect(.{ .e = try p.node(.{ .literal = v }), .deps = .{}, .ty = tc.Type.ofValue(v), .rc = true }, exp);
            },
        }
    }

    fn parseFormat(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["format", part, {opts}?, part, {opts}?, ...] — an options object
        // binds to the part before it.
        var sections: std.ArrayList(Expr.FormatSection) = .empty;
        var deps = Deps{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (args[i] == .object) return error.InvalidExpression; // options without a part
            const part = try p.parseJson(args[i], .{});
            deps = deps.merge(part.deps);
            var sec = Expr.FormatSection{ .content = try p.fold(part.e, part.deps, part.rc) };
            if (i + 1 < args.len and args[i + 1] == .object) {
                i += 1;
                const opts = args[i].object;
                const fields = [_]struct { name: []const u8, slot: *?*const Expr, want: tc.Type }{
                    .{ .name = "font-scale", .slot = &sec.font_scale, .want = .number },
                    .{ .name = "text-font", .slot = &sec.text_font, .want = tc.Type.arrayOf(.string, null) },
                    .{ .name = "text-color", .slot = &sec.text_color, .want = .color },
                    .{ .name = "vertical-align", .slot = &sec.vertical_align, .want = .string },
                };
                for (fields) |f| {
                    if (opts.get(f.name)) |jv| {
                        const r = try p.parseJson(jv, .{ .ty = f.want });
                        deps = deps.merge(r.deps);
                        f.slot.* = try p.fold(r.e, r.deps, r.rc);
                    }
                }
                // a constant vertical-align validates at parse
                if (sec.vertical_align) |va| {
                    if (va.* == .literal and va.literal == .string) {
                        const v = va.literal.string;
                        if (!std.mem.eql(u8, v, "bottom") and !std.mem.eql(u8, v, "center") and !std.mem.eql(u8, v, "top"))
                            return error.InvalidExpression;
                    }
                }
            }
            try sections.append(p.arena, sec);
        }
        const e = try p.node(.{ .format_op = sections.items });
        // formatted output: never folded (host images)
        return p.expect(.{ .e = e, .deps = deps, .ty = .formatted }, exp);
    }

    fn parseLet(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["let", name1, value1, ..., body] — values parse in the OUTER
        // scope: a binding must not reference a sibling binding.
        if (args.len < 3 or args.len % 2 == 0) return error.InvalidExpression;
        const n_bind = (args.len - 1) / 2;
        const values = try p.arena.alloc(*const Expr, n_bind);
        var value_deps = try p.arena.alloc(Deps, n_bind);
        var value_tys = try p.arena.alloc(tc.Type, n_bind);
        var deps = Deps{};
        var rc = true;
        for (0..n_bind) |i| {
            if (args[i * 2] != .string) return error.InvalidExpression;
            // Variable names are alphanumeric/underscore only (fixture
            // let/invalid-name).
            for (args[i * 2].string) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidExpression;
            }
            const r = try p.parseJson(args[i * 2 + 1], .{});
            values[i] = try p.fold(r.e, r.deps, r.rc);
            value_deps[i] = r.deps;
            value_tys[i] = r.ty;
            deps = deps.merge(r.deps);
            if (values[i].* != .literal) rc = false;
        }
        const scope_base = p.scope.items.len;
        for (0..n_bind) |i| {
            try p.scope.append(p.arena, .{ .name = args[i * 2].string, .deps = value_deps[i], .ty = value_tys[i] });
        }
        const body = try p.parseJson(args[args.len - 1], exp);
        p.scope.shrinkRetainingCapacity(scope_base);
        deps = deps.merge(.{ .feature = body.deps.feature, .zoom = body.deps.zoom });
        const folded_body = try p.fold(body.e, body.deps, body.rc);
        if (folded_body.* != .literal) rc = false;
        const e = try p.node(.{ .let_bind = .{ .values = values, .body = folded_body } });
        return p.out(e, deps, body.ty, rc, exp);
    }

    /// A match label: a string, or a number that is an integer within the
    /// reference's 2^53-1 bound (fixtures match/label-non-integer,
    /// match/label-overflow).
    fn matchLabel(p: *Parser, j: std.json.Value) ParseError!Value {
        const max_safe: f64 = 9007199254740991;
        switch (j) {
            .string => |s| return .{ .string = try p.arena.dupe(u8, s) },
            .integer => |n| {
                const f: f64 = @floatFromInt(n);
                if (@abs(f) > max_safe) return error.InvalidExpression;
                return .{ .number = f };
            },
            .float => |f| {
                if (f != @trunc(f) or @abs(f) > max_safe) return error.InvalidExpression;
                return .{ .number = f };
            },
            else => return error.InvalidExpression,
        }
    }

    fn parseMatch(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["match", input, label1, out1, ..., fallback]
        // args = input + k label/output pairs + fallback: even, at least 4.
        if (args.len < 4 or args.len % 2 != 0) return error.InvalidExpression;
        const input = try p.parseJson(args[0], .{});
        var deps = input.deps;
        var rc = input.e.* == .literal;
        var branches: std.ArrayList(Expr.Branch) = .empty;
        var label_is_string: ?bool = null;
        // Branch outputs unify: the expectation (when concrete) or the first
        // output pins the type (fixture match/mismatch-output).
        var out_ty: ?tc.Type = null;
        if (exp.ty) |t| {
            if (concrete(t)) out_ty = t;
        }
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            const out_r = try p.parseJson(args[i + 1], .{ .ty = out_ty });
            if (out_ty == null) out_ty = out_r.ty;
            deps = deps.merge(out_r.deps);
            const folded = try p.fold(out_r.e, out_r.deps, out_r.rc);
            if (folded.* != .literal) rc = false;
            const labels: []const std.json.Value = switch (args[i]) {
                .array => |ls| blk: {
                    if (ls.items.len == 0) return error.InvalidExpression;
                    break :blk ls.items;
                },
                else => (&args[i])[0..1],
            };
            for (labels) |lj| {
                const label = try p.matchLabel(lj);
                // labels share one type and must be unique (fixtures
                // match/labels-mixed-*, match/unreachable-branch-*)
                if (label_is_string) |is_str| {
                    if (is_str != (label == .string)) return error.InvalidExpression;
                } else label_is_string = label == .string;
                for (branches.items) |b| {
                    if (b.label.eql(label)) return error.InvalidExpression;
                }
                try branches.append(p.arena, .{ .label = label, .out = folded });
            }
        }
        // The input must be able to carry the labels' type (fixtures
        // match/mismatch-input*).
        if (concrete(input.ty)) {
            const ok = if (label_is_string.?) input.ty == .string else input.ty == .number;
            if (!ok) return error.InvalidExpression;
        }
        const fb = try p.parseJson(args[args.len - 1], .{ .ty = out_ty });
        if (out_ty == null) out_ty = fb.ty;
        deps = deps.merge(fb.deps);
        const folded_fb = try p.fold(fb.e, fb.deps, fb.rc);
        if (folded_fb.* != .literal) rc = false;
        const e = try p.node(.{ .match_op = .{
            .input = try p.fold(input.e, input.deps, input.rc),
            .branches = branches.items,
            .fallback = folded_fb,
        } });
        return p.out(e, deps, out_ty.?, rc, exp);
    }

    fn parseCase(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["case", cond1, out1, ..., fallback]
        if (args.len < 3 or args.len % 2 == 0) return error.InvalidExpression;
        const n = (args.len - 1) / 2;
        const conds = try p.arena.alloc(*const Expr, n);
        const outs = try p.arena.alloc(*const Expr, n);
        var deps = Deps{};
        var rc = true;
        var out_ty: ?tc.Type = null;
        if (exp.ty) |t| {
            if (concrete(t)) out_ty = t;
        }
        for (0..n) |i| {
            const c = try p.parseJson(args[i * 2], .{ .ty = .boolean });
            const o = try p.parseJson(args[i * 2 + 1], .{ .ty = out_ty });
            if (out_ty == null) out_ty = o.ty;
            deps = deps.merge(c.deps).merge(o.deps);
            conds[i] = try p.fold(c.e, c.deps, c.rc);
            outs[i] = try p.fold(o.e, o.deps, o.rc);
            if (conds[i].* != .literal or outs[i].* != .literal) rc = false;
        }
        const fb = try p.parseJson(args[args.len - 1], .{ .ty = out_ty });
        if (out_ty == null) out_ty = fb.ty;
        deps = deps.merge(fb.deps);
        const folded_fb = try p.fold(fb.e, fb.deps, fb.rc);
        if (folded_fb.* != .literal) rc = false;
        const e = try p.node(.{ .case_op = .{ .conds = conds, .outs = outs, .fallback = folded_fb } });
        return p.out(e, deps, out_ty.?, rc, exp);
    }

    fn parseCoalesce(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        if (args.len == 0) return error.InvalidExpression;
        // Arguments check against the surrounding expectation but stay
        // unwrapped (the reference omits the annotation so a null can fall
        // through): fixtures coalesce/argument-type-mismatch and
        // coalesce/infer-array-type still reject concrete mismatches.
        var seed: ?tc.Type = null;
        if (exp.ty) |t| {
            if (concrete(t)) seed = t;
        }
        const list = try p.arena.alloc(*const Expr, args.len);
        var deps = Deps{};
        var rc = true;
        var first_ty: tc.Type = .value;
        for (args, 0..) |a, i| {
            const r = try p.parseJson(a, .{ .ty = seed, .omit = true });
            if (i == 0) first_ty = r.ty;
            deps = deps.merge(r.deps);
            list[i] = try p.fold(r.e, r.deps, r.rc);
            if (list[i].* != .literal) rc = false;
        }
        const e = try p.node(.{ .coalesce = list });
        return p.out(e, deps, seed orelse first_ty, rc, exp);
    }

    fn parseInterpolate(p: *Parser, args: []const std.json.Value, space: Expr.ColorSpace, exp: Exp) ParseError!Res {
        // ["interpolate", kind, input, stop1, out1, stop2, out2, ...]
        if (args.len < 4 or args.len % 2 != 0) return error.InvalidExpression;
        const kind = try parseInterpKind(args[0]);
        const input = try p.parseJson(args[1], .{});
        if (!numish(input.ty)) return error.InvalidExpression;
        // Lab/HCL interpolate colors (or color arrays when the property asks
        // for them — fixture interpolate-hcl/linear-color-array); plain
        // interpolate takes the surrounding expectation, else the first
        // output pins it.
        var out_exp: ?tc.Type = null;
        switch (space) {
            .lab, .hcl => out_exp = if (exp.ty != null and exp.ty.? == .color_array) .color_array else .color,
            .rgb => if (exp.ty) |t| {
                if (concrete(t)) out_exp = t;
            },
        }
        var out_ty: ?tc.Type = out_exp;
        const n = (args.len - 2) / 2;
        const stops = try p.arena.alloc(f64, n);
        const outs = try p.arena.alloc(*const Expr, n);
        var deps = input.deps;
        var rc = input.e.* == .literal;
        for (0..n) |i| {
            stops[i] = switch (args[2 + i * 2]) {
                .integer => |v| @floatFromInt(v),
                .float => |v| v,
                else => return error.InvalidExpression, // stop inputs are literal numbers
            };
            if (i > 0 and stops[i] <= stops[i - 1]) return error.InvalidExpression;
            const r = try p.parseJson(args[3 + i * 2], .{ .ty = out_ty });
            if (out_ty == null) out_ty = r.ty;
            deps = deps.merge(r.deps);
            outs[i] = try p.fold(r.e, r.deps, r.rc);
            if (outs[i].* != .literal) rc = false;
        }
        // The output type must be interpolatable (fixtures interpolate/
        // uninterpolable-output/*, exponential-string-array). Without a
        // pinned expectation a string output may still be a color under the
        // property's later coercion, and a value resolves at runtime — the
        // reference meets those shapes only with the property type attached,
        // and plain `parse` (style.zig) never attaches one.
        const t = out_ty.?;
        const ok = t.interpolatable() or
            (out_exp == null and (t == .string or t == .value or t == .err));
        if (!ok) return error.InvalidExpression;
        const e = try p.node(.{ .interp = .{
            .kind = kind,
            .input = try p.fold(input.e, input.deps, input.rc),
            .stops = stops,
            .outputs = outs,
            .space = space,
        } });
        return p.out(e, deps, t, rc, exp);
    }

    fn parseStep(p: *Parser, args: []const std.json.Value, exp: Exp) ParseError!Res {
        // ["step", input, out0, stop1, out1, stop2, out2, ...]
        if (args.len < 2 or args.len % 2 != 0) return error.InvalidExpression;
        const input = try p.parseJson(args[0], .{});
        if (!numish(input.ty)) return error.InvalidExpression;
        var deps = input.deps;
        var rc = input.e.* == .literal;
        var out_ty: ?tc.Type = null;
        if (exp.ty) |t| {
            if (concrete(t)) out_ty = t;
        }
        const first = try p.parseJson(args[1], .{ .ty = out_ty });
        if (out_ty == null) out_ty = first.ty;
        deps = deps.merge(first.deps);
        const n = (args.len - 2) / 2;
        const thresholds = try p.arena.alloc(f64, n);
        const outs = try p.arena.alloc(*const Expr, n + 1);
        outs[0] = try p.fold(first.e, first.deps, first.rc);
        if (outs[0].* != .literal) rc = false;
        for (0..n) |i| {
            thresholds[i] = switch (args[2 + i * 2]) {
                .integer => |v| @floatFromInt(v),
                .float => |v| v,
                else => return error.InvalidExpression,
            };
            if (i > 0 and thresholds[i] <= thresholds[i - 1]) return error.InvalidExpression;
            const r = try p.parseJson(args[3 + i * 2], .{ .ty = out_ty });
            deps = deps.merge(r.deps);
            outs[i + 1] = try p.fold(r.e, r.deps, r.rc);
            if (outs[i + 1].* != .literal) rc = false;
        }
        const e = try p.node(.{ .step_op = .{
            .input = try p.fold(input.e, input.deps, input.rc),
            .thresholds = thresholds,
            .outputs = outs,
        } });
        return p.out(e, deps, out_ty.?, rc, exp);
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
        // exactly four numeric control coordinates, each within [0, 1]
        // (fixtures interpolate/cubic-bezier-5-args, -invalid-control-point)
        if (rest.len != 4) return error.InvalidExpression;
        var c: [4]f64 = undefined;
        for (rest, 0..) |v, i| c[i] = switch (v) {
            .integer => |x| @floatFromInt(x),
            .float => |x| x,
            else => return error.InvalidExpression,
        };
        for (c) |x| {
            if (!(x >= 0 and x <= 1)) return error.InvalidExpression;
        }
        return .{ .cubic_bezier = c };
    }
    return error.InvalidExpression;
}

fn checkArity(op: Op, n: usize) ParseError!void {
    const bad = switch (op) {
        .eq, .neq, .lt, .le, .gt, .ge => n != 2 and n != 3, // optional collator argument
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
        .collator => n != 3, // normalized by the parser
        .is_supported_script, .resolved_locale => n != 1,
    };
    if (bad) return error.InvalidExpression;
}

// ---- ["zoom"] placement (property expressions) ------------------------------

const ZoomFind = union(enum) {
    none,
    curve: *const Expr,
    fail,
};

fn zoomCurveHere(e: *const Expr) ?*const Expr {
    switch (e.*) {
        .step_op => |s| if (s.input.* == .zoom) return e,
        .interp => |ip| if (ip.input.* == .zoom) return e,
        else => {},
    }
    return null;
}

/// The reference's findZoomCurve, over our AST: locate the zoom curve
/// reachable through the "output spine" (let bodies, coalesce arguments, the
/// node itself), then sweep ALL children — a curve anywhere else, or a
/// second distinct curve, fails (fixtures zoom/invalid-*; zoom/nested-let
/// and zoom/nested-coalesce stay valid).
fn findZoomCurve(e: *const Expr) ZoomFind {
    const result: ZoomFind = switch (e.*) {
        .let_bind => |l| findZoomCurve(l.body),
        .coalesce => |list| blk: {
            for (list) |arg| {
                const r = findZoomCurve(arg);
                if (r != .none) break :blk r;
            }
            break :blk ZoomFind.none;
        },
        else => blk: {
            if (zoomCurveHere(e)) |c| break :blk ZoomFind{ .curve = c };
            break :blk ZoomFind.none;
        },
    };
    if (result == .fail) return result;
    var sweep = ZoomSweep{ .result = result };
    eachChild(e, &sweep, ZoomSweep.visit);
    return sweep.result;
}

const ZoomSweep = struct {
    result: ZoomFind,

    fn visit(self: *ZoomSweep, child: *const Expr) void {
        if (self.result == .fail) return;
        switch (findZoomCurve(child)) {
            .none => {},
            .fail => self.result = .fail,
            .curve => |c| switch (self.result) {
                // a curve below a non-curve position: zoom must feed a
                // TOP-LEVEL step/interpolate
                .none => self.result = .fail,
                .curve => |mine| {
                    if (mine != c) self.result = .fail; // two distinct curves
                },
                .fail => {},
            },
        }
    }
};

fn eachChild(e: *const Expr, ctx: anytype, comptime visit: anytype) void {
    switch (e.*) {
        .literal, .zoom, .geometry_type, .id, .var_ref, .global_state, .elevation, .heatmap_density, .line_progress, .properties, .distance => {},
        .get, .has => |prop| {
            if (prop.obj) |o| visit(ctx, o);
            if (prop.key_expr) |k| visit(ctx, k);
        },
        .feature_state => |k| visit(ctx, k),
        .within => |w| visit(ctx, w),
        .image_op => |img| visit(ctx, img),
        .format_op => |sections| for (sections) |sec| {
            visit(ctx, sec.content);
            if (sec.font_scale) |x| visit(ctx, x);
            if (sec.text_font) |x| visit(ctx, x);
            if (sec.text_color) |x| visit(ctx, x);
            if (sec.vertical_align) |x| visit(ctx, x);
        },
        .number_format => |nf| {
            visit(ctx, nf.input);
            if (nf.currency) |x| visit(ctx, x);
            if (nf.unit) |x| visit(ctx, x);
            if (nf.min_frac) |x| visit(ctx, x);
            if (nf.max_frac) |x| visit(ctx, x);
        },
        .let_bind => |l| {
            for (l.values) |v| visit(ctx, v);
            visit(ctx, l.body);
        },
        .op => |call| for (call.args) |a| visit(ctx, a),
        .match_op => |m| {
            visit(ctx, m.input);
            for (m.branches) |b| visit(ctx, b.out);
            visit(ctx, m.fallback);
        },
        .case_op => |c| {
            for (c.conds) |x| visit(ctx, x);
            for (c.outs) |x| visit(ctx, x);
            visit(ctx, c.fallback);
        },
        .coalesce => |list| for (list) |x| visit(ctx, x),
        .interp => |ip| {
            visit(ctx, ip.input);
            for (ip.outputs) |x| visit(ctx, x);
        },
        .step_op => |s| {
            visit(ctx, s.input);
            for (s.outputs) |x| visit(ctx, x);
        },
        .assert_op => |a| for (a.args) |x| visit(ctx, x),
        .assert_array => |a| for (a.args) |x| visit(ctx, x),
        .array_of => |list| for (list) |x| visit(ctx, x),
        .fallback_try => |f| {
            visit(ctx, f.attempt);
            visit(ctx, f.otherwise);
        },
    }
}

/// Parse an expression from parsed JSON. Everything lands in `arena`.
/// Statically typechecks, but attaches no outer type expectation and skips
/// the ["zoom"] placement rule — this is the reference's plain-expression
/// path (filters use bare ["zoom"] comparisons; tile57's styles depend on
/// that).
pub fn parse(arena: std.mem.Allocator, j: std.json.Value) ParseError!Parsed {
    var p = Parser{ .arena = arena, .scope = .empty };
    const r = try p.parseJson(j, .{});
    return .{ .root = try p.fold(r.e, r.deps, r.rc), .deps = r.deps, .ty = r.ty };
}

/// Parse as the reference parses a PROPERTY expression: `expected` is the
/// property's type (the conformance harness derives it from the fixture's
/// propertySpec), and ["zoom"] may only feed one top-level ["step"] or
/// ["interpolate"] curve.
pub fn parseWithType(arena: std.mem.Allocator, j: std.json.Value, expected: ?tc.Type) ParseError!Parsed {
    var p = Parser{ .arena = arena, .scope = .empty };
    const r = try p.parseJson(j, .{ .ty = expected });
    if (r.deps.zoom and findZoomCurve(r.e) != .curve) return error.InvalidExpression;
    return .{ .root = try p.fold(r.e, r.deps, r.rc), .deps = r.deps, .ty = r.ty };
}

/// Parse an expression from JSON text (test/tool convenience).
pub fn parseText(arena: std.mem.Allocator, text: []const u8) !Parsed {
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return parse(arena, doc);
}

test {
    _ = @import("eval.zig");
    _ = @import("typecheck.zig");
}

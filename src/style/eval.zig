//! Expression evaluation. `eval` never panics and never throws past its
//! error set: a type mismatch is error.Eval, and the caller (a property
//! evaluation, a filter) turns that into the property default or false —
//! the spec's fallback behaviour. Results allocate in the caller's arena,
//! reset per tile batch.
//!
//! Documented deviations (the spec measures string positions in UTF-16 code
//! units, a JavaScript-ism): `length`, `slice` and `index-of` on strings
//! count Unicode codepoints here. Identical for ASCII, which is what
//! machine-generated styles compare.

const std = @import("std");
const exprs = @import("expr.zig");
const colors = @import("color.zig");
const vals = @import("value.zig");
const geojson = @import("geojson.zig");

pub const Value = vals.Value;
pub const Color = vals.Color;
pub const Expr = exprs.Expr;

pub const GeomType = enum { unknown, point, line, polygon };

/// How the evaluator reads a feature. Implemented by the tile decoder; the
/// default is the empty feature (every property absent).
pub const Feature = struct {
    ptr: ?*const anyopaque = null,
    get_fn: *const fn (?*const anyopaque, key: []const u8) Value = emptyGet,
    /// Distinguishes present-with-null from absent (`has` is true for a
    /// property that exists with a null value). Defaults to get != null.
    has_fn: ?*const fn (?*const anyopaque, key: []const u8) bool = null,
    /// The full property object, for ["properties"]. Optional: decoders
    /// that cannot enumerate return null and the operator errors.
    props_fn: ?*const fn (?*const anyopaque) Value = null,
    geom: GeomType = .unknown,
    /// lon/lat geometry for ["within"] / ["distance"]; optional.
    geometry: ?geojson.Geometry = null,
    id: Value = .null,

    fn emptyGet(_: ?*const anyopaque, _: []const u8) Value {
        return .null;
    }
    pub fn get(self: Feature, key: []const u8) Value {
        return self.get_fn(self.ptr, key);
    }
    pub fn has(self: Feature, key: []const u8) bool {
        if (self.has_fn) |f| return f(self.ptr, key);
        return self.get_fn(self.ptr, key) != .null;
    }
};

pub const Context = struct {
    zoom: f64 = 0,
    feature: Feature = .{},
    /// Map-level state the host sets (["global-state", key]).
    global_state: []const Value.Entry = &.{},
    /// Host state for the CURRENT feature (["feature-state", key]).
    feature_state: []const Value.Entry = &.{},
    elevation: f64 = 0,
    heatmap_density: f64 = 0,
    line_progress: f64 = 0,
    /// Sprite images the host has loaded (["image"] availability).
    available_images: []const []const u8 = &.{},
    /// Runtime `let` bindings; managed by eval (push on let entry, pop on
    /// exit). Parse-time indices line up with this stack by construction.
    bindings: std.ArrayList(Value) = .empty,
};

pub const Error = error{ Eval, OutOfMemory };

pub fn eval(a: std.mem.Allocator, e: *const Expr, ctx: *Context) Error!Value {
    switch (e.*) {
        .literal => |v| return v,
        .get => |prop| {
            if (prop.obj) |obj_e| {
                const obj = try eval(a, obj_e, ctx);
                const entries = switch (obj) {
                    .object => |entries| entries,
                    else => return error.Eval,
                };
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, prop.key)) return entry.value;
                }
                return .null;
            }
            return ctx.feature.get(prop.key);
        },
        .has => |prop| {
            if (prop.obj) |obj_e| {
                const obj = try eval(a, obj_e, ctx);
                const entries = switch (obj) {
                    .object => |entries| entries,
                    else => return error.Eval,
                };
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, prop.key)) return Value.true_;
                }
                return Value.false_;
            }
            return .{ .boolean = ctx.feature.has(prop.key) };
        },
        .zoom => return .{ .number = ctx.zoom },
        .geometry_type => return .{ .string = switch (ctx.feature.geom) {
            .point => "Point",
            .line => "LineString",
            .polygon => "Polygon",
            .unknown => return error.Eval,
        } },
        .id => return ctx.feature.id,
        .global_state => |key| {
            for (ctx.global_state) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return .null;
        },
        .feature_state => |key_e| {
            const key = switch (try eval(a, key_e, ctx)) {
                .string => |s| s,
                else => return error.Eval,
            };
            for (ctx.feature_state) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return .null;
        },
        .elevation => return .{ .number = ctx.elevation },
        .heatmap_density => return .{ .number = ctx.heatmap_density },
        .line_progress => return .{ .number = ctx.line_progress },
        .properties => {
            const f = ctx.feature.props_fn orelse return error.Eval;
            return f(ctx.feature.ptr);
        },
        .image_op => |name_e| {
            const name = switch (try eval(a, name_e, ctx)) {
                .string => |s| s,
                else => return error.Eval,
            };
            var available = false;
            for (ctx.available_images) |img| {
                if (std.mem.eql(u8, img, name)) {
                    available = true;
                    break;
                }
            }
            const entries = try a.alloc(Value.Entry, 2);
            entries[0] = .{ .key = "name", .value = .{ .string = name } };
            entries[1] = .{ .key = "available", .value = .{ .boolean = available } };
            return .{ .object = entries };
        },
        .format_op => |sections| {
            const out = try a.alloc(Value, sections.len);
            for (sections, 0..) |sec, i| {
                var text: []const u8 = "";
                var image: Value = .null;
                const content = try eval(a, sec.content, ctx);
                if (isImageValue(content)) {
                    image = content;
                } else {
                    text = try content.toString(a);
                }
                var scale: Value = .null;
                if (sec.font_scale) |e2| scale = try eval(a, e2, ctx);
                var font_stack: Value = .null;
                if (sec.text_font) |e2| {
                    const fonts = switch (try eval(a, e2, ctx)) {
                        .array => |items| items,
                        else => return error.Eval,
                    };
                    var joined: std.ArrayList(u8) = .empty;
                    for (fonts, 0..) |f, j| {
                        if (f != .string) return error.Eval;
                        if (j != 0) try joined.append(a, ',');
                        try joined.appendSlice(a, f.string);
                    }
                    font_stack = .{ .string = joined.items };
                }
                var text_color: Value = .null;
                if (sec.text_color) |e2| {
                    const cv = try eval(a, e2, ctx);
                    text_color = switch (cv) {
                        .color => cv,
                        .string => |cs| if (colors.parse(cs)) |c| .{ .color = c } else return error.Eval,
                        else => return error.Eval,
                    };
                }
                var valign: Value = .null;
                if (sec.vertical_align) |e2| {
                    const vv = try eval(a, e2, ctx);
                    if (vv != .string) return error.Eval;
                    const s2 = vv.string;
                    if (!std.mem.eql(u8, s2, "bottom") and !std.mem.eql(u8, s2, "center") and !std.mem.eql(u8, s2, "top"))
                        return error.Eval;
                    valign = vv;
                }
                const entries = try a.alloc(Value.Entry, 6);
                entries[0] = .{ .key = "text", .value = .{ .string = text } };
                entries[1] = .{ .key = "image", .value = image };
                entries[2] = .{ .key = "scale", .value = scale };
                entries[3] = .{ .key = "fontStack", .value = font_stack };
                entries[4] = .{ .key = "textColor", .value = text_color };
                entries[5] = .{ .key = "verticalAlign", .value = valign };
                out[i] = .{ .object = entries };
            }
            const root = try a.alloc(Value.Entry, 1);
            root[0] = .{ .key = "sections", .value = .{ .array = out } };
            return .{ .object = root };
        },
        .number_format => |nf| {
            const n = switch (try eval(a, nf.input, ctx)) {
                .number => |x| x,
                else => return error.Eval,
            };
            var min_frac: usize = 0;
            var max_frac: usize = 3;
            var prefix: []const u8 = "";
            var suffix: []const u8 = "";
            if (nf.currency) |ce| {
                const code = switch (try eval(a, ce, ctx)) {
                    .string => |s| s,
                    else => return error.Eval,
                };
                const cur = currencyOf(code) orelse return error.Eval;
                prefix = cur.symbol;
                min_frac = cur.digits;
                max_frac = cur.digits;
            } else if (nf.unit) |ue| {
                const name = switch (try eval(a, ue, ctx)) {
                    .string => |s| s,
                    else => return error.Eval,
                };
                suffix = unitOf(name) orelse return error.Eval;
            }
            if (nf.min_frac) |me| min_frac = fracDigits(try eval(a, me, ctx)) orelse min_frac;
            if (nf.max_frac) |me| max_frac = fracDigits(try eval(a, me, ctx)) orelse max_frac;
            if (max_frac < min_frac) max_frac = min_frac;
            const body = try formatDecimal(a, n, min_frac, max_frac);
            if (prefix.len == 0 and suffix.len == 0) return .{ .string = body };
            return .{ .string = try std.mem.concat(a, u8, &.{ prefix, body, suffix }) };
        },
        .within => |arg| {
            const v = try eval(a, arg, ctx);
            var polys: std.ArrayList(geojson.Polygon) = .empty;
            geojson.valueToPolygons(a, v, &polys) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => return error.Eval,
            };
            const geom = ctx.feature.geometry orelse return error.Eval;
            const result = geojson.within(a, geom, polys.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => return error.Eval,
            };
            return .{ .boolean = result };
        },
        .distance => |geoms| {
            const geom = ctx.feature.geometry orelse return error.Eval;
            const d = geojson.distance(geom, geoms.*) orelse return error.Eval;
            return .{ .number = d };
        },
        .var_ref => |i| {
            if (i >= ctx.bindings.items.len) return error.Eval;
            return ctx.bindings.items[i];
        },
        .let_bind => |l| {
            const base = ctx.bindings.items.len;
            defer ctx.bindings.shrinkRetainingCapacity(base);
            for (l.values) |v| {
                try ctx.bindings.append(a, try eval(a, v, ctx));
            }
            return eval(a, l.body, ctx);
        },
        .coalesce => |list| {
            // First non-null. Errors PROPAGATE (the reference only skips
            // nulls; a failing assertion inside coalesce fails the whole
            // expression) — generated dead branches survive because absent
            // properties are null, not errors.
            for (list) |sub| {
                const v = try eval(a, sub, ctx);
                if (v == .null) continue;
                if (isImageValue(v) and !imageAvailable(v)) continue;
                return v;
            }
            return .null;
        },
        .case_op => |c| {
            for (c.conds, c.outs) |cond, out| {
                const cv = try eval(a, cond, ctx);
                if (cv != .boolean) return error.Eval; // conditions are typed
                if (cv.boolean) return eval(a, out, ctx);
            }
            return eval(a, c.fallback, ctx);
        },
        .match_op => |m| {
            const input = try eval(a, m.input, ctx);
            if (input == .string or input == .number) {
                for (m.branches) |br| {
                    if (br.label.eql(input)) return eval(a, br.out, ctx);
                }
            }
            return eval(a, m.fallback, ctx);
        },
        .step_op => |s| {
            const x = (try eval(a, s.input, ctx)).toNumber() catch return error.Eval;
            var idx: usize = 0;
            for (s.thresholds) |t| {
                if (x >= t) idx += 1 else break;
            }
            return eval(a, s.outputs[idx], ctx);
        },
        .interp => |ip| return evalInterpolate(a, ip, ctx),
        .op => |call| return evalOp(a, call, ctx),
        .assert_op => |asrt| {
            for (asrt.args) |sub| {
                const v = eval(a, sub, ctx) catch continue;
                const ok = switch (asrt.kind) {
                    .number => v == .number,
                    .string => v == .string,
                    .boolean => v == .boolean,
                    .object => v == .object,
                };
                if (ok) return v;
            }
            return error.Eval;
        },
        .assert_array => |asrt| {
            for (asrt.args) |sub| {
                const v = eval(a, sub, ctx) catch continue;
                if (arrayMatches(v, asrt.item, asrt.len)) return v;
            }
            return error.Eval;
        },
        .array_of => |list| {
            const items = try a.alloc(Value, list.len);
            for (list, 0..) |sub, i| items[i] = try eval(a, sub, ctx);
            return .{ .array = items };
        },
        .fallback_try => |f| {
            return eval(a, f.attempt, ctx) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Eval => eval(a, f.otherwise, ctx),
            };
        },
    }
}

// ---- number-format (en-US digits; a locale table can grow here) ------------

const Currency = struct { symbol: []const u8, digits: usize };

fn currencyOf(code: []const u8) ?Currency {
    const table = [_]struct { code: []const u8, cur: Currency }{
        .{ .code = "USD", .cur = .{ .symbol = "$", .digits = 2 } },
        .{ .code = "EUR", .cur = .{ .symbol = "€", .digits = 2 } },
        .{ .code = "JPY", .cur = .{ .symbol = "¥", .digits = 0 } },
        .{ .code = "GBP", .cur = .{ .symbol = "£", .digits = 2 } },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.code, code)) return e.cur;
    }
    return null;
}

fn unitOf(name: []const u8) ?[]const u8 {
    const table = [_]struct { name: []const u8, suffix: []const u8 }{
        .{ .name = "meter", .suffix = " m" },
        .{ .name = "kilometer", .suffix = " km" },
        .{ .name = "celsius", .suffix = "°C" },
        .{ .name = "fahrenheit", .suffix = "°F" },
        .{ .name = "kilobyte", .suffix = " kB" },
        .{ .name = "megabyte", .suffix = " MB" },
        .{ .name = "foot", .suffix = " ft" },
        .{ .name = "mile", .suffix = " mi" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.suffix;
    }
    return null;
}

fn fracDigits(v: Value) ?usize {
    return switch (v) {
        .number => |n| if (n >= 0 and n <= 100) @intFromFloat(n) else null,
        else => null,
    };
}

/// en-US decimal formatting: shortest round-trip digits, rounded to
/// max_frac, zero-padded to min_frac, integer part grouped by thousands.
fn formatDecimal(a: std.mem.Allocator, n: f64, min_frac: usize, max_frac: usize) Error![]const u8 {
    if (std.math.isNan(n) or std.math.isInf(n)) return error.Eval;
    const shortest = try std.fmt.allocPrint(a, "{d}", .{@abs(n)});
    const dot = std.mem.indexOfScalar(u8, shortest, '.');
    var int_part = if (dot) |i| shortest[0..i] else shortest;
    var frac: std.ArrayList(u8) = .empty;
    if (dot) |i| try frac.appendSlice(a, shortest[i + 1 ..]);

    if (frac.items.len > max_frac) {
        // decimal-string rounding with carry into the integer part
        const round_up = frac.items[max_frac] >= '5';
        frac.shrinkRetainingCapacity(max_frac);
        if (round_up) {
            var i: usize = frac.items.len;
            var carry = true;
            while (carry and i > 0) {
                i -= 1;
                if (frac.items[i] == '9') {
                    frac.items[i] = '0';
                } else {
                    frac.items[i] += 1;
                    carry = false;
                }
            }
            if (carry) {
                // 0.99 -> 1.00: bump the integer part
                const int_v = std.fmt.parseInt(u64, int_part, 10) catch return error.Eval;
                int_part = try std.fmt.allocPrint(a, "{d}", .{int_v + 1});
            }
        }
    }
    while (frac.items.len > min_frac and frac.items.len > 0 and frac.items[frac.items.len - 1] == '0') {
        frac.shrinkRetainingCapacity(frac.items.len - 1);
    }
    while (frac.items.len < min_frac) try frac.append(a, '0');

    var out: std.ArrayList(u8) = .empty;
    if (n < 0) try out.append(a, '-');
    const lead = int_part.len % 3;
    if (lead != 0) try out.appendSlice(a, int_part[0..lead]);
    var i: usize = lead;
    while (i < int_part.len) : (i += 3) {
        if (i != 0) try out.append(a, ',');
        try out.appendSlice(a, int_part[i .. i + 3]);
    }
    if (int_part.len == 0) try out.append(a, '0');
    if (frac.items.len > 0) {
        try out.append(a, '.');
        try out.appendSlice(a, frac.items);
    }
    return out.items;
}

/// An ["image"] result: exactly {name, available}.
fn isImageValue(v: Value) bool {
    if (v != .object or v.object.len != 2) return false;
    return std.mem.eql(u8, v.object[0].key, "name") and std.mem.eql(u8, v.object[1].key, "available");
}

fn imageAvailable(v: Value) bool {
    return v.object[1].value == .boolean and v.object[1].value.boolean;
}

/// A ["format"] result's sections, or null.
fn formattedSections(v: Value) ?[]const Value {
    if (v != .object or v.object.len != 1) return null;
    if (!std.mem.eql(u8, v.object[0].key, "sections")) return null;
    return switch (v.object[0].value) {
        .array => |items| items,
        else => null,
    };
}

fn arrayMatches(v: Value, item: anytype, len: ?usize) bool {
    const items = switch (v) {
        .array => |items| items,
        else => return false,
    };
    if (len) |want| {
        if (items.len != want) return false;
    }
    if (item) |want| {
        for (items) |it| {
            const ok = switch (want) {
                .number => it == .number,
                .string => it == .string,
                .boolean => it == .boolean,
            };
            if (!ok) return false;
        }
    }
    return true;
}

/// Evaluate as a filter: errors and non-boolean truthiness collapse to
/// false/true; an error is false (the feature is not admitted).
pub fn evalFilter(a: std.mem.Allocator, e: *const Expr, ctx: *Context) bool {
    const v = eval(a, e, ctx) catch return false;
    return v.truthy();
}

fn asNum(v: Value) Error!f64 {
    return switch (v) {
        .number => |n| n,
        else => error.Eval,
    };
}

fn asStr(v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.Eval,
    };
}

fn evalOp(a: std.mem.Allocator, call: Expr.OpCall, ctx: *Context) Error!Value {
    const op = call.op;
    const args = call.args;

    // Short-circuit logic first: `all`/`any` must not evaluate past their
    // answer (a guard clause protects the clauses after it).
    switch (op) {
        .all => {
            for (args) |sub| {
                const v = try eval(a, sub, ctx);
                if (v != .boolean) return error.Eval;
                if (!v.boolean) return Value.false_;
            }
            return Value.true_;
        },
        .any => {
            for (args) |sub| {
                const v = try eval(a, sub, ctx);
                if (v != .boolean) return error.Eval;
                if (v.boolean) return Value.true_;
            }
            return Value.false_;
        },
        .to_number => {
            for (args) |sub| {
                const v = eval(a, sub, ctx) catch continue;
                const n = v.toNumber() catch continue;
                return .{ .number = n };
            }
            return error.Eval;
        },
        .to_color => {
            for (args) |sub| {
                const v = eval(a, sub, ctx) catch continue;
                switch (v) {
                    .color => return v,
                    .string => |s| if (colors.parse(s)) |c| return .{ .color = c },
                    // [r, g, b] / [r, g, b, a]: rgb in 0-255, alpha 0-1
                    .array => |items| if (colorFromArray(items)) |c| return .{ .color = c },
                    else => {},
                }
            }
            return error.Eval;
        },
        else => {},
    }

    // Everything else evaluates its arguments eagerly.
    var buf: [8]Value = undefined;
    const vs = if (args.len <= buf.len) buf[0..args.len] else try a.alloc(Value, args.len);
    for (args, 0..) |sub, i| vs[i] = try eval(a, sub, ctx);

    switch (op) {
        .all, .any, .to_number, .to_color => unreachable,

        .err => return error.Eval,
        .collator => {
            // args normalized by the parser: [case-sensitive,
            // diacritic-sensitive, locale]. The value is an options object
            // consumed by the comparison operators and resolved-locale.
            const cs = switch (vs[0]) {
                .boolean => |b| b,
                else => return error.Eval,
            };
            const ds = switch (vs[1]) {
                .boolean => |b| b,
                else => return error.Eval,
            };
            const locale: ?[]const u8 = switch (vs[2]) {
                .string => |s| s,
                .null => null,
                else => return error.Eval,
            };
            const entries = try a.alloc(Value.Entry, if (locale != null) 3 else 2);
            entries[0] = .{ .key = "case-sensitive", .value = .{ .boolean = cs } };
            entries[1] = .{ .key = "diacritic-sensitive", .value = .{ .boolean = ds } };
            if (locale) |loc| entries[2] = .{ .key = "locale", .value = .{ .string = loc } };
            return .{ .object = entries };
        },
        // Text shaping is glyph-range based here; every script the glyph
        // pipeline carries is "supported". Hosts with a stricter shaper can
        // gate this later.
        .is_supported_script => return Value.true_,
        .resolved_locale => {
            const entries = switch (vs[0]) {
                .object => |entries| entries,
                else => return error.Eval,
            };
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, "locale") and entry.value == .string)
                    return entry.value;
            }
            return .{ .string = "en" };
        },
        .eq, .neq => {
            var equal: bool = undefined;
            if (vs.len == 3 and vs[0] == .string and vs[1] == .string) {
                const flags = collatorFlagsOf(vs[2]) orelse return error.Eval;
                equal = (try collate(a, vs[0].string, vs[1].string, flags)) == .eq;
            } else {
                // With a collator, NON-string operands still compare by
                // plain equality (fixture: equal/collator-value).
                equal = vs[0].eql(vs[1]);
            }
            return .{ .boolean = if (op == .eq) equal else !equal };
        },
        .lt, .le, .gt, .ge => {
            if (vs[0] == .string and vs[1] == .string) {
                const o = if (vs.len == 3) blk: {
                    const flags = collatorFlagsOf(vs[2]) orelse return error.Eval;
                    break :blk try collate(a, vs[0].string, vs[1].string, flags);
                } else std.mem.order(u8, vs[0].string, vs[1].string);
                return .{ .boolean = switch (op) {
                    .lt => o == .lt,
                    .le => o != .gt,
                    .gt => o == .gt,
                    .ge => o != .lt,
                    else => unreachable,
                } };
            }
            const x = try asNum(vs[0]);
            const y = try asNum(vs[1]);
            return .{ .boolean = switch (op) {
                .lt => x < y,
                .le => x <= y,
                .gt => x > y,
                .ge => x >= y,
                else => unreachable,
            } };
        },
        .not => return switch (vs[0]) {
            .boolean => |b| .{ .boolean = !b },
            else => error.Eval,
        },
        .in => switch (vs[1]) {
            .string => |hay| {
                // Lenient per the reference behaviour: a number or boolean
                // needle is compared by its string form; null is simply not
                // contained; an empty needle in an EMPTY haystack is false.
                const needle: []const u8 = switch (vs[0]) {
                    .string => |s| s,
                    .number, .boolean => try vs[0].toString(a),
                    .null => return Value.false_,
                    else => return error.Eval,
                };
                if (hay.len == 0) return Value.false_;
                return .{ .boolean = std.mem.indexOf(u8, hay, needle) != null };
            },
            .array => |items| {
                switch (vs[0]) {
                    .string, .number, .boolean, .null => {},
                    else => return error.Eval, // needle must be primitive
                }
                for (items) |it| {
                    if (it.eql(vs[0])) return Value.true_;
                }
                return Value.false_;
            },
            .null => return Value.false_,
            else => return error.Eval,
        },

        .concat => {
            var out: std.ArrayList(u8) = .empty;
            for (vs) |v| try out.appendSlice(a, try v.toString(a));
            return .{ .string = out.items };
        },
        .length => return switch (vs[0]) {
            .string => |s| .{ .number = @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len) },
            .array => |items| .{ .number = @floatFromInt(items.len) },
            else => error.Eval,
        },
        .at => {
            const idx = try asNum(vs[0]);
            const arr = switch (vs[1]) {
                .array => |items| items,
                else => return error.Eval,
            };
            if (idx < 0 or idx != @trunc(idx) or idx >= @as(f64, @floatFromInt(arr.len))) return error.Eval;
            return arr[@intFromFloat(idx)];
        },
        .slice => {
            const start = try asNum(vs[1]);
            switch (vs[0]) {
                .array => |items| {
                    const end = if (vs.len == 3) try asNum(vs[2]) else @as(f64, @floatFromInt(items.len));
                    const lo = wrapIndex(start, items.len);
                    const hi = wrapIndex(end, items.len);
                    return .{ .array = items[lo..@max(lo, hi)] };
                },
                .string => |s| {
                    const n_cp = std.unicode.utf8CountCodepoints(s) catch return error.Eval;
                    const end = if (vs.len == 3) try asNum(vs[2]) else @as(f64, @floatFromInt(n_cp));
                    const lo = cpToByte(s, wrapIndex(start, n_cp));
                    const hi = cpToByte(s, wrapIndex(end, n_cp));
                    return .{ .string = s[lo..@max(lo, hi)] };
                },
                else => return error.Eval,
            }
        },
        .index_of => {
            const from_raw: ?f64 = if (vs.len == 3) try asNum(vs[2]) else null;
            switch (vs[1]) {
                .array => |items| {
                    switch (vs[0]) {
                        .string, .number, .boolean, .null => {},
                        else => return error.Eval, // needle must be primitive
                    }
                    // A negative from-index wraps from the end (fixtures:
                    // with-negative-from-index).
                    var i: usize = if (from_raw) |f| blk: {
                        const flen: f64 = @floatFromInt(items.len);
                        const adj = if (f < 0) @max(0, flen + f) else f;
                        break :blk clampIndex(adj, items.len);
                    } else 0;
                    while (i < items.len) : (i += 1) {
                        if (items[i].eql(vs[0])) return .{ .number = @floatFromInt(i) };
                    }
                    return .{ .number = -1 };
                },
                .string => |hay| {
                    // Needles coerce by string form; null is never found; a
                    // negative from-index searches from the start.
                    const needle: []const u8 = switch (vs[0]) {
                        .string => |ns| ns,
                        .number, .boolean => try vs[0].toString(a),
                        .null => return .{ .number = -1 },
                        else => return error.Eval,
                    };
                    const from: usize = if (from_raw) |f| clampIndex(f, std.math.maxInt(u32)) else 0;
                    const from_b = cpToByte(hay, from);
                    const found = std.mem.indexOfPos(u8, hay, from_b, needle) orelse return .{ .number = -1 };
                    // report the position in codepoints
                    const cp = std.unicode.utf8CountCodepoints(hay[0..found]) catch return error.Eval;
                    return .{ .number = @floatFromInt(cp) };
                },
                else => return error.Eval,
            }
        },
        .upcase => {
            const s = try asStr(vs[0]);
            const out = try a.dupe(u8, s);
            for (out) |*c| c.* = std.ascii.toUpper(c.*);
            return .{ .string = out };
        },
        .downcase => {
            const s = try asStr(vs[0]);
            const out = try a.dupe(u8, s);
            for (out) |*c| c.* = std.ascii.toLower(c.*);
            return .{ .string = out };
        },
        .split => {
            const s = try asStr(vs[0]);
            const sep = try asStr(vs[1]);
            var parts: std.ArrayList(Value) = .empty;
            if (sep.len == 0) {
                // Empty separator splits into single codepoints.
                var i: usize = 0;
                while (i < s.len) {
                    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                    try parts.append(a, .{ .string = s[i..@min(i + n, s.len)] });
                    i += n;
                }
            } else {
                var it = std.mem.splitSequence(u8, s, sep);
                while (it.next()) |part| try parts.append(a, .{ .string = part });
            }
            return .{ .array = parts.items };
        },
        .join => {
            const items = switch (vs[0]) {
                .array => |items| items,
                else => return error.Eval,
            };
            const sep = try asStr(vs[1]);
            var out: std.ArrayList(u8) = .empty;
            for (items, 0..) |it, i| {
                if (i != 0) try out.appendSlice(a, sep);
                try out.appendSlice(a, try it.toString(a));
            }
            return .{ .string = out.items };
        },

        .add => {
            var acc: f64 = 0;
            for (vs) |v| acc += try asNum(v);
            return .{ .number = acc };
        },
        .mul => {
            var acc: f64 = 1;
            for (vs) |v| acc *= try asNum(v);
            return .{ .number = acc };
        },
        .sub => return .{ .number = if (vs.len == 1) -(try asNum(vs[0])) else (try asNum(vs[0])) - (try asNum(vs[1])) },
        .div => return .{ .number = (try asNum(vs[0])) / (try asNum(vs[1])) },
        .mod => return .{ .number = @mod(try asNum(vs[0]), try asNum(vs[1])) },
        .pow => return .{ .number = std.math.pow(f64, try asNum(vs[0]), try asNum(vs[1])) },
        .sqrt => return .{ .number = @sqrt(try asNum(vs[0])) },
        .abs => return .{ .number = @abs(try asNum(vs[0])) },
        .round => return .{ .number = @round(try asNum(vs[0])) },
        .floor => return .{ .number = @floor(try asNum(vs[0])) },
        .ceil => return .{ .number = @ceil(try asNum(vs[0])) },
        .min => {
            var acc: f64 = std.math.inf(f64);
            for (vs) |v| acc = @min(acc, try asNum(v));
            return .{ .number = acc };
        },
        .max => {
            var acc: f64 = -std.math.inf(f64);
            for (vs) |v| acc = @max(acc, try asNum(v));
            return .{ .number = acc };
        },
        .ln => return .{ .number = @log(try asNum(vs[0])) },
        .log10 => return .{ .number = std.math.log10(try asNum(vs[0])) },
        .log2 => return .{ .number = std.math.log2(try asNum(vs[0])) },
        .sin => return .{ .number = @sin(try asNum(vs[0])) },
        .cos => return .{ .number = @cos(try asNum(vs[0])) },
        .tan => return .{ .number = @tan(try asNum(vs[0])) },
        .asin => return .{ .number = std.math.asin(try asNum(vs[0])) },
        .acos => return .{ .number = std.math.acos(try asNum(vs[0])) },
        .atan => return .{ .number = std.math.atan(try asNum(vs[0])) },
        .e_const => return .{ .number = std.math.e },
        .pi_const => return .{ .number = std.math.pi },
        .ln2_const => return .{ .number = std.math.ln2 },

        .to_string => {
            if (formattedSections(vs[0])) |sections| {
                var joined: std.ArrayList(u8) = .empty;
                for (sections) |sec| {
                    if (sec != .object) continue;
                    for (sec.object) |entry| {
                        if (std.mem.eql(u8, entry.key, "text") and entry.value == .string)
                            try joined.appendSlice(a, entry.value.string);
                    }
                }
                return .{ .string = joined.items };
            }
            return .{ .string = try vs[0].toString(a) };
        },
        .to_boolean => return .{ .boolean = vs[0].truthy() },
        .to_rgba => {
            const c = switch (vs[0]) {
                .color => |c| c,
                .string => |str| colors.parse(str) orelse return error.Eval,
                .array => |items| colorFromArray(items) orelse return error.Eval,
                else => return error.Eval,
            };
            const arr = try a.alloc(Value, 4);
            arr[0] = .{ .number = @as(f64, c.r) * 255.0 };
            arr[1] = .{ .number = @as(f64, c.g) * 255.0 };
            arr[2] = .{ .number = @as(f64, c.b) * 255.0 };
            arr[3] = .{ .number = c.a };
            return .{ .array = arr };
        },
        .rgba, .rgb => {
            const r = try asNum(vs[0]);
            const g = try asNum(vs[1]);
            const b = try asNum(vs[2]);
            const alpha: f64 = if (vs.len == 4) try asNum(vs[3]) else 1.0;
            if (r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 or alpha < 0 or alpha > 1)
                return error.Eval;
            return .{ .color = .{
                .r = @floatCast(r / 255.0),
                .g = @floatCast(g / 255.0),
                .b = @floatCast(b / 255.0),
                .a = @floatCast(alpha),
            } };
        },
        .typeof => switch (vs[0]) {
            .array => |items| {
                var item_type: ?[]const u8 = null;
                var uniform = true;
                for (items) |it| {
                    const t = it.typeName();
                    if (item_type) |prev| {
                        if (!std.mem.eql(u8, prev, t)) uniform = false;
                    } else item_type = t;
                }
                const t = if (uniform and item_type != null) item_type.? else "value";
                return .{ .string = try std.fmt.allocPrint(a, "array<{s}, {d}>", .{ t, items.len }) };
            },
            else => return .{ .string = vs[0].typeName() },
        },
    }
}

// ---- collation (["collator"] comparisons) ----------------------------------
//
// Three-level collation, semantics derived from the spec fixtures
// (collator/*): primary is the base letter with diacritics folded,
// secondary the diacritic (compared only when diacritic-sensitive),
// tertiary the case with lowercase BEFORE uppercase (compared only when
// case-sensitive). Locale data is a Latin-1 + Latin Extended-A fold
// table, not ICU: German expands ä/ö/ü to ae/oe/ue (fixtures:
// accent-equals-de, variable-gt), Swedish sorts å/ä/ö as distinct
// letters after z (fixture: variable-gt), and any other or unknown
// locale ("dk", ...) collates with the root fold, mirroring the
// reference's fallback to its default locale.

const CollLocale = enum { root, de, sv };

const CollatorFlags = struct {
    case_sensitive: bool = false,
    diacritic_sensitive: bool = false,
    locale: CollLocale = .root,
};

fn collatorFlagsOf(v: Value) ?CollatorFlags {
    const entries = switch (v) {
        .object => |entries| entries,
        else => return null,
    };
    var flags = CollatorFlags{};
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "case-sensitive")) {
            if (entry.value == .boolean) flags.case_sensitive = entry.value.boolean;
        } else if (std.mem.eql(u8, entry.key, "diacritic-sensitive")) {
            if (entry.value == .boolean) flags.diacritic_sensitive = entry.value.boolean;
        } else if (std.mem.eql(u8, entry.key, "locale")) {
            if (entry.value == .string) flags.locale = collLocaleOf(entry.value.string);
        }
    }
    return flags;
}

/// Locales with dedicated fold behaviour, keyed on the primary language
/// subtag.
fn collLocaleOf(s: []const u8) CollLocale {
    const end = std.mem.indexOfScalar(u8, s, '-') orelse s.len;
    const lang = s[0..end];
    if (std.mem.eql(u8, lang, "de")) return .de;
    if (std.mem.eql(u8, lang, "sv")) return .sv;
    return .root;
}

/// Secondary weights. Relative order between distinct diacritics is not
/// spec-determined; only none-versus-some and same-versus-same are.
const Diac = enum(u8) {
    none = 0,
    grave,
    acute,
    circumflex,
    tilde,
    umlaut,
    ring,
    cedilla,
    stroke,
    macron,
    breve,
    ogonek,
    dot_above,
    caron,
    double_acute,
    ligature,
    dotless,
    middle_dot,
    apostrophe,
};

const Fold = struct { base: []const u8, diac: Diac, upper: bool };

/// Root fold for Latin-1 Supplement and Latin Extended-A letters.
fn latinFold(cp: u21) ?Fold {
    return switch (cp) {
        0xC0, 0xE0 => .{ .base = "a", .diac = .grave, .upper = cp == 0xC0 },
        0xC1, 0xE1 => .{ .base = "a", .diac = .acute, .upper = cp == 0xC1 },
        0xC2, 0xE2 => .{ .base = "a", .diac = .circumflex, .upper = cp == 0xC2 },
        0xC3, 0xE3 => .{ .base = "a", .diac = .tilde, .upper = cp == 0xC3 },
        0xC4, 0xE4 => .{ .base = "a", .diac = .umlaut, .upper = cp == 0xC4 },
        0xC5, 0xE5 => .{ .base = "a", .diac = .ring, .upper = cp == 0xC5 },
        0xC6, 0xE6 => .{ .base = "ae", .diac = .ligature, .upper = cp == 0xC6 },
        0xC7, 0xE7 => .{ .base = "c", .diac = .cedilla, .upper = cp == 0xC7 },
        0xC8, 0xE8 => .{ .base = "e", .diac = .grave, .upper = cp == 0xC8 },
        0xC9, 0xE9 => .{ .base = "e", .diac = .acute, .upper = cp == 0xC9 },
        0xCA, 0xEA => .{ .base = "e", .diac = .circumflex, .upper = cp == 0xCA },
        0xCB, 0xEB => .{ .base = "e", .diac = .umlaut, .upper = cp == 0xCB },
        0xCC, 0xEC => .{ .base = "i", .diac = .grave, .upper = cp == 0xCC },
        0xCD, 0xED => .{ .base = "i", .diac = .acute, .upper = cp == 0xCD },
        0xCE, 0xEE => .{ .base = "i", .diac = .circumflex, .upper = cp == 0xCE },
        0xCF, 0xEF => .{ .base = "i", .diac = .umlaut, .upper = cp == 0xCF },
        0xD0, 0xF0 => .{ .base = "d", .diac = .stroke, .upper = cp == 0xD0 }, // eth
        0xD1, 0xF1 => .{ .base = "n", .diac = .tilde, .upper = cp == 0xD1 },
        0xD2, 0xF2 => .{ .base = "o", .diac = .grave, .upper = cp == 0xD2 },
        0xD3, 0xF3 => .{ .base = "o", .diac = .acute, .upper = cp == 0xD3 },
        0xD4, 0xF4 => .{ .base = "o", .diac = .circumflex, .upper = cp == 0xD4 },
        0xD5, 0xF5 => .{ .base = "o", .diac = .tilde, .upper = cp == 0xD5 },
        0xD6, 0xF6 => .{ .base = "o", .diac = .umlaut, .upper = cp == 0xD6 },
        0xD8, 0xF8 => .{ .base = "o", .diac = .stroke, .upper = cp == 0xD8 },
        0xD9, 0xF9 => .{ .base = "u", .diac = .grave, .upper = cp == 0xD9 },
        0xDA, 0xFA => .{ .base = "u", .diac = .acute, .upper = cp == 0xDA },
        0xDB, 0xFB => .{ .base = "u", .diac = .circumflex, .upper = cp == 0xDB },
        0xDC, 0xFC => .{ .base = "u", .diac = .umlaut, .upper = cp == 0xDC },
        0xDD, 0xFD => .{ .base = "y", .diac = .acute, .upper = cp == 0xDD },
        0xDE, 0xFE => .{ .base = "th", .diac = .ligature, .upper = cp == 0xDE }, // thorn
        0xDF => .{ .base = "ss", .diac = .ligature, .upper = false }, // ß
        0xFF => .{ .base = "y", .diac = .umlaut, .upper = false },
        0x100, 0x101 => .{ .base = "a", .diac = .macron, .upper = cp == 0x100 },
        0x102, 0x103 => .{ .base = "a", .diac = .breve, .upper = cp == 0x102 },
        0x104, 0x105 => .{ .base = "a", .diac = .ogonek, .upper = cp == 0x104 },
        0x106, 0x107 => .{ .base = "c", .diac = .acute, .upper = cp == 0x106 },
        0x108, 0x109 => .{ .base = "c", .diac = .circumflex, .upper = cp == 0x108 },
        0x10A, 0x10B => .{ .base = "c", .diac = .dot_above, .upper = cp == 0x10A },
        0x10C, 0x10D => .{ .base = "c", .diac = .caron, .upper = cp == 0x10C },
        0x10E, 0x10F => .{ .base = "d", .diac = .caron, .upper = cp == 0x10E },
        0x110, 0x111 => .{ .base = "d", .diac = .stroke, .upper = cp == 0x110 },
        0x112, 0x113 => .{ .base = "e", .diac = .macron, .upper = cp == 0x112 },
        0x114, 0x115 => .{ .base = "e", .diac = .breve, .upper = cp == 0x114 },
        0x116, 0x117 => .{ .base = "e", .diac = .dot_above, .upper = cp == 0x116 },
        0x118, 0x119 => .{ .base = "e", .diac = .ogonek, .upper = cp == 0x118 },
        0x11A, 0x11B => .{ .base = "e", .diac = .caron, .upper = cp == 0x11A },
        0x11C, 0x11D => .{ .base = "g", .diac = .circumflex, .upper = cp == 0x11C },
        0x11E, 0x11F => .{ .base = "g", .diac = .breve, .upper = cp == 0x11E },
        0x120, 0x121 => .{ .base = "g", .diac = .dot_above, .upper = cp == 0x120 },
        0x122, 0x123 => .{ .base = "g", .diac = .cedilla, .upper = cp == 0x122 },
        0x124, 0x125 => .{ .base = "h", .diac = .circumflex, .upper = cp == 0x124 },
        0x126, 0x127 => .{ .base = "h", .diac = .stroke, .upper = cp == 0x126 },
        0x128, 0x129 => .{ .base = "i", .diac = .tilde, .upper = cp == 0x128 },
        0x12A, 0x12B => .{ .base = "i", .diac = .macron, .upper = cp == 0x12A },
        0x12C, 0x12D => .{ .base = "i", .diac = .breve, .upper = cp == 0x12C },
        0x12E, 0x12F => .{ .base = "i", .diac = .ogonek, .upper = cp == 0x12E },
        0x130 => .{ .base = "i", .diac = .dot_above, .upper = true }, // İ
        0x131 => .{ .base = "i", .diac = .dotless, .upper = false }, // ı
        0x132, 0x133 => .{ .base = "ij", .diac = .ligature, .upper = cp == 0x132 },
        0x134, 0x135 => .{ .base = "j", .diac = .circumflex, .upper = cp == 0x134 },
        0x136, 0x137 => .{ .base = "k", .diac = .cedilla, .upper = cp == 0x136 },
        0x138 => .{ .base = "k", .diac = .ligature, .upper = false }, // ĸ kra
        0x139, 0x13A => .{ .base = "l", .diac = .acute, .upper = cp == 0x139 },
        0x13B, 0x13C => .{ .base = "l", .diac = .cedilla, .upper = cp == 0x13B },
        0x13D, 0x13E => .{ .base = "l", .diac = .caron, .upper = cp == 0x13D },
        0x13F, 0x140 => .{ .base = "l", .diac = .middle_dot, .upper = cp == 0x13F },
        0x141, 0x142 => .{ .base = "l", .diac = .stroke, .upper = cp == 0x141 },
        0x143, 0x144 => .{ .base = "n", .diac = .acute, .upper = cp == 0x143 },
        0x145, 0x146 => .{ .base = "n", .diac = .cedilla, .upper = cp == 0x145 },
        0x147, 0x148 => .{ .base = "n", .diac = .caron, .upper = cp == 0x147 },
        0x149 => .{ .base = "n", .diac = .apostrophe, .upper = false }, // ŉ
        0x14A, 0x14B => .{ .base = "n", .diac = .ligature, .upper = cp == 0x14A }, // eng
        0x14C, 0x14D => .{ .base = "o", .diac = .macron, .upper = cp == 0x14C },
        0x14E, 0x14F => .{ .base = "o", .diac = .breve, .upper = cp == 0x14E },
        0x150, 0x151 => .{ .base = "o", .diac = .double_acute, .upper = cp == 0x150 },
        0x152, 0x153 => .{ .base = "oe", .diac = .ligature, .upper = cp == 0x152 },
        0x154, 0x155 => .{ .base = "r", .diac = .acute, .upper = cp == 0x154 },
        0x156, 0x157 => .{ .base = "r", .diac = .cedilla, .upper = cp == 0x156 },
        0x158, 0x159 => .{ .base = "r", .diac = .caron, .upper = cp == 0x158 },
        0x15A, 0x15B => .{ .base = "s", .diac = .acute, .upper = cp == 0x15A },
        0x15C, 0x15D => .{ .base = "s", .diac = .circumflex, .upper = cp == 0x15C },
        0x15E, 0x15F => .{ .base = "s", .diac = .cedilla, .upper = cp == 0x15E },
        0x160, 0x161 => .{ .base = "s", .diac = .caron, .upper = cp == 0x160 },
        0x162, 0x163 => .{ .base = "t", .diac = .cedilla, .upper = cp == 0x162 },
        0x164, 0x165 => .{ .base = "t", .diac = .caron, .upper = cp == 0x164 },
        0x166, 0x167 => .{ .base = "t", .diac = .stroke, .upper = cp == 0x166 },
        0x168, 0x169 => .{ .base = "u", .diac = .tilde, .upper = cp == 0x168 },
        0x16A, 0x16B => .{ .base = "u", .diac = .macron, .upper = cp == 0x16A },
        0x16C, 0x16D => .{ .base = "u", .diac = .breve, .upper = cp == 0x16C },
        0x16E, 0x16F => .{ .base = "u", .diac = .ring, .upper = cp == 0x16E },
        0x170, 0x171 => .{ .base = "u", .diac = .double_acute, .upper = cp == 0x170 },
        0x172, 0x173 => .{ .base = "u", .diac = .ogonek, .upper = cp == 0x172 },
        0x174, 0x175 => .{ .base = "w", .diac = .circumflex, .upper = cp == 0x174 },
        0x176, 0x177 => .{ .base = "y", .diac = .circumflex, .upper = cp == 0x176 },
        0x178 => .{ .base = "y", .diac = .umlaut, .upper = true }, // Ÿ
        0x179, 0x17A => .{ .base = "z", .diac = .acute, .upper = cp == 0x179 },
        0x17B, 0x17C => .{ .base = "z", .diac = .dot_above, .upper = cp == 0x17B },
        0x17D, 0x17E => .{ .base = "z", .diac = .caron, .upper = cp == 0x17D },
        0x17F => .{ .base = "s", .diac = .ligature, .upper = false }, // ſ
        else => null,
    };
}

/// One collation weight string per level.
const SortKey = struct {
    primary: std.ArrayList(u8) = .empty,
    secondary: std.ArrayList(u8) = .empty,
    tertiary: std.ArrayList(u8) = .empty,

    fn addElem(k: *SortKey, a: std.mem.Allocator, base: u21, diac: Diac, upper: bool) Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(base, &buf) catch return error.Eval;
        try k.primary.appendSlice(a, buf[0..n]);
        try k.secondary.append(a, @intFromEnum(diac));
        try k.tertiary.append(a, @intFromBool(upper));
    }

    /// A multi-letter fold ("ü" -> "ue"): the first element carries the
    /// diacritic and case, the tail is plain.
    fn addExpansion(k: *SortKey, a: std.mem.Allocator, base: []const u8, diac: Diac, upper: bool) Error!void {
        try k.addElem(a, base[0], diac, upper);
        for (base[1..]) |c| try k.addElem(a, c, .none, false);
    }

    fn addCp(k: *SortKey, a: std.mem.Allocator, cp: u21, loc: CollLocale) Error!void {
        if (cp >= 'A' and cp <= 'Z') return k.addElem(a, cp + 32, .none, true);
        if (cp < 0xC0) return k.addElem(a, cp, .none, false);
        switch (loc) {
            .de => switch (cp) {
                // German phonebook-style umlaut expansions
                0xC4, 0xE4 => return k.addExpansion(a, "ae", .umlaut, cp == 0xC4),
                0xD6, 0xF6 => return k.addExpansion(a, "oe", .umlaut, cp == 0xD6),
                0xDC, 0xFC => return k.addExpansion(a, "ue", .umlaut, cp == 0xDC),
                else => {},
            },
            .sv => switch (cp) {
                // å, ä, ö are distinct letters ordered after z
                0xC5, 0xE5 => return k.addElem(a, 'z' + 1, .none, cp == 0xC5),
                0xC4, 0xE4 => return k.addElem(a, 'z' + 2, .none, cp == 0xC4),
                0xD6, 0xF6 => return k.addElem(a, 'z' + 3, .none, cp == 0xD6),
                else => {},
            },
            .root => {},
        }
        if (latinFold(cp)) |f| {
            if (f.base.len == 1) return k.addElem(a, f.base[0], f.diac, f.upper);
            return k.addExpansion(a, f.base, f.diac, f.upper);
        }
        return k.addElem(a, cp, .none, false);
    }
};

fn sortKey(a: std.mem.Allocator, s: []const u8, loc: CollLocale) Error!SortKey {
    var k = SortKey{};
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n == 0 or i + n > s.len) {
            try k.addCp(a, s[i], loc); // not UTF-8: collate the raw byte
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try k.addCp(a, s[i], loc);
            i += 1;
            continue;
        };
        try k.addCp(a, cp, loc);
        i += n;
    }
    return k;
}

fn collate(a: std.mem.Allocator, s1: []const u8, s2: []const u8, flags: CollatorFlags) Error!std.math.Order {
    const k1 = try sortKey(a, s1, flags.locale);
    const k2 = try sortKey(a, s2, flags.locale);
    const p = std.mem.order(u8, k1.primary.items, k2.primary.items);
    if (p != .eq) return p;
    if (flags.diacritic_sensitive) {
        const sec = std.mem.order(u8, k1.secondary.items, k2.secondary.items);
        if (sec != .eq) return sec;
    }
    if (flags.case_sensitive) return std.mem.order(u8, k1.tertiary.items, k2.tertiary.items);
    return .eq;
}

fn colorFromArray(items: []const Value) ?Color {
    if (items.len != 3 and items.len != 4) return null;
    var c: [4]f64 = .{ 0, 0, 0, 1 };
    for (items, 0..) |it, i| {
        c[i] = switch (it) {
            .number => |n| n,
            else => return null,
        };
    }
    if (c[0] < 0 or c[0] > 255 or c[1] < 0 or c[1] > 255 or c[2] < 0 or c[2] > 255 or c[3] < 0 or c[3] > 1)
        return null;
    return .{
        .r = @floatCast(c[0] / 255.0),
        .g = @floatCast(c[1] / 255.0),
        .b = @floatCast(c[2] / 255.0),
        .a = @floatCast(c[3]),
    };
}

/// Negative indices count from the end (slice semantics).
fn wrapIndex(x: f64, len: usize) usize {
    const flen: f64 = @floatFromInt(len);
    const adj = if (x < 0) @max(0, flen + x) else x;
    return clampIndex(adj, len);
}

fn clampIndex(x: f64, len: usize) usize {
    if (x <= 0 or std.math.isNan(x)) return 0;
    const flen: f64 = @floatFromInt(len);
    if (x >= flen) return len;
    return @intFromFloat(x);
}

/// Byte offset of codepoint index `cp` (saturating at the end).
fn cpToByte(s: []const u8, cp: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cp) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += 1;
    }
    return @min(i, s.len);
}

fn evalInterpolate(a: std.mem.Allocator, ip: Expr.Interp, ctx: *Context) Error!Value {
    const x = (try eval(a, ip.input, ctx)).toNumber() catch return error.Eval;
    const stops = ip.stops;
    if (x <= stops[0]) return coerceInterpOutput(a, try eval(a, ip.outputs[0], ctx), ip.space);
    if (x >= stops[stops.len - 1]) return coerceInterpOutput(a, try eval(a, ip.outputs[stops.len - 1], ctx), ip.space);
    var hi: usize = 1;
    while (stops[hi] < x) hi += 1;
    const lo = hi - 1;
    const t = interpFactor(ip.kind, x, stops[lo], stops[hi]);
    const va = try eval(a, ip.outputs[lo], ctx);
    const vb = try eval(a, ip.outputs[hi], ctx);
    return lerpValueSpace(a, va, vb, t, ip.space);
}

fn interpFactor(kind: exprs.InterpKind, x: f64, x0: f64, x1: f64) f64 {
    const range = x1 - x0;
    const linear_t = (x - x0) / range;
    return switch (kind) {
        .linear => linear_t,
        .exponential => |base| blk: {
            if (base == 1.0) break :blk linear_t;
            break :blk (std.math.pow(f64, base, x - x0) - 1) / (std.math.pow(f64, base, range) - 1);
        },
        .cubic_bezier => |c| cubicBezierY(c, linear_t),
    };
}

/// y(t*) of the CSS cubic-bezier curve where t* solves x(t*) = t, by
/// bisection (monotone x for valid control points; 30 iterations lands
/// well past f32 paint precision).
fn cubicBezierY(c: [4]f64, x: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    var lo: f64 = 0;
    var hi: f64 = 1;
    var t: f64 = x;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const cx = bez(c[0], c[2], t);
        if (cx < x) lo = t else hi = t;
        t = (lo + hi) * 0.5;
    }
    return bez(c[1], c[3], t);
}

fn bez(p1: f64, p2: f64, t: f64) f64 {
    const u = 1 - t;
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
}

fn lerpValueSpace(a: std.mem.Allocator, va: Value, vb: Value, t: f64, space: Expr.ColorSpace) Error!Value {
    if (space != .rgb) {
        const ca: ?Color = switch (va) {
            .color => |c| c,
            .string => |s| colors.parse(s),
            else => null,
        };
        const cb: ?Color = switch (vb) {
            .color => |c| c,
            .string => |s| colors.parse(s),
            else => null,
        };
        if (ca != null and cb != null) {
            return .{ .color = lerpColorSpace(ca.?, cb.?, @floatCast(t), space) };
        }
        // arrays of colors lerp elementwise in the same space
        if (va == .array and vb == .array and va.array.len == vb.array.len) {
            const out = try a.alloc(Value, va.array.len);
            for (va.array, vb.array, 0..) |ia, ib, i| out[i] = try lerpValueSpace(a, ia, ib, t, space);
            return .{ .array = out };
        }
    }
    return lerpValue(a, va, vb, t);
}

/// interpolate-hcl / interpolate-lab always yield colors: a clamped
/// endpoint's string (or array-of-string) stop coerces before returning.
fn coerceInterpOutput(a: std.mem.Allocator, v: Value, space: Expr.ColorSpace) Error!Value {
    if (space == .rgb) return v;
    switch (v) {
        .string => |s| {
            if (colors.parse(s)) |c| return .{ .color = c };
            return error.Eval;
        },
        .array => |items| {
            var any_string = false;
            for (items) |it| {
                if (it == .string) any_string = true;
            }
            if (!any_string) return v;
            const out = try a.alloc(Value, items.len);
            for (items, 0..) |it, i| out[i] = try coerceInterpOutput(a, it, space);
            return .{ .array = out };
        },
        else => return v,
    }
}

// ---- CIE Lab / HCL interpolation (D65, standard colorimetry formulas) ----

const Lab = struct { l: f64, a: f64, b: f64, alpha: f64 };

fn srgbToLinear(c: f64) f64 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(c: f64) f64 {
    const v = if (c <= 0.0031308) 12.92 * c else 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
    return std.math.clamp(v, 0, 1);
}

const XN = 0.950470;
const ZN = 1.088830;
const T1 = 6.0 / 29.0;
const T2 = T1 * T1;
const T3 = T1 * T1 * T1;

fn labF(t: f64) f64 {
    return if (t > T3) std.math.cbrt(t) else t / (3 * T2) + 4.0 / 29.0;
}

fn labFInv(t: f64) f64 {
    return if (t > T1) t * t * t else 3 * T2 * (t - 4.0 / 29.0);
}

fn colorToLab(c: Color) Lab {
    const r = srgbToLinear(c.r);
    const g = srgbToLinear(c.g);
    const b = srgbToLinear(c.b);
    const x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
    const y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    const z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;
    const fx = labF(x / XN);
    const fy = labF(y);
    const fz = labF(z / ZN);
    return .{
        .l = 116 * fy - 16,
        .a = 500 * (fx - fy),
        .b = 200 * (fy - fz),
        .alpha = c.a,
    };
}

fn labToColor(lab: Lab) Color {
    const fy = (lab.l + 16) / 116;
    const fx = fy + lab.a / 500;
    const fz = fy - lab.b / 200;
    const x = XN * labFInv(fx);
    const y = labFInv(fy);
    const z = ZN * labFInv(fz);
    const r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    const g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    const b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
    return .{
        .r = @floatCast(linearToSrgb(r)),
        .g = @floatCast(linearToSrgb(g)),
        .b = @floatCast(linearToSrgb(b)),
        .a = @floatCast(std.math.clamp(lab.alpha, 0, 1)),
    };
}

fn lerpColorSpace(ca: Color, cb: Color, t: f64, space: Expr.ColorSpace) Color {
    const la = colorToLab(ca);
    const lb = colorToLab(cb);
    switch (space) {
        .rgb => unreachable,
        .lab => return labToColor(.{
            .l = la.l + (lb.l - la.l) * t,
            .a = la.a + (lb.a - la.a) * t,
            .b = la.b + (lb.b - la.b) * t,
            .alpha = la.alpha + (lb.alpha - la.alpha) * t,
        }),
        .hcl => {
            // LCH(ab): hue takes the shortest path; an achromatic endpoint
            // adopts the other's hue.
            const chroma_a = std.math.hypot(la.a, la.b);
            const chroma_b = std.math.hypot(lb.a, lb.b);
            var hue_a = std.math.atan2(la.b, la.a);
            var hue_b = std.math.atan2(lb.b, lb.a);
            if (chroma_a < 1e-7) hue_a = hue_b;
            if (chroma_b < 1e-7) hue_b = hue_a;
            var dh = hue_b - hue_a;
            if (dh > std.math.pi) dh -= 2 * std.math.pi;
            if (dh < -std.math.pi) dh += 2 * std.math.pi;
            const hue = hue_a + dh * t;
            const chroma = chroma_a + (chroma_b - chroma_a) * t;
            const l = la.l + (lb.l - la.l) * t;
            return labToColor(.{
                .l = l,
                .a = chroma * std.math.cos(hue),
                .b = chroma * std.math.sin(hue),
                .alpha = la.alpha + (lb.alpha - la.alpha) * t,
            });
        },
    }
}

fn lerpValue(a: std.mem.Allocator, va: Value, vb: Value, t: f64) Error!Value {
    switch (va) {
        .number => |x| return .{ .number = x + ((try asNum(vb)) - x) * t },
        .string => |sa| {
            if (colors.parse(sa)) |ca| return lerpValue(a, .{ .color = ca }, vb, t);
            // Two non-color strings interpolate as a projection transition
            // ({from, to, transition} — the projectionDefinition rule; even
            // identical names produce the transition object mid-range).
            const sb = switch (vb) {
                .string => |s2| s2,
                else => return error.Eval,
            };
            const entries = try a.alloc(Value.Entry, 3);
            entries[0] = .{ .key = "from", .value = .{ .string = sa } };
            entries[1] = .{ .key = "to", .value = .{ .string = sb } };
            entries[2] = .{ .key = "transition", .value = .{ .number = t } };
            return .{ .object = entries };
        },
        .color => |ca| {
            const cb = switch (vb) {
                .color => |c| c,
                .string => |sb| colors.parse(sb) orelse return error.Eval,
                else => return error.Eval,
            };
            const ft: f32 = @floatCast(t);
            return .{ .color = .{
                .r = ca.r + (cb.r - ca.r) * ft,
                .g = ca.g + (cb.g - ca.g) * ft,
                .b = ca.b + (cb.b - ca.b) * ft,
                .a = ca.a + (cb.a - ca.a) * ft,
            } };
        },
        .array => |items_a| {
            const items_b = switch (vb) {
                .array => |items| items,
                else => return error.Eval,
            };
            if (items_a.len != items_b.len) return error.Eval;
            const out = try a.alloc(Value, items_a.len);
            for (items_a, items_b, 0..) |ia, ib, i| out[i] = try lerpValue(a, ia, ib, t);
            return .{ .array = out };
        },
        else => return error.Eval,
    }
}

test {
    _ = @import("expr_test.zig");
    _ = @import("legacy.zig");
    _ = @import("geojson.zig");
    _ = @import("conformance_test.zig");
}

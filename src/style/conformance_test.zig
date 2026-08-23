//! Conformance harness: runs the vendored maplibre-style-spec expression
//! fixtures (test/spec/expression, see THIRD-PARTY-NOTICES.md) against the
//! expression engine and scores the result. The goal is 100% of the spec;
//! unimplemented features live on the explicit skip list below, never
//! silently.
//!
//! Comparison rules: values match within numeric tolerance; an expected
//! error matches any of our errors (never message text — those are the
//! reference implementation's prose, not the spec's); a fixture whose
//! compile is expected to fail passes if our parse fails too, and is
//! counted "lenient" if we accept it (we type dynamically; their parser
//! rejects statically — burn-down work for the typechecker).

const std = @import("std");
const exprs = @import("expr.zig");
const eval_mod = @import("eval.zig");
const ct_build = @import("ct_build");
const Value = exprs.Value;

/// Spec features not yet implemented: fixtures under these directories are
/// counted as skipped. Shrink this list; never grow it silently.
const skip_ops = [_][]const u8{};

/// The ratchet: the harness fails if fewer fixtures fully pass. Raise this
/// every time the number goes up; never lower it.
/// History: 229 (first contact, 2026-08-12) → 291 (assertions, split/join,
/// semiliteral, objects, collator-eq, strict booleans, coalesce errors) →
/// 352 (legacy property functions, Lab/HCL interpolation) -> 377 (global-
/// state, feature-state, elevation, heatmap-density, properties) -> 400
/// (within, tessellation-era libm rounding) -> 485 (three-level collation,
/// distance with tile-grid quantization) -> 575 (static typechecker: all
/// 85 lenient-compile fixtures now reject at parse — typed operator
/// signatures, comparison/match/branch unification, interpolatability,
/// property-type expectations, zoom-curve placement, fatal constant folds).
///
/// Known-fail (2): interpolate-{hcl,lab}/linear-color — the reference
/// applies a gamut-mapping step to out-of-gamut interpolation results that
/// plain channel clipping does not reproduce (confirmed: chroma reduction
/// in LCH(ab) gets within 0.003; the exact stopping rule is undetermined
/// from the fixtures alone). Checked upstream on 2026-08-12: the
/// maplibre-style-spec repo still carries exactly three cases under each of
/// interpolate-hcl and interpolate-lab (linear-color, linear-color-array,
/// uninterpolable-output), so there are still only two independent data
/// points and the rule stays underdetermined. Revisit if fixtures are
/// added; the pixel difference is below visibility.
const PASS_FLOOR: usize = 575;

const Score = struct {
    total: usize = 0,
    pass: usize = 0,
    skipped: usize = 0,
    lenient_compile: usize = 0, // they reject at compile; we accept
    fail_parse: usize = 0, // they compile; we don't
    fail_output: usize = 0,
    flag_mismatch: usize = 0, // constancy flags disagree (informational)
    type_mismatch: usize = 0, // inferred type != compiled.type (informational)
    /// Fixture inputs where style/compile.zig claimed the expression and
    /// agreed with the interpreter.
    compiled_ok: usize = 0,
    /// Where it claimed the expression and DISAGREED. This is the compiled
    /// tier's whole correctness standard, so it must stay 0: the compiler is
    /// a performance tier over the interpreter, identical output or wrong.
    compiled_mismatch: usize = 0,
};

/// The expected expression type a fixture's propertySpec pins, as the
/// reference derives it before parsing (spec `type` plus `value`/`length`
/// for arrays). Unknown spec types pin nothing.
fn specExpectedType(spec: ?std.json.Value) ?exprs.Type {
    const s = spec orelse return null;
    if (s != .object) return null;
    const t = s.object.get("type") orelse return null;
    if (t != .string) return null;
    var item: ?[]const u8 = null;
    if (s.object.get("value")) |v| {
        if (v == .string) item = v.string;
    }
    var len: ?usize = null;
    if (s.object.get("length")) |l| {
        if (l == .integer and l.integer >= 0) len = @intCast(l.integer);
    }
    return exprs.Type.fromSpecName(t.string, item, len);
}

/// The type the reference would report for the whole expression: the
/// inferred type, except where the top-level assertion/coercion wrap the
/// expected type injects takes over.
fn displayedType(inferred: exprs.Type, expected: ?exprs.Type) exprs.Type {
    const want = expected orelse return inferred;
    if (inferred == .value or inferred == .err) return want;
    if (std.meta.activeTag(want) != std.meta.activeTag(inferred) and want.accepts(inferred)) return want;
    // an empty array literal is wrapped in the expected array assertion
    if (inferred == .array and want == .array and
        (inferred.array.len orelse 1) == 0 and inferred.array.item == .value and want.array.item != .value)
        return want;
    return inferred;
}

fn jsonToValue(a: std.mem.Allocator, j: std.json.Value) !Value {
    return switch (j) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .number = @floatFromInt(i) },
        .float => |f| .{ .number = f },
        .number_string => |s| .{ .number = std.fmt.parseFloat(f64, s) catch return error.Unsupported },
        .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const items = try a.alloc(Value, arr.items.len);
            for (arr.items, 0..) |it, i| items[i] = try jsonToValue(a, it);
            break :blk .{ .array = items };
        },
        .object => |map| blk: {
            const entries = try a.alloc(Value.Entry, map.count());
            var it = map.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                entries[i] = .{ .key = kv.key_ptr.*, .value = try jsonToValue(a, kv.value_ptr.*) };
            }
            break :blk .{ .object = entries };
        },
    };
}

const FixtureFeature = struct {
    keys: [][]const u8,
    values: []Value,
    entries: []Value.Entry = &.{},

    fn get(ptr: ?*const anyopaque, key: []const u8) Value {
        const self: *const FixtureFeature = @ptrCast(@alignCast(ptr.?));
        for (self.keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return .null;
    }

    fn props(ptr: ?*const anyopaque) Value {
        const self: *const FixtureFeature = @ptrCast(@alignCast(ptr.?));
        return .{ .object = self.entries };
    }

    fn hasKey(ptr: ?*const anyopaque, key: []const u8) bool {
        const self: *const FixtureFeature = @ptrCast(@alignCast(ptr.?));
        for (self.keys) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    // ---- the compiled tier's view of the same feature ----
    // Slots resolve to indices into `keys` ONCE per program; the program
    // then reads by integer, which is the point of compiling at all.

    fn resolve(ctx: ?*const anyopaque, key: []const u8) u32 {
        const self: *const FixtureFeature = @ptrCast(@alignCast(ctx.?));
        for (self.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return @intCast(i);
        }
        return compile_mod.NO_HANDLE;
    }

    fn slot(ptr: ?*const anyopaque, handle: u32) Value {
        const self: *const FixtureFeature = @ptrCast(@alignCast(ptr.?));
        if (handle >= self.values.len) return .null;
        return self.values[handle];
    }

    fn slotHas(ptr: ?*const anyopaque, handle: u32) bool {
        const self: *const FixtureFeature = @ptrCast(@alignCast(ptr.?));
        return handle < self.keys.len;
    }
};

const compile_mod = @import("compile.zig");

/// Run the compiled tier beside the interpreter on one fixture input and
/// score whether they agree. Expressions the compiler declines are not
/// counted either way — declining is always correct.
/// Flip to trace which expressions the compiled tier disagrees on. Off by
/// default: the counter below is the gate, the print is the debugger.
const dbg_mismatch = false;
var dbg_expr: std.json.Value = .null;

fn checkCompiled(
    a: std.mem.Allocator,
    score: *Score,
    root: *const exprs.Expr,
    feature: *const FixtureFeature,
    fr: eval_mod.Feature,
    ctx: *eval_mod.Context,
) void {
    // The oracle is eval() itself, NOT the harness's spec-wrapped
    // evalWithSpec: a propertySpec injects an assertion the compiled tier
    // never sees, and comparing against it would score the wrapper.
    const want: ?Value = eval_mod.eval(a, root, ctx) catch null;
    const zoom = ctx.zoom;
    const prog = compile_mod.compile(a, root) catch return;
    const handles = a.alloc(u32, prog.keyCount()) catch return;
    prog.bind(FixtureFeature.resolve, feature, handles);
    const regs = a.alloc(Value, @max(1, prog.regCount())) catch return;
    var st = compile_mod.Run{
        .zoom = zoom,
        .fields = .{
            .ptr = feature,
            .get = FixtureFeature.slot,
            .has = FixtureFeature.slotHas,
            .geom = fr.geom,
            .id = fr.id,
        },
        .handles = handles,
        .regs = regs,
    };
    const got = compile_mod.run(a, &prog, &st);
    if (dbg_mismatch) {
        const shown = struct {
            var n: usize = 0;
        };
        const agree = blk: {
            const w = want orelse break :blk (if (got) |_| false else |_| true);
            const v = got catch break :blk false;
            break :blk v.eql(w);
        };
        if (!agree and shown.n < 25) {
            shown.n += 1;
            std.debug.print("  MISMATCH {f}\n", .{std.json.fmt(dbg_expr, .{})});
        }
    }
    const expected = want orelse {
        // The interpreter errored, so the program must too.
        if (got) |_| score.compiled_mismatch += 1 else |_| score.compiled_ok += 1;
        return;
    };
    const v = got catch {
        score.compiled_mismatch += 1;
        return;
    };
    if (v.eql(expected)) score.compiled_ok += 1 else score.compiled_mismatch += 1;
}

const geojson = @import("geojson.zig");

/// The reference harness converts fixture lon/lat into integer tile-grid
/// coordinates (EXTENT 8192 at the input's canonicalID zoom) before
/// evaluating. The distance fixtures' expected meter values include that
/// quantization noise (distance/basic: a point measured against itself is
/// 0.00170188 m away), so the feature side quantizes for them. `within`
/// fixtures hold under exact geometry (the reference converts BOTH sides
/// to the same grid there, keeping boundary points on the boundary), so
/// they stay unquantized.
fn quantizePoint(p: geojson.Point, z: f64) geojson.Point {
    const scale = 8192.0 * std.math.exp2(z);
    const x = (p[0] + 180.0) / 360.0 * scale;
    const y = (0.5 - @log(@tan(std.math.pi / 4.0 + p[1] * std.math.rad_per_deg / 2.0)) /
        (2.0 * std.math.pi)) * scale;
    const merc = std.math.pi * (1.0 - 2.0 * @round(y) / scale);
    return .{
        @round(x) / scale * 360.0 - 180.0,
        std.math.atan(std.math.sinh(merc)) * std.math.deg_per_rad,
    };
}

fn coordsToPoints(a: std.mem.Allocator, j: std.json.Value, quant_z: ?f64) ![]geojson.Point {
    if (j != .array) return error.Malformed;
    const pts = try a.alloc(geojson.Point, j.array.items.len);
    for (j.array.items, 0..) |it, i| {
        if (it != .array or it.array.items.len < 2) return error.Malformed;
        pts[i] = .{ try numOf(it.array.items[0]), try numOf(it.array.items[1]) };
        if (quant_z) |z| pts[i] = quantizePoint(pts[i], z);
    }
    return pts;
}

fn numOf(j: std.json.Value) !f64 {
    return switch (j) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.Malformed,
    };
}

fn geomFromGeoJson(a: std.mem.Allocator, type_name: []const u8, coords_j: ?std.json.Value, quant_z: ?f64) !geojson.Geometry {
    const coords = coords_j orelse return error.Malformed;
    if (std.mem.eql(u8, type_name, "Point")) {
        if (coords != .array or coords.array.items.len < 2) return error.Malformed;
        const pts = try a.alloc(geojson.Point, 1);
        pts[0] = .{ try numOf(coords.array.items[0]), try numOf(coords.array.items[1]) };
        if (quant_z) |z| pts[0] = quantizePoint(pts[0], z);
        const parts = try a.alloc([]const geojson.Point, 1);
        parts[0] = pts;
        return .{ .kind = .point, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "MultiPoint") or std.mem.eql(u8, type_name, "LineString")) {
        const parts = try a.alloc([]const geojson.Point, 1);
        parts[0] = try coordsToPoints(a, coords, quant_z);
        return .{ .kind = if (type_name[0] == 'M') .point else .line, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "MultiLineString")) {
        if (coords != .array) return error.Malformed;
        const parts = try a.alloc([]const geojson.Point, coords.array.items.len);
        for (coords.array.items, 0..) |it, i| parts[i] = try coordsToPoints(a, it, quant_z);
        return .{ .kind = .line, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "Polygon")) {
        if (coords != .array) return error.Malformed;
        const parts = try a.alloc([]const geojson.Point, coords.array.items.len);
        for (coords.array.items, 0..) |rv, i| parts[i] = try coordsToPoints(a, rv, quant_z);
        return .{ .kind = .polygon, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "MultiPolygon")) {
        // Rings flatten across polygons; even-odd containment still holds
        // for the fixtures' disjoint polygons.
        if (coords != .array) return error.Malformed;
        var rings: std.ArrayList([]const geojson.Point) = .empty;
        for (coords.array.items) |pv| {
            if (pv != .array) return error.Malformed;
            for (pv.array.items) |rv| try rings.append(a, try coordsToPoints(a, rv, quant_z));
        }
        return .{ .kind = .polygon, .parts = rings.items };
    }
    return error.Malformed;
}

fn geomFromString(s: []const u8) eval_mod.GeomType {
    if (std.mem.eql(u8, s, "Point") or std.mem.eql(u8, s, "MultiPoint")) return .point;
    if (std.mem.eql(u8, s, "LineString") or std.mem.eql(u8, s, "MultiLineString")) return .line;
    if (std.mem.eql(u8, s, "Polygon") or std.mem.eql(u8, s, "MultiPolygon")) return .polygon;
    return .unknown;
}

fn numClose(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    // Fixture numbers are truncated to ~6 significant figures.
    return @abs(a - b) <= 1e-8 + 1.2e-5 * @abs(b);
}

fn valueMatches(got: Value, want: std.json.Value) bool {
    switch (want) {
        .null => return got == .null,
        .bool => |b| return got == .boolean and got.boolean == b,
        .integer => |i| return got == .number and numClose(got.number, @floatFromInt(i)),
        .float => |f| return got == .number and numClose(got.number, f),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return false;
            return got == .number and numClose(got.number, f);
        },
        .string => |s| return got == .string and std.mem.eql(u8, got.string, s),
        .array => |arr| {
            switch (got) {
                // Colors serialize as PREMULTIPLIED unit-RGBA arrays.
                .color => |c| {
                    if (arr.items.len != 4) return false;
                    const comps = [4]f64{ c.r * c.a, c.g * c.a, c.b * c.a, c.a };
                    for (arr.items, comps) |w, g| {
                        const wf: f64 = switch (w) {
                            .integer => |i| @floatFromInt(i),
                            .float => |f| f,
                            else => return false,
                        };
                        if (@abs(g - wf) > 2e-3) return false;
                    }
                    return true;
                },
                .array => |items| {
                    if (items.len != arr.items.len) return false;
                    for (items, arr.items) |g, w| {
                        if (!valueMatches(g, w)) return false;
                    }
                    return true;
                },
                else => return false,
            }
        },
        .object => |map| {
            // A color inside a colorArray serializes as a STRAIGHT-alpha
            // {r,g,b,a} object (unlike bare colors, which are premultiplied
            // arrays).
            if (got == .color and map.get("r") != null) {
                const c = got.color;
                const comps = [4]f64{ c.r, c.g, c.b, c.a };
                const names = [4][]const u8{ "r", "g", "b", "a" };
                for (names, comps) |name, g| {
                    const w = map.get(name) orelse return false;
                    const wf: f64 = switch (w) {
                        .integer => |i| @floatFromInt(i),
                        .float => |f| f,
                        else => return false,
                    };
                    if (@abs(g - wf) > 2e-3) return false;
                }
                return true;
            }
            if (got == .object) {
                if (map.count() != got.object.len) return false;
                for (got.object) |entry| {
                    const w = map.get(entry.key) orelse return false;
                    if (!valueMatches(entry.value, w)) return false;
                }
                return true;
            }
            // numberArray/colorArray property values serialize as
            // {"values": [...]} in the fixtures.
            if (map.get("values")) |inner| return valueMatches(got, inner);
            return false;
        },
    }
}

const RunError = error{ OutOfMemory, Malformed, Unsupported };

/// Evaluate, then apply the implicit assertion/coercion the reference
/// derives from the fixture's propertySpec (a property typed array<string>
/// implicitly asserts the expression's result, a color property implicitly
/// to-colors a string, and so on).
fn evalWithSpec(
    a: std.mem.Allocator,
    root: *const exprs.Expr,
    ctx: *eval_mod.Context,
    spec: ?std.json.Value,
) eval_mod.Error!Value {
    const v = try eval_mod.eval(a, root, ctx);
    const s = spec orelse return v;
    if (s != .object) return v;
    const t = s.object.get("type") orelse return v;
    if (t != .string) return v;
    const type_name = t.string;
    if (std.mem.eql(u8, type_name, "number")) {
        if (v != .number) return error.Eval;
    } else if (std.mem.eql(u8, type_name, "string")) {
        // string properties COERCE (the reference wraps them in to-string)
        return .{ .string = try v.toString(a) };
    } else if (std.mem.eql(u8, type_name, "boolean")) {
        if (v != .boolean) return error.Eval;
    } else if (std.mem.eql(u8, type_name, "color")) {
        switch (v) {
            .color => {},
            .string => |str| {
                const colors = @import("color.zig");
                const c = colors.parse(str) orelse return error.Eval;
                return .{ .color = c };
            },
            else => return error.Eval,
        }
    } else if (std.mem.eql(u8, type_name, "colorArray")) {
        const colors = @import("color.zig");
        switch (v) {
            .color => {
                const out = try a.alloc(Value, 1);
                out[0] = v;
                return .{ .array = out };
            },
            .string => |str| {
                const c = colors.parse(str) orelse return error.Eval;
                const out = try a.alloc(Value, 1);
                out[0] = .{ .color = c };
                return .{ .array = out };
            },
            .array => |items| {
                const out = try a.alloc(Value, items.len);
                for (items, 0..) |it, i| {
                    out[i] = switch (it) {
                        .color => it,
                        .string => |str| .{ .color = colors.parse(str) orelse return error.Eval },
                        else => return error.Eval,
                    };
                }
                return .{ .array = out };
            },
            else => return error.Eval,
        }
    } else if (std.mem.eql(u8, type_name, "numberArray")) {
        switch (v) {
            .number => {
                const out = try a.alloc(Value, 1);
                out[0] = v;
                return .{ .array = out };
            },
            .array => |items| for (items) |it| {
                if (it != .number) return error.Eval;
            },
            else => return error.Eval,
        }
    } else if (std.mem.eql(u8, type_name, "padding")) {
        // CSS shorthand: [t] [t,r] [t,r,b] [t,r,b,l] -> [t,r,b,l]
        var p4: [4]f64 = undefined;
        switch (v) {
            .number => |n| p4 = .{ n, n, n, n },
            .array => |items| {
                if (items.len < 1 or items.len > 4) return error.Eval;
                var nums: [4]f64 = undefined;
                for (items, 0..) |it, i| {
                    nums[i] = switch (it) {
                        .number => |n| n,
                        else => return error.Eval,
                    };
                }
                p4 = switch (items.len) {
                    1 => .{ nums[0], nums[0], nums[0], nums[0] },
                    2 => .{ nums[0], nums[1], nums[0], nums[1] },
                    3 => .{ nums[0], nums[1], nums[2], nums[1] },
                    else => nums,
                };
            },
            else => return error.Eval,
        }
        const out = try a.alloc(Value, 4);
        for (p4, 0..) |n, i| out[i] = .{ .number = n };
        return .{ .array = out };
    } else if (std.mem.eql(u8, type_name, "array")) {
        const items = switch (v) {
            .array => |items| items,
            else => return error.Eval,
        };
        if (s.object.get("length")) |jl| {
            if (jl == .integer and items.len != @as(usize, @intCast(jl.integer))) return error.Eval;
        }
        if (s.object.get("value")) |jv| {
            if (jv == .string) {
                for (items) |it| {
                    const ok = if (std.mem.eql(u8, jv.string, "number"))
                        it == .number
                    else if (std.mem.eql(u8, jv.string, "string"))
                        it == .string
                    else if (std.mem.eql(u8, jv.string, "boolean"))
                        it == .boolean
                    else
                        true;
                    if (!ok) return error.Eval;
                }
            }
        }
    } else if (std.mem.eql(u8, type_name, "formatted")) {
        // implicit coercion: any string-ish result becomes one section
        if (v == .object) return v;
        const entries = try a.alloc(Value.Entry, 6);
        entries[0] = .{ .key = "text", .value = .{ .string = try v.toString(a) } };
        entries[1] = .{ .key = "image", .value = .null };
        entries[2] = .{ .key = "scale", .value = .null };
        entries[3] = .{ .key = "fontStack", .value = .null };
        entries[4] = .{ .key = "textColor", .value = .null };
        entries[5] = .{ .key = "verticalAlign", .value = .null };
        const sections = try a.alloc(Value, 1);
        sections[0] = .{ .object = entries };
        const fmt_root = try a.alloc(Value.Entry, 1);
        fmt_root[0] = .{ .key = "sections", .value = .{ .array = sections } };
        return .{ .object = fmt_root };
    } else if (std.mem.eql(u8, type_name, "projectionDefinition")) {
        // a projection is a name string, a [from, to, t] transition array,
        // or the {from, to, transition} object interpolation produces
        switch (v) {
            .string => {},
            .array => |items| if (items.len != 3) return error.Eval,
            .object => |entries| if (entries.len != 3) return error.Eval,
            else => return error.Eval,
        }
    } else if (std.mem.eql(u8, type_name, "enum")) {
        // Enum membership is a VALIDATION-time check; at runtime the
        // reference only asserts string-ness (legacy identity/enum passes
        // values outside the enum through).
        if (v != .string) return error.Eval;
    }
    return v;
}

/// Run one fixture; updates the score. Returns the failure detail (arena-
/// allocated) when the fixture fails, for the report.
fn jsonEntries(a: std.mem.Allocator, j: std.json.Value) RunError![]Value.Entry {
    if (j != .object) return &.{};
    const entries = try a.alloc(Value.Entry, j.object.count());
    var it = j.object.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) {
        entries[i] = .{ .key = kv.key_ptr.*, .value = jsonToValue(a, kv.value_ptr.*) catch .null };
    }
    return entries;
}

fn runFixture(a: std.mem.Allocator, score: *Score, doc: std.json.Value, quantize_feature: bool) RunError!?[]const u8 {
    if (doc != .object) return error.Malformed;
    const expression = doc.object.get("expression") orelse return error.Malformed;
    const expected = doc.object.get("expected") orelse return error.Malformed;
    if (expected != .object) return error.Malformed;
    const compiled = expected.object.get("compiled") orelse return error.Malformed;
    const compile_ok = compiled == .object and compiled.object.get("result") != null and
        compiled.object.get("result").? == .string and
        std.mem.eql(u8, compiled.object.get("result").?.string, "success");

    const legacy = @import("legacy.zig");
    const expected_ty = specExpectedType(doc.object.get("propertySpec"));
    const parsed = (if (expression == .object)
        legacy.convert(a, expression, doc.object.get("propertySpec"))
    else
        exprs.parseWithType(a, expression, expected_ty)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidExpression => {
            if (!compile_ok) {
                score.pass += 1;
                return null;
            }
            score.fail_parse += 1;
            return "parse failed; reference compiles";
        },
    };
    if (!compile_ok) {
        // The reference rejects this statically; we accepted it. Count it,
        // and still demand our runtime behaves (fixtures carry no outputs
        // in this case, so there is nothing further to check).
        score.lenient_compile += 1;
        return null;
    }

    // Inference oracle (informational): the fixture records the reference's
    // inferred type; compare ours. Legacy conversions don't infer.
    if (expression != .object) {
        if (compiled.object.get("type")) |jt| {
            if (jt == .string) {
                const got = try displayedType(parsed.ty, expected_ty).toSpecString(a);
                if (!std.mem.eql(u8, got, jt.string)) score.type_mismatch += 1;
            }
        }
    }

    // Constancy flags (informational: folding can make us MORE constant
    // than the reference claims, which is fine; less constant is not).
    if (compiled.object.get("isFeatureConstant")) |jf| {
        if (jf == .bool and jf.bool and parsed.deps.feature) score.flag_mismatch += 1;
    }
    if (compiled.object.get("isZoomConstant")) |jz| {
        if (jz == .bool and jz.bool and parsed.deps.zoom) score.flag_mismatch += 1;
    }

    const inputs = doc.object.get("inputs") orelse return error.Malformed;
    const outputs = expected.object.get("outputs") orelse return error.Malformed;
    if (inputs != .array or outputs != .array) return error.Malformed;
    if (inputs.array.items.len != outputs.array.items.len) return error.Malformed;

    for (inputs.array.items, outputs.array.items, 0..) |input, want, idx| {
        if (input != .array or input.array.items.len != 2) return error.Malformed;
        const globals = input.array.items[0];
        const feat_json = input.array.items[1];

        var ctx = eval_mod.Context{};
        if (doc.object.get("globalState")) |gs| ctx.global_state = try jsonEntries(a, gs);
        if (globals == .object) {
            if (globals.object.get("zoom")) |z| {
                ctx.zoom = switch (z) {
                    .integer => |i| @floatFromInt(i),
                    .float => |f| f,
                    else => 0,
                };
            }
            if (globals.object.get("globalState")) |gs| ctx.global_state = try jsonEntries(a, gs);
            if (globals.object.get("elevation")) |e| ctx.elevation = switch (e) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => 0,
            };
            if (globals.object.get("heatmapDensity")) |e| ctx.heatmap_density = switch (e) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => 0,
            };
            if (globals.object.get("lineProgress")) |e| ctx.line_progress = switch (e) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => 0,
            };
            if (globals.object.get("availableImages")) |imgs| {
                if (imgs == .array) {
                    const names = try a.alloc([]const u8, imgs.array.items.len);
                    var n_names: usize = 0;
                    for (imgs.array.items) |it| {
                        if (it == .string) {
                            names[n_names] = it.string;
                            n_names += 1;
                        }
                    }
                    ctx.available_images = names[0..n_names];
                }
            }
        }

        var feature = FixtureFeature{ .keys = &.{}, .values = &.{} };
        var fr = eval_mod.Feature{ .ptr = &feature, .get_fn = FixtureFeature.get, .has_fn = FixtureFeature.hasKey, .props_fn = FixtureFeature.props };
        if (feat_json == .object) {
            if (feat_json.object.get("properties")) |props| {
                if (props == .object) {
                    const n = props.object.count();
                    feature.keys = try a.alloc([]const u8, n);
                    feature.values = try a.alloc(Value, n);
                    var it = props.object.iterator();
                    var i: usize = 0;
                    while (it.next()) |kv| : (i += 1) {
                        feature.keys[i] = kv.key_ptr.*;
                        feature.values[i] = jsonToValue(a, kv.value_ptr.*) catch {
                            score.skipped += 1;
                            return null; // object-valued property: tier 2
                        };
                    }
                    const fentries = try a.alloc(Value.Entry, n);
                    for (feature.keys, feature.values, 0..) |k, v, j| fentries[j] = .{ .key = k, .value = v };
                    feature.entries = fentries;
                }
            }
            if (feat_json.object.get("geometry")) |g| {
                if (g == .object) {
                    var quant_z: ?f64 = null;
                    if (quantize_feature and globals == .object) {
                        if (globals.object.get("canonicalID")) |cid| {
                            if (cid == .object) {
                                if (cid.object.get("z")) |zj| quant_z = numOf(zj) catch null;
                            }
                        }
                    }
                    if (g.object.get("type")) |t| {
                        if (t == .string) {
                            fr.geom = geomFromString(t.string);
                            fr.geometry = geomFromGeoJson(a, t.string, g.object.get("coordinates"), quant_z) catch null;
                        }
                    }
                }
            }
            if (feat_json.object.get("id")) |idv| {
                fr.id = jsonToValue(a, idv) catch .null;
            }
            if (feat_json.object.get("featureState")) |fs| ctx.feature_state = try jsonEntries(a, fs);
        }
        ctx.feature = fr;

        const want_error = want == .object and want.object.get("error") != null;
        const got = evalWithSpec(a, parsed.root, &ctx, doc.object.get("propertySpec"));
        // The compiled tier runs the SAME expression against the SAME input
        // and must land on the same Value.
        dbg_expr = expression;
        checkCompiled(a, score, parsed.root, &feature, fr, &ctx);
        if (want_error) {
            if (got) |_| {
                score.fail_output += 1;
                return try std.fmt.allocPrint(a, "input {d}: expected error, got value", .{idx});
            } else |_| continue;
        }
        const v = got catch {
            score.fail_output += 1;
            return try std.fmt.allocPrint(a, "input {d}: eval error, expected value", .{idx});
        };
        if (!valueMatches(v, want)) {
            score.fail_output += 1;
            return try std.fmt.allocPrint(a, "input {d}: value mismatch", .{idx});
        }
    }
    score.pass += 1;
    return null;
}

test "spec expression conformance suite" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = std.Io.Dir.openDirAbsolute(io, ct_build.spec_fixture_dir, .{ .iterate = true }) catch
        return error.SkipZigTest; // fixtures not vendored in this checkout
    defer dir.close(io);

    var score = Score{};
    var failures: std.ArrayList([]const u8) = .empty;

    var walker = try dir.walk(arena);
    defer walker.deinit();
    outer: while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "test.json")) continue;
        score.total += 1;
        // The walker's paths carry the native separator.
        for (skip_ops) |s| {
            if (std.mem.startsWith(u8, entry.path, s) and entry.path.len > s.len and entry.path[s.len] == std.fs.path.sep) {
                score.skipped += 1;
                continue :outer;
            }
        }
        // Per-fixture arena scope: retain only failure strings.
        const bytes = dir.readFileAlloc(io, entry.path, arena, .limited(4 * 1024 * 1024)) catch
            return error.SkipZigTest;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
            score.fail_parse += 1;
            continue;
        };
        const distance_fixture = std.mem.startsWith(u8, entry.path, "distance") and
            entry.path.len > "distance".len and entry.path["distance".len] == std.fs.path.sep;
        const detail = runFixture(arena, &score, doc, distance_fixture) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed, error.Unsupported => {
                score.skipped += 1;
                continue;
            },
        };
        if (detail) |d| {
            try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ entry.path, d }));
        }
    }

    std.debug.print(
        "\nspec conformance: {d}/{d} pass ({d} skipped, {d} lenient-compile, " ++
            "{d} parse-fail, {d} output-fail, {d} constancy-flag mismatches, " ++
            "{d} type-inference mismatches, {d} compiled ok, " ++
            "{d} compiled mismatches)\n" ++
            "full failure list: {s}\n",
        .{ score.pass, score.total, score.skipped, score.lenient_compile, score.fail_parse, score.fail_output, score.flag_mismatch, score.type_mismatch, score.compiled_ok, score.compiled_mismatch, ct_build.report_path },
    );
    // The detailed list goes to a file: hundreds of stderr lines from inside
    // a test upset the build runner's status stream, and a file diffs.
    var report: std.ArrayList(u8) = .empty;
    for (failures.items) |f| {
        try report.appendSlice(arena, f);
        try report.append(arena, '\n');
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ct_build.report_path, .data = report.items }) catch {};

    try std.testing.expect(score.pass >= PASS_FLOOR);
    // The compiled tier's whole correctness standard. It is allowed to
    // DECLINE an expression (the interpreter then runs it), but never to
    // answer differently from the interpreter on one it claimed.
    try std.testing.expectEqual(@as(usize, 0), score.compiled_mismatch);
    try std.testing.expect(score.compiled_ok > 300);
}

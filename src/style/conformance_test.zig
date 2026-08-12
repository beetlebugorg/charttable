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
const skip_ops = [_][]const u8{
    "interpolate/projection",
    "collator",
    "distance",
    "format",
    "image",
    "object",
    "projection",
};

/// The ratchet: the harness fails if fewer fixtures fully pass. Raise this
/// every time the number goes up; never lower it.
/// History: 229 (first contact, 2026-08-12) → 291 (assertions, split/join,
/// semiliteral, objects, collator-eq, strict booleans, coalesce errors) →
/// 352 (legacy property functions, Lab/HCL interpolation) -> 377 (global-
/// state, feature-state, elevation, heatmap-density, properties) -> 400
/// (within, tessellation-era libm rounding).
///
/// Known-fail (2): interpolate-{hcl,lab}/linear-color — the reference
/// applies a gamut-mapping step to out-of-gamut interpolation results that
/// plain channel clipping does not reproduce (confirmed: chroma reduction
/// in LCH(ab) gets within 0.003; the exact stopping rule is undetermined
/// from the fixtures alone). Revisit with more fixture data points; the
/// pixel difference is below visibility.
const PASS_FLOOR: usize = 407;

const Score = struct {
    total: usize = 0,
    pass: usize = 0,
    skipped: usize = 0,
    lenient_compile: usize = 0, // they reject at compile; we accept
    fail_parse: usize = 0, // they compile; we don't
    fail_output: usize = 0,
    flag_mismatch: usize = 0, // constancy flags disagree (informational)
};

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
};

const geojson = @import("geojson.zig");

fn coordsToPoints(a: std.mem.Allocator, j: std.json.Value) ![]geojson.Point {
    if (j != .array) return error.Malformed;
    const pts = try a.alloc(geojson.Point, j.array.items.len);
    for (j.array.items, 0..) |it, i| {
        if (it != .array or it.array.items.len < 2) return error.Malformed;
        pts[i] = .{ try numOf(it.array.items[0]), try numOf(it.array.items[1]) };
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

fn geomFromGeoJson(a: std.mem.Allocator, type_name: []const u8, coords_j: ?std.json.Value) !geojson.Geometry {
    const coords = coords_j orelse return error.Malformed;
    if (std.mem.eql(u8, type_name, "Point")) {
        if (coords != .array or coords.array.items.len < 2) return error.Malformed;
        const pts = try a.alloc(geojson.Point, 1);
        pts[0] = .{ try numOf(coords.array.items[0]), try numOf(coords.array.items[1]) };
        const parts = try a.alloc([]const geojson.Point, 1);
        parts[0] = pts;
        return .{ .kind = .point, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "MultiPoint") or std.mem.eql(u8, type_name, "LineString")) {
        const parts = try a.alloc([]const geojson.Point, 1);
        parts[0] = try coordsToPoints(a, coords);
        return .{ .kind = if (type_name[0] == 'M') .point else .line, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "MultiLineString")) {
        if (coords != .array) return error.Malformed;
        const parts = try a.alloc([]const geojson.Point, coords.array.items.len);
        for (coords.array.items, 0..) |it, i| parts[i] = try coordsToPoints(a, it);
        return .{ .kind = .line, .parts = parts };
    }
    if (std.mem.eql(u8, type_name, "Polygon") or std.mem.eql(u8, type_name, "MultiPolygon")) {
        return .{ .kind = .polygon, .parts = &.{} };
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
    } else if (std.mem.eql(u8, type_name, "projectionDefinition")) {
        // a projection is a name string or a [from, to, t] transition array
        switch (v) {
            .string => {},
            .array => |items| if (items.len != 3) return error.Eval,
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

fn runFixture(a: std.mem.Allocator, score: *Score, doc: std.json.Value) RunError!?[]const u8 {
    if (doc != .object) return error.Malformed;
    const expression = doc.object.get("expression") orelse return error.Malformed;
    const expected = doc.object.get("expected") orelse return error.Malformed;
    if (expected != .object) return error.Malformed;
    const compiled = expected.object.get("compiled") orelse return error.Malformed;
    const compile_ok = compiled == .object and compiled.object.get("result") != null and
        compiled.object.get("result").? == .string and
        std.mem.eql(u8, compiled.object.get("result").?.string, "success");

    const legacy = @import("legacy.zig");
    const parsed = (if (expression == .object)
        legacy.convert(a, expression, doc.object.get("propertySpec"))
    else
        exprs.parse(a, expression)) catch |e| switch (e) {
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
                    if (g.object.get("type")) |t| {
                        if (t == .string) {
                            fr.geom = geomFromString(t.string);
                            fr.geometry = geomFromGeoJson(a, t.string, g.object.get("coordinates")) catch null;
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
        for (skip_ops) |s| {
            if (std.mem.startsWith(u8, entry.path, s) and entry.path.len > s.len and entry.path[s.len] == '/') {
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
        const detail = runFixture(arena, &score, doc) catch |e| switch (e) {
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
            "{d} parse-fail, {d} output-fail, {d} constancy-flag mismatches)\n" ++
            "full failure list: {s}\n",
        .{ score.pass, score.total, score.skipped, score.lenient_compile, score.fail_parse, score.fail_output, score.flag_mismatch, ct_build.report_path },
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
}

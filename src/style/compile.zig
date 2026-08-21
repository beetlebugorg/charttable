//! The style compiler's first tier: expression trees to a flat register
//! bytecode over INTERNED feature-property slots.
//!
//! Why (DESIGN.md "Style compilation", and the measurement behind it): the
//! maplibre-native experiment put ~730 of 1395 worker samples inside
//! expression evaluation. charttable already constant-folds at parse and
//! annotates every node with an inferred type, so what is left is the
//! per-feature cost of the walk itself — and the biggest single item is
//! `["get", key]`, which hashes a key string against the tile layer's key
//! table on EVERY lookup (map.zig MvtFeature.get). A program resolves each
//! distinct key ONCE per (program × tile layer) into an integer handle and
//! then executes over registers.
//!
//! The interpreter (style/eval.zig) stays the reference oracle. This tier is
//! a performance tier: identical Values or it is wrong, which is what the
//! conformance harness's `compiled_mismatch` counter exists to prove. An
//! expression using anything outside the compilable set fails to compile and
//! the caller keeps using the interpreter — permanently correct either way.
//!
//! Scope, deliberately: the operators tile57's styles actually use —
//! get/has/zoom/geometry-type/id, match, case, coalesce, step, interpolate,
//! let/var, comparisons, boolean logic, arithmetic, and the scalar
//! coercions. Everything else returns error.Unsupported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const exprs = @import("expr.zig");
const eval_mod = @import("eval.zig");
const vals = @import("value.zig");

const Expr = exprs.Expr;
pub const Value = vals.Value;

/// Where a property's value comes from, from its dependency set. `global`
/// (host state, elevation, …) counts as zoom-only: it cannot be folded and
/// it is re-evaluated per frame, not per feature.
pub const Class = enum {
    /// Already a value — parse-time folding finished the job.
    constant,
    /// Varies with the camera only: evaluate once per frame into a uniform.
    zoom_only,
    /// Varies per feature only: evaluate once per feature at layout.
    data_driven,
    /// Both: the layout bakes a (value@z0, value@z1) pair and the shader
    /// mixes by zoom_t.
    zoom_and_data,

    pub fn of(deps: exprs.Deps) Class {
        const zoomish = deps.zoom or deps.global;
        if (deps.feature and zoomish) return .zoom_and_data;
        if (deps.feature) return .data_driven;
        if (zoomish) return .zoom_only;
        return .constant;
    }

    /// True when a change of this class forces a re-layout rather than a
    /// paint-stream refill or a uniform update.
    pub fn needsLayout(self: Class) bool {
        return self == .data_driven or self == .zoom_and_data;
    }
};

pub const Error = error{ Unsupported, OutOfMemory };
pub const RunError = error{ Eval, OutOfMemory };

pub const Reg = u16;
pub const NO_HANDLE: u32 = 0xFFFF_FFFF;

/// Per-feature field access by PRE-RESOLVED handle — the point of the whole
/// exercise. The handle is whatever the decoder's own key table uses; the
/// program never sees a key string again after binding.
pub const Fields = struct {
    ptr: ?*const anyopaque = null,
    get: *const fn (?*const anyopaque, handle: u32) Value = noField,
    /// Present-with-null vs absent, for ["has"].
    has: ?*const fn (?*const anyopaque, handle: u32) bool = null,
    geom: eval_mod.GeomType = .unknown,
    id: Value = .null,

    fn noField(_: ?*const anyopaque, _: u32) Value {
        return .null;
    }
};

/// Resolve a program's key slots against one tile layer. `resolve` returns
/// the decoder's handle for a key name, or NO_HANDLE when the layer has no
/// such key — which is not an error, just a feature that reads null.
pub const Resolver = *const fn (ctx: ?*const anyopaque, key: []const u8) u32;

pub const Op1 = enum {
    not,
    abs,
    floor,
    ceil,
    round,
    sqrt,
    ln,
    log10,
    log2,
    sin,
    cos,
    tan,
    to_number,
    to_string,
    to_boolean,
    length,
};

pub const Op2 = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    min,
    max,
    eq,
    neq,
    lt,
    le,
    gt,
    ge,
};

pub const Ins = union(enum) {
    load_const: struct { dst: Reg, idx: u32 },
    load_prop: struct { dst: Reg, slot: u32 },
    load_has: struct { dst: Reg, slot: u32 },
    load_zoom: struct { dst: Reg },
    load_geom: struct { dst: Reg },
    load_id: struct { dst: Reg },
    move: struct { dst: Reg, src: Reg },
    un: struct { op: Op1, dst: Reg, a: Reg },
    bin: struct { op: Op2, dst: Reg, a: Reg, b: Reg },
    /// `n` consecutive registers from `first`, concatenated as strings.
    concat: struct { dst: Reg, first: Reg, n: u16 },
    jump: struct { target: u32 },
    jump_if_false: struct { cond: Reg, target: u32 },
    /// Like jump_if_false, but a non-boolean is an evaluation ERROR rather
    /// than a falsy value — the spec types `case` conditions, and the
    /// interpreter enforces it.
    branch_case: struct { cond: Reg, target: u32 },
    jump_if_true: struct { cond: Reg, target: u32 },
    jump_if_not_null: struct { src: Reg, target: u32 },
    /// The whole reason a compiled match beats a walked one: one hash (or
    /// one binary search) instead of a linear scan over the labels.
    match: struct { input: Reg, table: u32 },
    step: struct { input: Reg, table: u32 },
    /// Nested programs per output, mixed by the shared interpolation
    /// helpers so the result is the interpreter's bit for bit.
    interp: struct { dst: Reg, input: Reg, table: u32 },
    ret: struct { src: Reg },
};

const MatchTable = struct {
    strings: std.StringHashMapUnmanaged(u32) = .empty,
    /// Ascending by key, binary-searched.
    numbers: []const NumTarget = &.{},
    fallback: u32,

    const NumTarget = struct { key: f64, target: u32 };

    fn find(self: *const MatchTable, v: Value) u32 {
        switch (v) {
            .string => |s| return self.strings.get(s) orelse self.fallback,
            .number => |n| {
                var lo: usize = 0;
                var hi: usize = self.numbers.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (self.numbers[mid].key == n) return self.numbers[mid].target;
                    if (self.numbers[mid].key < n) lo = mid + 1 else hi = mid;
                }
                return self.fallback;
            },
            else => return self.fallback,
        }
    }
};

const StepTable = struct {
    /// Ascending. `targets.len == thresholds.len + 1`.
    thresholds: []const f64,
    targets: []const u32,

    fn find(self: *const StepTable, x: f64) u32 {
        var lo: usize = 0;
        var hi: usize = self.thresholds.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.thresholds[mid] <= x) lo = mid + 1 else hi = mid;
        }
        return self.targets[lo];
    }
};

const InterpTable = struct {
    kind: exprs.InterpKind,
    space: Expr.ColorSpace,
    stops: []const f64,
    outputs: []const Program,
};

pub const Program = struct {
    code: []const Ins,
    consts: []const Value,
    /// Distinct ["get"]/["has"] key names, in slot order. Bind once per
    /// (program × tile layer).
    keys: []const []const u8,
    matches: []const MatchTable,
    steps: []const StepTable,
    interps: []const InterpTable,
    n_regs: u16,

    pub fn keyCount(self: *const Program) usize {
        return self.keys.len;
    }

    /// Fill `out` with the decoder's handle per key slot. Call once per tile
    /// layer, not once per feature — that is the whole optimization.
    pub fn bind(self: *const Program, resolve: Resolver, ctx: ?*const anyopaque, out: []u32) void {
        for (self.keys, 0..) |k, i| {
            if (i >= out.len) return;
            out[i] = resolve(ctx, k);
        }
    }

    /// Registers a run needs. The caller owns the register file so a hot
    /// loop allocates nothing per feature.
    pub fn regCount(self: *const Program) usize {
        return self.n_regs;
    }
};

/// One execution's mutable state. `regs` and `handles` are the caller's, so
/// evaluating a million features allocates nothing (except what building a
/// string value genuinely needs).
pub const Run = struct {
    zoom: f64 = 0,
    fields: Fields = .{},
    handles: []const u32 = &.{},
    regs: []Value,
};

pub fn run(a: Allocator, p: *const Program, st: *Run) RunError!Value {
    std.debug.assert(st.regs.len >= p.n_regs);
    var pc: usize = 0;
    var guard: usize = 0;
    const limit = p.code.len * 4 + 64; // no compiled program loops
    while (pc < p.code.len) {
        guard += 1;
        if (guard > limit) return error.Eval;
        const ins = p.code[pc];
        pc += 1;
        switch (ins) {
            .load_const => |i| st.regs[i.dst] = p.consts[i.idx],
            .load_prop => |i| st.regs[i.dst] = readField(st, i.slot),
            .load_has => |i| {
                const h = handleOf(st, i.slot);
                if (h == NO_HANDLE) {
                    st.regs[i.dst] = .{ .boolean = false };
                } else if (st.fields.has) |f| {
                    st.regs[i.dst] = .{ .boolean = f(st.fields.ptr, h) };
                } else {
                    st.regs[i.dst] = .{ .boolean = st.fields.get(st.fields.ptr, h) != .null };
                }
            },
            .load_zoom => |i| st.regs[i.dst] = .{ .number = st.zoom },
            .load_geom => |i| st.regs[i.dst] = .{ .string = switch (st.fields.geom) {
                .point => "Point",
                .line => "LineString",
                .polygon => "Polygon",
                .unknown => return error.Eval,
            } },
            .load_id => |i| st.regs[i.dst] = st.fields.id,
            .move => |i| st.regs[i.dst] = st.regs[i.src],
            .un => |i| st.regs[i.dst] = try applyUn(a, i.op, st.regs[i.a]),
            .bin => |i| st.regs[i.dst] = try applyBin(i.op, st.regs[i.a], st.regs[i.b]),
            .concat => |i| {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                for (0..i.n) |k| {
                    const s = st.regs[i.first + k].toString(a) catch return error.Eval;
                    try buf.appendSlice(a, s);
                }
                st.regs[i.dst] = .{ .string = buf.items };
            },
            .jump => |i| pc = i.target,
            .jump_if_false => |i| if (!st.regs[i.cond].truthy()) {
                pc = i.target;
            },
            .branch_case => |i| {
                const c = st.regs[i.cond];
                if (c != .boolean) return error.Eval;
                if (!c.boolean) pc = i.target;
            },
            .jump_if_true => |i| if (st.regs[i.cond].truthy()) {
                pc = i.target;
            },
            .jump_if_not_null => |i| if (st.regs[i.src] != .null) {
                pc = i.target;
            },
            .match => |i| pc = p.matches[i.table].find(st.regs[i.input]),
            .step => |i| {
                const x = st.regs[i.input].toNumber() catch return error.Eval;
                pc = p.steps[i.table].find(x);
            },
            .interp => |i| st.regs[i.dst] = try runInterp(a, &p.interps[i.table], st.regs[i.input], st),
            .ret => |i| return st.regs[i.src],
        }
    }
    return error.Eval;
}

fn handleOf(st: *const Run, slot: u32) u32 {
    if (slot >= st.handles.len) return NO_HANDLE;
    return st.handles[slot];
}

fn readField(st: *const Run, slot: u32) Value {
    const h = handleOf(st, slot);
    if (h == NO_HANDLE) return .null;
    return st.fields.get(st.fields.ptr, h);
}

/// Mirrors eval.zig's evalInterpolate step for step, INCLUDING the fact that
/// only the two endpoint cases coerce their output while the interpolated
/// pair is mixed raw. Coercing the pair first was a real divergence: 34
/// fixture inputs disagreed until this matched exactly.
fn runInterp(a: Allocator, t: *const InterpTable, input: Value, st: *Run) RunError!Value {
    const x = input.toNumber() catch return error.Eval;
    const stops = t.stops;
    if (x <= stops[0]) {
        return coerce(a, try runNested(a, &t.outputs[0], st), t.space);
    }
    if (x >= stops[stops.len - 1]) {
        return coerce(a, try runNested(a, &t.outputs[stops.len - 1], st), t.space);
    }
    var hi: usize = 1;
    while (stops[hi] < x) hi += 1;
    const lo = hi - 1;
    const f = eval_mod.interpFactor(t.kind, x, stops[lo], stops[hi]);
    const va = try runNested(a, &t.outputs[lo], st);
    const vb = try runNested(a, &t.outputs[hi], st);
    return eval_mod.lerpValueSpace(a, va, vb, f, t.space) catch error.Eval;
}

fn coerce(a: Allocator, v: Value, space: Expr.ColorSpace) RunError!Value {
    return eval_mod.coerceInterpOutput(a, v, space) catch error.Eval;
}

fn runNested(a: Allocator, p: *const Program, st: *Run) RunError!Value {
    // A nested program (an interpolate output) borrows the run's context but
    // needs its own registers; they are few and shallow.
    var regs: [32]Value = undefined;
    if (p.n_regs > regs.len) return error.Eval;
    var sub = Run{
        .zoom = st.zoom,
        .fields = st.fields,
        .handles = st.handles,
        .regs = regs[0..p.n_regs],
    };
    return run(a, p, &sub);
}

fn applyUn(a: Allocator, op: Op1, v: Value) RunError!Value {
    return switch (op) {
        .not => .{ .boolean = !(v == .boolean and v.boolean) },
        .to_string => .{ .string = v.toString(a) catch return error.Eval },
        .to_boolean => .{ .boolean = v.truthy() },
        .to_number => .{ .number = v.toNumber() catch return error.Eval },
        .length => switch (v) {
            .string => |s| .{ .number = @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len) },
            .array => |items| .{ .number = @floatFromInt(items.len) },
            else => error.Eval,
        },
        else => blk: {
            const n = num(v) catch break :blk error.Eval;
            break :blk Value{ .number = switch (op) {
                .abs => @abs(n),
                .floor => @floor(n),
                .ceil => @ceil(n),
                .round => @round(n),
                .sqrt => @sqrt(n),
                .ln => @log(n),
                .log10 => @log10(n),
                .log2 => @log2(n),
                .sin => @sin(n),
                .cos => @cos(n),
                .tan => @tan(n),
                else => unreachable,
            } };
        },
    };
}

fn applyBin(op: Op2, a: Value, b: Value) RunError!Value {
    switch (op) {
        .eq => return .{ .boolean = valueEq(a, b) },
        .neq => return .{ .boolean = !valueEq(a, b) },
        .lt, .le, .gt, .ge => {
            const ord = try compare(a, b);
            return .{ .boolean = switch (op) {
                .lt => ord == .lt,
                .le => ord != .gt,
                .gt => ord == .gt,
                .ge => ord != .lt,
                else => unreachable,
            } };
        },
        else => {},
    }
    const x = num(a) catch return error.Eval;
    const y = num(b) catch return error.Eval;
    return .{ .number = switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .mod => @mod(x, y),
        .pow => std.math.pow(f64, x, y),
        .min => @min(x, y),
        .max => @max(x, y),
        else => unreachable,
    } };
}

fn num(v: Value) error{Eval}!f64 {
    return switch (v) {
        .number => |n| n,
        else => error.Eval,
    };
}

fn valueEq(a: Value, b: Value) bool {
    return a.eql(b);
}

fn compare(a: Value, b: Value) RunError!std.math.Order {
    if (a == .number and b == .number) {
        return std.math.order(a.number, b.number);
    }
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string, b.string);
    }
    // The spec makes a mixed-type comparison an evaluation error, which the
    // interpreter enforces; a compiled program must not be laxer.
    return error.Eval;
}

// ---- the compiler ----------------------------------------------------------

const Builder = struct {
    a: Allocator,
    code: std.ArrayListUnmanaged(Ins) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    /// SHARED with any nested program (an interpolate output): slots are
    /// bound once, against the parent's handle array, so a nested program
    /// numbering its own keys would read the wrong field entirely.
    keys: *std.ArrayListUnmanaged([]const u8),
    matches: std.ArrayListUnmanaged(MatchTable) = .empty,
    steps: std.ArrayListUnmanaged(StepTable) = .empty,
    interps: std.ArrayListUnmanaged(InterpTable) = .empty,
    /// Registers handed out. Temporaries return to the watermark after a
    /// node finishes, so depth costs registers, not width.
    next_reg: Reg = 0,
    high: Reg = 0,
    /// let-binding stack: parse-time var index -> the register holding it.
    bindings: std.ArrayListUnmanaged(Reg) = .empty,

    fn alloc(self: *Builder) Error!Reg {
        if (self.next_reg == std.math.maxInt(Reg)) return error.Unsupported;
        const r = self.next_reg;
        self.next_reg += 1;
        if (self.next_reg > self.high) self.high = self.next_reg;
        return r;
    }

    fn emit(self: *Builder, ins: Ins) Error!u32 {
        const at: u32 = @intCast(self.code.items.len);
        try self.code.append(self.a, ins);
        return at;
    }

    fn here(self: *const Builder) u32 {
        return @intCast(self.code.items.len);
    }

    fn constant(self: *Builder, v: Value) Error!u32 {
        const i: u32 = @intCast(self.consts.items.len);
        try self.consts.append(self.a, v);
        return i;
    }

    fn keySlot(self: *Builder, name: []const u8) Error!u32 {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, name)) return @intCast(i);
        }
        const i: u32 = @intCast(self.keys.items.len);
        try self.keys.append(self.a, name);
        return i;
    }

    fn patch(self: *Builder, at: u32, target: u32) void {
        switch (self.code.items[at]) {
            .jump => |*j| j.target = target,
            .jump_if_false => |*j| j.target = target,
            .branch_case => |*j| j.target = target,
            .jump_if_true => |*j| j.target = target,
            .jump_if_not_null => |*j| j.target = target,
            else => unreachable,
        }
    }
};

/// Compile one expression. Returns error.Unsupported for anything outside
/// the compilable set — the caller then keeps using the interpreter, which
/// is always correct.
pub fn compile(a: Allocator, root: *const Expr) Error!Program {
    const keys = try a.create(std.ArrayListUnmanaged([]const u8));
    keys.* = .empty;
    return compileShared(a, root, keys);
}

fn compileShared(
    a: Allocator,
    root: *const Expr,
    keys: *std.ArrayListUnmanaged([]const u8),
) Error!Program {
    var b = Builder{ .a = a, .keys = keys };
    const dst = try b.alloc();
    try compileInto(&b, root, dst);
    _ = try b.emit(.{ .ret = .{ .src = dst } });
    return .{
        .code = b.code.items,
        .consts = b.consts.items,
        .keys = keys.items,
        .matches = b.matches.items,
        .steps = b.steps.items,
        .interps = b.interps.items,
        .n_regs = b.high,
    };
}

fn compileInto(b: *Builder, e: *const Expr, dst: Reg) Error!void {
    const mark = b.next_reg;
    defer b.next_reg = mark;

    switch (e.*) {
        .literal => |v| _ = try b.emit(.{ .load_const = .{ .dst = dst, .idx = try b.constant(v) } }),
        .zoom => _ = try b.emit(.{ .load_zoom = .{ .dst = dst } }),
        .geometry_type => _ = try b.emit(.{ .load_geom = .{ .dst = dst } }),
        .id => _ = try b.emit(.{ .load_id = .{ .dst = dst } }),
        .get => |prop| {
            // Object reads and computed names: interpreter.
            if (prop.obj != null or prop.key_expr != null) return error.Unsupported;
            _ = try b.emit(.{ .load_prop = .{ .dst = dst, .slot = try b.keySlot(prop.key) } });
        },
        .has => |prop| {
            if (prop.obj != null or prop.key_expr != null) return error.Unsupported;
            _ = try b.emit(.{ .load_has = .{ .dst = dst, .slot = try b.keySlot(prop.key) } });
        },
        .var_ref => |idx| {
            if (idx >= b.bindings.items.len) return error.Unsupported;
            _ = try b.emit(.{ .move = .{ .dst = dst, .src = b.bindings.items[idx] } });
        },
        .let_bind => |let| {
            const base = b.bindings.items.len;
            for (let.values) |ve| {
                const r = try b.alloc();
                try compileInto(b, ve, r);
                try b.bindings.append(b.a, r);
            }
            try compileInto(b, let.body, dst);
            b.bindings.shrinkRetainingCapacity(base);
        },
        .coalesce => |list| {
            // First non-null wins; everything after it is skipped.
            var done: std.ArrayListUnmanaged(u32) = .empty;
            defer done.deinit(b.a);
            for (list, 0..) |sub, i| {
                try compileInto(b, sub, dst);
                if (i + 1 == list.len) break;
                try done.append(b.a, try b.emit(.{ .jump_if_not_null = .{ .src = dst, .target = 0 } }));
            }
            for (done.items) |at| b.patch(at, b.here());
        },
        .case_op => |c| {
            if (c.conds.len != c.outs.len) return error.Unsupported;
            var ends: std.ArrayListUnmanaged(u32) = .empty;
            defer ends.deinit(b.a);
            for (c.conds, c.outs) |cond, out| {
                const cr = try b.alloc();
                try compileInto(b, cond, cr);
                const skip = try b.emit(.{ .branch_case = .{ .cond = cr, .target = 0 } });
                try compileInto(b, out, dst);
                try ends.append(b.a, try b.emit(.{ .jump = .{ .target = 0 } }));
                b.patch(skip, b.here());
                b.next_reg = mark; // the condition register is free again
            }
            try compileInto(b, c.fallback, dst);
            for (ends.items) |at| b.patch(at, b.here());
        },
        .match_op => |m| {
            const ir = try b.alloc();
            try compileInto(b, m.input, ir);
            const table: u32 = @intCast(b.matches.items.len);
            try b.matches.append(b.a, .{ .fallback = 0 });
            _ = try b.emit(.{ .match = .{ .input = ir, .table = table } });
            b.next_reg = mark;

            var strings: std.StringHashMapUnmanaged(u32) = .empty;
            var numbers: std.ArrayListUnmanaged(MatchTable.NumTarget) = .empty;
            var ends: std.ArrayListUnmanaged(u32) = .empty;
            defer ends.deinit(b.a);
            for (m.branches) |br| {
                const target = b.here();
                switch (br.label) {
                    .string => |s| {
                        // First label wins, matching the interpreter's scan.
                        if (!strings.contains(s)) try strings.put(b.a, s, target);
                    },
                    .number => |n| try numbers.append(b.a, .{ .key = n, .target = target }),
                    else => return error.Unsupported,
                }
                try compileInto(b, br.out, dst);
                try ends.append(b.a, try b.emit(.{ .jump = .{ .target = 0 } }));
            }
            const fallback = b.here();
            try compileInto(b, m.fallback, dst);
            for (ends.items) |at| b.patch(at, b.here());

            std.mem.sort(MatchTable.NumTarget, numbers.items, {}, struct {
                fn lt(_: void, x: MatchTable.NumTarget, y: MatchTable.NumTarget) bool {
                    return x.key < y.key;
                }
            }.lt);
            b.matches.items[table] = .{
                .strings = strings,
                .numbers = numbers.items,
                .fallback = fallback,
            };
        },
        .step_op => |s| {
            if (s.outputs.len != s.thresholds.len + 1) return error.Unsupported;
            const ir = try b.alloc();
            try compileInto(b, s.input, ir);
            const table: u32 = @intCast(b.steps.items.len);
            try b.steps.append(b.a, .{ .thresholds = &.{}, .targets = &.{} });
            _ = try b.emit(.{ .step = .{ .input = ir, .table = table } });
            b.next_reg = mark;

            const targets = try b.a.alloc(u32, s.outputs.len);
            var ends: std.ArrayListUnmanaged(u32) = .empty;
            defer ends.deinit(b.a);
            for (s.outputs, 0..) |out, i| {
                targets[i] = b.here();
                try compileInto(b, out, dst);
                try ends.append(b.a, try b.emit(.{ .jump = .{ .target = 0 } }));
            }
            for (ends.items) |at| b.patch(at, b.here());
            b.steps.items[table] = .{ .thresholds = s.thresholds, .targets = targets };
        },
        .interp => |ip| {
            if (ip.outputs.len != ip.stops.len or ip.stops.len == 0) return error.Unsupported;
            const ir = try b.alloc();
            try compileInto(b, ip.input, ir);
            const outs = try b.a.alloc(Program, ip.outputs.len);
            // Nested outputs share the parent's key table.
            for (ip.outputs, 0..) |out, i| outs[i] = try compileShared(b.a, out, b.keys);
            const table: u32 = @intCast(b.interps.items.len);
            try b.interps.append(b.a, .{
                .kind = ip.kind,
                .space = ip.space,
                .stops = ip.stops,
                .outputs = outs,
            });
            _ = try b.emit(.{ .interp = .{ .dst = dst, .input = ir, .table = table } });
        },
        .op => |call| try compileOp(b, call, dst),
        else => return error.Unsupported,
    }
}

fn compileOp(b: *Builder, call: Expr.OpCall, dst: Reg) Error!void {
    const mark = b.next_reg;
    defer b.next_reg = mark;

    if (unaryOf(call.op)) |u| {
        if (call.args.len != 1) return error.Unsupported;
        const r = try b.alloc();
        try compileInto(b, call.args[0], r);
        _ = try b.emit(.{ .un = .{ .op = u, .dst = dst, .a = r } });
        return;
    }
    if (binaryOf(call.op)) |bo| {
        // min/max/+/* are variadic in the spec; fold left. A comparison,
        // though, takes an optional THIRD argument (a collator) with its own
        // string semantics -- that form goes to the interpreter.
        if (call.args.len < 2) return error.Unsupported;
        if (isCompare(bo) and call.args.len != 2) return error.Unsupported;
        const ra = try b.alloc();
        try compileInto(b, call.args[0], ra);
        const rb = try b.alloc();
        for (call.args[1..]) |arg| {
            try compileInto(b, arg, rb);
            _ = try b.emit(.{ .bin = .{ .op = bo, .dst = ra, .a = ra, .b = rb } });
        }
        _ = try b.emit(.{ .move = .{ .dst = dst, .src = ra } });
        return;
    }
    switch (call.op) {
        .all, .any => {
            // Short-circuit, exactly as the interpreter does.
            const want_true = call.op == .all;
            var outs: std.ArrayListUnmanaged(u32) = .empty;
            defer outs.deinit(b.a);
            const r = try b.alloc();
            for (call.args) |arg| {
                try compileInto(b, arg, r);
                try outs.append(b.a, try b.emit(if (want_true)
                    .{ .jump_if_false = .{ .cond = r, .target = 0 } }
                else
                    .{ .jump_if_true = .{ .cond = r, .target = 0 } }));
            }
            // Fell through: every arg agreed.
            _ = try b.emit(.{ .load_const = .{
                .dst = dst,
                .idx = try b.constant(.{ .boolean = want_true }),
            } });
            const done = try b.emit(.{ .jump = .{ .target = 0 } });
            const short = b.here();
            for (outs.items) |at| b.patch(at, short);
            _ = try b.emit(.{ .load_const = .{
                .dst = dst,
                .idx = try b.constant(.{ .boolean = !want_true }),
            } });
            b.patch(done, b.here());
        },
        .concat => {
            if (call.args.len == 0) return error.Unsupported;
            // Consecutive registers, so the instruction takes a base + count.
            const first = try b.alloc();
            for (call.args[1..]) |_| _ = try b.alloc();
            for (call.args, 0..) |arg, i| {
                try compileInto(b, arg, @intCast(first + i));
            }
            _ = try b.emit(.{ .concat = .{
                .dst = dst,
                .first = first,
                .n = @intCast(call.args.len),
            } });
        },
        else => return error.Unsupported,
    }
}

fn isCompare(op: Op2) bool {
    return switch (op) {
        .eq, .neq, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn unaryOf(op: exprs.Op) ?Op1 {
    return switch (op) {
        .not => .not,
        .abs => .abs,
        .floor => .floor,
        .ceil => .ceil,
        .round => .round,
        .sqrt => .sqrt,
        .ln => .ln,
        .log10 => .log10,
        .log2 => .log2,
        .sin => .sin,
        .cos => .cos,
        .tan => .tan,
        .to_number => null, // multi-arg coercion with fallbacks: interpreter
        .to_string => .to_string,
        .to_boolean => .to_boolean,
        .length => .length,
        else => null,
    };
}

fn binaryOf(op: exprs.Op) ?Op2 {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .min => .min,
        .max => .max,
        .eq => .eq,
        .neq => .neq,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        else => null,
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const TestFeature = struct {
    keys: []const []const u8,
    values: []const Value,

    fn resolve(ctx: ?*const anyopaque, key: []const u8) u32 {
        const self: *const TestFeature = @ptrCast(@alignCast(ctx.?));
        for (self.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return @intCast(i);
        }
        return NO_HANDLE;
    }

    fn get(ptr: ?*const anyopaque, handle: u32) Value {
        const self: *const TestFeature = @ptrCast(@alignCast(ptr.?));
        if (handle >= self.values.len) return .null;
        return self.values[handle];
    }
};

/// Compile and run, and assert the interpreter agrees — the only correctness
/// standard this tier has.
fn parseJson(a: Allocator, json: []const u8) !exprs.Parsed {
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return exprs.parse(a, doc);
}

fn bothAgree(a: Allocator, json: []const u8, feat: *const TestFeature, zoom: f64) !Value {
    const parsed = try parseJson(a, json);
    const prog = try compile(a, parsed.root);

    const handles = try a.alloc(u32, prog.keyCount());
    prog.bind(TestFeature.resolve, feat, handles);
    const regs = try a.alloc(Value, @max(1, prog.regCount()));
    var st = Run{
        .zoom = zoom,
        .fields = .{ .ptr = feat, .get = TestFeature.get },
        .handles = handles,
        .regs = regs,
    };
    const compiled = try run(a, &prog, &st);

    var ctx = eval_mod.Context{ .zoom = zoom };
    var ifeat = InterpFeature{ .f = feat };
    ctx.feature = .{ .ptr = &ifeat, .get_fn = InterpFeature.get };
    const interpreted = try eval_mod.eval(a, parsed.root, &ctx);
    try testing.expect(compiled.eql(interpreted));
    return compiled;
}

const InterpFeature = struct {
    f: *const TestFeature,
    fn get(ptr: ?*const anyopaque, key: []const u8) Value {
        const self: *const InterpFeature = @ptrCast(@alignCast(ptr.?));
        for (self.f.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return self.f.values[i];
        }
        return .null;
    }
};

test "Class follows the dependency set" {
    try testing.expectEqual(Class.constant, Class.of(.{}));
    try testing.expectEqual(Class.zoom_only, Class.of(.{ .zoom = true }));
    try testing.expectEqual(Class.data_driven, Class.of(.{ .feature = true }));
    try testing.expectEqual(Class.zoom_and_data, Class.of(.{ .feature = true, .zoom = true }));
    // Host state cannot be folded and is re-read per frame, like zoom.
    try testing.expectEqual(Class.zoom_only, Class.of(.{ .global = true }));
    try testing.expectEqual(Class.zoom_and_data, Class.of(.{ .feature = true, .global = true }));
    try testing.expect(!Class.of(.{ .zoom = true }).needsLayout());
    try testing.expect(Class.of(.{ .feature = true }).needsLayout());
}

test "compiled programs agree with the interpreter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feat = TestFeature{
        .keys = &.{ "depth", "kind", "name" },
        .values = &.{ .{ .number = 12 }, .{ .string = "wreck" }, .{ .string = "Annapolis" } },
    };

    const cases = [_][]const u8{
        \\["get", "depth"]
        ,
        \\["has", "depth"]
        ,
        \\["==", ["get", "kind"], "wreck"]
        ,
        \\["all", [">", ["get", "depth"], 5], ["==", ["get", "kind"], "wreck"]]
        ,
        \\["any", [">", ["get", "depth"], 50], ["==", ["get", "kind"], "rock"]]
        ,
        \\["match", ["get", "kind"], "rock", 1, "wreck", 2, 0]
        ,
        \\["match", ["get", "kind"], ["rock", "wreck"], 7, 0]
        ,
        \\["case", [">", ["get", "depth"], 20], "deep", [">", ["get", "depth"], 5], "mid", "shallow"]
        ,
        \\["coalesce", ["get", "missing"], ["get", "kind"], "fallback"]
        ,
        \\["step", ["get", "depth"], "a", 5, "b", 20, "c"]
        ,
        \\["concat", "pat:", ["get", "kind"]]
        ,
        \\["+", ["get", "depth"], 3, 4]
        ,
        \\["*", ["get", "depth"], 2]
        ,
        \\["let", "d", ["get", "depth"], ["+", ["var", "d"], ["var", "d"]]]
        ,
        \\["interpolate", ["linear"], ["zoom"], 10, 1, 16, 4]
        ,
        \\["interpolate", ["exponential", 2], ["get", "depth"], 0, 0, 20, 10]
        ,
        \\["interpolate", ["linear"], ["zoom"], 10, "#ff0000", 16, "#0000ff"]
        ,
        \\["floor", ["/", ["get", "depth"], 5]]
        ,
        \\["!", ["==", ["get", "kind"], "rock"]]
        ,
        \\["to-string", ["get", "depth"]]
        ,
    };
    for (cases) |json| {
        _ = bothAgree(a, json, &feat, 13.5) catch |e| {
            std.debug.print("case failed: {s} ({t})\n", .{ json, e });
            return e;
        };
    }
}

test "a match dispatches by table, and an absent key reads null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const feat = TestFeature{ .keys = &.{"kind"}, .values = &.{.{ .string = "wreck" }} };
    const v = try bothAgree(a, "[\"match\", [\"get\", \"kind\"], \"rock\", 1, \"wreck\", 2, 0]", &feat, 0);
    try testing.expectEqual(@as(f64, 2), v.number);

    // A tile layer without the key binds NO_HANDLE and the get reads null,
    // which is the fallback branch — not an error.
    const other = TestFeature{ .keys = &.{"other"}, .values = &.{.{ .string = "x" }} };
    const v2 = try bothAgree(a, "[\"match\", [\"get\", \"kind\"], \"rock\", 1, \"wreck\", 2, 0]", &other, 0);
    try testing.expectEqual(@as(f64, 0), v2.number);
}

test "keys intern once per program and bind once per layer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The same key three times must yield ONE slot: that is the lookup the
    // interpreter was paying for per read.
    const parsed = try parseJson(a,
        \\["case", [">", ["get", "d"], 1], ["get", "d"], ["<", ["get", "d"], 0], 0, ["get", "d"]]
    );
    const prog = try compile(a, parsed.root);
    try testing.expectEqual(@as(usize, 1), prog.keyCount());

    const feat = TestFeature{ .keys = &.{ "x", "d" }, .values = &.{ .null, .{ .number = 5 } } };
    const handles = try a.alloc(u32, prog.keyCount());
    prog.bind(TestFeature.resolve, &feat, handles);
    try testing.expectEqual(@as(u32, 1), handles[0]); // the decoder's own index
}

test "unsupported operators refuse to compile rather than guess" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each reads the feature, so none folds to a literal at parse -- a
    // folded constant IS compilable and would not prove anything.
    const cases = [_][]const u8{
        \\["format", ["get", "name"], {}]
        ,
        \\["number-format", ["get", "d"], {}]
        ,
        \\["properties"]
        ,
        \\["at", 0, ["get", "list"]]
        ,
        \\["upcase", ["get", "name"]]
        ,
    };
    for (cases) |json| {
        const parsed = parseJson(a, json) catch continue;
        testing.expectError(error.Unsupported, compile(a, parsed.root)) catch |e| {
            std.debug.print("expected refusal: {s}\n", .{json});
            return e;
        };
    }
}

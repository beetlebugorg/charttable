const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const apple = target.result.os.tag == .macos or target.result.os.tag == .ios;

    // The library module every consumer imports (`@import("charttable")`).
    const mod = b.addModule("charttable", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // libc everywhere (the lookout rule): the Metal shim is ObjC on
        // Apple, and util/lock.zig's non-Apple path is pthread — both sides
        // of the fence need it.
        .link_libc = true,
    });

    // The Metal backend (src/gpu/gpu_metal.zig + metal_shim.m). The shader
    // source rides an anonymous import (`@embedFile("metal_msl")`) and is
    // compiled by the shim at runtime — no offline shader toolchain. The
    // import itself is target-independent; only the ObjC shim and the
    // frameworks are Apple-gated (non-mac targets select gpu_none.zig and
    // never analyze the Metal backend).
    mod.addAnonymousImport("metal_msl", .{ .root_source_file = b.path("shaders/metal.metal") });
    if (apple) {
        mod.addIncludePath(b.path("src/gpu")); // metal_shim.h for the @cImport
        // Manual retain/release on purpose — objects live in C structs
        // (same pattern as lookout-marine's build.zig).
        mod.addCSourceFile(.{
            .file = b.path("src/gpu/metal_shim.m"),
            .flags = &.{ "-O2", "-fno-objc-arc", "-fno-sanitize=undefined" },
        });
        mod.linkFramework("Metal", .{});
        mod.linkFramework("QuartzCore", .{});
        mod.linkFramework("Foundation", .{});
    }

    // Where the vendored spec conformance fixtures live (absolute, so the
    // test binary finds them regardless of its own cwd). The harness skips
    // itself when the directory is absent.
    const ct_opts = b.addOptions();
    ct_opts.addOption([]const u8, "spec_fixture_dir", b.pathFromRoot("test/spec/expression"));
    ct_opts.addOption([]const u8, "report_path", b.pathFromRoot("test/spec/conformance-failures.txt"));
    mod.addOptions("ct_build", ct_opts);

    // `zig build test` — the gate. Every source module is referenced from
    // src/root.zig so its tests ride this one build.
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

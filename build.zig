const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module every consumer imports (`@import("charttable")`).
    const mod = b.addModule("charttable", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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

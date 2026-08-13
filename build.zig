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
    // libwebp, when the host has it. Optional on purpose: charttable's own
    // PNG reader covers what tile servers usually send, and a hard
    // dependency would land on every embedder. Tile servers that serve WebP
    // (elevation tiles especially) need this.
    const use_webp = b.option(bool, "webp", "Decode WebP tiles with libwebp") orelse false;
    // libpng, likewise optional. Ours reads what tile servers send; libpng
    // reads the shapes ours declines (interlaced, 16-bit) and is the
    // reference for correctness.
    const use_libpng = b.option(bool, "libpng", "Decode PNG with libpng instead of the built-in reader") orelse false;
    if (use_webp or use_libpng) {
        if (use_webp) mod.linkSystemLibrary("webp", .{});
        if (use_libpng) mod.linkSystemLibrary("png", .{});
        // Homebrew's prefix is not on the default search path.
        if (target.result.os.tag == .macos) {
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
    }

    const ct_opts = b.addOptions();
    ct_opts.addOption(bool, "webp", use_webp);
    ct_opts.addOption(bool, "libpng", use_libpng);
    ct_opts.addOption([]const u8, "spec_fixture_dir", b.pathFromRoot("test/spec/expression"));
    ct_opts.addOption([]const u8, "report_path", b.pathFromRoot("test/spec/conformance-failures.txt"));
    ct_opts.addOption([]const u8, "assets_dir", b.pathFromRoot("test/assets"));
    ct_opts.addOption([]const u8, "out_dir", b.pathFromRoot("zig-out"));
    mod.addOptions("ct_build", ct_opts);

    // The C ABI as a static library: `zig build lib` drops libcharttable.a
    // and include/charttable.h into zig-out for a host to link (src/capi.zig
    // holds the exports; the header is checked in, not generated).
    const lib = b.addLibrary(.{
        .name = "charttable",
        .root_module = mod,
        .linkage = .static,
    });
    const lib_step = b.step("lib", "Build the static library + C header");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    lib_step.dependOn(&b.addInstallFileWithDir(
        b.path("include/charttable.h"),
        .header,
        "charttable.h",
    ).step);
    b.getInstallStep().dependOn(lib_step);

    // `zig build example -Dtile57=<path>` — the macOS demo.
    //
    // Built HERE rather than by hand-linking libcharttable.a: ld rejects the
    // archive Zig writes ("64-bit mach-o not 8-byte aligned") once the
    // objects reach certain sizes, and linkLibrary sidesteps the archive
    // entirely by handing the linker Zig's own objects.
    if (target.result.os.tag == .macos) {
        const tile57_path = b.option([]const u8, "tile57", "Path to a tile57 checkout, for the chart demo");
        const exe_mod = b.createModule(.{ .target = target, .optimize = optimize });
        exe_mod.link_libc = true;
        const exe = b.addExecutable(.{ .name = "chartview", .root_module = exe_mod });

        var flags: std.ArrayListUnmanaged([]const u8) = .empty;
        flags.appendSlice(b.allocator, &.{ "-O2", "-fobjc-arc" }) catch @panic("OOM");
        if (tile57_path) |tp| {
            flags.append(b.allocator, "-DUSE_TILE57_COMPOSE") catch @panic("OOM");
            exe_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ tp, "include" }) });
            exe_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ tp, "zig-out/lib/libtile57.a" }) });
        }
        exe_mod.addCSourceFile(.{
            .file = b.path("examples/macos/main.m"),
            .flags = flags.items,
        });
        exe_mod.addIncludePath(b.path("include"));
        exe_mod.linkLibrary(lib);
        if (use_webp) exe_mod.linkSystemLibrary("webp", .{});
        if (use_libpng) exe_mod.linkSystemLibrary("png", .{});
        if (use_webp or use_libpng) {
            exe_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
        for ([_][]const u8{ "Cocoa", "Metal", "QuartzCore", "CoreGraphics", "ImageIO", "UniformTypeIdentifiers" }) |fw| {
            exe_mod.linkFramework(fw, .{});
        }
        const example_step = b.step("example", "Build the macOS chart demo");
        example_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // `zig build test` — the gate. Every source module is referenced from
    // src/root.zig so its tests ride this one build.
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

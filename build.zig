const std = @import("std");
const codecs = @import("build/codecs.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const apple = switch (target.result.os.tag) {
        .macos, .ios, .visionos => true,
        else => false,
    };
    const windows = target.result.os.tag == .windows;
    const android = target.result.abi == .android or target.result.abi == .androideabi;

    // Windows can draw with either backend: D3D12 is the default there, and
    // the Vulkan backend has a win32 surface path for a host that would rather
    // run on the loader. Everywhere else this option has nothing to choose.
    const GpuBackend = enum { auto, vk, d3d12 };
    const gpu_choice = b.option(GpuBackend, "gpu", "Windows renderer backend: d3d12 (default) or vk") orelse .auto;
    const use_d3d12 = windows and gpu_choice != .vk;
    const use_vk = !apple and !use_d3d12;

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

    if (android) {
        // bionic's nullability-on-array declarations ("const struct timeval
        // _Nonnull [2]") break translate-c, and the @cImports here (png.h,
        // vulkan.h) reach sys/ headers through the NDK sysroot. The
        // annotations are hints only; defining them empty drops them for our
        // parse and the C compiles alike — the same neutralisation
        // lookout-marine applies to its own module.
        mod.addCMacro("_Nonnull", "");
        mod.addCMacro("_Nullable", "");
        mod.addCMacro("_Null_unspecified", "");
    }

    // The Metal backend (src/gpu/gpu_metal.zig + metal_shim.m). The shader
    // source rides an anonymous import (`@embedFile("metal_msl")`) and is
    // compiled by the shim at runtime — no offline shader toolchain. The
    // import itself is target-independent; only the ObjC shim and the
    // frameworks are Apple-gated (non-mac targets select gpu_none.zig and
    // never analyze the Metal backend).
    mod.addAnonymousImport("metal_msl", .{ .root_source_file = b.path("shaders/metal.metal") });

    // The Vulkan backend (src/gpu/gpu_vk.zig). Everything off Apple draws with
    // it. Unlike Metal there is no runtime shader compiler, so the programs
    // ride in precompiled as SPIR-V; shaders/vk/README.md holds the command
    // that regenerates them. The headers are vendored with no VK_USE_PLATFORM_*
    // (those drag in the X11, Wayland and Windows SDKs) and the loader is
    // linked by the consumer, which is what lets one build serve every window
    // system.
    // The D3D12 backend (src/gpu/gpu_d3d12.zig). The HLSL rides in as source
    // and is compiled by d3dcompiler_47.dll at open, so there is no offline
    // shader toolchain and no import library: d3d12.dll, dxgi.dll and the
    // compiler are all loaded by name at runtime (src/gpu/c_d3d12.zig).
    if (use_d3d12) {
        const hlsl = [_][2][]const u8{
            .{ "d3d12_fill_vert", "shaders/d3d12/fill.vert.hlsl" },
            .{ "d3d12_fill_frag", "shaders/d3d12/fill.frag.hlsl" },
            .{ "d3d12_pattern_vert", "shaders/d3d12/pattern.vert.hlsl" },
            .{ "d3d12_pattern_frag", "shaders/d3d12/pattern.frag.hlsl" },
            .{ "d3d12_sprite_vert", "shaders/d3d12/sprite.vert.hlsl" },
            .{ "d3d12_sprite_frag", "shaders/d3d12/sprite.frag.hlsl" },
            .{ "d3d12_sdf_frag", "shaders/d3d12/sdf.frag.hlsl" },
            .{ "d3d12_overlay_vert", "shaders/d3d12/overlay.vert.hlsl" },
            .{ "d3d12_overlay_frag", "shaders/d3d12/overlay.frag.hlsl" },
        };
        for (hlsl) |e| mod.addAnonymousImport(e[0], .{ .root_source_file = b.path(e[1]) });
    }

    if (use_vk) {
        const spv = [_][2][]const u8{
            .{ "fill_vert_spv", "shaders/vk/fill.vert.spv" },
            .{ "fill_frag_spv", "shaders/vk/fill.frag.spv" },
            .{ "sprite_vert_spv", "shaders/vk/sprite.vert.spv" },
            .{ "sprite_frag_spv", "shaders/vk/sprite.frag.spv" },
            .{ "sdf_frag_spv", "shaders/vk/sdf.frag.spv" },
            .{ "pattern_vert_spv", "shaders/vk/pattern.vert.spv" },
            .{ "pattern_frag_spv", "shaders/vk/pattern.frag.spv" },
            .{ "overlay_vert_spv", "shaders/vk/overlay.vert.spv" },
            .{ "overlay_frag_spv", "shaders/vk/overlay.frag.spv" },
        };
        for (spv) |e| mod.addAnonymousImport(e[0], .{ .root_source_file = b.path(e[1]) });
        mod.addIncludePath(b.path("vendor/vulkan/include"));
    }

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
    const use_webp = b.option(bool, "webp", "Decode WebP tiles with libwebp") orelse true;
    // libpng, likewise. Ours reads what tile servers send; libpng
    // reads the shapes ours declines (interlaced, 16-bit) and is the
    // reference for correctness.
    const use_libpng = b.option(bool, "libpng", "Decode PNG with libpng instead of the built-in reader") orelse true;
    // A directory holding cross-built codec archives: include/ plus
    // lib/libwebp.a and lib/libpng16.a. Set it for a target that has no system
    // package manager, such as an iOS or visionOS device. Left unset, the codecs
    // come from Homebrew on macOS and from the system elsewhere.
    // An empty value counts as unset, so an embedder can pass the option
    // unconditionally.
    const codec_dir: ?[]const u8 = blk: {
        const d = b.option([]const u8, "codec-dir", "Directory of cross-built codec archives (include/ + lib/)") orelse break :blk null;
        break :blk if (d.len == 0) null else d;
    };
    // Under a sysroot the SDK's own headers are not on the search path for
    // this module's C sources, and a framework header that includes a plain
    // one (Security.h -> libDER/DERItem.h) stops resolving. The host build
    // passes a sysroot on every Xcode cross build.
    if (b.sysroot) |sr| {
        mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sr, "usr/include" }) });
    }
    if (use_webp or use_libpng) {
        // Windows and Android carry neither Homebrew nor a system copy of
        // these, and both options default to on, so the sources are fetched
        // by the package manager and compiled in (build/codecs.zig) — zlib
        // included, so nothing here asks the linker to search for -lz.
        // Naming a codec-dir still wins, for a build with its own archives.
        if ((windows or android) and codec_dir == null) {
            _ = codecs.addFromSource(b, mod, target, use_webp, use_libpng);
        } else {
            if (codec_dir) |dir| {
                mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include" }) });
            } else if (target.result.os.tag == .macos) {
                mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            }
            if (use_webp) linkCodec(b, mod, target, codec_dir, "webp");
            if (use_libpng) {
                linkCodec(b, mod, target, codec_dir, "png16");
                // libpng's objects arrive with their zlib symbols undefined, so
                // zlib has to resolve here as well as in whatever links this.
                linkZlib(b, mod);
            }
        }
    }

    const ct_opts = b.addOptions();
    ct_opts.addOption(bool, "webp", use_webp);
    ct_opts.addOption(bool, "libpng", use_libpng);
    // Which renderer src/gpu/gpu.zig selects on Windows.
    ct_opts.addOption(bool, "gpu_d3d12", use_d3d12);
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
        if (use_webp) linkCodec(b, exe_mod, target, codec_dir, "webp");
        if (use_libpng) {
            linkCodec(b, exe_mod, target, codec_dir, "png16");
            linkZlib(b, exe_mod);
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
    // The library leaves the Vulkan loader to whoever links it (the shells do,
    // through meson/gradle/MSBuild), but a test binary IS the consumer, so it
    // has to name the loader itself. tests.root_module IS `mod`, so this flag
    // rides on every consumer too — harmless where the shell links the loader
    // anyway, but an android cross-build has no -lvulkan to find, and its
    // tests never run; the gradle/CMake link names the loader there. The
    // D3D12 backend links nothing.
    if (use_vk and !android) tests.root_module.linkSystemLibrary("vulkan", .{});
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Link an image codec by ABSOLUTE PATH rather than by name.
///
/// `linkSystemLibrary` cannot find Homebrew under a sysroot, and every Xcode
/// cross build passes one: zig resolves library search paths beneath the
/// sysroot, where Homebrew is not. An object file handed over by path is not
/// searched for at all. Adding Homebrew's directory to the search path is not
/// the fix either, because one unopenable directory takes the whole search
/// down and the SDK's own libz stops resolving with it.
///
/// The static archive is also what a shipped app needs. A dynamic link against
/// Homebrew's dylib would require Homebrew on the user's machine.
///
/// Falls back to the plain system link off macOS, where Homebrew is not the
/// source of these libraries.
fn linkCodec(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    codec_dir: ?[]const u8,
    name: []const u8,
) void {
    if (codec_dir) |dir| {
        mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ dir, b.fmt("lib/lib{s}.a", .{name}) }) });
        return;
    }
    if (target.result.os.tag != .macos) {
        mod.linkSystemLibrary(name, .{});
        return;
    }
    mod.addObjectFile(.{ .cwd_relative = b.fmt("/opt/homebrew/lib/lib{s}.a", .{name}) });
}

/// Link zlib, which libpng needs and does not carry.
///
/// Under a sysroot `linkSystemLibrary("z")` fails with "searched paths: none",
/// because the search is rooted beneath the SDK and finds nothing there. Name
/// the SDK's own stub outright instead. Without a sysroot the plain system
/// link is correct.
fn linkZlib(b: *std.Build, mod: *std.Build.Module) void {
    if (b.sysroot) |sr| {
        mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ sr, "usr/lib/libz.tbd" }) });
    } else {
        mod.linkSystemLibrary("z", .{});
    }
}

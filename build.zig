const std = @import("std");
const codecs = @import("build/codecs.zig");
/// Read for `.version`, which is the dev sentinel a source build reports. A
/// release passes the tag as `-Dversion` instead.
const zon = @import("build.zig.zon");

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

    // The same module again, for `zig build test`. A test binary IS the
    // consumer of the renderer, so it names the Vulkan loader itself; the
    // library must not. Keeping the two apart is what leaves that one link
    // input off every archive, shared library and cross build.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

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
    // Compile the codecs from source instead of taking them from the platform.
    // Windows and Android have neither Homebrew nor a system copy, so they turn
    // it on by themselves. A cross build asks for it too: the system headers of
    // the host describe the host, and a release wants an archive that carries
    // its own decoders rather than one that hunts for them on the target.
    const codec_source = b.option(bool, "codec-source", "Compile libwebp and libpng from source") orelse (windows or android);
    // The version the library reports and the shared library stamps into its
    // soname. A release passes the tag, so nobody hand-edits a version to match
    // one. build.zig.zon carries the default, for every other build.
    const version = b.option([]const u8, "version", "Version the library reports (default: build.zig.zon)") orelse zon.version;
    const semver = std.SemanticVersion.parse(version) catch @panic("-Dversion is not a semantic version");

    const ct_opts = b.addOptions();
    // NUL-terminated, so charttable_version() hands the pointer straight to C.
    ct_opts.addOption([:0]const u8, "version", b.allocator.dupeZ(u8, version) catch @panic("OOM"));
    ct_opts.addOption(bool, "webp", use_webp);
    ct_opts.addOption(bool, "libpng", use_libpng);
    // Which renderer src/gpu/gpu.zig selects on Windows.
    ct_opts.addOption(bool, "gpu_d3d12", use_d3d12);
    // Where the vendored spec conformance fixtures live (absolute, so the
    // test binary finds them regardless of its own cwd). The harness skips
    // itself when the directory is absent.
    ct_opts.addOption([]const u8, "spec_fixture_dir", b.pathFromRoot("test/spec/expression"));
    ct_opts.addOption([]const u8, "report_path", b.pathFromRoot("test/spec/conformance-failures.txt"));
    ct_opts.addOption([]const u8, "assets_dir", b.pathFromRoot("test/assets"));
    ct_opts.addOption([]const u8, "out_dir", b.pathFromRoot("zig-out"));

    // Both modules take the same configuration. Only the test module names the
    // Vulkan loader (below), so no artifact a consumer takes away carries it.
    for ([_]*std.Build.Module{ mod, test_mod }) |m| {
        if (android) {
            // bionic's nullability-on-array declarations ("const struct timeval
            // _Nonnull [2]") break translate-c, and the @cImports here (png.h,
            // vulkan.h) reach sys/ headers through the NDK sysroot. The
            // annotations are hints only; defining them empty drops them for our
            // parse and the C compiles alike — the same neutralisation
            // lookout-marine applies to its own module.
            m.addCMacro("_Nonnull", "");
            m.addCMacro("_Nullable", "");
            m.addCMacro("_Null_unspecified", "");
        }

        // The Metal backend (src/gpu/gpu_metal.zig + metal_shim.m). The shader
        // source rides an anonymous import (`@embedFile("metal_msl")`) and is
        // compiled by the shim at runtime — no offline shader toolchain. The
        // import itself is target-independent; only the ObjC shim and the
        // frameworks are Apple-gated (non-mac targets select gpu_none.zig and
        // never analyze the Metal backend).
        m.addAnonymousImport("metal_msl", .{ .root_source_file = b.path("shaders/metal.metal") });

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
            for (hlsl) |e| m.addAnonymousImport(e[0], .{ .root_source_file = b.path(e[1]) });
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
            for (spv) |e| m.addAnonymousImport(e[0], .{ .root_source_file = b.path(e[1]) });
            m.addIncludePath(b.path("vendor/vulkan/include"));
        }

        if (apple) {
            m.addIncludePath(b.path("src/gpu")); // metal_shim.h for the @cImport
            // Manual retain/release on purpose — objects live in C structs
            // (same pattern as lookout-marine's build.zig).
            m.addCSourceFile(.{
                .file = b.path("src/gpu/metal_shim.m"),
                .flags = &.{ "-O2", "-fno-objc-arc", "-fno-sanitize=undefined" },
            });
            m.linkFramework("Metal", .{});
            m.linkFramework("QuartzCore", .{});
            m.linkFramework("Foundation", .{});
        }

        // Under a sysroot the SDK's own headers are not on the search path for
        // this module's C sources, and a framework header that includes a plain
        // one (Security.h -> libDER/DERItem.h) stops resolving. The host build
        // passes a sysroot on every Xcode cross build.
        if (b.sysroot) |sr| {
            m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sr, "usr/include" }) });
            // The SDK's frameworks, for the same reason. A NATIVE macOS build
            // finds these by asking xcrun where the SDK is. Naming -Dtarget
            // makes the build a cross build, and a cross build starts with an
            // EMPTY framework search path — passing --sysroot does not fill it,
            // because the compiler reads the sysroot for headers and libraries
            // only. Metal, QuartzCore and Foundation live here.
            if (apple) m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sr, "System/Library/Frameworks" }) });
        }
        if (use_webp or use_libpng) {
            // The sources are fetched by the package manager (build.zig.zon) and
            // built here — zlib included, so nothing asks the linker to search for
            // -lz. Naming a codec-dir still wins, for a build with its own archives.
            if (codec_source and codec_dir == null) {
                _ = codecs.addFromSource(b, m, target, use_webp, use_libpng);
            } else {
                if (codec_dir) |dir| {
                    m.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include" }) });
                } else if (target.result.os.tag == .macos) {
                    m.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
                }
                if (use_webp) linkCodec(b, m, target, codec_dir, "webp");
                if (use_libpng) {
                    linkCodec(b, m, target, codec_dir, "png16");
                    // libpng's objects arrive with their zlib symbols undefined, so
                    // zlib has to resolve here as well as in whatever links this.
                    linkZlib(b, m);
                }
            }
        }
        m.addOptions("ct_build", ct_opts);
    }

    // The C ABI as a static library: `zig build lib` drops libcharttable.a
    // and include/charttable.h into zig-out for a host to link (src/capi.zig
    // holds the exports; the header is checked in, not generated).
    const lib = b.addLibrary(.{
        .name = "charttable",
        .root_module = mod,
        .linkage = .static,
    });
    const header = b.addInstallFileWithDir(
        b.path("include/charttable.h"),
        .header,
        "charttable.h",
    );
    const lib_step = b.step("lib", "Build the static library + C header");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    lib_step.dependOn(&header.step);
    b.getInstallStep().dependOn(lib_step);

    // The same C ABI as a shared library: `zig build shared` drops
    // libcharttable.so (.dylib, or charttable.dll plus its import library) next
    // to the archive. A host that loads the renderer at run time takes this one;
    // a host that links it into its own binary takes the archive.
    //
    // Its own step, not part of the default build: a shared library is a final
    // link, so it fails where the archive still builds — a target with no
    // dynamic linker, for one.
    //
    // A cross build leaves the Vulkan loader undefined, as the archive does: the
    // library draws through whichever loader the process already holds, and that
    // is what lets one build serve every window system.
    const shared = b.addLibrary(.{
        .name = "charttable",
        .root_module = mod,
        .linkage = .dynamic,
        .version = semver,
    });
    // Room in the Mach-O header for a longer install name. Zig writes
    // `@rpath/libcharttable.dylib` as the id, and a package manager rewrites
    // that to the absolute path it installed to, which is far longer.
    // install_name_tool cannot grow the load commands after the fact, so the
    // space has to be reserved at link time.
    if (apple) shared.headerpad_max_install_names = true;

    const shared_step = b.step("shared", "Build the shared library + C header");
    shared_step.dependOn(&b.addInstallArtifact(shared, .{}).step);
    shared_step.dependOn(&header.step);

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
        // The library it links already carries the codecs when they come from
        // source. Otherwise the exe names the platform archives, as the module
        // does: the archive holds the calls, not the decoders.
        if (!codec_source or codec_dir != null) {
            if (use_webp) linkCodec(b, exe_mod, target, codec_dir, "webp");
            if (use_libpng) {
                linkCodec(b, exe_mod, target, codec_dir, "png16");
                linkZlib(b, exe_mod);
            }
        }
        for ([_][]const u8{ "Cocoa", "Metal", "QuartzCore", "CoreGraphics", "ImageIO", "UniformTypeIdentifiers" }) |fw| {
            exe_mod.linkFramework(fw, .{});
        }
        const example_step = b.step("example", "Build the macOS chart demo");
        example_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // `zig build test` — the gate. Every source module is referenced from
    // src/root.zig so its tests ride this one build.
    const tests = b.addTest(.{ .root_module = test_mod });
    // The library leaves the Vulkan loader to whoever links it (the shells do,
    // through meson/gradle/MSBuild), and the test binary is that consumer, so
    // it names the loader here. An android cross-build is the exception: it has
    // no -lvulkan to find, and its tests never run. The D3D12 backend links
    // nothing.
    if (use_vk and !android) test_mod.linkSystemLibrary("vulkan", .{});
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

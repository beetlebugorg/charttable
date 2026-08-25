//! libwebp, libpng and zlib compiled from source into the charttable module.
//!
//! The default on every target; `-Dcodec-source=false` links the platform's
//! libraries instead, `-Dcodec-dir` names cross-built archives.
//!
//! Only the decoders are built. charttable reads tiles; it never writes a WebP
//! or a PNG, so libwebp's encoder, mux and demux are left out and libpng's
//! writer rides along only because it shares translation units with the reader.
//!
//! The SIMD kernels are compiled per architecture with the flag each one needs.
//! libwebp dispatches on runtime CPU detection, so an SSE4.1 kernel compiled
//! here is only ever entered on a CPU that has it.

const std = @import("std");

const webp_dec = [_][]const u8{
    "src/dec/alpha_dec.c",
    "src/dec/buffer_dec.c",
    "src/dec/frame_dec.c",
    "src/dec/idec_dec.c",
    "src/dec/io_dec.c",
    "src/dec/quant_dec.c",
    "src/dec/tree_dec.c",
    "src/dec/vp8_dec.c",
    "src/dec/vp8l_dec.c",
    "src/dec/webp_dec.c",
};

const webp_utils = [_][]const u8{
    "src/utils/bit_reader_utils.c",
    "src/utils/color_cache_utils.c",
    "src/utils/filters_utils.c",
    "src/utils/huffman_utils.c",
    "src/utils/palette.c",
    "src/utils/quant_levels_dec_utils.c",
    "src/utils/random_utils.c",
    "src/utils/rescaler_utils.c",
    "src/utils/thread_utils.c",
    "src/utils/utils.c",
};

// src/dsp/Makefile.am COMMON_SOURCES: the portable kernels.
const webp_dsp = [_][]const u8{
    "src/dsp/alpha_processing.c",
    "src/dsp/cpu.c",
    "src/dsp/dec.c",
    "src/dsp/dec_clip_tables.c",
    "src/dsp/filters.c",
    "src/dsp/lossless.c",
    "src/dsp/rescaler.c",
    "src/dsp/upsampling.c",
    "src/dsp/yuv.c",
};

const webp_dsp_sse2 = [_][]const u8{
    "src/dsp/alpha_processing_sse2.c",
    "src/dsp/dec_sse2.c",
    "src/dsp/filters_sse2.c",
    "src/dsp/lossless_sse2.c",
    "src/dsp/rescaler_sse2.c",
    "src/dsp/upsampling_sse2.c",
    "src/dsp/yuv_sse2.c",
};

const webp_dsp_sse41 = [_][]const u8{
    "src/dsp/alpha_processing_sse41.c",
    "src/dsp/dec_sse41.c",
    "src/dsp/lossless_sse41.c",
    "src/dsp/upsampling_sse41.c",
    "src/dsp/yuv_sse41.c",
};

const webp_dsp_neon = [_][]const u8{
    "src/dsp/alpha_processing_neon.c",
    "src/dsp/dec_neon.c",
    "src/dsp/filters_neon.c",
    "src/dsp/lossless_neon.c",
    "src/dsp/rescaler_neon.c",
    "src/dsp/upsampling_neon.c",
    "src/dsp/yuv_neon.c",
};

const zlib_src = [_][]const u8{
    "adler32.c", "compress.c", "crc32.c",   "deflate.c", "gzclose.c",
    "gzlib.c",   "gzread.c",   "gzwrite.c", "infback.c", "inffast.c",
    "inflate.c", "inftrees.c", "trees.c",   "uncompr.c", "zutil.c",
};

const png_src = [_][]const u8{
    "png.c",      "pngerror.c", "pngget.c",   "pngmem.c",
    "pngpread.c", "pngread.c",  "pngrio.c",   "pngrtran.c",
    "pngrutil.c", "pngset.c",   "pngtrans.c", "pngwio.c",
    "pngwrite.c", "pngwtran.c", "pngwutil.c",
};

const png_neon = [_][]const u8{
    "arm/arm_init.c",
    "arm/filter_neon_intrinsics.c",
    "arm/palette_neon_intrinsics.c",
};

/// These libraries predate the checks by decades and trip them on shapes they
/// rely on (unaligned loads, signed shifts). Zig turns UB checks on for C in
/// the safe modes, and a trap in a decoder is a crash on a malformed tile.
const base_flags = [_][]const u8{ "-O2", "-fno-sanitize=undefined" };

/// Wire the requested codecs into `mod`. Returns false when a lazy dependency
/// has not been fetched yet, in which case the build system refetches and runs
/// this file again.
pub fn addFromSource(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    want_webp: bool,
    want_libpng: bool,
) bool {
    var ready = true;
    if (want_webp) ready = addWebp(b, mod, target) and ready;
    if (want_libpng) ready = addPng(b, mod, target) and ready;
    return ready;
}

fn addWebp(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) bool {
    const dep = b.lazyDependency("libwebp", .{}) orelse return false;
    const root = dep.path(".");
    // libwebp's own sources include "src/dec/...", so they resolve against the
    // package root; charttable's @cImport asks for "webp/decode.h", which
    // resolves against src/.
    mod.addIncludePath(root);
    mod.addIncludePath(dep.path("src"));
    mod.addCSourceFiles(.{ .root = root, .files = &webp_dec, .flags = &base_flags });
    mod.addCSourceFiles(.{ .root = root, .files = &webp_utils, .flags = &base_flags });
    mod.addCSourceFiles(.{ .root = root, .files = &webp_dsp, .flags = &base_flags });
    switch (target.result.cpu.arch) {
        .x86, .x86_64 => {
            // SSE2 is baseline on x86_64 and the kernels guard themselves on
            // 32-bit; SSE4.1 has to be asked for. It is asked for at the cc1
            // level because zig resolves a C compile's cpu from the module
            // target, and an -msse4.1 in cflags loses to it. The MSVC ABI is
            // where that bites: clang defines _MSC_VER there, webp's cpu.h
            // reads that as permission to use the SSE4.1 intrinsics (real
            // MSVC needs no arch flag), and without the real features every
            // kernel fails to compile. On the other ABIs nothing defines
            // __SSE4_1__, so these units compile empty and the dispatcher
            // stays on SSE2.
            mod.addCSourceFiles(.{ .root = root, .files = &webp_dsp_sse2, .flags = &(base_flags ++ [_][]const u8{"-msse2"}) });
            mod.addCSourceFiles(.{ .root = root, .files = &webp_dsp_sse41, .flags = &(base_flags ++ [_][]const u8{
                "-Xclang", "-target-feature", "-Xclang", "+ssse3",
                "-Xclang", "-target-feature", "-Xclang", "+sse4.1",
            }) });
        },
        .aarch64, .aarch64_be => {
            mod.addCSourceFiles(.{ .root = root, .files = &webp_dsp_neon, .flags = &base_flags });
        },
        else => {},
    }
    return true;
}

fn addPng(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) bool {
    const zdep = b.lazyDependency("zlib", .{}) orelse return false;
    const pdep = b.lazyDependency("libpng", .{}) orelse return false;

    const zroot = zdep.path(".");
    mod.addIncludePath(zroot); // zlib.h, for libpng and for the charttable @cImport
    // Off Windows zlib's gz* io calls read/write/lseek/close; without the
    // define it leaves them implicitly declared, an error under C99.
    if (target.result.os.tag == .windows) {
        mod.addCSourceFiles(.{ .root = zroot, .files = &zlib_src, .flags = &base_flags });
    } else {
        mod.addCSourceFiles(.{ .root = zroot, .files = &zlib_src, .flags = &(base_flags ++ [_][]const u8{"-DZ_HAVE_UNISTD_H"}) });
    }

    const proot = pdep.path(".");
    // libpng is normally configured; the shipped prebuilt is that configuration
    // with every option at its default, which is the reader charttable wants.
    const conf = b.addWriteFiles();
    _ = conf.addCopyFile(pdep.path("scripts/pnglibconf.h.prebuilt"), "pnglibconf.h");
    mod.addIncludePath(conf.getDirectory());
    mod.addIncludePath(proot);
    mod.addCSourceFiles(.{ .root = proot, .files = &png_src, .flags = &base_flags });
    switch (target.result.cpu.arch) {
        .aarch64, .aarch64_be => {
            mod.addCSourceFiles(.{ .root = proot, .files = &png_neon, .flags = &base_flags });
        },
        else => {},
    }
    return true;
}

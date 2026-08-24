#!/usr/bin/env bash
# Print the Homebrew formula for a released version, reading each archive's
# sha256 out of <dist-dir> (the tarballs that release.yml just published).
# The tap job pipes this into Formula/charttable.rb.
#
# Usage: brew-formula.sh <version> <dist-dir>
set -euo pipefail

version="$1"
dist="$2"
# The repo the release lives in, so a fork's test release yields a formula
# pointing at the fork's own downloads.
repo="${GITHUB_REPOSITORY:-beetlebugorg/charttable}"
base="https://github.com/$repo/releases/download/v$version"

sha() { shasum -a 256 "$dist/charttable-$version-$1.tar.gz" | cut -d' ' -f1; }

# Resolved before the heredoc: a command substitution that fails inside one is
# not caught by `set -e`, and a missing archive would emit an empty sha256.
mac_arm="$(sha aarch64-macos)"
mac_intel="$(sha x86_64-macos)"
linux_arm="$(sha aarch64-linux-gnu)"
linux_intel="$(sha x86_64-linux-gnu)"

cat <<EOF
class Charttable < Formula
  desc "Native map renderer for the MapLibre style spec"
  homepage "https://github.com/beetlebugorg/charttable"
  version "$version"
  license "MIT"

  on_macos do
    on_arm do
      url "$base/charttable-$version-aarch64-macos.tar.gz"
      sha256 "$mac_arm"
    end
    on_intel do
      url "$base/charttable-$version-x86_64-macos.tar.gz"
      sha256 "$mac_intel"
    end
  end

  on_linux do
    on_arm do
      url "$base/charttable-$version-aarch64-linux-gnu.tar.gz"
      sha256 "$linux_arm"
    end
    on_intel do
      url "$base/charttable-$version-x86_64-linux-gnu.tar.gz"
      sha256 "$linux_intel"
    end
  end

  def install
    include.install "include/charttable.h"
    # The archive, the shared library, and the two symlinks that carry the
    # soname.
    lib.install Dir["lib/*"]

    # Zig writes a bare file name as the dylib id, and dyld does not search the
    # Homebrew prefix. Name the installed path instead, so a program that links
    # -lcharttable finds the library at run time. Editing a Mach-O header
    # breaks the ad-hoc signature on Apple Silicon, so sign it again.
    return unless OS.mac?

    dylib = lib/"libcharttable.#{version}.dylib"
    system "install_name_tool", "-id", lib/"libcharttable.#{version.major}.dylib", dylib
    MachO.codesign!(dylib) if Hardware::CPU.arm?
  end

  test do
    (testpath/"abi.c").write <<~C
      #include <charttable.h>
      int main(void) { return charttable_abi_layout() == 0; }
    C

    # charttable_abi_layout reports the struct-layout guard. It touches no GPU,
    # so it runs anywhere.
    if OS.mac?
      system ENV.cc, "abi.c", "-I#{include}", "-L#{lib}", "-lcharttable", "-o", "abi"
      system "./abi"
    else
      # The library leaves the Vulkan loader to the program that links it, and
      # a test machine has none. Compile against the header instead.
      system ENV.cc, "-I#{include}", "-c", "abi.c", "-o", "abi.o"
    end
  end
end
EOF

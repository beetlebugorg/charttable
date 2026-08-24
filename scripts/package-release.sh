#!/usr/bin/env bash
# Stage the built trees into the release archive for one target, and — when a
# Debian architecture is given — the matching .deb. Run it after both builds:
#
#   zig build lib    -p out/static -Dtarget=<target> -Doptimize=ReleaseFast -Dcodec-source
#   zig build shared -p out/shared -Dtarget=<target> -Doptimize=ReleaseFast -Dcodec-source
#
# Everything lands in dist/. Invoked per target by .github/workflows/release.yml.
#
# Two prefixes, not one: on Windows the static archive and the DLL's import
# library are both named charttable.lib, so a single prefix loses the first to
# the second. The archive keeps that name here and the import library becomes
# charttable.dll.lib.
#
# Usage: package-release.sh <version> <target> [deb-arch]
set -euo pipefail

version="$1"
target="$2"
deb_arch="${3:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/dist"
name="charttable-$version-$target"
stage="$out/$name"

rm -rf "$stage"
mkdir -p "$stage/lib" "$stage/include"

cp -a "$root"/out/static/lib/. "$stage/lib/"
case "$target" in
  *windows*)
    mkdir -p "$stage/bin"
    cp "$root/out/shared/bin/charttable.dll" "$stage/bin/"
    cp "$root/out/shared/lib/charttable.lib" "$stage/lib/charttable.dll.lib"
    ;;
  *macos*)
    # -a keeps the soname symlinks (libcharttable.dylib -> libcharttable.0.dylib
    # -> libcharttable.0.1.0.dylib) as links instead of three copies.
    cp -a "$root"/out/shared/lib/libcharttable*.dylib "$stage/lib/"
    ;;
  *)
    cp -a "$root"/out/shared/lib/libcharttable.so* "$stage/lib/"
    ;;
esac

cp "$root/include/charttable.h" "$stage/include/"
cp "$root/LICENSE" "$root/THIRD-PARTY-NOTICES.md" "$root/README.md" "$stage/"

cd "$out"
case "$target" in
  *windows*) rm -f "$name.zip" && zip -qry "$name.zip" "$name" ;;
  *) tar czf "$name.tar.gz" "$name" ;;
esac

# The same payload under /usr, for `apt install ./libcharttable-dev_*.deb`.
# There is no apt repository — the .deb is a release asset. One package, not the
# usual runtime/dev pair: a release asset is installed to build against, and
# splitting it would ship two files that are only ever taken together.
if [ -n "$deb_arch" ]; then
  # dpkg reads `0.2.0-rc1` as upstream 0.2.0 with revision rc1, which sorts
  # AFTER plain 0.2.0 and makes the final release look like a downgrade. `~`
  # is the separator that sorts before, so 0.2.0~rc1 upgrades to 0.2.0.
  deb_version="$(printf '%s' "$version" | sed 's/-/~/')"
  pkg="$out/deb"
  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/lib" "$pkg/usr/include" \
           "$pkg/usr/share/doc/libcharttable-dev"
  cp -a "$stage/lib/." "$pkg/usr/lib/"
  chmod 644 "$pkg/usr/lib/libcharttable.a"
  install -m644 "$stage/include/charttable.h" "$pkg/usr/include/"
  install -m644 "$root/LICENSE" "$pkg/usr/share/doc/libcharttable-dev/copyright"
  cat > "$pkg/DEBIAN/control" <<EOF
Package: libcharttable-dev
Version: $deb_version
Architecture: $deb_arch
Maintainer: Jeremy Collins <jeremy.collins@beetlebug.org>
Section: libdevel
Priority: optional
Homepage: https://github.com/beetlebugorg/charttable
Description: Native map renderer for the MapLibre style spec
 charttable takes a MapLibre style and vector tiles and draws them straight to
 the GPU, holding 60 fps through pan, pinch-zoom and rotation. Tiles lay out
 into resident GPU buckets once, so a pan, zoom or rotation is a matrix change
 rather than a rebuild.
 .
 Ships libcharttable.a, libcharttable.so and the C header. The Vulkan loader
 stays undefined in both libraries: the program that links charttable names it.
EOF
  dpkg-deb --build --root-owner-group "$pkg" "$out/libcharttable-dev_${deb_version}_${deb_arch}.deb"
  rm -rf "$pkg"
fi

rm -rf "$stage"
ls -l "$out"

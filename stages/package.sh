#!/usr/bin/env bash
# Package the PS4 xemu build as XEMU00001
# (IV0000-XEMU00001_00-XEMUPS4000000000.pkg: the IDs stay, so an update installs over earlier
# builds and keeps /data/xemu).
#   ./build.sh pkg                     version 00.01
#   XEMU_VERSION=00.16 ./build.sh pkg  version shown in the PS4's menu
# Result: out/xemu-ps4-vXX.YY.pkg (older ones are deleted). The console gets the package from
# Windows with tools/upload-to-console.sh (uploads sent from WSL were lost on the console).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
openorbis_env
B="$BUILD_ROOT/xemu"
EBOOT="$B/eboot/eboot.bin"
VERSION="${XEMU_VERSION:-00.01}"

[ -f "$EBOOT" ] || { echo "missing $EBOOT: build first" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9][0-9]\.[0-9][0-9]$ ]] || { echo "version must look like 00.01" >&2; exit 1; }
STAGE="$BUILD_ROOT/xemu-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/sce_sys"
cp "$EBOOT" "$STAGE/eboot.bin"
cp "$ORBIS_ROOT/package/sce_sys/icon0.png" "$ORBIS_ROOT/package/sce_sys/pic1.png" "$STAGE/sce_sys/"
echo "$VERSION" > "$STAGE/version.txt"
# PkgTool's pkg_build crashes ("Sequence contains no elements") on empty folders.
find "$STAGE" -type d -empty -delete
# Vulkan (RADV on GNM) runs under the plain homebrew identity (4.5 GiB of direct memory).
PKG="$(SFO_STYLE=plain NO_RIGHT_SPRX=1 DOLPHIN_PS4_MODULES_DIR=/nonexistent "$ORBIS_ROOT/package/make-pkg.sh" "$STAGE" XEMU00001 "xemu" "$VERSION" XEMUPS4 "$WORK/out" | tail -1)"
ls -la "$PKG"
# a copy in the repo's out/ folder (easy to find from Windows: \\wsl$\...); *.pkg is ignored by git
mkdir -p "$ORBIS_ROOT/out"
NAME="xemu-ps4-v$VERSION.pkg"
cp "$PKG" "$ORBIS_ROOT/out/$NAME"
find "$ORBIS_ROOT/out" -maxdepth 1 -name '*.pkg' ! -name "$NAME" -print -delete | sed 's|^|removed old |'
# Keep the symbols of every packaged build: crash logs must be symbolized against the exact binary.
mkdir -p "$OELF_DIR"
cp "$B/eboot/xemu.oelf" "$OELF_DIR/v$VERSION.oelf"
cp "$B/qemu-system-i386" "$OELF_DIR/v$VERSION.elf"
echo "out/$NAME"

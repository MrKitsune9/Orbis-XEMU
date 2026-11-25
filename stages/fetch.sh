#!/usr/bin/env bash
# Downloads the sources and applies this repo's patches on top of them:
#   xemu    github.com/xemu-project/xemu at the base in patches/BASE.txt + patches/xemu-ps4.patch
#           (branch "ps4" in ~/orbis-xemu-work/src/xemu; your edits there are kept)
#   Mesa    26.0.8 + mesa/mesa-ps4.patch (RADV on the PS4 GPU)
#   libdrm  headers only (Mesa wants them; the PS4 has no DRM)
#   ./build.sh fetch
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
need git curl tar xz

GIT_ID=(-c user.name="orbis-xemu" -c user.email="orbis-xemu@localhost")

# --- xemu ----------------------------------------------------------------------------------------
echo "== xemu"
[ -n "$XEMU_BASE" ] || { echo "patches/BASE.txt has no 'base:' line" >&2; exit 1; }
[ -d "$XEMU_SRC/.git" ] || git clone https://github.com/xemu-project/xemu.git "$XEMU_SRC"
if git -C "$XEMU_SRC" rev-parse --verify -q ps4 >/dev/null; then
    echo "branch ps4 already there (kept as is; ./tools/save-patch.sh exports your changes)"
    git -C "$XEMU_SRC" checkout -q ps4
else
    git -C "$XEMU_SRC" checkout -q -b ps4 "$XEMU_BASE"
    git -C "$XEMU_SRC" apply "$ORBIS_ROOT/patches/xemu-ps4.patch"
    git -C "$XEMU_SRC" add -A
    git -C "$XEMU_SRC" "${GIT_ID[@]}" commit -q -m "xemu-ps4 patch (imported)"
    echo "applied patches/xemu-ps4.patch on $XEMU_BASE"
fi

# --- Mesa --------------------------------------------------------------------------------------
echo "== Mesa $MESA_VER"
if [ ! -d "$MESA_SRC/.git" ]; then
    rm -rf "$MESA_SRC"
    if ! fetch_tar "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" "$MESA_SRC"; then
        rm -rf "$MESA_SRC"
        fetch_tar "https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-$MESA_VER/mesa-mesa-$MESA_VER.tar.gz" "$MESA_SRC"
    fi
    # build-id of RADV comes from the Mesa commit, so the tree must be a git repo
    git -C "$MESA_SRC" init -q
    git -C "$MESA_SRC" add -A
    git -C "$MESA_SRC" "${GIT_ID[@]}" commit -q -m "mesa $MESA_VER (upstream)"
fi
if ! git -C "$MESA_SRC" log --format=%s | grep -q "^ps4 patch"; then
    if ! git -C "$MESA_SRC" apply --check "$ORBIS_ROOT/mesa/mesa-ps4.patch" 2>/dev/null; then
        echo "mesa/mesa-ps4.patch does not apply on this Mesa: it was made for Mesa 26.0.8" >&2
        exit 1
    fi
    git -C "$MESA_SRC" apply "$ORBIS_ROOT/mesa/mesa-ps4.patch"
    git -C "$MESA_SRC" add -A
    git -C "$MESA_SRC" "${GIT_ID[@]}" commit -q -m "ps4 patch"
    echo "applied mesa/mesa-ps4.patch"
fi

# --- libdrm headers ------------------------------------------------------------------------------
echo "== libdrm $LIBDRM_VER (headers)"
fetch_tar "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" "$LIBDRM_SRC"
[ -f "$LIBDRM_SRC/include/drm/amdgpu_drm.h" ] && [ -f "$LIBDRM_SRC/amdgpu/amdgpu.h" ] || { echo "libdrm headers not where Mesa expects them" >&2; exit 1; }

echo "fetch done"

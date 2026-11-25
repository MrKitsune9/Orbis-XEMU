#!/usr/bin/env bash
# config.sh - the ONLY place with paths and versions. Every script does `source .../config.sh`.
#
# Everything generated (sources, builds, sysroot, logs) goes into $WORK, outside the repo:
#     ~/orbis-xemu-work/
#         src/      xemu, Mesa, libdrm, LLVM and the other dependencies' sources
#         sysroot/  libc++ 21, libc overlay and every library cross-built for the PS4
#         build/    build directories (mesa, xemu, sdl3, ...)
#         logs/     one log per stage
#         oelf/     ELF + symbols of every packaged version (crashlog.sh needs them)
#         .stamps/  which stages are already done
# The repo itself stays clean: only the finished .pkg is copied to out/.
#
# Override with environment variables: ORBIS_WORK, OPENORBIS, CLANG_VER, JOBS.

_cfg_self="${BASH_SOURCE[0]}"
ORBIS_ROOT_REAL="$(cd "$(dirname "$_cfg_self")" && pwd)"

export WORK="${ORBIS_WORK:-$HOME/orbis-xemu-work}"
export PSB="$WORK"                        # older name, still used by toolchain/ scripts
export SRC_ROOT="$WORK/src"
export BUILD_ROOT="$WORK/build"
export LOG_DIR="$WORK/logs"
export STAMPS="$WORK/.stamps"
export OELF_DIR="$WORK/oelf"

# Toolchain flags (linker script paths and so on) break on a space in the repo path, so a
# repo kept in a folder like "PS4 Projects" is reached through a space-free link instead.
if [ -z "${ORBIS_CONFIG_LOADED:-}" ]; then
    mkdir -p "$WORK" "$SRC_ROOT" "$BUILD_ROOT" "$LOG_DIR" "$STAMPS" "$OELF_DIR"
    if [[ "$ORBIS_ROOT_REAL" == *" "* ]]; then
        ln -sfn "$ORBIS_ROOT_REAL" "$WORK/repo"
        export ORBIS_ROOT="$WORK/repo"
    else
        export ORBIS_ROOT="$ORBIS_ROOT_REAL"
    fi
fi
export ORBIS_ROOT

# --- versions ----------------------------------------------------------------------------------
export LLVM_VER="${LLVM_VER:-21.1.6}"             # libc++ / libc++abi built for the PS4
export MESA_VER="${MESA_VER:-26.0.8}"             # RADV, with mesa/mesa-ps4.patch
export LIBDRM_VER="${LIBDRM_VER:-2.4.125}"        # headers only (the PS4 has no DRM)
export ZLIB_VER=1.3.1
export GLSLANG_VER=15.1.0
export PIXMAN_VER=0.46.4
export GLIB_VER=2.84.4
export SDL3_REV=829a65d769d935c4852f8159e964312c0957260a     # xemu's subprojects/sdl3.wrap
XEMU_BASE="$(awk '/^base:/{print $2}' "$ORBIS_ROOT/patches/BASE.txt" 2>/dev/null || true)"
export XEMU_BASE
export XEMU_SRC="${XEMU_SRC:-$SRC_ROOT/xemu}"
export MESA_SRC="$SRC_ROOT/mesa"
export LIBDRM_SRC="$SRC_ROOT/libdrm"

# --- the PS4 toolchain (clang 21 + libc++ 21 on top of the OpenOrbis C runtime) -----------------
export OPENORBIS="${OPENORBIS:-/opt/pacbrew/ps4/openorbis}"
export PS4_SYSROOT="$WORK/sysroot"                # our libc++, zlib, glib, SDL3, ... install here
export PS4_BUILD_ROOT="$WORK"                     # older name, still used by a few scripts
export PS4_TARGET="x86_64-pc-freebsd12-elf"
export CLANG_VER="${CLANG_VER:-21}"
export PS4_CC="clang-$CLANG_VER"
export PS4_CXX="clang++-$CLANG_VER"
export PS4_LD="ld.lld-$CLANG_VER"
export PS4_AR="llvm-ar-$CLANG_VER"
export PS4_RANLIB="llvm-ranlib-$CLANG_VER"
export PS4_TOOLCHAIN_BIN="$ORBIS_ROOT/toolchain/bin"      # ps4-cc / ps4-c++ (read by the cmake files)
export PS4_MESA_BUILD="$BUILD_ROOT/mesa"

# The OpenOrbis C library is musl; __PS4__ tells our patched libc++ not to take its FreeBSD paths.
export PS4_BASE_FLAGS="--target=$PS4_TARGET -D_GNU_SOURCE -D__PS4__ -D__ORBIS__ -D__OPENORBIS__ -fPIC -funwind-tables \
 --sysroot=$OPENORBIS -isystem $PS4_SYSROOT/libc-overlay -isystem $OPENORBIS/include"
export PS4_CXX_FLAGS="-nostdinc++ -isystem $PS4_SYSROOT/include/c++/v1"

export JOBS="${JOBS:-$(nproc)}"
export ORBIS_CONFIG_LOADED=1

# --- helpers -------------------------------------------------------------------------------------
need() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t  (run ./build.sh doctor)" >&2; exit 1; }
    done
}

# OpenOrbis' own environment (ps4vars.sh), plus a private libxml2.so.2 link when the distro only
# ships a newer libxml2 (PacBrew's ld.lld wants .so.2). Needed by the Mesa and package stages.
openorbis_env() {
    # shellcheck disable=SC1091
    source "$OPENORBIS/ps4vars.sh"
    if ldd "$OPENORBIS/bin/ld.lld" 2>/dev/null | grep -q "libxml2.so.2 => not found"; then
        local compat
        compat=$(ls /usr/lib/x86_64-linux-gnu/libxml2.so.* 2>/dev/null | grep -E 'libxml2\.so\.[0-9]+$' | head -1 || true)
        if [ -n "$compat" ]; then
            mkdir -p "$WORK/host-compat"
            ln -sf "$compat" "$WORK/host-compat/libxml2.so.2"
            export LD_LIBRARY_PATH="$WORK/host-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    fi
}

# fetch <url> <dest file>: download once (resumable, retries)
fetch_file() {
    local url="$1" dest="$2"
    [ -s "$dest" ] && return 0
    mkdir -p "$(dirname "$dest")"
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 -o "$dest.part" "$url" && mv "$dest.part" "$dest"
}

# fetch_tar <url> <dest dir> [tar flags]: download a tarball and unpack it with its top folder removed
fetch_tar() {
    local url="$1" dir="$2"
    [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] && return 0
    local f="$SRC_ROOT/downloads/$(basename "$url")"
    fetch_file "$url" "$f"
    mkdir -p "$dir"
    tar -xf "$f" -C "$dir" --strip-components=1
}

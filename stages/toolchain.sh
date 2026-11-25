#!/usr/bin/env bash
# The PS4 toolchain's sysroot: libc++ / libc++abi 21 (built from the LLVM release, patched for the
# OpenOrbis musl C library), the patched libc headers ("libc overlay") and the runtime library.
# Slow (~20-40 min), done once.
#   ./build.sh toolchain
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
need "$PS4_CC" "$PS4_CXX" cmake ninja curl tar xz
[ -f "$OPENORBIS/ps4vars.sh" ] || { echo "OpenOrbis not found in $OPENORBIS (see ./build.sh doctor)" >&2; exit 1; }

# libc overlay + libc++ (build-libcxx.sh runs prepare-sysroot.sh first)
bash "$ORBIS_ROOT/toolchain/build-libcxx.sh"
# libdolphinps4_rt.a: the malloc the wrappers link into everything that is not the final eboot
bash "$ORBIS_ROOT/toolchain/build-runtime.sh"
[ -f "$PS4_SYSROOT/lib/libc++.a" ] && [ -f "$PS4_SYSROOT/lib/libdolphinps4_rt.a" ] || { echo "sysroot incomplete" >&2; exit 1; }
echo "toolchain done: $PS4_SYSROOT"

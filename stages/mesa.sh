#!/usr/bin/env bash
# Cross-builds Mesa's RADV (Vulkan for the PS4's AMD GCN GPU) as static libraries into
# ~/orbis-xemu-work/build/mesa. The eboot links them in (stages/xemu.sh).
#   Mesa source   : ~/orbis-xemu-work/src/mesa   (./build.sh fetch: 26.0.8 + mesa/mesa-ps4.patch)
#   libdrm headers: ~/orbis-xemu-work/src/libdrm (headers only: the PS4 has no DRM; the winsys in
#                   mesa/winsys/ac_ps4_drm.c submits through libSceGnmDriver instead)
#   host tools    : meson/mako/pyyaml in ~/orbis-xemu-work/mesa-venv, glslangValidator from apt
# The GS-ring fix that xemu needs (xemu runs nearly every draw through a geometry shader) is part
# of mesa/winsys + mesa/mesa-ps4.patch: the legacy GS rings are allocated larger than programmed.
#   ./build.sh mesa            build (reconfigures only the first time)
#   ./build.sh mesa setup      reconfigure from scratch
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
openorbis_env
need git python3 ninja "$PS4_CC" "$PS4_CXX" "$PS4_AR" glslangValidator

ROOT="$WORK"
SYSROOT="$PS4_SYSROOT"
MESA="$MESA_SRC"
LIBDRM="$LIBDRM_SRC"
MESA_DIR="$ORBIS_ROOT/mesa"
build="$BUILD_ROOT/mesa"
[ -d "$MESA/.git" ] && [ -d "$LIBDRM/amdgpu" ] || { echo "sources missing: run ./build.sh fetch" >&2; exit 1; }
[ -f "$SYSROOT/lib/libc++.a" ] || { echo "sysroot missing: run ./build.sh toolchain" >&2; exit 1; }

# --- host tools ----------------------------------------------------------------------------------
VENV="$ROOT/mesa-venv"
if [ ! -x "$VENV/bin/meson" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q "$XEMU_SRC/python/wheels/"meson-*.whl mako pyyaml packaging
fi
mkdir -p "$ROOT/host-tools/bin"
ln -sf "$(command -v glslangValidator)" "$ROOT/host-tools/bin/glslangValidator"
export PATH="$VENV/bin:$ROOT/host-tools/bin:$PATH"

# --- header-only libdrm / libdrm_amdgpu packages for meson's dependency() checks -----------------
pc="$ROOT/mesa-pkgconfig"
mkdir -p "$pc"
rm -f "$pc/libdrm.pc"
for name in libdrm_amdgpu; do
    cat > "$pc/$name.pc" <<PCEOF
Name: $name
Description: libdrm headers only (PS4 has no DRM)
Version: 2.4.125
Cflags: -I$LIBDRM -I$LIBDRM/include/drm -I$LIBDRM/amdgpu
Libs:
PCEOF
done

# --- meson cross file ----------------------------------------------------------------------------
flags="'-target', 'x86_64-pc-freebsd12-elf', '-D_GNU_SOURCE', '-D__PS4__', '-D__OPENORBIS__',
  '-D__ORBIS__', '-DPS4', '-D__BSD_VISIBLE', '-D_BSD_SOURCE', '-fPIC', '-funwind-tables',
  '-march=btver2', '-isysroot', '$OPENORBIS', '-isystem', '$SYSROOT/libc-overlay',
  '-isystem', '$MESA_DIR/overlay', '-I$LIBDRM', '-I$LIBDRM/include/drm',
  '-isystem', '$OPENORBIS/include', '-I$OPENORBIS/usr/include'"
link="'-fuse-ld=$OPENORBIS/bin/ld.lld', '-nostdlib', '-Wl,-m,elf_x86_64', '-Wl,-pie',
  '-Wl,--eh-frame-hdr', '-Wl,--script,$OPENORBIS/link.x', '-L$OPENORBIS/lib',
  '$OPENORBIS/lib/crt1.o', '-lkernel', '-lc', '-lclang_rt.builtins-x86_64', '-lSceLibcInternal'"
cross="$ROOT/mesa-ps4-cross.ini"
cat > "$cross" <<CROSSEOF
[binaries]
c = '$PS4_CC'
cpp = '$PS4_CXX'
ar = '$PS4_AR'
strip = 'llvm-strip-$CLANG_VER'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$pc'

[built-in options]
c_args = [$flags]
cpp_args = ['-nostdinc++', '-isystem', '$SYSROOT/include/c++/v1', $flags]
c_link_args = [$link]
cpp_link_args = [$link, '$SYSROOT/lib/libc++.a', '$SYSROOT/lib/libc++abi.a',
  '$OPENORBIS/lib/libunwind.a']

[host_machine]
system = 'freebsd'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
CROSSEOF

# The PS4 implementation of the amdgpu kernel interface lives in this repo.
tr -d '\015' < "$MESA_DIR/winsys/ac_ps4_drm.c" > "$MESA/src/amd/common/ac_ps4_drm.c"

if [ "${1:-}" = setup ] || [ ! -f "$build/build.ninja" ]; then
    rm -rf "$build"
    PKG_CONFIG_LIBDIR="$pc" meson setup "$build" "$MESA" --cross-file "$cross" \
        -Dbuildtype=release -Db_ndebug=true -Ddefault_library=static \
        -Dvulkan-drivers=amd -Dgallium-drivers= -Dplatforms= -Dllvm=disabled \
        -Damd-use-llvm=false -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dglx=disabled \
        -Degl=disabled -Dgbm=disabled -Dzstd=disabled -Dexpat=disabled -Dxmlconfig=disabled \
        -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false \
        -Dshader-cache=disabled -Dvulkan-layers= -Dtools= -Dvideo-codecs= -Dspirv-tools=disabled \
        -Dperfetto=false -Dselinux=false
fi
# The static libraries RADV needs (meson's default targets also include host tools such as
# ac_ib_parser, which don't link for the PS4 and aren't needed).
libs=(src/amd/vulkan/libvulkan_radeon.a src/amd/addrlib/libaddrlib.a
    src/amd/common/libamd_common.a src/amd/compiler/libaco.a src/c11/impl/libmesa_util_c11.a
    src/compiler/libcompiler.a src/compiler/nir/libnir.a src/compiler/spirv/libvtn.a
    src/util/blake3/libblake3.a src/util/libmesa_util.a src/util/libmesa_util_clflush.a
    src/util/libmesa_util_clflushopt.a src/util/libmesa_util_simd.a src/util/libparson.a
    src/util/libxmlconfig.a src/vulkan/runtime/libvulkan_instance.a
    src/vulkan/runtime/libvulkan_runtime.a src/vulkan/util/libvulkan_util.a
    src/vulkan/wsi/libvulkan_wsi.a)
# RADV derives its pipeline-cache UUID from the binary's build-id note via dladdr, which the PS4
# lacks ("cannot generate UUID"): give it the Mesa commit instead (stable, so editing
# mesa/winsys/ac_ps4_drm.c doesn't rebuild all of RADV; the disk shader cache is off).
build_id="$(git -C "$MESA" rev-parse HEAD)"
meson configure "$build" -Dradv-build-id="$build_id" >/dev/null
ninja -C "$build" -j"$JOBS" "${@:2}" "${libs[@]}"
echo "mesa done: $build"

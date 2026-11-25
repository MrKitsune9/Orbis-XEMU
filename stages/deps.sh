#!/usr/bin/env bash
# Cross-build the libraries xemu needs into $PS4_SYSROOT (static, for the PS4).
#   ./build.sh deps                     everything not built yet
#   ./build.sh deps glib sdl3           (re)build only these
# Order: venv (meson), overlay (libc additions), zlib, glslang, vulkan (headers), samplerate,
# pixman, glib, sdl3. Each one leaves a stamp in ~/orbis-xemu-work/.stamps/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
need cmake ninja perl python3 git curl
TC="$ORBIS_ROOT/toolchain"
DEPS="$SRC_ROOT/deps"
VENV="$WORK/venv"
CROSS="$WORK/ps4-cross.ini"
mkdir -p "$DEPS" "$BUILD_ROOT"
export PKG_CONFIG_LIBDIR="$PS4_SYSROOT/lib/pkgconfig:$PS4_SYSROOT/libdata/pkgconfig:$PS4_SYSROOT/share/pkgconfig"
unset PKG_CONFIG_PATH

fetch() {   # fetch <url> <dir name>: download and unpack into $DEPS (top folder kept)
    local url="$1" dir="$2"
    [ -d "$DEPS/$dir" ] && return
    local f="$SRC_ROOT/downloads/$(basename "$url")"
    fetch_file "$url" "$f"
    tar -C "$DEPS" -xf "$f"
}

meson_build() {     # meson_build <src> <build name> <meson options...>
    local src="$1" name="$2"; shift 2
    local b="$BUILD_ROOT/$name"
    rm -rf "$b"
    "$VENV/bin/meson" setup "$b" "$src" --cross-file "$CROSS" --prefix "$PS4_SYSROOT" --libdir lib \
        --buildtype release -Ddefault_library=static --wrap-mode=default "$@"
    ninja -C "$b" -j"$JOBS"
    ninja -C "$b" install
}

# cmake_build <name> <source dir> [cmake args...]: configure, build and install into the sysroot
cmake_build() {
    local name="$1" src="$2"; shift 2
    local o="$BUILD_ROOT/deps-$name"
    rm -rf "$o"
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS cmake -G Ninja -S "$src" -B "$o" \
        -DCMAKE_TOOLCHAIN_FILE="$TC/ps4-deps.cmake" -DPS4_TRY_LINK=ON -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PS4_SYSROOT" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$PS4_SYSROOT" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
    ninja -C "$o" -j"$JOBS"
    ninja -C "$o" install
}

# meson (xemu's own copy, from its python/wheels) and the cross file for the PS4
dep_venv() {
    if [ ! -x "$VENV/bin/meson" ]; then
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install -q "$XEMU_SRC/python/wheels/"meson-*.whl packaging
    fi
    bash "$TC/make-meson-cross.sh"
}

# libc overlay additions + libps4compat.a (toolchain/xemu-overlay.sh)
dep_overlay() { bash "$TC/xemu-overlay.sh"; }

# zlib (QEMU requires it): plain C, compiled file by file (recipe verified on hardware by PSChrome)
dep_zlib() {
    fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.xz" "zlib-$ZLIB_VER"
    local s="$DEPS/zlib-$ZLIB_VER" o="$BUILD_ROOT/deps-zlib"
    rm -rf "$o"; mkdir -p "$o"
    for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil; do
        "$TC/bin/ps4-cc" -O2 -march=btver2 -DHAVE_UNISTD_H -DHAVE_STDARG_H -c "$s/$f.c" -o "$o/$f.o"
    done
    rm -f "$PS4_SYSROOT/lib/libz.a"
    "$PS4_AR" rcs "$PS4_SYSROOT/lib/libz.a" "$o"/*.o
    mkdir -p "$PS4_SYSROOT/include" "$PS4_SYSROOT/lib/pkgconfig"
    cp "$s/zlib.h" "$s/zconf.h" "$PS4_SYSROOT/include/"
    cat > "$PS4_SYSROOT/lib/pkgconfig/zlib.pc" <<PC
prefix=$PS4_SYSROOT
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: $ZLIB_VER
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
PC
}

# glslang >= 15 (xemu's Vulkan renderer compiles GLSL at run time)
dep_glslang() {
    fetch_tar "https://github.com/KhronosGroup/glslang/archive/refs/tags/$GLSLANG_VER.tar.gz" "$DEPS/glslang-$GLSLANG_VER"
    cmake_build glslang "$DEPS/glslang-$GLSLANG_VER" -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF \
        -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_SPVREMAPPER=OFF -DGLSLANG_ENABLE_INSTALL=ON \
        -DENABLE_HLSL=OFF -DBUILD_EXTERNAL=OFF
}

# Vulkan headers (the API RADV implements: Mesa's include/vulkan, VK_HEADER_VERSION 335)
dep_vulkan() {
    [ -d "$MESA_SRC/include/vulkan" ] || { echo "Mesa sources missing: run ./build.sh fetch" >&2; return 1; }
    mkdir -p "$PS4_SYSROOT/include"
    cp -r "$MESA_SRC/include/vulkan" "$MESA_SRC/include/vk_video" "$PS4_SYSROOT/include/"
    mkdir -p "$PS4_SYSROOT/lib/pkgconfig"
    local ver
    ver="$(awk '/define VK_HEADER_VERSION /{print $3}' "$PS4_SYSROOT/include/vulkan/vulkan_core.h")"
    # no library: RADV is linked into the eboot (stages/xemu.sh)
    cat > "$PS4_SYSROOT/lib/pkgconfig/vulkan.pc" <<PC
prefix=$PS4_SYSROOT
includedir=\${prefix}/include
Name: vulkan
Description: Vulkan headers (RADV on GNM is linked into the eboot)
Version: 1.4.$ver
Cflags: -I\${includedir}
PC
}

# libsamplerate: PacBrew's PS4 build (plain C, static)
dep_samplerate() {
    local pb="$OPENORBIS/usr"
    [ -f "$pb/lib/libsamplerate.a" ] || { echo "OpenOrbis (PacBrew) has no libsamplerate in $pb/lib" >&2; return 1; }
    mkdir -p "$PS4_SYSROOT/include" "$PS4_SYSROOT/lib/pkgconfig"
    cp "$pb/include/samplerate.h" "$PS4_SYSROOT/include/"
    cp "$pb/lib/libsamplerate.a" "$PS4_SYSROOT/lib/"
    sed -e "s|^prefix=.*|prefix=$PS4_SYSROOT|" "$pb/lib/pkgconfig/samplerate.pc" > "$PS4_SYSROOT/lib/pkgconfig/samplerate.pc"
}

dep_pixman() {
    fetch "https://cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz" "pixman-$PIXMAN_VER"
    meson_build "$DEPS/pixman-$PIXMAN_VER" pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled \
        -Dlibpng=disabled -Dopenmp=disabled -Da64-neon=disabled -Darm-simd=disabled -Dneon=disabled \
        -Dmips-dspr2=disabled -Dloongson-mmi=disabled -Dvmx=disabled -Drvv=disabled
}

dep_glib() {
    fetch "https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER"
    # libffi (gobject) and pcre2 come from glib's wraps; libffi's meson port lists no FreeBSD
    ( cd "$DEPS/glib-$GLIB_VER" && "$VENV/bin/meson" subprojects download libffi pcre2 proxy-libintl )
    sed -i "s/\['darwin', 'ios', 'linux', 'android'\].contains(host_system)/['darwin', 'ios', 'linux', 'android', 'freebsd'].contains(host_system)/" \
        "$DEPS/glib-$GLIB_VER/subprojects/libffi/meson.build"
    meson_build "$DEPS/glib-$GLIB_VER" glib -Dtests=false -Dintrospection=disabled -Dnls=disabled \
        -Dlibmount=disabled -Dselinux=disabled -Dxattr=false -Dman-pages=disabled -Ddtrace=disabled \
        -Dsystemtap=disabled -Dsysprof=disabled -Ddocumentation=false -Dbsymbolic_functions=false \
        -Dglib_debug=disabled -Dglib_assert=false -Dglib_checks=false -Dinstalled_tests=false \
        -Dlibelf=disabled -Dfile_monitor_backend=auto -Dpcre2:jit=disabled -Dpcre2:grep=false -Dpcre2:test=false
}

# SDL3 (xemu's audio streams, gamepads, events): a console build (no video: the PS4 frontend
# presents through Vulkan) with the PS4 audio driver (sceAudioOut) from patches/sdl3-ps4.patch
dep_sdl3() {
    local src="$DEPS/SDL3"
    if [ ! -d "$src" ]; then
        git clone -q https://github.com/libsdl-org/SDL "$src"
        git -C "$src" checkout -q "$SDL3_REV"
        git -C "$src" checkout -q -b ps4
    fi
    # idempotent: skipped when the patch is already in the tree
    if [ -s "$ORBIS_ROOT/patches/sdl3-ps4.patch" ] && git -C "$src" apply --check "$ORBIS_ROOT/patches/sdl3-ps4.patch" 2>/dev/null; then
        git -C "$src" apply "$ORBIS_ROOT/patches/sdl3-ps4.patch"
    fi
    local b="$BUILD_ROOT/sdl3"
    rm -rf "$b"
    cmake -S "$src" -B "$b" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TC/ps4-wrapper.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PS4_SYSROOT" -DCMAKE_INSTALL_LIBDIR=lib \
        -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_VIDEO=OFF -DSDL_RENDER=OFF -DSDL_GPU=OFF -DSDL_CAMERA=OFF \
        -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_SENSOR=OFF -DSDL_POWER=OFF -DSDL_HIDAPI=ON -DSDL_HIDAPI_LIBUSB=OFF -DSDL_HIDAPI_JOYSTICK=OFF \
        -DSDL_VIRTUAL_JOYSTICK=ON -DSDL_DBUS=OFF -DSDL_IBUS=OFF -DSDL_LIBUDEV=OFF -DSDL_DISKAUDIO=OFF -DSDL_PS4AUDIO=ON \
        -DSDL_OSS=OFF -DSDL_ALSA=OFF -DSDL_JACK=OFF -DSDL_PIPEWIRE=OFF -DSDL_PULSEAUDIO=OFF \
        -DSDL_SNDIO=OFF -DSDL_LIBICONV=OFF -DSDL_USB=OFF -DSDL_LIBURING=OFF -DSDL_RPATH=OFF
    ninja -C "$b" -j"$JOBS"
    ninja -C "$b" install
}

ORDER=(venv overlay zlib glslang vulkan samplerate pixman glib sdl3)
run_dep() {
    local d="$1" log="$LOG_DIR/dep-$1.log"
    echo "== $d  (log: $log)"
    if ! "dep_$d" > "$log" 2>&1; then
        echo "FAILED: $d - last lines of $log:"; tail -30 "$log"; exit 1
    fi
    touch "$STAMPS/dep-$d"
}
if [ $# -eq 0 ] || [ "$1" = all ]; then
    for d in "${ORDER[@]}"; do
        if [ -f "$STAMPS/dep-$d" ]; then echo "== $d  (already done)"; continue; fi
        run_dep "$d"
    done
else
    for d in "$@"; do
        declare -F "dep_$d" >/dev/null || { echo "unknown dependency: $d (one of: ${ORDER[*]})" >&2; exit 1; }
        run_dep "$d"
    done
fi
echo "deps done"

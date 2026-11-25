#!/usr/bin/env bash
# xemu itself: configure (QEMU's configure + meson, i386-softmmu only), build, and turn the ELF
# into eboot.bin (fake SELF) with the OELF checks.
#   ./build.sh xemu                 configure the first time, then an incremental build
#   ./build.sh xemu reconfigure     run configure again (after changing CMake/meson files)
#   ./build.sh xemu clean           throw the build directory away and start over
#   ./build.sh xemu -k 0 ...        any other arguments go to ninja
# Result: ~/orbis-xemu-work/build/xemu/eboot/eboot.bin. Logs: ~/orbis-xemu-work/logs/xemu-*.log
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
need "$PS4_CC" "$PS4_CXX" ninja python3 gcc pkg-config
SRC="$XEMU_SRC"
B="$BUILD_ROOT/xemu"
MESA="$BUILD_ROOT/mesa"
BIN="$PS4_TOOLCHAIN_BIN"

[ -d "$SRC/.git" ] || { echo "xemu sources missing: run ./build.sh fetch" >&2; exit 1; }
[ -f "$PS4_SYSROOT/lib/libz.a" ] && [ -f "$PS4_SYSROOT/lib/pkgconfig/glib-2.0.pc" ] || { echo "sysroot libraries missing: run ./build.sh deps" >&2; exit 1; }
[ -f "$MESA/src/amd/vulkan/libvulkan_radeon.a" ] || { echo "RADV missing: run ./build.sh mesa" >&2; exit 1; }

configure_xemu() {
    mkdir -p "$B"
    cd "$B"
    export PKG_CONFIG=pkg-config
    export PKG_CONFIG_LIBDIR="$PS4_SYSROOT/lib/pkgconfig:$PS4_SYSROOT/libdata/pkgconfig:$PS4_SYSROOT/share/pkgconfig"
    unset PKG_CONFIG_PATH
    export AR="$PS4_AR" RANLIB="$PS4_RANLIB" NM="llvm-nm-$CLANG_VER" STRIP="llvm-strip-$CLANG_VER" \
           OBJCOPY="llvm-objcopy-$CLANG_VER" READELF="llvm-readelf-$CLANG_VER" LD="$PS4_LD"

    mkdir -p "$B"
    cd "$B"
    "$SRC/configure" \
        --cross-prefix=x86_64-ps4- --cc="$BIN/ps4-cc" --cxx="$BIN/ps4-c++" --host-cc=gcc \
        --target-list=i386-softmmu \
        --extra-cflags="-DXBOX=1 -DSOL_IP=0 -march=btver2 -Wno-error=redundant-decls" \
        --disable-werror --disable-docs --disable-tools --disable-guest-agent --disable-rust \
        --disable-plugins --disable-curl --disable-vnc --disable-gtk --disable-spice --enable-slirp \
        --disable-capstone --disable-keyring --disable-libudev --disable-alsa --disable-oss --disable-pa \
        --disable-pipewire --disable-jack --disable-sndio --disable-tpm --disable-vhost-user \
        --disable-vhost-net --disable-vhost-kernel --disable-vhost-vdpa --disable-linux-aio \
        --disable-linux-io-uring --disable-bpf --disable-seccomp --disable-cap-ng --disable-attr \
        --disable-libssh --disable-libnfs --disable-rbd --disable-glusterfs --disable-libiscsi \
        --disable-zstd --disable-bzip2 --disable-lzo --disable-snappy --disable-lzfse \
        --disable-gnutls --disable-nettle --disable-gcrypt --disable-crypto-afalg --disable-auth-pam \
        --disable-libusb --disable-usb-redir --disable-smartcard --disable-u2f --disable-virglrenderer \
        --disable-opengl --disable-png --disable-vte --disable-xkbcommon --disable-dbus-display \
        --disable-multiprocess --disable-qom-cast-debug \
        --with-coroutine=sigaltstack --audio-drv-list=sdl \
        "$@"

}

build_xemu() {
    # the PS4 runtime from port/ (heap, crash log, sampler; crt1.o routing all mallocs to the heap)
    bash "$ORBIS_ROOT/toolchain/build-port.sh" >/dev/null

    # The program's final link, through toolchain/bin/ps4-c++ (as Resonance's ps4-love-style.cmake):
    #   - RADV on GNM, whole archives (Mesa's dispatch tables reach entry points through weak symbols)
    #   - the system libraries the frontend calls
    #   - malloc family to the port heap; large mmaps (TCG's code buffer) from the system flexible
    #     pool; the TSC clock; threads on all cores; host names through the PS4 resolver
    mesa_libs=(
        src/amd/vulkan/libvulkan_radeon.a src/amd/common/libamd_common.a
        src/amd/compiler/libaco.a src/amd/addrlib/libaddrlib.a src/vulkan/util/libvulkan_util.a
        src/compiler/spirv/libvtn.a src/compiler/nir/libnir.a src/compiler/libcompiler.a
        src/util/libxmlconfig.a src/util/libmesa_util.a src/util/libmesa_util_simd.a
        src/util/libmesa_util_clflush.a src/util/libmesa_util_clflushopt.a src/util/libparson.a
        src/util/blake3/libblake3.a src/c11/impl/libmesa_util_c11.a)
    ld=("$PSB/build/port/libxemups4_port.a" -Wl,--whole-archive)
    for l in "${mesa_libs[@]}"; do ld+=("$MESA/$l"); done
    ld+=(-Wl,--no-whole-archive
        -lSceSysmodule -lSceSystemService -lSceUserService -lSceVideoOut -lSceAudioOut -lScePad
        -lSceNet -lSceCommonDialog -lSceImeDialog)
    for fn in malloc free calloc realloc memalign __memalign pthread_once mmap clock_gettime \
              pthread_create getaddrinfo gethostbyname; do
        ld+=("-Wl,--wrap=$fn")
    done
    export PS4_APP_LDFLAGS="${ld[*]}"
    export PS4_CRT1="$PSB/build/port/crt1.o"
    export PS4_RT_LIB=
    # the ENOSYS stubs toolchain/trim-libc.py took out of libc.a, for what still calls them
    export PS4_APP_LDFLAGS_END="$PS4_SYSROOT/lib/libc_enosys.a"

    ninja -C "$B" -j"$JOBS" "$@" qemu-system-i386

    # ELF -> fake SELF. Program authority ID: the plain homebrew identity, under which RADV gets the
    # 4.5 GiB of direct memory (as Resonance); auth info as love-ps4/Resonance.
    PAID="${PS4_PAID:-0x3800000000000035}"
    AUTHINFO="000000000000000000000000001C004000FF000000000080000000000000000000000000000000000000008000400040000000000000008000000000000000080040FFFF000000F000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    mkdir -p "$B/eboot"
    OO_PS4_TOOLCHAIN="$OPENORBIS" "$OPENORBIS/bin/create-fself" -in="$B/qemu-system-i386" \
        -out="$B/eboot/xemu.oelf" --eboot "$B/eboot/eboot.bin" --paid "$PAID" --authinfo "$AUTHINFO"
    cmake -DOELF="$B/eboot/xemu.oelf" -P "$ORBIS_ROOT/toolchain/check-oelf.cmake"
    python3 "$ORBIS_ROOT/toolchain/check-oelf-data.py" "$B/eboot/xemu.oelf"
    ls -la "$B/eboot/eboot.bin"

}

if [ "${1:-}" = clean ]; then rm -rf "$B"; shift; fi
if [ "${1:-}" = reconfigure ]; then rm -f "$B/build.ninja"; shift; fi

# run a function as its own "set -e" step, keeping its output in a log
run_logged() {   # run_logged <log> <function> [args...]
    local log="$1"; shift
    set +e
    ( set -e; "$@" ) > "$log" 2>&1
    local rc=$?
    set -e
    return $rc
}

if [ ! -f "$B/build.ninja" ]; then
    echo "== configure (log: $LOG_DIR/xemu-configure.log)"
    run_logged "$LOG_DIR/xemu-configure.log" configure_xemu || { tail -30 "$LOG_DIR/xemu-configure.log"; exit 1; }
fi
echo "== build (log: $LOG_DIR/xemu-build.log)"
if ! run_logged "$LOG_DIR/xemu-build.log" build_xemu "$@"; then
    echo "build failed. Errors:"
    grep "error:" "$LOG_DIR/xemu-build.log" | sed 's/.*src\/xemu\///' | sort | uniq -c | sort -rn | head -40
    tail -15 "$LOG_DIR/xemu-build.log"
    exit 1
fi
tail -3 "$LOG_DIR/xemu-build.log"
echo "xemu done: $B/eboot/eboot.bin"

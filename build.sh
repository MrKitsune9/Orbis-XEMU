#!/usr/bin/env bash
# Orbis XEMU - the only script you need to run.
#
#   ./build.sh doctor         confere o WSL e diz o que falta instalar
#   ./build.sh all [00.16]    faz tudo, na ordem, ate o .pkg (pula o que ja esta pronto)
#   ./build.sh status         mostra o que ja foi feito
#
# Etapas (cada uma pode ser rodada sozinha; as marcadas [1x] so rodam uma vez no "all"):
#   fetch      [1x]  baixa xemu, Mesa e libdrm e aplica os patches deste repositorio
#   toolchain  [1x]  libc++ 21 + sysroot do PS4                          (~30 min)
#   mesa       [1x]  RADV (Vulkan) para a GPU do PS4                     (~1 h)
#   deps       [1x]  zlib, glslang, pixman, glib, SDL3 (com o audio)     (~30 min)
#   xemu             configura e compila o xemu, gera o eboot.bin        (~30 min, depois incremental)
#   pkg [00.16]      empacota out/xemu-ps4-vXX.YY.pkg
#
# Tudo que e gerado fica em ~/orbis-xemu-work (ORBIS_WORK muda o lugar). Logs em ~/orbis-xemu-work/logs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"

ORDER=(doctor fetch toolchain mesa deps xemu pkg)
ONCE=(fetch toolchain mesa deps)
script_of() {
    case "$1" in
        doctor) echo doctor.sh;; fetch) echo fetch.sh;; toolchain) echo toolchain.sh;;
        mesa) echo mesa.sh;; deps) echo deps.sh;; xemu) echo xemu.sh;; pkg) echo package.sh;;
        *) return 1;;
    esac
}
is_once() { local s; for s in "${ONCE[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

run_stage() {   # run_stage <stage> [args...]
    local name="$1"; shift
    local script log="$LOG_DIR/$name.log"
    script="$(script_of "$name")" || { echo "etapa desconhecida: $name" >&2; return 2; }
    echo
    echo "==> $name"
    bash "$ORBIS_ROOT/stages/$script" "$@" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo
        echo "A etapa '$name' falhou (codigo $rc). Log completo: $log"
        return "$rc"
    fi
    is_once "$name" && touch "$STAMPS/$name"
    return 0
}

status() {
    echo "Pasta de trabalho: $WORK"
    local s state
    for s in "${ORDER[@]}"; do
        case "$s" in
            doctor) state="(rode quando quiser)";;
            xemu)   [ -f "$BUILD_ROOT/xemu/eboot/eboot.bin" ] && state="eboot.bin pronto" || state="pendente";;
            pkg)    ls "$ORBIS_ROOT"/out/*.pkg >/dev/null 2>&1 && state="$(basename "$(ls -t "$ORBIS_ROOT"/out/*.pkg | head -1)")" || state="pendente";;
            *)      [ -f "$STAMPS/$s" ] && state="feito" || state="pendente";;
        esac
        printf '  %-10s %s\n' "$s" "$state"
    done
}

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
    help|-h|--help) usage; echo; status;;
    status)         status;;
    all)
        [ "${1:-}" ] && export XEMU_VERSION="$1"
        for s in "${ORDER[@]}"; do
            if is_once "$s" && [ -f "$STAMPS/$s" ]; then
                echo; echo "==> $s: ja feito (./build.sh $s para refazer)"; continue
            fi
            run_stage "$s" || exit $?
        done
        echo; echo "Pronto!"; status;;
    pkg)
        if [[ "${1:-}" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then export XEMU_VERSION="$1"; shift; fi
        run_stage pkg "$@";;
    *)
        if script_of "$cmd" >/dev/null; then run_stage "$cmd" "$@"; else
            echo "comando desconhecido: $cmd" >&2; echo >&2; usage >&2; exit 2
        fi;;
esac

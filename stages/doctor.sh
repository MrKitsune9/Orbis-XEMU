#!/usr/bin/env bash
# Checks the build machine (WSL Ubuntu) and says exactly what is missing. Fixes the two things a
# Windows unzip breaks (script permissions and CRLF line endings) on its own.
#   ./build.sh doctor
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"

bad=0; warn=0
ok()   { printf '  [ok]   %s\n' "$1"; }
fail() { printf '  [FALTA] %s\n         -> %s\n' "$1" "$2"; bad=$((bad+1)); }
note() { printf '  [aviso] %s\n' "$1"; warn=$((warn+1)); }

echo "== 1. Arquivos do repositorio (permissoes e fim de linha)"
fixed=0
while IFS= read -r f; do
    if grep -q $'\r' "$f" 2>/dev/null; then sed -i 's/\r$//' "$f"; fixed=$((fixed+1)); fi
done < <(find "$ORBIS_ROOT_REAL" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.cmake' -o -path '*/toolchain/bin/*' \) -not -path '*/.git/*')
find "$ORBIS_ROOT_REAL" -type f \( -name '*.sh' -o -path '*/toolchain/bin/*' \) -not -path '*/.git/*' -exec chmod +x {} +
ok "scripts executaveis (corrigidos fim de linha em $fixed arquivo(s))"

echo "== 2. Ferramentas do Linux (apt)"
apt_missing=()
for c in git curl perl python3 cmake ninja pkg-config gcc g++ make tar xz unzip zip; do
    command -v "$c" >/dev/null 2>&1 || apt_missing+=("$c")
done
python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || apt_missing+=(python3-venv)
if [ ${#apt_missing[@]} -eq 0 ]; then ok "git curl perl python3 cmake ninja pkg-config gcc make tar xz unzip zip venv"
else fail "faltam: ${apt_missing[*]}" "sudo apt install -y git curl perl python3 python3-venv python3-pip cmake ninja-build pkg-config build-essential xz-utils unzip zip"; fi
command -v glslangValidator >/dev/null 2>&1 && ok "glslangValidator" || fail "glslangValidator (o Mesa precisa)" "sudo apt install -y glslang-tools"
python3 -c 'import PIL' >/dev/null 2>&1 && ok "python3 Pillow (so para refazer os icones)" || note "Pillow ausente: so e preciso para package/make-art.py (sudo apt install python3-pil)"

echo "== 3. clang / LLVM $CLANG_VER"
llvm_missing=()
for c in clang-$CLANG_VER clang++-$CLANG_VER ld.lld-$CLANG_VER llvm-ar-$CLANG_VER llvm-ranlib-$CLANG_VER llvm-nm-$CLANG_VER \
         llvm-strip-$CLANG_VER llvm-objcopy-$CLANG_VER llvm-readelf-$CLANG_VER llvm-symbolizer-$CLANG_VER; do
    command -v "$c" >/dev/null 2>&1 || llvm_missing+=("$c")
done
if [ ${#llvm_missing[@]} -eq 0 ]; then ok "clang-$CLANG_VER, lld, llvm-*"
else fail "faltam: ${llvm_missing[*]}" "wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && sudo ./llvm.sh $CLANG_VER && sudo apt install -y lld-$CLANG_VER llvm-$CLANG_VER"; fi

echo "== 4. OpenOrbis (PacBrew) em $OPENORBIS"
oo_missing=()
for f in ps4vars.sh link.x cmake/ps4.cmake lib/libc.a lib/crt1.o bin/create-fself \
         bin/linux/PkgTool.Core bin/linux/create-gp4 samples/piglet/sce_module; do
    [ -e "$OPENORBIS/$f" ] || oo_missing+=("$f")
done
if [ ${#oo_missing[@]} -eq 0 ]; then ok "toolchain, create-fself, PkgTool, modulos do piglet"
else fail "faltam em $OPENORBIS: ${oo_missing[*]}" "instale o OpenOrbis do PacBrew em /opt/pacbrew/ps4/openorbis (ou exporte OPENORBIS=/caminho)"; fi
[ -f "$OPENORBIS/usr/lib/libsamplerate.a" ] && ok "libsamplerate (PacBrew)" || fail "libsamplerate.a em $OPENORBIS/usr/lib" "instale o pacote libsamplerate do PacBrew (ps4-openorbis)"

echo "== 5. Onde as coisas estao"
case "$WORK" in /mnt/*) fail "a pasta de trabalho ($WORK) esta no disco do Windows" "export ORBIS_WORK=\$HOME/orbis-xemu-work  (o disco do WSL e muito mais rapido e nao quebra links)";; *) ok "pasta de trabalho: $WORK";; esac
case "$ORBIS_ROOT_REAL" in /mnt/*) note "o repositorio esta em $ORBIS_ROOT_REAL (disco do Windows): funciona, mas e mais lento; o ideal e ~/orbis-xemu";; *) ok "repositorio: $ORBIS_ROOT_REAL";; esac
free_gb=$(df -Pk "$WORK" | awk 'NR==2{printf "%d", $4/1048576}')
[ "${free_gb:-0}" -ge 40 ] && ok "espaco livre: ${free_gb} GB" || note "so ${free_gb} GB livres (o build completo usa uns 30-40 GB)"
mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
[ "${mem_gb:-0}" -ge 8 ] && ok "memoria: ${mem_gb} GB" || note "so ${mem_gb} GB de RAM: compilar Mesa/LLVM pode falhar; use JOBS=4 (ou menos)"
curl -sSI -m 15 -o /dev/null https://github.com && ok "internet (github.com)" || fail "sem acesso a github.com" "o build baixa o xemu, Mesa, SDL3, LLVM..."

echo
if [ $bad -eq 0 ]; then echo "doctor: tudo certo ($warn aviso(s))."; else echo "doctor: $bad problema(s) a resolver acima."; exit 1; fi

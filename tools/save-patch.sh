#!/usr/bin/env bash
# Commit the work in ~/orbis-xemu-work/src/xemu (branch ps4) and export it as
# patches/xemu-ps4.patch against the upstream base recorded in patches/BASE.txt.
#   save-patch.sh "commit message"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config.sh"
SRC="$XEMU_SRC"
BASE="$XEMU_BASE"
git -C "$SRC" add -A
git -C "$SRC" diff --cached --quiet || git -C "$SRC" -c user.name=orbis-xemu -c user.email=orbis-xemu@localhost commit -q -m "${1:-PS4 port work}"
git -C "$SRC" diff "$BASE" HEAD > "$HERE/../patches/xemu-ps4.patch"
echo "patches/xemu-ps4.patch: $(grep -c '^diff --git' "$HERE/../patches/xemu-ps4.patch") files"

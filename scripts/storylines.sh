#!/bin/zsh
# Runs user storylines in Kore (phase 12): builds `kore-storylines` (Kore with the storyline
# host inside), then plays the chosen storylines and prints the report. Exits 0 when every one
# passed.
#
#   scripts/storylines.sh [--build debug|release] [--tag a,b] [--name A,B] [--provider claude|codex]
#                         [--size WxH] [--replay 'name|folder|agent:id;…'] [--out <dir>] [--list]
#                         [--real-input [--real-keys]]
#
# Each run gets a folder of its own ($TMPDIR/kore-storylines/<time>, or --out) for its scratch
# folders, report.json / report.txt, event logs, dumps and failure snapshots. The app's settings
# live in the `kore-storylines` defaults domain, emptied first, so the owner's Kore settings are
# never read or written. Codex gets its own CODEX_HOME under the run folder, except with
# --replay, whose recorded sessions are read where they were made.
#
# --real-input sends pointer events through the window server (the real cursor moves), and
# --real-keys real keystrokes too: only after the owner has OK'd that run in chat.
set -u
cd "$(dirname "$0")/.." || exit 2
build=debug
out=""
replay=0
args=()
while (( $# )); do
  case $1 in
    --build) build=$2; shift ;;
    --out) out=$2; shift ;;
    --replay) replay=1; args+=("$1" "$2"); shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
if ! swift build -c $build --product kore-storylines >/tmp/kore-storylines-build.$$ 2>&1; then
  grep -E 'error:' /tmp/kore-storylines-build.$$ | head -20
  rm -f /tmp/kore-storylines-build.$$
  exit 2
fi
rm -f /tmp/kore-storylines-build.$$
bin="$(swift build -c $build --show-bin-path)/kore-storylines"
[[ -n $out ]] || out="${TMPDIR:-/tmp}/kore-storylines/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
defaults delete kore-storylines >/dev/null 2>&1
if (( ! replay )); then
  mkdir -p "$out/codex-home"
  export CODEX_HOME="$out/codex-home"
fi
"$bin" "${args[@]}" --out "$out" 2>"$out/stderr.log"

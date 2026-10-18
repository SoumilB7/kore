#!/bin/zsh
# Runs user storylines in Kore (phase 12): builds `kore-storylines` (Kore with the storyline
# host inside), then plays the chosen storylines and prints the report. Exits 0 when every one
# passed.
#
#   scripts/storylines.sh [--build debug|release] [--tag a,b] [--name A,B] [--provider claude|codex]
#                         [--cli scripted|process] [--live haiku|gpt-6-luna [--record]]
#                         [--size WxH] [--replay 'name|folder|agent:id;…'] [--out <dir>] [--list]
#                         [--real-input | --real-input-dry [--real-keys]]
#
# Each run gets a folder of its own ($TMPDIR/kore-storylines/<time>, or --out) for its scratch
# folders, report.json / report.txt, event logs, dumps and failure snapshots. The app's settings
# live in the `kore-storylines` defaults domain, emptied first, so the owner's Kore settings are
# never read or written. Chats talk to the scripted CLI unless --cli process (recorded cassettes,
# played by kore-fake-cli) or --live <model> says otherwise; the run's Claude store and Codex home
# are kept in its folder. The --replay sessions are read where they were made.
#
# --real-input sends pointer events through the window server (the real cursor moves), and
# --real-keys real keystrokes too: only after the owner has OK'd that run in chat.
# --real-input-dry plays the same storylines with everything real input does around its events
# (the banner and its countdown, Kore brought forward, the front given back) but posts nothing:
# the cursor stays put, and a step that needs the real pointer's effect fails.
set -u
cd "$(dirname "$0")/.." || exit 2
build=debug
out=""
process=0
replay=0
args=()
while (( $# )); do
  case $1 in
    --build) build=$2; shift ;;
    --out) out=$2; shift ;;
    --cli) [[ $2 == process ]] && process=1; args+=("$1" "$2"); shift ;;
    --replay) replay=1; args+=("$1" "$2"); shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
products=(kore-storylines)
(( process )) && products+=(kore-fake-cli)
for product in $products; do
  if ! swift build -c $build --product $product >/tmp/kore-storylines-build.$$ 2>&1; then
    grep -E 'error:' /tmp/kore-storylines-build.$$ | head -20
    rm -f /tmp/kore-storylines-build.$$
    exit 2
  fi
done
rm -f /tmp/kore-storylines-build.$$
bins="$(swift build -c $build --show-bin-path)"
(( process )) && args+=(--fake-cli "$bins/kore-fake-cli")
[[ -n $out ]] || out="${TMPDIR:-/tmp}/kore-storylines/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
defaults delete kore-storylines >/dev/null 2>&1
# Recorded Codex threads take one writer at a time: replays wait for any other run's (the lock
# verify-landing takes too). A caller that already holds it says so with KORE_REPLAY_LOCK_HELD.
lock=/private/tmp/kore-verify-replay.lock
if (( replay )) && [[ -z ${KORE_REPLAY_LOCK_HELD:-} ]]; then
  until mkdir $lock 2>/dev/null; do sleep 2; done
  trap "rmdir $lock 2>/dev/null" EXIT
fi
"$bins/kore-storylines" "${args[@]}" --cassettes "$PWD/Tests/Fixtures/cassettes" --out "$out" 2>"$out/stderr.log"

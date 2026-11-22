#!/bin/zsh
# A copy of KoreDev/tools/one-build.sh (the one every build runs, untracked): kept here so its
# changes land with the gate that relies on them.
# Build slots: KORE_BUILD_SLOTS (default 2 until the first mybox window works; owner OK 2026-11-10), then back to 1.
# A dev job: it runs as its own to macOS, so its energy is never charged to the Kore whose chat
# started it (scripts/devrun, docs/dev-builds.md).
[[ -n ${KORE_DEVRUN_JOB-} || ! -x ${0:A:h}/devrun ]] || exec ${0:A:h}/devrun --name one-build -- /bin/zsh "$0" "$@"
slots=${KORE_BUILD_SLOTS:-2}
while :; do
  for i in $(seq 1 $slots); do
    lock=/tmp/kore-one-build.lock; (( i > 1 )) && lock=/tmp/kore-one-build.lock$i
    if mkdir $lock 2>/dev/null; then break 2; fi
    [[ -f $lock/pid ]] && ! kill -0 $(cat $lock/pid) 2>/dev/null && rm -rf $lock
  done
  sleep 15
done
print $$ > $lock/pid
# The Mac stays awake while the slot is held (an idle sleep froze a check mid-run); the display may
# sleep. The hold ("Kore Dev: one-build" in pmset -g assertions) is this holder's: it ends by itself
# when the holder ends.
if [[ -x ${0:A:h}/devrun ]]; then ${0:A:h}/devrun --hold one-build $$ &!; else caffeinate -i -w $$ &!; fi
trap "rm -rf $lock" EXIT INT TERM
"$@"

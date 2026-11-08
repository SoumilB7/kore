#!/bin/zsh
# A copy of KoreDev/tools/one-build.sh (the one every build runs, untracked): kept here so its
# changes land with the gate that relies on them.
# Build slots: KORE_BUILD_SLOTS (default 2 until the first mybox window works; owner OK 2026-11-10), then back to 1.
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
# sleep. The hold is this holder's: it ends by itself when the holder ends.
caffeinate -i -w $$ &!
trap "rm -rf $lock" EXIT INT TERM
"$@"

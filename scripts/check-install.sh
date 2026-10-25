#!/bin/zsh
# Is /Applications/Kore.app the build of <sha>, and is the Kore running that copy?
# Reads only. Prints PASS or FAIL with why; exits 0 on PASS.
#
#   scripts/check-install.sh <expected-sha>
set -u
want=${1:?usage: check-install.sh <expected-sha>}
app=/Applications/Kore.app
have=$(/usr/libexec/PlistBuddy -c 'Print :KoreBuild' "$app/Contents/Info.plist" 2>/dev/null || echo none)
fail=()
[[ $have == ${want[1,7]}* || $want == ${have}* ]] || fail+=("installed build $have, wanted $want")
pids=($(ps -axo pid=,comm= | awk '$NF ~ /\/Kore$/ {print $1}'))
(( ${#pids} )) || fail+=("Kore isn't running")
for pid in $pids; do
  exe=$(ps -o comm= -p $pid)
  [[ $exe == $app/Contents/MacOS/Kore ]] || fail+=("pid $pid runs $exe")
  # A copy replaced since it started runs the old binary: its start must follow the install.
  [[ $(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p $pid | xargs)" +%s) -ge $(stat -f %m "$app/Contents/MacOS/Kore") ]] || fail+=("pid $pid started before the install")
done
if (( ${#fail} )); then print -l "FAIL" "  "${^fail}; exit 1; fi
echo "PASS $app is $have, running pid ${pids[*]}"

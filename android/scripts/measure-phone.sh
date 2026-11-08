#!/bin/zsh
# Kore's phone app, measured over adb in one go: what it costs to run, not its size.
#   measure-phone.sh [--long] [--pkg dev.kore.android]
#
# Phases (each prints one block; everything also lands in a dated folder under
# ~/Library/Application Support/KoreDev/scratch/measure/<time>/):
#   1. cold start x5         am force-stop, then am start -W of the launcher: TotalTime, median
#   2. on screen, idle 60 s  PSS / Java / native heap, CPU% (from /proc/<pid>/stat), threads by name,
#                            frames drawn while nothing changes (gfxinfo), wakelocks, alarms, jobs
#   3. backgrounded 60 s     the same, after the owner leaves the app (the script waits for Enter;
#                            it never injects input on the phone)
#   4. --long: 30 min on screen with the battery's charging hidden from Android
#      (dumpsys battery unplug) and batterystats reset: per-app CPU, wakeups, network bytes,
#      estimated mAh. The screen stays on by the "stay on while plugged in" setting, which is put
#      back afterwards, as is the battery state.
# The Mac side: Kore's own CPU time across each phase (ps), so per-phase Mac cost is beside the phone's.
# Needs: the phone on USB with debugging allowed, Kore's phone app installed and joined.
set -u
pkg=dev.kore.android
long=0
while (( $# )); do case $1 in --long) long=1;; --pkg) pkg=$2; shift;; *) print "usage: measure-phone.sh [--long] [--pkg id]"; exit 2;; esac; shift; done
adb=${ADB:-$(command -v adb || print "$HOME/Library/Android/sdk/platform-tools/adb")}
out="$HOME/Library/Application Support/KoreDev/scratch/measure/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
say() { print -r -- "$*" | tee -a "$out/summary.txt"; }
sh() { "$adb" shell "$@" 2>/dev/null | tr -d '\r'; }

[[ $("$adb" get-state 2>/dev/null) == device ]] || { print "no phone on adb (plug it in, allow USB debugging)"; exit 2; }
sh pm path $pkg | grep -q package: || { print "$pkg isn't installed"; exit 2; }
launcher=$(sh cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg | tail -1)
hz=$(sh getconf CLK_TCK); hz=${hz:-100}
say "phone: $(sh getprop ro.product.model) · Android $(sh getprop ro.build.version.release) · $pkg $(sh dumpsys package $pkg | grep -m1 versionName | cut -d= -f2)"
say "launcher: $launcher · out: $out"

pid() { sh pidof $pkg | awk '{print $1}'; }
ticks() { sh cat /proc/$1/stat | awk '{print $14 + $15}'; }
macKore() { local p; p=$(pgrep -x Kore | head -1); [[ -n $p ]] && ps -o cputime= -p $p | awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else print $1*60+$2+$3/100 }' || print 0; }

# One phase: CPU% over $2 s, memory, threads, frames, wakelocks/alarms/jobs.
measure() {
    local name=$1 secs=$2 p t0 t1 m0 m1
    p=$(pid)
    [[ -z $p ]] && { say "[$name] process not running (good when backgrounded long enough)"; return; }
    sh dumpsys gfxinfo $pkg reset >/dev/null
    t0=$(ticks $p); m0=$(macKore)
    sleep $secs
    p2=$(pid)
    if [[ $p2 != $p ]]; then say "[$name] process ended during the phase"; return; fi
    t1=$(ticks $p); m1=$(macKore)
    sh dumpsys meminfo $pkg > "$out/$name-meminfo.txt"
    local pss java native
    pss=$(awk '/TOTAL PSS:/ {print $3; exit} /^ *TOTAL / {print $2; exit}' "$out/$name-meminfo.txt")
    java=$(awk '/Java Heap:/ {print $3; exit}' "$out/$name-meminfo.txt")
    native=$(awk '/Native Heap:/ {print $3; exit}' "$out/$name-meminfo.txt")
    sh "cat /proc/$p/task/*/comm" | sed -E 's/[0-9]+$//' | sort | uniq -c | sort -rn > "$out/$name-threads.txt"
    local threads=$(awk '{s+=$1} END {print s}' "$out/$name-threads.txt")
    sh dumpsys gfxinfo $pkg > "$out/$name-gfx.txt"
    local frames=$(awk -F': ' '/Total frames rendered/ {print $2; exit}' "$out/$name-gfx.txt")
    sh dumpsys power | grep -i "$pkg" > "$out/$name-wakelocks.txt"
    sh dumpsys alarm | grep -i "$pkg" > "$out/$name-alarms.txt"
    sh dumpsys jobscheduler | grep -i "$pkg" > "$out/$name-jobs.txt"
    say "[$name] ${secs}s: CPU $(awk -v d=$((t1 - t0)) -v hz=$hz -v s=$secs 'BEGIN {printf "%.2f", 100*d/hz/s}')% · PSS ${pss:-?} KB (Java ${java:-?}, native ${native:-?}) · threads $threads · frames drawn $frames · wakelocks $(wc -l < "$out/$name-wakelocks.txt" | tr -d ' ') · alarms $(wc -l < "$out/$name-alarms.txt" | tr -d ' ') · jobs $(wc -l < "$out/$name-jobs.txt" | tr -d ' ') · Mac Kore CPU $(awk -v a=$m0 -v b=$m1 'BEGIN {printf "%.2f", b-a}')s"
    say "    busiest threads: $(head -6 "$out/$name-threads.txt" | awk '{printf "%s×%s ", $2, $1}')"
}

# 1. Cold start.
say "--- 1. cold start (5 runs)"
starts=()
for i in {1..5}; do
    sh am force-stop $pkg; sleep 2
    t=$(sh am start -W -n $launcher | awk -F': ' '/TotalTime/ {print $2}')
    starts+=($t); say "    run $i: ${t} ms"; sleep 3
done
say "cold start median: $(print -l $starts | sort -n | sed -n 3p) ms"

# 2. On screen, idle.
say "--- 2. on screen, idle: leave Kore on its Home screen, touch nothing"
sleep 15   # the tailnet and links come up first
measure on-screen 60

# 3. Backgrounded.
print "Leave Kore now (Home button or another app), then press Enter here."; read -r _
sleep 10   # the app's own grace (5 s) and the bye window
measure background 60

# 4. 30 min on screen, battery.
if (( long )); then
    print "Open Kore again on its Home screen, then press Enter. The next 30 min need it on screen."; read -r _
    stay=$(sh settings get global stay_on_while_plugged_in)
    sh settings put global stay_on_while_plugged_in 7
    sh dumpsys batterystats --reset >/dev/null
    sh dumpsys battery unplug
    m0=$(macKore)
    say "--- 4. 30 min on screen (started $(date +%H:%M))"
    sleep 1800
    m1=$(macKore)
    sh dumpsys batterystats $pkg > "$out/batterystats.txt"
    sh dumpsys battery reset
    sh settings put global stay_on_while_plugged_in ${stay:-0}
    uid=$(sh dumpsys package $pkg | awk -F'[= ]' '/userId=/ {print $NF; exit}')
    say "    estimated power: $(grep -iE "Uid u0a${uid#10}|uid $uid" "$out/batterystats.txt" | grep -m1 -oE '[0-9.]+ ?mAh' || print '? (see batterystats.txt)')"
    say "    CPU: $(grep -m1 -E 'Total cpu time' "$out/batterystats.txt" | sed 's/^ *//')"
    say "    network: $(grep -m1 -E 'Network:' "$out/batterystats.txt" | sed 's/^ *//')"
    say "    wakeups: $(grep -m1 -iE 'wakeup alarm|Wakeup alarm' "$out/batterystats.txt" | sed 's/^ *//')"
    say "    Mac Kore CPU over 30 min: $(awk -v a=$m0 -v b=$m1 'BEGIN {printf "%.1f", b-a}')s"
fi
say "--- done: $out/summary.txt"

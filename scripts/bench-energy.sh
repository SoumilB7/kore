#!/bin/zsh
# The energy bench: what Kore's own process (and its helpers: git, shells) spends in each
# normal state, played by the storyline harness with the scripted CLI (no CLI process, no model).
#
#   scripts/bench-energy.sh [--runs 3] [--seconds 60] [--scenarios a,b,…] [--out <dir>]
#                           [--sample] [--check] [--force] [--wait <minutes>] [--no-build]
#
# Scenarios (Sources/KoreStorylines/Catalogue/EnergyStorylines.swift), each a fresh process:
#   EnergyIdleFront      1 window, 3 chats with history, idle, window in front
#   EnergyIdleHidden     the same, window covered (occluded)
#   EnergyStreamOne      1 chat streaming a long markdown answer (~75 tokens/s), shown
#   EnergyStreamThree    3 chats streaming, one shown
#   EnergyLongTranscript 6,000-entry transcript idle, then scrolled
#   EnergyWorking        a background command (">_") + a working turn (live line, spinners),
#                        front then covered
#   EnergyTabBurst       60 tab switches at 4/s, then the 30 s after
#   EnergyAmbient        git repo folder, Devices icon with KoreNet off then on (scripted)
# "Front" is a transparent (1/255), click-through, floating window on the main screen, the app
# run as an accessory app (KORE_ENERGY_FRONT=1: a never-activated regular app's windows get no
# Space, so they stay occluded); Kore is never activated, no key or pointer event is posted.
#
# Readings: proc_pid_rusage (CPU, package-idle and interrupt wakeups, ri_energy_nj, footprint),
# TASK_POWER_INFO_V2 GPU time, children's rusage; the harness's 50 ms poll is off while reading.
# Budgets: idle (front and covered) ≤ 0.2 % of one core and ≤ 2 wakeups/s. --check runs only
# EnergyIdleBudget, which fails over budget (twice running) and prints SKIP on battery or load ≥ 3.
#
# Numbers count only on AC power with 1-minute load < 3: otherwise the bench stops (exit 3),
# --wait polls every 3 minutes up to that long for a quiet window, and --force runs anyway with
# the results marked "not valid". --sample also writes `sample` stacks (those readings cost more).
set -u
cd "$(dirname "$0")/.." || exit 2
runs=3
seconds=60
scenarios=(EnergyIdleFront EnergyIdleHidden EnergyStreamOne EnergyStreamThree EnergyLongTranscript EnergyWorking EnergyTabBurst EnergyAmbient)
out=""
sample=0
check=0
force=0
waitmin=0
build=1
while (( $# )); do
  case $1 in
    --runs) runs=$2; shift ;;
    --seconds) seconds=$2; shift ;;
    --scenarios) scenarios=(${(s:,:)2}); shift ;;
    --out) out=$2; shift ;;
    --sample) sample=1 ;;
    --check) check=1; scenarios=(EnergyIdleBudget); runs=1 ;;
    --force) force=1 ;;
    --wait) waitmin=$2; shift ;;
    --no-build) build=0 ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
  shift
done

quiet() {  # prints why the Mac isn't fit to measure, or nothing
  pmset -g batt | grep -q "AC Power" || { print "not on AC power"; return }
  local load=$(sysctl -n vm.loadavg | awk '{print $2}')
  (( ${load%.*} >= 3 )) && print "1-minute load $load"
}

if (( build )); then
  swift build -c release --product kore-storylines >/tmp/kore-energy-build.$$ 2>&1 || {
    grep -E "error:" /tmp/kore-energy-build.$$ | head -20; rm -f /tmp/kore-energy-build.$$; exit 2; }
  rm -f /tmp/kore-energy-build.$$
fi
bins="$(swift build -c release --show-bin-path)"
# Its own name, so its own defaults domain (never the owner's "Kore").
name=kore-energy-bench
ln -sf kore-storylines "$bins/$name"

why=$(quiet)
if [[ -n $why ]] && (( waitmin > 0 )); then
  deadline=$(( SECONDS + waitmin * 60 ))
  while [[ -n $why ]] && (( SECONDS < deadline )); do
    print "waiting for a quiet Mac: $why"
    sleep 180
    why=$(quiet)
  done
fi
valid=1
if [[ -n $why ]]; then
  if (( check )); then print "SKIP energy budget: $why"; exit 0; fi
  if (( ! force )); then print "preflight failed: $why (--wait <min> to wait, --force to run anyway)"; exit 3; fi
  print "forced: $why; these numbers are not valid results"
  valid=0
fi

[[ -n $out ]] || out="$HOME/Library/Application Support/KoreDev/energy-runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
print "results: $out"
for (( r = 1; r <= runs; r++ )); do
  for s in $scenarios; do
    dir="$out/$s-$r"
    mkdir -p "$dir"
    defaults delete $name >/dev/null 2>&1
    # A hard limit per run: setup, two readings, the window's close.
    env KORE_ENERGY_SECONDS=$seconds KORE_ENERGY_RUN=$r KORE_ENERGY_SAMPLE=$sample \
      perl -e 'alarm shift; exec @ARGV' $(( seconds * 3 + 240 )) \
      "$bins/$name" --name $s --cassettes "$PWD/Tests/Fixtures/cassettes" --out "$dir" >"$dir/stdout.log" 2>"$dir/stderr.log"
    code=$?
    grep -E "^(PASS|FAIL|SKIP)|SKIP:|✗" "$dir/stdout.log" | head -3
    [[ -f "$dir/energy.jsonl" ]] && cat "$dir/energy.jsonl" >>"$out/energy.jsonl"
    (( check )) && { defaults delete $name >/dev/null 2>&1; exit $code; }
  done
done
defaults delete $name >/dev/null 2>&1
[[ -f "$out/energy.jsonl" ]] || { print "no readings"; exit 1; }
python3 - "$out/energy.jsonl" $valid <<'EOF' | tee "$out/summary.md"
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
valid = sys.argv[2] == "1"
order = []
for r in rows:
    if r["scenario"] not in order: order.append(r["scenario"])
def med(rs, k): return statistics.median(r[k] for r in rs)
print(("" if valid else "NOT VALID (battery or load): ") + f"{len(rows)} readings, medians over runs")
print("| scenario | n | CPU % | CPU ms/min | idle wk/s | intr wk/s | energy mW | GPU ms/min | MB | helpers % | visible | load |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--|--:|")
over = []
for s in order:
    rs = [r for r in rows if r["scenario"] == s]
    cpu, wk = med(rs, "cpu_percent"), max(med(rs, "idle_wakeups_ps"), med(rs, "interrupt_wakeups_ps"))
    print(f"| {s} | {len(rs)} | {cpu:.3f} | {med(rs,'cpu_ms_per_min'):.0f} | {med(rs,'idle_wakeups_ps'):.2f} | {med(rs,'interrupt_wakeups_ps'):.2f} | "
          f"{med(rs,'energy_mw'):.2f} | {med(rs,'gpu_ms_per_min'):.1f} | {med(rs,'footprint_mb'):.0f} | {med(rs,'helper_cpu_percent'):.3f} | "
          f"{sum(1 for r in rs if r['visible_end'])}/{len(rs)} | {med(rs,'load_start'):.1f} |")
    if s.startswith("idle-") and (cpu > 0.2 or wk > 2): over.append(f"{s}: CPU {cpu:.3f}%, wakeups {wk:.2f}/s")
print("idle budget (≤ 0.2 % CPU, ≤ 2 wakeups/s): " + ("; ".join(over) if over else "within"))
EOF

#!/bin/zsh
# scripts/ui-scale.sh [--bin <release bin dir>] [--sizes narrow,laptop,large] [--out <dir>]
#
# The UI at scale (docs/dev-builds.md, "UI at scale"): every area of the window worked as a person
# works it (the `scale` storylines, Catalogue/ScaleStorylines.swift), at three window sizes and two
# loads, every click and key timed to the frame it settles on. Six off-screen kore-storylines apps
# at once (Claude and Codex × the three sizes), input in process, the scripted CLI (no models).
#
#   sizes   narrow 560×700, laptop 1440×860, large 3008×1692
#   loads   light: each area's own storyline (tabs, groups, both pickers, Devices, the agent map,
#           History, the explorer, table and code copy, the rail, the composer, the terminal);
#           heavy: 30 tabs (tabs, Devices), a chat of 300 turns (open, scroll, rail, both copies,
#           both pickers, the composer), 500 files (the explorer)
#   budgets a click or key settled (the window drawing at the display's pace again) in 100 ms;
#           a scroll's frames at p95 16 ms; popups whole in the window at their anchor; frames
#           steady and nothing clipped (the live check's Look)
#
# stdout: one ✔/✘ per area × load × size × CLI with its slowest step in ms, the ten slowest steps,
# then the total. Detail: <out>/<shard>/ui-scale.jsonl, report.txt, shots/. ≤10 min in all.
[[ -n ${KORE_DEVRUN_JOB-} || ! -x ${0:A:h}/devrun ]] || exec ${0:A:h}/devrun --name ui-scale -- /bin/zsh "$0" "$@"
set -u
zmodload zsh/datetime
cd "${0:A:h}/.." || exit 2
root=$PWD
bin=""; out=""; sizes=narrow,laptop,large
while (( $# )); do
  case $1 in
    --bin) bin=${2:A}; shift ;;
    --sizes) sizes=$2; shift ;;
    --out) out=$2; shift ;;
    *) print "ui-scale.sh: unknown $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $out ]] || out="${TMPDIR:-/tmp}/kore-ui-scale/$(date +%Y%m%d-%H%M%S)"
rm -rf $out; mkdir -p $out
log=$out/ui-scale.log
start=$EPOCHREALTIME
typeset -A dims=(narrow 560x700 laptop 1440x860 large 3008x1692)

limit() {
  local t=$1; shift
  setopt local_options monitor 2>/dev/null
  "$@" &
  local pid=$!
  ( sleep $t; kill -TERM -$pid 2>/dev/null; sleep 3; kill -KILL -$pid 2>/dev/null ) &!
  local watch=$!
  wait $pid; local rc=$?
  pkill -P $watch 2>/dev/null; kill $watch 2>/dev/null
  return $rc
}

# ---- the build: the given one, or one here (release, nice, through the shared build slot)
if [[ -z $bin ]]; then
  b0=$EPOCHREALTIME
  print "== swift build -c release --product kore-storylines" >> $log
  if ! limit 1500 nice -n 10 $root/scripts/one-build.sh swift build -c release --product kore-storylines >> $log 2>&1; then
    print "✘ build failed ($log)"; exit 2
  fi
  bin=$(swift build -c release --show-bin-path 2>/dev/null)
  printf 'build %ds\n' $(( EPOCHREALTIME - b0 )) >> $log
fi
[[ -x $bin/kore-storylines ]] || { print "✘ no kore-storylines in $bin"; exit 2; }

# ---- each app under a name of its own (its own defaults domain, pasteboard and
# Kore folders), so none reads another's settings or another's copy
shard() {
  local name=$1 provider=$2 size=$3
  local link=$bin/kore-storylines-us$$-$name
  ln -sf kore-storylines $link
  defaults delete ${link:t} >/dev/null 2>&1
  mkdir -p $out/$name
  limit 540 nice -n 5 $link --tag scale --provider $provider --size $size \
    --cassettes $root/Tests/Fixtures/cassettes --out $out/$name >> $out/$name/stdout.log 2>&1
  print $? > $out/$name/exit
}
cleanup() {
  for f in $bin/kore-storylines-us$$-*(N); do defaults delete ${f:t} >/dev/null 2>&1; rm -f ~/Library/Preferences/${f:t}.plist; done
  rm -f $bin/kore-storylines-us$$-*(N)
}
trap cleanup EXIT
for s in ${(s:,:)sizes}; do
  [[ -n ${dims[$s]-} ]] || { print "ui-scale.sh: no size $s (narrow, laptop, large)" >&2; exit 2; }
done
load0=$(sysctl -n vm.loadavg | awk '{print $2}')
t0=$EPOCHREALTIME
# Two apps at a time, Claude's and Codex's, each through the sizes in turn: six at once loaded the
# Mac enough to time the load, not the app (a 7 s "stall" alone measured 33 ms).
for p in claude codex; do
  ( for s in ${(s:,:)sizes}; do shard $s-$p $p ${dims[$s]}; done ) &
done
wait
run_s=$(printf '%d' $(( EPOCHREALTIME - t0 )))

# ---- the report
python3 -I - $out $run_s $(printf '%d' $(( EPOCHREALTIME - start ))) "$sizes" "$load0" "$(sysctl -n vm.loadavg | awk '{print $2}')" <<'PY'
import json, os, re, sys
out, run_s, total_s, sizes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4].split(",")
load0, load1 = sys.argv[5], sys.argv[6]
CLIS = ["claude", "codex"]
STEP_BUDGET, FRAME_BUDGET = 100.0, 16.0

rows = {}      # (element, load, size, cli) -> {"ms": slowest, "label": ..., "fail": reason, "slow": [...]}
steps = []     # every timed step: (ms, element, load, size, cli, label, worst)
missing = []
for size in sizes:
    for cli in CLIS:
        shard = f"{size}-{cli}"
        d = os.path.join(out, shard)
        begins = {}  # story -> last (element, load)
        try:
            lines = [json.loads(l) for l in open(os.path.join(d, "ui-scale.jsonl")) if l.strip()]
        except Exception:
            lines = []
        for r in lines:
            key = (r.get("element", ""), r.get("load", ""), size, cli)
            if r["kind"] == "begin":
                begins[r["story"]] = (r["element"], r["load"])
                rows.setdefault(key, {"ms": 0.0, "label": "", "fail": None, "slow": []})
            elif r["kind"] in ("step", "frames"):
                row = rows.setdefault(key, {"ms": 0.0, "label": "", "fail": None, "slow": []})
                budget = r.get("budget", STEP_BUDGET if r["kind"] == "step" else FRAME_BUDGET)
                what = r["label"] + (" (frame p95)" if r["kind"] == "frames" else "")
                if r["ms"] > row["ms"]:
                    row["ms"], row["label"] = r["ms"], what
                if r["ms"] > budget:
                    row["slow"].append(f"{what} {r['ms']:.0f} ms > {budget:.0f}")
                if r["kind"] == "step":
                    steps.append((r["ms"], r["element"], r["load"], size, cli, r["label"], r.get("worst", 0), r.get("busy", 0)))
        try:
            report = json.load(open(os.path.join(d, "report.json")))["stories"]
        except Exception:
            report = None
        if report is None:
            missing.append(f"{shard}: no report (exit {open(os.path.join(d, 'exit')).read().strip() if os.path.exists(os.path.join(d, 'exit')) else '?'}, {d}/stdout.log)")
            continue
        for story in report:
            failed = [s for s in story["steps"] if s["outcome"] == "fail"]
            if not failed:
                continue
            step = failed[0]
            err = (step.get("error") or "failed").replace("\n", " ")
            m = re.search(r"\((shots/[^)]+\.png)\)\s*$", err)
            shot = f" ({shard}/{m.group(1)})" if m else ""
            if m:
                err = err[: m.start()].strip()
            # The failure belongs to the area begun last before the failing step.
            labels = [s["label"] for s in story["steps"]]
            idx = labels.index(step["label"]) if step["label"] in labels else len(labels)
            element, load = None, None
            for s in story["steps"][:idx + 1]:
                mm = re.match(r"· (.+), (light|30 tabs|huge chat|500 files)$", s["label"])
                if mm:
                    element, load = mm.group(1), mm.group(2)
            if element is None:
                element, load = begins.get(story["name"], (story["name"], "?"))
            key = (element, load, size, cli)
            row = rows.setdefault(key, {"ms": 0.0, "label": "", "fail": None, "slow": []})
            row["fail"] = f"{step['label']}: {err[:180]}{shot}"

order = {"light": 0, "30 tabs": 1, "huge chat": 2, "500 files": 3}
size_order = {s: i for i, s in enumerate(sizes)}
ok = bad = 0
for key in sorted(rows, key=lambda k: (k[0].replace(" layout", "~"), order.get(k[1], 9), size_order.get(k[2], 9), k[3])):
    element, load, size, cli = key
    row = rows[key]
    if row["fail"] or row["slow"]:
        bad += 1
        why = row["fail"] or "slow: " + "; ".join(row["slow"][:3])
        print(f"✘ {element} · {load} · {size} · {cli}: {why}")
    else:
        ok += 1
        slowest = f"slowest {row['ms']:.0f} ms ({row['label']})" if row["label"] else "no timed step"
        print(f"✔ {element} · {load} · {size} · {cli}: {slowest}")
for m in missing:
    bad += 1
    print(f"✘ {m}")
print("")
print("slowest 10 steps (settled ms; busy = its own main-thread work, worst = longest frame gap):")
for ms, element, load, size, cli, label, worst, busy in sorted(steps, reverse=True)[:10]:
    print(f"  {ms:7.0f} ms  {element} · {load} · {size} · {cli}: {label} (busy {busy:.0f}, worst frame {worst:.0f})")
over = sum(1 for s in steps if s[0] > STEP_BUDGET)
print("")
print(f"total: {ok} ✔, {bad} ✘; {len(steps)} timed steps, {over} over {STEP_BUDGET:.0f} ms; run {run_s // 60}m{run_s % 60:02d}s, all {total_s // 60}m{total_s % 60:02d}s; load {load0} → {load1} ({out})")
try:
    if max(float(load0), float(load1)) > 12:
        print(f"note: the Mac's 1-min load was {load0} → {load1}: times over budget may be the load's; rerun one area alone (--sizes) to tell")
except ValueError:
    pass
sys.exit(1 if bad else 0)
PY

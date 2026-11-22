#!/bin/zsh
# scripts/ui-scale.sh [--bin <release bin dir>] [--sizes narrow,laptop,large] [--drive] [--out <dir>]
#
# The UI at scale (docs/dev-builds.md, "UI at scale"): every area of the window worked as a person
# works it (the `scale` storylines, Catalogue/Scale*Storylines.swift), at three window sizes and two
# loads, every click and key timed to the frame it settles on. Size by size behind a load gate,
# Claude's and Codex's off-screen kore-storylines apps at once, input in process, the scripted CLI
# (no models).
#
#   sizes   narrow 560×700, laptop 1440×860, large 3008×1692
#   loads   light: each area's own storyline (tabs, groups and their fold, drag out, close and
#           place, both pickers, Devices and its +, the agent map, History and its current row, the
#           explorer, table and code copy, the rail, the composer, the terminal, a command's whole
#           output, Arsenal and its tab groups, Kore's questions and tip, a box's History);
#           heavy: 30 tabs (tabs, a group's popup, Devices, the terminal, the agent map, History,
#           both pickers, Arsenal), a chat of 300 turns (open, scroll, rail, both copies, both
#           pickers, the composer), 500 files (the explorer)
#   gate    before each size, the 1-minute load at most the Mac's cores (waits up to
#           KORE_SCALE_WAIT s, 600; a size run over it is marked loaded)
#   budgets a click or key settled (the window drawing at the display's pace again) in 100 ms;
#           a scroll's frames at p95 16 ms; popups whole in the window at their anchor; frames
#           steady and nothing clipped (the live check's Look)
#
#   drive   with --drive, every control the coverage audit found undriven, driven once and its
#           effect checked (tag `drive`, Catalogue/Drive*Storylines.swift), at laptop size on both
#           CLIs after the sizes, behind the same gate
#
# stdout: one ✔/✘ per area × load × size × CLI with its slowest step in ms, ◌ per area whose
# feature this build doesn't have (pending), the ten slowest steps, how many looks read their
# text, the gate per size, then the total. Detail: <out>/<shard>/ui-scale.jsonl, report.txt, shots/.
[[ -n ${KORE_DEVRUN_JOB-} || ! -x ${0:A:h}/devrun ]] || exec ${0:A:h}/devrun --name ui-scale -- /bin/zsh "$0" "$@"
set -u
zmodload zsh/datetime
cd "${0:A:h}/.." || exit 2
root=$PWD
bin=""; out=""; sizes=narrow,laptop,large; drive=0
while (( $# )); do
  case $1 in
    --bin) bin=${2:A}; shift ;;
    --sizes) sizes=$2; shift ;;
    --out) out=$2; shift ;;
    --drive) drive=1 ;;
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
  # kore-command too: Arsenal's walks call the real binary.
  if ! limit 1500 nice -n 10 $root/scripts/one-build.sh zsh -c 'swift build -c release --product kore-storylines && swift build -c release --product kore-command' >> $log 2>&1; then
    print "✘ build failed ($log)"; exit 2
  fi
  bin=$(swift build -c release --show-bin-path 2>/dev/null)
  printf 'build %ds\n' $(( EPOCHREALTIME - b0 )) >> $log
fi
[[ -x $bin/kore-storylines ]] || { print "✘ no kore-storylines in $bin"; exit 2; }

# ---- each app under a name of its own (its own defaults domain, pasteboard and
# Kore folders), so none reads another's settings or another's copy
shard() {
  local name=$1 provider=$2 size=$3 tag=${4:-scale}
  local link=$bin/kore-storylines-us$$-$name
  ln -sf kore-storylines $link
  defaults delete ${link:t} >/dev/null 2>&1
  mkdir -p $out/$name
  limit 900 nice -n 5 $link --tag $tag --provider $provider --size $size \
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
# The load gate, before each size: the 1-minute load at most the Mac's cores (hw.ncpu), so a
# runnable thread doesn't wait for a core. Above it, threads queue, and a step's time is the
# queue's as much as the app's (six apps at once timed a 7 s "stall" that alone took 33 ms; a
# narrow run at load 12→17 on 10 cores failed only on time). Waits up to KORE_SCALE_WAIT s
# (600), checking every 20 s; a size run over it anyway is marked "loaded" in the report.
cores=$(sysctl -n hw.ncpu)
gate() {
  local waited=0 load
  while :; do
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    if (( load <= cores )); then print "ok $load $waited"; return; fi
    if (( waited >= ${KORE_SCALE_WAIT:-600} )); then print "loaded $load $waited"; return; fi
    sleep 20; (( waited += 20 ))
  done
}
t0=$EPOCHREALTIME
# Size by size, each behind the gate; Claude's and Codex's apps of a size at once: six at once
# loaded the Mac enough to time the load, not the app.
for s in ${(s:,:)sizes}; do
  print "$s $(gate)" > $out/gate-$s
  print "== $s: gate $(cat $out/gate-$s)" >> $log
  for p in claude codex; do shard $s-$p $p ${dims[$s]} & done
  wait
done
if (( drive )); then
  print "drive $(gate)" > $out/gate-drive
  for p in claude codex; do shard drive-$p $p ${dims[laptop]} drive & done
  wait
fi
run_s=$(printf '%d' $(( EPOCHREALTIME - t0 )))

# ---- the report
python3 -I - $out $run_s $(printf '%d' $(( EPOCHREALTIME - start ))) "$sizes" "$load0" "$(sysctl -n vm.loadavg | awk '{print $2}')" <<'PY'
import json, os, re, sys
out, run_s, total_s, sizes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4].split(",")
load0, load1 = sys.argv[5], sys.argv[6]
CLIS = ["claude", "codex"]
STEP_BUDGET, FRAME_BUDGET = 100.0, 16.0

gates = {}     # size -> (state, load, waited s)
for size in sizes:
    try:
        _, state, load, waited = open(os.path.join(out, f"gate-{size}")).read().split()
        gates[size] = (state, load, waited)
    except Exception:
        gates[size] = ("?", "?", "0")
pending = {}   # (element, load, size, cli) -> what
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
            elif r["kind"] == "pending":
                pending[key] = r["label"]
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
            if any((s.get("error") or "").startswith("SKIP: pending") for s in story["steps"]):
                continue
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
for key in list(rows):
    if key in pending or (key[0].endswith(" layout") and (key[0][: -len(" layout")],) + key[1:] in pending):
        del rows[key]
for key in sorted(rows, key=lambda k: (k[0].replace(" layout", "~"), order.get(k[1], 9), size_order.get(k[2], 9), k[3])):
    element, load, size, cli = key
    row = rows[key]
    if row["fail"] or row["slow"]:
        bad += 1
        why = row["fail"] or "slow: " + "; ".join(row["slow"][:3])
        # Over budget only, in a size the gate let through loaded: the load's as likely as the app's.
        tag = " (loaded size)" if not row["fail"] and gates.get(size, ("?",))[0] == "loaded" else ""
        print(f"✘ {element} · {load} · {size} · {cli}: {why}{tag}")
    else:
        ok += 1
        slowest = f"slowest {row['ms']:.0f} ms ({row['label']})" if row["label"] else "no timed step"
        print(f"✔ {element} · {load} · {size} · {cli}: {slowest}")
for m in missing:
    bad += 1
    print(f"✘ {m}")
for key in sorted(pending, key=lambda k: (k[0], size_order.get(k[2], 9), k[3])):
    element, load, size, cli = key
    print(f"◌ {element} · {load} · {size} · {cli}: pending, {pending[key]}")
print("")
looked = unread = 0
for size in sizes:
    for cli in CLIS:
        try:
            notes = open(os.path.join(out, f"{size}-{cli}", "live-notes.txt")).read().splitlines()
        except Exception:
            continue
        for n in notes:
            if " text: " in n:
                looked += 1
                unread += "text: not read" in n
if looked:
    print(f"text: read in {looked - unread} of {looked} looks (an unread look's stale and clipped checks didn't run)")
drive_ok = drive_bad = drive_pending = 0
for cli in CLIS:
    d = os.path.join(out, f"drive-{cli}")
    if not os.path.isdir(d):
        continue
    try:
        report = json.load(open(os.path.join(d, "report.json")))["stories"]
    except Exception:
        drive_bad += 1
        print(f"✘ drive · {cli}: no report ({d}/stdout.log)")
        continue
    for story in report:
        failed = [st for st in story["steps"] if st["outcome"] == "fail"]
        skipped = [st for st in story["steps"] if (st.get("error") or "").startswith("SKIP")]
        if failed:
            drive_bad += 1
            st = failed[0]
            print(f"✘ drive · {story['name']} · {cli}: {st['label']}: {(st.get('error') or 'failed').replace(chr(10), ' ')[:200]}")
        elif skipped:
            drive_pending += 1
            print(f"◌ drive · {story['name']} · {cli}: {skipped[0]['error'][:160]}")
        else:
            drive_ok += 1
if drive_ok or drive_bad or drive_pending:
    print(f"drive: {drive_ok} ✔, {drive_bad} ✘, {drive_pending} skipped")
    bad += drive_bad
print("gate: " + ", ".join(f"{s} {g[0]} at load {g[1]} after {g[2]} s" for s, g in gates.items()) + f" (≤ {os.cpu_count()} cores)")
print("slowest 10 steps (settled ms; busy = its own main-thread work, worst = longest frame gap):")
for ms, element, load, size, cli, label, worst, busy in sorted(steps, reverse=True)[:10]:
    print(f"  {ms:7.0f} ms  {element} · {load} · {size} · {cli}: {label} (busy {busy:.0f}, worst frame {worst:.0f})")
over = sum(1 for s in steps if s[0] > STEP_BUDGET)
print("")
print(f"total: {ok} ✔, {bad} ✘, {len(pending)} pending; {len(steps)} timed steps, {over} over {STEP_BUDGET:.0f} ms; run {run_s // 60}m{run_s % 60:02d}s, all {total_s // 60}m{total_s % 60:02d}s; load {load0} → {load1} ({out})")
sys.exit(1 if bad else 0)
PY

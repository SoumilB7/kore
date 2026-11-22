#!/bin/zsh
# scripts/live-check.sh [--bin <release bin dir>] [--tests <test scratch path> | --no-relay] [--devices [--switch]] [--scale] [--out <dir>]
#
# Kore looked at as a person would, on top of the gate (docs/dev-builds.md, "Live check"):
#   tour  the screen tour, the `livecheck` storylines: the Claude and Codex tellings side by side,
#         each in ONE kore-storylines app, off screen, input in process. Each area's frames are
#         compared (steady, no flicker), read (no work word left over, no clipped label), measured
#         (the same at two heights, nothing over text, whole in the window) and timed (clicks
#         settle under KORE_LIVE_SETTLE_MS, 800 ms). Budget 3 min.
#   net   KoreNet, boxes, the link and remote control on their fakes (scripted net, phones, boxes,
#         a link client): no tailnet, no socket; and the phone relay and KoreNet system tests (Mac,
#         kore-host and an emulated phone on an in-memory tailnet). Budget 2 min, beside the tour.
#         The tests run from --tests (the gate's test build, <src>/.build-test), else this tree's
#         .build-test, built once here if missing (SwiftPM links every test target into one
#         bundle, so there is no smaller build of them). --no-relay leaves them out.
#   --devices  the real box, `ssh mybox`: kore-host's version and daemon, the link over SSH and
#         over the tailnet, and which tailnet each side says it's on.
#   --scale    after the rest, the UI at scale (scripts/ui-scale.sh, ≤10 min) on the same build
#   --switch   (with --devices; ~6 min, never by default) stops tailscaled on mybox, root restore
#         timers armed first (300 s and 600 s), and reads the box's journal for the move to Kore's
#         own tailnet and back.
# stdout: one ✔/✘ per area (✘ with a short reason and the frame that shows it), a line per part
# with its time (over budget is ✘ slow), and the total. Everything else goes to <out>/live-check.log.
# --bin: the gate's release build (its kore-storylines and kore beside it); without it, one release
# build here first.
[[ -n ${KORE_DEVRUN_JOB-} || ! -x ${0:A:h}/devrun ]] || exec ${0:A:h}/devrun --name live-check -- /bin/zsh "$0" "$@"
set -u
zmodload zsh/datetime
cd "${0:A:h}/.." || exit 2
root=$PWD
bin=""; tests=""; relay=1; devices=0; switch=0; scale=0; out=""
while (( $# )); do
  case $1 in
    --bin) bin=${2:A}; shift ;;
    --tests) tests=${2:A}; shift ;;
    --no-relay) relay=0 ;;
    --devices) devices=1 ;;
    --switch) switch=1 ;;
    --scale) scale=1 ;;
    --out) out=$2; shift ;;
    *) print "live-check.sh: unknown $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $out ]] || out="${TMPDIR:-/tmp}/kore-live-check/$(date +%Y%m%d-%H%M%S)"
rm -rf $out; mkdir -p $out
log=$out/live-check.log
start=$EPOCHREALTIME
secs() { printf '%d' $(( EPOCHREALTIME - $1 )) }
human() { local s=$1; (( s >= 60 )) && printf '%dm%02ds' $((s / 60)) $((s % 60)) || printf '%ds' $s }

# Runs "$@" for at most $1 seconds (its whole process group); output as the caller sends it.
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

# ---- the build: the gate's, or one here
if [[ -z $bin ]]; then
  b0=$EPOCHREALTIME
  for p in kore-storylines kore-command; do
    print "== swift build -c release --product $p" >> $log
    if ! limit 1500 swift build -c release --product $p >> $log 2>&1; then print "✘ build: $p failed ($log)"; exit 2; fi
  done
  bin=$(swift build -c release --show-bin-path 2>/dev/null)
  print "build $(human $(secs $b0))" >> $log
fi
[[ -x $bin/kore-storylines ]] || { print "✘ no kore-storylines in $bin"; exit 2; }
if (( relay )) && [[ -z $tests ]]; then
  tests=$root/.build-test
  if [[ ! -d $tests/debug/KorePackageTests.xctest ]]; then
    print "== swift build --build-tests" >> $log
    limit 1800 swift build --build-tests --scratch-path $tests -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing >> $log 2>&1 \
      || { print "✘ build: tests failed ($log)"; exit 2; }
  fi
fi
(( relay )) || tests=""

# ---- tour and net: three apps at once, each under a name of its own (its own defaults domain,
# pasteboard and Kore folders), so none reads another's settings
net_names=DevicesAddPhone,DevicesTakeOffline,DevicesJoinKoreNet,DevicesAddBoxOnTailnet,DevicesPane,BoxTailnetLinuxOverTailscale,BoxTailnetLinuxOtherWay,BoxTailnetMacOverTailscale,BoxTailnetMacOtherWay,BoxTailnetOtherAccount,LinkRingAndAct,LinkRingDenied,LinkFullControl,LinkArsenal,RemoteControlOnOff
typeset -A took
shard() {
  local name=$1 limit_s=$2; shift 2
  local link=$bin/kore-storylines-lc$$-$name
  ln -sf kore-storylines $link
  defaults delete ${link:t} >/dev/null 2>&1
  mkdir -p $out/$name
  limit $limit_s $link "$@" --cassettes $root/Tests/Fixtures/cassettes --out $out/$name >> $log 2>&1
  print $? > $out/$name/exit
  print $(( EPOCHREALTIME )) > $out/$name/ended
}
# The shards run in subshells: their links and defaults domains are found by name.
cleanup() {
  for n in codex claude net; do defaults delete kore-storylines-lc$$-$n >/dev/null 2>&1; rm -f ~/Library/Preferences/kore-storylines-lc$$-$n.plist; done
  rm -f $bin/kore-storylines-lc$$-*(N)
}
trap cleanup EXIT
t0=$EPOCHREALTIME
shard claude 300 --tag livecheck --provider claude &
shard codex 300 --tag livecheck --provider codex &
shard net 200 --name $net_names --provider claude &
if [[ -n $tests && -d $tests ]]; then
  (
    mkdir -p $out/tests
    cd ${tests:h} && limit 120 swift test --skip-build --scratch-path $tests --filter 'KoreNetSystemTests|BoxRelayOnceTests|NetSweepMacTests' > $out/tests/out.txt 2>&1
    print $? > $out/tests/exit
    print $(( EPOCHREALTIME )) > $out/tests/ended
  ) &
fi
wait
for s in net codex claude; do took[$s]=$(( $(cat $out/$s/ended 2>/dev/null || print $EPOCHREALTIME) - t0 )); done
tour_s=$(printf '%d' $(( took[claude] > took[codex] ? took[claude] : took[codex] )))
[[ -f $out/tests/ended ]] && took[tests]=$(( $(cat $out/tests/ended) - t0 )) || took[tests]=0
net_s=$(printf '%d' $(( took[net] > took[tests] ? took[net] : took[tests] )))

# ---- the real box
dev_lines=()
if (( devices )); then
  d0=$EPOCHREALTIME
  ssh_=(ssh -o BatchMode=yes -o ConnectTimeout=8 mybox)
  # Version and daemon.
  if limit 20 $ssh_ 'PATH=$HOME/.local/bin:$PATH; kore-host --version; kore-host status; systemctl --user is-active kore-host' > $out/box-status.txt 2>&1; then
    v=$(head -1 $out/box-status.txt)
    if grep -qx active $out/box-status.txt; then dev_lines+=("✔ box: ${v:-kore-host}, daemon active"); else dev_lines+=("✘ box: daemon not active ($out/box-status.txt)"); fi
  else
    dev_lines+=("✘ box: ssh mybox failed ($out/box-status.txt)")
  fi
  cat $out/box-status.txt >> $log
  # The link over SSH: kore-host answers attach's version line.
  if limit 20 $ssh_ 'PATH=$HOME/.local/bin:$PATH; kore-host --version' > $out/link-ssh.txt 2>&1; then dev_lines+=("✔ link-ssh"); else dev_lines+=("✘ link-ssh ($out/link-ssh.txt)"); fi
  # The link over the tailnet: the box's KoreNet port (its status line) from this Mac.
  port=$(awk '$1 == "port" {print $2}' $out/box-status.txt | head -1)
  addr=$(awk '$1 == "listen" {print $3}' $out/box-status.txt | cut -d, -f1 | head -1)
  if [[ -n $port && -n $addr ]] && limit 8 nc -z -G 5 $addr $port >> $log 2>&1; then
    dev_lines+=("✔ link-tailnet ($addr:$port)")
  else
    dev_lines+=("✘ link-tailnet: ${addr:-no address}:${port:-?} not reachable ($out/box-status.txt)")
  fi
  # Which tailnet: the address Kore on this Mac listens on (its hosts log, read only) must be a
  # peer on the box's tailnet; the box's own line says which tailnet it's on.
  macaddr=$(grep -h 'listening host=korenet' ~/Library/Logs/Kore/hosts.log(N) 2>/dev/null | tail -1 | sed -E 's/.*reason=([0-9.]+).*/\1/')
  boxnet=$(awk '$1 == "tailnet" {$1=""; print}' $out/box-status.txt | head -1)
  print "mac korenet address: $macaddr; box tailnet:$boxnet" >> $log
  if [[ -z $macaddr ]]; then
    dev_lines+=("✘ tailnet: no KoreNet address in Kore's hosts log")
  elif limit 15 $ssh_ "tailscale status 2>/dev/null | grep -qF '$macaddr ' || PATH=\$HOME/.local/bin:\$PATH kore-host status | grep -qF '$macaddr'" >> $log 2>&1; then
    dev_lines+=("✔ tailnet: box (${boxnet## }) sees the Mac at $macaddr")
  else
    dev_lines+=("✘ tailnet: box (${boxnet## }) doesn't see the Mac's $macaddr ($log)")
  fi
  # The override: tailscaled stopped with restore timers armed FIRST, then the journal read.
  if (( switch )); then
    if limit 20 $ssh_ 'sudo -n systemd-run --on-active=300 /usr/bin/systemctl start tailscaled && sudo -n systemd-run --on-active=600 /usr/bin/systemctl start tailscaled' >> $log 2>&1; then
      mark=$(limit 10 $ssh_ 'date +%s' > $out/mark.txt 2>&1; cat $out/mark.txt)
      limit 20 $ssh_ 'sudo -n systemctl stop tailscaled' >> $log 2>&1
      moved=0; back=0
      for i in {1..26}; do
        sleep 15
        limit 15 $ssh_ "journalctl --user -u kore-host --since @$mark --no-pager | grep 'korenet listening'" > $out/switch.txt 2>&1
        grep -q 'tailnet.kore' $out/switch.txt && moved=1
        (( moved )) && grep -v 'tailnet.kore' $out/switch.txt | grep -q . && back=1
        (( back )) && break
      done
      (( moved && back )) && dev_lines+=("✔ switch: to Kore's tailnet and back") \
        || dev_lines+=("✘ switch: moved=$moved back=$back ($out/switch.txt)")
    else
      dev_lines+=("✘ switch: restore timers not armed, nothing stopped ($log)")
    fi
  fi
  dev_s=$(secs $d0)
fi

# ---- the report
python3 -I - $out $tour_s $net_s ${dev_s:-} "${(pj:\n:)dev_lines}" <<'PY'
import json, os, re, sys
out, tour_s, net_s = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
dev_s = int(sys.argv[4]) if sys.argv[4] else None
dev = [l for l in sys.argv[5].split("\n") if l.strip()]

def load(shard):
    try:
        return json.load(open(os.path.join(out, shard, "report.json")))["stories"]
    except Exception:
        return None

def reason(story, shard):
    for step in story["steps"]:
        if step["outcome"] == "fail":
            err = step.get("error") or "failed"
            m = re.search(r"\((shots/[^)]+\.png)\)\s*$", err)
            if m:
                return err[: m.start()].strip(), f"{shard}/{m.group(1)}"
            pngs = [f for f in story.get("files", []) if f.endswith(".png")]
            text = f"{step['label']}: {err}"
            return text[:90] + ("…" if len(text) > 90 else ""), (f"{shard}/{pngs[0]}" if pngs else None)
    return None, None

def area(name):
    name = name[4:] if name.startswith("Live") else name
    return re.sub(r"(?<!^)([A-Z])", r"-\1", name).lower()

lines, passed, total = [], 0, 0
for shard in ("claude", "codex"):
    stories = load(shard)
    if stories is None:
        lines.append(f"✘ tour-{shard}: no report ({shard}/stderr)"); total += 1
        continue
    for s in stories:
        both = s["variant"] and any(o["name"] == s["name"] and o["variant"] != s["variant"] for sh in ("claude", "codex") for o in (load(sh) or []))
        label = area(s["name"]) + (f":{s['variant']}" if both else "")
        total += 1
        if all(st["outcome"] != "fail" for st in s["steps"]):
            passed += 1; lines.append(f"✔ {label}")
        else:
            why, shot = reason(s, shard)
            lines.append(f"✘ {label}: {why}" + (f" ({shot})" if shot else ""))

groups = {"net-devices": "Devices", "net-tailnet": "BoxTailnet", "net-link": "Link", "net-remote": "RemoteControl"}
net = load("net")
if net is None:
    lines.append("✘ net: no report (net/)"); total += 1
else:
    for g, prefix in groups.items():
        mine = [s for s in net if s["name"].startswith(prefix)]
        if not mine: continue
        total += 1
        bad = [s for s in mine if any(st["outcome"] == "fail" for st in s["steps"])]
        if not bad:
            passed += 1; lines.append(f"✔ {g}")
        else:
            why, shot = reason(bad[0], "net")
            lines.append(f"✘ {g}: {bad[0]['name']}: {why}" + (f" ({shot})" if shot else ""))

tests_exit = None
try: tests_exit = int(open(os.path.join(out, "tests", "exit")).read())
except Exception: pass
if tests_exit is None:
    pass
elif tests_exit == 0:
    total += 1; passed += 1; lines.append("✔ net-relay")
else:
    total += 1
    fails = [l.strip() for l in open(os.path.join(out, "tests", "out.txt"), errors="replace") if "✘" in l]
    lines.append("✘ net-relay: " + ((fails[0][:90]) if fails else f"exit {tests_exit}") + " (tests/out.txt)")
skipped = [] if tests_exit is not None else ["net-relay (--no-relay)"]
skipped += ["phone (real device)", "model turns (live)", "kore new --silent (needs a live agent turn)"]
def fmt(s): return f"{s // 60}m{s % 60:02d}s" if s >= 60 else f"{s}s"
parts = [("tour", tour_s, 180), ("net", net_s, 120)]
for name, s, budget in parts:
    total += 1
    if s > budget: lines.append(f"✘ {name}: slow, {fmt(s)} > {fmt(budget)}")
    else: passed += 1
for l in dev:
    total += 1; passed += l.startswith("✔"); lines.append(l)
print("\n".join(lines))
print("skipped: " + ", ".join(skipped))
print(f"{passed}/{total}", end="")
open(os.path.join(out, "passed"), "w").write("1" if passed == total else "0")
PY
print " · tour $(human $tour_s) · net $(human $net_s)${dev_s:+ · devices $(human $dev_s)} · total $(human $(secs $start)) · $out"
scale_ok=1
if (( scale )); then
  print "\n== UI at scale"
  KORE_DEVRUN_JOB=${KORE_DEVRUN_JOB-ui-scale} /bin/zsh $root/scripts/ui-scale.sh --bin $bin --out $out/scale || scale_ok=0
fi
[[ $(cat $out/passed 2>/dev/null) == 1 ]] && (( scale_ok ))

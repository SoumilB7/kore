#!/bin/zsh
# scripts/verify-fast.sh <clone> <ref> <base-ref> [out-dir] [--radius] [--shards N]
#
# Run from main's checkout (the gate is the base's, never the ref's under check). z-docs/tools/
# verify-landing.sh's checklist, the same checks on the same files, run side by side:
#   - the Android check, the Swift tests and the release build start together;
#   - the Swift tests build once, then every test target runs at the same time;
#   - after the release build, the 60 s launch check and the storylines run together, the
#     storylines in N shards (default 5, KORE_GATE_SHARDS), each kore-storylines under a name of
#     its own (a link beside it): its own defaults domain and pasteboard, and its own --out (its
#     own Kore folders, KoreFolders); the replays run in shard 1, under the replay lock.
# The heavy phases hold every one-build slot (KoreDev/tools/one-build.sh), so nothing else builds or runs
# beside them; storyline waits run 3× as long before failing (KORE_STORY_WAIT_SCALE: a wait still
# ends at its event). The report has verify-landing.sh's sections in its order (✘ lines count the
# same), and "== times" with each phase's wall time.
#
# --radius: only what the change can reach (gate-radius.py, gate-radius.map): the Swift test
# targets that depend on a changed target, the storylines of the changed UI areas plus a smoke set,
# the Android check only when android/ changed. Shared code (LinkProtocol, src, KoreCore,
# Package.swift, scripts/, Tests/Fixtures) runs the full check. The identity, traces, lint,
# release build, launch check and replays always run. The full check (no --radius) stays the one
# for installs and releases.
set -u
zmodload zsh/datetime zsh/mathfunc
pos=(); radius=0; plan=0; shards=${KORE_GATE_SHARDS:-}; jobs=${KORE_GATE_JOBS:-}
while (( $# )); do
  case $1 in
    --radius) radius=1 ;;
    --plan) plan=1 ;;
    --shards) shards=$2; shift ;;
    --jobs) jobs=$2; shift ;;
    *) pos+=("$1") ;;
  esac
  shift
done
clone=${pos[1]:?clone}; ref=${pos[2]:?ref}; base=${pos[3]:?base}
sha=$(git -C $clone rev-parse $ref) || exit 1
short=${sha[1,7]}
out=${pos[4]:-${TMPDIR:-/tmp}/verify-$short}
rm -rf $out; mkdir -p $out
tools=${0:A:h}
here="$HOME/Library/Application Support/KoreDev"
cache="$here/verify-cache"
times=$here/tools/storyline-times.tsv
start=$EPOCHREALTIME
typeset -A began ended
phase() { began[$1]=$EPOCHREALTIME }
done_() { ended[$1]=$EPOCHREALTIME }

# One check at a time uses the kept build folder (its wait is its own phase: the time another
# gate or an install held it).
phase wait-cache
until mkdir $cache.lock 2>/dev/null; do
  holder=$(cat $cache.lock/pid 2>/dev/null)
  if [[ -z $holder ]] || ! kill -0 $holder 2>/dev/null; then rm -rf $cache.lock; continue; fi
  sleep 5
done
print $$ > $cache.lock/pid
done_ wait-cache
trap "rm -rf '$cache.lock' 2>/dev/null; pkill -P $$ 2>/dev/null" EXIT
phase sync
mkdir -p $cache/src $out/ref
git -C $clone archive $sha | tar x -C $out/ref
# What the kept folder last held (every gate writes its ref there), and how many files differ now: the release build's
# line says how warm it is.
built_from=$(cat $cache/ref 2>/dev/null); built_from=${built_from:-nothing}
synced=$(rsync -rlci --delete --exclude /.build --exclude /.build-test --exclude /build $out/ref/ $cache/src/ | grep -c '^[>*]')
rm -rf $out/ref
ln -s $cache/src $out/src
print $sha > $cache/ref
done_ sync
tree=$(git -C $clone rev-parse "$sha^{tree}")
# Everything builds and runs in the kept folder by its own path, the same every run: SwiftPM keys
# what it built by the path it was built in, so a per-run path (verify-<sha>/src) builds cold.
src=$cache/src
plugin=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)

# ---- the head: commits, identity, traces, lint (as verify-landing.sh)
phase head
{
  print "ref $sha"
  print "tree $tree"
  print "base $(git -C $clone rev-parse $base)"
  print "== commits"
  git -C $clone log --format='%h %an <%ae> | %cn <%ce> | %ad | %cd | %s' --date=iso $base..$sha
  back=$(( $(date +%u) % 7 )); sunday=${KORE_COMMIT_DAY:-$(date -v-${back}d +%Y-%m-%d)}
  floor=$(git -C $clone log -1 --format=%ct $base); now=$(date +%s)
  dayend=$(date -j -f '%Y-%m-%d %H:%M:%S' "$sunday 23:59:59" +%s); (( dayend > now )) && now=$dayend
  nine=$(date -j -f '%Y-%m-%d %H:%M:%S' "$sunday 00:00:00" +%s); (( floor < nine )) && floor=$nine
  bad=0; prev=$floor
  for line in ${(f)"$(git -C $clone log --reverse --format='%an %ae %cn %ce %at %ct %ad' --date=format:%Y-%m-%d $base..$sha)"}; do
    f=(${=line})
    [[ "$f[1] $f[2] $f[3] $f[4]" == "SoumilB7 107888098+SoumilB7@users.noreply.github.com SoumilB7 107888098+SoumilB7@users.noreply.github.com" ]] || { bad=$((bad+1)); continue }
    (( f[5] == f[6] && f[6] >= prev && f[6] <= now )) && [[ $f[7] == $sunday ]] || bad=$((bad+1))
    prev=$f[6]
  done
  print "identity-or-date-mismatches $bad"
  print "trailers $(git -C $clone log --format=%B $base..$sha | grep -ciE 'co-authored|signed-off')"
  print "agent-traces $(git -C $clone diff $base $sha | grep -E '^\+' | grep -ciE 'anthropic|claude code|opus|sonnet|haiku 5|co-author|kore-fe|kore-ef|kore-design|kore-f7|kore-3d|kore-95|kore-bb')"
  print "== lint"
  (cd $src && ./scripts/lint-theme.sh 2>&1 | tail -3)
} > $out/r-head.txt 2>&1
done_ head

# ---- the radius (before any build: dump-package takes SwiftPM's lock on .build)
android=0; [[ -x $src/android/scripts/check.sh && -x $HOME/Library/Android/jdk-17/Contents/Home/bin/java && -d $HOME/Library/Android/sdk/platforms ]] && android=1
all_tests=(${(f)"$(cd $src/Tests && ls -d *Tests(/) 2>/dev/null)"})
test_targets=($all_tests)
story_names=""; all_stories=1
if (( radius )); then
  phase radius
  git -C $clone diff --name-only $base $sha > $out/changed.txt
  (cd $src && swift package dump-package > $out/package.json 2>/dev/null)
  eval "$(python3 -I $tools/gate-radius.py $src $out/changed.txt $out/package.json)"
  {
    print "== radius"
    if (( radius_full )); then
      print "full: $radius_why"
    else
      print "radius: $radius_why"
      print "tests: ${radius_tests:-none}"
      (( radius_all_stories )) && print "storylines: every gate storyline" || print "storylines: ${radius_stories:-smoke}"
      print "android: $( (( radius_android )) && print yes || print no)"
    fi
  } > $out/r-radius.txt
  if (( ! radius_full )); then
    test_targets=(${=radius_tests})
    all_stories=$radius_all_stories
    story_names=$radius_stories
    (( radius_android )) || android=0
  fi
  done_ radius
fi

# The storylines to run and their shards (shards.txt: "<i>\t<names>"), from the release build's list.
plan_shards() {
  # The gate's storylines, by name, and how long each took last time (both variants together).
  $rel/kore-storylines --list 2>/dev/null | grep -E '\[[^]]*\bgate\b' | awk '{print $1}' | sort -u > $out/stories-gate.txt
  if (( ! all_stories )); then
    print -l ${(s:,:)story_names} | sort -u | comm -12 - $out/stories-gate.txt > $out/stories-run.txt
    # A name the map asks for that isn't a gate storyline (renamed, untagged) is a hole: it says so.
    unknown=(${(f)"$(print -l ${(s:,:)story_names} | sort -u | comm -23 - $out/stories-gate.txt)"})
    (( ${#unknown} )) && print "✘ radius-unknown-storylines ${(j:,:)unknown}" >> $out/r-radius.txt
  else
    cp $out/stories-gate.txt $out/stories-run.txt
  fi
  # A ref from before its storyline hosts could run side by side runs them in one.
  grep -q 'hasPrefix("kore-storylines")' $src/Sources/KoreCore/KoreLog.swift 2>/dev/null || shards=1
  touch $times
  # Longest first onto the least loaded shard; the replays (one Codex writer at a time) in shard 1.
  python3 -I - $out/stories-run.txt $times $shards > $out/shards.txt <<'PY'
import sys
names = [l.strip() for l in open(sys.argv[1]) if l.strip()]
took = {}
for line in open(sys.argv[2]):
    parts = line.split("\t")
    if len(parts) == 2:
        took[parts[0]] = int(parts[1])
n = max(1, min(int(sys.argv[3]), len(names)))
load = [0] * n
shards = [[] for _ in range(n)]
replays = [s for s in names if s.startswith("ReplayDump")]
for s in replays:
    shards[0].append(s); load[0] += took.get(s, 8000)
for s in sorted((s for s in names if s not in replays), key=lambda s: -took.get(s, 8000)):
    i = load.index(min(load))
    shards[i].append(s); load[i] += took.get(s, 8000)
for i, s in enumerate(shards):
    if s:
        print(f"{i + 1}\t{','.join(s)}")
PY
}

# ---- the heavy phases (builds, tests, storylines) hold every one-build slot
# (KoreDev/tools/one-build.sh's locks): no other build or gate runs beside them, so no load from outside
# skews what they check. A slot held by whoever started this gate (one-build.sh verify-fast.sh …)
# is already ours.
slots=${KORE_BUILD_SLOTS:-2}
held=()
mine=($$ $PPID)
phase wait-slots
for i in $(seq 1 $(( plan ? 0 : slots ))); do
  lock=/tmp/kore-one-build.lock; (( i > 1 )) && lock=$lock$i
  while :; do
    if mkdir $lock 2>/dev/null; then print $$ > $lock/pid; held+=($lock); break; fi
    holder=$(cat $lock/pid 2>/dev/null)
    [[ -n $holder ]] && (( ${mine[(Ie)$holder]} )) && break
    [[ -n $holder ]] && ! kill -0 $holder 2>/dev/null && rm -rf $lock
    sleep 5
  done
done
trap "rm -rf '$cache.lock' ${held[*]} 2>/dev/null; pkill -P $$ 2>/dev/null" EXIT
done_ wait-slots

# ---- how much at once: storyline shards and test targets side by side, from the cores and the
# load as the heavy phases start (fewer with other builds running), unless given (--shards,
# --jobs, KORE_GATE_SHARDS, KORE_GATE_JOBS). What runs is the same whatever they are.
ncpu=$(sysctl -n hw.ncpu); perf=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || print $ncpu)
load=$(sysctl -n vm.loadavg | awk '{print $2}')
others=$(ps -axo %cpu=,command= | awk '$1 > 5 && /swift-build|swift-frontend|GradleDaemon|GradleWorkerMain|kore-storylines/' | wc -l | tr -d ' ')
# Room: the cores half again (test processes wait on I/O and each other), less the load beyond
# what's ours; halved again while other builds run. At least 2 of each, so a busy Mac still
# overlaps the phases; at most 5 shards (what the storylines were proven side by side at).
free=$(( ncpu * 1.5 - load )); (( others )) && free=$(( free / 2 ))
whys=()
if [[ -n $shards ]]; then whys+=("shards given"); else shards=$(( int(rint(free / 2)) )); (( shards < 2 )) && shards=2; (( shards > 5 )) && shards=5; fi
if [[ -n $jobs ]]; then whys+=("jobs given"); else jobs=$(( int(rint(free)) )); (( jobs < 2 )) && jobs=2; fi
(( shards < 1 )) && shards=1; (( shards > 6 )) && shards=6
(( jobs < 1 )) && jobs=1; (( jobs > ${#test_targets} && ${#test_targets} > 0 )) && jobs=${#test_targets}
why=${(j:, :)whys}; [[ -n $why ]] || why="auto"
parallel="shards $shards, jobs $jobs ($why: $ncpu cores, $perf performance, load $load, $( (( others )) && print "$others other builds" || print "no other builds"))"

# --plan: what would run, and on how many shards and jobs, then nothing more (no build: it lists
# the storylines with the kept release build).
if (( plan )); then
  rel=$src/.build/release
  print "parallel: $parallel"
  print "== tests (${#test_targets})"; print -l $test_targets
  plan_shards
  print "== storylines ($(wc -l < $out/stories-run.txt | tr -d ' ') in $(wc -l < $out/shards.txt | tr -d ' ') shards)"
  cat $out/shards.txt
  exit 0
fi

# ---- the Android check
if (( android )); then
  phase android
  ( { print "== android"; cd $src/android && ./scripts/check.sh 2>&1 | grep -E '^(✔|✘|·|    |android check)' } > $out/r-android.txt 2>&1; print $EPOCHREALTIME > $out/t-android ) &
  android_pid=$!
fi

# ---- the Swift tests: built once in their own scratch folder, then every target at once
if (( ${#test_targets} )); then
  phase tests
  (
    cd $src
    swift build --build-tests --scratch-path .build-test $plugin 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > $out/swift-test-build.log
    print $EPOCHREALTIME > $out/t-tests-built
    bins=$(swift build --scratch-path .build-test --show-bin-path 2>/dev/null)
    clt=/Library/Developer/CommandLineTools
    helper=$clt/usr/libexec/swift/pm/swiftpm-testing-helper
    if grep -q 'hasPrefix("swiftpm-testing-helper")' Sources/KoreCore/KoreLog.swift 2>/dev/null; then
      # Each target in its own process under its own name (swiftpm-testing-helper-<target>): its
      # own defaults domain, as when swift test ran them one after another.
      mkdir -p $out/helpers
      # `jobs` at a time, the longest-running targets first.
      order=(HostClientTests KoreHostTests KoreNetSystemTests KoreLinkTests KoreUITests KoreCoreTests StorylineTests NetTrustTests)
      queue=(${order:*test_targets} ${test_targets:|order})
      pids=()
      for t in $queue; do
        while (( ${#pids} >= jobs )); do
          pids=(${(f)"$(for p in $pids; do kill -0 $p 2>/dev/null && print $p; done)"})
          (( ${#pids} >= jobs )) && sleep 0.2
        done
        ln -sf $helper $out/helpers/swiftpm-testing-helper-$t
        b=$bins/$t.xctest/Contents/MacOS/$t
        ( DYLD_FRAMEWORK_PATH=$clt/Library/Developer/Frameworks DYLD_LIBRARY_PATH=$clt/Library/Developer/usr/lib \
            $out/helpers/swiftpm-testing-helper-$t --test-bundle-path $b $b --testing-library swift-testing > $out/swift-test-$t.log 2>&1
          defaults delete swiftpm-testing-helper-$t >/dev/null 2>&1 ) &
        pids+=($!)
      done
      wait
    else
      # A ref from before its test processes could run side by side: one after another, as swift test does.
      swift test --skip-build --scratch-path .build-test $plugin > $out/swift-test-all.log 2>&1
      test_targets=(all)
    fi
    # In order, so the report reads the same however they finished.
    { grep -E 'error:' $out/swift-test-build.log | head -20; for t in $test_targets; do sed 's/\x1b\[[0-9;]*m//g' $out/swift-test-$t.log; done } > $out/swift-test.log
    print $EPOCHREALTIME > $out/t-tests
  ) &
  tests_pid=$!
fi

# ---- the release build, then the launch check and the storylines together
phase build
# Warm: the kept folder has a release build to go on from (only what changed compiles).
if [[ -x $src/.build/release/Kore ]]; then
  warmth="warm: $synced files changed since the kept build of ${built_from[1,7]}"
else
  warmth="cold: no kept build"
fi
{
  print "== release build"
  (cd $src && swift build -c release 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'error:|warning: [^s]|Build complete' | grep -v 'search path' | tail -20)
  if [[ -x $src/.build/release/Kore ]]; then
    inits=$(otool -l $src/.build/release/Kore 2>/dev/null | grep -cE '__mod_init_func|__init_offsets')
    if (( inits == 0 )); then print "static-initializers 0"; else print "✘ static-initializers $inits"; fi
  fi
} > $out/r-build.txt 2>&1
done_ build
print "release build: $warmth, $(printf %.1f $(( ended[build] - began[build] ))) s" >> $out/r-build.txt
rel=$src/.build/release

if [[ -x $rel/Kore ]]; then
  phase launch
  (
    {
      print "== launch"
      cp $rel/Kore $out/KoreLaunch
      defaults delete KoreLaunch >/dev/null 2>&1
      mkdir -p $out/launch-logs
      KORE_LOG_DIR=$out/launch-logs $out/KoreLaunch >/dev/null 2>&1 &
      app=$!
      alive=0
      for i in {1..60}; do sleep 1; kill -0 $app 2>/dev/null || break; alive=$i; done
      if kill -0 $app 2>/dev/null; then
        socks=$(lsof -a -p $app -U 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if (( socks <= 1 )); then print "launch-unix-sockets $socks"; else print "✘ launch-unix-sockets $socks"; fi
        print "launch-threads $(ps -M -p $app | tail -n +2 | wc -l | tr -d ' ')"
      fi
      if (( alive >= 60 )); then print "launch: alive at 60 s"; kill $app 2>/dev/null; else print "✘ launch: died after $alive s"; fi
      wait $app 2>/dev/null
      defaults delete KoreLaunch >/dev/null 2>&1
      rm -f $out/KoreLaunch
    } > $out/r-launch.txt 2>&1
    print $EPOCHREALTIME > $out/t-launch
  ) &
  launch_pid=$!
fi

fixtures=${KORE_VERIFY_FIXTURES:-}
if [[ -n $fixtures && -x $rel/kore-storylines ]]; then
  phase storylines
  print "== replays" > $out/r-stories.txt
  print "== storylines (gate)" >> $out/r-stories.txt
  plan_shards
  lock=/private/tmp/kore-verify-replay.lock
  spids=()
  for line in ${(f)"$(<$out/shards.txt)"}; do
    i=${line%%$'\t'*}; names=${line#*$'\t'}
    # Shard i runs as kore-storylines-i (a link beside the binary): its own defaults domain and pasteboard.
    bin=$rel/kore-storylines; (( i > 1 )) && { bin=$rel/kore-storylines-$i; ln -sf kore-storylines $bin }
    domain=${bin:t}
    sout=$out/storylines/s$i
    mkdir -p $sout
    (
      defaults delete $domain >/dev/null 2>&1
      args=(--tag gate --name $names --cassettes $src/Tests/Fixtures/cassettes --out $sout)
      if (( i == 1 )); then
        # One replay at a time across every verifier (a Codex thread takes one writer).
        until mkdir $lock 2>/dev/null; do
          holder=$(cat $lock/pid 2>/dev/null)
          if [[ -z $holder ]] || ! kill -0 $holder 2>/dev/null; then rm -rf $lock; continue; fi
          sleep 2
        done
        print $$ > $lock/pid
        (cd $src && KORE_STORY_WAIT_SCALE=3 $bin $args --replay "$fixtures" > $sout/stdout.log 2> $sout/stderr.log)
        rm -rf $lock
      else
        (cd $src && KORE_STORY_WAIT_SCALE=3 $bin $args > $sout/stdout.log 2> $sout/stderr.log)
      fi
      defaults delete $domain >/dev/null 2>&1
    ) &
    spids+=($!)
  done
  wait $spids
  for f in ${(s:;:)fixtures}; do name=${f%%|*}; cp $out/storylines/s1/$name.dump $out/$name.dump 2>/dev/null; done
  # Every shard's failures, then one total, as one run's report reads; the times kept for next time.
  python3 -I - $out/storylines $times >> $out/r-stories.txt <<'PY'
import glob, json, os, sys
root, times = sys.argv[1], sys.argv[2]
passed = failed = skipped = 0
lines, took = [], {}
for path in sorted(glob.glob(os.path.join(root, "s*", "report.json")), key=lambda p: int(p.split("/s")[-1].split("/")[0])):
    for story in json.load(open(path)).get("stories", []):
        took[story["name"]] = took.get(story["name"], 0) + int(story.get("ms", 0))
        steps = [s.get("outcome") for s in story.get("steps", [])]
        if any(o == "fail" for o in steps):
            failed += 1
        elif all(o == "skip" for o in steps):
            skipped += 1
        else:
            passed += 1
    text = os.path.join(os.path.dirname(path), "report.txt")
    if os.path.exists(text):
        lines += [l.rstrip("\n") for l in open(text) if "✗" in l or l.startswith("FAIL")]
shards = len(glob.glob(os.path.join(root, "s*")))
reports = len(glob.glob(os.path.join(root, "s*", "report.json")))
for l in lines[-19:]:
    print(l)
print(f"{passed} passed, {failed} failed" + (f", {skipped} skipped" if skipped else ""))
if reports < shards:
    print(f"✘ storylines-INCOMPLETE: {reports} of {shards} shards reported")
old = {}
if os.path.exists(times):
    for line in open(times):
        k, _, v = line.rstrip("\n").partition("\t")
        if v:
            old[k] = v
old.update({k: str(v) for k, v in took.items()})
with open(times, "w") as f:
    for k in sorted(old):
        f.write(f"{k}\t{old[k]}\n")
PY
  for f in ${(s:;:)fixtures}; do
    name=${f%%|*}
    print "$name $(wc -l < $out/$name.dump 2>/dev/null | tr -d ' ') rows, sha $(cut -d'|' -f1-4 $out/$name.dump 2>/dev/null | shasum | cut -c1-12)" >> $out/r-stories.txt
  done
  done_ storylines
fi

[[ -n ${launch_pid:-} ]] && { wait $launch_pid; ended[launch]=$(<$out/t-launch) }
[[ -n ${android_pid:-} ]] && { wait $android_pid; ended[android]=$(<$out/t-android) }
if [[ -n ${tests_pid:-} ]]; then
  wait $tests_pid
  ended[tests]=$(<$out/t-tests)
  {
    print "== swift test"
    grep -E 'Test run with|failed|error:' $out/swift-test.log | tail -20
    summaries=$(grep -c 'Test run with' $out/swift-test.log)
    (( summaries < ${#test_targets} )) && print "swift-test-INCOMPLETE: $summaries of ${#test_targets} test targets reported"
  } > $out/r-tests.txt 2>&1
fi
# The heavy phases are over: the slots go back.
(( ${#held} )) && rm -rf $held

r=$out/report.txt
{
  cat $out/r-head.txt
  print "parallel: $parallel"
  [[ -f $out/r-radius.txt ]] && cat $out/r-radius.txt
  [[ -f $out/r-android.txt ]] && cat $out/r-android.txt
  cat $out/r-build.txt
  [[ -f $out/r-launch.txt ]] && cat $out/r-launch.txt
  [[ -f $out/r-stories.txt ]] && cat $out/r-stories.txt
  [[ -f $out/r-tests.txt ]] && cat $out/r-tests.txt
  print "== times"
  for p in wait-cache sync head radius wait-slots android tests build launch storylines; do
    [[ -n ${began[$p]:-} && -n ${ended[$p]:-} ]] && printf "%-11s %6.1f s  (from %5.1f s)\n" $p $(( ended[$p] - began[$p] )) $(( began[$p] - start ))
  done
  [[ -f $out/t-tests-built ]] && printf "%-11s %6.1f s\n" tests-built $(( $(<$out/t-tests-built) - began[tests] ))
  printf "release build: %s, %.1f s\n" $warmth $(( ended[build] - began[build] ))
  [[ -f $out/shards.txt ]] && print "storyline shards $(wc -l < $out/shards.txt | tr -d ' '), stories $(wc -l < $out/stories-run.txt | tr -d ' ')"
  total=$(( EPOCHREALTIME - start )); queued=$(( ended[wait-slots] - began[wait-slots] + ended[wait-cache] - began[wait-cache] ))
  printf "total       %6.1f s: %.1f s queued (kept build folder, build slots), %.1f s the gate's own\n" $total $queued $(( total - queued ))
  print "== done $out"
} > $r 2>&1
cat $r

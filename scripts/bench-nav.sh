#!/bin/zsh
# The navigation bench (z-docs/phases/phase-11-navigation-p0/research-harness.md).
#
#   scripts/bench-nav.sh [--runs 5] [--fixtures a,b,…] [--size 880,760] [--compare <ref>] [--gate] [--smoke]
#
# Builds a release of this checkout (and of <ref>, from `git archive`, never a worktree), restores
# each fixture before every run, runs the plan for that fixture through KORE_BENCH with a clean
# defaults domain (the binary runs as "KoreBench"), samples any stall past 250 ms, and prints the
# report. --smoke runs through a failed preflight, to check the bench itself; its numbers are not
# results, and its folder is named smoke-…. --gate exits 1 on any budget FAIL or invalid record. Windows come to the front while it
# runs; say so to whoever is at the machine first.
#
# Fixtures live in $KORE_BENCH_HOME (default ~/Library/Application Support/KoreBench), built
# once by scripts/bench/fixtures.swift; results go under its results/ folder.
set -u
cd "$(dirname "$0")/.." || exit 2
repo=$PWD
home="${KORE_BENCH_HOME:-$HOME/Library/Application Support/KoreBench}"
runs=5
size=880,760
compare=""
gate=0
smoke=0
fixtures=(claude-600k claude-6mb claude-61mb compacted agents tabs3 codex-long)
while (( $# )); do
  case $1 in
    --runs) runs=$2; shift ;;
    --size) size=$2; shift ;;
    --compare) compare=$2; shift ;;
    --gate) gate=1 ;;
    --smoke) smoke=1 ;;
    --fixtures) fixtures=(${(s:,:)2}); shift ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
  shift
done

single="ready;scroll:top@2000;scroll:bottom@2000;scroll:top@2000,warm;fling*5:4000;earlier*3;fold*10;send:local*5;resize:700-1400/8;idle:10;mem"
compacted="ready;earlierconv;scroll:top@2000;scroll:bottom@2000;scroll:top@2000,warm;fold*10;send:local*5;idle:10;mem"
typeset -A plans=(
  claude-600k "$single" claude-6mb "$single" claude-61mb "$compacted" compacted "$compacted"
  agents "$single" codex-long "$single" tabs3 "ready;switch:all*20;idle:5;mem"
)

# MARK: Preflight
pre=()
pmset -g batt | grep -q "AC Power" || pre+=("not on AC power")
[[ "$(pmset -g | awk '/lowpowermode/ {print $2}')" == 1 ]] && pre+=("Low Power Mode is on")
load=$(sysctl -n vm.loadavg | awk '{print $2}')
(( ${load%.*} >= 4 )) && pre+=("1-minute load $load")
pressure=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/ {print $2}')
for f in $fixtures; do [[ -f "$home/fixtures/$f/fixture.tsv" ]] || pre+=("missing fixture $f (run scripts/bench/fixtures.swift)"); done
print "preflight: load $load, memory free $pressure"
if (( ${#pre} )); then
  print -l -- "preflight failed:" "${pre[@]}"
  (( smoke )) || exit 3
  print "smoke run: going on anyway; these numbers are not results"
fi

# MARK: Builds
build() {  # build <ref> → prints the binary path
  local ref=$1 sha dir
  sha=$(git -C "$repo" rev-parse --short "$ref") || return 1
  dir="$home/src/$sha"
  if [[ $ref == HEAD && -n "$(git -C "$repo" status --porcelain -- Sources Package.swift)" ]]; then
    # The working tree as it is: build in place.
    dir=$repo
    sha="$sha+dirty"
  elif [[ ! -x "$dir/.build/release/Kore" ]]; then
    rm -rf "$dir"; mkdir -p "$dir"
    git -C "$repo" archive "$ref" | tar -x -C "$dir" || return 1
  fi
  mkdir -p "$home/src"
  local log="$home/src/$sha.build.log"
  print -u2 "building $ref ($sha)"
  if ! (cd "$dir" && swift build -c release >"$log" 2>&1); then
    print -u2 "build of $ref failed:"; grep -E "error:" "$log" | head -20 >&2; return 1
  fi
  mkdir -p "$home/bin/$sha"
  cp "$dir/.build/release/Kore" "$home/bin/$sha/KoreBench"
  print -r -- "$sha|$home/bin/$sha/KoreBench"
}

# MARK: Fixtures
escape() { print -r -- "${1//[^A-Za-z0-9]/-}"; }

restore() {  # restore <fixture> → sets project, resume, codex_home, model
  local name=$1 line agent session file
  line=$(head -1 "$home/fixtures/$name/fixture.tsv")
  agent=$(print -r -- "$line" | cut -f2); session=$(print -r -- "$line" | cut -f3); file=$(print -r -- "$line" | cut -f4)
  project="$home/projects/$name"
  mkdir -p "$project"
  project=$(cd "$project" && pwd -P)
  codex_home=""
  if [[ $agent == claude ]]; then
    local history="$HOME/.claude/projects/$(escape "$project")"
    rm -rf "$history"; mkdir -p "$history"
    for item in "$home/fixtures/$name"/*(N); do
      [[ ${item:t} == fixture.tsv ]] || cp -R "$item" "$history/"
    done
    resume=""
    for id in ${(s:,:)session}; do resume+="${resume:+,}claude:$id"; done
  else
    codex_home="$home/codex-home/$name"
    rm -rf "$codex_home"; mkdir -p "$codex_home"
    local date=${${file#rollout-}[1,10]}
    mkdir -p "$codex_home/sessions/${date//-//}"
    cp "$home/fixtures/$name/$file" "$codex_home/sessions/${date//-//}/"
    ln -s "$HOME/.codex/auth.json" "$codex_home/auth.json"
    [[ -f "$HOME/.codex/config.toml" ]] && cp "$HOME/.codex/config.toml" "$codex_home/"
    resume="codex:$session"
  fi
  model=$([[ $agent == claude ]] && print haiku || print gpt-6-luna)
}

# MARK: Running
stamp=$(date +%Y%m%d-%H%M%S)
out="$home/results/${${smoke:#0}:+smoke-}$stamp"
mkdir -p "$out"

run_one() {  # run_one <sha> <binary> <fixture> <run>
  local sha=$1 bin=$2 name=$3 run=$4 log record pid
  restore "$name"
  defaults delete KoreBench >/dev/null 2>&1
  record="$out/$sha--$name--$run.ndjson"
  log="$out/$sha--$name--$run.log"
  env ${codex_home:+CODEX_HOME=$codex_home} KORE_OPEN="$project" KORE_RESUME="$resume" KORE_MODEL="$model" \
    KORE_SIZE="$size" KORE_HANGS=33 KORE_BENCH="${plans[$name]}" KORE_BENCH_OUT="$record" \
    KORE_BENCH_SHA="$sha" KORE_BENCH_FIXTURE="$name" KORE_BENCH_RUN="$run" \
    "$bin" >/dev/null 2>"$log" &
  pid=$!
  # A stall past 250 ms gets sampled while it lasts (at most 3 per run).
  local sampled=0 waited=0
  while kill -0 $pid 2>/dev/null; do
    if (( sampled < 3 )) && grep -q "STALL-START" "$log" 2>/dev/null && (( $(grep -c STALL-START "$log") > sampled )); then
      sampled=$(( sampled + 1 ))
      sample $pid 1 -file "$out/$sha--$name--$run--stall$sampled.txt" >/dev/null 2>&1 &
    fi
    sleep 0.2
    waited=$(( waited + 1 ))
    if (( waited > 1500 )); then kill $pid; print -u2 "  $name run $run timed out"; break; fi
  done
  wait $pid 2>/dev/null
  restore "$name"  # resuming appends to the session; leave the fixture as it was
  defaults delete KoreBench >/dev/null 2>&1
  print "  $sha $name run $run: $(grep -c . "$record" 2>/dev/null || print 0) records"
}

built=$(build HEAD) || exit 1
builds=("$built")
if [[ -n $compare ]]; then built=$(build "$compare") || exit 1; builds+=("$built"); fi
print "builds: ${builds[*]}"
for name in $fixtures; do
  print "fixture $name"
  # One discarded warm-up per build, then the runs, alternating builds (A B A B).
  for b in $builds; do run_one "${b%%|*}" "${b#*|}" "$name" 0; done
  # A covered window (another app full screen, say) isn't composited: every run would be invalid.
  if grep -q '"occluded":true' "$out"/*--"$name"--0.ndjson 2>/dev/null; then
    print -u2 "Kore's window was covered or on another Space during the warm-up; show a plain desktop and run again"
    (( smoke )) || exit 4
  fi
  for (( r = 1; r <= runs; r++ )); do
    for b in $builds; do run_one "${b%%|*}" "${b#*|}" "$name" $r; done
  done
done

print "results: $out"
report=("$out" "$repo/scripts/bench/budgets.tsv")
[[ -n $compare ]] && report+=(--base "${builds[2]%%|*}")
swift "$repo/scripts/bench/report.swift" "${report[@]}" | tee "$out/report.md"
result=${pipestatus[1]}
(( gate )) && exit $result
exit 0

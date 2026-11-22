#!/bin/zsh
# KoreNet's SSH → KoreNet upgrade, end to end on real processes: Kore's HostClient (korenet-rig,
# Kore.app without its UI) against systemd boxes in Docker with real sshd and tailscaled, all on
# a local Headscale with one DERP relay. Kore's own tailnet is the real kore-tailnet helper built
# `-tags koretest` (the only build that reads KORE_TAILNET_CONTROL_URL); this Mac's installed
# Tailscale is open-source tailscaled in userspace mode with its own socket and state (the
# owner's Tailscale, its account and its routes are never touched).
#
#   scripts/tests/korenet-real/run.sh [scenario…]        (all when none; `korenet-rig list` names them)
#
# One line per scenario, ✔/✘ with its time; each scenario's story (Kore's lines, each box's
# journal) in $RIG_RUN/logs/<scenario>.log. Everything made is labelled com.kore.rig=1 and goes at
# the end, pass or fail: containers, the network, the box image, Headscale's nodes (its database
# is a tmpfs), the run's keys. Needs Docker, Go, and the swift.org toolchain with the Static Linux
# SDK. KEEP_IMAGE=1 keeps the box image for the next run.
set -u
zmodload zsh/datetime
here=${0:A:h}
root=${here:h:h:h}
RIG_RUN="${RIG_RUN:-$HOME/Library/Application Support/KoreDev/rig-run}"
RIG_BUILD="${RIG_BUILD:-$HOME/Library/Application Support/KoreDev/rig-build}"
export RIG_RUN RIG_BIN="$RIG_BUILD/bin" RIG_HOSTBIN="$RIG_BUILD/hostbin"
export KORE_TAILNET_CONTROL_URL=http://127.0.0.1:18080 KORE_TAILNET_BIN="$RIG_BUILD/bin/kore-tailnet-darwin"
swift_linux=${KORE_LINUX_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift}
ts_version=$(sed -n 's/^\ttailscale.com \(v[0-9.]*\)$/\1/p' "$root/tools/kore-tailnet/go.mod")
mkdir -p "$RIG_RUN" "$RIG_BIN" "$RIG_HOSTBIN"
# A hard bound on a command (no coreutils timeout on a Mac).
# Builds run niced, one swift build at a time (another's under way: waited for).
swiftwait() { while pgrep -x swift-build >/dev/null; do sleep 5; done; }
bound() { perl -e '$s=shift; $p=fork; if(!$p){setpgrp(0,0); exec @ARGV or die "exec: $!"} $SIG{ALRM}=sub{kill -9,-$p; kill -9,$p; print STDERR "timed out after ${s}s\n"; exit 124}; alarm $s; waitpid $p,0; exit($?>>8)' "$@"; }
t0=$EPOCHREALTIME
lap() { printf '[%5.0fs] %s\n' $(( EPOCHREALTIME - t0 )) "$1"; }

cleanup() {
    trap - EXIT INT TERM
    pkill -f "$RIG_BIN/tailscaled-darwin" 2>/dev/null
    for id in $(docker ps -aq --filter label=com.kore.rig=1); do docker rm -f $id >/dev/null; done
    (cd $here && RIG_RUN=$RIG_RUN docker compose down -v --remove-orphans >/dev/null 2>&1)
    for net in $(docker network ls -q --filter label=com.kore.rig=1); do docker network rm $net >/dev/null 2>&1; done
    [[ ${KEEP_IMAGE:-} == 1 ]] || docker rmi kore-rig-box:1 >/dev/null 2>&1
    rm -rf /tmp/kr-[0-9]*(N) "$RIG_RUN/id_ed25519"(N) "$RIG_RUN/id_ed25519.pub"(N) "$RIG_RUN/authkey"(N) "$RIG_RUN/certs"(N) "$RIG_BUILD/ctx"(N)
    defaults delete korenet-rig >/dev/null 2>&1; defaults delete korenet-rig-fresh >/dev/null 2>&1
    rm -f ~/Library/Preferences/korenet-rig.plist ~/Library/Preferences/korenet-rig-fresh.plist
    lap "cleaned up (everything labelled com.kore.rig=1)"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. Binaries: tailscaled + tailscale (darwin: the Mac's "installed" one; linux: the boxes'),
# derper, kore-tailnet -tags koretest (both), kore-host for Linux (static musl), korenet-rig and
# kore-command beside it (`kore pipe`, as Kore.app's Helpers/kore).
export CGO_ENABLED=0 GOFLAGS=-mod=mod
ts=$(go env GOMODCACHE)/tailscale.com@$ts_version
[[ -d $ts ]] || (cd "$root/tools/kore-tailnet" && go mod download tailscale.com)
for os in darwin linux; do
    for cmd in tailscaled tailscale; do
        [[ -x $RIG_BIN/$cmd-$os ]] || (cd $ts && GOOS=$os GOARCH=arm64 bound 900 nice -n 10 go build -trimpath -buildvcs=false -ldflags "-s -w" -o $RIG_BIN/$cmd-$os ./cmd/$cmd) || exit 1
    done
done
[[ -x $RIG_BIN/derper-linux ]] || (cd $ts && GOOS=linux GOARCH=arm64 bound 900 nice -n 10 go build -trimpath -buildvcs=false -ldflags "-s -w" -o $RIG_BIN/derper-linux ./cmd/derper) || exit 1
tags="$(paste -sd, "$root/tools/kore-tailnet/build-tags"),koretest"
for os in darwin linux; do
    (cd "$root/tools/kore-tailnet" && GOOS=$os GOARCH=arm64 bound 600 nice -n 10 go build -trimpath -buildvcs=false -ldflags "-s -w" -tags "$tags" -o "$RIG_BIN/kore-tailnet-$os" .) || exit 1
done
cp "$RIG_BIN/kore-tailnet-linux" "$RIG_HOSTBIN/kore-tailnet-linux-aarch64"
linux=(--package-path "$root" --swift-sdk aarch64-swift-linux-musl -c release --product kore-host --scratch-path "$root/.build-linux")
swiftwait; bound 2400 nice -n 10 "$root/scripts/one-build.sh" "$swift_linux" build "${linux[@]}" -Xlinker --strip-all >"$RIG_RUN/linux.log" 2>&1 || { tail -20 "$RIG_RUN/linux.log"; exit 1; }
cp "$root/.build-linux/release/kore-host" "$RIG_HOSTBIN/kore-host-linux-aarch64"
swiftwait; bound 1200 nice -n 10 "$root/scripts/one-build.sh" zsh -c 'swift build --package-path "$1" --product korenet-rig && swift build --package-path "$1" --product kore-command' _ "$root" >"$RIG_RUN/rig.log" 2>&1 || { tail -20 "$RIG_RUN/rig.log"; exit 1; }
rig="$(swift build --package-path "$root" --product korenet-rig --show-bin-path)/korenet-rig"
lap "built"

# 2. The box image, the DERP cert, Headscale + DERP, the owner's user, the run's ssh key.
ctx="$RIG_BUILD/ctx"
mkdir -p $ctx && cp $here/box/* $ctx/ && cp $RIG_BIN/tailscaled-linux $ctx/tailscaled && cp $RIG_BIN/tailscale-linux $ctx/tailscale && cp $RIG_BIN/derper-linux $ctx/derper
bound 900 docker build -q --label com.kore.rig=1 -t kore-rig-box:1 $ctx >/dev/null || exit 1
mkdir -p "$RIG_RUN/certs"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=localhost \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -keyout "$RIG_RUN/certs/localhost.key" -out "$RIG_RUN/certs/localhost.crt" 2>/dev/null
(cd $here && bound 120 docker compose up -d >/dev/null 2>&1) || { print -u2 "korenet-real: docker compose up failed"; exit 1; }
for i in {1..50}; do docker exec kore-rig-headscale-1 headscale users list >/dev/null 2>&1 && break; sleep 0.2; done
docker exec kore-rig-headscale-1 headscale users create owner >/dev/null 2>&1
docker exec kore-rig-headscale-1 headscale preauthkeys create --user 1 --reusable --expiration 6h -o json \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])' > "$RIG_RUN/authkey" || exit 1
ssh-keygen -q -t ed25519 -N '' -C kore-rig -f "$RIG_RUN/id_ed25519" <<<y >/dev/null 2>&1
lap "Headscale, DERP and the box image up"

# 3. The scenarios, each its own process (Kore's objects are process-wide), cleaned after each.
scenarios=("$@")
(( $# )) || scenarios=(${(f)"$("$rig" list | cut -f1)"})
passed=0 failed=0
# The clean slate each scenario starts from, checked and kept as proof/<scenario>/reset.txt.
reset_check() {
    local bad=0 out="$RIG_RUN/proof/$1"
    mkdir -p "$out"
    {
        print "Clean slate before $1 ($(date '+%H:%M:%S')):"
        local boxes=$(docker ps -aq --filter label=com.kore.rig.scenario | wc -l | tr -d ' ')
        [[ $boxes == 0 ]] && print "  ✔ no rig box containers" || { print "  ✘ $boxes rig box containers"; bad=1; }
        local nodes=$(docker exec kore-rig-headscale-1 headscale nodes list -o json 2>/dev/null | python3 -c 'import sys,json; print(len(json.load(sys.stdin) or []))')
        [[ $nodes == 0 ]] && print "  ✔ Headscale has no nodes" || { print "  ✘ Headscale has $nodes nodes"; bad=1; }
        local scratch=(/tmp/kr-[0-9]*(N))
        (( ${#scratch} == 0 )) && print "  ✔ no Kore scratch folders (/tmp/kr-*)" || { print "  ✘ left: $scratch"; bad=1; }
        [[ $(defaults read korenet-rig 2>/dev/null) == *=* ]] && { print "  ✘ the korenet-rig settings domain still holds keys"; bad=1; } || print "  ✔ no korenet-rig settings"
        pgrep -f "$RIG_BIN/tailscaled-darwin" >/dev/null && { print "  ✘ this Mac's rig tailscaled still runs"; bad=1; } || print "  ✔ no rig tailscaled on this Mac"
        print "  · the owner's ~/.ssh is never read or written: every ssh runs with -F <the run's config>"
        (( bad == 0 )) && print "clean" || print "not clean"
    } > "$out/reset.txt"
    return $bad
}
# The reset: whatever an earlier run left of the rig goes (only what's labelled com.kore.rig=1,
# the rig's own Headscale nodes, its scratch and settings domain, its tailscaled on this Mac).
reset() {
    pkill -f "$RIG_BIN/tailscaled-darwin" 2>/dev/null
    for id in $(docker ps -aq --filter label=com.kore.rig.scenario); do docker rm -f $id >/dev/null; done
    for id in $(docker exec kore-rig-headscale-1 headscale nodes list -o json 2>/dev/null | python3 -c 'import sys,json;[print(n["id"]) for n in json.load(sys.stdin) or []]'); do
        docker exec kore-rig-headscale-1 headscale nodes delete --identifier $id --force >/dev/null
    done
    rm -rf /tmp/kr-[0-9]*(N) /tmp/kr-fresh(N)
    defaults delete korenet-rig >/dev/null 2>&1; defaults delete korenet-rig-fresh >/dev/null 2>&1
}
for s in $scenarios; do
    rm -rf "$RIG_RUN/proof/$s"
    reset
    reset_check $s || { print "✘ $s: not a clean slate ($(grep '✘' "$RIG_RUN/proof/$s/reset.txt" | tr '\n' ' '))"; (( failed += 1 )); continue; }
    RIG_SCENARIO_LIMIT=${RIG_SCENARIO_LIMIT:-600} bound $(( ${RIG_SCENARIO_LIMIT:-600} + 30 )) "$rig" $s
    code=$?
    if (( code != 0 )); then
        (( code == 124 )) && print "✘ $s: timed out ($(( ${RIG_SCENARIO_LIMIT:-600} + 30 ))s)"
        # Whatever a failed or stuck run left: its boxes, this Mac's tailscaled, every node.
        pkill -f "$RIG_BIN/tailscaled-darwin" 2>/dev/null
        for id in $(docker ps -aq --filter label=com.kore.rig.scenario=$s); do docker rm -f $id >/dev/null; done
        for id in $(docker exec kore-rig-headscale-1 headscale nodes list -o json 2>/dev/null | python3 -c 'import sys,json;[print(n["id"]) for n in json.load(sys.stdin) or []]'); do
            docker exec kore-rig-headscale-1 headscale nodes delete --identifier $id --force >/dev/null
        done
    fi
    if (( code == 0 )); then (( passed += 1 )); else (( failed += 1 )); fi
done
# The summary: one row per case (the rig's, and mybox-proof.sh's when it ran), linking its folder.
{
    print "| case | verdict | proof |"
    print "|---|---|---|"
    for v in "$RIG_RUN"/proof/*/verdict.txt(N); do
        c=${v:h:t}
        print "| $c | $(head -1 $v | sed 's/|/\\|/g') | [proof/$c](./$c/) |"
    done
} > "$RIG_RUN/proof/SUMMARY.md"
lap "$passed passed, $failed failed · $RIG_RUN/proof/SUMMARY.md"
(( failed == 0 ))

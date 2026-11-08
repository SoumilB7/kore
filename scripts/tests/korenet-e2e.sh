#!/bin/zsh
# KoreNet over real Tailscale, end to end: an isolated kore-host on a box and KoreNet's own code on
# this Mac (`korenet-e2e`). Run before installs; unit suites never touch the real network path.
#
#   KORE_E2E_TAILNET=1 scripts/tests/korenet-e2e.sh
#
# Steps: this Mac's Tailscale is Running and `ssh <box>` works (else exit 2); kore-host is built
# for Linux (static musl) into a scratch folder and copied to <box>:/tmp/kore-e2e; there it runs
# with HOME, XDG_STATE_HOME, XDG_RUNTIME_DIR and XDG_CONFIG_HOME under /tmp/kore-e2e and
# KORE_NET_PORT=47571 (`net on`, `join`, `run`): never the real service, its state, grants or
# port 47470. The Mac client, with an identity made for the run in a temp folder (no Keychain, no
# defaults), enrolls over `ssh <box> … attach --proto 2`, dials the box's tailnet address,
# checks WhoIs and both identity proofs, pings, lists a folder, drops TCP and resumes with its
# ticket and cursors, checks `chat.call` dedupe (`setDraft`: no CLI, no model), then holds the
# link idle 30 s while the box daemon's RSS and CPU are read from /proc. Everything on the box and
# the scratch folder goes at the end, pass or fail.
#
# KORE_E2E_BOX (mybox), KORE_E2E_IDLE (30), KORE_E2E_HOST_BIN (a kore-host already built for the
# box: skips the Linux build), KORE_LINUX_SWIFT (the swift.org toolchain).
set -u
zmodload zsh/datetime
[[ ${KORE_E2E_TAILNET:-} == 1 ]] || { print "korenet-e2e: skipped (KORE_E2E_TAILNET=1 runs it)"; exit 0; }

root=${0:A:h:h:h}
box=${KORE_E2E_BOX:-mybox}
idle=${KORE_E2E_IDLE:-30}
port=47571
dir=/tmp/kore-e2e
tailscale=/usr/local/bin/tailscale
swift_linux=${KORE_LINUX_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift}
ssh_box=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$box")
# Everything the test daemon sees: its own folders and port, no CLI on PATH, nothing inherited.
remote="env -i HOME=$dir/home XDG_STATE_HOME=$dir/state XDG_RUNTIME_DIR=$dir/run XDG_CONFIG_HOME=$dir/config KORE_NET_PORT=$port PATH=/usr/bin:/bin $dir/kore-host"

t0=$EPOCHREALTIME
lap() { printf '[%5.1fs] %s\n' $(( EPOCHREALTIME - t0 )) "$1"; }

# 1. Preconditions: never started or changed here.
if ! "$tailscale" status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then
    print -u2 "korenet-e2e: this Mac's Tailscale isn't Running: start Tailscale on this Mac, then run it again"
    exit 2
fi
if ! "${ssh_box[@]}" true 2>/dev/null; then
    print -u2 "korenet-e2e: ssh -o BatchMode=yes $box true failed: check the box is up and the ssh alias works"
    exit 2
fi

scratch=$(mktemp -d -t korenet-e2e)
# Only processes running the test binary are stopped; the real kore-host never matches.
remote_cleanup="for p in /proc/[0-9]*; do case \$(readlink \$p/exe 2>/dev/null) in $dir/kore-host*) kill \${p#/proc/} 2>/dev/null;; esac; done; rm -rf $dir"
cleanup() {
    local code=$?
    trap - EXIT INT TERM
    if (( code != 0 )); then
        print "--- box daemon log (last 25 lines)"
        "${ssh_box[@]}" "tail -25 $dir/daemon.log" 2>/dev/null
    fi
    "${ssh_box[@]}" "$remote_cleanup" 2>/dev/null
    rm -rf "$scratch"
    lap "cleaned up ($box:$dir, $scratch)"
    exit $code
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# A run killed before its cleanup leaves its daemon: it goes first.
"${ssh_box[@]}" "$remote_cleanup"

# 2. kore-host for the box's CPU, and the Mac client.
arch=$("${ssh_box[@]}" uname -m)
[[ $arch == (x86_64|aarch64) ]] || { print -u2 "korenet-e2e: $box is $arch: x86_64 or aarch64 only"; exit 1; }
if [[ -n ${KORE_E2E_HOST_BIN:-} ]]; then
    host_bin=$KORE_E2E_HOST_BIN
else
    [[ -x $swift_linux ]] || { print -u2 "korenet-e2e: no $swift_linux (the swift.org 6.4.2 toolchain)"; exit 1; }
    linux=(--package-path "$root" --swift-sdk "$arch-swift-linux-musl" -c release --product kore-host --scratch-path "$scratch/linux")
    "$swift_linux" build "${linux[@]}" -Xlinker --strip-all >"$scratch/linux.log" 2>&1 || { tail -30 "$scratch/linux.log"; exit 1; }
    host_bin="$("$swift_linux" build "${linux[@]}" --show-bin-path)/kore-host"
    lap "built kore-host for $arch-linux-musl ($(( $(stat -f %z "$host_bin") / 1024 )) KB)"
fi
swift build --package-path "$root" --product korenet-e2e >"$scratch/client.log" 2>&1 || { tail -30 "$scratch/client.log"; exit 1; }
client="$(swift build --package-path "$root" --product korenet-e2e --show-bin-path)/korenet-e2e"
t0=$EPOCHREALTIME
lap "client built; the timed part starts"

"${ssh_box[@]}" "mkdir -m 700 $dir" || exit 1
scp -q -o BatchMode=yes "$host_bin" "$box:$dir/kore-host" || exit 1
lap "copied to $box:$dir"

# 3. The test daemon: served folder $dir, a full grant for the SSH upgrade, KoreNet on, joined.
said=$("${ssh_box[@]}" "set -e; cd $dir; chmod 700 kore-host; mkdir -m 700 home state run config config/kore-host
printf '{\"folders\":[\"$dir\"]}' > config/kore-host/config.json
$remote allow e2e --control full >/dev/null
$remote net on >/dev/null
$remote join >join.log
nohup $remote run >daemon.log 2>&1 </dev/null &
hex=\$(printf '%04X' $port)
for i in \$(seq 100); do grep -q \":\$hex [0-9A-F:]* 0A \" /proc/net/tcp /proc/net/tcp6 2>/dev/null && break; sleep 0.05; done
grep -q \":\$hex [0-9A-F:]* 0A \" /proc/net/tcp /proc/net/tcp6 || { echo 'not listening on $port' >&2; cat join.log daemon.log >&2; exit 1; }
echo device=\$(cat state/kore-host/device-id)
echo key=\$(base64 -w0 state/kore-host/identity.key)
echo pid=\$(cat run/kore-host/kore-host.pid)
echo ip=\$(tailscale ip -4 | head -1)") || { print -u2 "korenet-e2e: the test daemon didn't start"; exit 1; }
typeset -A got
for line in ${(f)said}; do got[${line%%=*}]=${line#*=}; done
for k in device key pid ip; do [[ -n ${got[$k]:-} ]] || { print -u2 "korenet-e2e: the box didn't say its $k"; exit 1; }; done
lap "test daemon up on $box (pid ${got[pid]}, ${got[ip]}:$port)"

# 4–5. The Mac end, with the round trips, resume, dedupe and the idle numbers.
"$client" --ssh "$box" --remote "$remote" --grant e2e --box-ip "${got[ip]}" --port $port --box-device "${got[device]}" \
    --box-key "${got[key]}" --folder "$dir" --pid "${got[pid]}" --idle "$idle"
code=$?
lap "client done"
exit $code

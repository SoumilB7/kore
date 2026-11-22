#!/bin/zsh
# The rig's real-box part, against a box the owner lent (mybox): this clone's kore-host run
# isolated there (HOME, XDG_* under /tmp/kore-rig, port 47571, no kore-tailnet beside it, so no
# tailnet node is ever made), never the box's own kore-host, its state or its grants.
#
#   KORE_RIG_BOX=mybox KORE_RIG_HOST_BIN=<kore-host for its CPU> [KORE_RIG_TAILSCALED=1] scripts/tests/korenet-real/mybox.sh
#
# 1. install-service on demand returns at once, the daemon running (the Linux spawn fix);
# 2. tailscaled stopped and started (root restore timers armed first, at 300 s and 600 s):
#    the daemon waits on installed Tailscale and listens again on tailscale0, timed; while
#    tailscaled restarts, `systemctl is-active` is what kore-host's boot grace reads.
# Everything under /tmp/kore-rig goes at the end; the timers are stopped once tailscaled is back.
set -u
zmodload zsh/datetime
box=${KORE_RIG_BOX:-mybox}
bin=${KORE_RIG_HOST_BIN:?KORE_RIG_HOST_BIN: a kore-host built for the box}
dir=/tmp/kore-rig port=47571
ssh=(ssh -o BatchMode=yes -o ConnectTimeout=8 $box)
env_="env -i HOME=$dir/home XDG_STATE_HOME=$dir/state XDG_RUNTIME_DIR=$dir/run XDG_CONFIG_HOME=$dir/config KORE_NET_PORT=$port KORE_HOST_SERVICE=on-demand PATH=/usr/bin:/bin"
fails=0
check() { if [[ $2 == 0 ]]; then print "✔ $1"; else print "✘ $1${3:+: $3}"; (( fails += 1 )); fi }
t0=$EPOCHREALTIME
cleanup() {
    "${ssh[@]}" "for p in /proc/[0-9]*; do case \$(readlink \$p/exe 2>/dev/null) in $dir/*) kill \${p#/proc/} 2>/dev/null;; esac; done; rm -rf $dir" 2>/dev/null
    # tailscaled up again whatever happened, then the restore timers go.
    [[ ${KORE_RIG_TAILSCALED:-} == 1 ]] && "${ssh[@]}" "sudo -n systemctl start tailscaled; for u in \$(systemctl list-units --plain --no-legend 'kore-rig-restore-*' | awk '{print \$1}'); do sudo -n systemctl stop \$u; done" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

"${ssh[@]}" "mkdir -m 700 -p $dir/home $dir/state $dir/run $dir/config/kore-host" || exit 2
scp -q -o BatchMode=yes "$bin" "$box:$dir/kore-host" || exit 2
"${ssh[@]}" "chmod 700 $dir/kore-host; printf '{\"folders\":[\"$dir\"],\"net\":true}' > $dir/config/kore-host/config.json"

# 1. On demand: install-service must return (it hung while the daemon held Foundation's socket).
start=$EPOCHREALTIME
said=$("${ssh[@]}" "timeout 20 $env_ $dir/kore-host install-service; echo exit=\$?")
took=$(( EPOCHREALTIME - start ))
check "install-service on demand returned ($(printf %.1f $took)s)" $([[ $said == *exit=0* ]] && echo 0 || echo 1) "$said"
listening() { "${ssh[@]}" "grep -q ':$(printf '%04X' $port) [0-9A-F:]* 0A ' /proc/net/tcp /proc/net/tcp6"; }
for i in {1..50}; do listening && break; sleep 0.2; done
listening; check "the isolated daemon listens on tailscale0:$port" $?

# 2. tailscaled stopped and started, restore timers first: only when asked (it cuts the box's
# Tailscale for a few seconds, every other user of it with it).
if [[ ${KORE_RIG_TAILSCALED:-} != 1 ]]; then
    print "  (tailscaled stop/start skipped: KORE_RIG_TAILSCALED=1 runs it)"
    print "mybox: $fails failed ($(printf %.0f $(( EPOCHREALTIME - t0 )))s)"
    exit $(( fails > 0 ))
fi
"${ssh[@]}" "sudo -n systemd-run --unit kore-rig-restore-a --on-active=300 /usr/bin/systemctl start tailscaled >/dev/null 2>&1; sudo -n systemd-run --unit kore-rig-restore-b --on-active=600 /usr/bin/systemctl start tailscaled >/dev/null 2>&1"
"${ssh[@]}" "sudo -n systemctl list-timers --no-legend 'kore-rig-restore-*' | wc -l" | read timers
check "two restore timers armed" $([[ ${timers:-0} -ge 2 ]] && echo 0 || echo 1) "${timers:-0}"
(( ${timers:-0} >= 2 )) || exit 1
"${ssh[@]}" "sudo -n systemctl stop tailscaled"
for i in {1..50}; do listening || break; sleep 0.2; done
! listening; check "with tailscaled stopped, nothing listens (no helper: it waits on Tailscale)" $?
state=$("${ssh[@]}" "cat $dir/state/kore-host/run/net.state 2>/dev/null || cat $dir/run/kore-host/net.state 2>/dev/null")
print "  net.state: $state"
# The restart as boot would see it: is-active while it comes up.
active=$("${ssh[@]}" "sudo -n systemctl start --no-block tailscaled; systemctl is-active tailscaled")
print "  systemctl is-active right after start: $active"
start=$EPOCHREALTIME
for i in {1..150}; do listening && break; sleep 0.2; done
listening; check "listening again after tailscaled came back ($(printf %.1f $(( EPOCHREALTIME - start )))s)" $?
print "mybox: $fails failed ($(printf %.0f $(( EPOCHREALTIME - t0 )))s)"
(( fails == 0 ))

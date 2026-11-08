#!/bin/zsh
# A box's own tailnet on a real box, end to end: a SECOND kore-host on <box>, in a scratch folder
# of its own, with KoreNet on and its tailnet forced to Kore's own `kore-tailnet`
# (KORE_HOST_TAILNET=kore): an ephemeral node named kore-test-<time>. It prints that node's
# sign-in page (the one manual step: open it on this Mac, sign in with the owner's account),
# waits for the node to run and kore-host to listen on it, then dials it from this Mac over the
# tailnet and says joined.
#
#   KORE_LIVE_TAILNET=1 scripts/tests/box-tailnet-live.sh
#
# The box's own kore-host (its service, ~/.local/state/kore-host, port 47470) and its system
# Tailscale are only read (`systemctl --user is-active`, the daemon's pid before and after), never
# started, stopped or changed; nothing runs `tailscale up/down/logout`. The test daemon runs with
# `env -i`: HOME and every XDG folder under /tmp/kore-live-<time>, port 47572 inside its own node,
# no CLI on PATH. At the end, pass, fail or ^C: the test daemon gets SIGINT (its kore-tailnet stops
# with it), the scratch folder is removed on the box and here. The ephemeral node leaves the
# tailnet by itself once offline; or remove kore-test-<time> under Machines in Tailscale's admin.
#
# KORE_LIVE_BOX (mybox), KORE_LIVE_WAIT (600 s for the sign-in), KORE_LIVE_HOST_BIN and
# KORE_LIVE_TAILNET_BIN (kore-host / kore-tailnet already built for the box, .xz or not: skip
# the builds), KORE_LINUX_SWIFT (the swift.org toolchain scripts/build-host.sh uses).
set -u
zmodload zsh/datetime
[[ ${KORE_LIVE_TAILNET:-} == 1 ]] || { print "box-tailnet-live: skipped (KORE_LIVE_TAILNET=1 runs it)"; exit 0; }

root=${0:A:h:h:h}
box=${KORE_LIVE_BOX:-mybox}
wait_for=${KORE_LIVE_WAIT:-600}
port=47572
stamp=$(date +%m%d-%H%M%S)
name=kore-test-$stamp
dir=/tmp/kore-live-$stamp
here=$(mktemp -d -t kore-live)
ssh_box=(ssh -o BatchMode=yes -o ConnectTimeout=8 $box)
remote="env -i HOME=$dir/home XDG_STATE_HOME=$dir/state XDG_RUNTIME_DIR=$dir/run XDG_CONFIG_HOME=$dir/config KORE_NET_PORT=$port"
remote+=" KORE_HOST_TAILNET=kore KORE_HOST_TAILNET_NAME=$name KORE_HOST_TAILNET_EPHEMERAL=1 PATH=/usr/bin:/bin $dir/bin/kore-host"
pid=""

t0=$EPOCHREALTIME
lap() { printf '[%5.1fs] %s\n' $(( EPOCHREALTIME - t0 )) "$1"; }
fail() { lap "FAIL: $1"; exit 1; }

cleanup() {
    trap - EXIT INT TERM
    if [[ -n $pid ]]; then
        "${ssh_box[@]}" "kill -INT $pid 2>/dev/null; i=0; while kill -0 $pid 2>/dev/null && [ \$i -lt 50 ]; do sleep 0.2; i=\$((i+1)); done; kill -KILL $pid 2>/dev/null; true" </dev/null
    fi
    # Its pid unknown (a launch that never answered): this run's daemon and helper by their folder.
    "${ssh_box[@]}" "pkill -INT -f '^$dir/bin/kore-host run' 2>/dev/null; sleep 2; pkill -KILL -f '^$dir/bin/kore-(host|tailnet)' 2>/dev/null; true" </dev/null
    "${ssh_box[@]}" "rm -rf '$dir'" </dev/null && lap "cleaned up: the test daemon stopped, $box:$dir removed"
    rm -rf "$here"
    print "note: $name is ephemeral and leaves the tailnet once offline (or remove it under Machines)"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. The box answers over SSH; its own kore-host as it is now (read only).
arch=$("${ssh_box[@]}" uname -m </dev/null) || fail "ssh $box doesn't work"
case $arch in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) fail "$box runs $arch" ;; esac
real_before=$("${ssh_box[@]}" 'systemctl --user is-active kore-host 2>/dev/null; cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kore-host/kore-host.pid" 2>/dev/null' </dev/null | tr '\n' ' ')
lap "$box ($arch); its own kore-host: ${real_before:-not running}"

# 2. This branch's kore-host and kore-tailnet for the box.
take() { # file, name: into $here/name, unpacked
    [[ $1 == *.xz ]] && { xz -dc "$1" > "$here/$2" || return 1; } || cp "$1" "$here/$2" || return 1
    chmod 755 "$here/$2"
}
host_bin=${KORE_LIVE_HOST_BIN:-}
if [[ -z $host_bin ]]; then
    lap "building kore-host for Linux $arch"
    "$root/scripts/build-host.sh" $arch >"$here/build-host.log" 2>&1 || { tail -5 "$here/build-host.log"; fail "kore-host didn't build"; }
    host_bin=$root/build/release/kore-host-linux-$arch.xz
fi
tailnet_bin=${KORE_LIVE_TAILNET_BIN:-}
if [[ -z $tailnet_bin ]]; then
    lap "building kore-tailnet for Linux $arch"
    "$root/scripts/build-tailnet.sh" linux-$arch >"$here/build-tailnet.log" 2>&1 || { tail -5 "$here/build-tailnet.log"; fail "kore-tailnet didn't build"; }
    tailnet_bin=$root/build/release/kore-tailnet-linux-$arch.xz
fi
take "$host_bin" kore-host && take "$tailnet_bin" kore-tailnet || fail "couldn't unpack the binaries"

# 3. Onto the box, beside each other in the scratch folder (never ~/.local/bin).
"${ssh_box[@]}" "umask 077; mkdir -p '$dir/bin'" </dev/null || fail "couldn't make $dir on $box"
for file in kore-host kore-tailnet; do
    "${ssh_box[@]}" "cat > '$dir/bin/$file' && chmod 755 '$dir/bin/$file'" < "$here/$file" || fail "couldn't copy $file"
done
"${ssh_box[@]}" "$remote --version" </dev/null | grep -q '^kore-host ' || fail "that kore-host doesn't run on $box"
lap "copied to $box:$dir/bin"

# 4. KoreNet on, and the test daemon (its own lock, sockets and node: the real one is left alone).
"${ssh_box[@]}" "$remote net on" </dev/null >/dev/null || fail "net on failed"
# Only the daemon goes to the background (a brace group, not a subshell holding ssh's output):
# ssh returns at once with its pid.
pid=$("${ssh_box[@]}" "cd '$dir' && { nohup $remote run > '$dir/run.log' 2>&1 < /dev/null & echo \$!; }" </dev/null)
[[ $pid == <-> ]] || fail "the test daemon didn't start"
lap "test daemon running (pid $pid), its node $name starting"

# 5. The sign-in page, then the node running and kore-host listening on it.
status() { "${ssh_box[@]}" "$remote status" </dev/null 2>/dev/null }
said="" page="" ip=""
end=$(( EPOCHREALTIME + wait_for ))
while (( EPOCHREALTIME < end )); do
    said=$(status)
    "${ssh_box[@]}" "kill -0 $pid" </dev/null 2>/dev/null || { "${ssh_box[@]}" "tail -5 '$dir/run.log'" </dev/null; fail "the test daemon ended"; }
    if [[ -z $page ]]; then
        page=$(print -r -- "$said" | sed -n 's/^sign in  *\(https:[^ ]*\).*/\1/p' | head -1)
        if [[ -n $page ]]; then
            lap "sign in for $name (the one manual step), on this Mac:"
            print "\n    $page\n"
        fi
    fi
    listen=$(print -r -- "$said" | sed -n 's/^listen  *//p' | head -1)
    if [[ $listen == listening*kore-tailnet* ]]; then
        ip=$(print -r -- "$listen" | sed -n 's/^listening \([0-9.]*\).*/\1/p')
        break
    fi
    sleep 2
done
[[ -n $ip ]] || { print -r -- "$said"; fail "not joined within $wait_for s" }
lap "joined: $name runs (Kore's own tailnet), kore-host listening on $ip port $port"
print -r -- "$said" | grep -E '^(tailnet|listen) '

# 6. This Mac reaches it over the tailnet (a connect, closed at once: a probe the box refunds).
if nc -z -G 10 "$ip" $port 2>/dev/null; then
    lap "this Mac reached $name at $ip:$port over the tailnet"
else
    fail "this Mac couldn't reach $ip:$port (is this Mac on the same tailnet?)"
fi

# 7. The box's own kore-host as it was.
real_after=$("${ssh_box[@]}" 'systemctl --user is-active kore-host 2>/dev/null; cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kore-host/kore-host.pid" 2>/dev/null' </dev/null | tr '\n' ' ')
[[ $real_after == $real_before ]] || fail "$box's own kore-host changed: before '$real_before', after '$real_after'"
lap "PASS: $box's own kore-host untouched ($real_after)"

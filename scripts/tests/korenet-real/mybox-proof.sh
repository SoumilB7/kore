#!/bin/zsh
# Each SSH path to a real box (one the owner lent: mybox) as its own case, with its proof in
# $RIG_RUN/proof/mybox-<case>/: the exact commands, the ssh config (`-F`, never ~/.ssh/config),
# the Mac end's lines (korenet-e2e: KoreNet's own code over this Mac's installed Tailscale), the
# box daemon's log, `tailscale status` on both sides before and after, the timings, the verdict.
# The box runs this clone's kore-host isolated (/tmp/kore-e2e, port 47571, no kore-tailnet beside
# it: no tailnet node is ever made); its own kore-host, state, grants and tailscaled are untouched.
#
#   scripts/tests/korenet-real/mybox-proof.sh        (KORE_RIG_HOST_BIN=<a kore-host for the box> skips the build)
#
# Cases: lan (its LAN IP), tailscale-ip, magicdns, proxyjump (through the box to itself). Not run
# here, with why in their folder: tailscale-ssh (the box's Tailscale SSH is off: turning it on
# changes the owner's tailnet settings), own-proxy (this Mac's own node would be a new node in
# the owner's tailnet), port-2222 (the box's sshd listens on 22 only). The rig covers all three.
set -u
zmodload zsh/datetime
here=${0:A:h}
root=${here:h:h:h}
box=${KORE_RIG_BOX:-mybox}
lan=${KORE_RIG_LAN:-192.168.1.11}
bin=${KORE_RIG_HOST_BIN:-}
if [[ -z $bin ]]; then
    # This clone's kore-host for the box's CPU (static musl), niced, after any other swift build.
    arch=$(ssh -o BatchMode=yes $box uname -m) || exit 2
    swift_linux=${KORE_LINUX_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift}
    while pgrep -x swift-build >/dev/null; do sleep 5; done
    nice -n 10 "$root/scripts/one-build.sh" "$swift_linux" build --package-path "$root" --swift-sdk $arch-swift-linux-musl -c release --product kore-host \
        --scratch-path "$root/.build-linux" -Xlinker --strip-all > /dev/null 2>&1 || { print -u2 "mybox-proof: the kore-host build failed"; exit 1; }
    bin="$root/.build-linux/out/Products/Release-staticlinux-$arch/kore-host"
fi
RIG_RUN="${RIG_RUN:-$HOME/Library/Application Support/KoreDev/rig-run}"
ts=/usr/local/bin/tailscale
tmp=$(mktemp -d -t mybox-proof)
trap 'rm -rf $tmp' EXIT
# The box's user and key as `ssh -G` reads them (read only), and its tailnet names.
user=$(ssh -G $box 2>/dev/null | awk '$1=="user"{print $2}')
key=$(ssh -G $box 2>/dev/null | awk '$1=="identityfile"{print $2; exit}')
key=${key/#\~/$HOME}
read tsip dns <<<"$($ts status --json | python3 -I -c 'import sys,json; d=json.load(sys.stdin); p=[p for p in d["Peer"].values() if p["HostName"]=="'$box'"][0]; print(p["TailscaleIPs"][0], p["DNSName"].rstrip("."))')"
typeset -A hostlines
hostlines=(
    lan          "HostName $lan"
    tailscale-ip "HostName $tsip"
    magicdns     "HostName $dns"
    proxyjump    "HostName 127.0.0.1\n  HostKeyAlias $box-loopback\n  ProxyJump $box-lan"
)
fails=0
for case in ${=KORE_RIG_CASES:-lan tailscale-ip magicdns proxyjump}; do
    out="$RIG_RUN/proof/mybox-$case"
    rm -rf "$out"; mkdir -p "$out"
    # A path without spaces: ssh hands `-F` on to ProxyJump's own ssh unquoted.
    cfg=$tmp/$case.ssh_config
    print -r -- "Host $box-$case
  ${hostlines[$case]}
  User $user
Host $box-lan
  HostName $lan
  User $user
Host *
  IdentityFile \"$key\"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $tmp/known_hosts
  ConnectTimeout 8" | sed 's/\\n/\n/g' > $cfg
    cp $cfg $out/ssh_config
    # The clean slate this case starts from (read only; the box's own services must be up).
    ssh -F $cfg -o BatchMode=yes $box-lan "echo \"Clean slate before mybox-$case (\$(date +%T)):\"
[ -e /tmp/kore-e2e ] && echo '  ✘ /tmp/kore-e2e left' || echo '  ✔ no test folder (/tmp/kore-e2e)'
pgrep -f '[/]tmp/kore-e2e/kore-host' >/dev/null && echo '  ✘ a test daemon still runs' || echo '  ✔ no test daemon'
systemctl is-active --quiet tailscaled && echo '  ✔ tailscaled running' || echo '  ✘ tailscaled not running'
systemctl is-active --quiet ssh && echo '  ✔ sshd running' || echo '  ✘ sshd not running'
[ \$(systemctl list-units --all --plain --no-legend 'kore-rig-*' | wc -l) = 0 ] && echo '  ✔ no kore-rig timers or units' || echo '  ✘ kore-rig units left'
for p in slack-watch boxpanel.py; do pgrep -f \$p >/dev/null && echo \"  ✔ \$p running\" || echo \"  ✘ \$p not running\"; done" > $out/reset.txt 2>&1
    $ts status >/dev/null 2>&1 && print "  ✔ this Mac's Tailscale running" >> $out/reset.txt || print "  ✘ this Mac's Tailscale not running" >> $out/reset.txt
    print "  · ssh: -F $out/ssh_config with an empty known_hosts of its own; ~/.ssh/config not read" >> $out/reset.txt
    grep -q '✘' $out/reset.txt && { print "✘ mybox-$case: not a clean slate"; cat $out/reset.txt; (( fails += 1 )); continue; }
    { print "# this Mac"; $ts status; print "\n# $box"; ssh -F $cfg -o BatchMode=yes $box-lan tailscale status; } > $out/tailscale-before.txt 2>&1
    cmd=(env KORE_E2E_TAILNET=1 KORE_E2E_BOX=$box-$case KORE_E2E_SSH_CONFIG=$cfg KORE_E2E_IDLE=5 KORE_E2E_HOST_BIN=$bin KORE_E2E_KEEP_LOG=$out/box-daemon.log nice -n 10 $root/scripts/tests/korenet-e2e.sh)
    print -r -- "${(q-)cmd[@]}" > $out/commands.txt
    start=$EPOCHREALTIME
    "${cmd[@]}" > $out/mac-korenet-e2e.txt 2>&1
    code=$?
    took=$(( EPOCHREALTIME - start ))
    { print "# this Mac"; $ts status; print "\n# $box"; ssh -F $cfg -o BatchMode=yes $box-lan tailscale status; } > $out/tailscale-after.txt 2>&1
    grep -E '^numbers:' $out/mac-korenet-e2e.txt | tr ';' '\n' > $out/timings.txt
    printf 'total %.1fs\n' $took >> $out/timings.txt
    if (( code == 0 )); then
        verdict="✔ mybox-$case ($(printf %.0f $took)s): every check passed over ssh to $box by ${${hostlines[$case]}%%\\n*}"
    else
        verdict="✘ mybox-$case ($(printf %.0f $took)s): $(grep -m3 '^✘' $out/mac-korenet-e2e.txt | tr '\n' ';')"
        (( fails += 1 ))
    fi
    print -r -- $verdict | tee $out/verdict.txt
done
for skipped in "tailscale-ssh:the box's Tailscale SSH is off (RunSSH false); turning it on changes the owner's tailnet settings · covered by the rig's tailscale-ssh" \
               "own-proxy:this Mac's own kore-tailnet node would be a new node in the owner's tailnet · covered by the rig's own-proxy" \
               "port-2222:the box's sshd listens on port 22 only; changing sshd isn't ours · covered by the rig's port-2222"; do
    mkdir -p "$RIG_RUN/proof/mybox-${skipped%%:*}"
    print -r -- "– mybox-${skipped%%:*}: not run: ${skipped#*:}" | tee "$RIG_RUN/proof/mybox-${skipped%%:*}/verdict.txt"
done
(( fails == 0 ))

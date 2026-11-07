#!/bin/zsh
# Ends a real Kore (the storyline host, with scripted chats) while agent control is on and a
# `kore log -f` follows, and checks from outside what's left. First by signal, as an installer
# does: no quit runs, so the socket file stays, and it must do no harm. Then in the same folder
# by quitting Kore's own way: the leftover is replaced, the socket goes, and the follower ends.
set -u
zmodload zsh/datetime
cd "${0:A:h:h:h}" || exit 2

# Short: a socket's path has to fit in 104 bytes.
tmp=$(mktemp -d /tmp/kaq-XXXXXX)
chmod 700 "$tmp"
fails=0
bin="$(swift build --show-bin-path)/kore-command"
sock="$tmp/kore.sock"
check() { # name, condition
    if eval "$2"; then print -r -- "✔ $1"; else print -r -- "✘ $1"; fails=$((fails+1)); fi
}
kore() { KORE_AGENT_SOCKET="$sock" KORE_AGENT_PASS= "$bin" "$@" }
# Waits up to $2 seconds for $1 to be true.
within() {
    local deadline=$(( EPOCHREALTIME + $2 ))
    while ! eval "$1"; do
        (( EPOCHREALTIME > deadline )) && return 1
        sleep 0.1
    done
}

# Starts a host for $1 (quit or signal), then a follower of its chat.
start() {
    rm -f "$tmp/ready"
    KORE_AGENT_QUIT_DIR="$tmp" KORE_AGENT_QUIT_HOW=$1 \
        scripts/storylines.sh --name AgentQuitPath --provider claude --out "$tmp/out-$1" >"$tmp/run-$1.log" 2>&1 &
    runner=$!
    if ! within '[[ -s $tmp/ready ]]' 300; then
        print -r -- "✘ $1: Kore never got ready"
        exit 1
    fi
    read -r host chat < "$tmp/ready"
    kore log "$chat" -f > "$tmp/follow-$1" 2>&1 &
    follower=$!
}
ended() { ! kill -0 $1 2>/dev/null }

print "== by signal"
start signal
within '[[ -S $sock ]]' 5
check "the socket is there while Kore runs" '[[ -S $sock ]]'
check "the follower is following" '! ended $follower'
kill -TERM $host
check "Kore ended" 'within "ended $host" 10'
check "the follower ended with it" 'within "ended $follower" 3'
check "the socket file is left behind" '[[ -e $sock ]]'
s=$EPOCHREALTIME
out=$(kore ls 2>&1)
code=$?
ms=$(( (EPOCHREALTIME - s) * 1000 ))
check "kore ls at the leftover: exit 5 at once ($(printf %.0f $ms) ms)" '(( code == 5 && ms < 500 ))'
wait $runner 2>/dev/null

print "== by quitting"
start quit
check "the follower reached the new socket and Kore quit" 'within "[[ -e $tmp/quitting ]]" 60'
check "Kore ended" 'within "ended $host" 20'
check "the follower ended" 'within "ended $follower" 3'
wait $follower
code=$?
check "the follower exited 0 (it was $code)" '(( code == 0 ))'
check "no socket file" '[[ ! -e $sock ]]'
out=$(kore ls 2>&1)
code=$?
check "kore ls: exit 5" '(( code == 5 ))'
wait $runner 2>/dev/null

(( fails == 0 )) && { print "all passed"; rm -rf "$tmp"; exit 0 }
print "$fails failed; left $tmp"
exit 1

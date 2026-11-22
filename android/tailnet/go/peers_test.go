package tailnet

import (
	"strings"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

// The online set WaitPeers compares: only online peers, sorted, so one changing order or an
// offline peer coming and going reads the same.
func TestOnlineKeysIsTheSortedOnlineSet(t *testing.T) {
	a, b, c := key.NewNode().Public(), key.NewNode().Public(), key.NewNode().Public()
	st := &ipnstate.Status{Peer: map[key.NodePublic]*ipnstate.PeerStatus{
		a: {PublicKey: a, Online: true},
		b: {PublicKey: b, Online: false},
		c: {PublicKey: c, Online: true},
	}}
	got := onlineKeys(st)
	want := []string{a.String(), c.String()}
	if want[0] > want[1] {
		want[0], want[1] = want[1], want[0]
	}
	if got != strings.Join(want, ",") {
		t.Fatalf("online keys %q, want %q", got, strings.Join(want, ","))
	}
	if onlineKeys(&ipnstate.Status{}) != "" {
		t.Fatal("no peers should be empty")
	}
}

// Before the node starts, both say nothing and never block.
func TestWaitPeersBeforeStartReturnsAtOnce(t *testing.T) {
	if OnlinePeers() != "" {
		t.Fatal("not started: no peers")
	}
	if WaitPeers("x", 60_000) != "x" {
		t.Fatal("not started: the known set back at once")
	}
}

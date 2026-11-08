//go:build kore_live

package tailnet

// A phone's tailnet login has to survive an app update, whatever the update changes in how the
// shim is built (its ts_omit tags; v0.3.0 → v0.3.1 lost it). Run in two builds over one state dir,
// against one control server (livectl), by scripts/check.sh:
//
//	KORE_LIVE_PHASE=login  with the old build's tags: Start, come up Running, keep the node key
//	KORE_LIVE_PHASE=check  with the new build's tags: Start on the same dir; Running again, same key,
//	                       and never NeedsLogin on the way.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// plain seals nothing: the test is about tsnet's own state across builds, not the Keystore.
type plain struct{}

func (plain) Seal(b []byte) ([]byte, error) { return append([]byte(nil), b...), nil }
func (plain) Open(b []byte) ([]byte, error) { return append([]byte(nil), b...), nil }

func TestLiveStateAcrossBuilds(t *testing.T) {
	url, dir, phase := os.Getenv("KORE_LIVE_CONTROL"), os.Getenv("KORE_LIVE_DIR"), os.Getenv("KORE_LIVE_PHASE")
	if url == "" || dir == "" || phase == "" {
		t.Skip("run by check.sh with KORE_LIVE_CONTROL, KORE_LIVE_DIR and KORE_LIVE_PHASE")
	}
	controlURL = url
	if err := Start(dir, "kore-pixel-6-7f3a", plain{}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer Stop()
	deadline := time.Now().Add(60 * time.Second)
	for State() != "Running" {
		if phase == "check" && State() == "NeedsLogin" {
			t.Fatalf("the update lost the login: NeedsLogin on the kept state")
		}
		if time.Now().After(deadline) {
			t.Fatalf("not Running after 60 s: %s", State())
		}
		time.Sleep(100 * time.Millisecond)
	}
	var self struct{ NodeKey string `json:"nodeKey"` }
	if err := json.Unmarshal([]byte(Self()), &self); err != nil || self.NodeKey == "" {
		t.Fatalf("no self: %v", err)
	}
	kept := filepath.Join(dir, "nodekey.txt")
	switch phase {
	case "login":
		if err := os.WriteFile(kept, []byte(self.NodeKey), 0o600); err != nil {
			t.Fatal(err)
		}
	case "check":
		was, err := os.ReadFile(kept)
		if err != nil {
			t.Fatal(err)
		}
		if string(was) != self.NodeKey {
			t.Fatalf("a new node after the update: %s, was %s", self.NodeKey, was)
		}
	}
}

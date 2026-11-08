package tailnet

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"

	"tailscale.com/ipn"
)

// TestBridge: socketpair fd <-> TCP echo, with half-close passed on.
func TestBridge(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		c, _ := ln.Accept()
		io.Copy(c, c)
		c.(*net.TCPConn).CloseWrite()
	}()
	tc, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	fd, err := bridge(tc)
	if err != nil {
		t.Fatal(err)
	}
	f := os.NewFile(uintptr(fd), "kotlin-side")
	c, err := net.FileConn(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	c.Write([]byte("hello kore"))
	c.(*net.UnixConn).CloseWrite()
	got, _ := io.ReadAll(c)
	if string(got) != "hello kore" {
		t.Fatalf("got %q", got)
	}
}

func TestSetInterfaces(t *testing.T) {
	err := SetInterfaces(`[{"name":"wlan0","index":30,"mtu":1500,"up":true,"broadcast":true,"multicast":true,"addrs":["192.168.1.5/24","fe80::1/64","bad"],"default":true,"gateway":"192.168.1.1"}]`)
	if err != nil {
		t.Fatal(err)
	}
	ifs, err := netInterfacesForTest()
	if err != nil || len(ifs) != 1 || len(ifs[0].AltAddrs) != 2 || !ifs[0].IsUp() {
		t.Fatalf("ifs=%+v err=%v", ifs, err)
	}
}

// xor stands in for the Keystore: what's on disk is never the plain state.
type xor struct{}

func (xor) Seal(p []byte) ([]byte, error) { return flip(p), nil }
func (xor) Open(s []byte) ([]byte, error) {
	if len(s) == 0 {
		return nil, errors.New("empty")
	}
	return flip(s), nil
}
func flip(b []byte) []byte {
	o := make([]byte, len(b))
	for i := range b {
		o[i] = b[i] ^ 0x5a
	}
	return o
}

func TestSealedStoreKeepsStateSealed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.sealed")
	s, err := openSealedStore(path, xor{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ReadState("k"); err != ipn.ErrStateNotExist {
		t.Fatalf("empty store: %v", err)
	}
	secret := []byte(`{"PrivateNodeKey":"privkey:abc"}`)
	if err := s.WriteState("k", secret); err != nil {
		t.Fatal(err)
	}
	disk, _ := os.ReadFile(path)
	if bytes.Contains(disk, []byte("privkey")) {
		t.Fatal("plain state on disk")
	}
	again, _ := openSealedStore(path, xor{})
	got, err := again.ReadState("k")
	if err != nil || !bytes.Equal(got, secret) {
		t.Fatalf("reopened: %q %v", got, err)
	}
	if err := again.WriteState("k", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := again.ReadState("k"); err != ipn.ErrStateNotExist {
		t.Fatal("deleted state still there")
	}
}

type refuse struct{ xor }

func (refuse) Open([]byte) ([]byte, error) { return nil, errors.New("key gone") }

func TestALostKeyStartsSignedOut(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.sealed")
	os.WriteFile(path, []byte("sealed by a key that's gone"), 0o600)
	s, err := openSealedStore(path, refuse{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ReadState("k"); err != ipn.ErrStateNotExist {
		t.Fatal("state from a lost key")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("unreadable state kept")
	}
}

func TestQuietLogfDropsTheSignInURL(t *testing.T) {
	verbose = true
	defer func() { verbose = false }()
	r, w, _ := os.Pipe()
	old := os.Stderr
	os.Stderr = w
	quietLogf("To authenticate, go to: %s", "https://login.tailscale.com/a/123")
	quietLogf("AuthURL is %s", "https://login.tailscale.com/a/123")
	quietLogf("url %s", "https://login.tailscale.com/a/123")
	quietLogf("plain %d", 1)
	w.Close()
	os.Stderr = old
	out, _ := io.ReadAll(r)
	if bytes.Contains(out, []byte("/a/")) || !bytes.Contains(out, []byte("plain 1")) {
		t.Fatalf("logged %q", out)
	}
}

func TestLogsGetAFolderInsideTheState(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TS_LOGS_DIR", "")
	if err := logsHere(dir); err != nil {
		t.Fatal(err)
	}
	got := os.Getenv("TS_LOGS_DIR")
	if got != filepath.Join(dir, "logs") {
		t.Fatalf("TS_LOGS_DIR = %q", got)
	}
	if fi, err := os.Stat(got); err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Fatalf("logs folder: %v %v", fi, err)
	}
}

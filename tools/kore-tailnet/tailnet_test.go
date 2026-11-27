package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/ipn"
)

func key(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func TestStoreSealsAndReopens(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.sealed")
	s, err := openStore(path, key(1))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ReadState("_machinekey"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("empty store read: %v", err)
	}
	secret := []byte("privkey:0123456789abcdef")
	if err := s.WriteState("_machinekey", secret); err != nil {
		t.Fatal(err)
	}
	s.WriteState("gone", []byte("x"))
	s.WriteState("gone", nil)
	raw, _ := os.ReadFile(path)
	if bytes.Contains(raw, secret) || bytes.Contains(raw, []byte("_machinekey")) {
		t.Fatal("state on disk is readable")
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode().Perm())
	}
	again, err := openStore(path, key(1))
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := again.ReadState("_machinekey"); !bytes.Equal(got, secret) {
		t.Fatalf("reopened %q", got)
	}
	if _, err := again.ReadState("gone"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatal("deleted key came back")
	}
	if _, err := openStore(path, key(2)); !errors.Is(err, errWrongKey) {
		t.Fatalf("wrong key: %v", err)
	}
	raw[len(raw)-1] ^= 1
	os.WriteFile(path, raw, 0o600)
	if _, err := openStore(path, key(1)); !errors.Is(err, errWrongKey) {
		t.Fatalf("tampered: %v", err)
	}
	if _, err := openStore(path, key(1)[:16]); err == nil {
		t.Fatal("short key taken")
	}
	if names, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".state-*")); len(names) != 0 {
		t.Fatalf("temp files left: %v", names)
	}
}

func pair(t *testing.T) (*net.UnixConn, *net.UnixConn) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	conn := func(fd int) *net.UnixConn {
		f := os.NewFile(uintptr(fd), "pair")
		defer f.Close()
		c, err := net.FileConn(f)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return c.(*net.UnixConn)
	}
	return conn(fds[0]), conn(fds[1])
}

// recvMsg is the Swift reader's side: the length with any descriptor, then the body.
func recvMsg(t *testing.T, c *net.UnixConn) (map[string]any, int) {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	hdr, oob := make([]byte, 4), make([]byte, syscall.CmsgSpace(4))
	n, oobn, _, _, err := c.ReadMsgUnix(hdr, oob)
	if err != nil || n != 4 {
		t.Fatalf("header: %d %v", n, err)
	}
	fd := -1
	if oobn > 0 {
		msgs, _ := syscall.ParseSocketControlMessage(oob[:oobn])
		fds, _ := syscall.ParseUnixRights(&msgs[0])
		fd = fds[0]
	}
	body := make([]byte, binary.BigEndian.Uint32(hdr))
	if _, err := io.ReadFull(c, body); err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	return m, fd
}

func TestFraming(t *testing.T) {
	a, b := pair(t)
	if err := writeMsg(a, map[string]any{"ok": true}, -1); err != nil {
		t.Fatal(err)
	}
	if got, err := readMsg(b); err != nil || string(got) != `{"ok":true}` {
		t.Fatalf("%q %v", got, err)
	}
	a.Write([]byte{0x7f, 0xff, 0xff, 0xff})
	if _, err := readMsg(b); !errors.Is(err, errTooBig) {
		t.Fatalf("oversize: %v", err)
	}
	a.Write([]byte{0, 0, 0, 9, '{'})
	a.CloseWrite()
	if _, err := readMsg(b); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("short body: %v", err)
	}
	if _, err := readMsg(b); !errors.Is(err, io.EOF) {
		t.Fatalf("clean end: %v", err)
	}
}

func TestDescriptorRidesWithLength(t *testing.T) {
	a, b := pair(t)
	x, y := pair(t)
	f, _ := x.File()
	defer f.Close()
	if err := writeMsg(a, okReply, int(f.Fd())); err != nil {
		t.Fatal(err)
	}
	m, fd := recvMsg(t, b)
	if m["ok"] != true || fd < 0 {
		t.Fatalf("%v %d", m, fd)
	}
	defer syscall.Close(fd)
	syscall.Write(fd, []byte("hi"))
	got := make([]byte, 2)
	y.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(y, got); err != nil || string(got) != "hi" {
		t.Fatalf("%q %v", got, err)
	}
}

func TestHeldDescriptorsCloseOnAckInOrder(t *testing.T) {
	var h heldFDs
	_, b1 := pair(t)
	_, b2 := pair(t)
	f1, _ := b1.File()
	f2, _ := b2.File()
	fd1, fd2 := int(f1.Fd()), int(f2.Fd())
	d1, _ := syscall.Dup(fd1)
	d2, _ := syscall.Dup(fd2)
	f1.Close()
	f2.Close()
	h.push(d1)
	h.push(d2)
	h.ack()
	if _, err := unix.FcntlInt(uintptr(d1), unix.F_GETFD, 0); err == nil {
		t.Fatal("first held descriptor still open after its ack")
	}
	if _, err := unix.FcntlInt(uintptr(d2), unix.F_GETFD, 0); err != nil {
		t.Fatal("second closed early")
	}
	h.closeAll()
	if _, err := unix.FcntlInt(uintptr(d2), unix.F_GETFD, 0); err == nil {
		t.Fatal("closeAll left one open")
	}
}

func TestPeerUID(t *testing.T) {
	a, _ := pair(t)
	if uid, err := peerUID(a); err != nil || uid != os.Getuid() {
		t.Fatalf("%d %v", uid, err)
	}
}

// fakeNode is tsnet's stand-in: canned answers, a pipe per dial, one connection per listen.
type fakeNode struct {
	masks  chan uint64
	dialed chan net.Conn
	closed chan struct{}
	// Set by logout (read after its reply).
	loggedOut atomic.Bool
}

func newFake() *fakeNode {
	return &fakeNode{masks: make(chan uint64, 1), dialed: make(chan net.Conn, 1), closed: make(chan struct{})}
}

func (f *fakeNode) Status(context.Context) (any, error) {
	return map[string]any{"BackendState": "NeedsLogin", "AuthURL": "https://login.example/a/x"}, nil
}
func (f *fakeNode) WhoIs(_ context.Context, addr string) (any, error) {
	return map[string]any{"Node": map[string]any{"Name": addr}}, nil
}
func (f *fakeNode) Watch(ctx context.Context, mask uint64, each func(any) error) error {
	f.masks <- mask
	each(map[string]any{"State": 2})
	each(map[string]any{"State": 6})
	<-ctx.Done()
	return nil
}
func (f *fakeNode) Listen(port int) (net.Listener, error) {
	ln := &oneListener{conns: make(chan net.Conn, 1), done: make(chan struct{})}
	mine, theirs := net.Pipe()
	ln.conns <- mine
	f.dialed <- theirs
	return ln, nil
}
func (f *fakeNode) Dial(_ context.Context, addr string, port int) (net.Conn, error) {
	mine, theirs := net.Pipe()
	f.dialed <- theirs
	return mine, nil
}
func (f *fakeNode) Logout(context.Context) error { f.loggedOut.Store(true); return nil }
func (f *fakeNode) Close() error                 { close(f.closed); return nil }

type oneListener struct {
	conns chan net.Conn
	done  chan struct{}
}

func (l *oneListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return &remoteConn{c}, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}
func (l *oneListener) Close() error   { close(l.done); return nil }
func (l *oneListener) Addr() net.Addr { return &net.TCPAddr{} }

type remoteConn struct{ net.Conn }

func (remoteConn) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.ParseIP("fd7a:115c:a1e0::9"), Port: 51000}
}

type harness struct {
	t    *testing.T
	path string
	srv  *server
	node *fakeNode
}

func serveFake(t *testing.T, uid int, startErr error) *harness {
	dir, err := os.MkdirTemp("", "kt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	h := &harness{t: t, path: filepath.Join(dir, "s"), node: newFake()}
	h.srv = newServer(uid, func(k []byte) (node, error) {
		if startErr != nil {
			return nil, startErr
		}
		return h.node, nil
	})
	ln, err := listenSocket(h.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	if info, _ := os.Stat(h.path); info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v", info.Mode().Perm())
	}
	go h.srv.serve(ln)
	return h
}

func (h *harness) ask(req map[string]any) (*net.UnixConn, map[string]any, int) {
	h.t.Helper()
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: h.path, Net: "unix"})
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { c.Close() })
	if req["v"] == nil {
		req["v"] = 1
	}
	if err := writeMsg(c, req, -1); err != nil {
		h.t.Fatal(err)
	}
	m, fd := recvMsg(h.t, c)
	return c, m, fd
}

func (h *harness) start() *net.UnixConn {
	c, m, _ := h.ask(map[string]any{"op": "start", "key": base64.StdEncoding.EncodeToString(key(7))})
	if m["ok"] != true {
		h.t.Fatalf("start: %v", m)
	}
	return c
}

func (h *harness) exitCode() int {
	select {
	case code := <-h.srv.exit:
		return code
	case <-time.After(5 * time.Second):
		h.t.Fatal("no exit")
		return -1
	}
}

func TestRefusals(t *testing.T) {
	other := serveFake(t, os.Getuid()+1, nil)
	if _, m, _ := other.ask(map[string]any{"op": "status"}); m["error"] != "not this user" {
		t.Fatalf("other uid: %v", m)
	}
	h := serveFake(t, os.Getuid(), nil)
	for req, want := range map[string]string{
		`{"op":"status"}`:          "not started",
		`{"v":2,"op":"status"}`:    "version 1 only",
		`{"op":"start","key":"x"}`: "the state key must be 32 bytes, base64",
	} {
		var m map[string]any
		json.Unmarshal([]byte(req), &m)
		if _, got, _ := h.ask(m); got["error"] != want {
			t.Errorf("%s: %v", req, got)
		}
	}
	if code := h.exitCode(); code != 2 {
		t.Fatalf("bad key exit %d", code)
	}
	failing := serveFake(t, os.Getuid(), errWrongKey)
	if _, m, _ := failing.ask(map[string]any{"op": "start", "key": base64.StdEncoding.EncodeToString(key(1))}); m["error"] != errWrongKey.Error() {
		t.Fatalf("wrong key: %v", m)
	}
}

func TestStatusWhoisThenOwnerGoneExits(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	owner := h.start()
	if _, m, _ := h.ask(map[string]any{"op": "start", "key": base64.StdEncoding.EncodeToString(key(7))}); m["error"] != "started already" {
		t.Fatalf("second start: %v", m)
	}
	_, m, _ := h.ask(map[string]any{"op": "status"})
	if st := m["status"].(map[string]any); st["BackendState"] != "NeedsLogin" || st["AuthURL"] == "" {
		t.Fatalf("status: %v", m)
	}
	if _, m, _ := h.ask(map[string]any{"op": "whois", "addr": "100.64.0.1"}); m["whois"] == nil {
		t.Fatalf("whois: %v", m)
	}
	owner.Close()
	if code := h.exitCode(); code != 0 {
		t.Fatalf("exit %d", code)
	}
}

func TestStopClosesTheNode(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	h.start()
	if _, m, _ := h.ask(map[string]any{"op": "stop"}); m["ok"] != true {
		t.Fatalf("stop: %v", m)
	}
	if code := h.exitCode(); code != 0 {
		t.Fatalf("exit %d", code)
	}
	select {
	case <-h.node.closed:
	default:
		t.Fatal("node still open")
	}
}

func TestWatchDropsEngineAndEndsOnClose(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	h.start()
	c, m, _ := h.ask(map[string]any{"op": "watch", "mask": 49155})
	if m["notify"].(map[string]any)["State"] != 2.0 {
		t.Fatalf("first: %v", m)
	}
	if m, _ := recvMsg(t, c); m["notify"].(map[string]any)["State"] != 6.0 {
		t.Fatalf("second: %v", m)
	}
	if mask := <-h.node.masks; mask != 49154 {
		t.Fatalf("mask %d", mask)
	}
	c.Close()
}

func TestDialHandsOverAWorkingConnection(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	h.start()
	if _, m, _ := h.ask(map[string]any{"op": "dial", "addr": "10.0.0.1", "port": 1}); m["error"] != "not a tailnet address" {
		t.Fatalf("lan dial: %v", m)
	}
	c, m, fd := h.ask(map[string]any{"op": "dial", "addr": "100.104.65.22", "port": 47470})
	if m["ok"] != true || fd < 0 {
		t.Fatalf("dial: %v %d", m, fd)
	}
	defer syscall.Close(fd)
	c.Close()
	peer := <-h.node.dialed
	syscall.Write(fd, []byte("hello"))
	got := make([]byte, 5)
	if _, err := io.ReadFull(peer, got); err != nil || string(got) != "hello" {
		t.Fatalf("%q %v", got, err)
	}
}

func TestListenHandsOffEachConnectionUntilAcked(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	h.start()
	c, m, _ := h.ask(map[string]any{"op": "listen", "port": 47470})
	if m["ok"] != true {
		t.Fatalf("listen: %v", m)
	}
	m, fd := recvMsg(t, c)
	if m["conn"].(map[string]any)["remote"] != "[fd7a:115c:a1e0::9]:51000" || fd < 0 {
		t.Fatalf("conn: %v %d", m, fd)
	}
	defer syscall.Close(fd)
	writeMsg(c, map[string]any{"v": 1, "op": "ack"}, -1)
	peer := <-h.node.dialed
	go peer.Write([]byte("hi"))
	got := make([]byte, 2)
	if _, err := syscall.Read(fd, got); err != nil || string(got) != "hi" {
		t.Fatalf("%q %v", got, err)
	}
}

func TestLogoutSignsOutAndKeepsRunning(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	if _, m, _ := h.ask(map[string]any{"op": "logout"}); m["error"] != "not started" {
		t.Fatalf("logout before start: %v", m)
	}
	h.start()
	if _, m, _ := h.ask(map[string]any{"op": "logout"}); m["ok"] != true {
		t.Fatalf("logout: %v", m)
	}
	if !h.node.loggedOut.Load() {
		t.Fatal("node not logged out")
	}
	// Still serving: a status after it answers.
	if _, m, _ := h.ask(map[string]any{"op": "status"}); m["ok"] != true {
		t.Fatalf("status after logout: %v", m)
	}
	select {
	case code := <-h.srv.exit:
		t.Fatalf("exited %d", code)
	default:
	}
}

// refs is how many descriptors this process has open on fd's socket (its device and inode).
func refs(t *testing.T, fd int) int {
	t.Helper()
	var want unix.Stat_t
	if err := unix.Fstat(fd, &want); err != nil {
		t.Fatal(err)
	}
	n := 0
	for i := 0; i < 512; i++ {
		var st unix.Stat_t
		if unix.Fstat(i, &st) == nil && st.Mode&unix.S_IFMT == unix.S_IFSOCK && st.Ino == want.Ino && st.Ino != 0 {
			n++
		}
	}
	return n
}

func settles(want int, count func() int) bool {
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(2 * time.Millisecond) {
		if count() == want {
			return true
		}
	}
	return false
}

// macOS may flush a socket whose last reference is in flight (the pipe broker did, 2026-11-25):
// the helper keeps its copy until the client has the descriptor, for a dial and for a listen.
func TestHelperHoldsEachDescriptorUntilTheClientHasIt(t *testing.T) {
	h := serveFake(t, os.Getuid(), nil)
	h.start()
	c, m, fd := h.ask(map[string]any{"op": "dial", "addr": "100.104.65.22", "port": 47470})
	if m["ok"] != true || fd < 0 {
		t.Fatalf("dial: %v %d", m, fd)
	}
	defer syscall.Close(fd)
	time.Sleep(50 * time.Millisecond)
	if n := refs(t, fd); n != 2 {
		t.Fatalf("dial: %d copies before the client let go, want ours and the helper's", n)
	}
	c.Close()
	if !settles(1, func() int { return refs(t, fd) }) {
		t.Fatal("dial: the helper's copy stayed open")
	}

	l := serveFake(t, os.Getuid(), nil)
	l.start()
	lc, _, _ := l.ask(map[string]any{"op": "listen", "port": 47470})
	_, got := recvMsg(t, lc)
	if got < 0 {
		t.Fatal("listen: no descriptor")
	}
	defer syscall.Close(got)
	time.Sleep(50 * time.Millisecond)
	if n := refs(t, got); n != 2 {
		t.Fatalf("listen: %d copies before the ack", n)
	}
	writeMsg(lc, map[string]any{"v": 1, "op": "ack"}, -1)
	if !settles(1, func() int { return refs(t, got) }) {
		t.Fatal("listen: the helper's copy stayed open after the ack")
	}
}

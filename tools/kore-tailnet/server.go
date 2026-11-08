package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"

	"tailscale.com/net/tsaddr"
)

// node is what the socket serves: tsnet in the program, a fake in tests.
type node interface {
	Status(ctx context.Context) (any, error)
	WhoIs(ctx context.Context, addr string) (any, error)
	// Watch calls each with every IPN bus message until ctx ends or each fails.
	Watch(ctx context.Context, mask uint64, each func(any) error) error
	Listen(port int) (net.Listener, error)
	Dial(ctx context.Context, addr string, port int) (net.Conn, error)
	Close() error
}

type request struct {
	V    int    `json:"v"`
	Op   string `json:"op"`
	Addr string `json:"addr"`
	Port int    `json:"port"`
	Mask uint64 `json:"mask"`
	Key  string `json:"key"`
}

// server answers the TailnetSidecar protocol (Sources/Tailnet/TailnetSidecar.swift). Nothing
// runs until a `start` brings the node up; the connection that sent it is the owner, and the
// program ends when the owner goes away or anyone sends `stop`.
type server struct {
	uid   int
	start func(key []byte) (node, error)

	mu      sync.Mutex
	node    node
	started bool
	exit    chan int
	once    sync.Once
}

func newServer(uid int, start func(key []byte) (node, error)) *server {
	return &server{uid: uid, start: start, exit: make(chan int, 1)}
}

// finish asks main to end with code; the first ask wins.
func (s *server) finish(code int) {
	s.once.Do(func() { s.exit <- code })
}

// shutdown closes the node; safe to call more than once.
func (s *server) shutdown() {
	s.mu.Lock()
	n := s.node
	s.node = nil
	s.mu.Unlock()
	if n != nil {
		n.Close()
	}
}

func (s *server) current() node {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.node
}

func (s *server) serve(ln *net.UnixListener) {
	for {
		c, err := ln.AcceptUnix()
		if err != nil {
			return
		}
		go s.handle(c)
	}
}

func peerUID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return -1, err
	}
	uid, uerr := -1, error(nil)
	if err := raw.Control(func(fd uintptr) { uid, uerr = peerUIDFD(int(fd)) }); err != nil {
		return -1, err
	}
	return uid, uerr
}

func (s *server) handle(c *net.UnixConn) {
	owner := false
	defer func() {
		if !owner {
			c.Close()
		}
	}()
	if uid, err := peerUID(c); err != nil || uid != s.uid {
		writeMsg(c, refusal("not this user"), -1)
		return
	}
	body, err := readMsg(c)
	if err != nil {
		return
	}
	var req request
	if err := json.Unmarshal(body, &req); err != nil {
		writeMsg(c, refusal("bad request"), -1)
		return
	}
	if req.V != 1 {
		writeMsg(c, refusal("version 1 only"), -1)
		return
	}
	switch req.Op {
	case "start":
		owner = s.handleStart(c, req)
		return
	case "stop":
		s.shutdown()
		writeMsg(c, okReply, -1)
		s.finish(0)
		return
	}
	n := s.current()
	if n == nil {
		writeMsg(c, refusal("not started"), -1)
		return
	}
	switch req.Op {
	case "status":
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		st, err := n.Status(ctx)
		reply(c, "status", st, err)
	case "whois":
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		who, err := n.WhoIs(ctx, req.Addr)
		reply(c, "whois", who, err)
	case "watch":
		s.handleWatch(c, n, req.Mask)
	case "listen":
		s.handleListen(c, n, req.Port)
	case "dial":
		s.handleDial(c, n, req.Addr, req.Port)
	default:
		writeMsg(c, refusal("unknown op"), -1)
	}
}

func reply(c *net.UnixConn, field string, v any, err error) {
	if err != nil {
		writeMsg(c, refusal(err.Error()), -1)
		return
	}
	writeMsg(c, map[string]any{"ok": true, field: v}, -1)
}

// handleStart brings the node up with the state key; true when c became the owner.
func (s *server) handleStart(c *net.UnixConn, req request) bool {
	s.mu.Lock()
	if s.started {
		s.mu.Unlock()
		writeMsg(c, refusal("started already"), -1)
		return false
	}
	s.started = true
	s.mu.Unlock()
	key, err := base64.StdEncoding.DecodeString(req.Key)
	if err != nil || len(key) != 32 {
		writeMsg(c, refusal("the state key must be 32 bytes, base64"), -1)
		s.finish(2)
		return false
	}
	n, err := s.start(key)
	clear(key)
	if err != nil {
		writeMsg(c, refusal(err.Error()), -1)
		s.finish(2)
		return false
	}
	s.mu.Lock()
	s.node = n
	s.mu.Unlock()
	if writeMsg(c, okReply, -1) != nil {
		c.Close()
		s.finish(0)
		return true
	}
	go func() {
		defer c.Close()
		for {
			body, err := readMsg(c)
			if err != nil {
				s.finish(0)
				return
			}
			var next request
			if json.Unmarshal(body, &next) == nil && next.Op == "stop" {
				s.shutdown()
				writeMsg(c, okReply, -1)
				s.finish(0)
				return
			}
		}
	}()
	return true
}

// untilClosed reads (and drops, apart from acks) whatever the client sends, then cancels:
// a client ends a watch, listen or dial by closing its connection.
func untilClosed(c *net.UnixConn, cancel func(), held *heldFDs) {
	defer cancel()
	for {
		body, err := readMsg(c)
		if err != nil {
			return
		}
		var req request
		if held != nil && json.Unmarshal(body, &req) == nil && req.Op == "ack" {
			held.ack()
		}
	}
}

// engineUpdates is ipn.NotifyWatchEngineUpdates: a message every 2 s, never forwarded.
const engineUpdates = 1

func (s *server) handleWatch(c *net.UnixConn, n node, mask uint64) {
	ctx, cancel := context.WithCancel(context.Background())
	go untilClosed(c, cancel, nil)
	err := n.Watch(ctx, mask&^engineUpdates, func(msg any) error {
		return writeMsg(c, map[string]any{"notify": msg}, -1)
	})
	if err != nil && ctx.Err() == nil {
		writeMsg(c, refusal(err.Error()), -1)
	}
	cancel()
}

func (s *server) handleListen(c *net.UnixConn, n node, port int) {
	if port < 1 || port > 65535 {
		writeMsg(c, refusal("bad port"), -1)
		return
	}
	ln, err := n.Listen(port)
	if err != nil {
		writeMsg(c, refusal(err.Error()), -1)
		return
	}
	held := &heldFDs{}
	defer held.closeAll()
	if writeMsg(c, okReply, -1) != nil {
		ln.Close()
		return
	}
	go untilClosed(c, func() { ln.Close() }, held)
	for {
		tc, err := ln.Accept()
		if err != nil {
			return
		}
		remote := tc.RemoteAddr().String()
		fd, err := bridge(tc)
		if err != nil {
			continue
		}
		if writeMsg(c, map[string]any{"conn": map[string]string{"remote": remote}}, fd) != nil {
			closeFD(fd)
			ln.Close()
			return
		}
		held.push(fd)
	}
}

func (s *server) handleDial(c *net.UnixConn, n node, addr string, port int) {
	ip, err := netip.ParseAddr(addr)
	if err != nil || !tsaddr.IsTailscaleIP(ip) {
		writeMsg(c, refusal("not a tailnet address"), -1)
		return
	}
	if port < 1 || port > 65535 {
		writeMsg(c, refusal("bad port"), -1)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	tc, err := n.Dial(ctx, ip.String(), port)
	cancel()
	if err != nil {
		writeMsg(c, refusal(err.Error()), -1)
		return
	}
	fd, err := bridge(tc)
	if err != nil {
		writeMsg(c, refusal(err.Error()), -1)
		return
	}
	defer closeFD(fd)
	if writeMsg(c, okReply, fd) != nil {
		return
	}
	// The client closes this connection once it holds the descriptor: that's the ack.
	io.Copy(io.Discard, c)
}

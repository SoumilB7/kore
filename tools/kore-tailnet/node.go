package main

import (
	"context"
	"fmt"
	"net"
	"strconv"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

// tsNode is the real node: tsnet with its state sealed in dir.
type tsNode struct {
	srv  *tsnet.Server
	lc   *local.Client
	stop context.CancelFunc
}

func startTSNet(dir, hostname string, ephemeral bool, key []byte, logf logger.Logf) (node, error) {
	store, err := openStore(dir+"/state.sealed", key)
	if err != nil {
		return nil, err
	}
	srv := &tsnet.Server{Dir: dir, Hostname: hostname, Ephemeral: ephemeral, Store: store, Logf: logf, UserLogf: quiet(logf)}
	if control := testControlURL(); control != "" {
		srv.ControlURL = control
	}
	if err := srv.Start(); err != nil {
		srv.Close()
		return nil, fmt.Errorf("tsnet: %w", err)
	}
	lc, err := srv.LocalClient()
	if err != nil {
		srv.Close()
		return nil, err
	}
	ctx, stop := context.WithCancel(context.Background())
	n := &tsNode{srv: srv, lc: lc, stop: stop}
	offer := &signInOffer{grace: signInGrace, ask: lc.StartLoginInteractive}
	if st, err := lc.Status(ctx); err == nil {
		offer.started(st.BackendState == ipn.NeedsLogin.String())
	}
	go offer.watch(ctx, n.bus)
	return n, nil
}

// bus hands each with every state and sign-in page change, from the current state on.
func (n *tsNode) bus(ctx context.Context, each func(*ipn.Notify) error) error {
	w, err := n.lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		return err
	}
	defer w.Close()
	for {
		msg, err := w.Next()
		if err != nil {
			return err
		}
		if err := each(&msg); err != nil {
			return err
		}
	}
}

// quiet keeps tsnet's user lines (the auth URL among them) off stderr unless logging is on.
func quiet(logf logger.Logf) logger.Logf {
	if logf == nil {
		return logger.Discard
	}
	return logf
}

func (n *tsNode) Status(ctx context.Context) (any, error) { return n.lc.Status(ctx) }

func (n *tsNode) WhoIs(ctx context.Context, addr string) (any, error) {
	return n.lc.WhoIs(ctx, addr)
}

func (n *tsNode) Watch(ctx context.Context, mask uint64, each func(any) error) error {
	w, err := n.lc.WatchIPNBus(ctx, ipn.NotifyWatchOpt(mask))
	if err != nil {
		return err
	}
	defer w.Close()
	for {
		msg, err := w.Next()
		if err != nil {
			return err
		}
		if err := each(&msg); err != nil {
			return err
		}
	}
}

func (n *tsNode) Listen(port int) (net.Listener, error) {
	return n.srv.Listen("tcp", ":"+strconv.Itoa(port))
}

func (n *tsNode) Dial(ctx context.Context, addr string, port int) (net.Conn, error) {
	return n.srv.Dial(ctx, "tcp", net.JoinHostPort(addr, strconv.Itoa(port)))
}

func (n *tsNode) Logout(ctx context.Context) error { return n.lc.Logout(ctx) }

func (n *tsNode) Close() error {
	n.stop()
	return n.srv.Close()
}

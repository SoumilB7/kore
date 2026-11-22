package main

import (
	"context"
	"sync"
	"time"

	"tailscale.com/ipn"
)

// signInGrace is how long a node that needs a login may wait for a page already asked for
// (tsnet asks once as it starts) before it asks itself.
const signInGrace = time.Second

// signInOffer keeps a sign-in page on offer, said on the bus. tsnet asks the control server for
// one only when the node needs a login as it starts; a node signed out later (removed in the admin
// console, its key run out, logged out) waits in NeedsLogin with no page, and one that the control
// server handed back unasked (an expired key at a restart) sits in the status with nothing on the
// bus to say so. Each time it drops into NeedsLogin and no page comes on the bus within the grace,
// it asks: an interactive login, which says the page it holds already, or gets one.
type signInOffer struct {
	grace time.Duration
	// ask starts an interactive login (StartLoginInteractive).
	ask func(ctx context.Context) error
	// after runs f once d has passed (time.AfterFunc; tests fire it themselves).
	after func(d time.Duration, f func())
	// rewatch is the pause before watching a dropped bus again (a second when zero).
	rewatch time.Duration

	mu      sync.Mutex
	needs   bool
	episode int
	offered bool
}

// started says how the node came up: needing a login there, tsnet has asked for its page already.
func (o *signInOffer) started(needs bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.needs, o.offered = needs, needs
}

// heard takes one IPN bus message.
func (o *signInOffer) heard(ctx context.Context, n *ipn.Notify) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if n.BrowseToURL != nil && *n.BrowseToURL != "" {
		o.offered = true
	}
	if n.State == nil {
		return
	}
	needs := *n.State == ipn.NeedsLogin
	if needs == o.needs {
		return
	}
	o.needs = needs
	o.episode++
	if !needs {
		o.offered = false
		return
	}
	episode := o.episode
	after := o.after
	if after == nil {
		after = func(d time.Duration, f func()) { time.AfterFunc(d, f) }
	}
	after(o.grace, func() { o.check(ctx, episode) })
}

// check asks for a page when the node still needs a login, in the same episode, with none said.
func (o *signInOffer) check(ctx context.Context, episode int) {
	if ctx.Err() != nil {
		return
	}
	o.mu.Lock()
	stale := !o.needs || o.episode != episode || o.offered
	o.mu.Unlock()
	if stale {
		return
	}
	if o.ask(ctx) == nil {
		o.mu.Lock()
		if o.episode == episode {
			o.offered = true
		}
		o.mu.Unlock()
	}
}

// watch feeds it the bus until ctx ends, watching again after a dropped bus.
func (o *signInOffer) watch(ctx context.Context, bus func(ctx context.Context, each func(*ipn.Notify) error) error) {
	for ctx.Err() == nil {
		bus(ctx, func(n *ipn.Notify) error {
			o.heard(ctx, n)
			return nil
		})
		pause := o.rewatch
		if pause == 0 {
			pause = time.Second
		}
		select {
		case <-ctx.Done():
		case <-time.After(pause):
		}
	}
}

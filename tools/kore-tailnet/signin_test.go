package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"tailscale.com/ipn"
)

// offerRig drives a signInOffer by hand: its timers wait in due until fired.
type offerRig struct {
	o    *signInOffer
	due  []func()
	asks int
	fail bool
}

func newOfferRig() *offerRig {
	r := &offerRig{}
	r.o = &signInOffer{
		grace: signInGrace,
		ask: func(context.Context) error {
			if r.fail {
				return errors.New("no control")
			}
			r.asks++
			return nil
		},
		after:   func(_ time.Duration, f func()) { r.due = append(r.due, f) },
		rewatch: time.Nanosecond,
	}
	return r
}

func (r *offerRig) state(s ipn.State) { r.o.heard(context.Background(), &ipn.Notify{State: &s}) }
func (r *offerRig) browse(url string) {
	r.o.heard(context.Background(), &ipn.Notify{BrowseToURL: &url})
}

// fire runs every timer due so far.
func (r *offerRig) fire() {
	due := r.due
	r.due = nil
	for _, f := range due {
		f()
	}
}

func TestSignedOutLaterAsksForAPage(t *testing.T) {
	r := newOfferRig()
	r.o.started(false)
	r.state(ipn.Starting)
	r.state(ipn.Running)
	r.fire()
	if r.asks != 0 {
		t.Fatalf("asked while running: %d", r.asks)
	}
	// Removed in the admin console, or its key ran out: NeedsLogin, no page.
	r.state(ipn.NeedsLogin)
	if r.asks != 0 || len(r.due) != 1 {
		t.Fatalf("asked before the grace: asks=%d due=%d", r.asks, len(r.due))
	}
	r.fire()
	if r.asks != 1 {
		t.Fatalf("asks %d, want 1", r.asks)
	}
	// The same sign-out heard again asks no more.
	r.state(ipn.NeedsLogin)
	r.fire()
	if r.asks != 1 {
		t.Fatalf("asked twice in one sign-out: %d", r.asks)
	}
	// Signed in, then out again: a new page.
	r.state(ipn.Running)
	r.state(ipn.NeedsLogin)
	r.fire()
	if r.asks != 2 {
		t.Fatalf("second sign-out: asks %d, want 2", r.asks)
	}
}

func TestStartedNeedingLoginLeavesTsnetsAsk(t *testing.T) {
	r := newOfferRig()
	r.o.started(true)
	r.state(ipn.NeedsLogin)
	r.fire()
	if r.asks != 0 {
		t.Fatalf("asked over tsnet's own ask: %d", r.asks)
	}
	r.state(ipn.Running)
	r.state(ipn.NeedsLogin)
	r.fire()
	if r.asks != 1 {
		t.Fatalf("signed out after the start: asks %d, want 1", r.asks)
	}
}

func TestAPageInTheGraceIsEnough(t *testing.T) {
	r := newOfferRig()
	r.state(ipn.Running)
	r.state(ipn.NeedsLogin)
	r.browse("https://login.example/a/1")
	r.fire()
	if r.asks != 0 {
		t.Fatalf("asked though a page came: %d", r.asks)
	}
}

// An expired key at a restart: the control server hands the page back to the non-interactive
// login, so it's in the status but never said on the bus. The ask says it.
func TestAPageNeverSaidIsAskedFor(t *testing.T) {
	r := newOfferRig()
	r.o.started(false)
	r.state(ipn.Starting)
	r.state(ipn.NeedsLogin)
	r.fire()
	if r.asks != 1 {
		t.Fatalf("asks %d, want 1", r.asks)
	}
}

func TestSignedInWithinTheGraceAsksNothing(t *testing.T) {
	r := newOfferRig()
	r.state(ipn.Running)
	r.state(ipn.NeedsLogin)
	r.state(ipn.Running)
	r.fire()
	if r.asks != 0 {
		t.Fatalf("asked after it was back: %d", r.asks)
	}
	// An earlier sign-out's timer doesn't ask in the next one.
	r.state(ipn.NeedsLogin)
	r.state(ipn.Running)
	r.state(ipn.NeedsLogin)
	r.due[0]()
	if r.asks != 0 {
		t.Fatalf("a stale timer asked: %d", r.asks)
	}
	r.due[1]()
	if r.asks != 1 {
		t.Fatalf("asks %d, want 1", r.asks)
	}
}

func TestAFailedAskIsTriedAtTheNextSignOut(t *testing.T) {
	r := newOfferRig()
	r.state(ipn.Running)
	r.fail = true
	r.state(ipn.NeedsLogin)
	r.fire()
	r.fail = false
	r.state(ipn.Running)
	r.state(ipn.NeedsLogin)
	r.fire()
	if r.asks != 1 {
		t.Fatalf("asks %d, want 1", r.asks)
	}
}

func TestWatchHearsTheBusAgainAfterItDrops(t *testing.T) {
	r := newOfferRig()
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	done := make(chan struct{})
	go func() {
		defer close(done)
		r.o.watch(ctx, func(ctx context.Context, each func(*ipn.Notify) error) error {
			calls++
			running, needs := ipn.Running, ipn.NeedsLogin
			if calls == 1 {
				each(&ipn.Notify{State: &running})
				return errors.New("bus dropped")
			}
			each(&ipn.Notify{State: &needs})
			cancel()
			return ctx.Err()
		})
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("watch didn't end with its context")
	}
	if calls != 2 || len(r.due) != 1 {
		t.Fatalf("calls %d due %d", calls, len(r.due))
	}
	// Its context ended: the timer asks nothing.
	r.fire()
	if r.asks != 0 {
		t.Fatalf("asked after the end: %d", r.asks)
	}
}

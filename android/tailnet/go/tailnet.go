// Package tailnet is Kore's embedded Tailscale node on the phone (phase 18 §5): a thin shim over
// tailscale.com/tsnet, bound with gomobile into the :tailnet AAR. It runs only while the app wants
// it (on screen, or the background setting on); the Kotlin side owns when.
//
// Exported surface is gomobile-friendly (string/int/bool/[]byte/error and interfaces):
//
//	Start(dir, hostname, sealer) error  start the node; its state lives sealed in dir
//	State() string                       NoState / NeedsLogin / NeedsMachineAuth / Starting / Running / Stopped
//	AuthURL() string                     the sign-in URL while NeedsLogin, else ""
//	Self() / Peers() / WhoIs(ip) string  JSON from this node's own Status and WhoIs
//	Dial(addr) (int, error)              TCP over the tailnet; one end of a socketpair
//	SetInterfaces(json) error            the interface list and default route from ConnectivityManager
//	NetworkChanged()                     ConnectivityManager callback -> netmon event
//	SetBinder(binder)                    binds tsnet's outside sockets to the current network
//	Logout() error, Stop() error
//
// Never logged, never uploaded: log upload is off (no logtail, no support logs) and every line
// that could carry the sign-in URL is dropped.
package tailnet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
)

// Sealer wraps the node's state at rest; Kotlin implements it with a Keystore AES-GCM key, so
// tailscaled's private keys never sit in plain text on the phone.
type Sealer interface {
	Seal(plain []byte) ([]byte, error)
	Open(sealed []byte) ([]byte, error)
}

// Binder binds a socket tsnet opens to reach the internet to Android's current network
// (Network.bindSocket), so it follows Wi-Fi and mobile data as ConnectivityManager says.
type Binder interface {
	BindSocket(fd int) error
}

var (
	mu  sync.Mutex
	srv *tsnet.Server

	ifMu    sync.RWMutex
	ifaces  []netmon.Interface
	ifSet   bool
	regOnce sync.Once
	logOnce sync.Once
)

// Start brings up the node. dir must be app-private storage (Context.getNoBackupFilesDir()).
// Non-blocking: read State() until Running (or NeedsLogin and AuthURL()).
func Start(dir, hostname string, sealer Sealer) error {
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return nil
	}
	if dir == "" || sealer == nil {
		return errors.New("tailnet: no state dir or sealer")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	quiet()
	registerGetter()
	if err := logsHere(dir); err != nil {
		return err
	}
	store, err := openSealedStore(filepath.Join(dir, "state.sealed"), sealer)
	if err != nil {
		return err
	}
	s := &tsnet.Server{
		Dir:       dir,
		Hostname:  hostname,
		Ephemeral: false,
		Store:     store,
		Logf:      quietLogf,
		UserLogf:  quietLogf,
	}
	if err := s.Start(); err != nil {
		s.Close()
		return err
	}
	srv = s
	return nil
}

// quiet turns off every way a log line or a support log leaves the phone.
func quiet() {
	logOnce.Do(func() {
		envknob.SetNoLogsNoSupport()
		logtail.Disable()
		log.SetOutput(io.Discard)
	})
}

// State returns the backend state name, or "Stopped" when the node isn't running.
func State() string {
	st, err := status(false)
	if err != nil {
		return "Stopped"
	}
	return st.BackendState
}

// AuthURL returns the interactive sign-in URL while State() is NeedsLogin. The only way the URL
// leaves the shim.
func AuthURL() string {
	st, err := status(false)
	if err != nil {
		return ""
	}
	return st.AuthURL
}

// node is one row as Kotlin reads it (dev.kore.link.net.TailnetNode).
type node struct {
	DNSName  string   `json:"dnsName"`
	HostName string   `json:"hostName"`
	OS       string   `json:"os"`
	Online   bool     `json:"online"`
	UserID   int64    `json:"userId"`
	Login    string   `json:"login,omitempty"`
	NodeKey  string   `json:"nodeKey"`
	IPs      []string `json:"ips"`
	Tags     []string `json:"tags,omitempty"`
}

func rowOf(p *ipnstate.PeerStatus, st *ipnstate.Status, online bool) node {
	n := node{
		DNSName:  p.DNSName,
		HostName: p.HostName,
		OS:       p.OS,
		Online:   online,
		UserID:   int64(p.UserID),
		NodeKey:  p.PublicKey.String(),
	}
	if u, ok := st.User[p.UserID]; ok {
		n.Login = u.LoginName
	}
	for _, ip := range p.TailscaleIPs {
		n.IPs = append(n.IPs, ip.String())
	}
	if p.Tags != nil {
		n.Tags = p.Tags.AsSlice()
		// A tagged node belongs to no user.
		n.UserID = 0
	}
	return n
}

// Self returns this node as JSON, or "" before it's signed in.
func Self() string {
	st, err := status(false)
	if err != nil || st.Self == nil || st.BackendState != ipn.Running.String() {
		return ""
	}
	return marshal(rowOf(st.Self, st, true))
}

// Peers returns every peer as a JSON array.
func Peers() string {
	st, err := status(true)
	if err != nil {
		return "[]"
	}
	rows := make([]node, 0, len(st.Peer))
	for _, p := range st.Peer {
		rows = append(rows, rowOf(p, st, p.Online))
	}
	return marshal(rows)
}

// WhoIs returns who holds tailnet address ip, as this node's own WhoIs says; "" when unknown.
func WhoIs(ip string) string {
	s := current()
	if s == nil {
		return ""
	}
	lc, err := s.LocalClient()
	if err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	w, err := lc.WhoIs(ctx, ip)
	if err != nil || w.Node == nil {
		return ""
	}
	n := node{
		DNSName: w.Node.Name,
		NodeKey: w.Node.Key.String(),
		Tags:    w.Node.Tags,
		Online:  w.Node.Online != nil && *w.Node.Online,
	}
	if w.Node.Hostinfo.Valid() {
		n.HostName = w.Node.Hostinfo.Hostname()
		n.OS = w.Node.Hostinfo.OS()
	}
	for _, a := range w.Node.Addresses {
		n.IPs = append(n.IPs, a.Addr().String())
	}
	if w.UserProfile != nil && len(w.Node.Tags) == 0 {
		n.UserID = int64(w.UserProfile.ID)
		n.Login = w.UserProfile.LoginName
	}
	return marshal(n)
}

func marshal(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}

func status(peers bool) (*ipnstate.Status, error) {
	s := current()
	if s == nil {
		return nil, errors.New("tailnet: not started")
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if peers {
		return lc.Status(ctx)
	}
	return lc.StatusWithoutPeers(ctx)
}

func current() *tsnet.Server {
	mu.Lock()
	defer mu.Unlock()
	return srv
}

// Dial opens a TCP connection to addr ("host:port", a MagicDNS name or 100.x address) over the
// tailnet and returns a file descriptor for one end of an AF_UNIX socketpair; ownership passes
// to the caller (Kotlin: ParcelFileDescriptor.adoptFd). Blocks until the node runs and the peer
// answers, at most 20 s: never call it on the main thread.
func Dial(addr string) (int, error) {
	s := current()
	if s == nil {
		return -1, errors.New("tailnet: not started")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	tc, err := s.Dial(ctx, "tcp", addr)
	if err != nil {
		return -1, err
	}
	return bridge(tc)
}

// bridge hands tc to the caller as one end of a socketpair.
func bridge(tc net.Conn) (int, error) {
	syscall.ForkLock.RLock()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err == nil {
		syscall.CloseOnExec(fds[0])
		syscall.CloseOnExec(fds[1])
	}
	syscall.ForkLock.RUnlock()
	if err != nil {
		tc.Close()
		return -1, fmt.Errorf("socketpair: %w", err)
	}
	// fds[0] stays in Go; fds[1] goes to Kotlin as a raw int (never an *os.File here, so no Go
	// finalizer can close it under Kotlin).
	f := os.NewFile(uintptr(fds[0]), "kore-tailnet")
	lc, err := net.FileConn(f) // dups the fd
	f.Close()
	if err != nil {
		tc.Close()
		syscall.Close(fds[1])
		return -1, err
	}
	go pump(tc, lc)
	return fds[1], nil
}

type closeWriter interface{ CloseWrite() error }

// pump copies both ways, passing half-closes on, and closes both when done.
func pump(a, b net.Conn) {
	var wg sync.WaitGroup
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		io.Copy(dst, src)
		if cw, ok := dst.(closeWriter); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
	}
	wg.Add(2)
	go cp(a, b)
	go cp(b, a)
	wg.Wait()
	a.Close()
	b.Close()
}

// NetworkChanged is called from ConnectivityManager.NetworkCallback (onAvailable, onLost,
// onLinkPropertiesChanged), after SetInterfaces: netmon takes the change at once, and sockets
// stay (WireGuard roams).
func NetworkChanged() {
	s := current()
	if s == nil {
		return
	}
	if sys := s.Sys(); sys != nil {
		if m, ok := sys.NetMon.GetOK(); ok && m != nil {
			m.InjectEvent()
		}
	}
}

// SetBinder registers how tsnet's outside sockets are bound to Android's current network; nil
// turns it off.
func SetBinder(b Binder) { setBinder(b) }

// ifaceJSON is one row built in Kotlin from ConnectivityManager: NetworkInterface for
// index/mtu/flags, LinkProperties for "ip/prefix" addresses and the default route's gateway.
type ifaceJSON struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	MTU       int      `json:"mtu"`
	Up        bool     `json:"up"`
	Broadcast bool     `json:"broadcast"`
	Loopback  bool     `json:"loopback"`
	P2P       bool     `json:"pointToPoint"`
	Multicast bool     `json:"multicast"`
	Addrs     []string `json:"addrs"`
	// Default marks the active network's interface; Gateway is its IPv4 default gateway.
	Default bool   `json:"default"`
	Gateway string `json:"gateway"`
}

// SetInterfaces replaces the interface list netmon sees (Android denies net.Interfaces and
// NETLINK_ROUTE to apps), and the default route with it. Call before Start and on every network
// change, then NetworkChanged.
func SetInterfaces(js string) error {
	var rows []ifaceJSON
	if err := json.Unmarshal([]byte(js), &rows); err != nil {
		return fmt.Errorf("tailnet: interfaces json: %w", err)
	}
	out := make([]netmon.Interface, 0, len(rows))
	defIf, defGw := "", ""
	for _, r := range rows {
		if r.Default {
			defIf, defGw = r.Name, r.Gateway
		}
		ni := &net.Interface{Index: r.Index, MTU: r.MTU, Name: r.Name}
		if r.Up {
			ni.Flags |= net.FlagUp | net.FlagRunning
		}
		if r.Broadcast {
			ni.Flags |= net.FlagBroadcast
		}
		if r.Loopback {
			ni.Flags |= net.FlagLoopback
		}
		if r.P2P {
			ni.Flags |= net.FlagPointToPoint
		}
		if r.Multicast {
			ni.Flags |= net.FlagMulticast
		}
		addrs := make([]net.Addr, 0, len(r.Addrs))
		for _, a := range r.Addrs {
			p, err := netip.ParsePrefix(strings.TrimSpace(a))
			if err != nil {
				continue
			}
			addrs = append(addrs, &net.IPNet{IP: p.Addr().AsSlice(), Mask: net.CIDRMask(p.Bits(), p.Addr().BitLen())})
		}
		// AltAddrs non-nil: netmon never calls (*net.Interface).Addrs, which hits netlink.
		out = append(out, netmon.Interface{Interface: ni, AltAddrs: addrs})
	}
	ifMu.Lock()
	ifaces, ifSet = out, true
	ifMu.Unlock()
	setDefaultRoute(defIf, defGw)
	registerGetter()
	return nil
}

// registerGetter installs the getter once. Until SetInterfaces is called it falls back to
// net.Interfaces (works on a Mac for tests; fails on Android).
func registerGetter() {
	regOnce.Do(func() {
		netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
			ifMu.RLock()
			defer ifMu.RUnlock()
			if ifSet {
				return append([]netmon.Interface(nil), ifaces...), nil
			}
			ifs, err := net.Interfaces()
			if err != nil {
				return nil, err
			}
			ret := make([]netmon.Interface, len(ifs))
			for i := range ifs {
				ret[i].Interface = &ifs[i]
			}
			return ret, nil
		})
	})
}

// Logout drops the node key on the control plane and locally (Leave KoreNet).
func Logout() error {
	s := current()
	if s == nil {
		return errors.New("tailnet: not started")
	}
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return lc.Logout(ctx)
}

// Stop shuts the node down; Start may be called again.
func Stop() error {
	mu.Lock()
	s := srv
	srv = nil
	mu.Unlock()
	if s == nil {
		return nil
	}
	return s.Close()
}

// quietLogf drops everything (verbose only on a dev machine) and never a line that could carry
// the sign-in URL.
func quietLogf(format string, a ...any) {
	if !verbose {
		return
	}
	if strings.Contains(format, "go to:") || strings.Contains(format, "AuthURL") {
		return
	}
	line := fmt.Sprintf(format, a...)
	if strings.Contains(line, "https://") && strings.Contains(line, "/a/") {
		return
	}
	fmt.Fprintln(os.Stderr, line)
}

var verbose = os.Getenv("KORE_TAILNET_VERBOSE") != ""

// logsHere gives Tailscale's log policy a folder of its own inside the app's state: on Android
// there's no home or cache folder for it to find, and without one tsnet panics at start ("no
// safe place found to store log state"). Upload stays off; this only holds its local state.
func logsHere(dir string) error {
	logs := filepath.Join(dir, "logs")
	if err := os.MkdirAll(logs, 0o700); err != nil {
		return err
	}
	return os.Setenv("TS_LOGS_DIR", logs)
}

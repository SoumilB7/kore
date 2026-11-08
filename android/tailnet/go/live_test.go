//go:build kore_live

package tailnet

// A real tsnet dial and accept between two nodes, with an in-process control server and DERP
// relay (Tailscale's own test harness): run with the shim's exact ts_omit tags (check.sh passes
// them), so a feature left out that a phone's link needs fails here, not on a phone.

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"testing"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/net/netns"
	"tailscale.com/net/stun/stuntest"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/nettype"
)

// derpAndSTUN is Tailscale's integration.RunDERPAndSTUN without that package (it pulls in SSH,
// which the shim's tags leave out): one DERP region on loopback, and a STUN server.
func derpAndSTUN(t *testing.T) *tailcfg.DERPMap {
	d := derpserver.New(key.NewNode(), logger.Discard)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(derpserver.Handler(d))
	srv.Listener.Close()
	srv.Listener = ln
	srv.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	srv.StartTLS()
	t.Cleanup(srv.Close)
	stunAddr, stunDone := stuntest.ServeWithPacketListener(t, nettype.Std{})
	t.Cleanup(stunDone)
	return &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{1: {
		RegionID: 1, RegionCode: "test",
		Nodes: []*tailcfg.DERPNode{{
			Name: "t1", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none",
			STUNPort: stunAddr.Port, DERPPort: ln.Addr().(*net.TCPAddr).Port, InsecureForTests: true, STUNTestIP: "127.0.0.1",
		}},
	}}}
}

func TestLiveDialAndAccept(t *testing.T) {
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	derpMap := derpAndSTUN(t)
	control := &testcontrol.Server{DERPMap: derpMap, DNSConfig: &tailcfg.DNSConfig{Proxied: true}, MagicDNSDomain: "tail-scale.ts.net", Logf: logger.Discard}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)

	up := func(name string) (*tsnet.Server, netip.Addr) {
		s := &tsnet.Server{Dir: filepath.Join(t.TempDir(), name), ControlURL: control.HTTPTestServer.URL, Hostname: name, Store: new(mem.Store), Ephemeral: true, Logf: logger.Discard}
		t.Cleanup(func() { s.Close() })
		st, err := s.Up(ctx)
		if err != nil {
			t.Fatalf("%s up: %v", name, err)
		}
		return s, st.TailscaleIPs[0]
	}
	box, boxIP := up("box")
	phone, phoneIP := up("phone")

	// The box accepts on Kore's port and echoes; the phone dials it, as a phone's link does.
	echo := func(s *tsnet.Server) {
		ln, err := s.Listen("tcp", ":47470")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
		t.Cleanup(func() { ln.Close() })
		go func() {
			for {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				go func() { defer c.Close(); io.Copy(c, c) }()
			}
		}()
	}
	roundTrip := func(from *tsnet.Server, to netip.Addr) {
		c, err := from.Dial(ctx, "tcp", netip.AddrPortFrom(to, 47470).String())
		if err != nil {
			t.Fatalf("dial %v: %v", to, err)
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(30 * time.Second))
		if _, err := c.Write([]byte("kore")); err != nil {
			t.Fatalf("write: %v", err)
		}
		got := make([]byte, 4)
		if _, err := io.ReadFull(c, got); err != nil || string(got) != "kore" {
			t.Fatalf("echo: %q %v", got, err)
		}
	}
	echo(box)
	roundTrip(phone, boxIP)
	// And the other way: the phone's node accepts too (netstack in both directions).
	echo(phone)
	roundTrip(box, phoneIP)
}

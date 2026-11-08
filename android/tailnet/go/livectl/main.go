//go:build kore_live

// livectl serves a Tailscale test control server and a DERP relay (no STUN) on loopback for the
// shim's state test (state_test.go), built without the shim's ts_omit tags so it outlives the
// test binaries built with each tag set. It prints its control URL, then runs until killed.
package main

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"

	"tailscale.com/derp/derpserver"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func main() {
	d := derpserver.New(key.NewNode(), logger.Discard)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	derp := httptest.NewUnstartedServer(derpserver.Handler(d))
	derp.Listener.Close()
	derp.Listener = ln
	derp.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	derp.StartTLS()
	m := &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{1: {
		RegionID: 1, RegionCode: "test",
		Nodes: []*tailcfg.DERPNode{{Name: "t1", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none",
			STUNPort: -1, DERPPort: ln.Addr().(*net.TCPAddr).Port, InsecureForTests: true}},
	}}}
	control := &testcontrol.Server{DERPMap: m, DNSConfig: &tailcfg.DNSConfig{Proxied: true}, MagicDNSDomain: "tail-scale.ts.net", Logf: logger.Discard}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	fmt.Println(control.HTTPTestServer.URL)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	<-stop
}

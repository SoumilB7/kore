//go:build android

package tailnet

import (
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
)

// Android netmon can't read /proc/net/route as an app: the default route comes from Kotlin.
func setDefaultRoute(ifName, gw string) {
	netmon.UpdateLastKnownDefaultRouteInterface(ifName)
	if gw != "" {
		netmon.UpdateLastKnownDefaultGateway(gw)
	}
}

func setBinder(b Binder) {
	if b == nil {
		netns.SetAndroidBindToNetworkFunc(nil)
		return
	}
	netns.SetAndroidBindToNetworkFunc(func(fd int) error { return b.BindSocket(fd) })
}

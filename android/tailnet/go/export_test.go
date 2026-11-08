package tailnet

import "tailscale.com/net/netmon"

func netInterfacesForTest() (netmon.InterfaceList, error) { return netmon.GetInterfaceList() }

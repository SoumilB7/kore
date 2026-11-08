//go:build !android

package tailnet

func setDefaultRoute(ifName, gw string) {}

func setBinder(b Binder) {}

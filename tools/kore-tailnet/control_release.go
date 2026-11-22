//go:build !koretest

package main

// The control server is always Tailscale's: a release build never reads one from the
// environment (scripts/tests/korenet-real builds with `-tags koretest`).
func testControlURL() string { return "" }

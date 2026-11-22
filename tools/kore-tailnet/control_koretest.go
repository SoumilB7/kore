//go:build koretest

package main

import "os"

// Test builds only (`-tags koretest`): KORE_TAILNET_CONTROL_URL points the node at a local
// control server (Headscale in scripts/tests/korenet-real). Never built into a release.
func testControlURL() string { return os.Getenv("KORE_TAILNET_CONTROL_URL") }

// kore-tailnet is Kore's own tailnet node (tsnet), run beside Kore.app or kore-host only when no
// usable installed Tailscale exists (phase 18 §1). It serves the TailnetSidecar protocol on a
// Unix socket for this user alone and hands tailnet connections over as descriptors.
//
//	kore-tailnet -socket <path> -state <dir> [-hostname <name>] [-v]
//
// It prints "ready" once the socket listens, waits for a `start` carrying the 32-byte state key
// (never argv or env), and ends when the connection that sent it closes, on `stop`, or on
// SIGTERM/SIGINT. Log upload is off; the auth URL leaves only through `status`.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/logtail"
	"tailscale.com/types/logger"
)

func main() {
	socket := flag.String("socket", "", "control socket path (its folder should be 0700)")
	state := flag.String("state", "", "state folder")
	hostname := flag.String("hostname", "", "tailnet node name (default: this machine's)")
	uid := flag.Int("uid", os.Getuid(), "the only uid allowed on the socket")
	within := flag.Duration("start-within", 30*time.Second, "give up when no start comes this soon")
	verbose := flag.Bool("v", false, "tsnet logs on stderr, auth URL left out")
	flag.Parse()
	if *socket == "" || *state == "" {
		fmt.Fprintln(os.Stderr, "usage: kore-tailnet -socket <path> -state <dir>")
		os.Exit(1)
	}
	if os.Getenv("GOMAXPROCS") == "" {
		runtime.GOMAXPROCS(1)
	}
	envknob.SetNoLogsNoSupport()
	logtail.Disable()
	var logf logger.Logf
	if *verbose {
		logf = withoutAuthURL
	} else {
		log.SetOutput(io.Discard)
	}
	name := *hostname
	if name == "" {
		name, _ = os.Hostname()
		name, _, _ = strings.Cut(name, ".")
	}
	if err := os.MkdirAll(*state, 0o700); err != nil {
		fail(err)
	}
	os.Chmod(*state, 0o700)

	ln, err := listenSocket(*socket)
	if err != nil {
		fail(err)
	}
	srv := newServer(*uid, func(key []byte) (node, error) { return startTSNet(*state, name, key, logf) })
	go srv.serve(ln)
	deadline := time.AfterFunc(*within, func() {
		srv.mu.Lock()
		started := srv.started
		srv.mu.Unlock()
		if !started {
			srv.finish(3)
		}
	})
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-signals
		srv.finish(0)
	}()
	fmt.Println("ready")

	code := <-srv.exit
	deadline.Stop()
	ln.Close()
	srv.shutdown()
	os.Exit(code)
}

// listenSocket binds the control socket 0600, refusing a path another kore-tailnet still serves.
func listenSocket(path string) (*net.UnixListener, error) {
	if c, err := net.Dial("unix", path); err == nil {
		c.Close()
		return nil, fmt.Errorf("%s is in use", path)
	}
	os.Remove(path)
	old := syscall.Umask(0o177)
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	ln.SetUnlinkOnClose(true)
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// withoutAuthURL logs to stderr, dropping any line that could carry the login URL.
func withoutAuthURL(format string, args ...any) {
	if strings.Contains(format, "go to:") || strings.Contains(format, "AuthURL") {
		return
	}
	line := fmt.Sprintf(format, args...)
	if strings.Contains(line, "/a/") || strings.Contains(strings.ToLower(line), "authurl") {
		return
	}
	fmt.Fprintln(os.Stderr, strings.TrimSuffix(line, "\n"))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "kore-tailnet:", err)
	os.Exit(1)
}

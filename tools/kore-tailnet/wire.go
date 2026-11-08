package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
)

// maxMessage matches TailnetSidecar.maxMessage on the Swift side.
const maxMessage = 16 << 20

var errTooBig = errors.New("message too big")

// readMsg reads one `u32 big-endian length | JSON` message; io.EOF at a clean end.
func readMsg(r io.Reader) ([]byte, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n > maxMessage {
		return nil, errTooBig
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, io.ErrUnexpectedEOF
	}
	return body, nil
}

// writeMsg sends v as one message. A descriptor (fd >= 0) rides as SCM_RIGHTS with the 4 length
// bytes, alone in that sendmsg, as the Swift reader expects.
func writeMsg(c *net.UnixConn, v any, fd int) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(body) > maxMessage {
		return errTooBig
	}
	hdr := binary.BigEndian.AppendUint32(nil, uint32(len(body)))
	if fd < 0 {
		_, err = c.Write(append(hdr, body...))
		return err
	}
	n, _, err := c.WriteMsgUnix(hdr, syscall.UnixRights(fd), nil)
	if err != nil {
		return err
	}
	if _, err = c.Write(append(hdr[n:], body...)); err != nil {
		return err
	}
	return nil
}

func closeFD(fd int) { syscall.Close(fd) }

func refusal(why string) map[string]any { return map[string]any{"ok": false, "error": why} }

var okReply = map[string]any{"ok": true}

// bridge turns a tailnet connection into a descriptor to hand over: one end of a Unix socket
// pair, the other pumped to tc here until either side closes.
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
		return -1, err
	}
	f := os.NewFile(uintptr(fds[0]), "kore-tailnet-bridge")
	near, err := net.FileConn(f)
	f.Close()
	if err != nil {
		tc.Close()
		syscall.Close(fds[1])
		return -1, err
	}
	go pump(tc, near)
	return fds[1], nil
}

// pump copies both ways, passing half-closes on, and closes both when both ways end.
func pump(a, b net.Conn) {
	var wg sync.WaitGroup
	copyHalf := func(dst, src net.Conn) {
		defer wg.Done()
		io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
	}
	wg.Add(2)
	go copyHalf(a, b)
	go copyHalf(b, a)
	wg.Wait()
	a.Close()
	b.Close()
}

// heldFDs keeps sent descriptors open until the receiver acks them, oldest first: macOS can
// deliver a dead descriptor when the sender closes its copy while it's still in flight.
type heldFDs struct {
	mu     sync.Mutex
	fds    []int
	closed bool
}

func (h *heldFDs) push(fd int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		syscall.Close(fd)
		return
	}
	h.fds = append(h.fds, fd)
}

func (h *heldFDs) ack() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.fds) > 0 {
		syscall.Close(h.fds[0])
		h.fds = h.fds[1:]
	}
}

func (h *heldFDs) closeAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, fd := range h.fds {
		syscall.Close(fd)
	}
	h.fds, h.closed = nil, true
}

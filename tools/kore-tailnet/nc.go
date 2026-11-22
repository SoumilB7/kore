package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"syscall"
)

// runNC is `kore-tailnet nc -socket <path> <addr> <port>`: a connection to a tailnet peer made by
// the kore-tailnet already running on that socket (this user's), relayed on stdin and stdout.
// It's ssh's ProxyCommand while Kore's own tailnet carries this device: SSH to a box at a
// tailnet address keeps working with installed Tailscale stopped or gone.
func runNC(args []string) int {
	var socket string
	for len(args) > 1 && args[0] == "-socket" {
		socket, args = args[1], args[2:]
	}
	if socket == "" || len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: kore-tailnet nc -socket <path> <addr> <port>")
		return 2
	}
	port, err := strconv.Atoi(args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "kore-tailnet nc: bad port")
		return 2
	}
	conn, err := dialThrough(socket, args[0], port)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kore-tailnet nc:", err)
		return 1
	}
	defer conn.Close()
	done := make(chan struct{})
	go func() {
		io.Copy(os.Stdout, conn)
		close(done)
	}()
	io.Copy(conn, os.Stdin)
	if cw, ok := conn.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
	<-done
	return 0
}

// dialThrough asks the helper on socket to dial addr:port and takes the descriptor it hands over.
func dialThrough(socket, addr string, port int) (net.Conn, error) {
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		return nil, err
	}
	defer c.Close()
	body, _ := json.Marshal(request{V: 1, Op: "dial", Addr: addr, Port: port})
	if _, err := c.Write(append(binary.BigEndian.AppendUint32(nil, uint32(len(body))), body...)); err != nil {
		return nil, err
	}
	// The length (with the descriptor, when there is one), then the reply.
	hdr := make([]byte, 4)
	oob := make([]byte, syscall.CmsgSpace(4))
	n, oobn, _, _, err := c.ReadMsgUnix(hdr, oob)
	if err != nil {
		return nil, err
	}
	if n < 4 {
		if _, err := io.ReadFull(c, hdr[n:]); err != nil {
			return nil, err
		}
	}
	fd := -1
	if oobn > 0 {
		if msgs, err := syscall.ParseSocketControlMessage(oob[:oobn]); err == nil && len(msgs) > 0 {
			if fds, err := syscall.ParseUnixRights(&msgs[0]); err == nil && len(fds) > 0 {
				fd = fds[0]
			}
		}
	}
	reply := make([]byte, binary.BigEndian.Uint32(hdr))
	if _, err := io.ReadFull(c, reply); err != nil {
		return nil, err
	}
	var said struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	json.Unmarshal(reply, &said)
	if !said.OK || fd < 0 {
		if fd >= 0 {
			syscall.Close(fd)
		}
		if said.Error == "" {
			said.Error = "no connection"
		}
		return nil, errors.New(said.Error)
	}
	f := os.NewFile(uintptr(fd), "tailnet")
	defer f.Close()
	return net.FileConn(f)
}

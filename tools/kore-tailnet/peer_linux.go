package main

import "golang.org/x/sys/unix"

// peerUIDFD is the uid of the process at the other end of a Unix socket (SO_PEERCRED).
func peerUIDFD(fd int) (int, error) {
	cred, err := unix.GetsockoptUcred(fd, unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil {
		return -1, err
	}
	return int(cred.Uid), nil
}

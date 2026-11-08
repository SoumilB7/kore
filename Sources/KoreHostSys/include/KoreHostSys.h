#ifndef KORE_HOST_SYS_H
#define KORE_HOST_SYS_H

#include <sys/types.h>

/// Turns transparent huge pages off for this process (Linux `prctl(PR_SET_THP_DISABLE)`), so an
/// idle kore-host keeps small pages it can give back. 0 when done; -1 elsewhere or on failure.
int kore_host_disable_thp(void);

/// A shell on a new pseudo-terminal (`forkpty`): `path` run with `argv` and `envp` in `cwd`, its
/// window `cols` x `rows`. The child closes every other descriptor and resets its signals before
/// it runs. The child's pid, with the terminal's own end (non-blocking, close-on-exec) in
/// `*master`; -1 when it couldn't start.
pid_t kore_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short cols, unsigned short rows, int *master);

/// Sets the terminal's window size (`TIOCSWINSZ`): 0 when done.
int kore_pty_resize(int master, unsigned short cols, unsigned short rows);

/// A descriptor that reads ready once `pid` exits (Linux `pidfd_open`); -1 elsewhere or when the
/// kernel can't.
int kore_pidfd_open(pid_t pid);

/// A folder `name` inside the folder open at `dirfd` (or `AT_FDCWD`), opened to read and never
/// through a link (`O_DIRECTORY | O_NOFOLLOW`, close-on-exec): -1 with `errno` when it's a link,
/// a file, or not there.
int kore_open_folder(int dirfd, const char *name);

/// KoreNet's sidecar socket (`kore-tailnet`): sends `len` bytes from `buf`, with `fd` attached as
/// SCM_RIGHTS when it isn't -1. Bytes sent, or -1.
ssize_t kore_send_fd(int sock, const void *buf, size_t len, int fd);

/// Receives up to `len` bytes into `buf`; a descriptor that came with them lands in `*fd`
/// (close-on-exec), else -1 there. Any further descriptors are closed. Bytes read, 0 at the end,
/// -1 on error.
ssize_t kore_recv_fd(int sock, void *buf, size_t len, int *fd);

/// A KoreNet TCP connection's options: `TCP_NODELAY` on, `TCP_NOTSENT_LOWAT` to `lowat` bytes.
/// 0 when both took.
int kore_tcp_tune(int fd, int lowat);

/// The connection's `TCP_NOTSENT_LOWAT`, or -1.
int kore_tcp_notsent_lowat(int fd);

/// kore-host's KoreNet port: a listening TCP socket on `ip` (v4 or v6, never a wildcard: the
/// caller checks) and `port`, non-blocking and close-on-exec, held to the interface `device` when
/// given (Linux `SO_BINDTODEVICE`; elsewhere `device` must be NULL). The descriptor, or -1 with
/// `errno` (`EADDRINUSE` when the port is taken).
int kore_listen_on(const char *ip, unsigned short port, const char *device, int backlog);

/// A netlink socket for link and address changes (Linux `RTMGRP_LINK | RTMGRP_IPV4_IFADDR |
/// RTMGRP_IPV6_IFADDR`), non-blocking: it reads ready only when an interface or an address comes
/// or goes. -1 elsewhere.
int kore_netlink_open(void);

/// Reads every waiting netlink message: 1 when one was about the interface `name` (or the index
/// `known`, for one already gone), 0 when none was, -1 when the socket failed.
int kore_netlink_drain(int fd, const char *name, int known);

/// The interface's index, 0 when there's none by that name.
int kore_interface_index(const char *name);

#endif

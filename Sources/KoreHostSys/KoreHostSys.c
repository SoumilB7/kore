#include "KoreHostSys.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <termios.h>
#include <unistd.h>

#if defined(__linux__)
#include <pty.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#ifndef PR_SET_THP_DISABLE
#define PR_SET_THP_DISABLE 41
#endif

int kore_host_disable_thp(void) { return prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0); }

int kore_pidfd_open(pid_t pid) {
#ifdef SYS_pidfd_open
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    return (int)syscall(434, pid, 0);
#endif
}
#else
#include <util.h>

int kore_host_disable_thp(void) { return -1; }
int kore_pidfd_open(pid_t pid) { (void)pid; return -1; }
#endif

/// Every descriptor above stderr, closed in the child before it runs the shell.
static void close_others(void) {
#if defined(__linux__)
#ifndef SYS_close_range
#define SYS_close_range 436
#endif
    if (syscall(SYS_close_range, 3, ~0U, 0) == 0) return;
#endif
    struct rlimit limit;
    long top = 4096;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && (long)limit.rlim_cur < 65536) top = (long)limit.rlim_cur;
    for (long fd = 3; fd < top; fd++) close((int)fd);
}

pid_t kore_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short cols, unsigned short rows, int *master) {
    struct winsize size;
    memset(&size, 0, sizeof size);
    size.ws_col = cols;
    size.ws_row = rows;
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        // The child: only async-signal-safe calls from here to exec.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int s = 1; s < 32; s++) {
            if (s == SIGKILL || s == SIGSTOP) continue;
            signal(s, SIG_DFL);
        }
        close_others();
        if (cwd && chdir(cwd) != 0) { if (chdir("/") != 0) _exit(127); }
        execve(path, argv, envp);
        _exit(127);
    }
    int flags = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    *master = fd;
    return pid;
}

int kore_pty_resize(int master, unsigned short cols, unsigned short rows) {
    struct winsize size;
    memset(&size, 0, sizeof size);
    size.ws_col = cols;
    size.ws_row = rows;
    return ioctl(master, TIOCSWINSZ, &size);
}

int kore_open_folder(int dirfd, const char *name) {
    return openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

ssize_t kore_send_fd(int sock, const void *buf, size_t len, int fd) {
    struct iovec iov = {.iov_base = (void *)buf, .iov_len = len};
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } control;
    if (fd >= 0) {
        memset(&control, 0, sizeof(control));
        msg.msg_control = control.buf;
        msg.msg_controllen = sizeof(control.buf);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof(int));
    }
    ssize_t n;
    do {
        n = sendmsg(sock, &msg, 0);
    } while (n < 0 && errno == EINTR);
    return n;
}

ssize_t kore_recv_fd(int sock, void *buf, size_t len, int *fd) {
    *fd = -1;
    struct iovec iov = {.iov_base = buf, .iov_len = len};
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    union {
        char buf[CMSG_SPACE(sizeof(int) * 4)];
        struct cmsghdr align;
    } control;
    msg.msg_control = control.buf;
    msg.msg_controllen = sizeof(control.buf);
#if defined(MSG_CMSG_CLOEXEC)
    int flags = MSG_CMSG_CLOEXEC;
#else
    int flags = 0;
#endif
    ssize_t n;
    do {
        n = recvmsg(sock, &msg, flags);
    } while (n < 0 && errno == EINTR);
    if (n < 0) return n;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < count; i++) {
            int got;
            memcpy(&got, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
            if (*fd < 0) {
                *fd = got;
                fcntl(got, F_SETFD, FD_CLOEXEC);
            } else {
                close(got);
            }
        }
    }
    if (msg.msg_flags & MSG_CTRUNC) {
        if (*fd >= 0) close(*fd);
        *fd = -1;
        errno = EMSGSIZE;
        return -1;
    }
    return n;
}

#if defined(__APPLE__) && !defined(TCP_NOTSENT_LOWAT)
#define TCP_NOTSENT_LOWAT 0x201
#elif defined(__linux__) && !defined(TCP_NOTSENT_LOWAT)
#define TCP_NOTSENT_LOWAT 25
#endif

int kore_tcp_tune(int fd, int lowat) {
    int on = 1;
    int a = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    int b = setsockopt(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT, &lowat, sizeof(lowat));
    return (a == 0 && b == 0) ? 0 : -1;
}

int kore_tcp_notsent_lowat(int fd) {
    int value = 0;
    socklen_t size = sizeof(value);
    if (getsockopt(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT, &value, &size) != 0) return -1;
    return value;
}

int kore_listen_on(const char *ip, unsigned short port, const char *device, int backlog) {
    struct sockaddr_storage address;
    memset(&address, 0, sizeof(address));
    socklen_t length;
    int family;
    struct sockaddr_in *v4 = (struct sockaddr_in *)&address;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&address;
    if (inet_pton(AF_INET, ip, &v4->sin_addr) == 1) {
        family = AF_INET;
        v4->sin_family = AF_INET;
        v4->sin_port = htons(port);
        length = sizeof(*v4);
    } else if (inet_pton(AF_INET6, ip, &v6->sin6_addr) == 1) {
        family = AF_INET6;
        v6->sin6_family = AF_INET6;
        v6->sin6_port = htons(port);
        length = sizeof(*v6);
    } else {
        errno = EINVAL;
        return -1;
    }
#if defined(__APPLE__)
    v4->sin_len = (unsigned char)length;
#endif
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    if (family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, sizeof(on));
    if (device != NULL) {
#if defined(__linux__)
        if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, device, (socklen_t)strlen(device)) != 0) {
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
#else
        close(fd);
        errno = ENOTSUP;
        return -1;
#endif
    }
    if (bind(fd, (struct sockaddr *)&address, length) != 0 || listen(fd, backlog) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int kore_interface_index(const char *name) { return (int)if_nametoindex(name); }

int kore_ifname_is(const void *payload, size_t room, const char *name) {
    // The whole name, NUL-terminated inside the attribute: never a prefix, never past its end.
    const char *got = (const char *)payload;
    return memchr(got, 0, room) != NULL && strcmp(got, name) == 0;
}

#if defined(__linux__)
// The static musl SDK has no kernel headers: rtnetlink's few shapes, as the kernel lays them out.
#define KORE_NETLINK_ROUTE 0
#define KORE_RTMGRP_LINK 0x1
#define KORE_RTMGRP_IPV4_IFADDR 0x10
#define KORE_RTMGRP_IPV6_IFADDR 0x100
#define KORE_RTM_NEWLINK 16
#define KORE_RTM_DELLINK 17
#define KORE_RTM_NEWADDR 20
#define KORE_RTM_DELADDR 21
#define KORE_IFLA_IFNAME 3
#define KORE_ALIGN4(n) (((n) + 3u) & ~3u)

struct kore_sockaddr_nl { unsigned short family; unsigned short pad; unsigned int pid; unsigned int groups; };
struct kore_nlmsghdr { unsigned int len; unsigned short type; unsigned short flags; unsigned int seq; unsigned int pid; };
struct kore_ifinfomsg { unsigned char family; unsigned char pad; unsigned short type; int index; unsigned int flags; unsigned int change; };
struct kore_ifaddrmsg { unsigned char family; unsigned char prefixlen; unsigned char flags; unsigned char scope; unsigned int index; };
struct kore_rtattr { unsigned short len; unsigned short type; };

int kore_netlink_open(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, KORE_NETLINK_ROUTE);
    if (fd < 0) return -1;
    struct kore_sockaddr_nl address;
    memset(&address, 0, sizeof(address));
    address.family = AF_NETLINK;
    address.groups = KORE_RTMGRP_LINK | KORE_RTMGRP_IPV4_IFADDR | KORE_RTMGRP_IPV6_IFADDR;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int kore_netlink_drain(int fd, const char *name, int known) {
    unsigned char buffer[16384] __attribute__((aligned(4)));
    int about = 0;
    for (;;) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return about;
            // ENOBUFS: messages were lost; look again to be safe.
            if (errno == ENOBUFS) { about = 1; continue; }
            return -1;
        }
        if (n == 0) return -1;
        int index = (int)if_nametoindex(name);
        size_t at = 0;
        while (at + sizeof(struct kore_nlmsghdr) <= (size_t)n) {
            struct kore_nlmsghdr *h = (struct kore_nlmsghdr *)(buffer + at);
            if (h->len < sizeof(*h) || at + h->len > (size_t)n) break;
            unsigned char *body = buffer + at + sizeof(*h);
            size_t size = h->len - sizeof(*h);
            if ((h->type == KORE_RTM_NEWLINK || h->type == KORE_RTM_DELLINK) && size >= sizeof(struct kore_ifinfomsg)) {
                struct kore_ifinfomsg *info = (struct kore_ifinfomsg *)body;
                if ((index > 0 && info->index == index) || (known > 0 && info->index == known)) about = 1;
                size_t a = KORE_ALIGN4(sizeof(*info));
                while (a + sizeof(struct kore_rtattr) <= size) {
                    struct kore_rtattr *attr = (struct kore_rtattr *)(body + a);
                    if (attr->len < sizeof(*attr) || a + attr->len > size) break;
                    if (attr->type == KORE_IFLA_IFNAME && kore_ifname_is(attr + 1, attr->len - sizeof(*attr), name)) about = 1;
                    a += KORE_ALIGN4(attr->len);
                }
            } else if ((h->type == KORE_RTM_NEWADDR || h->type == KORE_RTM_DELADDR) && size >= sizeof(struct kore_ifaddrmsg)) {
                struct kore_ifaddrmsg *info = (struct kore_ifaddrmsg *)body;
                if ((index > 0 && (int)info->index == index) || (known > 0 && (int)info->index == known)) about = 1;
            }
            at += KORE_ALIGN4(h->len);
        }
    }
}
#else
int kore_netlink_open(void) { return -1; }
int kore_netlink_drain(int fd, const char *name, int known) { (void)fd; (void)name; (void)known; return -1; }
#endif

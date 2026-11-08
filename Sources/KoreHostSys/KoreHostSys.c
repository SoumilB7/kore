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

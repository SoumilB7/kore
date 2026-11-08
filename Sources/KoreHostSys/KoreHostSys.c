#include "KoreHostSys.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
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

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

#endif

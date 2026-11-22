// kore-devrun: runs a dev job (a build, the gate, storylines, Gradle) as its own to macOS, so its
// energy is never charged to the Kore it was started from. Built and run by scripts/devrun.
//
// Battery settings and Activity Monitor's Energy tab charge a process to its resource coalition:
// an app's, which every child inherits, whatever its responsibility (Kore already disclaims that
// for the CLIs, and their builds still counted as Kore's). Only launchd starts a process in a new
// coalition, and an unprivileged process can't make one, so the job runs as a launchd job of its
// own in this user's GUI domain: a plist in a scratch folder (never ~/Library/LaunchAgents),
// booted out when the job ends. The caller keeps its stdout, stderr and exit code (FIFOs and a
// status pipe); its signals go to the job. Outside a Kore the command runs in place.
//
//   kore-devrun [--name NAME] [--] command [args…]   the job (KORE_DEVRUN=always|off overrides)
//   kore-devrun --hold NAME PID                     keeps the Mac from idle sleep while PID lives,
//                                                   as "Kore Dev: NAME" (caffeinate -i -w, named)
//   kore-devrun --who [PID]                         PID's (else this process's) responsible pid,
//                                                   resource coalition and whether it's in a Kore's
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

extern char **environ;
// libsystem's, private: who macOS holds responsible for a process (TCC, Activity Monitor's column).
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid) __attribute__((weak_import));

#define PROC_PIDCOALITIONINFO 20
struct coalition_info { uint64_t id[2]; uint64_t reserved[3]; };

static uint64_t coalition(pid_t pid) {
    struct coalition_info info = {0};
    return proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 1, &info, sizeof info) == sizeof info ? info.id[0] : 0;
}

static pid_t parent(pid_t pid) {
    struct proc_bsdshortinfo info;
    return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof info) == sizeof info ? (pid_t)info.pbsi_ppid : 0;
}

// A Kore app's binary: …/Kore.app/Contents/MacOS/Kore, Kore Dev.app's, a renamed one's.
static int is_kore_app(const char *path) {
    const char *macos = strstr(path, ".app/Contents/MacOS/");
    if (!macos) return 0;
    const char *slash = macos;
    while (slash > path && slash[-1] != '/') slash--;
    return strncmp(slash, "Kore", 4) == 0;
}

// The Kore whose coalition `pid` is in: the nearest ancestor that is a Kore app and shares it.
static pid_t kore_of(pid_t pid) {
    uint64_t mine = coalition(pid);
    if (!mine) return 0;
    for (pid_t p = parent(pid); p > 1; p = parent(p)) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = "";
        if (coalition(p) != mine) return 0;
        if (proc_pidpath(p, path, sizeof path) > 0 && is_kore_app(path)) return p;
    }
    return 0;
}

static int who(pid_t pid) {
    pid_t responsible = responsibility_get_pid_responsible_for_pid ? responsibility_get_pid_responsible_for_pid(pid) : -1;
    printf("pid %d responsible %d coalition %llu kore %d\n", pid, responsible, coalition(pid), kore_of(pid));
    return 0;
}

static IOPMAssertionID hold_awake(const char *name) {
    char reason[256];
    snprintf(reason, sizeof reason, "Kore Dev: %s", name);
    CFStringRef cf = CFStringCreateWithCString(NULL, reason, kCFStringEncodingUTF8);
    IOPMAssertionID id = 0;
    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn, cf, &id);
    CFRelease(cf);
    return id;
}

// Waits (no polling) until `pid` ends.
static void wait_for(pid_t pid) {
    int kq = kqueue();
    struct kevent change;
    EV_SET(&change, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    struct kevent event;
    if (kq < 0 || kevent(kq, &change, 1, &event, 1, NULL) < 0) {
        while (kill(pid, 0) == 0) sleep(5);   // not ours to watch: check now and then
    }
}

static int hold(const char *name, pid_t pid) {
    signal(SIGHUP, SIG_IGN);   // `&!` in the script: it outlives no one but its holder
    hold_awake(name);
    wait_for(pid);
    return 0;
}

// ---- files in the job's folder

static int write_all(int fd, const void *data, size_t size) {
    const char *p = data;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n; size -= (size_t)n;
    }
    return 0;
}

// strings as one file, each ending in NUL
static int put_list(const char *dir, const char *name, char *const *items, int count) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return -1;
    for (int i = 0; i < count || (count < 0 && items[i]); i++)
        if (write_all(fd, items[i], strlen(items[i]) + 1)) { close(fd); return -1; }
    return close(fd);
}

static char **get_list(const char *dir, const char *name) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) return NULL;
    char *data = malloc((size_t)st.st_size + 1);
    ssize_t got = read(fd, data, (size_t)st.st_size);
    close(fd);
    if (got != st.st_size) return NULL;
    data[got] = 0;
    size_t count = 0;
    for (ssize_t i = 0; i < got; i++) if (!data[i]) count++;
    char **items = calloc(count + 1, sizeof *items);
    char *p = data;
    for (size_t i = 0; i < count; i++) { items[i] = p; p += strlen(p) + 1; }
    return items;
}

static int launchctl(const char *verb, const char *what);
static const char *job_files[] = {"status", "out", "err", "argv", "env", "meta", "job.plist"};

// ---- the job, inside launchd: runs the command, says its pid and then its exit code

static int inner(const char *dir) {
    signal(SIGPIPE, SIG_IGN);
    char **argv = get_list(dir, "argv"), **env = get_list(dir, "env"), **meta = get_list(dir, "meta");
    // meta: cwd, umask, open-file limit, merged (one FIFO for stdout and stderr), caller, label
    if (!argv || !argv[0] || !env || !meta) return 1;
    for (int i = 0; i < 6; i++) if (!meta[i]) return 1;
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/status", dir);
    int status = open(path, O_WRONLY);
    if (status < 0) return 1;
    if (getpgrp() != getpid()) setpgid(0, 0);
    char line[64];
    snprintf(line, sizeof line, "pid %d\n", getpid());
    write_all(status, line, strlen(line));

    umask((mode_t)strtol(meta[1], NULL, 8));
    struct rlimit files;
    if (!getrlimit(RLIMIT_NOFILE, &files)) {
        rlim_t want = (rlim_t)strtoull(meta[2], NULL, 10);
        if (want > files.rlim_max) want = files.rlim_max;
        files.rlim_cur = want;
        setrlimit(RLIMIT_NOFILE, &files);
    }
    snprintf(path, sizeof path, "%s/out", dir);
    int out = open(path, O_WRONLY);
    int err = out;
    if (strcmp(meta[3], "1")) { snprintf(path, sizeof path, "%s/err", dir); err = open(path, O_WRONLY); }
    if (out < 0 || err < 0) return 1;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, out, 1);
    posix_spawn_file_actions_adddup2(&actions, err, 2);
    posix_spawn_file_actions_addchdir(&actions, meta[0]);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t none, all;
    sigemptyset(&none); sigfillset(&all);
    posix_spawnattr_setsigmask(&attributes, &none);
    posix_spawnattr_setsigdefault(&attributes, &all);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    // the job's signals reach the whole group: this one stays to report the command's end
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN);

    pid_t child;
    char *const *saved = environ;
    environ = env;   // posix_spawnp searches the job's PATH, not launchd's
    int e = posix_spawnp(&child, argv[0], &actions, &attributes, argv, env);
    environ = (char **)saved;
    int code;
    if (e) {
        dprintf(err, "kore-devrun: %s: %s\n", argv[0], strerror(e));
        code = e == ENOENT ? 127 : 126;
    } else {
        int st = 0;
        while (waitpid(child, &st, 0) < 0 && errno == EINTR) {}
        code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    }
    snprintf(line, sizeof line, "exit %d\n", code);
    write_all(status, line, strlen(line));
    // a caller that's gone can't boot the job out: it goes itself (this process ends with it)
    pid_t caller = (pid_t)atoi(meta[4]);
    if (kill(caller, 0) && errno == ESRCH) {
        for (size_t i = 0; i < sizeof job_files / sizeof *job_files; i++) { snprintf(path, sizeof path, "%s/%s", dir, job_files[i]); unlink(path); }
        rmdir(dir);
        launchctl("bootout", meta[5]);
    }
    return 0;
}

// ---- the caller's side

static volatile sig_atomic_t caught;
static void on_signal(int sig) { caught = sig; }

// In place: this process becomes the command.
static int run(char *const *argv) {
    execvp(argv[0], argv);
    fprintf(stderr, "kore-devrun: %s: %s\n", argv[0], strerror(errno));
    return errno == ENOENT ? 127 : 126;
}

static int launchctl(const char *verb, const char *what) {
    char domain[64];
    snprintf(domain, sizeof domain, "gui/%d", getuid());
    char target[PATH_MAX + 64];
    const char *args[5] = {"launchctl", verb, domain, what, NULL};
    if (!strcmp(verb, "bootout")) { snprintf(target, sizeof target, "%s/%s", domain, what); args[2] = target; args[3] = NULL; }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    pid_t pid;
    if (posix_spawn(&pid, "/bin/launchctl", &actions, NULL, (char *const *)args, environ)) return -1;
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void xml(FILE *f, const char *s) {
    for (; *s; s++) {
        if (*s == '&') fputs("&amp;", f); else if (*s == '<') fputs("&lt;", f); else if (*s == '>') fputs("&gt;", f); else fputc(*s, f);
    }
}

// Copies what's waiting on `from` to `to` (dropped once the caller's end is gone); 0 at EOF/none.
static ssize_t relay(int from, int to, int *open_to) {
    char buf[65536];
    ssize_t n = read(from, buf, sizeof buf);
    if (n > 0 && *open_to && write_all(to, buf, (size_t)n)) *open_to = 0;
    return n;
}

static void clear(const char *dir, int *fds, int *keep) {
    char path[PATH_MAX];
    for (int i = 0; i < 3; i++) { if (fds[i] >= 0) close(fds[i]); if (keep[i] >= 0) close(keep[i]); }
    for (size_t i = 0; i < sizeof job_files / sizeof *job_files; i++) { snprintf(path, sizeof path, "%s/%s", dir, job_files[i]); unlink(path); }
    rmdir(dir);
}

static int job(const char *name, char *const *argv, const char *helper) {
    char dir[PATH_MAX], path[PATH_MAX], cwd[PATH_MAX], label[256];
    int fds[3] = {-1, -1, -1}, keep[3] = {-1, -1, -1};
    const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof dir, "%s/kore-devrun.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    setenv("KORE_DEVRUN_JOB", name, 1);
    if (!mkdtemp(dir)) return run(argv);
    if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "/");
    snprintf(label, sizeof label, "dev.kore.devrun.%s.%d", name, getpid());
    for (char *c = label; *c; c++) if (*c == '/' || *c == ' ') *c = '-';
    // stdout and stderr through one FIFO when they're one file (2>&1): their order holds
    struct stat so, se;
    int merged = !fstat(1, &so) && !fstat(2, &se) && so.st_dev == se.st_dev && so.st_ino == se.st_ino;
    struct rlimit files = {256, 256};
    getrlimit(RLIMIT_NOFILE, &files);
    mode_t mask = umask(022); umask(mask);
    char smask[16], sfiles[32], caller[16];
    snprintf(smask, sizeof smask, "%o", mask);
    snprintf(sfiles, sizeof sfiles, "%llu", (unsigned long long)files.rlim_cur);
    snprintf(caller, sizeof caller, "%d", getpid());
    char *meta[] = {cwd, smask, sfiles, merged ? "1" : "0", caller, label};
    int argc = 0;
    while (argv[argc]) argc++;
    if (put_list(dir, "argv", argv, argc) || put_list(dir, "env", environ, -1) || put_list(dir, "meta", meta, 6)) goto failed;
    for (int i = 0; i < 3; i++) {
        if (i == 2 && merged) continue;
        snprintf(path, sizeof path, "%s/%s", dir, job_files[i]);
        if (mkfifo(path, 0600)) goto failed;
        // a writer of our own: no EOF before the job opens its end, nothing blocks on open
        fds[i] = open(path, O_RDONLY | O_NONBLOCK);
        keep[i] = open(path, O_WRONLY | O_NONBLOCK);
        if (fds[i] < 0 || keep[i] < 0) goto failed;
    }
    snprintf(path, sizeof path, "%s/job.plist", dir);
    FILE *plist = fopen(path, "w");
    if (!plist) goto failed;
    fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n<key>Label</key><string>", plist);
    xml(plist, label);
    fputs("</string>\n<key>ProgramArguments</key><array><string>", plist);
    xml(plist, helper);
    fputs("</string><string>--inner</string><string>", plist);
    xml(plist, dir);
    // Interactive: the priority a terminal's or Kore's children get (31); Standard runs at 20,
    // Adaptive at 4 (throttled), which would slow the gate and skew storyline timings.
    fputs("</string></array>\n<key>RunAtLoad</key><true/>\n<key>ProcessType</key><string>Interactive</string>\n</dict></plist>\n", plist);
    fclose(plist);

    struct sigaction action = {0};
    action.sa_handler = on_signal;
    sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL); sigaction(SIGHUP, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    if (launchctl("bootstrap", path)) {
        fprintf(stderr, "kore-devrun: launchd wouldn't start the job: running it in place\n");
        goto failed;
    }

    pid_t inner_pid = 0;
    int code = -1, open_out = 1, open_err = 1, sent = 0, quiet = 0;
    char status[128] = "";
    size_t got = 0;
    while (code < 0) {
        struct pollfd polls[3];
        int n = 0;
        for (int i = 0; i < 3; i++) if (fds[i] >= 0) polls[n++] = (struct pollfd){fds[i], POLLIN, 0};
        int ready = poll(polls, (nfds_t)n, 2000);
        // the caller's signals go to the job's whole group
        if (caught && inner_pid && sent != caught) { kill(-inner_pid, caught); sent = caught; }
        if (ready < 0) continue;
        if (ready == 0) {
            // the job gone without a word (killed, or launchd never ran it)
            if ((inner_pid && kill(inner_pid, 0) && errno == ESRCH) || (!inner_pid && ++quiet > 15)) break;
            continue;
        }
        relay(fds[1], 1, &open_out);
        if (fds[2] >= 0) relay(fds[2], 2, &open_err);
        ssize_t r = read(fds[0], status + got, sizeof status - 1 - got);
        if (r > 0) {
            got += (size_t)r; status[got] = 0;
            char *pid_line = strstr(status, "pid "), *exit_line = strstr(status, "exit ");
            if (pid_line && !inner_pid) inner_pid = (pid_t)atoi(pid_line + 4);
            if (exit_line && strchr(exit_line, '\n')) code = atoi(exit_line + 5);
        }
    }
    // what the command wrote before it ended
    while (relay(fds[1], 1, &open_out) > 0) {}
    while (fds[2] >= 0 && relay(fds[2], 2, &open_err) > 0) {}
    // its definition goes, and with it anything the command left running in its group
    launchctl("bootout", label);
    clear(dir, fds, keep);
    if (code < 0) { fprintf(stderr, "kore-devrun: the job %s ended without an exit code\n", label); return caught ? 128 + caught : 1; }
    return code;

failed:
    // nothing started: the command runs in place, as it would without kore-devrun
    clear(dir, fds, keep);
    return run(argv);
}

static int usage(void) {
    fputs("usage: kore-devrun [--name NAME] [--] command [args…]\n"
          "       kore-devrun --hold NAME PID\n"
          "       kore-devrun --who [PID]\n", stderr);
    return 2;
}

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "--inner")) return inner(argv[2]);
    if (argc >= 2 && !strcmp(argv[1], "--who")) return who(argc >= 3 ? atoi(argv[2]) : getpid());
    if (argc >= 4 && !strcmp(argv[1], "--hold")) return hold(argv[2], atoi(argv[3]));
    const char *name = "job";
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--")) { i++; break; }
        else if (argv[i][0] == '-') return usage();
        else break;
    }
    if (i >= argc) return usage();
    char helper[PATH_MAX];
    uint32_t size = sizeof helper;
    if (_NSGetExecutablePath(helper, &size)) return usage();
    char real[PATH_MAX];
    if (realpath(helper, real)) strcpy(helper, real);
    const char *mode = getenv("KORE_DEVRUN");
    int away = mode && !strcmp(mode, "always") ? 1 : mode && !strcmp(mode, "off") ? 0 : kore_of(getpid()) != 0;
    if (!away) { setenv("KORE_DEVRUN_JOB", name, 1); return run(argv + i); }
    return job(name, argv + i, helper);
}

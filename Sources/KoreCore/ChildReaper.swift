import Foundation

/// Ends the CLIs Kore started once Kore has gone, however it went (quit, crash, SIGKILL). A
/// `claude -p` that reads EOF on stdin finishes its turn, and waits on background agents, before
/// it exits, so one left behind by Kore keeps acting as an orphan while Kore resumes the same
/// session in a new process.
///
/// It is a small `/bin/sh` reading Kore's lines on a pipe: `+ <pid>` when a child starts and
/// `- <pid>` when it ends. Only the kernel closes that pipe, when Kore exits, and then each child
/// still running gets SIGTERM (it and its process group), and SIGKILL, with every process under
/// it, if it is still there after `grace`. A pid counts as Kore's only while its start time is
/// the one recorded at `+`, so a pid reused by another program is never signalled.
package final class ChildReaper: @unchecked Sendable {
    /// The one every `StdioProcess` reports to, started with the first child.
    package static let shared = ChildReaper(grace: .seconds(5))

    private let grace: Duration
    private let lock = NSLock()
    private var input: FileHandle?
    private var reaper: Process?
    private var failed = false

    package init(grace: Duration) {
        self.grace = grace
    }

    func watch(_ pid: pid_t) { send("+ \(pid)") }
    func forget(_ pid: pid_t) { send("- \(pid)") }

    /// The reaper's pid, once started.
    var pid: pid_t? { lock.withLock { reaper?.processIdentifier } }

    /// What Kore exiting does to the pipe. For tests; Kore never calls it.
    func end() {
        lock.withLock {
            try? input?.close()
            input = nil
            failed = true
        }
    }

    private func send(_ line: String) {
        lock.withLock {
            if input == nil, !failed { start() }
            // Writes to a reaper that died fail with EPIPE (SIGPIPE is ignored); nothing to do then.
            try? input?.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    private func start() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script(tenths: Int(grace / .milliseconds(100)))]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            reaper = process
            input = pipe.fileHandleForWriting
        } catch {
            failed = true
        }
    }

    private static func script(tenths: Int) -> String {
        #"""
        started() { ps -o lstart= -p "$1" 2>/dev/null | tr -d ' '; }
        ours() { [ -n "${1#*:}" ] && [ "$(started "${1%%:*}")" = "${1#*:}" ]; }
        tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
        live=
        while read -r op pid; do
          case $op in
            +) s=$(started "$pid"); [ -n "$s" ] && live="$live $pid:$s" ;;
            -) kept=; for e in $live; do [ "${e%%:*}" = "$pid" ] || kept="$kept $e"; done; live=$kept ;;
          esac
        done
        n=0
        while :; do
          left=; for e in $live; do ours "$e" && left="$left $e"; done
          live=$left
          [ -z "$live" ] && exit 0
          [ $n -ge \#(tenths) ] && break
          if [ $n -eq 0 ]; then
            for e in $live; do kill -TERM -- "-${e%%:*}" 2>/dev/null; kill -TERM "${e%%:*}" 2>/dev/null; done
          fi
          sleep 0.1; n=$((n + 1))
        done
        for e in $live; do
          p=${e%%:*}; all=$(tree "$p")
          kill -KILL -- "-$p" 2>/dev/null; kill -KILL $all 2>/dev/null
        done
        """#
    }
}

import Darwin
import Foundation

/// An owned child process and the work under it. Identities include the kernel start time: a delayed
/// shutdown can never mistake a reused PID for the shell or one of its jobs.
package struct ProcessChild: Sendable, Equatable {
    package let pid: pid_t
    private let seconds: UInt64
    private let microseconds: UInt64

    package init?(_ pid: pid_t) {
        guard pid > 1, let info = Self.info(pid) else { return nil }
        self.init(pid, info: info)
    }

    private init(_ pid: pid_t, info: proc_bsdinfo) {
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }

    package var alive: Bool {
        guard let info = Self.info(pid) else { return false }
        return matches(info) && info.pbi_status != SZOMB
    }

    /// Detects `exec program`, which keeps the shell's PID and foreground group.
    package var executable: String? {
        guard alive else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// An interactive shell is at its prompt when its own group owns the PTY. No timer is
    /// needed: window/terminal close asks this once, including when the panel is hidden.
    package func hasForegroundWork(terminal fd: Int32) -> Bool {
        guard alive, fd >= 0 else { return false }
        let foreground = tcgetpgrp(fd)
        return foreground > 0 && foreground != getpgid(pid)
    }

    /// Captured before parents can die and their children move to launchd. Each process is
    /// signalled by identity, across job-control groups; never the owner's process group.
    package func descendants() -> [ProcessChild] { descendants(stopping: false) }

    private func descendants(stopping: Bool) -> [ProcessChild] {
        guard alive else { return [] }
        var found: [ProcessChild] = []
        var seen: Set<pid_t> = [pid]
        func visit(_ parent: pid_t) {
            let needed = proc_listchildpids(parent, nil, 0)
            guard needed > 0 else { return }
            var children = [pid_t](repeating: 0, count: min(Int(needed) + 32, 65_536))
            // Unlike proc_listpids, proc_listchildpids returns a PID count, not bytes.
            let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return }
            for child in children.prefix(Int(count)) where child > 1 && seen.insert(child).inserted {
                guard let info = Self.info(child), info.pbi_ppid == UInt32(parent), info.pbi_status != SZOMB else { continue }
                let identity = ProcessChild(child, info: info)
                if stopping { identity.signal(SIGSTOP) }
                visit(child)
                found.append(identity)
            }
        }
        visit(pid)
        return found
    }

    package func signal(_ signal: Int32) {
        guard let info = Self.info(pid), matches(info), info.pbi_status != SZOMB else { return }
        kill(pid, signal)
    }

    /// Signal the whole captured tree before its shell ends, then finish stubborn jobs. A
    /// normal close gives applications a short chance to handle the signal; app termination cannot
    /// leave delayed cleanup behind and kills immediately.
    package func close(signal terminationSignal: Int32 = SIGTERM, immediately: Bool = false) {
        let owned = stoppedTree()
        for child in owned { child.signal(terminationSignal); child.signal(SIGCONT) }
        if immediately {
            for child in owned { child.signal(SIGKILL) }
        } else {
            Self.closing.schedule(owned)
        }
    }

    /// Freeze this direct child and each descendant before visiting its children. The
    /// caller must signal/resume every returned identity, including already-stopped jobs.
    package func stoppedTree() -> [ProcessChild] {
        guard alive, Self.info(pid)?.pbi_ppid == UInt32(getpid()) else { return [] }
        signal(SIGSTOP)
        return descendants(stopping: true) + [self]
    }

    /// Finish already-closed trees too when quitting during their grace period.
    package static func finishClosing() { closing.finishAll() }
    private static let closing = Closing()

    private final class Closing: @unchecked Sendable {
        private let lock = NSLock()
        private var trees: [UUID: [ProcessChild]] = [:]

        func schedule(_ children: [ProcessChild]) {
            let id = UUID()
            lock.withLock { trees[id] = children }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(350)) {
                let children = self.lock.withLock { self.trees.removeValue(forKey: id) } ?? []
                for child in children { child.signal(SIGKILL) }
            }
        }
        func finishAll() {
            let children = lock.withLock {
                let children = trees.values.flatMap { $0 }
                trees = [:]
                return children
            }
            for child in children { child.signal(SIGKILL) }
        }
    }

    private func matches(_ info: proc_bsdinfo) -> Bool {
        info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == microseconds
    }

    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}

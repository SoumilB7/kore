#if !canImport(Darwin)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// An owned child process and the work under it, read from /proc. Identities include the kernel
/// start time: a delayed shutdown can never mistake a reused PID for the shell or one of its jobs.
package struct ProcessChild: Sendable, Equatable {
    package let pid: pid_t
    private let started: UInt64

    package init?(_ pid: pid_t) {
        guard pid > 1, let info = Self.info(pid) else { return nil }
        self.pid = pid
        started = info.started
    }

    private init(_ pid: pid_t, started: UInt64) {
        self.pid = pid
        self.started = started
    }

    package var alive: Bool {
        guard let info = Self.info(pid) else { return false }
        return info.started == started && !info.zombie
    }

    package var executable: String? {
        guard alive, let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") else { return nil }
        return path
    }

    package func hasForegroundWork(terminal fd: Int32) -> Bool {
        guard alive, fd >= 0 else { return false }
        let foreground = tcgetpgrp(fd)
        return foreground > 0 && foreground != getpgid(pid)
    }

    package func descendants() -> [ProcessChild] { descendants(stopping: false) }

    private func descendants(stopping: Bool) -> [ProcessChild] {
        guard alive else { return [] }
        let all = Self.table()
        var found: [ProcessChild] = []
        var seen: Set<pid_t> = [pid]
        func visit(_ parent: pid_t) {
            for (child, info) in all where info.ppid == parent && !info.zombie && seen.insert(child).inserted {
                let identity = ProcessChild(child, started: info.started)
                if stopping { identity.signal(SIGSTOP) }
                visit(child)
                found.append(identity)
            }
        }
        visit(pid)
        return found
    }

    package func signal(_ signal: Int32) {
        guard let info = Self.info(pid), info.started == started, !info.zombie else { return }
        kill(pid, signal)
    }

    package func close(signal terminationSignal: Int32 = SIGTERM, immediately: Bool = false) {
        let owned = stoppedTree()
        for child in owned { child.signal(terminationSignal); child.signal(SIGCONT) }
        if immediately {
            for child in owned { child.signal(SIGKILL) }
        } else {
            Self.closing.schedule(owned)
        }
    }

    package func stoppedTree() -> [ProcessChild] {
        guard alive, Self.info(pid)?.ppid == getpid() else { return [] }
        signal(SIGSTOP)
        return descendants(stopping: true) + [self]
    }

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

    package static func parent(of pid: pid_t) -> pid_t? {
        guard pid > 1, let info = info(pid), !info.zombie else { return nil }
        return info.ppid
    }

    private struct Info {
        let ppid: pid_t
        let started: UInt64
        let zombie: Bool
    }

    /// /proc/<pid>/stat: the state (3rd field), the parent (4th) and the start time (22nd),
    /// after the command's closing parenthesis.
    private static func info(_ pid: pid_t) -> Info? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ppid = pid_t(fields[1]), let started = UInt64(fields[19]) else { return nil }
        return Info(ppid: ppid, started: started, zombie: fields[0] == "Z")
    }

    private static func table() -> [(pid_t, Info)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return names.compactMap { name in pid_t(name).flatMap { pid in info(pid).map { (pid, $0) } } }
    }
}
#endif

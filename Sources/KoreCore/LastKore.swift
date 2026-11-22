import Foundation

/// The CLIs the last Kore left. Kore gone by a crash or a kill leaves them to its `ChildReaper`:
/// SIGTERM at once, what outlasts its grace killed. A Kore started meanwhile starts no CLI on a
/// session before that reaper is done (`gone`), so a session never has its old CLI and a new one
/// live at once. The old CLI can't be found by its session (Codex's app-server doesn't name its
/// thread), but its reaper can: a running reaper with no Kore over it. With none, which is nearly
/// always, nothing waits.
package final class LastKore: Sendable {
    /// This Kore's, looked for once, at its first CLI on a session. Tests set their own.
    package static let shared = HostSetting(LastKore())

    /// How long past its grace a reaper is waited for: its passes take longer on a busy Mac, and
    /// one that never ends can't keep a chat from starting.
    static let slack: Duration = .seconds(5)

    package init() {}

    #if canImport(Darwin)
    private let search = HostSetting<Task<(left: [ProcessChild], until: ContinuousClock.Instant), Never>?>(nil)

    /// Returns once the last Kore's CLIs have ended, and how long that took; throws when cancelled.
    @discardableResult
    package func gone() async throws -> Duration {
        let looking = search.value ?? Task.detached(priority: .userInitiated) {
            (Self.reapers(), .now + ChildReaper.graceAfterTerm + Self.slack)
        }
        search.value = looking
        let (left, until) = await looking.value
        let began = ContinuousClock.now
        while ContinuousClock.now < until, left.contains(where: \.alive) {
            try await Task.sleep(for: .milliseconds(50))
        }
        return left.isEmpty ? .zero : ContinuousClock.now - began
    }

    /// The reapers whose Kore has gone: their parent is launchd, as any orphan's is.
    static func reapers() -> [ProcessChild] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)
            .filter { ProcessChild.parent(of: $0) == 1 && isReaper($0) }
            .compactMap { ProcessChild($0) }
    }

    /// A shell running the reaper's script, this version's or another's (`ChildReaper.opening`).
    static func isReaper(_ pid: pid_t) -> Bool {
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0,
            ["sh", "bash", "dash", "zsh"].contains(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        else { return false }
        // Its arguments can't be read for a moment just after its Kore went (EIO): asked again,
        // briefly. Only an orphaned shell gets here.
        for attempt in 0..<20 {
            if attempt > 0 { usleep(5_000) }
            guard let arguments = arguments(pid) else { continue }
            return arguments.range(of: Data(ChildReaper.opening.utf8)) != nil
        }
        return false
    }

    /// Its executable, arguments and environment as the kernel keeps them; nil when unreadable now.
    private static func arguments(_ pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var arguments = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &arguments, &size, nil, 0) == 0 else { return nil }
        return Data(arguments.prefix(size))
    }
    #else
    @discardableResult
    package func gone() async throws -> Duration { .zero }
    #endif
}

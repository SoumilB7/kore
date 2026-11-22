import Foundation

/// How high a session's mode may go without its owner: a chat a phone had copied or forked
/// (`chat.copyVia`, `chat.fork`), whose history may end in a higher mode than the phone may give.
/// Kept by session on the machine that has it, so it holds through replay, a restart, a rest and a
/// move; the owner picking a higher mode (or a phone's fingerprint) raises it to that one.
package enum ModeCeilings {
    private static let key = "modeCeilings"
    /// Two puts at once each keep theirs.
    private static let lock = NSLock()

    package static func at(_ session: String) -> Int? { all[session] }

    /// `level` nil: none (any mode its history ends in).
    package static func put(_ level: Int?, for session: String) {
        lock.lock()
        defer { lock.unlock() }
        var ceilings = all
        guard ceilings[session] != level else { return }
        ceilings[session] = level
        UserDefaults.standard.set(ceilings, forKey: key)
        // Written now on a box too: Foundation there keeps it in memory until asked.
        UserDefaults.standard.synchronize()
    }

    private static var all: [String: Int] { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
}

extension ProviderDescriptor {
    /// `mode` under `ceiling`: itself at or below it, else the first mode (Manual). One it doesn't
    /// know is never under one.
    package func held(_ mode: String, under ceiling: Int?) -> String {
        guard let ceiling else { return mode }
        guard let level = modes.first(where: { $0.id == mode })?.level, level <= ceiling else { return modes[0].id }
        return mode
    }

    /// The ceiling once the owner picks `mode`: that mode's own level (the highest holds nothing,
    /// and is kept, so a move says it was raised).
    package func ceiling(picking mode: String) -> Int { modes.first { $0.id == mode }?.level ?? 0 }
}

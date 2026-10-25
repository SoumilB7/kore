import Foundation
import Observation

/// How full the chat's context is, and whether it's being compacted: what the composer's wheel
/// shows. Usage comes from the CLI (main agent only); "compacting" runs from the CLI's start
/// (or Kore's click) to its compaction or failure.
@MainActor @Observable
final class ContextStore {
    private(set) var usage: ContextUsage?
    private(set) var compacting = false
    /// Kore compacts by itself when a turn ends at or past this percent of the window (one of
    /// `snapPoints`); nil: off, and the CLI compacts at its own limit (the ring's end).
    var autoCompactAt: Int?

    /// Where the auto-compact point can go; past the last is off.
    nonisolated static let snapPoints = [50, 60, 70, 80, 90]

    func apply(_ event: ChatEvent) {
        switch event {
        case .contextUsage(let next):
            usage = next
        case .compactionStarted:
            compacting = true
        case .compacted, .compactionFailed, .compactionStopped, .exited:
            compacting = false
        case .replayed(let events):
            events.forEach(apply)
            // A past compaction that never finished isn't still running.
            compacting = false
        default:
            break
        }
    }

    /// Kore asked for a compaction; the CLI's own start may follow.
    func begin() { compacting = true }

    /// The compaction Kore asked for never reached the CLI (it didn't start).
    func end() { compacting = false }

    /// Used / window, 0…1; nil until the CLI has said its window.
    var fraction: Double? {
        guard let usage, let window = usage.window, window > 0 else { return nil }
        return min(max(Double(usage.used) / Double(window), 0), 1)
    }

    /// The point as a fraction of the window, for the ring and the track.
    var threshold: Double? { autoCompactAt.map { Double($0) / 100 } }

    /// Usage has reached the point: the turn ending now compacts.
    var pastPoint: Bool {
        guard let fraction, let threshold else { return false }
        return fraction >= threshold
    }

    /// The tokens in use, "~58k" while they're Kore's estimate.
    var usedText: String {
        guard let usage else { return "" }
        return (usage.approximate ? "~" : "") + Self.tokens(usage.used)
    }

    /// 1.2k, 18k, 403k, 1.1M, 12M (T3 Code's format): at most three figures, the one token count
    /// every view shows (the context wheel, the agent rows and the map).
    static func tokens(_ count: Int) -> String {
        let k = (Double(count) / 1_000 * 10).rounded() / 10
        let m = (Double(count) / 1_000_000 * 10).rounded() / 10
        switch count {
        case ..<1_000: return "\(count)"
        case _ where k < 10: return trimmed(k) + "k"
        case _ where k.rounded() < 1_000: return "\(Int(k.rounded()))k"
        case _ where m < 10: return trimmed(m) + "M"
        default: return "\(Int(m.rounded()))M"
        }
    }

    /// One decimal, without a trailing ".0".
    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// "62%", or "<1%" for a sliver.
    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }
}

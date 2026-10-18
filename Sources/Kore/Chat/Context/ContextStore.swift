import Foundation
import Observation

/// How full the chat's context is, and whether it's being compacted: what the composer's wheel
/// shows. Usage comes from the CLI (main agent only); "compacting" runs from the CLI's start
/// (or Kore's click) to its compaction or failure.
@MainActor @Observable
final class ContextStore {
    private(set) var usage: ContextUsage?
    private(set) var compacting = false
    /// Tokens before the last compaction, until the next message is sent ("Compacted from 152k";
    /// the new size arrives right after the compaction).
    private(set) var compactedFrom: Int?

    func apply(_ event: ChatEvent) {
        switch event {
        case .contextUsage(let next):
            usage = next
        case .userMessage:
            compactedFrom = nil
        case .compactionStarted:
            compacting = true
        case .compacted(_, let from, _):
            compacting = false
            compactedFrom = from
        case .compactionFailed, .exited:
            compacting = false
        case .replayed(let events):
            events.forEach(apply)
            compactedFrom = nil
            // A past compaction that never finished isn't still running.
            compacting = false
        default:
            break
        }
    }

    /// Kore asked for a compaction; the CLI's own start may follow.
    func begin() { compacting = true }

    /// Used / window, 0…1; nil until the CLI has said its window.
    var fraction: Double? {
        guard let usage, let window = usage.window, window > 0 else { return nil }
        return min(max(Double(usage.used) / Double(window), 0), 1)
    }

    /// 1.2k, 18k, 1.1M (T3 Code's format).
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<10_000: return trimmed(Double(count) / 1_000) + "k"
        case ..<1_000_000: return "\(Int((Double(count) / 1_000).rounded()))k"
        default: return trimmed(Double(count) / 1_000_000) + "M"
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

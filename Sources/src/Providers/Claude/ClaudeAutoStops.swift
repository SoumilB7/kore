import Foundation
import KoreCore

/// Calls Auto refused without asking anyone (the owner via Kore-main, 2026-11-19;
/// z-docs/design/cli-wiring.md, "Auto asks"): the safety check's critical removals, which Auto
/// never runs, and the classifier's blocks outside Kore's ask list. The CLI already answered
/// them; Kore shows a card saying what was stopped and why, so nothing is refused unseen. Nothing
/// on it runs the call: Auto never runs a critical removal, and no mode is switched for it.
@MainActor
package final class ClaudeAutoStops {
    nonisolated package static let idPrefix = "autostop-"
    /// The CLI's own words (claude 2.1.318) for the two hard stops.
    nonisolated package static let classifierDenial = "Permission for this action was denied by the Claude Code auto mode classifier"
    nonisolated package static let safetyDenial = "Permission for this command was denied by a built-in Claude Code safety check"
    nonisolated package static let safetyLine = "Auto never runs this; switch the chat to Manual if you mean it."
    nonisolated package static let classifierLine = "Auto's check refused this; switch the chat to Manual if you mean it."

    package struct Card: Equatable, Sendable {
        package let id: String
        package let title: String
        package let line: String
    }

    private var shown: Set<String> = []

    package init() {}

    /// A call's error: its card, when it's one of Auto's hard stops (once per call).
    package func denied(toolUseId: String, tool: String, input: JSONValue, error text: String) -> Card? {
        let safety = text.hasPrefix(Self.safetyDenial)
        guard safety || text.hasPrefix(Self.classifierDenial), shown.insert(toolUseId).inserted else { return nil }
        let what = input["command"]?.string ?? input["file_path"]?.string ?? tool
        let reason = safety ? "a removal Auto never runs" : Self.reason(text)
        return Card(
            id: Self.idPrefix + toolUseId, title: "Auto stopped: \(Self.oneLine(what, max: 120))" + (reason.isEmpty ? "" : " (\(reason))"),
            line: safety ? Self.safetyLine : Self.classifierLine)
    }

    /// The process ended: the cards it raised go with it.
    package func exited() -> [String] {
        defer { shown = [] }
        return shown.sorted().map { Self.idPrefix + $0 }
    }

    /// The classifier's reason ("[Undermining Oversight]" → "Undermining Oversight").
    nonisolated static func reason(_ text: String) -> String {
        guard let range = text.range(of: "Reason: ") else { return "" }
        var reason = text[range.upperBound...].prefix { $0 != "\n" && $0 != "." }
        reason = reason.drop { $0 == "[" }
        if reason.hasSuffix("]") { reason = reason.dropLast() }
        return oneLine(String(reason), max: 60)
    }

    nonisolated static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}

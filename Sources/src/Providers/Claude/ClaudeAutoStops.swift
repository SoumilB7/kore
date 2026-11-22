import AgentTools
import Foundation
import KoreCore

/// Auto stops (the owner via Kore-main, 2026-11-22; z-docs/design/cli-wiring.md, "Auto stops"):
/// in Auto, Claude's own check is the only judge, and a refusal mid-turn is no card: Claude
/// usually goes another way. Kore notes each refusal of the turn (`system/permission_denied`, and
/// the refused `tool_result`) with its call's command; when the turn ends with the LAST call
/// refused and nothing run after it, Claude stopped for it, and one card says so: Run once (a
/// one-time pass, `KoreAskList.Pass`), Always allow (the kind, `KoreAlwaysRule`, in the project's
/// local settings) or Dismiss. A critical removal is only the person's, in Manual mode.
@MainActor
package final class ClaudeAutoStops {
    nonisolated package static let idPrefix = "autostop-"
    /// The CLI's own words (claude 2.1.318) for its refusals in Auto.
    nonisolated package static let classifierDenial = "Permission for this action was denied by the Claude Code auto mode classifier"
    nonisolated package static let safetyDenial = "Permission for this command was denied by a built-in Claude Code safety check"
    nonisolated package static let otherDenial = "Permission for this action has been denied. Reason: "
    /// A critical removal's card: no Run once, no Always allow.
    nonisolated package static let criticalLine = "Only you, in Manual mode."
    /// How long a Run once pass waits for its command.
    nonisolated package static let passLife: TimeInterval = 600

    nonisolated package static func title(_ command: String) -> String { "Claude stopped: it needs `\(oneLine(command, max: 120))`" }
    /// What the chat is sent after Run once or Always allow.
    nonisolated package static func continueMessage(_ command: String) -> String { "You may run `\(command)` once now; continue." }

    /// A refused call's error text, in the CLI's words.
    nonisolated package static func isRefusal(_ text: String) -> Bool {
        text.hasPrefix(classifierDenial) || text.hasPrefix(safetyDenial) || text.hasPrefix(otherDenial)
    }

    package struct Card: Equatable, Sendable {
        package let id: String
        package let command: String
        package let cwd: String
        /// `KoreAlwaysRule.critical`: only the person, in Manual mode.
        package let critical: Bool
        /// What Always allow keeps (`KoreAlwaysRule.rule`); nil: none.
        package let rule: String?
        package var title: String { ClaudeAutoStops.title(command) }

        package init(id: String, command: String, cwd: String, critical: Bool, rule: String?) {
            self.id = id
            self.command = command
            self.cwd = cwd
            self.critical = critical
            self.rule = rule
        }

        /// The card as the chat shows it.
        package var approval: Approval {
            var approval = Approval(
                id: id, title: title, detail: critical ? ClaudeAutoStops.criticalLine : nil, body: nil, canAlwaysAllow: !critical && rule != nil,
                questions: [])
            approval.autoStop = true
            approval.tool = "Bash"
            approval.command = command
            approval.cwd = cwd
            approval.alwaysRule = critical ? nil : rule
            approval.allowNote = critical ? ClaudeAutoStops.criticalLine : nil
            approval.retryMessage = critical ? nil : ClaudeAutoStops.continueMessage(command)
            return approval
        }
    }

    /// The clock: a test's virtual one.
    package var now: () -> Date = Date.init

    /// The main agent's calls this turn, and the last one.
    private var calls: [String: (tool: String, input: JSONValue)] = [:]
    private var last: String?
    /// This turn's refused calls, by tool_use id.
    package private(set) var refused: [String] = []
    package private(set) var card: Card?
    private var pass: KoreAskList.Pass?

    package init() {}

    /// The main agent called a tool: it is the turn's last call until another comes.
    package func called(_ id: String, tool: String, input: JSONValue) {
        if calls.count > 256 { calls.removeAll() }
        calls[id] = (tool, input)
        last = id
    }

    /// The CLI refused a call (`permission_denied`, or its result's text).
    package func denied(_ id: String) {
        if !refused.contains(id) { refused.append(id) }
    }

    package func result(_ id: String, isError: Bool, text: String) {
        if isError, Self.isRefusal(text) { denied(id) }
    }

    /// The turn ended: its card, when its last call was a refused command (only in Auto).
    package func turnEnded(cwd: String, auto: Bool = true) -> Card? {
        defer {
            calls.removeAll()
            last = nil
            refused.removeAll()
        }
        guard auto, let id = last, refused.contains(id), let call = calls[id], call.tool == "Bash", let command = call.input["command"]?.string else { return nil }
        let critical = KoreAlwaysRule.critical(command, cwd: cwd)
        let card = Card(
            id: Self.idPrefix + id, command: command, cwd: cwd, critical: critical, rule: critical ? nil : KoreAlwaysRule.rule(for: command, cwd: cwd))
        self.card = card
        return card
    }

    /// Dismiss, a new message, or the process gone: the card's id, to withdraw.
    package func dismiss() -> String? {
        defer { card = nil }
        return card?.id
    }

    /// Run once on the card `id`: a pass for exactly its command in this chat, once, for `passLife`.
    package func runOnce(_ id: String) -> KoreAskList.Pass? {
        guard let card, card.id == id, !card.critical else { return nil }
        self.card = nil
        pass = KoreAskList.Pass(command: card.command, cwd: card.cwd, until: now().addingTimeInterval(Self.passLife))
        return pass
    }

    /// The pass, while it is open (an expired one is gone).
    package var openPass: KoreAskList.Pass? {
        if let pass, now().timeIntervalSince1970 >= pass.until { self.pass = nil }
        return pass
    }

    /// The CLI asks about the pass's command (Kore's hook said "ask"): Kore allows it, and the
    /// pass is spent.
    package func spend(_ r: PermissionRequest) -> Bool {
        guard let pass = openPass, r.toolName == "Bash", r.decisionReasonType == "hook", r.decisionReason == KoreAskList.passReason,
            let command = r.input["command"]?.string, pass.covers(command, at: now())
        else { return false }
        self.pass = nil
        return true
    }

    /// The process ended: the turn's notes go with it (a card is withdrawn by the caller).
    package func exited() {
        calls.removeAll()
        last = nil
        refused.removeAll()
    }

    nonisolated static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}

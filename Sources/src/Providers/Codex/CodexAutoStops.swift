import Foundation
import KoreCore

/// Approve for me's reviewer (Codex's auto-review) refused a call (the owner via Kore-main,
/// 2026-11-19; z-docs/design/cli-wiring.md, "Auto asks"): `item/autoApprovalReview/completed`
/// with `denied` or `timedOut`. Kore shows it as a card. Run once is Codex's own
/// `thread/approveGuardianDeniedAction`: one retry of that action, which the model sees, and which
/// still goes through the reviewer; a critical-risk denial is never overridden, so its card only
/// says so. Nothing is written to Codex's settings.
@MainActor
package final class CodexAutoStops {
    nonisolated package static let idPrefix = "codexstop-"
    nonisolated package static let criticalLine = "Codex never runs a critical-risk action this way; switch the chat to Ask for approval if you mean it."

    package struct Card: Sendable, Equatable {
        package let id: String
        package let title: String
        package let command: String
        /// The review as `thread/approveGuardianDeniedAction` takes it back.
        package let event: JSONValue
        /// Why Run once can't: a critical-risk denial.
        package let refusal: String?
    }

    private var cards: [String: Card] = [:]

    package init() {}

    /// A finished review: its card when it refused the call.
    package func reviewed(_ params: JSONValue) -> Card? {
        let review = params["review"] ?? .null
        guard let status = review["status"]?.string, ["denied", "timedOut"].contains(status), let reviewId = params["reviewId"]?.string,
            cards[Self.idPrefix + reviewId] == nil
        else { return nil }
        let command = Self.shown(params["action"] ?? .null)
        let why = review["rationale"]?.string.map { Self.oneLine($0, max: 80) } ?? (status == "timedOut" ? "the review timed out" : "")
        let critical = review["riskLevel"]?.string == "critical"
        let card = Card(
            id: Self.idPrefix + reviewId, title: "Auto stopped: \(Self.oneLine(command, max: 120))" + (why.isEmpty ? "" : " (\(why))"),
            command: command, event: Self.event(params), refusal: critical ? Self.criticalLine : nil)
        cards[card.id] = card
        return card
    }

    /// The card answered (or gone): it's taken.
    package func take(_ id: String) -> Card? { cards.removeValue(forKey: id) }

    /// The message that asks the agent to run it again, when the chat is idle by then.
    nonisolated package static func retry(_ command: String) -> String { "Run once: `\(oneLine(command, max: 200))`" }

    package func exited() -> [String] {
        defer { cards = [:] }
        return cards.keys.sorted()
    }

    /// The action's command as the person reads it: `/bin/zsh -lc '<command>'` unwrapped.
    nonisolated static func shown(_ action: JSONValue) -> String {
        if let command = action["command"]?.string {
            for shell in ["/bin/zsh -lc '", "/bin/zsh -c '", "/bin/bash -lc '", "/bin/bash -c '", "bash -lc '", "zsh -lc '"]
            where command.hasPrefix(shell) && command.hasSuffix("'") {
                return String(command.dropFirst(shell.count).dropLast())
            }
            return command
        }
        if let program = action["program"]?.string {
            return ([program] + (action["argv"]?.array ?? []).dropFirst().compactMap(\.string)).joined(separator: " ")
        }
        return action["type"]?.string ?? "an action"
    }

    /// `item/autoApprovalReview/completed`'s params as the internal `GuardianAssessmentEvent`
    /// (codex-cli 0.170.0 checks its variant names: `unified_exec`, not `unifiedExec`).
    nonisolated static func event(_ params: JSONValue) -> JSONValue {
        let review = params["review"] ?? .null
        var event: [String: JSONValue] = [
            "id": params["reviewId"] ?? .null, "turn_id": params["turnId"] ?? .null,
            "status": .string(snake(review["status"]?.string ?? "denied")),
            "decision_source": .string(snake(params["decisionSource"]?.string ?? "agent")),
            "action": snaked(params["action"] ?? .null),
        ]
        if let target = params["targetItemId"] { event["target_item_id"] = target }
        if let risk = review["riskLevel"]?.string { event["risk_level"] = .string(snake(risk)) }
        if let authorization = review["userAuthorization"]?.string { event["user_authorization"] = .string(snake(authorization)) }
        if let rationale = review["rationale"] { event["rationale"] = rationale }
        return .object(event)
    }

    /// An object's keys and its `type`, `source` and `status` values in snake_case.
    nonisolated static func snaked(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, field) in fields {
                if ["type", "source", "status"].contains(key), let text = field.string {
                    out[snake(key)] = .string(snake(text))
                } else {
                    out[snake(key)] = snaked(field)
                }
            }
            return .object(out)
        case .array(let items): return .array(items.map(snaked))
        default: return value
        }
    }

    nonisolated static func snake(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }

    nonisolated static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}

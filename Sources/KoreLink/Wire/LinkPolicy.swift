import Foundation

/// What the local link may do in Kore, decided again for every command against the chat as it is
/// when the command is applied. The lists are frozen (`z-docs/link-protocol.md` §6): a change takes
/// a doc change and the owner's approval first. The link reaches Kore's chats, not the Mac: it can
/// follow, answer and send to them in any mode (owner, 2026-11-01), but never raise how much an
/// agent may do without asking.
package enum LinkPolicy {
    /// The most permissive mode a chat may be in for the link to send to it: every mode.
    package static let sendMaxLevel = ModeLevel.danger
    /// The most permissive mode the link may leave plan into: leaving plan into a mode where tools
    /// don't ask raises how much the agent may do.
    package static let leavePlanMaxLevel = ModeLevel.manual
    /// The longest message the link may send.
    package static let maxText = 64 * 1024
    /// Slash commands the link may send: compacting only. Others can run shell or switch accounts.
    package static let commands: Set<String> = ["compact"]

    /// One chat as the policy sees it.
    package struct ChatFacts: Sendable, Equatable {
        package struct Card: Sendable, Equatable {
            package var kind: LinkCard.Kind
            package var digest: String
            package init(kind: LinkCard.Kind, digest: String) {
                self.kind = kind
                self.digest = digest
            }
        }

        /// The mode's level, and whether a plan switch kept apart from the modes is on (Codex).
        package var level: ModeLevel
        package var planOn: Bool
        /// The levels of the modes this chat offers, by id.
        package var modes: [String: ModeLevel]
        /// Cards waiting, by id.
        package var cards: [String: Card]

        package init(level: ModeLevel, planOn: Bool = false, modes: [String: ModeLevel], cards: [String: Card] = [:]) {
            self.level = level
            self.planOn = planOn
            self.modes = modes
            self.cards = cards
        }

        /// What the agent may do now: a plan switch that's on means planning, whatever the mode.
        package var effectiveLevel: ModeLevel { planOn ? .plan : level }
    }

    package enum Verdict: Sendable, Equatable {
        case allow
        case deny(ResultCode, String)
    }

    package static func check(_ command: LinkCommand, _ chat: ChatFacts?) -> Verdict {
        switch command {
        case .unknown: return .deny(.invalid, "Kore doesn't know that command.")
        case .new: return .allow
        default: break
        }
        guard let chat else { return .deny(.goneChat, "That chat isn't open in Kore any more.") }
        switch command {
        case .send(_, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, text.utf8.count <= maxText else { return .deny(.invalid, "Nothing to send, or too long.") }
            if trimmed.hasPrefix("/") {
                let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
                guard commands.contains(String(name)) else { return .deny(.command, "Only /compact can be sent over the link.") }
            }
            // The claude CLI runs a message starting with "!" as a shell command.
            if trimmed.hasPrefix("!") { return .deny(.command, "Shell commands can't be sent over the link.") }
            return .allow
        case .stop:
            return .allow
        case .answer(_, let cardId, let action, let digest, _):
            guard let card = chat.cards[cardId] else { return .deny(.goneCard, "That was answered or withdrawn.") }
            if card.kind == .signIn { return .deny(.signIn, "Answer sign-ins in Kore.") }
            switch action {
            case .allowAlways: return .deny(.alwaysAllow, "Always allow can only be set in Kore.")
            case .approvePlanAcceptEdits: return .deny(.raiseMode, "Approving with auto-accept edits raises the mode; do it in Kore.")
            default: break
            }
            guard actions(card.kind).contains(action) else { return .deny(.action, "That card doesn't take that answer.") }
            guard digest == card.digest else { return .deny(.staleCard, "The card changed; look again.") }
            return .allow
        case .setMode(_, let modeId):
            guard let target = chat.modes[modeId] else { return .deny(.invalid, "This chat doesn't offer that mode.") }
            return target <= chat.level ? .allow : .deny(.raiseMode, "The link can only lower a chat's mode.")
        case .setPlan(_, let on):
            // Plan is the lowest level: on lowers. Off goes back to the chat's own mode, which the
            // link may do only where tools still ask.
            return on || !chat.planOn || chat.level <= leavePlanMaxLevel ? .allow : .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore.")
        case .planReady(_, let choice):
            guard chat.cards.values.contains(where: { $0.kind == .planReady }) else { return .deny(.goneCard, "No plan is waiting.") }
            return choice == .stay || chat.level <= leavePlanMaxLevel
                ? .allow : .deny(.raiseMode, "Implementing leaves plan, which raises the mode; do it in Kore.")
        case .new, .unknown:
            return .allow
        }
    }

    /// The answers each kind of card takes over the link. `approvePlan` starts the work in Manual.
    package static func actions(_ kind: LinkCard.Kind) -> Set<CardAction.ID> {
        switch kind {
        case .permission: [.allow, .deny]
        case .questions: [.submitAnswers, .deny]
        case .plan: [.approvePlan, .keepPlanning]
        case .planReady: [.implement, .stay]
        case .signIn, .unknown: []
        }
    }

    /// The modes the link may switch a chat to: its own level and below.
    package static func allowedModes(_ chat: ChatFacts) -> Set<String> {
        Set(chat.modes.filter { $0.value <= chat.level }.keys)
    }
}

/// At most `limit` in any `window`.
package struct RateLimiter: Sendable {
    let limit: Int
    let window: TimeInterval
    private var times: [Date] = []

    package init(limit: Int, per window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// Takes one if there's room at `now`.
    package mutating func take(at now: Date = Date()) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= window }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}

/// Messages a second: a token bucket with a burst. Past 4× the rate (the bucket far in debt), the
/// link ends.
package struct MessageBucket: Sendable {
    package let rate: Double
    package let burst: Double
    private var tokens: Double
    private var debt: Double = 0
    private var last: Date?

    package init(rate: Double = 20, burst: Double = 40) {
        self.rate = rate
        self.burst = burst
        tokens = burst
    }

    package enum Verdict: Sendable, Equatable { case ok, over, far }

    package mutating func take(at now: Date = Date()) -> Verdict {
        if let last {
            let refill = now.timeIntervalSince(last) * rate
            tokens = min(burst, tokens + refill)
            debt = max(0, debt - refill)
        }
        last = now
        if tokens >= 1 {
            tokens -= 1
            return .ok
        }
        debt += 1
        // A second's worth at 4× the rate, past the burst.
        return debt > rate * 3 + burst ? .far : .over
    }
}

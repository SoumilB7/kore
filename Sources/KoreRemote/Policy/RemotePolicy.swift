import Foundation

/// What a phone may do on this Mac, decided again for every command. The phone reaches Kore's
/// chats, not the laptop: it can follow and answer them, but never raise how much an agent may do
/// without asking, and it sends only to chats where tools still ask (Manual and Plan, by default).
package enum RemotePolicy {
    /// What the Mac lets a paired phone do (the owner can widen it on the Mac).
    package struct Grant: Sendable, Equatable {
        /// The most permissive mode a chat may be in for the phone to send to it.
        package var sendMaxLevel: ModeLevel = .manual
        /// "Yes, and auto-accept edits" on a plan: a raise to Edits.
        package var approvePlanWithEdits = false

        package init(sendMaxLevel: ModeLevel = .manual, approvePlanWithEdits: Bool = false) {
            self.sendMaxLevel = sendMaxLevel
            self.approvePlanWithEdits = approvePlanWithEdits
        }
    }

    /// One chat as the policy sees it.
    package struct ChatFacts: Sendable, Equatable {
        package struct Card: Sendable, Equatable {
            package var kind: WireCard.Kind
            package init(kind: WireCard.Kind) { self.kind = kind }
        }

        /// The mode's level, and whether a plan switch kept apart from the modes is on (Codex).
        package var level: ModeLevel
        package var planOn: Bool
        /// The levels of the modes this chat offers, by id.
        package var modes: [String: ModeLevel]
        /// Cards waiting, by id.
        package var cards: [String: Card]
        /// Text that starts a message the CLI would read as its own command.
        package var commandPrefix = "/"

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

    /// The longest message the phone may send.
    package static let maxText = 64 * 1024
    /// Slash commands the phone may send: compacting only. Others can run shell or switch accounts.
    package static let commands: Set<String> = ["compact"]

    package static func check(_ command: RemoteCommand, _ chat: ChatFacts?, grant: Grant) -> Verdict {
        if case .new = command { return .allow }
        guard let chat else { return .deny(.goneChat, "That chat isn't open on the Mac any more.") }
        switch command {
        case .send(_, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, text.utf8.count <= maxText else { return .deny(.invalid, "Nothing to send, or too long.") }
            guard chat.effectiveLevel <= grant.sendMaxLevel else {
                return .deny(.sendCap, "This chat acts without asking; send to it from the Mac.")
            }
            if trimmed.hasPrefix("/") {
                let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
                guard commands.contains(String(name)) else { return .deny(.command, "Only /compact can be sent from the phone.") }
            }
            // The claude CLI runs a message starting with "!" as a shell command.
            if trimmed.hasPrefix("!") { return .deny(.command, "Shell commands can't be sent from the phone.") }
            return .allow
        case .stop:
            return .allow
        case .answer(_, let cardId, let action, _, _):
            guard let card = chat.cards[cardId] else { return .deny(.goneCard, "That was answered or withdrawn.") }
            if card.kind == .signIn { return .deny(.signIn, "Answer sign-ins on the Mac.") }
            switch action {
            case .allowAlways: return .deny(.alwaysAllow, "Always allow can only be set on the Mac.")
            case .approvePlanAcceptEdits:
                guard card.kind == .plan, grant.approvePlanWithEdits else {
                    return .deny(.raiseMode, "Approving with auto-accept edits raises the mode; do it on the Mac.")
                }
                return .allow
            case .approvePlan:
                // Approving starts the work in Manual: every tool still asks.
                guard card.kind == .plan else { return .deny(.action, "That card doesn't take that answer.") }
                return ModeLevel.manual <= grant.sendMaxLevel ? .allow : .deny(.raiseMode, "Approve this plan on the Mac.")
            default:
                return actions(card.kind).contains(action) ? .allow : .deny(.action, "That card doesn't take that answer.")
            }
        case .setMode(_, let modeId):
            guard let target = chat.modes[modeId] else { return .deny(.invalid, "This chat doesn't offer that mode.") }
            return target <= chat.level ? .allow : .deny(.raiseMode, "The phone can only lower a chat's mode.")
        case .setPlan(_, let on):
            // Plan is the lowest level: on lowers. Off goes back to the chat's mode, which the
            // phone may do only where tools still ask.
            return on || !chat.planOn || leavesPlan(chat, grant) ? .allow : .deny(.raiseMode, "Leaving plan raises the mode; do it on the Mac.")
        case .planReady(_, let choice):
            guard chat.cards.values.contains(where: { $0.kind == .planReady }) else { return .deny(.goneCard, "No plan is waiting.") }
            return choice == .stay || leavesPlan(chat, grant)
                ? .allow : .deny(.raiseMode, "Implementing leaves plan, which raises the mode; do it on the Mac.")
        case .new:
            return .allow
        }
    }

    /// Leaving a plan switch for the chat's own mode stays within what the phone may send to.
    private static func leavesPlan(_ chat: ChatFacts, _ grant: Grant) -> Bool { chat.level <= grant.sendMaxLevel }

    /// The answers each kind of card takes from the phone.
    package static func actions(_ kind: WireCard.Kind) -> Set<CardAction.ID> {
        switch kind {
        case .permission: [.allow, .deny]
        case .questions: [.submitAnswers, .deny]
        case .plan: [.approvePlan, .keepPlanning]
        case .planReady: [.implement, .stay]
        case .signIn, .unknown: []
        }
    }

    /// The modes the phone may switch a chat to: its own level and below.
    package static func allowedModes(_ chat: ChatFacts) -> Set<String> {
        Set(chat.modes.filter { $0.value <= chat.level }.keys)
    }
}

/// At most `limit` actions in any `window`: the phone's sends, and its actions overall.
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

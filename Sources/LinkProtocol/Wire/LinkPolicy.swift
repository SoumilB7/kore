import Foundation
import src

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
    /// Files a message from the link may carry.
    package static let maxBlobs = 10
    /// "/" commands the link always refuses: Kore's own entries (they open Kore's popups) and the
    /// CLI's sign-in, usage and remote commands they stand in for, which only work in a terminal.
    /// Any other command the chat offers may be sent, as on the Mac (owner, 2026-11-01).
    package static let koreOnly: Set<String> = ["usage", "account", "login", "logout", "remote-control"]

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
        /// The "/" commands the chat offers (CLI commands and skills, by name), and Kore's own
        /// entries in its "/" menu.
        package var commands: Set<String>
        package var koreEntries: Set<String>
        /// Why the chat can't have Arsenal now (Codex outside Full access); nil when it can.
        package var arsenalUnavailable: String?

        package init(
            level: ModeLevel, planOn: Bool = false, modes: [String: ModeLevel], cards: [String: Card] = [:], commands: Set<String> = [],
            koreEntries: Set<String> = [], arsenalUnavailable: String? = nil
        ) {
            self.level = level
            self.planOn = planOn
            self.modes = modes
            self.cards = cards
            self.commands = commands
            self.koreEntries = koreEntries
            self.arsenalUnavailable = arsenalUnavailable
        }

        /// What the agent may do now: a plan switch that's on means planning, whatever the mode.
        package var effectiveLevel: ModeLevel { planOn ? .plan : level }
    }

    package enum Verdict: Sendable, Equatable {
        case allow
        case deny(ResultCode, String)
    }

    /// The longest title a rename may set.
    package static let maxTitle = 200
    /// The longest code a sign-in takes back from its manual page.
    package static let maxSignInInput = 4096
    /// Arsenal's built tiers, lowest first: what `chat.setArsenal` takes besides "off". Full isn't
    /// built, so it is refused.
    package static let arsenalTiers = ["watch", "own", "drive"]

    package static func check(_ command: LinkCommand, _ chat: ChatFacts?, control: LinkControlLevel = .standard) -> Verdict {
        switch command {
        case .unknown: return .deny(.invalid, "Kore doesn't know that command.")
        case .new: return .allow
        case .control(let kind, let args): return check(kind, args, chat, control: control)
        default: break
        }
        guard let chat else { return .deny(.goneChat, "That chat isn't open in Kore any more.") }
        switch command {
        case .send(_, let text, let blobs):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !blobs.isEmpty, text.utf8.count <= maxText, blobs.count <= maxBlobs else {
                return .deny(.invalid, "Nothing to send, or too long.")
            }
            // The claude CLI runs a message starting with "!" as a shell command.
            if trimmed.hasPrefix("!") { return .deny(.command, "Shell commands can't be sent over the link.") }
            if trimmed.hasPrefix("/") {
                let name = String(trimmed.dropFirst().prefix { !$0.isWhitespace })
                if koreOnly.contains(name) || chat.koreEntries.contains(name) { return .deny(.command, "/\(name) is Kore's own; use it in Kore.") }
                guard name == "compact" || chat.commands.contains(name) else { return .deny(.command, "This chat doesn't offer /\(name).") }
            }
            return .allow
        case .stop:
            return .allow
        case .answer(_, let cardId, let action, let digest, _):
            guard let card = chat.cards[cardId] else { return .deny(.goneCard, "That was answered or withdrawn.") }
            if card.kind == .signIn { return .deny(.signIn, "Answer sign-ins in Kore.") }
            switch action {
            case .allowAlways: return .deny(.alwaysAllow, "Always allow can only be set in Kore.")
            case .approvePlanAcceptEdits where control != .full:
                return .deny(.raiseMode, "Approving with auto-accept edits raises the mode; do it in Kore.")
            default: break
            }
            let taken = actions(card.kind).union(control == .full && card.kind == .plan ? [.approvePlanAcceptEdits] : [])
            guard taken.contains(action) else { return .deny(.action, "That card doesn't take that answer.") }
            guard digest == card.digest else { return .deny(.staleCard, "The card changed; look again.") }
            return .allow
        case .setMode(_, let modeId):
            guard let target = chat.modes[modeId] else { return .deny(.invalid, "This chat doesn't offer that mode.") }
            return target <= chat.level || (control == .full && target <= raiseCap)
                ? .allow : .deny(.raiseMode, control == .full ? "The link can raise a chat's mode up to Auto." : "The link can only lower a chat's mode.")
        case .setPlan(_, let on):
            // Plan is the lowest level: on lowers. Off goes back to the chat's own mode, which the
            // link may do only where tools still ask, or with full control.
            return on || !chat.planOn || chat.level <= leavePlanMaxLevel || (control == .full && chat.level <= raiseCap)
                ? .allow : .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore.")
        case .planReady(_, let choice):
            guard chat.cards.values.contains(where: { $0.kind == .planReady }) else { return .deny(.goneCard, "No plan is waiting.") }
            return choice == .stay || chat.level <= leavePlanMaxLevel || (control == .full && chat.level <= raiseCap)
                ? .allow : .deny(.raiseMode, "Implementing leaves plan, which raises the mode; do it in Kore.")
        case .new, .unknown, .control:
            return .allow
        }
    }

    /// A 1.2 command: only with full control granted on the Mac this run. Full control widens
    /// what the link may arrange (chats, tabs, boards, windows, history). Always allow and `!`
    /// lines stay refused. Two exceptions, the owner's: Arsenal (1.3), which full control may turn
    /// on and raise to a built tier, as the Mac's tiers popup does; and a chat's mode (2026-11-10),
    /// which full control may raise up to Auto (`raiseCap`), never to Bypass or Full access.
    package static func check(_ kind: ControlKind, _ args: ControlArgs, _ chat: ChatFacts?, control: LinkControlLevel) -> Verdict {
        guard control == .full else { return .deny(.deniedControl, "Full control isn't granted in Kore for this run.") }
        if kind.onChat, chat == nil { return .deny(.goneChat, "That chat isn't open in Kore any more.") }
        switch kind {
        case .chatRename, .historyRename:
            let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= maxTitle, !title.contains(where: \.isNewline) else { return .deny(.invalid, "A title is one line, up to 200 characters.") }
        case .chatSendAtReset:
            if let chat, case .deny(let code, let message) = check(.send(chatId: "", text: args.text ?? "", blobs: args.blobs ?? []), chat) {
                return .deny(code, message)
            }
        case .chatSetDraft:
            guard (args.text ?? "").utf8.count <= maxText else { return .deny(.invalid, "Too long.") }
        case .chatSetAutoCompact:
            if let at = args.at, !(1...100).contains(at) { return .deny(.invalid, "A percentage from 1 to 100, or off.") }
        case .accountSignIn:
            guard args.provider != nil, [nil, "active", "new", "login"].contains(args.aim), args.aim != "login" || args.login != nil else {
                return .deny(.invalid, "A sign-in names its CLI, and a login when it's for one.")
            }
        case .accountSubmit:
            let input = (args.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard args.provider != nil, args.serial != nil, !input.isEmpty, input.utf8.count <= maxSignInInput, !input.contains(where: \.isNewline)
            else { return .deny(.invalid, "The code is one line.") }
        case .accountSwitch, .accountRemove:
            guard args.provider != nil, args.login != nil else { return .deny(.invalid, "Name the CLI and the login.") }
        case .accountCancel, .accountSignOut, .accountRefresh:
            guard args.provider != nil else { return .deny(.invalid, "Name the CLI.") }
        case .accountPrivacy:
            guard args.on != nil else { return .deny(.invalid, "Say on or off.") }
        case .chatSetArsenal:
            let tier = args.tier ?? ""
            if tier == "full" { return .deny(.invalid, "Arsenal's Full tier isn't built yet.") }
            guard tier == "off" || arsenalTiers.contains(tier) else { return .deny(.invalid, "Arsenal has no such tier.") }
            if tier != "off", let why = chat?.arsenalUnavailable { return .deny(.busy, why) }
        default: break
        }
        return .allow
    }

    /// A relayed backend call (1.5 `chat.call`): full control only, each case decided here, so a
    /// new one can't compile without its rule. Raises stop at Auto, `!` lines and Always allow are
    /// refused, and no call carries a key. `card` is the approval's card when it has one.
    package static func check(_ command: ChatCommand, _ chat: ChatFacts?, control: LinkControlLevel) -> Verdict {
        guard control == .full else { return .deny(.deniedControl, "Driving a chat needs a grant with full control.") }
        if case .unknown(let tag) = command { return .deny(.invalid, "The box doesn't know \(tag.isEmpty ? "that call" : tag).") }
        guard let chat else { return .deny(.goneChat, "That chat isn't on the box any more.") }
        switch command {
        case .send(let text, let files, _, _):
            return check(.send(chatId: "", text: text, blobs: files.map(\.blob)), chat, control: control)
        case .respond(_, let decision):
            switch decision {
            case .allowAlways: return .deny(.alwaysAllow, "Always allow can only be set on the box.")
            // Approving into Accept edits raises the mode, within Auto: full control may.
            case .allow, .deny, .approvePlan, .keepPlanning, .answers: return .allow
            }
        case .setMode(let mode):
            return check(.setMode(chatId: "", modeId: mode), chat, control: control)
        case .setPlanMode(let on):
            return check(.setPlan(chatId: "", on: on), chat, control: control)
        case .rename(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count <= maxTitle && !trimmed.contains(where: \.isNewline)
                ? .allow : .deny(.invalid, "A title is one line, up to 200 characters.")
        case .compact(let instructions):
            return instructions.utf8.count <= maxText ? .allow : .deny(.invalid, "Too long.")
        case .setRemoteControl:
            // The CLI's own remote hands the chat to another service: only on the box itself.
            return .deny(.command, "Remote control of a box's chat is turned on on the box.")
        case .interrupt, .setModel, .setEffort, .setFastMode, .stopAgent, .stopCommand, .backgroundCommand, .commandOutput, .watchCommands,
            .agentHistory, .fork, .forkAtEnd, .rollback, .earlier, .earlierMessages, .unloadPoint, .unloaded, .usage, .useReset, .relaunch,
            .listModels:
            return .allow
        case .unknown:
            return .deny(.invalid, "The box doesn't know that call.")
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

    /// The highest a full-control client may raise a mode (owner, 2026-11-10: Auto, not Bypass or
    /// Full access).
    package static let raiseCap = ModeLevel.auto

    /// The modes the link may switch a chat to: its own level and below; with full control, also
    /// up to Auto.
    package static func allowedModes(_ chat: ChatFacts, control: LinkControlLevel = .standard) -> Set<String> {
        let top = control == .full ? max(chat.level, raiseCap) : chat.level
        return Set(chat.modes.filter { $0.value <= top }.keys)
    }
}

/// At most `limit` in any `window`.
package struct RateLimiter: Sendable {
    package let limit: Int
    package let window: TimeInterval
    private var times: [Date] = []

    package init(limit: Int, per window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// When the next one frees up, if there's no room at `now`; nil when there's room.
    package func nextFree(at now: Date = Date()) -> Date? {
        let live = times.filter { now.timeIntervalSince($0) < window }
        guard live.count >= limit, let oldest = live.min() else { return nil }
        return oldest.addingTimeInterval(window)
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

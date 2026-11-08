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
            // Implementing a plan, or approving one into the chat's own mode, leaves plan: the same
            // rule as `chat.planReady` and `chat.setPlan`. Approving into Accept edits (full
            // control only, above) goes to a mode under Auto.
            if (card.kind == .planReady && action == .implement) || (card.kind == .plan && action == .approvePlan), !mayLeavePlan(chat, control: control) {
                return .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore.")
            }
            return .allow
        case .setMode(_, let modeId):
            guard let target = chat.modes[modeId] else { return .deny(.invalid, "This chat doesn't offer that mode.") }
            return target <= chat.level || (control == .full && target <= raiseCap)
                ? .allow : .deny(.raiseMode, control == .full ? "The link can raise a chat's mode up to Auto." : "The link can only lower a chat's mode.")
        case .setPlan(_, let on):
            // Plan is the lowest level: on lowers. Off goes back to the chat's own mode, which the
            // link may do only where tools still ask, or with full control.
            return on || !chat.planOn || mayLeavePlan(chat, control: control)
                ? .allow : .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore.")
        case .planReady(_, let choice):
            guard chat.cards.values.contains(where: { $0.kind == .planReady }) else { return .deny(.goneCard, "No plan is waiting.") }
            return choice == .stay || mayLeavePlan(chat, control: control)
                ? .allow : .deny(.raiseMode, "Implementing leaves plan, which raises the mode; do it in Kore.")
        case .new, .unknown, .control:
            return .allow
        }
    }

    /// Leaving plan goes back to the chat's own mode: allowed where tools still ask, or up to Auto
    /// with full control.
    package static func mayLeavePlan(_ chat: ChatFacts, control: LinkControlLevel) -> Bool {
        chat.level <= leavePlanMaxLevel || (control == .full && chat.level <= raiseCap)
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

    /// A forwarded backend call (1.5 `chat.call`): full control only, each case decided here, so a
    /// new one can't compile without its rule. Raises stop at Auto, `!` lines and Always allow are
    /// refused, and no call carries a key. `card` is the approval's card when it has one.
    package static func check(_ command: ChatCommand, _ chat: ChatFacts?, control: LinkControlLevel) -> Verdict {
        guard control == .full else { return .deny(.deniedControl, "Driving a chat needs a grant with full control.") }
        if case .unknown(let tag) = command { return .deny(.invalid, "Unknown call: \(tag.isEmpty ? "?" : tag).") }
        guard let chat else { return .deny(.goneChat, "That chat isn't on the box any more.") }
        switch command {
        case .send(let text, let files, _, _):
            return check(.send(chatId: "", text: text, blobs: files.map(\.blob)), chat, control: control)
        case .respond(let approval, let decision):
            if chat.cards[approval]?.kind == .signIn { return .deny(.signIn, "Sign-ins are answered on the box itself.") }
            switch decision {
            case .allowAlways: return .deny(.alwaysAllow, "Always allow is set on the box itself.")
            // Into the chat's own mode: leaving plan's rule. Into Accept edits: under Auto.
            case .approvePlan(let acceptEdits):
                return acceptEdits || mayLeavePlan(chat, control: control) ? .allow : .deny(.raiseMode, "Leaving plan into that mode is set on the box itself.")
            case .allow, .deny, .keepPlanning, .answers: return .allow
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
        case .keepRow(let text, _):
            // Only the row of a typed /compact, the one a chat shows without sending.
            return Chat.compactCommand(text) != nil && text.utf8.count <= maxText ? .allow : .deny(.invalid, "Only a /compact row is kept that way.")
        case .setRemoteControl:
            // The CLI's own remote hands the chat to another service: only on the box itself.
            return .deny(.command, "Remote control of a box's chat is turned on on the box.")
        case .setAutoCompact(let at):
            return at.map { (1...100).contains($0) } ?? true ? .allow : .deny(.invalid, "A percentage from 1 to 100, or off.")
        case .setDraft(let text):
            return text.utf8.count <= maxText ? .allow : .deny(.invalid, "Too long.")
        case .setArsenal(let tier):
            // The tier the client holds: it answers the agent's calls at it (1.6).
            return check(.chatSetArsenal, ControlArgs(tier: tier ?? "off"), chat, control: control)
        case .interrupt, .setModel, .setEffort, .setFastMode, .stopAgent, .stopCommand, .backgroundCommand, .commandOutput, .watchCommands,
            .agentHistory, .fork, .forkAtEnd, .rollback, .earlier, .earlierMessages, .unloadPoint, .unloaded, .usage, .useReset, .relaunch,
            .listModels, .close, .draft:
            return .allow
        case .unknown:
            return .deny(.invalid, "Unknown call.")
        }
    }

    /// The calls a full grant may make (1.5): every one but those this policy always refuses.
    package static let callable = ChatCommand.tags.filter { $0 != "setRemoteControl" }

    /// The sign-ins a box runs: the ones with no browser on the box. Never a key: no message
    /// carries one.
    package static let boxSignIns: Set<String> = ["claudeai", "chatgptDeviceCode"]

    /// A model or effort as a box takes it: a short plain id, so nothing odd reaches the CLI's
    /// arguments (the box also checks it against its CLI's list when it has one).
    package static func plainID(_ id: String?) -> Bool {
        guard let id, (1...128).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:[]-".unicodeScalars.contains($0) } && id.allSatisfy(\.isASCII)
    }

    /// A box's own control commands (1.4), each kind with its rule; anything else is refused.
    /// `levels`: the levels of the new chat's CLI's modes, for `chat.new`. A new chat starts at
    /// most where tools still ask, or at Auto with full control.
    package static func checkBox(_ kind: ControlKind, _ args: ControlArgs, _ chat: ChatFacts?, control: LinkControlLevel, levels: [String: ModeLevel] = [:]) -> Verdict {
        func full() -> Verdict { control == .full ? .allow : .deny(.deniedControl, "That needs a grant with full control.") }
        if kind.onChat, chat == nil { return .deny(.goneChat, "That chat isn't on the box any more.") }
        switch kind {
        case .chatNew:
            if let mode = args.mode, (levels[mode] ?? .danger) > (control == .full ? raiseCap : leavePlanMaxLevel) {
                return .deny(.raiseMode, "A new chat can't start in that mode from here.")
            }
            if args.modelId != nil, !plainID(args.modelId) { return .deny(.invalid, "That isn't a model.") }
            if args.level != nil, !plainID(args.level) { return .deny(.invalid, "That isn't an effort.") }
            if let title = args.title, title.count > maxTitle || title.contains(where: \.isNewline) { return .deny(.invalid, "A title is one line, up to 200 characters.") }
            return .allow
        case .chatSetModel:
            return plainID(args.modelId) ? .allow : .deny(.invalid, "Name the chat and the model.")
        case .chatSetEffort:
            return plainID(args.level) ? .allow : .deny(.invalid, "Name the chat and the effort.")
        case .chatSetFast:
            return args.on != nil ? .allow : .deny(.invalid, "Name the chat and on or off.")
        case .chatClose, .foldersList, .folderAdd:
            return .allow
        case .syncWatch, .syncUnwatch:
            // The box also checks it serves the folder.
            guard let folder = args.folder, folder.hasPrefix("/"), !folder.contains("\0") else { return .deny(.invalid, "Name the folder.") }
            return .allow
        case .fsList, .fsRead, .fsMkdir:
            // 1.7: the box's files, full grants only. The box also checks where the path leads
            // (`HostFiles`): its home or a served folder, never through a link out of one.
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            if kind == .fsList, args.path == nil { return .allow }
            guard LinkFiles.plainPath(args.path) else { return .deny(.invalid, "An absolute path.") }
            if kind == .fsRead, let max = args.max, max < 0 { return .deny(.invalid, "A size of 0 or more.") }
            return .allow
        case .fsWrite, .fsCreate, .fsDelete, .fsCount:
            // 1.8: inside served folders only (the box checks where the path leads).
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard LinkFiles.plainPath(args.path) else { return .deny(.invalid, "An absolute path.") }
            if kind == .fsWrite, [args.text != nil, args.data != nil, args.blob != nil].filter({ $0 }).count != 1 {
                return .deny(.invalid, "One of text, data or blob.")
            }
            return .allow
        case .fsRename, .fsCopy:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard LinkFiles.plainPath(args.from), LinkFiles.plainPath(args.to) else { return .deny(.invalid, "Two absolute paths.") }
            return .allow
        case .fsSearch:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard LinkFiles.plainPath(args.root) else { return .deny(.invalid, "An absolute root.") }
            guard let query = args.query, !query.isEmpty, query.count <= 200, !query.contains("\0"), !query.contains(where: \.isNewline) else {
                return .deny(.invalid, "A query of one line, up to 200 characters.")
            }
            guard args.mode == nil || args.mode == "name" || args.mode == "text" else { return .deny(.invalid, "name or text.") }
            return .allow
        case .fsWatch:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            let folders = args.folders ?? []
            guard folders.count <= LinkFiles.watchMax, folders.allSatisfy(LinkFiles.plainPath) else { return .deny(.invalid, "Up to 64 absolute folders.") }
            return .allow
        case .tabReopen:
            // A closed chat back: named by `sourceId` (it isn't one of the box's chats until then).
            return args.sourceId != nil ? .allow : .deny(.invalid, "Name the chat.")
        // 1.9: a chat's own operations, as a Mac window offers them. An act grant does the
        // ordinary ones; a full grant also what raises (an Arsenal tier on) or acts at a plan's
        // limit (Continue, a message at the reset). Always allow, `!` lines and keys stay refused.
        case .chatRename, .historyRename:
            if kind == .historyRename, args.sessionId == nil { return .deny(.invalid, "Name the chat.") }
            return check(kind, args, chat, control: .full)
        case .chatFork:
            guard args.entryId != nil || args.after == true else { return .deny(.invalid, "Name the message to fork from.") }
            return .allow
        case .chatCompact:
            return (args.instructions ?? "").utf8.count <= maxText ? .allow : .deny(.invalid, "Too long.")
        case .chatSetAutoCompact, .chatSetDraft:
            return check(kind, args, chat, control: .full)
        case .chatRetry, .chatCancelContinue, .arsenalStopAll:
            return .allow
        case .chatContinue:
            return full()
        case .chatSendAtReset:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard (args.blobs ?? []).isEmpty else { return .deny(.invalid, "A message at the reset carries no files from here.") }
            return check(kind, args, chat, control: .full)
        case .historyOpen, .historyArchive:
            return args.sessionId != nil ? .allow : .deny(.invalid, "Name the chat.")
        case .chatSetArsenal:
            // Off lowers; a tier on raises what the chat's agent may do: full grants only.
            if (args.tier ?? "off") != "off", case .deny(let code, let message) = full() { return .deny(code, message) }
            return check(kind, args, chat, control: .full)
        case .authGh:
            return full()
        case .accountSignIn:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            if let method = args.method, !boxSignIns.contains(method) { return .deny(.invalid, "That sign-in isn't taken here.") }
            return check(kind, args, chat, control: control)
        case .accountSubmit, .accountCancel, .accountSignOut, .accountRefresh:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            return check(kind, args, chat, control: control)
        // 1.10: a chat's move between the box and a Mac, full grants only. The box also checks
        // the chat's owner and gen, and where the files lead (its own staging folder only).
        case .chatRelease:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard args.chatId != nil, let phase = args.phase.flatMap(MovePhase.init(rawValue:)) else { return .deny(.invalid, "Name the chat and the phase.") }
            guard (args.gen ?? -1) >= 0 else { return .deny(.invalid, "Say the gen the move starts from.") }
            if phase != .prepare || args.moveId != nil, !LinkMoves.plainMoveID(args.moveId) { return .deny(.invalid, "Name the move.") }
            return .allow
        case .chatAdopt:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard let phase = args.phase.flatMap(MovePhase.init(rawValue:)), LinkMoves.plainMoveID(args.moveId) else { return .deny(.invalid, "Name the move and the phase.") }
            guard phase == .abort || (LinkMoves.plainSession(args.sessionId) && args.provider != nil && (args.gen ?? -1) >= 0) else {
                return .deny(.invalid, "Name the session, its CLI and the gen.")
            }
            if phase == .commit {
                guard let folder = args.folder, folder.hasPrefix("/"), !folder.contains("\0") else { return .deny(.invalid, "Name the folder.") }
                if args.modelId != nil, !plainID(args.modelId) { return .deny(.invalid, "That isn't a model.") }
                if args.level != nil, !plainID(args.level) { return .deny(.invalid, "That isn't an effort.") }
                if let title = args.title, title.count > maxTitle || title.contains(where: \.isNewline) { return .deny(.invalid, "A title is one line, up to 200 characters.") }
            }
            if let host = args.host, host.count > 100 || host.contains(where: \.isNewline) { return .deny(.invalid, "A name is one line.") }
            return .allow
        case .chatMirror:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard args.chatId != nil, (args.gen ?? -1) >= 0, (args.seq ?? -1) >= 0 else { return .deny(.invalid, "Name the chat, its gen and the first seq.") }
            guard (args.events?.items ?? []).count <= LinkMoves.mirrorMax else { return .deny(.invalid, "Too many events at once.") }
            return .allow
        case .syncFlush:
            if case .deny(let code, let message) = full() { return .deny(code, message) }
            guard let folder = args.folder, folder.hasPrefix("/"), !folder.contains("\0") else { return .deny(.invalid, "Name the folder.") }
            return .allow
        default:
            return .deny(.invalid, "Not taken here.")
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

import Foundation
import AgentTools
import KoreCore

/// What Drive adds (`z-docs/agent-protocol.md`): new chats in the caller's window, sends, stops,
/// a tab brought to the front, question cards answered, and Own's changes on the window's other
/// chats, each at or below the caller's own mode. Each goes through the control a person uses
/// (a new tab as ⌘T and a CLI's pick open it, a message as the composer sends it), so it looks
/// and runs the same; the receiving chat says who it came from. Approving stays the user's.
extension Chat {
    /// The lowest mode a caller allows another chat's permission card from, once (the owner's to
    /// confirm, 2026-11-15): Auto, whose CLI runs commands without asking first, so what it allows
    /// another to do it could do itself (Codex: Approve for me and up). Nil: no caller does.
    package static let approvalFloor: String? = "auto"

    /// Held messages let in by another chat's agent (chat, by, messages), for the log: the app's
    /// on the Mac, kore-host's journal on a box.
    package static var heldLetIn: (_ chat: String, _ by: String, _ messages: Int) -> Void = { _, _, _ in }

    /// At or above `approvalFloor`, and not there by "Allow commands in Plan".
    package static func mayApprove(_ caller: Chat) -> Bool {
        guard let floor = approvalFloor else { return false }
        let rank = caller.arsenalRank
        return !rank.unreviewed && modeLevel(rank.id) >= modeLevel(floor)
    }

    /// "Auto", for a refusal.
    package static var approvalFloorLabel: String {
        approvalFloor.map { floor in ClaudeModes.all.first { $0.id == floor }?.label ?? floor } ?? "any level"
    }

    /// What it can do on its own now is no more than `other` can (`noFreer`), and it hasn't been
    /// told Always allow where `other` hasn't: Drive reaches it.
    package func noFreer(than other: Chat) -> Bool {
        let (mine, theirs) = (arsenalRank, other.arsenalRank)
        guard !alwaysAllowed || other.alwaysAllowed else { return false }
        return Self.noFreer(mine.id, unreviewed: mine.unreviewed, than: theirs.id, unreviewed: theirs.unreviewed)
    }

    /// Why Drive from `other` doesn't reach it (`noFreer` false), as the list can show it.
    package func freerLine(than other: Chat) -> String { Self.freerLine(always: alwaysAllowed && !other.alwaysAllowed) }

    /// `always`: told Always allow where the caller wasn't, which no mode shows.
    package static func freerLine(always: Bool) -> String {
        always ? "That chat was told Always allow and this one wasn't: only you drive it." : "That chat's mode is above this one's: only you drive it."
    }

    /// A message from another chat's agent: shown with where it came from, then sent as the
    /// composer would, queued while a turn runs. A "/" command only from the chat's own "/" list,
    /// and never one of `userCommands` (the owner, 2026-11-15); a "!" shell line never.
    package func arsenalSend(_ text: String, from caller: String) -> Result<String, ArsenalRefusal> {
        arsenalSend(text, from: caller, done: nil)
    }

    /// `arsenalSend`, and `done` once the CLI has the message or with why it didn't go (`sendFromLink`):
    /// a chat just woken from History answers its caller only then, so a CLI that doesn't start is
    /// said, not lost.
    package func arsenalSend(_ text: String, from caller: String, done: (@MainActor (Result<Bool, Error>) -> Void)?) -> Result<String, ArsenalRefusal> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refusal = Self.arsenalRefusal(text) { return .failure(refusal) }
        if Self.arsenalLead(text) == "/" {
            text = String(String.UnicodeScalarView(text.unicodeScalars.drop { $0 != "/" }))
            if case .failure(let refusal) = arsenalCommand(text) { return .failure(refusal) }
        }
        let queued = status.isRunning
        note("Arsenal · sent by \(caller)")
        guard sendFromLink(text, done: done) else { return .failure(.init("This chat can't take a message right now.")) }
        return .success(queued ? "Queued: it goes when the turn running there ends." : "Sent.")
    }

    /// The first character that counts: invisible format characters (U+200B, U+FEFF, U+2060, …)
    /// before a "/" or "!" don't hide it, as a CLI may drop them.
    package static func arsenalLead(_ text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first { !$0.properties.isWhitespace && $0.properties.generalCategory != .format }
    }

    /// Why no chat takes this message from an agent, whatever chat it is: empty, a "!" shell
    /// line, or a "/" command only the user runs. A "/" in the chat's own list is the chat's to say.
    package static func arsenalRefusal(_ text: String) -> ArsenalRefusal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .init("A message needs some text.") }
        switch arsenalLead(text) {
        case "!": return .init("Only you run a “!” shell line.")
        case "/":
            let command = String(String.UnicodeScalarView(text.unicodeScalars.drop { $0 != "/" }))
            let name = String(command.dropFirst().prefix { !$0.isWhitespace }).lowercased()
            guard !name.isEmpty else { return .init("A “/” needs a command after it.") }
            if let kore = koreSets[name] { return .init("Kore sets that: \(kore), not /\(name).") }
            if userCommands.contains(name) { return .init("Only you run /\(name): sign-in, account, permission and settings commands are yours.") }
            return nil
        default: return nil
        }
    }

    /// The "/" commands only the user runs: signing in and accounts, permissions, settings, the
    /// CLI's own exit, and what Kore sets with a command of its own (mode, model, effort, fast).
    package static let userCommands: Set<String> = [
        "login", "logout", "account", "usage", "upgrade", "extra-usage", "privacy-settings", "remote-control", "feedback", "bug",
        "permissions", "allowed-tools", "approvals", "add-dir", "sandbox", "sandbox-add-read-dir",
        "config", "settings", "hooks", "statusline", "terminal-setup", "mcp", "plugin", "plugins", "agents", "output-style",
        "theme", "vim", "ide", "keybindings", "install-github-app", "install-slack-app", "personality", "experimental",
        "exit", "quit", "plan", "model", "effort", "fast",
    ]

    /// Kore's own command for one of `userCommands`, where it has one.
    private static let koreSets = ["plan": "kore mode", "model": "kore model", "effort": "kore effort", "fast": "kore fast"]

    /// A "/" command it may send this chat: one its "/" list has, not one of `userCommands`.
    package func arsenalCommand(_ text: String) -> Result<Void, ArsenalRefusal> {
        let name = String(text.dropFirst().prefix { !$0.isWhitespace }).lowercased()
        guard !name.isEmpty else { return .failure(.init("A “/” needs a command after it.")) }
        if let kore = Self.koreSets[name] { return .failure(.init("Kore sets that: \(kore), not /\(name).")) }
        guard !Self.userCommands.contains(name) else {
            return .failure(.init("Only you run /\(name): sign-in, account, permission and settings commands are yours."))
        }
        // compact is Kore's own, as the context wheel's.
        guard name == "compact" || controls.commands.contains(where: { $0.kind != .kore && $0.name.lowercased() == name }) else {
            return .failure(.init("/\(name) isn't in this chat's “/” list."))
        }
        return .success(())
    }

    /// A question card's answers, an option's label (or typed text, where the card takes it) per
    /// question in order; `deny`, which any card takes; or `allow`, a permission card allowed once,
    /// by a caller at Auto or above (one whose own mode lets its CLI run commands without asking
    /// first), in a chat it reaches (the owner, 2026-11-15); an Auto-asks card run once or Always
    /// allowed with Act unlimited or above too (`arsenalRunAutoAsk`). Never another card's Always
    /// allow, a plan, a sign-in or a secret question: those stay the user's.
    /// Held cross-session messages let in by another chat's agent at Act unlimited (the owner,
    /// 2026-11-18: ask here, answer there): never by a chat whose own message is held there, and
    /// never a hold a flag can't lift. The chat's line says who let them in.
    package func arsenalLetIn(_ card: Approval, senders: [Approval.HeldSender], by caller: Chat?) -> Result<String, ArsenalRefusal> {
        guard let caller else { return .failure(.init("Only a chat in Kore lets held messages in.")) }
        if let note = card.allowNote { return .failure(.init(note)) }
        if Self.sentAny(senders, caller: caller) {
            return .failure(.init("This chat sent one of the held messages: only you or another chat lets them in."))
        }
        let short = String(caller.id.uuidString.prefix(8)).lowercased()
        answerHeld(card, allow: true, by: short)
        Self.heldLetIn(String(id.uuidString.prefix(8)).lowercased(), short, senders.count)
        return .success("Let in.")
    }

    /// One of `senders` is `caller`: by its address while its CLI runs, or by its name.
    package static func sentAny(_ senders: [Approval.HeldSender], caller: Chat) -> Bool {
        sentAny(senders, address: caller.peerAddress, name: caller.title)
    }

    /// The same, from an address (`uds:/tmp/cc-socks/<pid>.sock`, `/private/tmp` or `/tmp`) and a name.
    package static func sentAny(_ senders: [Approval.HeldSender], address: String?, name: String) -> Bool {
        let socket = address.map { "/cc-socks/" + ($0 as NSString).lastPathComponent }
        return senders.contains { sender in
            if let socket, sender.from.hasSuffix(socket) { return true }
            return sender.name?.lowercased() == name.lowercased()
        }
    }

    /// `always`: Always allow on an Auto-asks card. `tier`: the caller's Arsenal tier, for an
    /// Auto-asks card (nil: off).
    package func arsenalAnswer(
        _ cardId: String, _ choices: [String], deny: Bool, allow: Bool = false, always: Bool = false, by caller: Chat? = nil, tier: ArsenalTier? = nil
    ) -> Result<String, ArsenalRefusal> {
        guard let card = approvals.pending.first(where: { $0.id == cardId }) else { return .failure(.init("That card was answered or withdrawn.")) }
        guard !card.signIn else { return .failure(.init("Only you answer a sign-in.")) }
        if deny {
            answer(card, .deny)
            note("Arsenal · denied “\(card.title)”")
            return .success("Denied.")
        }
        if allow, let senders = card.held {
            return arsenalLetIn(card, senders: senders, by: caller)
        }
        if allow || always, let refusal = Self.startedRefusal(self, by: caller) { return .failure(refusal) }
        if allow || always, card.autoStop { return arsenalRunAutoAsk(card, always: always, by: caller, tier: tier) }
        if always { return .failure(.init("Only you choose Always allow here; an agent may Always allow only a card Auto asks about.")) }
        if allow {
            guard card.isPermission else { return .failure(.init("Only a permission card is allowed this way; plans stay yours to approve.")) }
            guard let caller, Self.mayApprove(caller) else {
                guard Self.approvalFloor != nil else { return .failure(.init("Only you allow a chat's commands.")) }
                return .failure(.init("Only a chat at \(Self.approvalFloorLabel) or above allows another's commands: this one is \(caller?.controls.activeMode.label ?? "outside Kore")."))
            }
            answer(card, .allow)
            note("Arsenal · allowed “\(card.title)” · by \(String(caller.id.uuidString.prefix(8)).lowercased())")
            return .success("Allowed once.")
        }
        guard !card.questions.isEmpty else { return .failure(.init("Only you approve this. An agent may deny it.")) }
        guard choices.count == card.questions.count else { return .failure(.init("This card asks \(card.questions.count) question(s): give one answer each.")) }
        var answers: [String: [String]] = [:]
        for (question, choice) in zip(card.questions, choices) {
            guard !question.secret else { return .failure(.init("Only you answer a secret question.")) }
            if let option = question.options.first(where: { $0.label.lowercased() == choice.lowercased() }) {
                answers[question.id] = [option.label]
            } else if question.other, !choice.isEmpty, choice.count <= 2000 {
                answers[question.id] = [choice]
            } else {
                return .failure(.init("“\(question.text)” takes: " + question.options.map(\.label).joined(separator: ", ")))
            }
        }
        answer(card, .answers(answers))
        note("Arsenal · answered “\(card.title)”")
        return .success("Answered.")
    }
}

extension Chat {
    /// What a chat's agent is told when it would allow a command in a chat it made.
    package static let startedLine = "Only you allow commands in a chat this one started."

    /// `caller` made this chat, or made, forked or woke one that did, while this one has been open:
    /// its agent could have the new chat run what it wants and allow that itself.
    package func arsenalStarted(by caller: Chat) -> Bool { arsenalOrigins.contains(caller.arsenalKey) }

    /// The chat it was made from, and that chat's own origins: what a chat made by `caller` keeps.
    package static func origins(madeBy caller: Chat) -> [String] { [caller.arsenalKey] + caller.arsenalOrigins.filter { $0 != caller.arsenalKey } }

    static func startedRefusal(_ chat: Chat, by caller: Chat?) -> ArsenalRefusal? {
        guard let caller, chat.arsenalStarted(by: caller) else { return nil }
        return ArsenalRefusal(startedLine)
    }

    /// The lowest tier that runs a command Auto asks about for another chat (the owner, 2026-11-21).
    package static let autoAskFloor = ArsenalTier.drive

    /// An Auto card (Claude's "Claude stopped", Codex's review) run once, or Always allowed, by
    /// another chat's agent (the owner, 2026-11-21): a caller at Auto or above (`mayApprove`) with
    /// Act unlimited or Act device, never in a chat it started (`arsenalOrigins`),
    /// never a forced removal of the working folder or above, a home folder or a system path
    /// (`KoreAlwaysRule.critical`). The same answer as the person's Run once or Always allow.
    func arsenalRunAutoAsk(_ card: Approval, always: Bool, by caller: Chat?, tier: ArsenalTier?) -> Result<String, ArsenalRefusal> {
        if let refusal = Self.startedRefusal(self, by: caller) { return .failure(refusal) }
        if let note = card.allowNote { return .failure(.init(note)) }
        guard let caller, Self.mayApprove(caller) else {
            guard Self.approvalFloor != nil else { return .failure(.init("Only you allow a chat's commands.")) }
            return .failure(.init("Only a chat at \(Self.approvalFloorLabel) or above runs a command Auto asks about: this one is \(caller?.controls.activeMode.label ?? "outside Kore")."))
        }
        guard let tier, ArsenalTier.allCases.firstIndex(of: tier)! >= ArsenalTier.allCases.firstIndex(of: Self.autoAskFloor)! else {
            return .failure(.init("Running a command Auto asks about needs \(Self.autoAskFloor.title) or above: this chat has \(tier?.title ?? "Arsenal off")."))
        }
        if let command = card.command, KoreAlwaysRule.critical(command, cwd: card.cwd) {
            return .failure(.init("Only you run this: it removes the working folder or one above it, a home folder or a system path."))
        }
        // A command the card doesn't carry (an older box's) can't be checked.
        if card.command == nil, ["Bash", "commandExecution"].contains(card.tool ?? "") {
            return .failure(.init("Only you run this: the card doesn't say its command, so Kore can't check it."))
        }
        let short = String(caller.id.uuidString.prefix(8)).lowercased()
        if always {
            guard card.canAlwaysAllow, let rule = card.alwaysRule else {
                return .failure(.init(card.alwaysAllowNote ?? "This card has no Always allow: run it once."))
            }
            answer(card, .allowAlways)
            note("Arsenal · always allowed “\(KoreAlwaysRule.shown(rule))” · by \(short)")
            return .success("Always allowed `\(KoreAlwaysRule.shown(rule))`.")
        }
        answer(card, .allow)
        note("Arsenal · ran once “\(card.command ?? card.title)” · by \(short)")
        return .success("Ran once.")
    }
}

/// Each CLI's models as a chat of it last listed them in this run, so Drive can check a model for a
/// CLI with no chat open in the caller's window. Codex's are read once, when Drive is first given
/// and no Codex chat has listed them, from a short-lived app-server (`model/list`).
@MainActor
package enum ArsenalModels {
    package private(set) static var seen: [String: [ModelOption]] = [:]

    package static func record(_ provider: String, _ models: [ModelOption]) {
        if !models.isEmpty { seen[provider] = models }
    }

    /// A model by its id or name, as the CLI lists it, case, spaces, hyphens and underscores aside:
    /// "gpt 6 sol" is gpt-6-sol.
    package static func match(_ name: String, in models: [ModelOption]) -> ModelOption? {
        let wanted = key(name)
        guard !wanted.isEmpty else { return nil }
        return models.first { $0.id.lowercased() == name.lowercased() || $0.name.lowercased() == name.lowercased() }
            ?? models.first { key($0.id) == wanted || key($0.name) == wanted }
    }

    /// `match`, else the one model within one letter of it (a typo: "gpt 6.1 tera" is gpt-6.1-terra);
    /// several that close, or none, is a refusal naming them.
    package static func find(_ name: String, in models: [ModelOption], cli: String) -> Result<ModelOption, ArsenalRefusal> {
        if let model = match(name, in: models) { return .success(model) }
        let wanted = key(name)
        let near = models.filter { key($0.id).isNear(wanted) || key($0.name).isNear(wanted) }
        if near.count == 1 { return .success(near[0]) }
        if near.count > 1 { return .failure(.init("“\(name.prefix(80))” is close to several: " + near.map(\.id).joined(separator: ", "))) }
        return .failure(.init("\(cli) offers: " + models.map(\.id).joined(separator: ", ")))
    }

    package static func key(_ text: String) -> String { text.lowercased().filter { !" -_".contains($0) } }
}

extension String {
    /// One letter added, dropped or changed away from `other` (not equal, and neither empty). A
    /// change that touches a digit or a dot is never forgiven: gpt-5 isn't a typo of gpt-6.
    package func isNear(_ other: String) -> Bool {
        let a = Array(self), b = Array(other)
        guard !a.isEmpty, !b.isEmpty, a != b, abs(a.count - b.count) <= 1 else { return false }
        let versioned = { (c: Character) in c.isNumber || c == "." }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count {
                if versioned(a[i]) { return false }
                i += 1
            } else if b.count > a.count {
                if versioned(b[j]) { return false }
                j += 1
            } else {
                if versioned(a[i]) || versioned(b[j]) { return false }
                i += 1
                j += 1
            }
        }
        // What's left at the end is the one edit.
        if a[i...].contains(where: versioned) || b[j...].contains(where: versioned) { return false }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}

import Foundation
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

    /// A message from another chat's agent: shown with where it came from, then sent as the
    /// composer would, queued while a turn runs. A "/" command only from the chat's own "/" list,
    /// and never one of `userCommands` (the owner, 2026-11-15); a "!" shell line never.
    package func arsenalSend(_ text: String, from caller: String) -> Result<String, ArsenalRefusal> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.init("A message needs some text.")) }
        // Invisible format characters (U+200B, U+FEFF, U+2060, …) before the "/" or "!" don't hide it: a CLI may drop them.
        let lead = text.unicodeScalars.first { !$0.properties.isWhitespace && $0.properties.generalCategory != .format }
        guard lead != "!" else { return .failure(.init("Only you run a “!” shell line.")) }
        if lead == "/" {
            text = String(String.UnicodeScalarView(text.unicodeScalars.drop { $0 != "/" }))
            if case .failure(let refusal) = arsenalCommand(text) { return .failure(refusal) }
        }
        let queued = status.isRunning
        note("Arsenal · sent by \(caller)")
        guard sendFromLink(text) else { return .failure(.init("This chat can't take a message right now.")) }
        return .success(queued ? "Queued: it goes when the turn running there ends." : "Sent.")
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
    /// first), in a chat it reaches (the owner, 2026-11-15). Never Always allow, a plan, a
    /// sign-in or a secret question: those stay the user's.
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

    package func arsenalAnswer(_ cardId: String, _ choices: [String], deny: Bool, allow: Bool = false, by caller: Chat? = nil) -> Result<String, ArsenalRefusal> {
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
        // A call Auto stopped is a person's to run, at every tier.
        if allow, card.autoStop { return .failure(.init("Only you can run a command Auto asks about.")) }
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

import Foundation

/// What Drive adds (`z-docs/agent-protocol.md`): new chats in the caller's window, sends, stops,
/// a tab brought to the front, question cards answered, and Own's changes on the window's other
/// chats, each at or below the caller's own mode. Each goes through the control a person uses
/// (a new tab as ⌘T and a CLI's pick open it, a message as the composer sends it), so it looks
/// and runs the same; the receiving chat says who it came from. Approving stays the user's.
extension Chat {
    /// What it can do on its own now is no more than `other` can (`noFreer`), and it hasn't been
    /// told Always allow where `other` hasn't: Drive reaches it.
    package func noFreer(than other: Chat) -> Bool {
        let (mine, theirs) = (arsenalRank, other.arsenalRank)
        guard !alwaysAllowed || other.alwaysAllowed else { return false }
        return Self.noFreer(mine.id, unreviewed: mine.unreviewed, than: theirs.id, unreviewed: theirs.unreviewed)
    }

    /// A message from another chat's agent: shown with where it came from, then sent as the
    /// composer would, queued while a turn runs. Never a "/" command: Kore runs some itself (`/plan`
    /// flips Codex's Plan, `/compact` compacts), and the CLIs run their own.
    package func arsenalSend(_ text: String, from caller: String) -> Result<String, ArsenalRefusal> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.init("A message needs some text.")) }
        // Invisible format characters (U+200B, U+FEFF, U+2060, …) before the "/" don't hide it: a CLI may drop them.
        let lead = text.unicodeScalars.first { !$0.properties.isWhitespace && $0.properties.generalCategory != .format }
        guard lead != "/" else { return .failure(.init("Only you send a “/” command.")) }
        let queued = status.isRunning
        note("Arsenal · sent by \(caller)")
        guard sendFromLink(text) else { return .failure(.init("This chat can't take a message right now.")) }
        return .success(queued ? "Queued: it goes when the turn running there ends." : "Sent.")
    }

    /// A question card's answers, an option's label (or typed text, where the card takes it) per
    /// question in order; or `deny`, which any card takes. Nothing else: approving stays the user's.
    package func arsenalAnswer(_ cardId: String, _ choices: [String], deny: Bool) -> Result<String, ArsenalRefusal> {
        guard let card = approvals.pending.first(where: { $0.id == cardId }) else { return .failure(.init("That card was answered or withdrawn.")) }
        guard !card.signIn else { return .failure(.init("Only you answer a sign-in.")) }
        if deny {
            answer(card, .deny)
            note("Arsenal · denied “\(card.title)”")
            return .success("Denied.")
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

extension Workspace {
    /// A new chat as a person opens one: a tab of its own in front, the CLI picked, the model as
    /// the picker would launch it. Its mode is the CLI's usual one when that's no freer than the
    /// caller's, else the highest one that is, or `mode` when asked for and allowed. Its Arsenal is off.
    /// A Codex chat's Plan is its switch, and its permissions still have to pass: Plan restricts
    /// nothing. `model`, when given, is one the CLI lists in an open chat of Kore's.
    package func arsenalNewChat(provider id: String, model: String?, mode: String?, under caller: Chat) -> Result<Chat, ArsenalRefusal> {
        let rank = caller.arsenalRank
        let cap = { (mode: String) in Chat.noFreer(mode, unreviewed: false, than: rank.id, unreviewed: rank.unreviewed) }
        guard let provider = Registry.provider(id) else { return .failure(.init("Kore runs claude or codex.")) }
        let modes = provider.modes.filter(\.listed)
        let named = { (option: ModeOption, name: String) in option.id.lowercased() == name.lowercased() || option.label.lowercased() == name.lowercased() }
        var wanted: ModeOption?
        var plan = false
        if let mode {
            if let toggle = provider.planToggle, named(toggle, mode) {
                plan = true
            } else {
                guard let found = modes.first(where: { named($0, mode) }) else {
                    return .failure(.init("\(provider.name)'s modes: " + (modes + [provider.planToggle].compactMap { $0 }).map(\.id).joined(separator: ", ")))
                }
                guard cap(found.id) else { return .failure(.init("Only you can start a chat above your own mode.")) }
                wanted = found
            }
        }
        let capped = modes.filter { cap($0.id) }
        guard !capped.isEmpty else {
            return .failure(.init("Only you can open a \(provider.name) chat from this one: its lowest mode does more on its own than \(caller.controls.activeMode.label)."))
        }
        var launch: String?
        if let model {
            let known = arsenalModels(provider.id, caller: caller)
            guard !known.isEmpty else { return .failure(.init("Kore doesn't have \(provider.name)'s models yet: open it without --model, then set one.")) }
            guard let option = known.first(where: { $0.id.lowercased() == model.lowercased() || $0.name.lowercased() == model.lowercased() }) else {
                return .failure(.init("\(provider.name) offers: " + known.map(\.id).joined(separator: ", ")))
            }
            launch = option.id
        }
        guard start(provider: id, model: launch), let chat = activeTab.chat else { return .failure(.init("Kore couldn't open a chat.")) }
        if wanted == nil, !cap(chat.controls.mode) {
            wanted = capped.max { Chat.modeLevel($0.id) < Chat.modeLevel($1.id) }
        }
        if let wanted, wanted.id != chat.controls.mode { chat.setMode(wanted.id, remember: false) }
        if plan { chat.setPlanMode(true) }
        return .success(chat)
    }

    /// The models a CLI lists, from a chat of it in this window that has them (the caller's first).
    func arsenalModels(_ provider: String, caller: Chat) -> [ModelOption] {
        let chats = [caller] + tabs.compactMap(\.chat)
        return chats.first { $0.provider.id == provider && !$0.controls.models.isEmpty }?.controls.models ?? []
    }

    /// The chat's tab to the front, as a click on it.
    package func arsenalShow(_ chat: Chat) -> Bool {
        guard let tab = tab(of: chat) else { return false }
        select(tab)
        return true
    }
}

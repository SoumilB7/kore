import Foundation
import KoreCore
import src

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

extension Chat {
    /// Where an agent's fork of this chat starts, as the fork on a message's or an answer's menu
    /// makes it: at the user message `at` names (its row id, its text, or a part only it has), which
    /// goes back to the fork's composer, or after the last answer.
    package func arsenalForkStart(at ref: String?) async -> Result<(start: ForkStart, draft: String), ArsenalRefusal> {
        let entries = transcript.entries
        guard let ref, !ref.isEmpty else {
            guard let last = entries.last(where: { $0.kind == .answer }) else { return .failure(.init("Nothing to fork yet: it hasn't answered.")) }
            guard let start = await forkStart(after: last) else { return .failure(.init("Couldn't fork it: the chat says why.")) }
            return .success((start, ""))
        }
        let messages = entries.filter { ($0.kind == .user || $0.kind == .peer) && !$0.inTurn }
        let wanted = ref.lowercased()
        let found = messages.first { $0.id.uuidString.lowercased() == wanted || $0.text.lowercased() == wanted }
            ?? { let parts = messages.filter { $0.text.lowercased().contains(wanted) }; return parts.count == 1 ? parts[0] : nil }()
        guard let entry = found else { return .failure(.init("No one message matches “\(ref.prefix(80))”: give its row id (kore log), or more of its text.")) }
        guard let start = await forkStart(entry) else { return .failure(.init("Couldn't fork it: the chat says why.")) }
        return .success((start, entry.kind == .user ? entry.text : ""))
    }
}

extension Workspace {
    /// A fork as a person opens one: a tab of its own right after the chat's, in front, in its mode
    /// (so no freer than a caller that reaches it), the same model unless `model` names another it
    /// lists, its Arsenal off. With `message`, the composer is left empty for it.
    package func arsenalOpenFork(_ chat: Chat, _ start: ForkStart, draft: String, model: String?, message: Bool) -> Result<Chat, ArsenalRefusal> {
        var launch: String?
        if let model {
            let known = chat.controls.models.isEmpty ? ArsenalModels.seen[chat.provider.id] ?? [] : chat.controls.models
            switch ArsenalModels.find(model, in: known, cli: chat.provider.name) {
            case .success(let option): launch = option.id
            case .failure(let refusal): return .failure(refusal)
            }
        }
        // An imported chat's fork from its start is written again by Kore and opens later, out of
        // the limits' sight: the user's to make.
        if case .fresh = start, chat.imported != nil {
            return .failure(.init("This chat was imported: only you fork it from its start (its menu's Fork). Fork after a later message instead."))
        }
        guard let fork = fork(chat, start, text: message ? "" : draft) else {
            return .failure(.init("Only you fork this chat from its start."))
        }
        if let launch { fork.launchModel = launch }
        return .success(fork)
    }

    /// A new chat as a person opens one: a tab of its own in front, the CLI picked, the model as
    /// the picker would launch it. Its mode is the CLI's usual one when that's no freer than the
    /// caller's, else the highest one that is, or `mode` when asked for and allowed. Its Arsenal is off.
    /// A Codex chat's Plan is its switch, and its permissions still have to pass: Plan restricts
    /// nothing. `model`, when given, is one the CLI lists in an open chat of Kore's.
    package func arsenalNewChat(provider id: String, model: String?, mode: String?, under caller: Chat) -> Result<Chat, ArsenalRefusal> {
        let rank = caller.arsenalRank
        let cap = { (mode: String) in Chat.noFreer(mode, unreviewed: false, than: rank.id, unreviewed: rank.unreviewed) }
        guard let provider = Registry.provider(id) else { return .failure(.init("Kore runs claude or codex.")) }
        // Codex's Read only isn't in the menu, but a chat can start in it here.
        let modes = provider.modes.filter { $0.listed || $0.id == CodexModes.readOnly }
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
            guard !known.isEmpty else {
                ArsenalModels.fetch(provider.id, folder: folder)
                return .failure(.init("Kore is still reading \(provider.name)'s models: ask again in a moment, or open it without a model."))
            }
            switch ArsenalModels.find(model, in: known, cli: provider.name) {
            case .success(let option): launch = option.id
            case .failure(let refusal): return .failure(refusal)
            }
        }
        guard start(provider: id, model: launch), let chat = activeTab.chat else { return .failure(.init("Kore couldn't open a chat.")) }
        if wanted == nil, !cap(chat.controls.mode) {
            wanted = capped.max { Chat.modeLevel($0.id) < Chat.modeLevel($1.id) }
        }
        if let wanted, wanted.id != chat.controls.mode { chat.setMode(wanted.id, remember: false) }
        if plan { chat.setPlanMode(true) }
        return .success(chat)
    }

    /// The models a CLI lists, from a chat of it in this window that has them (the caller's first),
    /// else as any chat of it last listed them in this run (`ArsenalModels`).
    func arsenalModels(_ provider: String, caller: Chat) -> [ModelOption] {
        let chats = [caller] + tabs.compactMap(\.chat)
        return chats.first { $0.provider.id == provider && !$0.controls.models.isEmpty }?.controls.models ?? ArsenalModels.seen[provider] ?? []
    }

    /// The chat's tab to the front, as a click on it.
    package func arsenalShow(_ chat: Chat) -> Bool {
        guard let tab = tab(of: chat) else { return false }
        select(tab)
        return true
    }
}

/// Each CLI's models as a chat of it last listed them in this run, so Drive can check a model for a
/// CLI with no chat open in the caller's window. Codex's are read once, when Drive is first given
/// and no Codex chat has listed them, from a short-lived app-server (`model/list`).
@MainActor
package enum ArsenalModels {
    package private(set) static var seen: [String: [ModelOption]] = [:]
    private static var fetching: Set<String> = []

    static func record(_ provider: String, _ models: [ModelOption]) {
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

    static func key(_ text: String) -> String { text.lowercased().filter { !" -_".contains($0) } }

    /// Codex's models, read off the main thread once in a run; nothing for a CLI that can't list
    /// them without a chat, and nothing in a storyline (its CLIs are scripted). Given up after
    /// `patience`, the app-server closed; a later Drive or model asked for tries again.
    static func fetch(_ provider: String, folder: URL) {
        guard provider == "codex", seen[provider] == nil, !fetching.contains(provider), StorylineSeams.backend == nil else { return }
        fetching.insert(provider)
        Task {
            defer { fetching.remove(provider) }
            let patience = Self.patience
            let work = Task.detached { () -> [JSONValue] in
                guard let server = try? await CodexAppServer.start(cwd: folder) else { return [] }
                // Closing it ends the process, which fails the request still waiting.
                let list = await withTaskCancellationHandler {
                    (try? await server.request("model/list"))?["data"]?.array ?? []
                } onCancel: {
                    Task { await server.close() }
                }
                await server.close()
                return list
            }
            let timer = Task.detached {
                try await Task.sleep(for: patience)
                work.cancel()
            }
            let list = await work.value
            timer.cancel()
            record(provider, list.compactMap { json -> ModelOption? in
                guard let id = json["id"]?.string, json["hidden"]?.bool != true else { return nil }
                let efforts = json["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string ?? $0.string }
                return ModelOption(id: id, name: json["displayName"]?.string ?? id, resolved: json["model"]?.string ?? id, efforts: efforts ?? [])
            })
        }
    }

    static let patience = Duration.seconds(10)
}

extension String {
    /// One letter added, dropped or changed away from `other` (not equal, and neither empty). A
    /// change that touches a digit or a dot is never forgiven: gpt-5 isn't a typo of gpt-6.
    func isNear(_ other: String) -> Bool {
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

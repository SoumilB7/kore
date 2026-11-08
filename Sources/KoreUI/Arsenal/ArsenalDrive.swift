import Foundation
import HostClient
import KoreCore
import src

extension Chat {
    /// Where an agent's fork of this chat starts, as the fork on a message's or an answer's menu
    /// makes it: at the user message `at` names (its row id, its text, or a part only it has), which
    /// goes back to the fork's composer, or after the last answer. `-N` is the Nth user message from
    /// the end, as the message scroller counts them while the pointer is over it (`-1` the last).
    package func arsenalForkStart(at ref: String?) async -> Result<(start: ForkStart, draft: String), ArsenalRefusal> {
        if let ref, let back = Self.fromEnd(ref) {
            switch await scrollerMessage(back) {
            case .success(let entry):
                guard let start = await forkStart(entry) else { return .failure(.init("Couldn't fork it: the chat says why.")) }
                return .success((start, entry.text))
            case .failure(let refusal): return .failure(refusal)
            }
        }
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

    /// "-3" → 3; nil for anything else.
    static func fromEnd(_ ref: String) -> Int? {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        guard ref.hasPrefix("-"), let n = Int(ref.dropFirst()), n > 0 else { return nil }
        return n
    }

    /// The scroller's message `back` from the end, read in from disk first if it isn't loaded, as a
    /// click on its mark reads it in.
    private func scrollerMessage(_ back: Int) async -> Result<TranscriptLog.Entry, ArsenalRefusal> {
        let store = transcript
        if store.earlierAvailable, store.earlierMarks.isEmpty { await readEarlierMessages() }
        // A chat nobody sees builds its rows only as it shows: its marks are counted from them.
        store.catchUp()
        var marks = store.messageMarks
        guard back <= marks.count else {
            return .failure(.init(marks.isEmpty ? "It has no messages to fork at yet." : "It has \(marks.count) message(s): -1 to -\(marks.count)."))
        }
        if case .earlier(let at) = marks[marks.count - back].place, store.earlierMarks.indices.contains(at) {
            await loadEarlier(turns: store.earlierMarks[at].turns)
            marks = store.messageMarks
        }
        let id: UUID?
        switch marks[max(marks.count - back, 0)].place {
        case .built(let section): id = UUID(uuidString: String(section.dropFirst(2)))
        case .held(let entry): id = entry
        case .earlier: id = nil
        }
        guard let id, let entry = store.entries.first(where: { $0.id == id }) else {
            return .failure(.init("Couldn't read that message in: fork at its text instead."))
        }
        return .success(entry)
    }
}

extension Workspace {
    /// A fork as a person opens one: a tab of its own right after the chat's, in front, in its mode
    /// (so no freer than a caller that reaches it), the same model unless `model` names another it
    /// lists, its Arsenal off. With `message`, the composer is left empty for it.
    package func arsenalOpenFork(_ chat: Chat, _ start: ForkStart, draft: String, model: String?, message: Bool) -> Result<Chat, ArsenalRefusal> {
        var launch: String?
        if let model {
            let known = chat.controls.models.isEmpty ? arsenalModels(chat.provider.id, caller: chat) : chat.controls.models
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
                // A box's CLIs list their own: they come with its next snapshot.
                guard box == nil else { return .failure(.init("\(provider.name) here hasn't listed its models yet: open it without a model.")) }
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

    /// A fork into the other CLI, as Import in a new chat makes one: a new chat of `provider` in a
    /// tab of its own in front, its mode no freer than the caller's (as `chat.new`'s), the whole
    /// conversation carried by Kore's handoff, and the tab carrying on in it. Its Arsenal off.
    package func arsenalForkAcross(_ chat: Chat, to provider: String, model: String?, under caller: Chat) async -> Result<Chat, ArsenalRefusal> {
        // Import carries a history file on this Mac: a box's chats aren't, so none opens there for it.
        if let box { return .failure(.init("A chat on \(NodeNames.name(box.alias)) forks into its own CLI only: leave out provider.")) }
        guard let session = chat.sessionId else { return .failure(.init("Nothing to fork yet: it hasn't started.")) }
        guard !chat.status.isRunning else { return .failure(.init("It's working: fork it into \(Registry.provider(provider)?.name ?? provider) once it's idle.")) }
        let fresh: Chat
        switch arsenalNewChat(provider: provider, model: model, mode: nil, under: caller) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let chat): fresh = chat
        }
        guard let tab = tab(of: fresh) else { return .failure(.init("Kore couldn't open a chat.")) }
        if let refusal = await importChat(.session(provider: chat.provider.id, id: session), into: fresh) {
            close(tab, remember: false)
            return .failure(.init(refusal.reason ?? "Kore can't carry this chat into \(fresh.provider.name)."))
        }
        guard let carried = tab.chat, carried !== fresh else { return .failure(.init("Kore couldn't open a chat.")) }
        return .success(carried)
    }

    /// The models a CLI lists, from a chat of it in this window that has them (the caller's first,
    /// when it runs where this window's chats do), else as any chat of it last listed them in this
    /// run (`ArsenalModels`); a box window's, as its box last listed them.
    func arsenalModels(_ provider: String, caller: Chat) -> [ModelOption] {
        let chats = (caller.services.onBox == (box != nil) ? [caller] : []) + tabs.compactMap(\.chat)
        if let found = chats.first(where: { $0.provider.id == provider && !$0.controls.models.isEmpty }) { return found.controls.models }
        return boxModels(provider) ?? ArsenalModels.seen[provider] ?? []
    }

    /// A past chat of this window's, opened as a click in History opens it: its tab in front if it's
    /// open already, else a tab of its own. `session` is its id, or the start of it only one has.
    /// Opened, its mode is capped as a new chat's is (no freer than the caller's), and its Arsenal
    /// stays off whatever it had: a tier is the user's to give it back. In a box's window it opens
    /// on the box, as that window's History does.
    package func arsenalOpen(session: String, under caller: Chat) async -> Result<(chat: Chat, opened: Bool), ArsenalRefusal> {
        let wanted = session.trimmingCharacters(in: .whitespaces).lowercased()
        func lookup() -> [SessionSummary] {
            chats.filter { $0.id.lowercased() == wanted || (wanted.count >= 6 && $0.id.lowercased().hasPrefix(wanted)) }
        }
        var found = lookup()
        // A box's History is read over the link: read again once before saying it has no such chat.
        if found.isEmpty, box != nil {
            await refresh()
            found = lookup()
        }
        guard let summary = found.first(where: { $0.id.lowercased() == wanted }) ?? (found.count == 1 ? found.first : nil) else {
            return .failure(.init(found.isEmpty ? "No past chat in \(folder.lastPathComponent) has that id." : "Several past chats start with that id: give more of it."))
        }
        if paired != nil, boxRowPlace(summary.id) != nil { return .failure(.init("That chat is on the box: open it from History.")) }
        if box == nil, let tab = tabs.first(where: { $0.chat?.sessionId == summary.id && $0.agent == nil }), let chat = tab.chat {
            select(tab)
            return .success((chat, false))
        }
        let provider = Registry.provider(for: summary.agent)
        let rank = caller.arsenalRank
        let cap = { (mode: String) in Chat.noFreer(mode, unreviewed: false, than: rank.id, unreviewed: rank.unreviewed) }
        // As a new chat's: Codex's Read only isn't in the menu, but a chat can be put in it here.
        let capped = provider.modes.filter { $0.listed || $0.id == CodexModes.readOnly }.filter { cap($0.id) }
        guard !capped.isEmpty else {
            return .failure(.init("Only you can open a \(provider.name) chat from this one: its lowest mode does more on its own than \(caller.controls.activeMode.label)."))
        }
        let chat: Chat
        if let box {
            // On the box, as its History opens it (a closed chat back on the box, or a session its CLI keeps).
            guard let shown = await openBoxSession(summary) else {
                return .failure(.init("\(NodeNames.name(box.alias)) didn't open that chat."))
            }
            if !shown.opened { return .success((shown.chat, false)) }
            chat = shown.chat
        } else {
            open(summary)
            guard let opened = tabs.first(where: { $0.chat?.sessionId == summary.id && $0.agent == nil })?.chat else {
                return .failure(.init("Kore couldn't open that chat."))
            }
            chat = opened
        }
        chat.arsenalByAgent = true
        let opened = chat.arsenalRank
        if !Chat.noFreer(opened.id, unreviewed: opened.unreviewed, than: rank.id, unreviewed: rank.unreviewed), let mode = capped.max(by: { Chat.modeLevel($0.id) < Chat.modeLevel($1.id) }) {
            chat.setMode(mode.id, remember: false)
        }
        return .success((chat, true))
    }

    /// The chat's tab to the front, as a click on it.
    package func arsenalShow(_ chat: Chat) -> Bool {
        guard let tab = tab(of: chat) else { return false }
        select(tab)
        return true
    }
}

/// Codex's models read once from a short-lived app-server, for Drive on this Mac.
extension ArsenalModels {
    private static var fetching: Set<String> = []

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

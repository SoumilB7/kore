import Foundation
import KoreCore
import os

/// A Codex chat: one `codex app-server` process (JSON-RPC), one thread.
@MainActor
final class CodexBackend: ChatBackend {
    let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    private var options: BackendOptions
    private let translator: CodexTranslator
    private var session: CodexSession?
    private var starting: Task<Void, any Error>?
    private var pump: Task<Void, Never>?
    private var replayPending: Bool
    private var resumeId: String?
    /// A fork not opened yet: its first launch forks `resumeId` through this turn.
    private var forkAt: String?
    /// A thread Kore starts has no name until a client sets one. After its first turn Kore saves
    /// the first prompt's `FallbackTitle` as its name (what the Codex extension saves when it
    /// can't generate a title), unless a name came from anywhere first: Kore never replaces one.
    private var mayTitle: Bool
    private var titlePrompt: String?
    /// Where the turns before the ones shown start (`thread/turns/list`'s cursor), and the
    /// rollout, read back as far as they need.
    private var earlierFrom: String?
    private var rollout: CodexRolloutReader?
    /// Turns per page: the newest when a chat opens, then each `earlier()`.
    private static let pageTurns = 10
    private static let log = Logger(subsystem: "Kore", category: "codex")

    var sessionId: String? { translator.threadId ?? resumeId }

    init(_ options: BackendOptions) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        translator = CodexTranslator(folder: options.folder)
        translator.planMode = options.planMode
        replayPending = options.resume != nil
        resumeId = options.resume?.id
        forkAt = options.fork?.at
        mayTitle = options.resume == nil && options.fork == nil
    }

    func start() async throws {
        if session != nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        let session = try await CodexSession.launch(
            .init(
                cwd: options.folder, model: options.model, effort: options.effort,
                permissions: CodexSession.Permissions(rawValue: options.mode) ?? .askForApproval,
                plan: options.planMode, resume: sessionId, forkAt: forkAt))
        // A resumed or forked thread's newest turns, read while Codex resumes it.
        let newest: (turns: [JSONValue], earlier: String?)?
        do {
            newest = try await session.open(page: replayPending ? Self.pageTurns : nil)
        } catch {
            await session.close()
            throw error
        }
        if forkAt != nil {
            // The fork is its own thread from here on (a relaunch resumes it).
            forkAt = nil
            resumeId = await session.threadId
            if let title = options.forkTitle { try? await session.rename(title) }
        }
        if replayPending {
            replayPending = false
            earlierFrom = newest?.earlier
            rollout = await session.rolloutPath.map(CodexRolloutReader.init)
            let replayed = await replay(newest?.turns ?? [], session)
            translator.adopt(replayed.carried)
            // It carries on with the settings its history ended with (the pill shows them), not
            // the ones it launched with.
            if let mode = replayed.carried.mode, let permissions = CodexSession.Permissions(rawValue: mode) {
                options.mode = mode
                await session.setPermissions(permissions)
            }
            if replayed.carried.planKnown {
                options.planMode = replayed.carried.planMode
                await session.setPlanMode(replayed.carried.planMode)
            }
            yield(.replayed(replayed.events))
            yield(.earlierHistory(earlierFrom != nil))
        }
        self.session = session
        pump = Task {
            for await event in session.events {
                // A new sub-agent's nickname, before the event that makes its card.
                let unseen = self.translator.unseenAgents(in: event)
                if !unseen.isEmpty { self.translator.agentThreads.merge(await session.agentThreads(unseen)) { _, new in new } }
                self.handle(event)
            }
        }
        yield(.controlsLoaded(await controls(session)))
    }

    /// A page of turns as events, with their settings from the rollout, parsed off the main
    /// thread on a translator of its own.
    private func replay(_ turns: [JSONValue], _ session: CodexSession) async -> CodexTranslator.Replayed {
        let wanted = turns.map { CodexRolloutReader.Turn(id: $0["id"]?.string ?? "", start: CodexTranslator.date($0["startedAt"])) }
        let reader = rollout
        let (settings, read) = await Task.detached(priority: .userInitiated) { () -> (CodexRollout, CodexRolloutReader?) in
            var reader = reader
            let settings = reader?.read(wanted) ?? CodexRollout()
            return (settings, reader)
        }.value
        rollout = read
        // Its sub-agents' nicknames and outcomes: metadata reads, about a millisecond each.
        let agents = await session.agentThreads(CodexTranslator.agents(in: turns))
        return await CodexTranslator.replayed(turns, rollout: settings, folder: options.folder, agents: agents)
    }

    /// Models (falling back to the account's default when the configured one isn't offered),
    /// effort, and the `/` menu: Codex's own commands plus its skills.
    private func controls(_ session: CodexSession) async -> ChatControls {
        let list = (try? await session.models()) ?? []
        let models = list.compactMap { json -> ModelOption? in
            guard let id = json["id"]?.string, json["hidden"]?.bool != true else { return nil }
            let efforts = json["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string ?? $0.string }
            return ModelOption(
                id: id, name: json["displayName"]?.string ?? id, resolved: json["model"]?.string ?? id,
                efforts: efforts ?? [])
        }
        var current = await session.model
        if current == nil || !models.contains(where: { $0.id == current }) {
            let fallback = (list.first { $0["isDefault"]?.bool == true } ?? list.first)?["id"]?.string
            if let fallback {
                if let old = current { yield(.notice("\(old) isn't available on this account, using \(fallback)")) }
                await session.setModel(fallback)
                current = fallback
            }
        }
        let skills = (try? await session.skills()) ?? []
        let commands =
            [
                SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
                SlashCommand(name: "compact", description: "Summarize the thread to free up context", hint: "", kind: .command),
                SlashCommand(
                    name: "goal", description: "Set a goal Codex keeps working toward until it is done",
                    hint: "objective", kind: .command),
            ]
            + skills.compactMap { json -> SlashCommand? in
                guard let name = json["name"]?.string, json["enabled"]?.bool != false else { return nil }
                return SlashCommand(
                    name: name, description: json["shortDescription"]?.string ?? json["description"]?.string ?? "",
                    hint: "", kind: .skill)
            }
        // What the thread runs at; the model's default only when Codex didn't say.
        let running = await session.reasoningEffort
        let effort = options.effort ?? running
            ?? current.flatMap { id in list.first { $0["id"]?.string == id } }?["defaultReasoningEffort"]?.string
        return ChatControls(models: models, model: current, effort: effort, commands: commands)
    }

    // MARK: - Events

    private func handle(_ event: CodexEvent) {
        translator.translate(event)
        flush()
        if case .turnCompleted = event { saveTitle() }
        if case .exited = event {
            resumeId = sessionId
            session = nil
            pump = nil
        }
    }

    private func flush() {
        let (events, changes) = translator.take()
        for event in events {
            if case .titleChanged = event { mayTitle = false }
            yield(event)
        }
        let folder = options.folder
        for (turn, task) in changes {
            Task {
                let changes = await task.value
                if !changes.isEmpty { yield(.turnChanges(turn, changes)) }
                // Kept for a resumed chat, by Codex's turn id: shell edits are in no item.
                if !changes.isEmpty {
                    Task.detached(priority: .utility) { TurnChangeLog.record(changes, key: turn, folder: folder) }
                }
            }
        }
    }

    private func yield(_ event: ChatEvent) {
        EventLog.write(event)
        sink.yield(event)
        EventLog.loadAgents(event, from: self)
    }

    // MARK: - Actions

    func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool {
        // The Codex extension's /plan is a local toggle: nothing is sent.
        if text == "/plan" && files.isEmpty {
            await setPlanMode(!options.planMode)
            return false
        }
        try await start()
        guard let session else { return false }
        // Its own slash commands map to RPCs (as in t3code); anything else is a prompt.
        if text == "/compact" && files.isEmpty {
            translator.compactRequested = true
            try await session.compact()
            return true
        }
        if text.hasPrefix("/goal ") && files.isEmpty {
            try await session.setGoal(String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            yield(.notice("Goal set"))
            return false
        }
        if mayTitle, titlePrompt == nil { titlePrompt = FallbackTitle.from(text) }
        let input: JSONValue =
            files.isEmpty ? [["type": "text", "text": .string(text), "text_elements": []]] : Attachments.codexInput(text: text, files: files)
        if let queued {
            // While a turn runs, the message joins it (`turn/steer`); otherwise it's the next turn.
            if await session.activeTurnId != nil {
                translator.pendingSteer.insert(queued)
                do {
                    try await session.steer(input: input, clientId: queued)
                    return true
                } catch {
                    translator.pendingSteer.remove(queued)  // the turn ended meanwhile
                }
            }
            translator.nextTurnQueued = queued
        }
        // Snapshot before Codex can edit anything; the turn itself opens on turn/started.
        translator.files.begin()
        await translator.files.ready()
        try await session.send(input: input)
        return true
    }

    func interrupt() async {
        try? await session?.interrupt()
    }

    func respond(to approvalID: String, _ decision: Decision) async {
        guard let request = translator.request(approvalID), let session else { return }
        let mapped: CodexDecision =
            switch decision {
            case .allow, .approvePlan: .accept
            case .allowAlways: .acceptForSession
            case .deny, .keepPlanning: .decline
            case .answers(let answers): .answers(answers.mapValues { [$0] })
            }
        try? await session.respond(to: request, mapped)
    }

    /// `thread/compact/start`: Codex runs it as a turn of its own (a `contextCompaction` item).
    /// It takes no instructions.
    func compact(instructions: String) async throws {
        try await start()
        guard let session else { return }
        translator.compactRequested = true
        try await session.compact()
    }

    func setMode(_ id: String) async throws {
        options.mode = id
        translator.userChanged(mode: id)
        flush()
        if let permissions = CodexSession.Permissions(rawValue: id) { await session?.setPermissions(permissions) }
    }

    func setPlanMode(_ on: Bool) async {
        options.planMode = on
        translator.userChanged(plan: on)
        flush()
        await session?.setPlanMode(on)
    }

    func setModel(_ id: String) async throws {
        options.model = id
        await session?.setModel(id)
    }

    func setEffort(_ level: String) async {
        await session?.setEffort(level)
    }

    func rename(_ title: String) async throws {
        mayTitle = false
        try await start()
        try await session?.rename(title)
    }

    /// Once, with one retry (the extension's: a thread just started can say its rollout is empty).
    private func saveTitle() {
        guard mayTitle, let name = titlePrompt, let session else { return }
        mayTitle = false
        Task {
            do {
                try await session.rename(name)
            } catch {
                try? await Task.sleep(for: .milliseconds(500))
                do { try await session.rename(name) } catch {
                    Self.log.warning("Couldn't save the thread's name: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stopAgent(_ id: String) async {
        guard let turn = translator.childTurn(id) else { return }
        try? await session?.interrupt(thread: id, turn: turn)
    }

    func agentHistory(_ id: String) async -> [ChatEvent] {
        try? await start()
        guard let session, let turns = try? await session.readThread(id) else { return [] }
        let history = await CodexTranslator.agentHistory(turns, agent: id, folder: options.folder, agents: translator.agentThreads)
        // Its own sub-agents and last words, as an older page's are: the live mode stays.
        translator.adopt(history.carried, history: true)
        return history.events
    }

    /// The turns before the message's turn, forked by the new tab's own app-server when it opens
    /// (`thread/fork` through the turn before; a thread forked here would stay this process's to
    /// write); the message itself goes in the new tab's composer.
    func fork(message id: String?, text: String) async throws -> ForkStart {
        try await start()
        guard let session, let thread = sessionId else { return .fresh }
        // A replayed message by its turn's id; one sent in this run by its text from the end.
        if let id, let start = try await fork(session, thread, view: .notLoaded, at: { $0["id"]?.string == id }) { return start }
        let match = { (turn: JSONValue) in
            (turn["items"]?.array ?? []).contains { item in
                item["type"]?.string == "userMessage"
                    && (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n") == text
            }
        }
        if let start = try await fork(session, thread, view: .summary, at: match) { return start }
        throw ForkError.notFound
    }

    /// Finds the newest turn `at` matches, a page at a time from the end (a long thread's turns
    /// are never read whole), and forks through the turn before it. Nil when none matches.
    private func fork(
        _ session: CodexSession, _ thread: String, view: CodexSession.TurnsView, at match: (JSONValue) -> Bool
    ) async throws -> ForkStart? {
        var cursor: String?
        var found = false
        repeat {
            let page = try await session.turns(of: thread, before: cursor, limit: 50, view: view)
            for turn in page.turns.reversed() {
                if found, let before = turn["id"]?.string { return .pending(ForkPoint(from: thread, at: before)) }
                found = match(turn)
            }
            cursor = page.earlier
        } while cursor != nil
        // The thread's first turn: nothing comes before it.
        return found ? .fresh : nil
    }

    /// Through the thread's last turn (`thread/fork`'s `lastTurnId` keeps turns through it):
    /// only the newest page is read, one turn without its items.
    func forkAtEnd() async throws -> ForkStart {
        try await start()
        guard let session, let thread = sessionId else { return .fresh }
        let newest = try await session.turns(of: thread, before: nil, limit: 1, view: .notLoaded)
        guard let last = newest.turns.last?["id"]?.string else { return .fresh }
        return .pending(ForkPoint(from: thread, at: last))
    }

    /// The ten turns before the ones shown.
    func earlier() async -> (events: [ChatEvent], more: Bool)? {
        guard let from = earlierFrom else { return nil }
        try? await start()
        guard let session, let thread = sessionId,
            let older = try? await session.turns(of: thread, before: from, limit: Self.pageTurns)
        else { return nil }
        earlierFrom = older.earlier
        // An older page is history only: it starts from no mode and leaves the live one alone.
        let replayed = await replay(older.turns, session)
        translator.adopt(replayed.carried, history: true)
        return (replayed.events, older.earlier != nil)
    }

    func close() async {
        pump?.cancel()
        pump = nil
        let session = session
        self.session = nil
        await session?.close()
        sink.finish()
    }
}

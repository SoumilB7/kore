import Foundation
import KoreCore

/// A Claude Code chat: one `claude -p` process (stream-json plus the control protocol).
@MainActor
final class ClaudeBackend: ChatBackend {
    let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    private var options: BackendOptions
    private let translator: ClaudeTranslator
    private var session: ClaudeSession?
    private var starting: Task<Void, any Error>?
    private var pump: Task<Void, Never>?
    private var replayPending: Bool
    /// The session has a name, or a prompt was sent to make one from.
    private var titled: Bool
    /// Transcript entries already taken as the cause of a CLI-started turn.
    private var resolvedTurns: Set<String> = []
    /// Background agents being followed through their transcripts.
    private var tails: [String: Task<Void, Never>] = [:]
    /// Where the conversation before what's shown goes on (a compaction's logical parent).
    private var earlierFrom: String?
    /// A fork's new session got its "(fork)" title.
    private var forkNamed = false
    /// The source session's transcript, indexed once and kept: later pages read only their lines.
    private var transcript: (id: String, reader: ClaudeTranscript)?

    var sessionId: String? { translator.sessionId }

    /// The session whose transcript holds the history: a fork reads the one it was made from
    /// until its own exists.
    private var source: String? { sessionId ?? options.fork?.from }

    /// History pages for `id`, read off the main thread.
    private func page(_ id: String, before: String? = nil, userTurns: Int? = nil) async -> ClaudeHistory.Page {
        let reader: ClaudeTranscript
        if let transcript, transcript.id == id {
            reader = transcript.reader
        } else {
            reader = ClaudeTranscript(sessionId: id, in: options.folder)
            transcript = (id, reader)
        }
        return await Task.detached(priority: .userInitiated) { reader.page(before: before, userTurns: userTurns) }.value
    }

    init(_ options: BackendOptions) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        // A fork has no session of its own until its first message makes one.
        translator = ClaudeTranslator(folder: options.folder, sessionId: options.fork == nil ? options.resume?.id : nil)
        replayPending = options.resume != nil
        titled = options.resume != nil
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
        // A resumed session's past is read while the CLI starts, and shown as soon as it's read
        // (a page takes a fraction of a second, the CLI a second or more).
        let folder = options.folder
        // A fork not yet made: its history is the original's up to the fork point, and the CLI
        // makes the new session (`--fork-session`) on the first message.
        let fork = sessionId == nil ? options.fork : nil
        // Only a first launch reads history: a relaunch (the CLI exited, the next send starts it
        // again) shows what's already there.
        let past: Task<ClaudeHistory.Page, Never>? =
            if !replayPending {
                nil
            } else if let history = fork?.history {
                Task { history }
            } else {
                source.map { id in Task { await page(id, before: fork?.at) } }
            }
        // Only needed once: the transcript holds it from here.
        options.fork?.history = nil
        var launch = ClaudeSession.Options(
            cwd: options.folder, model: options.model, effort: options.effort,
            permissionMode: ClaudeSession.PermissionMode(rawValue: options.mode) ?? .default,
            resume: fork?.from ?? sessionId)
        if let fork { launch.extraArgs += ["--fork-session", "--resume-session-at", fork.at] }
        let starting = Task { try await ClaudeSession.start(launch) }
        if let past {
            replayPending = false
            let first = await past.value
            earlierFrom = first.earlier
            // Parsed into events off the main thread, on a translator of its own.
            let replayed = await ClaudeTranslator.replayed(first.messages, folder: folder, sessionId: translator.sessionId)
            translator.adopt(replayed.carried)
            yield(.replayed(replayed.events))
            yield(.earlierHistory(earlierFrom != nil))
        }
        let session = try await starting.value
        self.session = session
        // Ends when the process does; `close()` cancels it.
        pump = Task {
            for await event in session.events { self.handle(event) }
        }
        yield(.controlsLoaded(await controls(session)))
        // The context's fill and window as soon as the CLI is up (a resumed chat's too).
        refreshContext()
    }

    private func controls(_ session: ClaudeSession) async -> ChatControls {
        let models = (await session.capabilities["models"]?.array ?? []).compactMap { json -> ModelOption? in
            guard let value = json["value"]?.string, value != "default" else { return nil }
            return ModelOption(
                id: value, name: json["displayName"]?.string ?? value,
                resolved: json["resolvedModel"]?.string ?? value,
                efforts: json["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [],
                supportsAutoMode: json["supportsAutoMode"]?.bool ?? false)
        }
        let commands = (await session.capabilities["commands"]?.array ?? []).compactMap { json -> SlashCommand? in
            guard let name = json["name"]?.string else { return nil }
            return SlashCommand(
                name: name, description: json["description"]?.string ?? "",
                hint: json["argumentHint"]?.string ?? "", kind: .command)
        }
        var controls = ChatControls(models: models, model: nil, effort: nil, commands: commands)
        if let applied = try? await session.settings()["applied"] {
            if let model = applied["model"]?.string {
                controls.model = models.first { $0.resolved == model }?.id ?? model
            }
            controls.effort = applied["effort"]?.string
        }
        return controls
    }

    // MARK: - Events

    private func handle(_ event: ClaudeEvent) {
        translator.translate(event)
        flush()
        if case .exited = event {
            session = nil
            pump = nil
        }
    }

    private func flush() {
        let (events, followups) = translator.take()
        for event in events {
            yield(event)
            // A background agent's commands don't reach stdout; its transcript has them.
            if case .agentSpawned(let agent) = event, agent.background { tail(agent.id) }
        }
        for followup in followups { run(followup) }
    }

    private func yield(_ event: ChatEvent) {
        EventLog.write(event)
        sink.yield(event)
        EventLog.loadAgents(event, from: self)
    }

    /// Asks the CLI how full the context is (`get_context_usage`).
    private func refreshContext() {
        guard let session else { return }
        Task {
            guard let usage = try? await session.contextUsage() else { return }
            translator.contextReported(usage)
            flush()
        }
    }

    private func run(_ followup: ClaudeTranslator.Followup) {
        let folder = options.folder
        switch followup {
        case .contextUsage:
            refreshContext()
        case .peer(let uuid, let turn):
            // Stdout doesn't carry a peer's message; its transcript entry is written as the
            // turn starts, so it's retried briefly.
            guard let session = sessionId else { return }
            Task {
                for _ in 0..<15 {
                    let entry = await Task.detached { ClaudeHistory.entry(uuid: uuid, sessionId: session, in: folder) }.value
                    if let entry {
                        if let peer = PeerMessage(entry: entry) {  // else e.g. a queued prompt of ours
                            yield(.turnOrigin(turn, .peer))
                            yield(.peerMessage(from: peer.from, text: peer.text, turn: turn))
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        case .cliTurn(let turn, let started):
            guard let session = sessionId else { return }
            Task {
                for _ in 0..<15 {
                    let entry = await Task.detached { ClaudeHistory.latestCLITurn(sessionId: session, in: folder) }.value
                    // Only an entry written for this turn (an older one is a past turn's).
                    if let entry, let uuid = entry["uuid"]?.string, !resolvedTurns.contains(uuid),
                        (ClaudeTranslator.date(entry["timestamp"]) ?? .distantPast) > started.addingTimeInterval(-10),
                        let origin = ClaudeTranslator.origin(entry["turnOrigin"]?.string)
                    {
                        resolvedTurns.insert(uuid)
                        yield(.turnOrigin(turn, origin))
                        if origin == .agentFinished {
                            translator.taskNotification(entry)
                            flush()
                        }
                        if let peer = PeerMessage(entry: entry) {
                            yield(.peerMessage(from: peer.from, text: peer.text, turn: turn))
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        case .changes(let turn, let key, let task):
            Task {
                let changes = await task.value
                if !changes.isEmpty { yield(.turnChanges(turn, changes)) }
                // Kept for a resumed chat: the transcript has no record of shell edits.
                if let key, !changes.isEmpty {
                    Task.detached(priority: .utility) { TurnChangeLog.record(changes, key: key, folder: folder) }
                }
            }
        }
    }

    // MARK: - Sub-agents

    func agentHistory(_ id: String) async -> [ChatEvent] {
        guard let session = sessionId else { return [] }
        let folder = options.folder
        let entries = await Task.detached {
            ClaudeHistory.subagentFile(toolUseId: id, sessionId: session, in: folder).map { ClaudeHistory.entries(in: $0).entries }
        }.value
        guard let entries else { return [] }
        return await ClaudeTranslator.agentHistory(entries, agent: id, folder: folder)
    }

    /// Reads a running background agent's transcript as it grows, until the agent finishes.
    private func tail(_ id: String) {
        guard tails[id] == nil, let session = sessionId else { return }
        let folder = options.folder
        tails[id] = Task {
            var file: URL?
            var offset: UInt64 = 0
            while !Task.isCancelled {
                let finished = translator.isFinished(id)
                if file == nil {
                    file = await Task.detached { ClaudeHistory.subagentFile(toolUseId: id, sessionId: session, in: folder) }.value
                }
                if let file {
                    let start = offset
                    let (entries, next) = await Task.detached { ClaudeHistory.entries(in: file, from: start) }.value
                    offset = next
                    for event in translator.agentEntries(entries, agent: id, skippingPrompt: start == 0, live: true) {
                        yield(event)
                    }
                }
                if finished { break }
                try? await Task.sleep(for: .milliseconds(700))
            }
            tails[id] = nil
        }
    }

    // MARK: - Fork and earlier history

    /// The history before the user message, as a fork the CLI makes on its first message
    /// (`--fork-session --resume-session-at` the message before it, as the extension does).
    func fork(message id: String?, text: String) async throws -> ForkStart {
        guard let source else { return .fresh }
        // A replayed message is found by its id (also in an earlier page); one sent in this run,
        // by its text from the end of the current history.
        let found = await page(source, before: id)
        let messages = found.messages
        let target = id.flatMap { id in messages.lastIndex { $0["uuid"]?.string == id } }
            ?? messages.lastIndex { $0["type"]?.string == "user" && ClaudeTranslator.promptText($0["message"]?["content"]) == text }
        guard let target else { throw ForkError.notFound }
        guard let before = messages[..<target].lastIndex(where: { !ClaudeHistory.isBoundary($0) }),
            let at = messages[before]["uuid"]?.string
        else { return .fresh }
        let history = ClaudeHistory.Page(messages: Array(messages[...before]), earlier: found.earlier)
        return .pending(ForkPoint(from: source, at: at, history: history))
    }

    /// Through the last message of the current history (`--resume-session-at` takes an
    /// assistant's uuid as well as a user's).
    func forkAtEnd() async throws -> ForkStart {
        guard let source else { return .fresh }
        let found = await page(source)
        guard let last = found.messages.last(where: { !ClaudeHistory.isBoundary($0) }), let at = last["uuid"]?.string else {
            return .fresh
        }
        return .pending(ForkPoint(from: source, at: at, history: found))
    }

    func earlier() async -> (events: [ChatEvent], more: Bool)? {
        guard let from = earlierFrom, let source else { return nil }
        let older = await page(source, before: from, userTurns: 10)
        earlierFrom = older.earlier
        // An older page is history only: it starts from no mode and leaves the live one alone.
        let replayed = await ClaudeTranslator.replayed(older.messages, folder: options.folder, sessionId: source)
        translator.adopt(replayed.carried, history: true)
        return (replayed.events, older.earlier != nil)
    }

    // MARK: - Context

    /// `/compact` as the CLI's own command (as Claude's VS Code extension sends it): no user
    /// message in the transcript; "compacting", then the boundary, come from the CLI.
    func compact(instructions: String) async throws {
        try await start()
        guard let session else { return }
        translator.compactRequested = true
        try await session.send(instructions.isEmpty ? "/compact" : "/compact \(instructions)")
    }

    // MARK: - Actions

    func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool {
        try await start()
        guard let session else { return false }
        if text.trimmingCharacters(in: .whitespaces) == "/compact" { translator.compactRequested = true }
        // A message sent while a turn runs: stamped with Kore's id, so its echo (mid-turn, at the
        // next tool boundary) or its `command_lifecycle` start (as the next turn) says where it went.
        let midTurn = queued != nil && translator.turn != nil
        if let queued, midTurn {
            translator.pendingQueued.insert(queued)
        } else if let queued {
            translator.startQueuedTurn(queued)
        } else {
            translator.openTurn(.user)
        }
        flush()
        // Snapshot before the CLI can edit anything.
        await translator.files.ready()
        do {
            if files.isEmpty {
                try await session.send(text, uuid: midTurn ? queued : nil)
            } else {
                // Reading and encoding files can take a moment; keep it off the main actor.
                let folder = options.folder
                let content = await Task.detached { Attachments.claudeContent(text: text, files: files, folder: folder) }.value
                try await session.send(content: content, uuid: midTurn ? queued : nil)
            }
        } catch {
            if let queued, midTurn {
                translator.pendingQueued.remove(queued)
            } else {
                translator.abandonTurn()
            }
            flush()
            throw error
        }
        // A fork's session exists from its first message: give it its "(fork)" title.
        if let title = options.forkTitle, !forkNamed {
            forkNamed = true
            try? await session.rename(title)
        }
        // Headless sessions don't name themselves; ask, as the VS Code extension does. Not
        // awaited: the next message (sent mid-turn) shouldn't wait on it.
        if !titled && !text.isEmpty && !text.hasPrefix("/") {
            titled = true
            Task { if let title = try? await session.generateTitle(from: text) { yield(.titleChanged(title)) } }
        }
        return true
    }

    /// Also drops messages queued behind the turn (Stop gives their text back to the composer).
    func interrupt() async {
        try? await session?.interrupt(cancelQueued: !translator.pendingQueued.isEmpty)
    }

    func respond(to approvalID: String, _ decision: Decision) async {
        guard let request = translator.request(approvalID), let session else { return }
        let mapped: PermissionDecision =
            switch decision {
            case .allow: .allow
            case .allowAlways: .allowAlways
            case .deny: .deny(message: "The user denied this tool call.")
            case .answers(let answers): .answers(answers)
            case .approvePlan(let autoAcceptEdits): autoAcceptEdits ? .allowSettingMode("acceptEdits") : .allow
            case .keepPlanning: .deny(message: "The user wants to keep planning. Ask what to change.")
            }
        try? await session.respond(to: request, mapped)
    }

    func setMode(_ id: String) async throws {
        options.mode = id
        guard let session, let mode = ClaudeSession.PermissionMode(rawValue: id) else { return }
        translator.requestMode(id)
        do {
            try await session.setPermissionMode(mode)
        } catch {
            translator.modeRefused()
            flush()
            throw error
        }
    }

    func setPlanMode(_ on: Bool) async {}

    func setModel(_ id: String) async throws {
        options.model = id
        try await session?.setModel(id)
    }

    func setEffort(_ level: String) async {
        try? await session?.setEffort(level)
    }

    func rename(_ title: String) async throws {
        try await start()
        titled = true
        try await session?.rename(title)
    }

    func stopAgent(_ id: String) async {
        guard let task = translator.taskId(forAgent: id) else { return }
        try? await session?.stopTask(task)
    }

    func close() async {
        for tail in tails.values { tail.cancel() }
        tails = [:]
        pump?.cancel()
        pump = nil
        let session = session
        self.session = nil
        await session?.close()
        sink.finish()
    }
}

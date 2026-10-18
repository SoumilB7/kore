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

    var sessionId: String? { translator.sessionId }

    init(_ options: BackendOptions) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        translator = ClaudeTranslator(folder: options.folder, sessionId: options.resume?.id)
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
        // A resumed session's past is read while the CLI starts (both take about a second on a
        // long session), not after.
        let folder = options.folder
        let past = replayPending ? sessionId.map { id in Task.detached { ClaudeHistory.messages(sessionId: id, in: folder) } } : nil
        let session = try await ClaudeSession.start(
            .init(
                cwd: options.folder, model: options.model,
                permissionMode: ClaudeSession.PermissionMode(rawValue: options.mode) ?? .default,
                resume: sessionId))
        if let past {
            replayPending = false
            yield(.replayed(translator.replay(await past.value)))
        }
        self.session = session
        // Ends when the process does; `close()` cancels it.
        pump = Task {
            for await event in session.events { self.handle(event) }
        }
        yield(.controlsLoaded(await controls(session)))
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

    private func run(_ followup: ClaudeTranslator.Followup) {
        let folder = options.folder
        switch followup {
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
        case .changes(let turn, let task):
            Task {
                let changes = await task.value
                if !changes.isEmpty { yield(.turnChanges(turn, changes)) }
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
        return entries.map { translator.agentEntries($0, agent: id, skippingPrompt: true, live: false) } ?? []
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

    // MARK: - Actions

    func send(_ text: String, files: [Attachments.File]) async throws -> Bool {
        try await start()
        guard let session else { return false }
        translator.openTurn(.user)
        flush()
        // Snapshot before the CLI can edit anything.
        await translator.files.ready()
        do {
            if files.isEmpty {
                try await session.send(text)
            } else {
                // Reading and encoding files can take a moment; keep it off the main actor.
                let folder = options.folder
                let content = await Task.detached { Attachments.claudeContent(text: text, files: files, folder: folder) }.value
                try await session.send(content: content)
            }
        } catch {
            translator.abandonTurn()
            flush()
            throw error
        }
        // Headless sessions don't name themselves; ask, as the VS Code extension does.
        if !titled && !text.isEmpty && !text.hasPrefix("/") {
            titled = true
            if let title = try? await session.generateTitle(from: text) { yield(.titleChanged(title)) }
        }
        return true
    }

    func interrupt() async {
        try? await session?.interrupt()
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
        try await session.setPermissionMode(mode)
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

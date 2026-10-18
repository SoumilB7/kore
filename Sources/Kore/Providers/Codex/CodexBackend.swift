import Foundation
import KoreCore

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

    var sessionId: String? { translator.threadId ?? resumeId }

    init(_ options: BackendOptions) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        translator = CodexTranslator(folder: options.folder)
        translator.planMode = options.planMode
        replayPending = options.resume != nil
        resumeId = options.resume?.id
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
        let session = try await CodexSession.start(
            .init(
                cwd: options.folder, model: options.model,
                permissions: CodexSession.Permissions(rawValue: options.mode) ?? .askForApproval,
                plan: options.planMode, resume: sessionId))
        if replayPending {
            replayPending = false
            yield(.replayed(translator.replay(await session.history)))
        }
        self.session = session
        pump = Task {
            for await event in session.events { self.handle(event) }
        }
        yield(.controlsLoaded(await controls(session)))
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
        let effort = current.flatMap { id in list.first { $0["id"]?.string == id } }?["defaultReasoningEffort"]?.string
        return ChatControls(models: models, model: current, effort: effort, commands: commands)
    }

    // MARK: - Events

    private func handle(_ event: CodexEvent) {
        translator.translate(event)
        let (events, changes) = translator.take()
        for event in events { yield(event) }
        for (turn, task) in changes {
            Task {
                let changes = await task.value
                if !changes.isEmpty { yield(.turnChanges(turn, changes)) }
            }
        }
        if case .exited = event {
            resumeId = sessionId
            session = nil
            pump = nil
        }
    }

    private func yield(_ event: ChatEvent) {
        EventLog.write(event)
        sink.yield(event)
        EventLog.loadAgents(event, from: self)
    }

    // MARK: - Actions

    func send(_ text: String, files: [Attachments.File]) async throws -> Bool {
        // The Codex extension's /plan is a local toggle: nothing is sent.
        if text == "/plan" && files.isEmpty {
            await setPlanMode(!options.planMode)
            yield(.planModeChanged(options.planMode))
            return false
        }
        try await start()
        guard let session else { return false }
        // Its own slash commands map to RPCs (as in t3code); anything else is a prompt.
        if text == "/compact" && files.isEmpty {
            try await session.compact()
            return true
        }
        if text.hasPrefix("/goal ") && files.isEmpty {
            try await session.setGoal(String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            yield(.notice("Goal set"))
            return false
        }
        // Snapshot before Codex can edit anything; the turn itself opens on turn/started.
        translator.files.begin()
        await translator.files.ready()
        if files.isEmpty {
            try await session.send(text)
        } else {
            try await session.send(input: Attachments.codexInput(text: text, files: files))
        }
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

    func setMode(_ id: String) async throws {
        options.mode = id
        if let permissions = CodexSession.Permissions(rawValue: id) { await session?.setPermissions(permissions) }
    }

    func setPlanMode(_ on: Bool) async {
        options.planMode = on
        translator.planMode = on
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
        try await start()
        try await session?.rename(title)
    }

    func stopAgent(_ id: String) async {
        guard let turn = translator.childTurn(id) else { return }
        try? await session?.interrupt(thread: id, turn: turn)
    }

    func agentHistory(_ id: String) async -> [ChatEvent] {
        try? await start()
        guard let session, let turns = try? await session.readThread(id) else { return [] }
        return translator.agentTurns(turns, agent: id)
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

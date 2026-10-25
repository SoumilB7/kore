import Foundation

/// One Codex thread on its own `codex app-server` process.
///
/// Flow: initialize → thread/start (or thread/resume) → turn/start per user message. A
/// turn/start sent while a turn is running steers that turn instead of starting a new one.
public actor CodexSession {
    /// The Codex CLI's `/permissions` presets, as approval policy + sandbox + reviewer.
    public enum Permissions: String, Sendable, CaseIterable {
        /// Read workspace files; edits and internet access need approval.
        case readOnly
        /// Read, edit and run commands in the workspace; going beyond it needs approval. Codex's default.
        case askForApproval
        /// Like askForApproval, but a reviewer agent approves and only unsafe actions reach the user.
        case approveForMe
        /// No sandbox, never ask.
        case fullAccess

        var approvalPolicy: JSONValue { self == .fullAccess ? "never" : "on-request" }

        var approvalsReviewer: JSONValue { self == .approveForMe ? "auto_review" : "user" }

        /// thread/start takes a sandbox mode string...
        var sandboxMode: JSONValue {
            switch self {
            case .readOnly: "read-only"
            case .askForApproval, .approveForMe: "workspace-write"
            case .fullAccess: "danger-full-access"
            }
        }

        /// ...turn/start takes a sandbox policy object.
        var sandboxPolicy: JSONValue {
            switch self {
            case .readOnly: ["type": "readOnly"]
            case .askForApproval, .approveForMe: ["type": "workspaceWrite"]
            case .fullAccess: ["type": "dangerFullAccess"]
            }
        }
    }

    public struct Options: Sendable {
        public var cwd: URL
        /// nil uses the model from ~/.codex/config.toml.
        public var model: String?
        /// "minimal", "low", "medium", "high", "xhigh"
        public var effort: String?
        public var permissions: Permissions
        /// Codex's Plan collaboration mode: research and propose a plan before changing anything.
        public var plan: Bool
        /// Thread id from a previous `.threadStarted`, to continue that conversation.
        public var resume: String?
        /// Opens a new thread holding `resume`'s turns through this one (`thread/fork`) instead.
        public var forkAt: String?
        /// Developer instructions for the thread, given each time it's opened (a handed-off chat's
        /// CLAUDE.md, in a folder without AGENTS.md).
        public var developerInstructions: String?
        public var executable: URL?
        public var environment: [String: String]

        public init(
            cwd: URL,
            model: String? = nil,
            effort: String? = nil,
            permissions: Permissions = .askForApproval,
            plan: Bool = false,
            resume: String? = nil,
            forkAt: String? = nil,
            developerInstructions: String? = nil,
            executable: URL? = nil,
            environment: [String: String] = [:]
        ) {
            self.cwd = cwd
            self.model = model
            self.effort = effort
            self.permissions = permissions
            self.plan = plan
            self.resume = resume
            self.forkAt = forkAt
            self.developerInstructions = developerInstructions
            self.executable = executable
            self.environment = environment
        }
    }

    public nonisolated let events: AsyncStream<CodexEvent>
    private let sink: AsyncStream<CodexEvent>.Continuation
    private let server: CodexAppServer
    private let options: Options
    private var permissions: Permissions
    private var plan: Bool
    private var effort: String?
    /// The reasoning effort the thread runs at: Kore's choice, else what the thread started or
    /// resumed with (config.toml's, or the one it last ran on).
    public var reasoningEffort: String? { effort }

    public private(set) var threadId = ""
    public private(set) var activeTurnId: String?
    private var finishedTurnId: String?
    /// Model the thread runs on; updated by `setModel`.
    public private(set) var model: String?
    /// The model Codex has the loaded thread on: what it opened with, then each turn's
    /// (`thread/settings/updated`). A `setModel` reaches it with the next turn, or `compact`.
    public private(set) var threadModel: String?
    /// While `reopen` waits for Codex to unload the thread.
    private var unloading: CheckedContinuation<Void, Never>?
    private var unloaded = false
    /// The thread's rollout file, where each turn's settings are kept (`CodexRolloutReader`).
    public private(set) var rolloutPath: String?
    /// Codex had no rollout for the thread to resume (it never ran a turn), so `open` started a
    /// new one in its place, with the same settings.
    public private(set) var startedFresh = false

    /// The rollout is on disk. Codex writes a thread's rollout with its first turn: before that
    /// the thread is only in memory, and can be neither resumed nor compacted.
    public var hasRollout: Bool { Self.rolloutExists(rolloutPath) }

    public nonisolated static func rolloutExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Codex's answer to `thread/resume` for a thread with no rollout ("no rollout found for
    /// thread id …"): there's nothing to resume.
    public nonisolated static func isMissingRollout(_ error: any Error) -> Bool {
        guard case CodexAppServer.Failure.rpc(_, let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("no rollout found")
    }
    /// Spawns the app-server and opens (or resumes) the thread.
    public static func start(_ options: Options) async throws -> CodexSession {
        let session = try await launch(options)
        do {
            _ = try await session.open()
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    /// Spawns the app-server only; `open` opens the thread.
    public static func launch(_ options: Options) async throws -> CodexSession {
        let server = try await CodexAppServer.start(
            cwd: options.cwd, executable: options.executable, environment: options.environment)
        return CodexSession(server: server, options: options)
    }

    /// Opens, resumes or forks the thread. A resumed or forked thread's turns don't come with it
    /// (a long one's are tens of MB): `turns` pages them. `page`: also its newest turns, read
    /// while Codex resumes it. Sent before the resume, a read slows it (twice as long on a
    /// small thread); sent just after, it's answered in tens of ms while the resume runs on.
    public func open(page limit: Int? = nil) async throws -> (turns: [JSONValue], earlier: String?)? {
        try await openThread(page: limit)
    }

    private init(server: CodexAppServer, options: Options) {
        self.server = server
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        permissions = options.permissions
        plan = options.plan
        effort = options.effort
    }

    // MARK: - Public API

    public func send(_ text: String) async throws {
        try await send(input: [["type": "text", "text": .string(text), "text_elements": []]])
    }

    /// Adds `input` to the running turn (`turn/steer`): it joins after the current item, as a
    /// `userMessage` item with `clientId`. Throws when no turn is running.
    public func steer(input: JSONValue, clientId: String) async throws {
        guard let turnId = activeTurnId else { throw CodexAppServer.Failure.rpc(code: -32600, message: "no active turn to steer") }
        _ = try await server.request(
            "turn/steer",
            ["threadId": .string(threadId), "expectedTurnId": .string(turnId), "input": input, "clientUserMessageId": .string(clientId)])
    }

    /// `input` is an array of Codex UserInput items (text, localImage, image, mention, skill).
    public func send(input: JSONValue) async throws {
        // Every setting is sent on every turn, as t3code does: some (the reviewer, the
        // collaboration mode) otherwise stay sticky from an earlier turn.
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "input": input,
            "approvalPolicy": permissions.approvalPolicy,
            "approvalsReviewer": permissions.approvalsReviewer,
            "sandboxPolicy": permissions.sandboxPolicy,
            // Model catalogs can default reasoning summaries to "none".
            "summary": "detailed",
        ]
        if let effort { params["effort"] = .string(effort) }
        if let model {
            params["model"] = .string(model)
            var settings: [String: JSONValue] = ["model": .string(model)]
            if let effort { settings["reasoning_effort"] = .string(effort) }
            params["collaborationMode"] = ["mode": plan ? "plan" : "default", "settings": .object(settings)]
        }
        let started = try await server.request("turn/start", .object(params))
        // The reply names the turn before `turn/started` does, so a message sent right after
        // can steer it; unless the turn already finished meanwhile.
        if let id = started["turn"]?["id"]?.string, id != finishedTurnId { activeTurnId = id }
    }

    public func respond(to approval: CodexApproval, _ decision: CodexDecision) async throws {
        try await server.respond(to: approval.id, result: decision.result(for: approval))
    }

    /// Stops the running turn; a `.turnCompleted` with status "interrupted" follows.
    public func interrupt() async throws {
        guard let turnId = activeTurnId else { return }
        _ = try await server.request("turn/interrupt", ["threadId": .string(threadId), "turnId": .string(turnId)])
    }

    /// Another thread's turns with their items, e.g. a sub-agent's (its own thread on this app-server).
    public func readThread(_ id: String) async throws -> [JSONValue] {
        let result = try await server.request("thread/read", ["threadId": .string(id), "includeTurns": true])
        return result["thread"]?["turns"]?.array ?? []
    }

    /// How much of each turn's items `turns` returns.
    public enum TurnsView: String, Sendable {
        /// Every item.
        case full
        /// The user's and agent's messages only.
        case summary
        /// None: ids, times and status.
        case notLoaded
    }

    /// Up to `limit` turns of `thread` (this one by default) before `cursor` (nil: the newest),
    /// oldest first, and the cursor for the ones before them (nil when there are none).
    public func turns(
        of thread: String? = nil, before cursor: String? = nil, limit: Int, view: TurnsView = .full
    ) async throws -> (turns: [JSONValue], earlier: String?) {
        let result = try await server.request("thread/turns/list", Self.turnsParams(thread ?? threadId, cursor, limit, view))
        return Self.page(result)
    }

    private static func turnsParams(_ thread: String, _ cursor: String?, _ limit: Int, _ view: TurnsView) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(thread), "sortDirection": "desc", "limit": .number(Double(limit)), "itemsView": .string(view.rawValue),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        return .object(params)
    }

    private static func page(_ result: JSONValue) -> (turns: [JSONValue], earlier: String?) {
        ((result["data"]?.array ?? []).reversed(), result["nextCursor"]?.string)
    }

    /// A thread's metadata (nickname, role, rollout path…) without its turns.
    public func threadInfo(_ id: String) async throws -> JSONValue {
        try await server.request("thread/read", ["threadId": .string(id), "includeTurns": false])["thread"] ?? .null
    }

    /// Stops a sub-agent's running turn (its own thread on this app-server).
    public func interrupt(thread: String, turn: String) async throws {
        _ = try await server.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
    }

    /// A thread's processes still running (this one by default), from its commands in a turn and
    /// those that outlived one: `[{itemId, processId, command, cwd, osPid, cpuPercent, rssKb}]`.
    /// Experimental.
    public func backgroundTerminals(of thread: String? = nil) async throws -> [JSONValue] {
        try await server.request("thread/backgroundTerminals/list", ["threadId": .string(thread ?? threadId)])["data"]?.array ?? []
    }

    /// Ends one of them; its item completes as failed (exit -1). False when it had already ended.
    public func terminate(process: String, in thread: String? = nil) async throws -> Bool {
        let result = try await server.request(
            "thread/backgroundTerminals/terminate", ["threadId": .string(thread ?? threadId), "processId": .string(process)])
        return result["terminated"]?.bool ?? false
    }

    /// Takes effect from the next turn.
    public func setPermissions(_ permissions: Permissions) {
        self.permissions = permissions
    }

    /// Takes effect from the next turn.
    public func setPlanMode(_ on: Bool) {
        plan = on
    }

    /// Takes effect from the next turn, or the next compaction (`compact`).
    public func setModel(_ model: String) {
        self.model = model
    }

    /// Reasoning effort ("low", "medium", "high", ...). Takes effect from the next turn.
    public func setEffort(_ effort: String?) {
        self.effort = effort
    }

    /// Models this account can use: `[{id, model, displayName, isDefault, ...}]`.
    public func models() async throws -> [JSONValue] {
        try await server.request("model/list")["data"]?.array ?? []
    }

    /// Skills available in this folder: `[{name, path, description, enabled, scope}]`.
    /// A skill is invoked by mentioning it as `$name` in a message.
    public func skills() async throws -> [JSONValue] {
        let data = try await server.request("skills/list", ["cwds": [.string(options.cwd.path)]])["data"]?.array ?? []
        let entry = data.first { $0["cwd"]?.string == options.cwd.path }
        return entry?["skills"]?.array ?? data.flatMap { $0["skills"]?.array ?? [] }
    }

    /// The account and its plan's limits, read from this app-server (`PlanUsage.codex`).
    public func planUsage() async throws -> PlanReading {
        try await PlanUsage.codex(server)
    }

    /// Uses one full reset of the account's limits (`PlanUsage.useReset`).
    public func useReset(credit: String?, attempt: UUID) async throws -> PlanResetOutcome {
        try await PlanUsage.useReset(server, credit: credit, attempt: attempt)
    }

    /// Summarizes the thread to free context. Runs as a turn (turn/started → turn/completed).
    /// Codex compacts with the model the thread is loaded on, which only a turn changes: a model
    /// picked since (or the fallback for one the account can't use) is put on the thread first.
    public func compact() async throws {
        // Before its first turn a thread is only in memory: there's nothing to summarize (Codex
        // would still call the model), and unloaded it would be gone.
        let empty = activeTurnId == nil && !hasRollout
        if empty, rolloutPath != nil {
            throw CodexAppServer.Failure.rpc(code: -32600, message: "Nothing to compact yet")
        }
        if let model, model != threadModel, activeTurnId == nil {
            if empty { throw CodexAppServer.Failure.rpc(code: -32600, message: "Nothing to compact yet") }
            try await reopen(model: model)
        }
        _ = try await server.request("thread/compact/start", ["threadId": .string(threadId)])
    }

    /// Puts the idle thread on `model` without a turn. Codex has no request for that, and ignores
    /// a resume's overrides while the thread is loaded: so it's unloaded (`thread/unsubscribe`,
    /// then `thread/closed`) and resumed with them, its turns left out. Throws when Codex keeps
    /// it on another model.
    private func reopen(model: String) async throws {
        unloaded = false
        let status = try await server.request("thread/unsubscribe", ["threadId": .string(threadId)])["status"]?.string
        if status == "unsubscribed", !unloaded {
            // Bounded: if it never comes, the resume below says what Codex kept.
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.didUnload()
            }
            await withCheckedContinuation { unloading = $0 }
            timeout.cancel()
        }
        let result = try await server.request("thread/resume", Self.reopenParams(threadId, model: model, cwd: options.cwd, permissions))
        threadModel = result["model"]?.string
        guard threadModel == model else {
            throw CodexAppServer.Failure.rpc(
                code: -32600, message: "Codex kept this thread on \(threadModel ?? "its model"); send a message to move it to \(model)")
        }
    }

    /// `thread/resume` putting a thread on `model`, under the current permissions, without its turns.
    static func reopenParams(_ thread: String, model: String, cwd: URL, _ permissions: Permissions) -> JSONValue {
        [
            "threadId": .string(thread), "model": .string(model), "cwd": .string(cwd.path), "excludeTurns": true,
            "approvalPolicy": permissions.approvalPolicy, "approvalsReviewer": permissions.approvalsReviewer,
            "sandbox": permissions.sandboxMode,
        ]
    }

    private func didUnload() {
        unloaded = true
        unloading?.resume()
        unloading = nil
    }

    public func rename(_ name: String) async throws {
        _ = try await server.request("thread/name/set", ["threadId": .string(threadId), "name": .string(name)])
    }

    /// Appends Responses items to the thread's model-visible history (`thread/inject_items`):
    /// written to its rollout at once, seen by the model from the next turn, and shown as no
    /// turn in any Codex view.
    public func inject(_ items: [JSONValue]) async throws {
        _ = try await server.request("thread/inject_items", ["threadId": .string(threadId), "items": .array(items)])
    }

    /// Sets an objective Codex keeps working toward across turns.
    /// A short title for a chat from its first message, written by `model` in an ephemeral
    /// thread of an app-server of its own, so nothing of it reaches this thread or its events.
    /// Codex names no thread itself and has no call that writes a name; Claude's CLI writes one
    /// with a model the same way. Nil when it can't (30 s at most).
    public func generateTitle(from text: String, model: String) async -> String? {
        let options = options
        let prompt = "Write a title of at most six words for a chat that begins with the message below. "
            + "Reply with the title only: no quotes, no full stop.\n\n" + String(text.prefix(2000))
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let server = try? await CodexAppServer.start(cwd: options.cwd, executable: options.executable, environment: options.environment)
                else { return nil }
                defer { Task { await server.close() } }
                guard let started = try? await server.request("thread/start", [
                    "cwd": .string(options.cwd.path), "model": .string(model), "ephemeral": true, "sandbox": "read-only",
                    "approvalPolicy": "never",
                ]), let thread = started["thread"]?["id"]?.string,
                    (try? await server.request("turn/start", [
                        "threadId": .string(thread), "input": [["type": "text", "text": .string(prompt), "text_elements": []]],
                    ])) != nil
                else { return nil }
                for await incoming in server.incoming {
                    switch incoming {
                    case .notification("item/completed", let params) where params["item"]?["type"]?.string == "agentMessage":
                        return params["item"]?["text"]?.string.flatMap(Self.title)
                    case .notification("turn/completed", _), .exited: return nil
                    default: continue
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A model's title, trimmed to one line without quotes or a full stop; nil when empty or long.
    public nonisolated static func title(_ said: String) -> String? {
        var line = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*#. ").union(.whitespaces))
        return line.isEmpty || line.count > 80 ? nil : line
    }

    public func setGoal(_ objective: String) async throws {
        _ = try await server.request("thread/goal/set", ["threadId": .string(threadId), "objective": .string(objective)])
    }

    public func close() async {
        await server.close()
    }

    /// The app-server's process id, how it ended and whether Kore asked it to, for the session log.
    public var process: (id: Int32?, end: ProcessEnd?, closeAsked: Bool) {
        get async { (await server.processId, await server.processEnd, await server.closeAsked) }
    }

    // MARK: - Wiring

    private func openThread(page limit: Int?) async throws -> (turns: [JSONValue], earlier: String?)? {
        var params: [String: JSONValue] = [
            "cwd": .string(options.cwd.path),
            "approvalPolicy": options.permissions.approvalPolicy,
            "approvalsReviewer": options.permissions.approvalsReviewer,
            "sandbox": options.permissions.sandboxMode,
        ]
        if let model = options.model { params["model"] = .string(model) }
        if let instructions = options.developerInstructions { params["developerInstructions"] = .string(instructions) }

        let result: JSONValue
        var page: (turns: [JSONValue], earlier: String?)?
        if let resume = options.resume, options.forkAt == nil {
            params["threadId"] = .string(resume)
            params["excludeTurns"] = true
            do {
                if let limit {
                    let replies = await server.requests([
                        ("thread/resume", .object(params)), ("thread/turns/list", Self.turnsParams(resume, nil, limit, .full)),
                    ])
                    result = try replies[0].get()
                    page = (try? replies[1].get()).map(Self.page)
                } else {
                    result = try await server.request("thread/resume", .object(params))
                }
            } catch where Self.isMissingRollout(error) {
                // A thread that never ran a turn left nothing to resume: a new one, as it would
                // have started.
                params["threadId"] = nil
                params["excludeTurns"] = nil
                result = try await server.request("thread/start", .object(params))
                page = nil
                startedFresh = true
            }
        } else if let resume = options.resume, let turn = options.forkAt {
            params["threadId"] = .string(resume)
            params["lastTurnId"] = .string(turn)
            params["excludeTurns"] = true
            result = try await server.request("thread/fork", .object(params))
        } else {
            result = try await server.request("thread/start", .object(params))
        }
        threadId = result["thread"]?["id"]?.string ?? ""
        rolloutPath = result["thread"]?["path"]?.string
        // A fork's turns exist once Codex has made it.
        if let limit, page == nil, options.forkAt != nil {
            page = try? await turns(limit: limit)
        }
        model = result["model"]?.string
        threadModel = model
        if effort == nil { effort = result["reasoningEffort"]?.string }
        sink.yield(.threadStarted(threadId: threadId, model: result["model"]?.string, raw: result))

        // Holds the session alive for as long as the app-server runs.
        Task {
            for await message in server.incoming { await handle(message) }
        }
        return page
    }

    private func handle(_ message: CodexAppServer.Incoming) async {
        switch message {
        case .notification(let method, let params):
            // Sub-agents share the connection; only our thread's notifications are the chat's.
            if let other = params["threadId"]?.string, !threadId.isEmpty, other != threadId {
                sink.yield(.subThread(threadId: other, method: method, params: params))
            } else {
                sink.yield(event(method: method, params: params))
            }
        case .request(let id, let method, let params):
            if let approval = CodexApproval(id: id, method: method, params: params) {
                sink.yield(.approvalRequest(approval))
            } else {
                // Dynamic tool calls, token refresh, attestation, legacy v1 approvals: we
                // register none of those, so refuse rather than leave Codex waiting.
                try? await server.respondError(to: id, message: "Kore does not handle \(method)")
            }
        case .stderr(let text):
            sink.yield(.stderr(text))
        case .exited(let status):
            activeTurnId = nil
            sink.yield(.exited(status: status))
            sink.finish()
        }
    }

    private func event(method: String, params: JSONValue) -> CodexEvent {
        switch method {
        case "turn/started": activeTurnId = params["turn"]?["id"]?.string
        case "turn/completed":
            activeTurnId = nil
            finishedTurnId = params["turn"]?["id"]?.string
        case "thread/settings/updated":
            if let model = params["threadSettings"]?["model"]?.string { threadModel = model }
        case "thread/closed": didUnload()
        default: break
        }
        return CodexEvent(notification: method, params: params)
    }
}

extension CodexEvent {
    /// Maps one notification. Also maps a sub-agent's (`.subThread`) notifications, which have the
    /// same shapes.
    public init(notification method: String, params: JSONValue) {
        let itemId = params["itemId"]?.string ?? ""
        let delta = params["delta"]?.string ?? ""
        self =
            switch method {
            case "turn/started": .turnStarted(turnId: params["turn"]?["id"]?.string ?? "")
            case "turn/completed": .turnCompleted(CodexTurnResult(params))
            case "item/started": .itemStarted(CodexItem(params["item"] ?? .null))
            case "item/completed": .itemCompleted(CodexItem(params["item"] ?? .null))
            case "item/agentMessage/delta": .textDelta(itemId: itemId, delta)
            case "item/reasoning/summaryTextDelta": .reasoningDelta(itemId: itemId, delta)
            case "item/plan/delta": .planDelta(itemId: itemId, delta)
            case "item/commandExecution/outputDelta": .commandOutputDelta(itemId: itemId, delta)
            case "serverRequest/resolved": .approvalResolved(requestId: params["requestId"] ?? .null)
            case "error":
                .error(
                    message: CodexError.readable(params["error"]?["message"]?.string ?? "unknown error"),
                    willRetry: params["willRetry"]?.bool ?? false)
            default: .raw(method: method, params: params)
            }
    }
}

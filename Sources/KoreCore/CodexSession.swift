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

    public private(set) var threadId = ""
    public private(set) var activeTurnId: String?
    /// Model the thread runs on; updated by `setModel`.
    public private(set) var model: String?
    /// Turns of a resumed thread (each with its `items`), oldest first.
    public private(set) var history: [JSONValue] = []
    /// The thread's rollout file, where each turn's settings are kept (`CodexHistory.turnSettings`).
    public private(set) var rolloutPath: String?

    /// Spawns the app-server and opens (or resumes) the thread.
    public static func start(_ options: Options) async throws -> CodexSession {
        let server = try await CodexAppServer.start(
            cwd: options.cwd, executable: options.executable, environment: options.environment)
        let session = CodexSession(server: server, options: options)
        do {
            try await session.openThread()
        } catch {
            await server.close()
            throw error
        }
        return session
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
        _ = try await server.request("turn/start", .object(params))
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

    /// Stops a sub-agent's running turn (its own thread on this app-server).
    public func interrupt(thread: String, turn: String) async throws {
        _ = try await server.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
    }

    /// Takes effect from the next turn.
    public func setPermissions(_ permissions: Permissions) {
        self.permissions = permissions
    }

    /// Takes effect from the next turn.
    public func setPlanMode(_ on: Bool) {
        plan = on
    }

    /// Takes effect from the next turn.
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

    /// Summarizes the thread to free context. Runs as a turn (turn/started → turn/completed).
    public func compact() async throws {
        _ = try await server.request("thread/compact/start", ["threadId": .string(threadId)])
    }

    public func rename(_ name: String) async throws {
        _ = try await server.request("thread/name/set", ["threadId": .string(threadId), "name": .string(name)])
    }

    /// Sets an objective Codex keeps working toward across turns.
    public func setGoal(_ objective: String) async throws {
        _ = try await server.request("thread/goal/set", ["threadId": .string(threadId), "objective": .string(objective)])
    }

    public func close() async {
        await server.close()
    }

    // MARK: - Wiring

    private func openThread() async throws {
        var params: [String: JSONValue] = [
            "cwd": .string(options.cwd.path),
            "approvalPolicy": options.permissions.approvalPolicy,
            "approvalsReviewer": options.permissions.approvalsReviewer,
            "sandbox": options.permissions.sandboxMode,
        ]
        if let model = options.model { params["model"] = .string(model) }

        let result: JSONValue
        if let resume = options.resume {
            params["threadId"] = .string(resume)
            if let turn = options.forkAt { params["lastTurnId"] = .string(turn) }
            result = try await server.request(options.forkAt == nil ? "thread/resume" : "thread/fork", .object(params))
            history = result["thread"]?["turns"]?.array ?? []
        } else {
            result = try await server.request("thread/start", .object(params))
        }
        threadId = result["thread"]?["id"]?.string ?? ""
        rolloutPath = result["thread"]?["path"]?.string
        model = result["model"]?.string
        sink.yield(.threadStarted(threadId: threadId, model: result["model"]?.string, raw: result))

        // Holds the session alive for as long as the app-server runs.
        Task {
            for await message in server.incoming { await handle(message) }
        }
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
        case "turn/completed": activeTurnId = nil
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
                    message: params["error"]?["message"]?.string ?? "unknown error",
                    willRetry: params["willRetry"]?.bool ?? false)
            default: .raw(method: method, params: params)
            }
    }
}

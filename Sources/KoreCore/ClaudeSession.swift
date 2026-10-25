import Foundation

/// One long-lived `claude` process driving one conversation, spoken to the same way the
/// Claude Agent SDK does it (which is what t3code uses under the hood):
///
///     claude -p --input-format stream-json --output-format stream-json --verbose
///            --include-partial-messages --permission-prompt-tool stdio
///
/// stdin and stdout carry newline-delimited JSON. Besides conversation messages, both
/// directions carry control traffic:
///   us → CLI   control_request  {initialize | interrupt | set_permission_mode | set_model}
///   CLI → us   control_response (answers to the above)
///   CLI → us   control_request  {can_use_tool}  → we reply with a control_response
///   CLI → us   control_cancel_request           (a pending can_use_tool was withdrawn)
public actor ClaudeSession {
    public enum PermissionMode: String, Sendable, CaseIterable {
        case `default`, acceptEdits, plan, auto, dontAsk, bypassPermissions
    }

    public struct Options: Sendable {
        public var cwd: URL
        public var model: String?
        public var effort: String?
        public var permissionMode: PermissionMode
        /// Explicit session choice; nil leaves the CLI's settings alone. True is only passed
        /// after the user enables fast mode. Availability is never probed by enabling it.
        public var fastMode: Bool?
        /// Session id from a previous `SessionInfo`, to continue that conversation.
        public var resume: String?
        public var thinkingSummaries: Bool
        /// Explicit binary path; otherwise resolved from the login shell's PATH.
        public var executable: URL?
        public var extraArgs: [String]
        public var environment: [String: String]

        public init(
            cwd: URL,
            model: String? = nil,
            effort: String? = nil,
            permissionMode: PermissionMode = .default,
            fastMode: Bool? = nil,
            resume: String? = nil,
            thinkingSummaries: Bool = true,
            executable: URL? = nil,
            extraArgs: [String] = [],
            environment: [String: String] = [:]
        ) {
            self.cwd = cwd
            self.model = model
            self.effort = effort
            self.permissionMode = permissionMode
            self.fastMode = fastMode
            self.resume = resume
            self.thinkingSummaries = thinkingSummaries
            self.executable = executable
            self.extraArgs = extraArgs
            self.environment = environment
        }

        var arguments: [String] {
            var args = [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                // Each user message is echoed where the CLI takes it: mid-turn for one sent while a
                // turn runs (it joins at the next tool boundary), or as its own turn.
                "--replay-user-messages",
                "--permission-prompt-tool", "stdio",
                "--permission-mode", permissionMode.rawValue,
            ]
            // Like the CLI and VS Code extension, Bypass is only available when explicitly launched in it.
            if permissionMode == .bypassPermissions { args.append("--allow-dangerously-skip-permissions") }
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
            if let resume { args += ["--resume", resume] }
            if let fastMode { args += ["--settings", fastMode ? #"{"fastMode":true}"# : #"{"fastMode":false}"#] }
            if thinkingSummaries { args += ["--thinking-display", "summarized"] }
            return args + extraArgs
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notRunning
        case controlError(String)

        public var description: String {
            switch self {
            case .notRunning: "claude process is not running"
            case .controlError(let message): "claude control request failed: \(message)"
            }
        }
    }

    public nonisolated let events: AsyncStream<ClaudeEvent>
    private let sink: AsyncStream<ClaudeEvent>.Continuation
    private let options: Options
    private var io: StdioProcess?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var running = false

    /// Latest session id; changes when the CLI forks a resumed session.
    public private(set) var sessionId: String?
    /// The `initialize` response: slash commands, models, account info, etc.
    public private(set) var capabilities: JSONValue = .null
    /// Fast mode from `initialize`. Each turn's `result` reports the current state again.
    public private(set) var fastMode: ClaudeFastMode?

    /// Spawns the CLI and completes the initialize handshake.
    public static func start(_ options: Options) async throws -> ClaudeSession {
        let session = ClaudeSession(options)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await session.launch()
                try Task.checkCancellation()
            } onCancel: {
                Task { _ = await session.close(waiting: .seconds(6)) }
            }
            return session
        } catch {
            if !(await session.close(waiting: .seconds(6))), let pending = await session.pendingShutdown { throw pending }
            throw error
        }
    }

    private init(_ options: Options) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Public API

    /// Queues a user message. Messages sent mid-turn are picked up by the CLI as it goes.
    /// `uuid` stamps it: the CLI keeps it for the message's echo and `command_lifecycle`.
    public func send(_ text: String, uuid: String? = nil) throws {
        try send(content: .string(text), uuid: uuid)
    }

    /// `content` is a string or an array of Anthropic content blocks (text, image, ...).
    public func send(content: JSONValue, uuid: String? = nil) throws {
        var message: [String: JSONValue] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": nil,
            "session_id": .string(sessionId ?? ""),
        ]
        if let uuid { message["uuid"] = .string(uuid) }
        try write(.object(message))
    }

    public func respond(to request: PermissionRequest, _ decision: PermissionDecision) throws {
        try write([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": .string(request.id),
                "response": decision.payload(for: request),
            ],
        ])
    }

    /// Stops the current turn. The process stays up; a `result` event follows. `cancelQueued` also
    /// drops uuid-stamped messages still waiting (otherwise the CLI runs them as the next turn).
    public func interrupt(cancelQueued: Bool = false) async throws {
        try await control("interrupt", cancelQueued ? ["cancel_queued": true] : [:])
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        try await control("set_permission_mode", ["mode": .string(mode.rawValue)])
    }

    /// `nil` resets to the default model.
    public func setModel(_ model: String?) async throws {
        try await control("set_model", ["model": model.map(JSONValue.string) ?? nil])
    }

    /// "low", "medium", "high", "xhigh", "max". Applies from the next request.
    public func setEffort(_ level: String) async throws {
        try await control("apply_flag_settings", ["settings": ["effortLevel": .string(level)]])
    }

    /// Fast mode, from the next request. The CLI says whether it took (`result`'s `fast_mode_state`).
    public func setFastMode(_ on: Bool) async throws {
        try await control("apply_flag_settings", Self.fastModeFields(on))
    }

    nonisolated static func fastModeFields(_ on: Bool) -> [String: JSONValue] {
        ["settings": ["fastMode": .bool(on)]]
    }

    /// Asks the CLI to name the session from `description` (e.g. the first prompt) and saves it
    /// as the session's AI title, as the VS Code extension does.
    public func generateTitle(from description: String) async throws -> String? {
        try await control("generate_session_title", ["description": .string(description), "persist": true])["title"]?
            .string
    }

    /// A user rename; saved as the session's custom title.
    public func rename(_ title: String) async throws {
        try await control("rename_session", ["title": .string(title), "source": "host"])
    }

    /// Stops one task (its `task_started` task id): a sub-agent, a shell, a monitor, also one in
    /// the foreground.
    public func stopTask(_ taskId: String) async throws {
        try await control("stop_task", ["task_id": .string(taskId)])
    }

    /// Whether a `stop_task` refusal says the task had already ended ("Task … is not running
    /// (status: completed)", "No task found with ID: …").
    public nonisolated static func alreadyEnded(_ error: any Error) -> Bool {
        guard case Failure.controlError(let message) = error else { return false }
        return message.contains("is not running") || message.hasPrefix("No task found")
    }

    /// Sends the foreground task started by the call `toolUseId` to the background (Ctrl+B): the
    /// call returns, the task runs on. False when nothing of it ran in the foreground.
    public func backgroundTask(toolUseId: String) async throws -> Bool {
        try await control("background_tasks", ["tool_use_id": .string(toolUseId)])["backgrounded"]?.bool ?? false
    }

    /// The end of a shell's or a Monitor's output, at most its last 8 KiB, running or ended.
    public func taskOutput(_ taskId: String) async throws -> String {
        try await control("get_task_output", ["task_id": .string(taskId)])["output"]?.string ?? ""
    }

    /// Effective settings; `applied.model` and `applied.effort` are what the next turn uses.
    /// How full the context is: `totalTokens`, `maxTokens` (the window), `autoCompactThreshold`,
    /// `isAutoCompactEnabled`, by category. "summary" answers from the last response's usage and
    /// local estimates, without token-count calls. Works before the first message.
    public func contextUsage() async throws -> JSONValue {
        try await control("get_context_usage", ["detail": "summary"])
    }

    public func settings() async throws -> JSONValue {
        try await control("get_settings")
    }

    /// The plan's limits (`rate_limits`, `subscription_type`, `rate_limits_available`), without
    /// the behaviour breakdown, which takes seconds more. Experimental in the CLI.
    public func usage() async throws -> JSONValue {
        try await control("get_usage", ["skip_behaviors": true])
    }

    /// Starts a sign-in (`claude_authenticate`): `loginWithClaudeAi` and any other field the
    /// method sends. Answers `{manualUrl, automaticUrl}`; the CLI opens no browser.
    public func authenticate(_ fields: [String: JSONValue]) async throws -> JSONValue {
        try await control("claude_authenticate", fields)
    }

    /// Delivers a pasted code only to the CLI that started this sign-in.
    public func submitSignIn(_ code: LoginCallback.Code) async throws {
        _ = try await control("claude_oauth_callback", ["authorizationCode": .string(code.authorizationCode), "state": .string(code.state)])
    }

    /// Waits for the sign-in started above to finish in the browser; answers `{account}`.
    public func waitForSignIn() async throws -> JSONValue {
        try await control("claude_oauth_wait_for_completion")
    }

    /// Ends the process.
    public func close() {
        closeAsked = true
        guard running else { return }
        io?.close()
    }

    /// A forced account change cannot start another CLI until this child has exited.
    public func close(waiting limit: Duration) async -> Bool {
        io?.prepareOwnedClose()
        close()
        guard let io else { return true }
        return await io.waitForExit(within: limit)
    }

    private var pendingShutdown: PendingCLIShutdown? { io.map(PendingCLIShutdown.init) }

    /// The process's id, for the session log.
    public var processId: Int32? { io?.pid }
    /// How the process ended, once it has.
    public var processEnd: ProcessEnd? { io?.end }
    /// Kore asked it to end (`close()`), so its exit was expected.
    public private(set) var closeAsked = false

    // MARK: - Process lifecycle

    private func launch() async throws {
        let resolved = try await CLIExecutable.resolve("claude", override: options.executable)
        try Task.checkCancellation()
        let io = try StdioProcess(
            executable: resolved.url,
            arguments: options.arguments,
            cwd: options.cwd,
            environment: resolved.environment.merging(options.environment) { $1 })
        self.io = io
        running = true

        // Holds the session alive for as long as the process runs.
        Task {
            for await output in io.output {
                switch output {
                case .line(let line): handle(line: line)
                case .stderr(let text): sink.yield(.stderr(text))
                case .exited(let status): didExit(status: status)
                }
            }
        }

        capabilities = try await control("initialize")
        fastMode = ClaudeFastMode(capabilities)
    }

    private func didExit(status: Int32) {
        running = false
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: Failure.notRunning) }
        sink.yield(.exited(status: status))
        sink.finish()
    }

    // MARK: - Wire

    private func handle(line: Data) {
        guard let message = try? JSONValue.parse(line) else {
            sink.yield(.stderr("unparseable stdout line: \(String(decoding: line, as: UTF8.self))\n"))
            return
        }

        switch message["type"]?.string {
        case "control_response":
            let response = message["response"]
            guard let id = response?["request_id"]?.string, let continuation = pending.removeValue(forKey: id) else {
                return
            }
            if response?["subtype"]?.string == "error" {
                continuation.resume(throwing: Failure.controlError(response?["error"]?.string ?? "unknown error"))
            } else {
                continuation.resume(returning: response?["response"] ?? .null)
            }

        case "control_request":
            let id = message["request_id"]?.string ?? ""
            let request = message["request"] ?? .null
            if request["subtype"]?.string == "can_use_tool" {
                sink.yield(.permissionRequest(PermissionRequest(id: id, request)))
            } else {
                // hook_callback, mcp_message, ...: we register none of those, so refuse
                // rather than leave the CLI waiting forever.
                try? write([
                    "type": "control_response",
                    "response": [
                        "subtype": "error",
                        "request_id": .string(id),
                        "error": .string("unsupported control request: \(request["subtype"]?.string ?? "?")"),
                    ],
                ])
            }

        case "control_cancel_request":
            sink.yield(.permissionCancelled(requestId: message["request_id"]?.string ?? ""))

        default:
            let event = ClaudeEvent(message: message)
            if case .sessionStarted(let info) = event { sessionId = info.sessionId }
            sink.yield(event)
        }
    }

    @discardableResult
    private func control(_ subtype: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = UUID().uuidString
        var request = fields
        request["subtype"] = .string(subtype)
        let message: JSONValue = ["type": "control_request", "request_id": .string(id), "request": .object(request)]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(message)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ message: JSONValue) throws {
        guard running, let io else { throw Failure.notRunning }
        try io.write(message)
    }
}

import Foundation

/// JSON-RPC connection to `codex app-server` (what t3code uses for Codex). Messages are
/// newline-delimited JSON-RPC 2.0 without the `"jsonrpc"` field:
///   us → server   {"id": n, "method", "params"}  requests, answered by {"id": n, "result" | "error"}
///   us → server   {"method", "params"}           notifications ("initialized")
///   server → us   {"method", "params"}           notifications (streaming, item and turn lifecycle)
///   server → us   {"id", "method", "params"}     requests we must answer (approvals, user input)
public actor CodexAppServer {
    public enum Incoming: Sendable {
        case notification(method: String, params: JSONValue)
        /// Must be answered with `respond(to:result:)` or `respondError(to:code:message:)`.
        case request(id: JSONValue, method: String, params: JSONValue)
        case stderr(String)
        case exited(status: Int32)
    }

    public enum Failure: Error, CustomStringConvertible {
        case notRunning
        case rpc(code: Int, message: String)

        public var description: String {
            switch self {
            case .notRunning: "codex app-server is not running"
            case .rpc(let code, let message): "codex app-server error \(code): \(message)"
            }
        }
    }

    public nonisolated let incoming: AsyncStream<Incoming>
    private let sink: AsyncStream<Incoming>.Continuation
    private var io: StdioProcess?
    private var running = false
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    /// The `initialize` response: user agent, CODEX_HOME, platform.
    public private(set) var info: JSONValue = .null

    /// Spawns `codex app-server` and completes the initialize handshake.
    public static func start(
        cwd: URL,
        executable: URL? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> CodexAppServer {
        let server = CodexAppServer()
        try await server.launch(cwd: cwd, executable: executable, arguments: arguments, environment: environment)
        return server
    }

    private init() {
        (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func request(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let id = nextId
        nextId += 1
        let message: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": params]
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

    public func notify(_ method: String, _ params: JSONValue? = nil) throws {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        try write(.object(message))
    }

    public func respond(to id: JSONValue, result: JSONValue) throws {
        try write(["id": id, "result": result])
    }

    public func respondError(to id: JSONValue, code: Int = -32601, message: String) throws {
        try write(["id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    public func close() {
        guard running else { return }
        io?.close()
    }

    // MARK: - Process lifecycle

    private func launch(cwd: URL, executable: URL?, arguments: [String], environment: [String: String]) async throws {
        let resolved = try await CLIExecutable.resolve("codex", override: executable)
        let io = try StdioProcess(
            executable: resolved.url,
            arguments: ["app-server"] + arguments,
            cwd: cwd,
            environment: resolved.environment.merging(environment) { $1 })
        self.io = io
        running = true

        Task {
            for await output in io.output {
                switch output {
                case .line(let line): handle(line: line)
                case .stderr(let text): sink.yield(.stderr(text))
                case .exited(let status): didExit(status: status)
                }
            }
        }

        info = try await request("initialize", [
            "clientInfo": ["name": "kore", "title": "Kore", "version": "0.1.0"],
            // Plan mode (collaborationMode) and plan deltas are experimental API.
            "capabilities": ["experimentalApi": true],
        ])
        try notify("initialized")
    }

    private func didExit(status: Int32) {
        running = false
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: Failure.notRunning) }
        sink.yield(.exited(status: status))
        sink.finish()
    }

    private func handle(line: Data) {
        guard let message = try? JSONValue.parse(line) else {
            sink.yield(.stderr("unparseable stdout line: \(String(decoding: line, as: UTF8.self))\n"))
            return
        }
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"] {
                sink.yield(.request(id: id, method: method, params: params))
            } else {
                sink.yield(.notification(method: method, params: params))
            }
        } else if let id = message["id"]?.int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] {
                continuation.resume(throwing: Failure.rpc(
                    code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "unknown error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    private func write(_ message: JSONValue) throws {
        guard running, let io else { throw Failure.notRunning }
        try io.write(message)
    }
}

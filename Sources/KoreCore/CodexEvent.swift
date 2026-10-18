import Foundation

/// What a `CodexSession` emits to the UI. Codex models a turn as a list of items
/// (agentMessage, reasoning, commandExecution, fileChange, mcpToolCall, ...), each with a
/// started → deltas → completed lifecycle. Anything not modeled arrives as `.raw`.
public enum CodexEvent: Sendable {
    case threadStarted(threadId: String, model: String?, raw: JSONValue)
    case turnStarted(turnId: String)
    case itemStarted(CodexItem)
    case itemCompleted(CodexItem)
    /// Streaming text of an agentMessage item.
    case textDelta(itemId: String, String)
    /// Streaming reasoning summary of a reasoning item.
    case reasoningDelta(itemId: String, String)
    /// Streaming text of a plan item (Plan mode's proposed plan).
    case planDelta(itemId: String, String)
    /// Live stdout/stderr of a commandExecution item.
    case commandOutputDelta(itemId: String, String)
    /// Codex is blocked until `CodexSession.respond(to:_:)` is called.
    case approvalRequest(CodexApproval)
    /// A pending approval was settled (by us, or withdrawn because the turn ended).
    case approvalResolved(requestId: JSONValue)
    case turnCompleted(CodexTurnResult)
    case error(message: String, willRetry: Bool)
    /// A notification for another thread on this app-server: a sub-agent the chat's thread
    /// spawned (`collaboration.spawn_agent`) streams its own items and turns here.
    case subThread(threadId: String, method: String, params: JSONValue)
    case raw(method: String, params: JSONValue)
    case stderr(String)
    case exited(status: Int32)
}

public struct CodexItem: Sendable, Identifiable {
    public let id: String
    /// "userMessage", "agentMessage", "reasoning", "commandExecution", "fileChange", "mcpToolCall", ...
    public let type: String
    public let raw: JSONValue

    public init(_ json: JSONValue) {
        id = json["id"]?.string ?? ""
        type = json["type"]?.string ?? ""
        raw = json
    }

    /// agentMessage / plan text.
    public var text: String? { raw["text"]?.string }
    /// commandExecution command line.
    public var command: String? { raw["command"]?.string }
    /// commandExecution exit code, once completed.
    public var exitCode: Int? { raw["exitCode"]?.int }
    /// "inProgress", "completed", "failed", "declined", ...
    public var status: String? { raw["status"]?.string }
}

public struct CodexApproval: Sendable, Identifiable {
    public enum Kind: Sendable {
        case command
        case fileChange
        /// Extra sandbox permissions (network, filesystem) for the rest of the turn/session.
        case permissions
        /// The agent asks the user questions; answer with `.answers`.
        case userInput
        case mcpElicitation
    }

    /// JSON-RPC request id; pass the approval back to `respond(to:_:)`.
    public let id: JSONValue
    public let kind: Kind
    public let itemId: String?
    public let command: String?
    public let cwd: String?
    public let reason: String?
    /// userInput questions: `{id, header, question, options: [{label, description}] | null}`.
    public let questions: [JSONValue]
    public let params: JSONValue

    init?(id: JSONValue, method: String, params: JSONValue) {
        switch method {
        case "item/commandExecution/requestApproval": kind = .command
        case "item/fileChange/requestApproval": kind = .fileChange
        case "item/permissions/requestApproval": kind = .permissions
        case "item/tool/requestUserInput": kind = .userInput
        case "mcpServer/elicitation/request": kind = .mcpElicitation
        default: return nil
        }
        self.id = id
        itemId = params["itemId"]?.string
        command = params["command"]?.string
        cwd = params["cwd"]?.string
        reason = params["reason"]?.string ?? params["message"]?.string
        questions = params["questions"]?.array ?? []
        self.params = params
    }
}

public enum CodexDecision: Sendable {
    case accept
    /// Accept, and don't ask again for the same thing this session.
    case acceptForSession
    case decline
    /// Decline and stop the turn.
    case cancel
    /// userInput answers, keyed by question id.
    case answers([String: [String]])

    func result(for approval: CodexApproval) -> JSONValue {
        switch approval.kind {
        case .command, .fileChange:
            return ["decision": .string(decisionName)]
        case .permissions:
            // Grant what was asked (dropping nulls), or nothing.
            let requested = approval.params["permissions"]?.object?.filter { $0.value != .null } ?? [:]
            let granted: [String: JSONValue] = isAccept ? requested : [:]
            return ["permissions": .object(granted), "scope": self == .acceptForSession ? "session" : "turn"]
        case .userInput:
            guard case .answers(let answers) = self else { return ["answers": [:]] }
            return ["answers": .object(answers.mapValues { ["answers": .array($0.map(JSONValue.string))] })]
        case .mcpElicitation:
            return ["action": isAccept ? "accept" : (self == .cancel ? "cancel" : "decline"), "content": nil, "_meta": nil]
        }
    }

    private var isAccept: Bool {
        switch self {
        case .accept, .acceptForSession, .answers: true
        case .decline, .cancel: false
        }
    }

    private var decisionName: String {
        switch self {
        case .accept, .answers: "accept"
        case .acceptForSession: "acceptForSession"
        case .decline: "decline"
        case .cancel: "cancel"
        }
    }
}

extension CodexDecision: Equatable {}

public struct CodexTurnResult: Sendable {
    public let turnId: String
    /// "completed", "interrupted", "failed"
    public let status: String
    public let errorMessage: String?
    public let durationMs: Int?
    public let raw: JSONValue

    init(_ params: JSONValue) {
        let turn = params["turn"]
        turnId = turn?["id"]?.string ?? ""
        status = turn?["status"]?.string ?? ""
        errorMessage = turn?["error"]?["message"]?.string.map(CodexError.readable)
        durationMs = turn?["durationMs"]?.int
        raw = params
    }
}

/// Codex error text as a person reads it. Codex passes the API's error body through, alone or
/// after a line of its own ("Error running remote compact task: {"type":"error","status":400,
/// "error":{"message":"The 'x' model is not supported…"}}"): the body's message is the error.
public enum CodexError {
    public static func readable(_ raw: String) -> String {
        guard let brace = raw.firstIndex(of: "{"),
            let json = try? JSONValue.parse(Data(raw[brace...].utf8)),
            let message = (json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        else { return raw }
        return message
    }
}

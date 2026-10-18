import Foundation

/// What the session emits to the UI. Anything not modeled here arrives as `.raw`
/// so nothing the CLI says is silently lost.
public enum ClaudeEvent: Sendable {
    /// `system/init`: first message of every process; carries the session id used for `--resume`.
    case sessionStarted(SessionInfo)
    /// Streaming text from `--include-partial-messages`.
    case textDelta(String, parentToolUseId: String?)
    case thinkingDelta(String, parentToolUseId: String?)
    /// A finalized assistant content block (the CLI sends one message per block).
    /// `usage`: the API call's token counts (how full the context is, as of this message).
    case assistant(messageId: String?, content: [ContentBlock], parentToolUseId: String?, usage: JSONValue?)
    /// User-role messages: tool results, and echoes of slash command output. `toolUseResult` is
    /// the CLI's structured result of the tool (an edit's patch, a sub-agent's totals).
    case user(content: [ContentBlock], parentToolUseId: String?, toolUseResult: JSONValue?)
    /// The CLI is blocked until `ClaudeSession.respond(to:_:)` is called.
    case permissionRequest(PermissionRequest)
    /// A pending permission request was withdrawn (e.g. the turn was interrupted).
    case permissionCancelled(requestId: String)
    /// The CLI switched permission mode on its own, e.g. to "default" after a plan is approved.
    case permissionModeChanged(String)
    /// `command_lifecycle`: the CLI runs a queued command on its own, such as a message from
    /// another Claude session (`PeerMessage`). Stdout doesn't carry its text; `id` is the uuid
    /// of its user entry in the transcript (`ClaudeHistory.entry`). `sessionId` comes with it: in a
    /// chat with nothing sent yet, this arrives before `system/init`.
    case commandStarted(id: String, sessionId: String?)
    case commandCompleted(id: String)
    /// A queued message was dropped (`interrupt {cancel_queued}`).
    case commandCancelled(id: String)
    /// A user message echoed where the CLI took it (`--replay-user-messages`); `uuid` is the one
    /// it was sent with.
    case userEcho(uuid: String?)
    /// End of a turn. The process stays alive for the next `send`.
    case turnCompleted(TurnResult)
    /// The API refused the login (an assistant message with `error: "authentication_failed"`):
    /// the CLI's own line ("Not logged in · Please run /login").
    case authFailed(String)
    case raw(JSONValue)
    case stderr(String)
    /// The process ended; the stream finishes after this.
    case exited(status: Int32)
}

public enum ContentBlock: Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: JSONValue, isError: Bool)
    case other(JSONValue)

    init(_ json: JSONValue) {
        switch json["type"]?.string {
        case "text":
            self = .text(json["text"]?.string ?? "")
        case "thinking":
            self = .thinking(json["thinking"]?.string ?? "")
        case "tool_use":
            self = .toolUse(
                id: json["id"]?.string ?? "",
                name: json["name"]?.string ?? "",
                input: json["input"] ?? .null)
        case "tool_result":
            self = .toolResult(
                toolUseId: json["tool_use_id"]?.string ?? "",
                content: json["content"] ?? .null,
                isError: json["is_error"]?.bool ?? false)
        default:
            self = .other(json)
        }
    }

    static func list(_ content: JSONValue?) -> [ContentBlock] {
        switch content {
        case .string(let s): [.text(s)]
        case .array(let blocks): blocks.map(ContentBlock.init)
        default: []
        }
    }
}

public struct SessionInfo: Sendable {
    public let sessionId: String
    public let model: String?
    public let cwd: String?
    public let permissionMode: String?
    public let tools: [String]
    public let slashCommands: [String]
    public let raw: JSONValue

    init(_ json: JSONValue) {
        sessionId = json["session_id"]?.string ?? ""
        model = json["model"]?.string
        cwd = json["cwd"]?.string
        permissionMode = json["permissionMode"]?.string
        tools = json["tools"]?.array?.compactMap(\.string) ?? []
        slashCommands = json["slash_commands"]?.array?.compactMap(\.string) ?? []
        raw = json
    }
}

public struct PermissionRequest: Sendable, Identifiable {
    /// The control `request_id`; pass the request back to `respond(to:_:)`.
    public let id: String
    public let toolName: String
    public let toolUseId: String?
    public let input: JSONValue
    public let description: String?
    /// Rule updates the CLI proposes for "always allow"; echoed back by `.allowAlways`.
    public let suggestions: [JSONValue]
    public let raw: JSONValue

    /// AskUserQuestion is routed through the permission channel; answer it with `.answers`.
    public var isQuestion: Bool { toolName == "AskUserQuestion" }

    init(id: String, _ request: JSONValue) {
        self.id = id
        toolName = request["tool_name"]?.string ?? ""
        toolUseId = request["tool_use_id"]?.string
        input = request["input"] ?? .object([:])
        description = request["description"]?.string
        suggestions = request["permission_suggestions"]?.array ?? []
        raw = request
    }
}

public enum PermissionDecision: Sendable {
    case allow
    /// Allow and apply the CLI's suggested rules, so it stops asking.
    case allowAlways
    case allowWithInput(JSONValue)
    /// Allow and switch the session's permission mode, e.g. approving a plan with "acceptEdits".
    case allowSettingMode(String)
    /// Answers for AskUserQuestion, keyed by question text.
    case answers([String: String])
    case deny(message: String, interrupt: Bool = false)

    func payload(for request: PermissionRequest) -> JSONValue {
        switch self {
        case .allow:
            ["behavior": "allow", "updatedInput": request.input]
        case .allowAlways:
            ["behavior": "allow", "updatedInput": request.input, "updatedPermissions": .array(request.suggestions)]
        case .allowWithInput(let input):
            ["behavior": "allow", "updatedInput": input]
        case .allowSettingMode(let mode):
            [
                "behavior": "allow", "updatedInput": request.input,
                "updatedPermissions": [["type": "setMode", "mode": .string(mode), "destination": "session"]],
            ]
        case .answers(let answers):
            [
                "behavior": "allow",
                "updatedInput": [
                    "questions": request.input["questions"] ?? [],
                    "answers": .object(answers.mapValues(JSONValue.string)),
                ],
            ]
        case .deny(let message, let interrupt):
            ["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)]
        }
    }
}

public struct TurnResult: Sendable {
    public let subtype: String
    public let isError: Bool
    public let result: String?
    public let sessionId: String?
    public let costUSD: Double?
    public let durationMs: Int?
    public let usage: JSONValue?
    public let raw: JSONValue

    init(_ json: JSONValue) {
        subtype = json["subtype"]?.string ?? ""
        isError = json["is_error"]?.bool ?? false
        result = json["result"]?.string
        sessionId = json["session_id"]?.string
        costUSD = json["total_cost_usd"]?.double
        durationMs = json["duration_ms"]?.int
        usage = json["usage"]
        raw = json
    }
}

extension ClaudeEvent {
    /// Maps one stdout message (not control traffic) to an event. Also takes transcript
    /// entries from `ClaudeHistory.messages`, which share the shape.
    public init(message json: JSONValue) {
        let parent = json["parent_tool_use_id"]?.string
        switch json["type"]?.string {
        case "system" where json["subtype"]?.string == "init":
            self = .sessionStarted(SessionInfo(json))
        case "system" where json["subtype"]?.string == "status" && json["permissionMode"]?.string != nil:
            self = .permissionModeChanged(json["permissionMode"]?.string ?? "")
        case "stream_event":
            let delta = json["event"]?["delta"]
            switch delta?["type"]?.string {
            case "text_delta": self = .textDelta(delta?["text"]?.string ?? "", parentToolUseId: parent)
            case "thinking_delta": self = .thinkingDelta(delta?["thinking"]?.string ?? "", parentToolUseId: parent)
            default: self = .raw(json)
            }
        case "assistant" where json["error"]?.string == "authentication_failed" && parent == nil:
            let said = ContentBlock.list(json["message"]?["content"]).compactMap { block -> String? in
                if case .text(let text) = block { text } else { nil }
            }
            self = .authFailed(said.joined(separator: "\n"))
        case "assistant":
            self = .assistant(
                messageId: json["message"]?["id"]?.string,
                content: ContentBlock.list(json["message"]?["content"]),
                parentToolUseId: parent, usage: json["message"]?["usage"])
        case "user" where json["isReplay"]?.bool == true:
            self = .userEcho(uuid: json["uuid"]?.string)
        case "user":
            self = .user(
                content: ContentBlock.list(json["message"]?["content"]), parentToolUseId: parent,
                // stdout says tool_use_result; transcripts say toolUseResult.
                toolUseResult: json["tool_use_result"] ?? json["toolUseResult"])
        case "result":
            self = .turnCompleted(TurnResult(json))
        case "command_lifecycle" where json["command_uuid"]?.string != nil:
            let id = json["command_uuid"]?.string ?? ""
            switch json["state"]?.string {
            case "started": self = .commandStarted(id: id, sessionId: json["session_id"]?.string)
            case "completed": self = .commandCompleted(id: id)
            case "cancelled": self = .commandCancelled(id: id)
            default: self = .raw(json)
            }
        default:
            self = .raw(json)
        }
    }
}

/// A message from another Claude session (the CLI's cross-session messaging). The CLI turns it
/// into a user turn of its own: the prompt wraps the text in `<cross-session-message>` plus
/// guidance for the model; the transcript entry's `origin` keeps the sender and the plain text.
public struct PeerMessage: Sendable {
    /// The sender's session name (e.g. "Kore-fe"), else its address.
    public let from: String
    public let text: String

    /// A transcript `user` entry whose origin is a peer; nil for anything else.
    public init?(entry: JSONValue) {
        guard let origin = entry["origin"], origin["kind"]?.string == "peer" else { return nil }
        from = origin["name"]?.string ?? origin["from"]?.string ?? "Another session"
        if let body = origin["body"]?.string {
            text = body
        } else {
            // No body: the text between the wrapper tags of the prompt.
            let prompt = entry["message"]?["content"]?.string ?? ""
            guard let open = prompt.range(of: "<cross-session-message"),
                let start = prompt[open.upperBound...].firstIndex(of: ">"),
                let close = prompt.range(of: "</cross-session-message>", range: start..<prompt.endIndex)
            else { return nil }
            text = prompt[prompt.index(after: start)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

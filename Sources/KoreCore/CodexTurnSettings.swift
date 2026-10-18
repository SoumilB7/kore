import Foundation

/// The settings a Codex turn ran with: what `thread/settings/updated` reports live (camelCase)
/// and what the rollout's `turn_context` entries keep for replay (snake_case). `turn/resume`
/// returns turns without them.
public struct CodexTurnSettings: Sendable, Equatable {
    public let permissions: CodexSession.Permissions
    /// The Plan collaboration mode.
    public let plan: Bool

    /// From `thread/settings/updated`'s `threadSettings` or a `turn_context` payload.
    public init?(_ json: JSONValue) {
        let approval = (json["approvalPolicy"] ?? json["approval_policy"])?.string
        let reviewer = (json["approvalsReviewer"] ?? json["approvals_reviewer"])?.string
        let sandbox = (json["sandboxPolicy"] ?? json["sandbox_policy"])?["type"]?.string
        guard let approval, let sandbox else { return nil }
        // Live uses camelCase types ("readOnly"), the rollout kebab-case ("read-only").
        let kind = sandbox.lowercased().replacingOccurrences(of: "-", with: "")
        if approval == "never" || kind == "dangerfullaccess" {
            permissions = .fullAccess
        } else if kind == "readonly" {
            permissions = .readOnly
        } else {
            permissions = reviewer == "auto_review" ? .approveForMe : .askForApproval
        }
        plan = (json["collaborationMode"] ?? json["collaboration_mode"])?["mode"]?.string == "plan"
    }
}

/// What Kore reads from a Codex rollout for replay: each turn's settings and the last token count.
public struct CodexRollout: Sendable {
    public var turnSettings: [String: CodexTurnSettings] = [:]
    /// `last_token_usage.total_tokens` of the last `token_count` event: the context in use.
    public var lastTokens: Int?
    public var contextWindow: Int?

    public init() {}
}

extension CodexHistory {
    /// A rollout's turn settings and last token count. Streams the file and parses only
    /// `turn_context` and `token_count` lines (a rollout can be hundreds of MB).
    public static func rollout(at path: String) -> CodexRollout {
        guard let handle = FileHandle(forReadingAtPath: path) else { return CodexRollout() }
        defer { try? handle.close() }
        let context = Data(#""type":"turn_context""#.utf8)
        let tokens = Data(#""type":"token_count""#.utf8)
        var rollout = CodexRollout()
        var carry = Data()
        while true {
            let more = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                var data = carry + chunk
                guard let last = data.lastIndex(of: 0x0A) else {
                    carry = data
                    return true
                }
                carry = data[(last + 1)...]
                data = data[..<last]
                for line in data.split(separator: 0x0A) {
                    // The type sits near the start of each line; skip the rest without parsing.
                    let head = line.prefix(160)
                    if head.range(of: context) != nil {
                        guard let entry = try? JSONValue.parse(Data(line)), let payload = entry["payload"],
                            let turn = payload["turn_id"]?.string, let parsed = CodexTurnSettings(payload)
                        else { continue }
                        rollout.turnSettings[turn] = parsed
                    } else if head.range(of: tokens) != nil {
                        guard let entry = try? JSONValue.parse(Data(line)), let info = entry["payload"]?["info"] else { continue }
                        rollout.lastTokens = info["last_token_usage"]?["total_tokens"]?.int ?? rollout.lastTokens
                        rollout.contextWindow = info["model_context_window"]?.int ?? rollout.contextWindow
                    }
                }
                return true
            }
            if !more { break }
        }
        return rollout
    }
}

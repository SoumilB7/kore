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

extension CodexHistory {
    /// Each turn's settings from a rollout file, by turn id. Streams the file and parses only
    /// `turn_context` lines (a rollout can be hundreds of MB).
    public static func turnSettings(rollout path: String) -> [String: CodexTurnSettings] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        let marker = Data(#""type":"turn_context""#.utf8)
        var settings: [String: CodexTurnSettings] = [:]
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            var data = carry + chunk
            guard let last = data.lastIndex(of: 0x0A) else {
                carry = data
                continue
            }
            carry = data[(last + 1)...]
            data = data[..<last]
            for line in data.split(separator: 0x0A) {
                // The type sits near the start of each line; skip the rest without parsing.
                guard line.prefix(96).range(of: marker) != nil, let entry = try? JSONValue.parse(Data(line)),
                    let payload = entry["payload"], let turn = payload["turn_id"]?.string,
                    let parsed = CodexTurnSettings(payload)
                else { continue }
                settings[turn] = parsed
            }
        }
        return settings
    }
}

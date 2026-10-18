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

/// Reads a rollout backwards from its end, as far as the turns shown need: they're the newest,
/// and a rollout can be hundreds of MB. Each `read` carries on from where the last one stopped.
public struct CodexRolloutReader: Sendable {
    /// A turn whose settings are wanted, and when it started (where reading back can stop).
    public struct Turn: Sendable {
        public let id: String
        public let start: Date?

        public init(id: String, start: Date?) {
            self.id = id
            self.start = start
        }
    }

    let path: String
    /// Bytes before this aren't read yet (nil: none read).
    private var end: UInt64?
    /// The start of a line cut by the last chunk read.
    private var carry = Data()
    private var settings: [String: CodexTurnSettings] = [:]
    private var tokensRead = false

    public init(path: String) {
        self.path = path
    }

    /// The settings of `turns`, read back until each is found or the lines are older than the
    /// oldest one's start. The first read also takes the last token count.
    public mutating func read(_ turns: [Turn]) -> CodexRollout {
        var rollout = CodexRollout()
        let wantTokens = !tokensRead
        tokensRead = true
        var missing = Set(turns.map(\.id)).subtracting(settings.keys)
        // A turn's context is written as it starts; a minute's slack for clocks and queued turns.
        let oldest = turns.compactMap(\.start).min()
        let cutoff = oldest.map { Data(Self.stamp.string(from: $0.addingTimeInterval(-60)).utf8) }
        var older = false
        var tokensFound = false

        if !(missing.isEmpty && !wantTokens), let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            var end = self.end ?? ((try? handle.seekToEnd()) ?? 0)
            while end > 0 && !(missing.isEmpty && (tokensFound || !wantTokens)) && !older {
                let start = end > Self.chunk ? end - Self.chunk : 0
                autoreleasepool {
                    try? handle.seek(toOffset: start)
                    var data = (try? handle.read(upToCount: Int(end - start))) ?? Data()
                    data.append(carry)
                    if start > 0 {
                        // The chunk's first line may start in the chunk before.
                        guard let first = data.firstIndex(of: 0x0A) else {
                            carry = data
                            return
                        }
                        carry = Data(data[..<first])
                        data = Data(data[(first + 1)...])
                    } else {
                        carry = Data()
                    }
                    for line in data.split(separator: 0x0A).reversed() {
                        // The type and time sit at the start of each line; skip the rest unparsed.
                        let head = line.prefix(160)
                        if let cutoff, let time = Self.time(head), time.lexicographicallyPrecedes(cutoff) { older = true }
                        if head.range(of: Self.context) != nil {
                            guard let entry = try? JSONValue.parse(Data(line)), let payload = entry["payload"],
                                let turn = payload["turn_id"]?.string, settings[turn] == nil, let parsed = CodexTurnSettings(payload)
                            else { continue }
                            settings[turn] = parsed
                            missing.remove(turn)
                        } else if wantTokens, !tokensFound, head.range(of: Self.tokens) != nil {
                            guard let entry = try? JSONValue.parse(Data(line)), let info = entry["payload"]?["info"],
                                let used = info["last_token_usage"]?["total_tokens"]?.int
                            else { continue }
                            rollout.lastTokens = used
                            rollout.contextWindow = info["model_context_window"]?.int
                            tokensFound = true
                        }
                    }
                }
                end = start
            }
            self.end = end
        }
        rollout.turnSettings = settings.filter { id, _ in turns.contains { $0.id == id } }
        return rollout
    }

    private static let chunk: UInt64 = 1 << 20
    private static let context = Data(#""type":"turn_context""#.utf8)
    private static let tokens = Data(#""type":"token_count""#.utf8)
    private static let timestampKey = Data(#"{"timestamp":""#.utf8)

    /// The line's timestamp to the second ("2026-09-25T08:28:45"), which sorts as text.
    private static func time(_ head: Data.SubSequence) -> Data.SubSequence? {
        guard head.starts(with: timestampKey) else { return nil }
        let from = head.startIndex + timestampKey.count
        guard head.endIndex - from >= 19 else { return nil }
        return head[from..<(from + 19)]
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

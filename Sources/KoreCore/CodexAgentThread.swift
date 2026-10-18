import Foundation

/// What Codex keeps about a sub-agent's thread besides its turns: the nickname and role it was
/// given (`thread/read` without turns) and, from the end of its rollout, its last answer, the
/// tokens it used and how long its last turn ran. Its instructions arrive encrypted (multi-agent
/// v2), so they aren't here.
public struct CodexAgentThread: Sendable {
    public var nickname: String?
    public var role: String?
    public var result: String?
    public var tokens: Int?
    public var duration: Duration?
    /// Its rollout, where it was read from, and when that was last written.
    public var path: String?
    public var size: UInt64 = 0
    public var modified: Date?
    /// How its last turn ended: nil while it runs (or the end isn't in the rollout's tail).
    public var lastEnd: End?

    public enum End: Sendable { case completed, aborted }

    public init(nickname: String? = nil, role: String? = nil) {
        self.nickname = nickname
        self.role = role
    }

    /// The last `task_complete` and `token_count` in the rollout's final 64 KB: both come at the
    /// end of a finished turn, so the rest of the file is never read. The last turn's start or
    /// end there says whether it still runs.
    public mutating func readOutcome(rollout path: String) {
        self.path = path
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        self.size = size
        modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd() else { return }
        let complete = Data(#""type":"task_complete""#.utf8)
        let count = Data(#""type":"token_count""#.utf8)
        let started = Data(#""type":"task_started""#.utf8)
        let aborted = Data(#""type":"turn_aborted""#.utf8)
        var sawComplete = false
        var sawLast = false
        lastEnd = nil
        for line in data.split(separator: 0x0A).reversed() where !sawComplete || tokens == nil || !sawLast {
            let head = line.prefix(160)
            if !sawLast {
                if head.range(of: complete) != nil {
                    lastEnd = .completed
                } else if head.range(of: aborted) != nil {
                    lastEnd = .aborted
                }
                sawLast = lastEnd != nil || head.range(of: started) != nil
            }
            if !sawComplete, head.range(of: complete) != nil, let payload = try? JSONValue.parse(Data(line))["payload"] {
                sawComplete = true
                result = payload["last_agent_message"]?.string
                duration = payload["duration_ms"]?.int.map { .milliseconds($0) }
            } else if tokens == nil, head.range(of: count) != nil, let payload = try? JSONValue.parse(Data(line))["payload"] {
                tokens = payload["info"]?["total_token_usage"]?["total_tokens"]?.int
            }
        }
    }

    /// What became of it as of `now`, for one another client runs: running while its last turn
    /// hasn't ended and its rollout was written within `quiet`.
    public func outcome(at now: Date = Date(), quiet: TimeInterval = AgentOutcome.quietLimit) -> AgentOutcome {
        switch lastEnd {
        case .completed?: return .finished
        case .aborted?: return .stopped
        case nil:
            guard let modified, now.timeIntervalSince(modified) <= quiet else { return .stopped }
            return .running
        }
    }
}

extension CodexSession {
    /// Sub-agent threads' nicknames, roles and outcomes so far, looked up together.
    public func agentThreads(_ ids: [String]) async -> [String: CodexAgentThread] {
        await withTaskGroup(of: (String, CodexAgentThread?).self) { group in
            for id in Set(ids) {
                group.addTask {
                    guard let (info, path) = await self.agentThread(id) else { return (id, nil) }
                    var thread = info
                    if let path { thread.readOutcome(rollout: path) }
                    return (id, thread)
                }
            }
            var threads: [String: CodexAgentThread] = [:]
            for await (id, thread) in group { threads[id] = thread }
            return threads
        }
    }

    /// Metadata only: no turns are read.
    private func agentThread(_ id: String) async -> (CodexAgentThread, String?)? {
        guard let thread = try? await threadInfo(id), thread["id"] != nil else { return nil }
        return (CodexAgentThread(nickname: thread["agentNickname"]?.string, role: thread["agentRole"]?.string), thread["path"]?.string)
    }
}

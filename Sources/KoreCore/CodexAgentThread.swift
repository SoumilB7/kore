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

    public init(nickname: String? = nil, role: String? = nil) {
        self.nickname = nickname
        self.role = role
    }

    /// The last `task_complete` and `token_count` in the rollout's final 64 KB: both come at the
    /// end of a finished turn, so the rest of the file is never read.
    public mutating func readOutcome(rollout path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd() else { return }
        let complete = Data(#""type":"task_complete""#.utf8)
        let count = Data(#""type":"token_count""#.utf8)
        var sawComplete = false
        for line in data.split(separator: 0x0A).reversed() where !sawComplete || tokens == nil {
            let head = line.prefix(160)
            if !sawComplete, head.range(of: complete) != nil, let payload = try? JSONValue.parse(Data(line))["payload"] {
                sawComplete = true
                result = payload["last_agent_message"]?.string
                duration = payload["duration_ms"]?.int.map { .milliseconds($0) }
            } else if tokens == nil, head.range(of: count) != nil, let payload = try? JSONValue.parse(Data(line))["payload"] {
                tokens = payload["info"]?["total_token_usage"]?["total_tokens"]?.int
            }
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

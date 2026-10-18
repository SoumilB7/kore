import Foundation

/// A past conversation in a folder, from either CLI's own records.
public struct SessionSummary: Sendable, Identifiable, Hashable {
    public enum Agent: String, Sendable { case claude, codex }

    /// Claude session id or Codex thread id: what `resume` takes.
    public let id: String
    public let agent: Agent
    public let title: String
    public let updated: Date

    public init(id: String, agent: Agent, title: String, updated: Date) {
        self.id = id
        self.agent = agent
        self.title = title
        self.updated = updated
    }
}

/// Claude Code's transcripts: `~/.claude/projects/<folder path, non-alphanumerics → "-">/<session>.jsonl`.
/// Read directly, as the Agent SDK's session helpers do (which t3code uses).
public enum ClaudeHistory {
    public static func sessions(in folder: URL) -> [SessionSummary] {
        let directory = projectDirectory(for: folder)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { file in
            guard let title = title(of: file) else { return nil }
            let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return SessionSummary(
                id: file.deletingPathExtension().lastPathComponent, agent: .claude, title: title,
                updated: updated ?? .distantPast)
        }
    }

    /// The session's user/assistant messages along its current branch, oldest first, in the
    /// same shape as stream-json `user` / `assistant` messages.
    public static func messages(sessionId: String, in folder: URL) -> [JSONValue] {
        let file = projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: file) else { return [] }
        var byId: [String: JSONValue] = [:]
        var leaf: String?
        for line in data.split(separator: 0x0A) {
            guard let entry = try? JSONValue.parse(Data(line)), let uuid = entry["uuid"]?.string else { continue }
            byId[uuid] = entry
            let type = entry["type"]?.string
            if (type == "user" || type == "assistant") && entry["isSidechain"]?.bool != true { leaf = uuid }
        }
        // Walk back from the last message so rewound branches are left out.
        var chain: [JSONValue] = []
        var cursor = leaf
        while let id = cursor, let entry = byId[id] {
            chain.append(entry)
            cursor = entry["parentUuid"]?.string
        }
        return chain.reversed().filter { entry in
            let type = entry["type"]?.string
            return (type == "user" || type == "assistant") && entry["isMeta"]?.bool != true
        }
    }

    static func projectDirectory(for folder: URL) -> URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        // realpath, like the CLI: Foundation's resolvingSymlinksInPath turns /private/tmp into /tmp.
        let path = realpath(folder.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? folder.path
        let name = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return root.appendingPathComponent("projects").appendingPathComponent(name)
    }

    /// Rename > AI title > first prompt. Transcripts can be many MB, so only the head and
    /// tail are read; the CLI re-appends its title entries as the session goes.
    private static func title(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let chunk = 128 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > UInt64(chunk) {
            try? handle.seek(toOffset: size - UInt64(chunk))
            tail = (try? handle.read(upToCount: chunk)) ?? Data()
        }

        var custom: String?, ai: String?, firstPrompt: String?
        for line in (head + tail).split(separator: 0x0A) {
            guard let entry = try? JSONValue.parse(Data(line)) else { continue }
            switch entry["type"]?.string {
            case "custom-title": custom = entry["customTitle"]?.string ?? custom
            case "ai-title": ai = entry["aiTitle"]?.string ?? ai
            case "user" where firstPrompt == nil && entry["isMeta"]?.bool != true && entry["isSidechain"]?.bool != true:
                firstPrompt = promptText(entry["message"]?["content"])
            default: break
            }
        }
        // No prompt means nothing was ever said (e.g. a session opened and closed).
        guard firstPrompt != nil || custom != nil || ai != nil else { return nil }
        return custom ?? ai ?? firstPrompt
    }

    private static func promptText(_ content: JSONValue?) -> String? {
        let text = content?.string ?? content?.array?.first { $0["type"]?.string == "text" }?["text"]?.string
        guard let text, !text.hasPrefix("<") else { return nil }  // command caveats, tool results
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.isEmpty ? nil : line
    }
}

/// Codex threads, from `thread/list` on a short-lived app-server.
public enum CodexHistory {
    public static func threads(in folder: URL, executable: URL? = nil) async throws -> [SessionSummary] {
        let server = try await CodexAppServer.start(cwd: folder, executable: executable)
        defer { Task { await server.close() } }
        let result = try await server.request(
            "thread/list", ["cwd": .string(folder.path), "limit": 100, "sortKey": "updated_at"])
        return (result["data"]?.array ?? []).compactMap { thread in
            guard let id = thread["id"]?.string else { return nil }
            let title = thread["name"]?.string ?? thread["preview"]?.string ?? "Untitled"
            let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
            return SessionSummary(
                id: id, agent: .codex, title: line,
                updated: Date(timeIntervalSince1970: thread["updatedAt"]?.double ?? 0))
        }
    }
}

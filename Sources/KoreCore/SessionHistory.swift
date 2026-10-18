import Foundation

/// A past conversation in a folder, from either CLI's own records.
public struct SessionSummary: Sendable, Identifiable, Hashable {
    public enum Agent: String, Sendable { case claude, codex }

    /// Claude session id or Codex thread id: what `resume` takes.
    public let id: String
    public let agent: Agent
    public let title: String
    public let updated: Date
    /// Archived chats stay on disk but are left out of the folder's tabs.
    public var archived: Bool

    public init(id: String, agent: Agent, title: String, updated: Date, archived: Bool = false) {
        self.id = id
        self.agent = agent
        self.title = title
        self.updated = updated
        self.archived = archived
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
            guard let (title, lastMessage) = summary(of: file) else { return nil }
            // The last message's time: resuming a session appends bookkeeping entries (mode,
            // cost) that bump the file's modification date without any conversation.
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return SessionSummary(
                id: file.deletingPathExtension().lastPathComponent, agent: .claude, title: title,
                updated: lastMessage ?? modified ?? .distantPast)
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
            // Peer messages are meta entries, but part of the conversation.
            return (type == "user" || type == "assistant")
                && (entry["isMeta"]?.bool != true || PeerMessage(entry: entry) != nil)
        }
    }

    /// One transcript entry by uuid, searched from the end (where a just-started command is).
    public static func entry(uuid: String, sessionId: String, in folder: URL) -> JSONValue? {
        let file = projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let chunk: UInt64 = 512 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        let needle = Data(uuid.utf8)
        for line in tail.split(separator: 0x0A).reversed() where line.range(of: needle) != nil {
            if let entry = try? JSONValue.parse(Data(line)), entry["uuid"]?.string == uuid { return entry }
        }
        return nil
    }

    static func projectDirectory(for folder: URL) -> URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        // realpath, like the CLI: Foundation's resolvingSymlinksInPath turns /private/tmp into /tmp.
        let path = realpath(folder.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? folder.path
        let name = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return root.appendingPathComponent("projects").appendingPathComponent(name)
    }

    /// Title (rename > AI title > first prompt) and the last message's time. Transcripts can be
    /// many MB, so only the head and tail are read; the CLI re-appends its title entries as the
    /// session goes.
    private static func summary(of file: URL) -> (title: String, lastMessage: Date?)? {
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

        var custom: String?, ai: String?, firstPrompt: String?, firstPeer: String?, lastMessage: Date?
        for line in (head + tail).split(separator: 0x0A) {
            guard let entry = try? JSONValue.parse(Data(line)) else { continue }
            let type = entry["type"]?.string
            if type == "user" || type == "assistant", let time = entry["timestamp"]?.string.flatMap(parseDate) {
                lastMessage = max(lastMessage ?? time, time)
            }
            switch type {
            case "custom-title": custom = entry["customTitle"]?.string ?? custom
            case "ai-title": ai = entry["aiTitle"]?.string ?? ai
            case "user" where entry["isSidechain"]?.bool != true:
                // A peer's message never titles the chat, unless it's all there is.
                if let peer = PeerMessage(entry: entry) {
                    firstPeer = firstPeer ?? "Message from \(peer.from)"
                } else if firstPrompt == nil && entry["isMeta"]?.bool != true {
                    firstPrompt = promptText(entry["message"]?["content"])
                }
            default: break
            }
        }
        // No prompt means nothing was ever said (e.g. a session opened and closed).
        guard let title = custom ?? ai ?? firstPrompt ?? firstPeer else { return nil }
        return (title, lastMessage)
    }

    private static func parseDate(_ string: String) -> Date? {
        (try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }

    private static func promptText(_ content: JSONValue?) -> String? {
        let text = content?.string ?? content?.array?.first { $0["type"]?.string == "text" }?["text"]?.string
        guard let text, !text.hasPrefix("<") else { return nil }  // command caveats, tool results
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.isEmpty ? nil : line
    }
}

/// Codex threads, from `thread/list` on a short-lived app-server. Archiving is Codex's own
/// (`thread/archive` moves the rollout to `archived_sessions`), shared with its other clients.
public enum CodexHistory {
    /// The folder's threads, archived ones included (flagged). Interactive sources only, as the
    /// Codex clients list them (no `exec` runs or subagents).
    public static func threads(in folder: URL, executable: URL? = nil) async throws -> [SessionSummary] {
        let server = try await CodexAppServer.start(cwd: folder, executable: executable)
        defer { Task { await server.close() } }
        var threads: [SessionSummary] = []
        for archived in [false, true] {
            var cursor: JSONValue = .null
            repeat {
                let result = try await server.request("thread/list", [
                    "cwd": .string(folder.path), "archived": .bool(archived), "limit": 100,
                    "sortKey": "updated_at", "cursor": cursor,
                ])
                threads += (result["data"]?.array ?? []).compactMap { summary($0, archived: archived) }
                cursor = result["nextCursor"]?.string.map(JSONValue.string) ?? .null
            } while cursor != .null && threads.count < 1000
        }
        return threads
    }

    public static func archive(_ id: String, in folder: URL, executable: URL? = nil) async throws {
        try await call("thread/archive", id, in: folder, executable: executable)
    }

    public static func unarchive(_ id: String, in folder: URL, executable: URL? = nil) async throws {
        try await call("thread/unarchive", id, in: folder, executable: executable)
    }

    private static func call(_ method: String, _ id: String, in folder: URL, executable: URL?) async throws {
        let server = try await CodexAppServer.start(cwd: folder, executable: executable)
        defer { Task { await server.close() } }
        _ = try await server.request(method, ["threadId": .string(id)])
    }

    private static func summary(_ thread: JSONValue, archived: Bool) -> SessionSummary? {
        guard let id = thread["id"]?.string else { return nil }
        let title = thread["name"]?.string ?? thread["preview"]?.string ?? "Untitled"
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
        return SessionSummary(
            id: id, agent: .codex, title: line,
            updated: Date(timeIntervalSince1970: thread["updatedAt"]?.double ?? 0), archived: archived)
    }
}

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
    ///
    /// The branch is the `parentUuid` walk back from the last message, which leaves out rewound
    /// branches. Parallel tool calls fork that chain: each call is its own entry (blocks of one
    /// assistant message), and results that come back out of order hang off different calls, so
    /// the walk misses some. Those are added back: entries of the same assistant messages, then
    /// the results of every included tool call, all in file order.
    public static func messages(sessionId: String, in folder: URL) -> [JSONValue] {
        let file = projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: file) else { return [] }
        var byId: [String: JSONValue] = [:]
        var order: [String] = []
        var leaf: String?
        // Only entries with a uuid (user, assistant, attachment, system) can be on the branch. The
        // rest, such as api-request bodies (a third of a long session's bytes), are skipped
        // unparsed: a line without this key can't have it at the top level. Only the key is
        // matched, so JSON written with spaces after its colons is read too.
        let uuidKey = Data("\"uuid\"".utf8)
        for line in data.jsonLines() where line.range(of: uuidKey) != nil {
            guard let entry = try? JSONValue.parse(line), let uuid = entry["uuid"]?.string else { continue }
            byId[uuid] = entry
            let type = entry["type"]?.string
            guard (type == "user" || type == "assistant") && entry["isSidechain"]?.bool != true else { continue }
            order.append(uuid)
            leaf = uuid
        }
        var included: Set<String> = []
        var cursor = leaf
        while let id = cursor, let entry = byId[id], included.insert(id).inserted {
            cursor = entry["parentUuid"]?.string
        }
        func blocks(_ entry: JSONValue) -> [JSONValue] { entry["message"]?["content"]?.array ?? [] }
        let messageIds = Set(included.compactMap { byId[$0]?["type"]?.string == "assistant" ? byId[$0]?["message"]?["id"]?.string : nil })
        for id in order where byId[id]?["type"]?.string == "assistant" {
            if let message = byId[id]?["message"]?["id"]?.string, messageIds.contains(message) { included.insert(id) }
        }
        let toolIds = Set(included.flatMap { id in
            byId[id]?["type"]?.string == "assistant" ? blocks(byId[id]!).compactMap { $0["type"]?.string == "tool_use" ? $0["id"]?.string : nil } : []
        })
        for id in order where byId[id]?["type"]?.string == "user" {
            if blocks(byId[id]!).contains(where: { toolIds.contains($0["tool_use_id"]?.string ?? "") }) { included.insert(id) }
        }
        return order.filter(included.contains).compactMap { byId[$0] }.filter { entry in
            // Peer messages, cron firings and finished-agent notices are meta entries, but they
            // start turns of the conversation.
            entry["isMeta"]?.bool != true || PeerMessage(entry: entry) != nil
                || cliTurnOrigins.contains(entry["turnOrigin"]?.string ?? "")
        }
    }

    /// `turnOrigin` values of turns the CLI starts by itself ("sdk" is a typed prompt).
    public static let cliTurnOrigins: Set<String> = ["scheduled", "task_notification", "peer"]

    /// The newest entry that started a turn the CLI began itself (a cron firing, a finished
    /// agent, a peer's message), searched from the end like `entry(uuid:)`.
    public static func latestCLITurn(sessionId: String, in folder: URL) -> JSONValue? {
        let file = projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let chunk: UInt64 = 512 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        let needle = Data("\"turnOrigin\"".utf8)
        for line in tail.jsonLines().reversed() where line.range(of: needle) != nil {
            guard let entry = try? JSONValue.parse(line), entry["type"]?.string == "user" else { continue }
            if cliTurnOrigins.contains(entry["turnOrigin"]?.string ?? "") { return entry }
        }
        return nil
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
        for line in tail.jsonLines().reversed() where line.range(of: needle) != nil {
            if let entry = try? JSONValue.parse(line), entry["uuid"]?.string == uuid { return entry }
        }
        return nil
    }

    /// A sub-agent's transcript, `<session>/subagents/agent-<id>.jsonl`, found by the Agent call
    /// that spawned it (its `.meta.json` names the `toolUseId`). Written live while it runs.
    public static func subagentFile(toolUseId: String, sessionId: String, in folder: URL) -> URL? {
        let directory = projectDirectory(for: folder).appendingPathComponent(sessionId).appendingPathComponent("subagents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where name.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                let meta = try? JSONValue.parse(data), meta["toolUseId"]?.string == toolUseId
            else { continue }
            return directory.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
        }
        return nil
    }

    /// The user / assistant entries of a JSONL transcript from byte `offset`, and the offset to
    /// read from next. Only whole lines are read, so a file still being written can be tailed.
    public static func entries(in file: URL, from offset: UInt64 = 0) -> (entries: [JSONValue], next: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let end = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let whole = data[data.startIndex...end]
        let entries = whole.jsonLines().compactMap { try? JSONValue.parse($0) }.filter {
            let type = $0["type"]?.string
            return type == "user" || type == "assistant"
        }
        return (entries, offset + UInt64(whole.count))
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
        for line in (head + tail).jsonLines() {
            guard let entry = try? JSONValue.parse(line) else { continue }
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

extension Data {
    /// The non-empty lines, found with `memchr` (Foundation's `split` is several times slower on
    /// a large transcript). The lines share this data's storage.
    func jsonLines() -> [Data] {
        var ranges: [Range<Int>] = []
        withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let end = memchr(base + start, 0x0A, bytes.count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                if end > start { ranges.append(start..<end) }
                start = end + 1
            }
        }
        return ranges.map { self[(startIndex + $0.lowerBound)..<(startIndex + $0.upperBound)] }
    }
}


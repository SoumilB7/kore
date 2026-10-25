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
    /// Its history file, when the listing says (Claude's transcript, Codex's rollout).
    public var file: URL?

    public init(id: String, agent: Agent, title: String, updated: Date, archived: Bool = false, file: URL? = nil) {
        self.id = id
        self.agent = agent
        self.title = title
        self.updated = updated
        self.archived = archived
        self.file = file
    }
}

/// Claude Code's transcripts: `~/.claude/projects/<folder path, non-alphanumerics → "-">/<session>.jsonl`.
/// Read directly, as the Agent SDK's session helpers do (which t3code uses).
/// What became of a sub-agent another client runs, as its own files say.
public enum AgentOutcome: Sendable, Equatable {
    case running, finished, stopped

    /// One whose files have had nothing new for this long has stopped: one call can run ten
    /// minutes without a line (the Bash tool's longest timeout), and its answer a few more. Of
    /// some 218,000 gaps between lines in agents' runs, 0.04% were longer (a machine asleep,
    /// mostly).
    public static let quietLimit: TimeInterval = 15 * 60
}

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
                updated: lastMessage ?? modified ?? .distantPast, file: file)
        }
    }

    /// A session's title as the history lists it (its custom or generated title, else its first
    /// prompt); nil when it has none. Reads the transcript's first and last 128 KB.
    public static func title(sessionId: String, in folder: URL) -> String? {
        summary(of: transcript(sessionId: sessionId, in: folder))?.title
    }

    /// The session's user/assistant messages along its current branch, oldest first, in the
    /// same shape as stream-json `user` / `assistant` messages, back to its last compaction.
    public static func messages(sessionId: String, in folder: URL) -> [JSONValue] {
        page(sessionId: sessionId, in: folder).messages
    }

    /// Part of a session's history, oldest first: user / assistant entries, plus a
    /// `system/compact_boundary` entry where the conversation was compacted.
    public struct Page: Sendable {
        public let messages: [JSONValue]
        /// Where earlier history continues (pass it as `before`), or nil at the session's start.
        public let earlier: String?

        public init(messages: [JSONValue], earlier: String?) {
            self.messages = messages
            self.earlier = earlier
        }
    }

    /// The current branch back to its last compaction (`before` nil), or `userTurns` user turns
    /// ending at `before`, crossing compactions.
    ///
    /// The branch is the `parentUuid` walk back from the last message, which leaves out rewound
    /// branches. A compaction ends that walk: its boundary has no parent, only a
    /// `logicalParentUuid` naming the entry before it, where earlier history goes on.
    /// Parallel tool calls fork the chain: each call is its own entry (blocks of one assistant
    /// message), and results that come back out of order hang off different calls, so the walk
    /// misses some. Those are added back: entries of the same assistant messages, then the
    /// results of every included tool call, all in file order.
    public static func page(sessionId: String, in folder: URL, before: String? = nil, userTurns: Int? = nil) -> Page {
        ClaudeTranscript(sessionId: sessionId, in: folder).page(before: before, userTurns: userTurns)
    }

    /// The page algorithm over an index of links (`ClaudeTranscript`); `load` reads the chosen
    /// entries' lines.
    static func page(_ links: Links, before: String?, userTurns: Int?, load: ([String]) -> [String: Data]) -> Page {
        let found = walk(links, before: before, userTurns: userTurns)
        return messages(found.ids, earlier: found.earlier, load: load)
    }

    /// The entries a page holds, in file order, before their lines are read.
    struct Walk: Equatable {
        var ids: [String]
        var earlier: String?
        /// The walk back from the leaf reached an entry with no parent (a compaction's boundary,
        /// or the session's first entry), not one whose parent isn't indexed.
        var reachedRoot: Bool
        /// That entry is a compaction's boundary.
        var rootIsBoundary: Bool
    }

    static func walk(_ links: Links, before: String?, userTurns: Int?) -> Walk {
        /// Where history goes on before a compaction: its logical parent, or, when that entry
        /// isn't in the file (the compaction kept it under a new id), the last message before
        /// the boundary.
        func continuation(of node: Links.Node) -> Int32? {
            if let logical = node.logical, links[logical] != nil { return logical }
            guard let at = node.position else { return nil }
            return links.order[..<Int(at)].last { links[$0]?.kind != .system }
        }
        var included: Set<Int32> = []
        var earlier: Int32?
        var prompts = 0
        var cursor = before.map { links.id(of: $0) } ?? links.leaf
        var reachedRoot = false
        var rootIsBoundary = false
        while let id = cursor, let node = links[id], included.insert(id).inserted {
            if let limit = userTurns, node.isPrompt {
                prompts += 1
                if prompts == limit {
                    earlier = node.parent
                    break
                }
            }
            if let parent = node.parent {
                cursor = parent
            } else {
                // A compaction: the current branch stops here; a page of earlier turns goes on.
                reachedRoot = true
                rootIsBoundary = node.isBoundary
                let logical = node.isBoundary ? continuation(of: node) : nil
                if userTurns == nil {
                    earlier = logical
                    break
                }
                cursor = logical
            }
        }
        let span = included.compactMap { links[$0]?.position }
        guard let first = span.min(), let last = span.max() else {
            return Walk(ids: [], earlier: nil, reachedRoot: reachedRoot, rootIsBoundary: rootIsBoundary)
        }
        let window = links.order[Int(first)...Int(last)]
        let messageIds = Set(included.compactMap { links[$0].flatMap { $0.kind == .assistant ? $0.message : nil } })
        for id in window {
            if let node = links[id], node.kind == .assistant, let message = node.message, messageIds.contains(message) {
                included.insert(id)
            }
        }
        let toolIds = Set(included.flatMap { id in links[id].map { $0.kind == .assistant ? links.toolUses($0) : [] } ?? [] })
        for id in window {
            if let node = links[id], node.kind == .user, links.toolResults(node).contains(where: toolIds.contains) { included.insert(id) }
        }
        // Queued messages taken mid-turn, hanging off an entry of the page.
        for id in window {
            if let node = links[id], node.isQueuedCommand, let parent = node.parent, included.contains(parent) { included.insert(id) }
        }
        return Walk(
            ids: window.filter(included.contains).map(links.key), earlier: earlier.map(links.key), reachedRoot: reachedRoot,
            rootIsBoundary: rootIsBoundary)
    }

    /// A walk's entries read and parsed: the conversation's, without other meta entries.
    static func messages(_ ids: [String], earlier: String?, load: ([String]) -> [String: Data]) -> Page {
        let lines = load(ids)
        let messages = parseAll(ids.compactMap { lines[$0] }).compactMap { $0 }.filter { entry in
            // Peer messages, cron firings and finished-agent notices are meta entries, but they
            // start turns of the conversation.
            isBoundary(entry) || entry["isMeta"]?.bool != true || PeerMessage(entry: entry) != nil
                || cliTurnOrigins.contains(entry["turnOrigin"]?.string ?? "")
        }
        return Page(messages: messages, earlier: earlier)
    }

    /// Lines parsed in order, nil for one that isn't JSON; a long page's on every core (a page
    /// back to a compaction can be thousands of entries and many MB).
    static func parseAll(_ lines: [Data]) -> [JSONValue?] {
        guard lines.count > 64 else { return lines.map { try? JSONValue.parse($0) } }
        let parsed = Parsed(count: lines.count)
        let slices = min(lines.count, ProcessInfo.processInfo.activeProcessorCount * 4)
        DispatchQueue.concurrentPerform(iterations: slices) { slice in
            var i = slice
            while i < lines.count {
                parsed.set(i, try? JSONValue.parse(lines[i]))
                i += slices
            }
        }
        return parsed.values
    }

    /// Slots written by index from several threads, each slot by one.
    private final class Parsed: @unchecked Sendable {
        private let slots: UnsafeMutableBufferPointer<JSONValue?>

        init(count: Int) {
            slots = .allocate(capacity: count)
            slots.initialize(repeating: nil)
        }

        deinit {
            slots.deinitialize()
            slots.deallocate()
        }

        func set(_ index: Int, _ value: JSONValue?) { slots[index] = value }
        var values: [JSONValue?] { Array(slots) }
    }

    /// A compaction's boundary: earlier history goes on from its `logicalParentUuid`.
    public static func isBoundary(_ entry: JSONValue) -> Bool {
        entry["type"]?.string == "system" && entry["subtype"]?.string == "compact_boundary"
    }

    /// What `page` reads of every entry: how it links to others, and nothing of its text or
    /// tool output (the decoder skips what isn't named here).
    struct Link: Decodable {
        let uuid: String
        let parentUuid: String?
        let logicalParentUuid: String?
        let type: String?
        let isBoundary: Bool
        let isSidechain: Bool?
        /// Something the user typed (or sent as files): it starts a turn. Tool results and
        /// command output (`<…>`) are user entries too, but not prompts.
        let isPrompt: Bool
        /// The assistant message an entry is a block of.
        let messageId: String?
        let toolUses: [String]
        let toolResults: [String]
        /// A message sent while a turn ran, taken at a tool boundary (`attachment.type
        /// "queued_command"`): kept in pages, where it was taken.
        let isQueuedCommand: Bool

        private enum Keys: String, CodingKey { case uuid, parentUuid, logicalParentUuid, type, subtype, isSidechain, isMeta, message, attachment }
        private enum AttachmentKeys: String, CodingKey { case type }
        private enum MessageKeys: String, CodingKey { case id, content }
        private struct Block: Decodable {
            let type: String?
            let id: String?
            let tool_use_id: String?
        }
        private struct TextBlock: Decodable { let text: String? }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            parentUuid = try? c.decodeIfPresent(String.self, forKey: .parentUuid)
            logicalParentUuid = try? c.decodeIfPresent(String.self, forKey: .logicalParentUuid)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            isBoundary = type == "system" && (try? c.decodeIfPresent(String.self, forKey: .subtype)) == "compact_boundary"
            isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
            let message = try? c.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
            messageId = try? message?.decodeIfPresent(String.self, forKey: .id)
            let text = try? message?.decodeIfPresent(String.self, forKey: .content)
            let blocks = text == nil ? (try? message?.decodeIfPresent([Block].self, forKey: .content)) ?? [] : []
            toolUses = blocks.compactMap { $0.type == "tool_use" ? $0.id : nil }
            toolResults = blocks.compactMap(\.tool_use_id)
            let attachment = try? c.nestedContainer(keyedBy: AttachmentKeys.self, forKey: .attachment)
            isQueuedCommand = type == "attachment" && (try? attachment?.decodeIfPresent(String.self, forKey: .type)) == "queued_command"
            let meta = (try? c.decodeIfPresent(Bool.self, forKey: .isMeta)) == true
            // A stopped turn's marker is a user entry the user didn't write.
            let texts =
                type != "user" ? []
                : text.map { [$0] } ?? ((try? message?.decodeIfPresent([TextBlock].self, forKey: .content)) ?? []).compactMap(\.text)
            let stopMarker = texts.count == 1 && ClaudeHistory.stopMarkers.contains(texts[0])
            isPrompt =
                type == "user" && !meta && !stopMarker
                && (text.map { !$0.hasPrefix("<") }
                    ?? (!blocks.contains { $0.type == "tool_result" }
                        && blocks.contains { ["text", "image", "document"].contains($0.type ?? "") }))
        }
    }

    /// What the CLI writes into a transcript, as a user message, when a turn is stopped.
    public static let stopMarkers: Set<String> = ["[Request interrupted by user]", "[Request interrupted by user for tool use]"]

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

    /// A sub-agent's transcript and what its meta file says: newer CLIs mark it `finished` when
    /// it ends, and `stoppedByUser` when stopped. `interrupted`: its last line is a stop marker
    /// (its parent's turn was stopped, which no meta file says). `modified`: when it last wrote
    /// anything.
    public struct Subagent: Sendable, Equatable {
        public let transcript: URL
        public let finished: Bool
        public let stoppedByUser: Bool
        public let interrupted: Bool
        public let modified: Date?

        public init(transcript: URL, finished: Bool, stoppedByUser: Bool, interrupted: Bool = false, modified: Date?) {
            self.transcript = transcript
            self.finished = finished
            self.stoppedByUser = stoppedByUser
            self.interrupted = interrupted
            self.modified = modified
        }

        /// What became of it as of `now`: running while it isn't marked finished or stopped and
        /// its transcript was written within `quiet` (a call can run minutes without a line).
        public func outcome(at now: Date = Date(), quiet: TimeInterval = AgentOutcome.quietLimit) -> AgentOutcome {
            if stoppedByUser { return .stopped }
            if finished { return .finished }
            if interrupted { return .stopped }
            guard let modified, now.timeIntervalSince(modified) <= quiet else { return .stopped }
            return .running
        }

        /// Read again: one small file, two stats and the transcript's last line.
        public static func read(_ transcript: URL) -> Subagent {
            let meta = transcript.deletingPathExtension().appendingPathExtension("meta.json")
            let json = (try? Data(contentsOf: meta)).flatMap { try? JSONValue.parse($0) }
            let modified = [transcript, meta].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }.max()
            return Subagent(
                transcript: transcript, finished: json?["finished"]?.bool == true,
                stoppedByUser: json?["stoppedByUser"]?.bool == true, interrupted: endsStopped(transcript),
                modified: modified)
        }

        /// When it began and when it last wrote: its transcript's first and last timestamps. One
        /// its files say ended had no notification to bring its time; this is the same time (the
        /// notification's `duration_ms` is the span between them).
        public struct Span: Sendable, Equatable {
            public let start: Date
            public let end: Date
            /// Its last model call's input, cache and output tokens: what its notification's
            /// `total_tokens` counts (within 1% for half of 240 real agents, 3% for most).
            public let tokens: Int?
        }

        /// Reads the first line and the file's last 64 KB (1 MB when those hold no time or no
        /// model call).
        public static func span(_ transcript: URL) -> Span? {
            guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
            defer { try? handle.close() }
            // The first line holds the prompt, which can run long.
            var head = Data()
            while head.firstIndex(of: 0x0A) == nil, head.count < 4 << 20,
                let more = try? handle.read(upToCount: 64 << 10), !more.isEmpty
            {
                head += more
            }
            guard let start = head.jsonLines().first.flatMap({ try? JSONValue.parse($0) }).flatMap(timestamp) else { return nil }
            let size = (try? handle.seekToEnd()) ?? 0
            var end: Date?
            var tokens: Int?
            // The last 64 KB nearly always hold a whole line with a time and the last model call;
            // a long tool result at the end takes up to 1 MB.
            for tail: UInt64 in [64 << 10, 1 << 20] {
                let from = size > tail ? size - tail : 0
                try? handle.seek(toOffset: from)
                // The read cuts the first line it gets; the last whole lines end it.
                let lines = ((try? handle.readToEnd()) ?? Data()).jsonLines().dropFirst(from > 0 ? 1 : 0)
                for line in lines.reversed() where end == nil || tokens == nil {
                    // Only a line that can hold usage is parsed for it alone.
                    guard end == nil || line.range(of: usageKey) != nil, let json = try? JSONValue.parse(line) else { continue }
                    end = end ?? timestamp(json)
                    tokens = tokens ?? usage(json)
                }
                if (end != nil && tokens != nil) || from == 0 { break }
            }
            guard let end else { return nil }
            return Span(start: start, end: max(start, end), tokens: tokens)
        }

        private static let usageKey = Data(#""usage""#.utf8)

        private static func timestamp(_ json: JSONValue) -> Date? {
            json["timestamp"]?.string.flatMap { Timestamp.parse($0) ?? iso.date(from: $0) }
        }

        /// An assistant entry's input, cache and output tokens.
        private static func usage(_ json: JSONValue) -> Int? {
            guard json["type"]?.string == "assistant", let usage = json["message"]?["usage"] else { return nil }
            let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .compactMap { usage[$0]?.int }.reduce(0, +)
            return total > 0 ? total : nil
        }

        /// ISO8601DateFormatter is thread-safe once configured.
        nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        /// Whether the last whole line is a stop marker: only the file's last 4 KB are read.
        static func endsStopped(_ file: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
            guard let data = try? handle.readToEnd(), let line = data.split(separator: 0x0A).last,
                let entry = try? JSONValue.parse(Data(line)), entry["type"]?.string == "user"
            else { return false }
            let content = entry["message"]?["content"]
            let texts = content?.string.map { [$0] } ?? (content?.array ?? []).compactMap { $0["text"]?.string }
            return texts.count == 1 && stopMarkers.contains(texts[0])
        }
    }

    /// The sub-agents of these Agent calls (tool_use ids), with the CLI's agent ids where known.
    /// The session's own first; then other sessions' of the project, where a forked history's
    /// agents ran (a fork copies the calls, not the agents' files): by agent id, else by meta.
    public static func subagents(toolUseIds: Set<String>, agentIds: [String: String], sessionId: String, in folder: URL)
        -> [String: Subagent]
    {
        let project = projectDirectory(for: folder)
        let manager = FileManager.default
        var found: [String: URL] = [:]
        var missing = toolUseIds
        func scan(_ directory: URL) {
            guard !missing.isEmpty, let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".meta.json") {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                    let tool = (try? JSONValue.parse(data))?["toolUseId"]?.string, missing.remove(tool) != nil
                else { continue }
                found[tool] = directory.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
                if missing.isEmpty { return }
            }
        }
        scan(project.appendingPathComponent(sessionId).appendingPathComponent("subagents"))
        if !missing.isEmpty {
            let others = ((try? manager.contentsOfDirectory(atPath: project.path)) ?? [])
                .filter { $0 != sessionId && !$0.hasSuffix(".jsonl") }
                .map { project.appendingPathComponent($0).appendingPathComponent("subagents") }
                .filter { manager.fileExists(atPath: $0.path) }
            for tool in missing {
                guard let agent = agentIds[tool] else { continue }
                let name = "agent-\(agent).jsonl"
                if let directory = others.first(where: { manager.fileExists(atPath: $0.appendingPathComponent(name).path) }) {
                    found[tool] = directory.appendingPathComponent(name)
                    missing.remove(tool)
                }
            }
            for directory in others where !missing.isEmpty { scan(directory) }
        }
        return found.mapValues(Subagent.read)
    }

    /// The `<task-notification>` texts in whole lines written to a transcript since `offset`, in
    /// whichever entry carries them (a queued prompt, an attachment, a turn's prompt), and the
    /// offset to read from next.
    public static func taskNotifications(in file: URL, from offset: UInt64) -> (texts: [String], next: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let end = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let whole = data[data.startIndex...end]
        let needle = Data("<task-notification>".utf8)
        let texts = whole.jsonLines().filter { $0.range(of: needle) != nil }.compactMap { line in
            (try? JSONValue.parse(line)).flatMap(notificationText)
        }
        return (texts, offset + UInt64(whole.count))
    }

    /// A task notification's text, from whichever entry carries it.
    public static func notificationText(_ entry: JSONValue) -> String? {
        let text = entry["content"]?.string ?? entry["message"]?["content"]?.string ?? entry["attachment"]?["prompt"]?.string
        return text.flatMap { $0.hasPrefix("<task-notification>") ? $0 : nil }
    }

    /// The size of a file, for reading only what's written to it from now on.
    public static func size(of file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// A session's own transcript.
    public static func transcript(sessionId: String, in folder: URL) -> URL {
        projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
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

    /// `~/.claude/projects` (or under `CLAUDE_CONFIG_DIR`): every folder's transcripts.
    public static var projectsDirectory: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("projects")
    }

    static func projectDirectory(for folder: URL) -> URL {
        projectsDirectory.appendingPathComponent(projectKey(for: folder))
    }

    /// The folder as the CLI names it in its paths: every character but ASCII letters and digits
    /// made "-".
    public static func projectKey(for folder: URL) -> String {
        // realpath, like the CLI: Foundation's resolvingSymlinksInPath turns /private/tmp into /tmp.
        let path = realpath(folder.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? folder.path
        return String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Where the CLI writes a background task's output (a shell's or a Monitor's) when it doesn't
    /// say: `claude-<uid>/<project key>/<session>/tasks/<task id>.output` in its temp folder. Its
    /// Bash result and the task's notification name it.
    public static func taskOutput(task: String, sessionId: String, in folder: URL) -> URL {
        URL(fileURLWithPath: "/private/tmp/claude-\(getuid())/\(projectKey(for: folder))/\(sessionId)/tasks/\(task).output")
    }

    /// A transcript's title as the history list shows it: the newest rename, else the newest AI
    /// title, else the first prompt's first line.
    public static func title(of file: URL) -> String? { summary(of: file)?.title }

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
        // Codex's list leaves out some threads Kore made here (an import's, injected before its
        // first turn), though each still opens: those Kore started, read one by one.
        let listed = Set(threads.map(\.id))
        for id in KoreSessions.shared.ids(cli: "codex", folder: folder).filter({ !listed.contains($0) }).prefix(Self.unlistedReads) {
            guard let thread = try? await server.request("thread/read", ["threadId": .string(id), "includeTurns": false])["thread"],
                thread["cwd"]?.string == folder.path, let found = summary(thread, archived: false)
            else { continue }
            threads.append(found)
        }
        return threads
    }

    /// At most this many of Kore's own threads missing from Codex's list are read for history.
    static let unlistedReads = 30

    /// A thread's rollout file (`thread/read`), to read its history from directly.
    public static func rolloutPath(_ id: String, in folder: URL, executable: URL? = nil) async throws -> URL? {
        let server = try await CodexAppServer.start(cwd: folder, executable: executable)
        defer { Task { await server.close() } }
        let thread = try await server.request("thread/read", ["threadId": .string(id), "includeTurns": false])["thread"]
        return thread?["path"]?.string.map { URL(fileURLWithPath: $0) }
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
            updated: Date(timeIntervalSince1970: thread["updatedAt"]?.double ?? 0), archived: archived,
            file: thread["path"]?.string.map { URL(fileURLWithPath: $0) })
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

    /// The lines that contain `needle`, found with `memchr` and `memmem` (several times faster
    /// than `range(of:)` across a long transcript).
    func jsonLines(containing needle: String) -> [Data] {
        var ranges: [Range<Int>] = []
        let pattern = Array(needle.utf8)
        withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let end = memchr(base + start, 0x0A, bytes.count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                if end > start, memmem(base + start, end - start, pattern, pattern.count) != nil { ranges.append(start..<end) }
                start = end + 1
            }
        }
        return ranges.map { self[(startIndex + $0.lowerBound)..<(startIndex + $0.upperBound)] }
    }
}


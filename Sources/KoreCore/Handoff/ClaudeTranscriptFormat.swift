import Foundation

/// Claude Code's transcripts (`~/.claude/projects/<folder>/<session>.jsonl`, or a copy from
/// anywhere) into the neutral form. It reads the page `ClaudeTranscript` gives (the active
/// branch back to the last compaction, its boundary and summary first, harness-only meta
/// entries already left out), so the branch walk and the parallel-call repairs are the history
/// view's own.
///
/// Turns start at the user's prompts. Assistant blocks are taken in order: text (the last one
/// is the reply), tool calls (steps, finished by their `tool_result`). Dropped: thinking,
/// `fallback` blocks, `<synthetic>` replies (slash-command output), `<command-name>` /
/// `<local-command-*>` / `<task-notification>` entries. An API error ends its turn failed; a
/// stop marker, interrupted.
public struct ClaudeTranscriptFormat: HandoffFormat {
    public let id = "claude"
    public let product = "Claude Code"
    public var store: URL { ClaudeHistory.projectsDirectory }

    public init() {}

    /// Its lines are objects with a `type`, and among them a conversation entry with the
    /// transcript's own keys: `uuid`, `parentUuid` (null for the first), `sessionId`, `message`.
    public func identify(_ head: HandoffHead) -> HandoffIdentity? {
        guard head.allObjects, head.lines.allSatisfy({ $0?["type"]?.string != nil && $0?["payload"] == nil }) else { return nil }
        let entry = head.lines.lazy.compactMap { $0 }.first { line in
            ["user", "assistant"].contains(line["type"]?.string ?? "") && line["uuid"]?.string != nil
                && line["sessionId"]?.string != nil && line["message"]?.object != nil && line.object?.keys.contains("parentUuid") == true
        }
        guard let entry, let session = entry["sessionId"]?.string else { return nil }
        let title = head.lines.lazy.compactMap { $0 }.compactMap { $0["customTitle"]?.string ?? $0["aiTitle"]?.string }.last
        return HandoffIdentity(format: id, product: product, file: head.file, sessionId: session, cwd: entry["cwd"]?.string, title: title)
    }

    /// The page back to the last compaction, read from the file's end for a long transcript
    /// (`ClaudeTranscript.latest`); the window isn't needed to stop it.
    public func read(_ file: URL, identity: HandoffIdentity, window: Int?) throws -> HandoffSegment {
        let transcript = ClaudeTranscript(file: file)
        let page = transcript.latest()?.page ?? transcript.page()
        guard transcript.malformed == 0 else {
            throw HandoffReadError(transcript.malformed == 1 ? "A line isn't valid JSON" : "\(transcript.malformed) lines aren't valid JSON")
        }
        // Rows Kore wrote into a session it made by an earlier import are that import's, not this
        // agent's own history.
        let written = Set(HandoffRecords.record(target: identity.sessionId)?.written ?? [])
        let folder = URL(fileURLWithPath: identity.cwd ?? file.deletingLastPathComponent().path)
        var segment = Self.segment(page.messages, sessionId: identity.sessionId, folder: folder, skipping: written)
        segment.title = identity.title
        segment.cwd = identity.cwd
        return segment
    }

    /// `skipping`: entries Kore wrote itself (an earlier import into this session).
    public static func segment(
        _ messages: [JSONValue], sessionId: String, folder: URL, skipping: Set<String> = []
    ) -> HandoffSegment {
        var reader = Reader(folder: folder)
        for entry in messages {
            if let uuid = entry["uuid"]?.string, skipping.contains(uuid) { continue }
            reader.read(entry)
        }
        reader.close()
        var segment = HandoffSegment(
            source: "claude", product: "Claude Code", sessionId: sessionId, model: reader.model, summary: reader.summary,
            turns: reader.turns)
        segment.unknown = reader.unknown
        segment.mode = reader.mode
        return segment
    }

    private struct Reader {
        let folder: URL
        var turns: [HandoffTurn] = []
        var current: HandoffTurn?
        /// Tool calls waiting for their results, by id: the step's index in `current`.
        var pending: [String: Int] = [:]
        var summary: String?
        var model: String?
        var mode: String?
        var unknown = 0

        init(folder: URL) { self.folder = folder }

        mutating func read(_ entry: JSONValue) {
            if ClaudeHistory.isBoundary(entry) { return }
            switch entry["type"]?.string {
            case "user": user(entry)
            case "assistant": assistant(entry)
            default: break
            }
        }

        mutating func user(_ entry: JSONValue) {
            let content = entry["message"]?["content"]
            if entry["isCompactSummary"]?.bool == true {
                summary = Self.texts(content).joined(separator: "\n\n")
                return
            }
            let blocks = content?.array ?? []
            if blocks.contains(where: { $0["type"]?.string == "tool_result" }) {
                for block in blocks where block["type"]?.string == "tool_result" { result(block, entry["toolUseResult"]) }
                return
            }
            let texts = Self.texts(content)
            if texts.count == 1, ClaudeHistory.stopMarkers.contains(texts[0]) {
                current?.end = .interrupted
                return
            }
            if let peer = PeerMessage(entry: entry) {
                open(entry, prompt: "Message from \(peer.from):\n\(peer.text)")
                return
            }
            // Turns the CLI starts itself (a cron firing, a finished agent's notice): its words
            // go on in the turn they belong to.
            if ClaudeHistory.cliTurnOrigins.contains(entry["turnOrigin"]?.string ?? "") { return }
            let prompt = texts.filter { !$0.hasPrefix("<") }
            var images: [HandoffImage] = []
            var files: [String] = []
            for block in blocks {
                switch block["type"]?.string {
                case "image": if let image = Self.image(block) { images.append(image) }
                case "document":
                    let pages = block["source"]?["media_type"]?.string == "application/pdf" ? ", PDF" : ""
                    files.append("[document: \(block["title"]?.string ?? "untitled")\(pages)]")
                default: break
                }
            }
            // Harness traffic: command echoes, their output, agents' notices.
            guard !prompt.isEmpty || !images.isEmpty || !files.isEmpty else { return }
            mode = entry["permissionMode"]?.string ?? mode
            open(entry, prompt: prompt.joined(separator: "\n\n"))
            current?.images = images
            current?.files = files
        }

        mutating func assistant(_ entry: JSONValue) {
            let message = entry["message"]
            if entry["isApiErrorMessage"]?.bool == true {
                ensureTurn(entry)
                current?.end = .failed(Self.texts(message?["content"]).first ?? "API error")
                return
            }
            let name = message?["model"]?.string
            if name == "<synthetic>" { return }
            if let name { model = name }
            ensureTurn(entry)
            for block in message?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "text":
                    if let text = block["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        current?.reply = text
                    }
                case "tool_use":
                    guard let id = block["id"]?.string else { continue }
                    pending[id] = current?.steps.count
                    let step = Self.step(block["name"]?.string ?? "tool", block["input"] ?? .null, folder: folder)
                    current?.steps.append(step)
                case "thinking", "redacted_thinking", "fallback":
                    break
                default:
                    unknown += 1
                }
            }
            if let uuid = entry["uuid"]?.string { current?.lastItem = uuid }
        }

        mutating func result(_ block: JSONValue, _ structured: JSONValue?) {
            guard let id = block["tool_use_id"]?.string, let index = pending.removeValue(forKey: id), var step = current?.steps[index]
            else { return }
            let content = block["content"]
            // Only its start and end are ever carried: a long output isn't held whole.
            step.output = HandoffRender.cut(content?.string ?? Self.texts(content).joined(separator: "\n"))
            step.images = (content?.array ?? []).compactMap { $0["type"]?.string == "image" ? Self.image($0) : nil }
            if block["is_error"]?.bool == true { step.status = .error }
            // Edits carry their exact hunks: the diff replaces what the call's input said.
            if step.kind == .edit || step.kind == .write, let structured, let change = FileChange(claudeToolResult: structured) {
                step.detail = "file: \(HandoffPaths.relative(change.path, in: folder))\n" + change.unifiedText
                step.added = change.added
                step.removed = change.removed
                if step.status == .ok { step.output = "ok" }
            }
            current?.steps[index] = step
        }

        mutating func open(_ entry: JSONValue, prompt: String) {
            close()
            let id = entry["uuid"]?.string ?? UUID().uuidString
            current = HandoffTurn(id: id, prompt: prompt, at: Self.date(entry))
        }

        /// A page that starts mid-turn (after a compaction) has its first words with no prompt.
        mutating func ensureTurn(_ entry: JSONValue) {
            guard current == nil else { return }
            open(entry, prompt: "")
        }

        /// Ends the current turn: calls that never got a result were cut off.
        mutating func close() {
            guard var turn = current else { return }
            for index in pending.values where index < turn.steps.count { turn.steps[index].status = .interrupted }
            if !pending.isEmpty, turn.end == .done { turn.end = .interrupted }
            pending = [:]
            turns.append(turn)
            current = nil
        }

        static func texts(_ content: JSONValue?) -> [String] {
            if let text = content?.string { return [text] }
            return (content?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
        }

        static func image(_ block: JSONValue) -> HandoffImage? {
            guard let data = block["source"]?["data"]?.string else { return nil }
            return HandoffImage(mediaType: block["source"]?["media_type"]?.string ?? "image/png", data: data)
        }

        static func date(_ entry: JSONValue) -> Date? {
            entry["timestamp"]?.string.flatMap { Timestamp.parse($0) ?? (try? Date($0, strategy: .iso8601)) }
        }

        /// A tool call as a step, before its result (which may add the output and an exact diff).
        static func step(_ name: String, _ input: JSONValue, folder: URL) -> HandoffStep {
            func field(_ key: String) -> String? { input[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
            func path(_ key: String = "file_path") -> String { field(key).map { HandoffPaths.relative($0, in: folder) } ?? "" }
            func lines(_ pairs: [(String, String?)]) -> String {
                pairs.compactMap { key, value in value.map { "\(key): \($0)" } }.joined(separator: "\n")
            }
            switch name {
            case "Bash", "Monitor":
                let command = field("command") ?? ""
                return HandoffStep(
                    kind: .command, tool: name, title: field("description") ?? command,
                    detail: lines([("description", field("description")), ("command", command)]))
            case "Read":
                let range = input["offset"]?.int.map { from in "from line \(from)" + (input["limit"]?.int.map { ", \($0) lines" } ?? "") }
                return HandoffStep(kind: .read, tool: name, title: path(), detail: lines([("file", path()), ("range", range)]))
            case "Grep", "Glob":
                let pattern = field("pattern") ?? ""
                return HandoffStep(
                    kind: .search, tool: name, title: pattern,
                    detail: lines([("pattern", pattern), ("path", field("path").map { HandoffPaths.relative($0, in: folder) }), ("glob", field("glob"))]))
            case "Edit", "MultiEdit", "NotebookEdit":
                var step = HandoffStep(kind: .edit, tool: name, title: path(name == "NotebookEdit" ? "notebook_path" : "file_path"))
                let edits = input["edits"]?.array ?? [input]
                let diff = edits.map { edit in
                    let old = (edit["old_string"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
                    let new = (edit["new_string"]?.string ?? edit["new_source"]?.string ?? "")
                        .split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
                    step.removed += old.count
                    step.added += new.count
                    return (old + new).joined(separator: "\n")
                }
                step.detail = "file: \(step.title)\n" + diff.joined(separator: "\n")
                return step
            case "Write":
                let content = field("content") ?? ""
                var step = HandoffStep(kind: .write, tool: name, title: path())
                let added = content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
                step.added = added.count
                step.detail = "file: \(step.title)\n" + added.joined(separator: "\n")
                return step
            case "WebSearch":
                return HandoffStep(kind: .web, tool: name, title: field("query") ?? "", detail: lines([("query", field("query"))]))
            case "WebFetch":
                return HandoffStep(
                    kind: .web, tool: name, title: field("url") ?? "", detail: lines([("url", field("url")), ("prompt", field("prompt"))]))
            case "Agent", "Task":
                let description = field("description") ?? field("subagent_type") ?? "task"
                return HandoffStep(
                    kind: .agent, tool: name, title: "Agent: \(description)",
                    detail: lines([("description", description), ("prompt", field("prompt"))]))
            case "TodoWrite":
                let todos = (input["todos"]?.array ?? []).map { todo in
                    let done = todo["status"]?.string == "completed" ? "x" : todo["status"]?.string == "in_progress" ? "~" : " "
                    return "[\(done)] \(todo["content"]?.string ?? "")"
                }
                return HandoffStep(kind: .plan, tool: name, title: "todo list", detail: todos.joined(separator: "\n"))
            case "ExitPlanMode", "EnterPlanMode":
                return HandoffStep(kind: .plan, tool: name, title: "plan", detail: field("plan") ?? name)
            case "AskUserQuestion":
                let questions = (input["questions"]?.array ?? []).map { question in
                    let options = (question["options"]?.array ?? []).compactMap { $0["label"]?.string }
                    return (question["question"]?.string ?? "") + (options.isEmpty ? "" : " (" + options.joined(separator: " / ") + ")")
                }
                return HandoffStep(kind: .question, tool: name, title: questions.first ?? "a question", detail: questions.joined(separator: "\n"))
            default:
                return HandoffStep(kind: name.hasPrefix("mcp__") ? .mcp : .other, tool: name, title: name, detail: "input: " + input.compact)
            }
        }
    }
}

/// Paths as the carried history shows them: relative to the chat's folder when inside it.
enum HandoffPaths {
    static func relative(_ path: String, in folder: URL) -> String {
        let path = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
        for root in [folder.standardizedFileURL.path, realPath(folder.path)] where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }
}

extension FileChange {
    /// The hunks as unified diff text (`@@ -1,3 +1,4 @@` and their lines).
    var unifiedText: String {
        hunks.map { hunk in
            let old = hunk.lines.count { $0.kind != .add }
            let new = hunk.lines.count { $0.kind != .remove }
            let body = hunk.lines.map { line -> String in
                switch line.kind {
                case .add: "+" + line.text
                case .remove: "-" + line.text
                case .context: " " + line.text
                }
            }
            return (["@@ -\(hunk.oldStart),\(old) +\(hunk.newStart),\(new) @@"] + body).joined(separator: "\n")
        }.joined(separator: "\n") + (isTruncated ? "\n[… more lines not kept …]" : "")
    }
}

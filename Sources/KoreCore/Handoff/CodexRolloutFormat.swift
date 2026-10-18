import Foundation

/// Codex rollouts (`~/.codex/sessions/…/rollout-…-<thread>.jsonl`, or a copy from anywhere)
/// into the neutral form, read from the file itself: its `response_item` lines are what the
/// model saw, in every rollout generation, and its turn events say where turns start and how
/// they ended. A compaction leaves the raw items before it in place (its own summary is
/// encrypted), so they're read back to the start. Reasoning is dropped (encrypted, and its
/// summary isn't model-visible on the other side either); a sub-agent keeps its name and final
/// answer, its task text being encrypted too.
public struct CodexRolloutFormat: HandoffFormat {
    public let id = "codex"
    public let product = "Codex"
    public var store: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            .map { $0.appendingPathComponent("sessions") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    public init() {}

    /// The first line is the rollout's `session_meta` (with the thread's id), and the lines after
    /// it are `{timestamp, type, payload}` records.
    public func identify(_ head: HandoffHead) -> HandoffIdentity? {
        guard head.allObjects, let first = head.lines.first ?? nil, first["type"]?.string == "session_meta",
            let meta = first["payload"], let thread = meta["id"]?.string, !thread.isEmpty,
            head.lines.dropFirst().allSatisfy({ $0?["type"]?.string != nil && $0?["payload"] != nil && $0?["timestamp"]?.string != nil })
        else { return nil }
        return HandoffIdentity(format: id, product: product, file: head.file, sessionId: thread, cwd: meta["cwd"]?.string)
    }

    /// Read from the file's end, newest turn first, only as far as the target's budget takes
    /// turns (a rollout can be well over a GB): lines are cut into turns at each turn's start
    /// (`task_started`, or `turn_context` in rollouts without it), and each turn is read by
    /// itself, oldest line first. The turns before the last one read are counted with a byte scan
    /// when the file is small enough, else left uncounted. With no window, the whole file.
    public func read(_ file: URL, identity: HandoffIdentity, window: Int?) throws -> HandoffSegment {
        guard var tail = TailLines(file: file) else { throw HandoffReadError("Couldn't read the file") }
        let folder = URL(fileURLWithPath: identity.cwd ?? file.deletingLastPathComponent().path)
        // A thread Kore made by an import holds that import's items before its first turn starts
        // (after the context Codex writes as the thread starts): a translation, not Codex's own.
        // Its turns are cut at `task_started` only, and what comes before the first is left out.
        let made = HandoffRecords.record(target: identity.sessionId) != nil
        var budget = window.map(HandoffBudget.init(window:))
        var segment = HandoffSegment(source: id, product: product, sessionId: identity.sessionId)
        segment.cwd = identity.cwd
        var newestFirst: [HandoffTurn] = []
        /// One turn's records, newest first, until its start.
        var lines: [JSONValue] = []
        var started = 0
        var cutAtContext = false
        var full = false
        func take(_ records: [JSONValue]) {
            var reader = Reader(folder: folder)
            for record in records.reversed() { reader.read(record) }
            reader.close()
            // The newest turn that says each one.
            segment.model = segment.model ?? reader.model
            segment.mode = segment.mode ?? reader.mode
            segment.effort = segment.effort ?? reader.effort
            segment.unknown += reader.unknown
            for turn in reader.turns.reversed() where !full {
                newestFirst.append(turn)
                if budget?.offer(turn) == false { full = true }
            }
        }
        while !full, let (_, line) = tail.next() {
            let head = line.prefix(240)
            guard Self.wanted.contains(where: { head.range(of: $0) != nil }) else { continue }
            // What the turns still to come can't carry isn't parsed: outputs once they can't be
            // full, tool calls once they can only be bare.
            if let level = budget?.level, level != .full, Self.outputs.contains(where: { head.range(of: $0) != nil }) { continue }
            if budget?.level == .bare, Self.calls.contains(where: { head.range(of: $0) != nil }) { continue }
            guard let record = try? JSONValue.parse(line) else { throw HandoffReadError("A line isn't valid JSON") }
            lines.append(record)
            let start = record["type"]?.string == "event_msg" && record["payload"]?["type"]?.string == "task_started"
            if start { started += 1 }
            let context = !made && record["type"]?.string == "turn_context"
            // A turn cut at its context still has its start just before it: counted as read.
            if context { started += 1 } else if start, cutAtContext { started -= 1 }
            cutAtContext = context
            if start || context {
                take(lines)
                lines = []
            }
        }
        if !full, !made { take(lines) }
        segment.turns = newestFirst.reversed()
        if !full {
            segment.earlier = 0
        } else if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.countLimit {
            // Older rollouts mark no turn starts: their turn contexts count instead.
            let starts = Self.count(Self.taskStarted, in: file)
            segment.earlier = max(0, (starts > 0 ? starts : Self.count(Self.turnContext, in: file)) - started)
        } else {
            segment.earlier = nil
        }
        return segment
    }

    /// Files up to this size have their turns counted (a byte scan, no parsing); a longer one's
    /// older turns are "earlier turns", uncounted.
    static let countLimit = 256 << 20
    private static let taskStarted = Data(#""type":"task_started""#.utf8)
    private static let turnContext = Data(#""type":"turn_context""#.utf8)

    /// How many times `needle` occurs in the file, scanned in place.
    static func count(_ needle: Data, in file: URL) -> Int {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return 0 }
        return data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var found = 0
            var at = 0
            needle.withUnsafeBytes { pattern in
                while at < bytes.count, let hit = memmem(base + at, bytes.count - at, pattern.baseAddress, pattern.count) {
                    found += 1
                    at = base.distance(to: UnsafeRawPointer(hit)) + pattern.count
                }
            }
            return found
        }
    }

    private static let outputs = [#""type":"function_call_output""#, #""type":"custom_tool_call_output""#].map { Data($0.utf8) }
    private static let calls = [#""type":"function_call""#, #""type":"custom_tool_call""#, #""type":"web_search_call""#].map { Data($0.utf8) }
    private static let wanted = [#""type":"response_item""#, #""type":"turn_context""#, #""type":"task_started""#, #""type":"turn_aborted""#, #""type":"error""#]
        .map { Data($0.utf8) }

    /// Images in prompts over this size don't carry (Claude takes 5 MB a block).
    static let imageLimit = 5 << 20

    private struct Reader {
        let folder: URL
        var turns: [HandoffTurn] = []
        var current: HandoffTurn?
        /// The turn the next prompt belongs to (`turn_context`).
        var turnId: String?
        var at: Date?
        /// Calls waiting for their outputs, by call id: the step's index in `current`.
        var pending: [String: Int] = [:]
        /// apply_patch calls make a step per file: their indexes.
        var patches: [String: [Int]] = [:]
        var model: String?
        var mode: String?
        var effort: String?
        var unknown = 0

        init(folder: URL) { self.folder = folder }

        mutating func read(_ record: JSONValue) {
            let payload = record["payload"] ?? .null
            switch record["type"]?.string {
            case "turn_context":
                turnId = payload["turn_id"]?.string
                at = record["timestamp"]?.string.flatMap(Timestamp.parse)
                model = payload["model"]?.string ?? model
                effort = payload["effort"]?.string ?? payload["reasoning_effort"]?.string ?? effort
                if let settings = CodexTurnSettings(payload) { mode = settings.plan ? "plan" : settings.permissions.rawValue }
            case "event_msg":
                switch payload["type"]?.string {
                case "turn_aborted": current?.end = .interrupted
                case "error": current?.end = .failed(CodexError.readable(payload["message"]?.string ?? "the turn failed"))
                default: break
                }
            case "response_item":
                item(payload)
            default:
                break
            }
        }

        mutating func item(_ item: JSONValue) {
            switch item["type"]?.string {
            case "message":
                message(item)
            case "function_call":
                function(item)
            case "custom_tool_call":
                custom(item)
            case "function_call_output", "custom_tool_call_output":
                output(item)
            case "web_search_call":
                let action = item["action"]
                let query = action?["query"]?.string ?? action?["queries"]?.array?.compactMap(\.string).joined(separator: " | ")
                    ?? action?["url"]?.string ?? ""
                add(HandoffStep(kind: .web, tool: "web_search", title: query, detail: "query: \(query)"))
            case "agent_message":
                agentMessage(item)
            case "reasoning", "compaction", "tool_search_call", "tool_search_output", "ghost_snapshot":
                break
            default:
                unknown += 1
            }
        }

        mutating func message(_ item: JSONValue) {
            let content = item["content"]?.array ?? []
            let texts = content.compactMap { $0["text"]?.string }
            switch item["role"]?.string {
            case "user":
                // The harness's own user messages: environment, instructions, notices.
                let prompt = texts.filter { !Self.isContext($0) }
                var images: [HandoffImage] = []
                var files: [String] = []
                for input in content where input["type"]?.string == "input_image" {
                    let url = input["image_url"]?.string ?? ""
                    if let image = HandoffImage(dataURL: url), image.data.utf8.count / 4 * 3 <= CodexRolloutFormat.imageLimit {
                        images.append(image)
                    } else {
                        files.append("[image]")
                    }
                }
                guard !prompt.isEmpty || !images.isEmpty else { return }
                // A message steered into a running turn joins it (older rollouts name no turns:
                // each prompt is one).
                if var turn = current, let turnId, turn.id == turnId {
                    turn.prompt += (turn.prompt.isEmpty ? "" : "\n\n") + prompt.joined(separator: "\n\n")
                    turn.images += images
                    current = turn
                    return
                }
                close()
                current = HandoffTurn(id: turnId ?? UUID().uuidString, prompt: prompt.joined(separator: "\n\n"), at: at)
                current?.images = images
                current?.files = files
            case "assistant":
                // Every message, in its place: the last one becomes the reply at the turn's end.
                current?.say(texts.joined(separator: "\n"))
            default:
                break  // developer: Codex's own instructions
            }
        }

        static func isContext(_ text: String) -> Bool {
            text.hasPrefix("<") || text.hasPrefix("# AGENTS.md instructions")
        }

        mutating func function(_ item: JSONValue) {
            let name = item["name"]?.string ?? "tool"
            let arguments = item["arguments"]?.string.flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .null
            let call = item["call_id"]?.string ?? ""
            func command(_ text: String) -> HandoffStep {
                HandoffStep(kind: .command, tool: name, title: text, detail: "command: \(text)")
            }
            let step: HandoffStep?
            switch name {
            case "exec_command":
                step = command(arguments["cmd"]?.string ?? "")
            case "shell", "shell_command", "local_shell":
                let parts = arguments["command"]?.array?.compactMap(\.string) ?? []
                let text = arguments["command"]?.string ?? (parts.count == 3 && parts[1] == "-lc" ? parts[2] : parts.joined(separator: " "))
                step = command(text)
            case "apply_patch":
                patch(arguments["input"]?.string ?? item["arguments"]?.string ?? "", call: call)
                return
            case "update_plan":
                let plan = (arguments["plan"]?.array ?? []).map { "[\($0["status"]?.string == "completed" ? "x" : " ")] \($0["step"]?.string ?? "")" }
                step = HandoffStep(kind: .plan, tool: name, title: "plan", detail: plan.joined(separator: "\n"))
            case "view_image":
                let path = HandoffPaths.relative(arguments["path"]?.string ?? "", in: folder)
                step = HandoffStep(kind: .read, tool: name, title: path, detail: "file: \(path)")
            case "spawn_agent":
                let task = arguments["task_name"]?.string ?? arguments["agent_type"]?.string ?? "sub-agent"
                step = HandoffStep(kind: .agent, tool: name, title: "Agent: \(task)")
            case "request_user_input", "request_user_input_async":
                let questions = (arguments["questions"]?.array ?? []).compactMap { $0["question"]?.string }
                step = HandoffStep(kind: .question, tool: name, title: questions.first ?? "a question", detail: questions.joined(separator: "\n"))
            // Waiting, polling and messaging agents (their texts are encrypted) say nothing to carry.
            case "wait", "write_stdin", "sleep", "wait_agent", "send_message", "followup_task", "list_agents", "close_agent":
                step = nil
            default:
                step = HandoffStep(
                    kind: name.hasPrefix("mcp__") ? .mcp : .other, tool: name, title: name, detail: "input: " + arguments.compact)
            }
            guard let step else { return }
            add(step, call: call)
        }

        /// Code mode's `exec` (a script) or `apply_patch` (the patch text).
        mutating func custom(_ item: JSONValue) {
            let name = item["name"]?.string ?? "tool"
            let input = item["input"]?.string ?? ""
            let call = item["call_id"]?.string ?? ""
            switch name {
            case "apply_patch":
                patch(input, call: call)
            case "exec":
                if let command = CodexRolloutFormat.execCommand(input) {
                    add(HandoffStep(kind: .command, tool: "exec_command", title: command, detail: "command: \(command)"), call: call)
                } else {
                    add(HandoffStep(kind: .other, tool: "exec", title: "a script", detail: HandoffRender.cut(input)), call: call)
                }
            default:
                add(HandoffStep(kind: .other, tool: name, title: name, detail: HandoffRender.cut(input)), call: call)
            }
        }

        /// One step per file the patch touches, with its part of the patch as the diff.
        mutating func patch(_ text: String, call: String) {
            var indexes: [Int] = []
            for file in CodexRolloutFormat.patchFiles(text) {
                var step = HandoffStep(kind: file.kind, tool: "apply_patch", title: HandoffPaths.relative(file.path, in: folder))
                step.detail = HandoffRender.cut("file: \(step.title)\n" + file.body)
                step.added = file.added
                step.removed = file.removed
                add(step)
                if let index = current.map({ $0.steps.count - 1 }) { indexes.append(index) }
            }
            if !indexes.isEmpty { patches[call] = indexes }
        }

        mutating func output(_ item: JSONValue) {
            let call = item["call_id"]?.string ?? ""
            let raw = item["output"]
            let text = raw?.string ?? (raw?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            if let indexes = patches.removeValue(forKey: call) {
                let failed = !text.contains("Success") && !text.isEmpty
                for index in indexes where index < (current?.steps.count ?? 0) {
                    current?.steps[index].output = failed ? HandoffRender.cut(text) : "ok"
                    if failed { current?.steps[index].status = .error }
                }
                return
            }
            guard let index = pending.removeValue(forKey: call), index < (current?.steps.count ?? 0) else { return }
            // Only its start and end are ever carried: a long output isn't held whole.
            current?.steps[index].output = HandoffRender.cut(text)
            if let exit = Self.exitCode(text) {
                current?.steps[index].exitCode = exit
                if exit != 0 { current?.steps[index].status = .error }
            }
        }

        /// A sub-agent's message to its parent: its final answer when it says so.
        mutating func agentMessage(_ item: JSONValue) {
            let text = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            guard text.contains("FINAL_ANSWER") else { return }
            let author = item["author"]?.string ?? "sub-agent"
            let name = author.split(separator: "/").last.map(String.init) ?? author
            let answer = text.range(of: "Payload:\n").map { String(text[$0.upperBound...]) } ?? ""
            if let index = current?.steps.lastIndex(where: { $0.kind == .agent && $0.title == "Agent: \(name)" }) {
                current?.steps[index].output = HandoffRender.cut(answer)
            } else {
                add(HandoffStep(kind: .agent, tool: "spawn_agent", title: "Agent: \(name)", output: answer))
            }
        }

        mutating func add(_ step: HandoffStep, call: String? = nil) {
            if current == nil { current = HandoffTurn(id: turnId ?? UUID().uuidString, prompt: "", at: at) }
            current?.steps.append(step)
            if let call, !call.isEmpty { pending[call] = (current?.steps.count ?? 1) - 1 }
        }

        /// Ends the current turn: calls that never got an output were cut off.
        mutating func close() {
            guard var turn = current else { return }
            for index in pending.values where index < turn.steps.count && turn.steps[index].kind != .agent {
                turn.steps[index].status = .interrupted
            }
            pending = [:]
            patches = [:]
            turn.settleReply()
            turn.lastItem = turn.id
            turns.append(turn)
            current = nil
        }

        /// "Process exited with code 1" in exec_command's output.
        static func exitCode(_ text: String) -> Int? {
            guard let range = text.range(of: "exited with code ") else { return nil }
            return Int(text[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
        }
    }

    /// The command of a script whose only call is `tools.exec_command({cmd: "…"})`.
    static func execCommand(_ script: String) -> String? {
        guard script.components(separatedBy: "tools.").count == 2,
            let call = script.range(of: #"tools\.exec_command\(\s*\{\s*"?cmd"?\s*:\s*"#, options: .regularExpression)
        else { return nil }
        let rest = script[call.upperBound...]
        guard let quote = rest.first, "\"'`".contains(quote) else { return nil }
        var value = ""
        var escaped = false
        for character in rest.dropFirst() {
            if escaped {
                value.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    /// The files of an apply_patch text (`*** Update File: path` … ), each with its lines.
    static func patchFiles(_ text: String) -> [(path: String, kind: HandoffStep.Kind, body: String, added: Int, removed: Int)] {
        var files: [(path: String, kind: HandoffStep.Kind, body: String, added: Int, removed: Int)] = []
        var lines: [Substring] = []
        func flush() {
            guard var file = files.popLast() else { return }
            file.body = lines.joined(separator: "\n")
            file.added = lines.count { $0.hasPrefix("+") }
            file.removed = lines.count { $0.hasPrefix("-") }
            files.append(file)
            lines = []
        }
        let headers: [(String, HandoffStep.Kind)] = [("*** Update File: ", .edit), ("*** Add File: ", .write), ("*** Delete File: ", .delete)]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let (prefix, kind) = headers.first(where: { line.hasPrefix($0.0) }) {
                flush()
                files.append((String(line.dropFirst(prefix.count)), kind, "", 0, 0))
            } else if line.hasPrefix("*** End Patch") || line.hasPrefix("*** Begin Patch") {
                continue
            } else if !files.isEmpty {
                lines.append(line)
            }
        }
        flush()
        return files
    }
}

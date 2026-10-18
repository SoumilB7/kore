import Foundation
import KoreCore

/// Turns Claude's stream-json into `ChatEvent`s. Transcripts share the shape, so a resumed
/// session's past goes through the same mapping (`replay`).
final class ClaudeTranslator {
    /// Work that needs the disk or time; the backend runs it and reports back.
    enum Followup {
        /// A turn the CLI started for a queued command: read its transcript entry for a peer's message.
        case peer(uuid: String, turn: TurnID)
        /// A turn the CLI started with no command (a cron firing, a finished agent): read its cause.
        case cliTurn(TurnID, startedAt: Date)
        /// The turn's changed files, once its end snapshot is diffed.
        case changes(TurnID, Task<[FileChange], Never>)
        /// Ask the CLI how full the context is now (after a compaction).
        case contextUsage
    }

    let files: TurnFiles
    private let folder: URL
    private(set) var sessionId: String?
    /// Permission requests waiting on the user, by request id.
    private var pending: [String: PermissionRequest] = [:]

    private var out: [ChatEvent] = []
    private var followups: [Followup] = []
    /// Replaying a transcript: no snapshots; a turn's files come from its tool edits.
    private var replaying = false
    private var replayChanges: [FileChange] = []
    /// Reading a sub-agent's own transcript: its edits belong to no turn of this chat.
    private var reading = false
    /// Live, a sub-agent's messages can come twice (its tailed transcript, and stdout when the
    /// CLI relays them): tool calls by id, text by content, each kept once.
    private var seen: Set<String> = []
    private var deduplicating = true

    private func firstTime(_ key: String, _ agent: AgentID) -> Bool {
        guard case .sub(let id) = agent, deduplicating else { return true }
        return seen.insert(id + "|" + key).inserted
    }

    /// The main agent's block receiving deltas; a new one starts at each content block.
    private var block: (id: BlockID, kind: TextKind)?

    private(set) var turn: TurnID?
    private var turnStart = Date()
    /// The main agent's answer blocks and tool calls, in order, to find the final answer.
    private var turnItems: [TurnItem] = []
    private enum TurnItem { case answer(BlockID), tool }

    // Sub-agents. `AgentID.sub` carries the Agent tool_use id that spawned it: messages name it
    // as their `parent_tool_use_id`, so it's known before `task_started` arrives.
    private var toolAgent: [String: AgentID] = [:]
    private var agentInputs: [String: JSONValue] = [:]
    /// task id → Agent tool_use id.
    private var taskTool: [String: String] = [:]
    private var spawned: Set<String> = []
    /// Finished agents, and whether their result text was given yet.
    private var finished: [String: Bool] = [:]
    /// Agent tool_use id → the CLI's agent id (its `subagents/agent-<id>.jsonl`).
    private(set) var agentFiles: [String: String] = [:]

    static let agentTools: Set<String> = ["Agent", "Task"]

    // Modes. The CLI reports every change as `system/status {permissionMode}` (and each turn's
    // `system/init`) but not why; the cause is what came just before it.
    /// The permission mode the CLI last confirmed.
    private(set) var mode: String?
    /// Asked for with `set_permission_mode`, not confirmed yet.
    private var requestedMode: String?
    /// An EnterPlanMode / ExitPlanMode call the CLI hasn't settled yet (live: until its result).
    private var modeCall: (id: String, tool: String, agent: AgentID)?
    /// Replay: plan-mode calls by tool id, and the time and exit target of the entry being read.
    private var modeCalls: [String: (tool: String, agent: AgentID)] = [:]
    private var replayTime = Date()
    private var replayExitMode: String?
    static let modeTools: Set<String> = ["EnterPlanMode", "ExitPlanMode"]

    // Context. `used` is the main agent's last model call: input + cache creation + cache read +
    // output tokens, as Claude's VS Code extension counts it.
    /// The session's model (system/init), whose window `result.modelUsage` names.
    private var model: String?
    private var contextUsed: Int?
    /// The effective window, as the extension computes it (`Self.effectiveWindow`).
    private var contextWindow: Int?
    private var autoCompacts: Bool?
    private var reportedContext: ContextUsage?
    /// Kore asked for this compaction (`compact()` or a typed /compact): not an automatic one.
    var compactRequested = false
    /// Live: a compaction's boundary came; its summary is the next synthetic user message.
    private var awaitingSummary = false

    init(folder: URL, sessionId: String?) {
        self.folder = folder
        self.sessionId = sessionId
        files = TurnFiles(folder: folder)
    }

    func take() -> (events: [ChatEvent], followups: [Followup]) {
        defer {
            out = []
            followups = []
        }
        return (out, followups)
    }

    func request(_ id: String) -> PermissionRequest? { pending.removeValue(forKey: id) }

    func taskId(forAgent id: String) -> String? { taskTool.first { $0.value == id }?.key }

    func isFinished(_ agent: String) -> Bool { finished[agent] != nil }

    // MARK: - Turns

    /// Opens a turn unless one is open. Kore opens one on send; the CLI's own turns open on
    /// `command_lifecycle` or `status "requesting"`.
    func openTurn(_ origin: TurnOrigin, at date: Date = .now) {
        guard turn == nil else { return }
        let id = ToolText.newID()
        turn = id
        turnStart = date
        turnItems = []
        block = nil
        if replaying { replayChanges = [] } else { files.begin() }
        out.append(.turnStarted(id, origin: origin, at: date))
    }

    /// Closes a turn that never reached the CLI (the send failed).
    func abandonTurn() {
        guard let turn else { return }
        out.append(.turnFinished(turn, .completed, duration: nil))
        _ = files.finish()
        self.turn = nil
    }

    private func finishTurn(_ outcome: TurnOutcome, duration: Duration?) {
        if let answer = finalAnswer() { out.append(.finalAnswer(answer)) }
        out.append(.turnFinished(turn, outcome, duration: duration))
        if let turn {
            if replaying {
                let changes = FileChange.mergedByPath(replayChanges)
                if !changes.isEmpty { out.append(.turnChanges(turn, changes)) }
            } else {
                followups.append(.changes(turn, files.finish()))
            }
        }
        turn = nil
        turnItems = []
        block = nil
    }

    /// Claude doesn't mark its final answer: it's the text after the turn's last tool call.
    private func finalAnswer() -> BlockID? {
        let lastTool = turnItems.lastIndex { if case .tool = $0 { true } else { false } }
        for item in turnItems[(lastTool.map { $0 + 1 } ?? 0)...] {
            if case .answer(let id) = item { return id }
        }
        return nil
    }

    // MARK: - Events

    func translate(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let info):
            identify(info.sessionId)
            model = info.model ?? model
            // Repeated at every turn; it differs only when Kore launched in another mode.
            if let reported = info.permissionMode { setMode(reported, .user, at: .now) }
        case .permissionModeChanged(let reported):
            modeReported(reported)
        case .textDelta(let text, nil):
            stream(.answer, text)
        case .thinkingDelta(let text, nil):
            stream(.thinking, text)
        case .assistant(_, let blocks, let parent, let usage):
            assistant(blocks, agent: parent.map(AgentID.sub) ?? .main)
            if parent == nil, let usage { context(usage) }
        case .user(let blocks, let parent, let result):
            // After a compaction's boundary, stdout sends its summary as a plain user message
            // (`isSynthetic`), the transcript's `isCompactSummary` entry.
            if awaitingSummary, parent == nil, blocks.count == 1, case .text(let text) = blocks[0], !text.hasPrefix("<") {
                awaitingSummary = false
                out.append(.compactionSummary(text))
                return
            }
            toolResults(blocks, result, agent: parent.map(AgentID.sub) ?? .main)
        case .permissionRequest(let request):
            pending[request.id] = request
            out.append(.approvalRequested(approval(request)))
        case .permissionCancelled(let id):
            pending[id] = nil
            out.append(.approvalWithdrawn(id))
        case .commandStarted(let id, let session):
            // In a chat with nothing sent yet, this comes before system/init.
            if sessionId == nil, let session { identify(session) }
            openTurn(.cli)
            if let turn { followups.append(.peer(uuid: id, turn: turn)) }
        case .turnCompleted(let result):
            pending.removeAll()
            awaitingSummary = false
            // The window of the session's model (the extension reads it from here too).
            let models = result.raw["modelUsage"]
            if let usage = model.flatMap({ models?[$0] }) ?? models?.object?.values.first(where: { $0["contextWindow"] != nil }),
                let window = usage["contextWindow"]?.int
            {
                contextWindow = Self.effectiveWindow(window, maxOutput: usage["maxOutputTokens"]?.int ?? 0)
                if let used = contextUsed { reportContext(used, at: .now) }
            }
            let outcome: TurnOutcome =
                !result.isError
                ? .completed
                : result.subtype == "error_during_execution" ? .interrupted : .failed(result.result ?? result.subtype)
            finishTurn(outcome, duration: result.durationMs.map { .milliseconds($0) })
        case .raw(let json):
            raw(json)
        case .exited(let status):
            pending.removeAll()
            turn = nil
            turnItems = []
            block = nil
            out.append(.exited(status: status))
        default:
            break  // sub-agents' deltas (they have none), command_lifecycle completed, stderr
        }
    }

    private func identify(_ id: String) {
        guard !id.isEmpty, id != sessionId else { return }
        sessionId = id
        out.append(.sessionIdentified(id))
    }

    private func stream(_ kind: TextKind, _ text: String) {
        guard !text.isEmpty else { return }
        if block?.kind != kind {
            let id = ToolText.newID()
            block = (id, kind)
            if kind == .answer { turnItems.append(.answer(id)) }
        }
        out.append(.text(block!.id, kind, text))
    }

    private func assistant(_ blocks: [ContentBlock], agent: AgentID) {
        // The main agent's text normally arrived as deltas. A slash command's output (e.g.
        // /context), a transcript, and a sub-agent's messages come whole.
        if agent != .main || block == nil {
            for case .text(let text) in blocks where !text.isEmpty && firstTime("text:" + text, agent) {
                let id = ToolText.newID()
                out.append(.text(id, .answer, text, agent: agent))
                if agent == .main { turnItems.append(.answer(id)) }
            }
        }
        if agent == .main { block = nil }
        for case .toolUse(let id, let name, let input) in blocks where firstTime("start:" + id, agent) {
            toolAgent[id] = agent
            if Self.agentTools.contains(name) { agentInputs[id] = input }
            if Self.modeTools.contains(name) {
                if replaying { modeCalls[id] = (name, agent) } else { modeCall = (id, name, agent) }
            }
            out.append(.toolStarted(Self.toolCall(id, name, input, in: folder), agent: agent))
            if agent == .main { turnItems.append(.tool) }
        }
    }

    private func toolResults(_ blocks: [ContentBlock], _ result: JSONValue?, agent: AgentID) {
        var first: String?
        for case .toolResult(let id, let content, let isError) in blocks where firstTime("end:" + id, agent) {
            first = first ?? id
            if modeCall?.id == id { modeCall = nil }  // live, the status (if any) came before it
            if replaying, !isError, let call = modeCalls.removeValue(forKey: id) {
                // A transcript has no status lines: the call succeeding is the switch.
                if call.tool == "EnterPlanMode" {
                    setMode("plan", .agent(.enteredPlanMode, call.agent), at: replayTime)
                } else {
                    // The target is the next prompt's mode. With no next prompt, or one sent back
                    // in plan (Kore switched it between turns, unrecorded), it isn't known: no
                    // guess; the next prompt (or the live session) says the mode.
                    if let target = replayExitMode, target != "plan" {
                        setMode(target, .agent(.planApproved, call.agent), at: replayTime)
                    }
                }
            }
            out.append(.toolFinished(id: id, output: Self.text(of: content), isError: isError, agent: agent))
        }
        guard let id = first, let result else { return }
        if let change = FileChange(claudeToolResult: result) {
            out.append(.fileChanged(toolId: id, [change], agent: agent))
            if reading {
            } else if replaying {
                replayChanges.append(change)
            } else {
                files.record([change])
            }
        } else if agentInputs[id] != nil {
            agentReturned(id, result)
        }
    }

    private func raw(_ json: JSONValue) {
        switch json["type"]?.string {
        case "stream_event":
            if json["event"]?["type"]?.string == "content_block_start", json["parent_tool_use_id"]?.string == nil {
                block = nil
            }
        case "system":
            switch json["subtype"]?.string {
            case "status" where json["status"]?.string == "requesting" && turn == nil:
                // Sent before every model request; with no turn open, the CLI started one itself.
                openTurn(.cli)
                if let turn { followups.append(.cliTurn(turn, startedAt: turnStart)) }
            case "compact_boundary":
                // /compact live: the divider goes above the summary that follows. The context's
                // new size is asked for (it isn't on the boundary).
                out.append(.compacted(at: .now, from: Self.preTokens(json), auto: Self.autoCompacted(json)))
                compactRequested = false
                awaitingSummary = true
                followups.append(.contextUsage)
            case "status" where json["status"]?.string == "compacting":
                out.append(.compactionStarted(auto: !compactRequested))
            case "status" where json["compact_result"]?.string.map({ $0 != "success" }) == true:
                compactRequested = false
                out.append(.compactionFailed(json["compact_error"]?.string ?? "Compaction \(json["compact_result"]?.string ?? "failed")"))
            case "task_started" where !(json["task_type"]?.string.map { !$0.contains("agent") } ?? false):
                // Background shell commands are tasks too (local_bash); only agents get a card.
                let tool = json["tool_use_id"]?.string ?? json["task_id"]?.string ?? ""
                if let task = json["task_id"]?.string { taskTool[task] = tool }
                spawn(
                    tool, name: json["description"]?.string, type: json["subagent_type"]?.string,
                    prompt: json["prompt"]?.string, background: json["is_backgrounded"]?.bool)
            case "task_progress" where spawned.contains(agent(ofTask: json)):
                let usage = json["usage"]
                out.append(
                    .agentProgress(
                        id: agent(ofTask: json),
                        AgentProgress(
                            tokens: usage?["total_tokens"]?.int, tools: usage?["tool_uses"]?.int,
                            duration: usage?["duration_ms"]?.int.map { .milliseconds($0) },
                            lastTool: json["last_tool_name"]?.string)))
            case "task_updated":
                finishAgent(agent(ofTask: json), status: json["patch"]?["status"]?.string, result: nil)
            case "task_notification":
                finishAgent(agent(ofTask: json), status: json["status"]?.string, result: json["summary"]?.string)
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: - Sub-agents

    private func agent(ofTask json: JSONValue) -> String {
        json["task_id"]?.string.flatMap { taskTool[$0] } ?? json["tool_use_id"]?.string ?? json["task_id"]?.string ?? ""
    }

    private func spawn(_ id: String, name: String? = nil, type: String? = nil, prompt: String? = nil, background: Bool? = nil) {
        guard !id.isEmpty, spawned.insert(id).inserted else { return }
        let input = agentInputs[id]
        out.append(
            .agentSpawned(
                AgentInfo(
                    id: id, parent: toolAgent[id] ?? .main, toolId: id,
                    name: name ?? input?["description"]?.string ?? "Agent",
                    type: type ?? input?["subagent_type"]?.string, model: input?["model"]?.string,
                    prompt: prompt ?? input?["prompt"]?.string,
                    background: background ?? input?["run_in_background"]?.bool ?? false)))
    }

    /// Once per agent, plus once more if its result text comes later (stdout's
    /// `task_notification` has none; the notification prompt that follows has it).
    private func finishAgent(_ id: String, status: String?, result: String?) {
        guard spawned.contains(id), let status = status.flatMap(Self.agentStatus) else { return }
        switch finished[id] {
        case nil: break
        case false? where result != nil: break
        default: return
        }
        finished[id] = result != nil
        out.append(.agentFinished(id: id, status, result: result))
    }

    /// The Agent call's own result. Live, the `task_*` events said it all already; a transcript
    /// has only this, so the agent is spawned and finished from it.
    private func agentReturned(_ id: String, _ result: JSONValue) {
        if let file = result["agentId"]?.string { agentFiles[id] = file }
        let status = result["status"]?.string ?? "completed"
        spawn(id)
        guard status != "async_launched" else { return }  // background: ends later
        // Live, `task_notification` finished it already, without the report; this has it.
        defer { finishAgent(id, status: status, result: result["content"].map(Self.text(of:))) }
        guard finished[id] == nil else { return }
        out.append(
            .agentProgress(
                id: id,
                AgentProgress(
                    tokens: result["totalTokens"]?.int, tools: result["totalToolUseCount"]?.int,
                    duration: result["totalDurationMs"]?.int.map { .milliseconds($0) }, lastTool: nil)))
    }

    /// The CLI's `<task-notification>` prompt, which starts the turn after a background agent
    /// stops: its status, result and totals (stdout's `task_notification` lacks the result).
    func taskNotification(_ entry: JSONValue) {
        guard let text = entry["message"]?["content"]?.string, text.contains("<task-notification>"),
            let id = Self.tag("tool-use-id", in: text)
        else { return }
        if finished[id] == nil {
            out.append(
                .agentProgress(
                    id: id,
                    AgentProgress(
                        tokens: Self.tag("subagent_tokens", in: text).flatMap { Int($0) },
                        tools: Self.tag("tool_uses", in: text).flatMap { Int($0) },
                        duration: Self.tag("duration_ms", in: text).flatMap { Int($0) }.map { .milliseconds($0) },
                        lastTool: nil)))
        }
        finishAgent(id, status: Self.tag("status", in: text), result: Self.tag("result", in: text))
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func agentStatus(_ status: String) -> AgentStatus? {
        switch status {
        case "completed", "success", "done": .completed
        case "failed", "error", "errored": .failed
        case "killed", "stopped", "cancelled", "canceled", "interrupted": .stopped
        default: nil  // running, pending
        }
    }

    // MARK: - Approvals

    private func approval(_ r: PermissionRequest) -> Approval {
        let agent = r.toolUseId.flatMap { toolAgent[$0] } ?? .main
        if r.toolName == "ExitPlanMode" {
            return Approval(
                id: r.id, title: "Ready to code?", detail: nil, body: nil, canAlwaysAllow: false,
                questions: [], plan: r.input["plan"]?.string ?? "", agent: agent)
        }
        if r.isQuestion {
            let questions = (r.input["questions"]?.array ?? []).map { q in
                let text = q["question"]?.string ?? ""
                return Approval.Question(id: text, text: text, options: ToolText.options(q["options"]))
            }
            return Approval(
                id: r.id, title: "", detail: nil, body: nil, canAlwaysAllow: false, questions: questions, agent: agent)
        }
        return Approval(
            id: r.id, title: "Allow \(r.toolName)?", detail: r.description,
            body: Self.summary(of: r.input, in: folder), canAlwaysAllow: !r.suggestions.isEmpty,
            questions: [], changes: Self.proposedChange(r.toolName, r.input).map { [$0] } ?? [], agent: agent)
    }

    /// The edit an Edit / Write approval asks about, shaped as the tool's own result would be.
    /// Edit's line numbers come from finding `old_string` in the file.
    static func proposedChange(_ tool: String, _ input: JSONValue) -> FileChange? {
        guard let path = input["file_path"]?.string else { return nil }
        switch tool {
        case "Write":
            let content = input["content"]?.string ?? ""
            return FileChange(claudeToolResult: ["type": "create", "filePath": .string(path), "content": .string(content), "structuredPatch": []])
        case "Edit":
            guard let old = input["old_string"]?.string, let new = input["new_string"]?.string else { return nil }
            var start = 1
            if let data = FileManager.default.contents(atPath: path), data.count < 2_000_000,
                let text = String(data: data, encoding: .utf8), let range = text.range(of: old)
            {
                start = text[..<range.lowerBound].count { $0 == "\n" } + 1
            }
            let removed = old.isEmpty ? [] : old.components(separatedBy: "\n").map { "-" + $0 }
            let added = new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+" + $0 }
            let hunk: JSONValue = [
                "oldStart": .number(Double(start)), "oldLines": .number(Double(removed.count)), "newStart": .number(Double(start)),
                "newLines": .number(Double(added.count)), "lines": .array((removed + added).map(JSONValue.string)),
            ]
            return FileChange(claudeToolResult: ["filePath": .string(path), "structuredPatch": [hunk]])
        default:
            return nil
        }
    }

    // MARK: - A sub-agent's transcript

    /// A sub-agent's own messages (`subagents/agent-<id>.jsonl`) as events of that agent. The
    /// first entry is the prompt it was given, which `AgentInfo` already holds.
    /// `live`: a running agent's new lines, kept apart from what stdout already gave. A card's
    /// full history (`live` false) is complete each time.
    func agentEntries(_ entries: [JSONValue], agent id: String, skippingPrompt: Bool, live: Bool) -> [ChatEvent] {
        let pending = out
        out = []
        reading = true
        deduplicating = live
        defer {
            out = pending
            reading = false
            deduplicating = true
        }
        for (index, entry) in entries.enumerated() {
            if skippingPrompt && index == 0 && entry["type"]?.string == "user" { continue }
            switch ClaudeEvent(message: entry) {
            case .assistant(_, let blocks, _, _): assistant(blocks, agent: .sub(id))
            case .user(let blocks, _, let result): toolResults(blocks, result, agent: .sub(id))
            default: break
            }
        }
        return out
    }

    // MARK: - Context

    private func context(_ usage: JSONValue) {
        let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            .compactMap { usage[$0]?.int }.reduce(0, +)
        guard used > 0 else { return }
        contextUsed = used
        // A replay reports only its last value (`replay`), at the end.
        if !replaying { reportContext(used, at: .now) }
    }

    /// The CLI's own count (`get_context_usage`): when it comes up, and after a compaction. Its
    /// `autoCompactThreshold` is the effective window (967,000 of haiku's 1,000,000).
    func contextReported(_ json: JSONValue) {
        guard let used = json["totalTokens"]?.int else { return }
        if let threshold = json["autoCompactThreshold"]?.int {
            contextWindow = threshold
        } else if let window = json["maxTokens"]?.int {
            contextWindow = Self.effectiveWindow(window, maxOutput: 0)
        }
        autoCompacts = json["isAutoCompactEnabled"]?.bool ?? autoCompacts
        contextUsed = used
        reportContext(used, at: .now)
    }

    /// The context's size before a compaction: stdout says `compact_metadata.pre_tokens`, the
    /// transcript `compactMetadata.preTokens`.
    static func preTokens(_ boundary: JSONValue) -> Int? {
        boundary["compact_metadata"]?["pre_tokens"]?.int ?? boundary["compactMetadata"]?["preTokens"]?.int
    }

    /// Whether the CLI compacted by itself: the boundary's `trigger` ("auto" / "manual").
    static func autoCompacted(_ boundary: JSONValue) -> Bool? {
        (boundary["compact_metadata"]?["trigger"] ?? boundary["compactMetadata"]?["trigger"])?.string.map { $0 == "auto" }
    }

    /// Claude's VS Code extension's `Wv0`: the window less the output reserve (at most 20k) and a
    /// 13k buffer. The CLI auto-compacts there.
    static func effectiveWindow(_ window: Int, maxOutput: Int) -> Int {
        window - min(maxOutput > 0 ? maxOutput : 20_000, 20_000) - 13_000
    }

    /// Sent only when something changed.
    private func reportContext(_ used: Int, at date: Date) {
        let usage = ContextUsage(used: used, window: contextWindow, autoCompacts: autoCompacts, at: date)
        if let last = reportedContext, last.used == usage.used, last.window == usage.window, last.autoCompacts == usage.autoCompacts {
            return
        }
        reportedContext = usage
        out.append(.contextUsage(usage))
    }

    // MARK: - Modes

    /// Kore asked the CLI for a mode; its status confirms it.
    func requestMode(_ id: String) { requestedMode = id }

    /// The CLI rejected the mode Kore asked for and kept its own.
    func modeRefused() {
        guard let asked = requestedMode else { return }
        requestedMode = nil
        guard let mode else { return }
        out.append(.modeChanged(ModeChange(mode: mode, previous: asked, source: .refused, at: .now)))
    }

    /// A live `system/status` mode: Kore's request, or the agent's plan-mode call before it.
    private func modeReported(_ reported: String) {
        let source: ModeSource
        if let asked = requestedMode, asked == reported {
            source = .user
            requestedMode = nil
        } else if let call = modeCall {
            source = .agent(call.tool == "EnterPlanMode" ? .enteredPlanMode : .planApproved, call.agent)
            modeCall = nil
        } else {
            source = .agent(.other, .main)  // not asked for by Kore: the CLI did it
        }
        setMode(reported, source, at: .now)
    }

    private func setMode(_ new: String, _ source: ModeSource, at date: Date) {
        guard !new.isEmpty, new != mode else { return }
        let previous = mode
        mode = new
        out.append(.modeChanged(ModeChange(mode: new, previous: previous, source: previous == nil ? .session : source, at: date)))
    }

    // MARK: - Replay off the main thread

    /// What a replay leaves for the live session: the mode, and the agents it may still hear
    /// about (a background agent finishing later) or open (their transcripts).
    struct Carried: Sendable {
        var mode: String?
        var toolAgent: [String: AgentID]
        var agentInputs: [String: JSONValue]
        var taskTool: [String: String]
        var spawned: Set<String>
        var finished: [String: Bool]
        var agentFiles: [String: String]
        var contextUsed: Int?
    }

    struct Replayed: Sendable {
        let events: [ChatEvent]
        let carried: Carried
    }

    /// Replays a transcript on a translator of its own, off the main thread: parsing a long
    /// history never blocks the UI. The live translator then `adopt`s what it leaves.
    static func replayed(_ messages: [JSONValue], folder: URL, sessionId: String?) async -> Replayed {
        await Task.detached(priority: .userInitiated) {
            let translator = ClaudeTranslator(folder: folder, sessionId: sessionId)
            let events = translator.replay(messages)
            return Replayed(events: events, carried: translator.carried)
        }.value
    }

    /// A sub-agent's transcript as events, off the main thread.
    static func agentHistory(_ entries: [JSONValue], agent id: String, folder: URL) async -> [ChatEvent] {
        await Task.detached(priority: .userInitiated) {
            ClaudeTranslator(folder: folder, sessionId: nil).agentEntries(entries, agent: id, skippingPrompt: true, live: false)
        }.value
    }

    private var carried: Carried {
        Carried(
            mode: mode, toolAgent: toolAgent, agentInputs: agentInputs, taskTool: taskTool, spawned: spawned,
            finished: finished, agentFiles: agentFiles, contextUsed: contextUsed)
    }

    /// Takes on a replay's state. `history` (an older page, prepended): only where its agents'
    /// transcripts are; the live mode and agents stay.
    func adopt(_ replayed: Carried, history: Bool = false) {
        agentFiles.merge(replayed.agentFiles) { live, _ in live }
        guard !history else { return }
        mode = replayed.mode ?? mode
        contextUsed = replayed.contextUsed ?? contextUsed
        // What the replay reported counts as reported.
        if let used = replayed.contextUsed { reportedContext = ContextUsage(used: used, window: nil, autoCompacts: nil, at: .now) }
        toolAgent.merge(replayed.toolAgent) { live, _ in live }
        agentInputs.merge(replayed.agentInputs) { live, _ in live }
        taskTool.merge(replayed.taskTool) { live, _ in live }
        spawned.formUnion(replayed.spawned)
        finished.merge(replayed.finished) { live, _ in live }
    }

    // MARK: - Replay

    /// A transcript (`ClaudeHistory.messages`) as events: turns open at each prompt (or peer
    /// message, cron firing, finished agent) and close before the next one, timed from the
    /// entries' timestamps.
    func replay(_ messages: [JSONValue]) -> [ChatEvent] {
        replaying = true
        defer {
            replaying = false
            modeCalls = [:]
        }
        // Leaving plan mode isn't recorded with its target; the next prompt's mode is it.
        var nextPromptMode = [String?](repeating: nil, count: messages.count)
        var upcoming: String?
        for index in messages.indices.reversed() {
            nextPromptMode[index] = upcoming
            if messages[index]["type"]?.string == "user", let mode = messages[index]["permissionMode"]?.string {
                upcoming = mode
            }
        }
        var lastAnswer: Date?
        func close() {
            guard turn != nil else { return }
            finishTurn(.completed, duration: lastAnswer.map { .seconds(max(0, $0.timeIntervalSince(turnStart))) })
            lastAnswer = nil
        }
        for (index, message) in messages.enumerated() {
            let time = Self.date(message["timestamp"]) ?? .now
            replayTime = time
            replayExitMode = nextPromptMode[index]
            if message["type"]?.string == "user", let prompted = message["permissionMode"]?.string, prompted != mode {
                // Each prompt records the mode it was sent in: a difference is a change between
                // turns (Kore's menu, or another client). Placed before the turn it applies to.
                close()
                setMode(prompted, .user, at: time)
            }
            if let peer = PeerMessage(entry: message) {
                close()
                openTurn(.peer, at: time)
                out.append(.peerMessage(from: peer.from, text: peer.text, turn: turn))
                continue
            }
            if ClaudeHistory.isBoundary(message) {
                close()
                out.append(.compacted(at: time, from: Self.preTokens(message), auto: Self.autoCompacted(message)))
                contextUsed = nil  // the last call before the compaction no longer describes it
                continue
            }
            if message["type"]?.string == "user", message["isCompactSummary"]?.bool == true {
                // Its compaction's summary, under the divider (as live), not a prompt of its own.
                if let text = Self.promptText(message["message"]?["content"]) ?? message["message"]?["content"]?.string {
                    out.append(.compactionSummary(text))
                }
                continue
            }
            if message["type"]?.string == "user" {
                if let origin = Self.origin(message["turnOrigin"]?.string), origin != .peer {
                    close()
                    openTurn(origin, at: time)
                    if origin == .agentFinished { taskNotification(message) }
                    continue
                }
                let content = message["message"]?["content"]
                let prompt = Self.promptText(content)
                let attachments = Self.attachments(content)
                if prompt != nil || !attachments.isEmpty {
                    close()
                    openTurn(.user, at: time)
                    // Its transcript id is where a fork from it starts.
                    out.append(.userMessage(text: prompt ?? "", attachments: attachments, id: message["uuid"]?.string))
                    continue
                }
            }
            translate(ClaudeEvent(message: message))
            if message["type"]?.string == "assistant" { lastAnswer = time }
        }
        close()
        block = nil
        if let used = contextUsed { reportContext(used, at: replayTime) }
        return take().events
    }

    static func origin(_ turnOrigin: String?) -> TurnOrigin? {
        switch turnOrigin {
        case "scheduled": .schedule
        case "task_notification": .agentFinished
        case "peer": .peer
        default: nil
        }
    }

    static func promptText(_ content: JSONValue?) -> String? {
        let text = content?.string ?? content?.array?.last { $0["type"]?.string == "text" }?["text"]?.string
        guard let text, !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    /// Image and document blocks of a user message.
    private static func attachments(_ content: JSONValue?) -> [SentAttachment] {
        (content?.array ?? []).compactMap { block in
            switch block["type"]?.string {
            case "image":
                let data = block["source"]?["data"]?.string.flatMap { Data(base64Encoded: $0) }
                return SentAttachment(name: "Image", kind: .image, url: nil, image: data)
            case "document":
                let isPDF = block["source"]?["media_type"]?.string == "application/pdf"
                return SentAttachment(name: block["title"]?.string ?? "Document", kind: isPDF ? .pdf : .text, url: nil, image: nil)
            default:
                return nil
            }
        }
    }

    /// ISO8601DateFormatter is thread-safe once configured (Apple's docs), so replays off the
    /// main thread share it.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ json: JSONValue?) -> Date? { json?.string.flatMap { iso.date(from: $0) } }

    // MARK: - Wording

    /// Tools that only read (the extension's "Explored" group).
    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS"]

    static func toolCall(_ id: String, _ name: String, _ input: JSONValue, in folder: URL) -> ToolCall {
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string
        let full: String? =
            switch name {
            case "Bash": input["command"]?.string
            case "Read":
                path.map { p in
                    guard let start = input["offset"]?.int else { return p }
                    guard let count = input["limit"]?.int else { return "\(p):\(start)" }
                    return "\(p):\(start)–\(start + count - 1)"
                }
            case "Grep", "Glob":
                input["pattern"]?.string.map { p in input["path"]?.string.map { "\(p)  in \($0)" } ?? p }
            case "Edit", "Write", "MultiEdit", "NotebookEdit": path
            case "WebFetch": input["url"]?.string
            case "WebSearch": input["query"]?.string
            default: input.pretty
            }
        return ToolCall(
            id: id, name: name, detail: summary(of: input, in: folder), input: full,
            description: input["description"]?.string, path: path, readOnly: readOnlyTools.contains(name))
    }

    /// The one input field worth showing for a tool call.
    static func summary(of input: JSONValue, in folder: URL) -> String {
        if let command = input["command"]?.string { return command }
        if let questions = input["questions"]?.array {  // AskUserQuestion
            return questions.compactMap { $0["question"]?.string }.joined(separator: " · ")
        }
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string {
            return ToolText.relative(path, in: folder)
        }
        for key in ["pattern", "url", "query", "description", "prompt"] {
            if let value = input[key]?.string { return value }
        }
        return String(input.compact.prefix(160))
    }

    static func text(of content: JSONValue) -> String {
        if let s = content.string { return s }
        return content.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? content.compact
    }
}

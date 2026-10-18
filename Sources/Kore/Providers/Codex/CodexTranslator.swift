import Foundation
import KoreCore

/// Turns Codex app-server notifications into `ChatEvent`s. A turn is a list of items, each
/// started → deltas → completed; sub-agents are child threads on the same connection, mapped
/// with `agent: .sub(threadId)`. `thread/resume` turns replay through the same item mapping.
@MainActor
final class CodexTranslator {
    let files: TurnFiles
    private let folder: URL
    private(set) var threadId: String?
    /// Plan mode is on: a finished plan offers "Implement this plan?".
    var planMode = false
    private var replaying = false

    private var out: [ChatEvent] = []
    private var changeTasks: [(TurnID, Task<[FileChange], Never>)] = []
    /// Approvals waiting on the user, by request id.
    private var pending: [String: CodexApproval] = [:]

    private var turn: TurnID?
    /// Per item: its phase (agentMessage), whether text or output streamed, its changes.
    private var phases: [String: String] = [:]
    private var streamedText: Set<String> = []
    private var streamedOutput: Set<String> = []
    private var itemChanges: [String: [FileChange]] = [:]
    /// The main thread's messages and tool items this turn, to find the final answer when the
    /// model doesn't mark it.
    private var turnItems: [TurnItem] = []
    private enum TurnItem { case message(String), tool }
    private var finalMarked = false
    private var replayChanges: [FileChange] = []

    // Sub-agents: child thread id → its running turn, tool count, state.
    private var childTurns: [String: String] = [:]
    private var childTools: [String: Int] = [:]
    private var spawned: Set<String> = []
    private var finished: Set<String> = []
    /// Each child's latest message: its result when it finishes.
    private var lastText: [String: String] = [:]

    init(folder: URL) {
        self.folder = folder
        files = TurnFiles(folder: folder)
    }

    func take() -> (events: [ChatEvent], changes: [(TurnID, Task<[FileChange], Never>)]) {
        defer {
            out = []
            changeTasks = []
        }
        return (out, changeTasks)
    }

    func request(_ id: String) -> CodexApproval? { pending.removeValue(forKey: id) }

    func childTurn(_ thread: String) -> String? { childTurns[thread] }

    // MARK: - Turns

    private func openTurn(_ id: TurnID, at date: Date) {
        turn = id
        turnItems = []
        finalMarked = false
        if replaying { replayChanges = [] } else { files.begin() }
        out.append(.turnStarted(id, origin: .user, at: date))
    }

    private func finishTurn(_ id: TurnID, _ outcome: TurnOutcome, duration: Duration?) {
        // Older models don't mark the final answer: the last message after the last tool.
        if !finalMarked {
            let lastTool = turnItems.lastIndex { if case .tool = $0 { true } else { false } }
            let after = turnItems[(lastTool.map { $0 + 1 } ?? 0)...]
            if let last = after.last(where: { if case .message = $0 { true } else { false } }),
                case .message(let item) = last
            {
                out.append(.finalAnswer(item))
            }
        }
        out.append(.turnFinished(id, outcome, duration: duration))
        if replaying {
            let changes = FileChange.mergedByPath(replayChanges)
            if !changes.isEmpty { out.append(.turnChanges(id, changes)) }
        } else {
            changeTasks.append((id, files.finish()))
        }
        turn = nil
        turnItems = []
    }

    // MARK: - Events

    func translate(_ event: CodexEvent, agent: AgentID = .main) {
        switch event {
        case .threadStarted(let id, _, _):
            threadId = id
            out.append(.sessionIdentified(id))
        case .turnStarted(let id):
            if case .sub(let thread) = agent {
                childTurns[thread] = id
            } else {
                openTurn(id, at: .now)
            }
        case .textDelta(let item, let text):
            guard !text.isEmpty else { return }
            if agent == .main, !finalMarked, phases[item] == "final_answer" {
                finalMarked = true
                out.append(.finalAnswer(item))
            }
            streamedText.insert(item)
            out.append(.text(item, .answer, text, agent: agent))
        case .reasoningDelta(let item, let text):
            guard !text.isEmpty else { return }
            streamedText.insert(item)
            out.append(.text(item, .thinking, text, agent: agent))
        case .planDelta(let item, let text):
            guard !text.isEmpty else { return }
            streamedText.insert(item)
            out.append(.text(item, .plan, text, agent: agent))
        case .commandOutputDelta(let item, let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { streamedOutput.insert(item) }
            out.append(.toolOutput(id: item, text, agent: agent))
        case .itemStarted(let item):
            itemStarted(item, agent: agent)
        case .itemCompleted(let item):
            itemCompleted(item, agent: agent)
        case .approvalRequest(let a):
            pending[a.id.compact] = a
            out.append(.approvalRequested(approval(a)))
        case .approvalResolved(let id):
            pending[id.compact] = nil
            out.append(.approvalWithdrawn(id.compact))
        case .turnCompleted(let result):
            if case .sub(let thread) = agent {
                childTurns[thread] = nil
                return
            }
            pending.removeAll()
            let outcome: TurnOutcome =
                switch result.status {
                case "interrupted": .interrupted
                case "failed": .failed(Self.cleanError(result.errorMessage ?? "Turn failed"))
                default: .completed
                }
            finishTurn(turn ?? result.turnId, outcome, duration: result.durationMs.map { .milliseconds($0) })
        case .raw(let method, let params):
            if method == "turn/diff/updated", agent == .main, let diff = params["diff"]?.string {
                files.setTurnDiff(UnifiedDiff.files(diff, root: folder))
            }
        case .subThread(let thread, let method, let params):
            let child = CodexEvent(notification: method, params: params)
            if !spawned.contains(thread) { spawn(thread, parent: .main, toolId: nil, name: nil, prompt: nil, model: nil) }
            translate(child, agent: .sub(thread))
        case .exited(let status):
            pending.removeAll()
            turn = nil
            out.append(.exited(status: status))
        case .error, .stderr:
            break
        }
    }

    private func itemStarted(_ item: CodexItem, agent: AgentID) {
        if let tool = tool(item) {
            out.append(.toolStarted(tool, agent: agent))
            if agent == .main { turnItems.append(.tool) }
            if case .sub(let thread) = agent, !replaying {
                childTools[thread, default: 0] += 1
                out.append(.agentProgress(id: thread, AgentProgress(tools: childTools[thread], lastTool: tool.name)))
            }
        }
        switch item.type {
        case "agentMessage":
            if let phase = item.raw["phase"]?.string { phases[item.id] = phase }
            if agent == .main { turnItems.append(.message(item.id)) }
        case "fileChange":
            itemChanges[item.id] = FileChange.codex(item.raw["changes"])
        case "subAgentActivity", "collabAgentToolCall":
            agentItem(item, agent: agent)
        default:
            break
        }
    }

    private func itemCompleted(_ item: CodexItem, agent: AgentID) {
        let failed = ["failed", "declined"].contains(item.status ?? "")
        switch item.type {
        case "plan":
            if !streamedText.contains(item.id), let text = item.text, !text.isEmpty {
                out.append(.text(item.id, .plan, text, agent: agent))
            }
            if planMode && agent == .main && !replaying { out.append(.planReady) }
        case "agentMessage":
            if case .sub(let thread) = agent, let text = item.text, !text.isEmpty { lastText[thread] = text }
            if !streamedText.contains(item.id), let text = item.text, !text.isEmpty {
                if agent == .main, !finalMarked, (item.raw["phase"]?.string ?? phases[item.id]) == "final_answer" {
                    finalMarked = true
                    out.append(.finalAnswer(item.id))
                }
                out.append(.text(item.id, .answer, text, agent: agent))
            }
            if agent == .main, !turnItems.contains(where: { if case .message(item.id) = $0 { true } else { false } }) {
                turnItems.append(.message(item.id))
            }
        case "commandExecution":
            let aggregated = item.raw["aggregatedOutput"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let output = streamedOutput.contains(item.id) ? nil : (!aggregated.isEmpty ? aggregated : "exit \(item.exitCode ?? 0)")
            let isError = (item.exitCode != nil && item.exitCode != 0) || failed
            out.append(.toolFinished(id: item.id, output: output, isError: isError, agent: agent))
        case "fileChange":
            let changes = FileChange.codex(item.raw["changes"])
            if !changes.isEmpty {
                out.append(.fileChanged(toolId: item.id, changes, agent: agent))
                if replaying { replayChanges += changes } else { files.record(changes) }
            }
            out.append(.toolFinished(id: item.id, output: item.status ?? "done", isError: failed, agent: agent))
        case "mcpToolCall", "webSearch":
            out.append(.toolFinished(id: item.id, output: item.status ?? "done", isError: failed, agent: agent))
        case "subAgentActivity", "collabAgentToolCall":
            agentItem(item, agent: agent)
        case "contextCompaction" where agent == .main:
            out.append(.compacted(at: .now))
        default:
            break
        }
        streamedText.remove(item.id)
        streamedOutput.remove(item.id)
        phases[item.id] = nil
    }

    /// A tool item worded for display; nil for items that aren't tools.
    private func tool(_ item: CodexItem) -> ToolCall? {
        switch item.type {
        case "commandExecution":
            let command = Self.command(item.raw) ?? item.command ?? ""
            // Codex parses each command: reads, searches and listings only count as exploring.
            let actions = item.raw["commandActions"]?.array ?? []
            let readOnly = !actions.isEmpty && actions.allSatisfy { ["read", "search", "listFiles"].contains($0["type"]?.string ?? "") }
            return ToolCall(id: item.id, name: "Run", detail: command, input: command, readOnly: readOnly)
        case "fileChange":
            let paths = (item.raw["changes"]?.array ?? []).compactMap { $0["path"]?.string }
            return ToolCall(
                id: item.id, name: "Edit", detail: paths.map { ToolText.relative($0, in: folder) }.joined(separator: ", "),
                input: paths.joined(separator: "\n"), path: paths.count == 1 ? paths[0] : nil)
        case "mcpToolCall":
            return ToolCall(
                id: item.id, name: "\(item.raw["server"]?.string ?? "mcp").\(item.raw["tool"]?.string ?? "tool")",
                detail: String((item.raw["arguments"]?.compact ?? "").prefix(160)), input: item.raw["arguments"]?.pretty)
        case "webSearch":
            let query = item.raw["query"]?.string ?? ""
            return ToolCall(id: item.id, name: "Search", detail: query, input: query)
        default:
            return nil
        }
    }

    // MARK: - Sub-agents

    /// `subAgentActivity` (what gpt-6-luna emits) and `collabAgentToolCall` (the schema's
    /// spawnAgent / wait / closeAgent) both describe child threads; either can come.
    private func agentItem(_ item: CodexItem, agent: AgentID) {
        let raw = item.raw
        if item.type == "subAgentActivity" {
            guard let thread = raw["agentThreadId"]?.string else { return }
            spawn(thread, parent: agent, toolId: item.id, name: raw["agentPath"]?.string, prompt: nil, model: nil)
            switch raw["kind"]?.string {
            case "completed": finish(thread, .completed)
            case "interrupted": finish(thread, .stopped)
            case "errored", "failed": finish(thread, .failed)
            default: break
            }
            return
        }
        let receivers = raw["receiverThreadIds"]?.array?.compactMap(\.string) ?? []
        if raw["tool"]?.string == "spawnAgent" {
            for thread in receivers {
                spawn(thread, parent: agent, toolId: item.id, name: nil, prompt: raw["prompt"]?.string, model: raw["model"]?.string)
            }
        }
        for (thread, state) in raw["agentsStates"]?.object ?? [:] {
            switch state["status"]?.string {
            case "completed": finish(thread, .completed)
            case "errored", "failed": finish(thread, .failed)
            case "interrupted", "shutdown", "closed": finish(thread, .stopped)
            default: break
            }
        }
    }

    private func spawn(_ thread: String, parent: AgentID, toolId: String?, name: String?, prompt: String?, model: String?) {
        guard spawned.insert(thread).inserted else { return }
        // An agent path like /root/count_lines names it.
        let shown = name.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "Agent"
        out.append(
            .agentSpawned(
                AgentInfo(
                    id: thread, parent: parent, toolId: toolId, name: shown, type: nil, model: model, prompt: prompt,
                    background: false)))
    }

    private func finish(_ thread: String, _ status: AgentStatus) {
        guard finished.insert(thread).inserted else { return }
        out.append(.agentFinished(id: thread, status, result: lastText[thread]))
    }

    // MARK: - Approvals

    private func approval(_ a: CodexApproval) -> Approval {
        let thread = a.params["threadId"]?.string
        let agent: AgentID = thread.map { $0 == threadId ? .main : .sub($0) } ?? .main
        func make(_ title: String, body: String? = nil, always: Bool = false, questions: [Approval.Question] = [],
                  changes: [FileChange] = []) -> Approval {
            Approval(
                id: a.id.compact, title: title, detail: a.reason, body: body, canAlwaysAllow: always,
                questions: questions, changes: changes, agent: agent)
        }
        switch a.kind {
        case .command:
            return make("Run command?", body: Self.command(a.params) ?? a.command, always: true)
        case .fileChange:
            let changes = a.itemId.flatMap { itemChanges[$0] } ?? []
            let body = changes.map { ToolText.relative($0.path, in: folder) }.joined(separator: ", ")
            return make("Apply file changes?", body: body.isEmpty ? nil : body, always: true, changes: changes)
        case .permissions:
            return make("Grant extra permissions?", body: a.params["permissions"]?.compact)
        case .mcpElicitation:
            return make("Allow MCP request?")
        case .userInput:
            let questions = a.questions.map { q in
                Approval.Question(
                    id: q["id"]?.string ?? "", text: q["question"]?.string ?? "", options: ToolText.options(q["options"]))
            }
            return make("", questions: questions)
        }
    }

    // MARK: - A sub-agent's thread

    /// A child thread's turns (`thread/read`) as events of that agent; its user messages are the
    /// instructions it was given.
    func agentTurns(_ turns: [JSONValue], agent thread: String) -> [ChatEvent] {
        let pending = out
        out = []
        replaying = true
        defer {
            out = pending
            replaying = false
        }
        for item in turns.flatMap({ $0["items"]?.array ?? [] }).map(CodexItem.init) where item.type != "userMessage" {
            itemStarted(item, agent: .sub(thread))
            itemCompleted(item, agent: .sub(thread))
        }
        return out
    }

    // MARK: - Replay

    /// `thread/resume` turns as events.
    func replay(_ turns: [JSONValue]) -> [ChatEvent] {
        replaying = true
        defer { replaying = false }
        for turn in turns {
            let id = turn["id"]?.string ?? ToolText.newID()
            openTurn(id, at: Self.date(turn["startedAt"]) ?? .now)
            for item in (turn["items"]?.array ?? []).map(CodexItem.init) {
                if item.type == "userMessage" {
                    let content = item.raw["content"] ?? []
                    let text = content.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
                    let attachments = Self.attachments(content)
                    // The turn's id is where a fork from this message starts.
                    if !text.isEmpty || !attachments.isEmpty { out.append(.userMessage(text: text, attachments: attachments, id: id)) }
                } else if item.type == "contextCompaction" {
                    // Its turn holds nothing else; resume keeps the turns before it.
                    out.append(.compacted(at: Self.date(turn["startedAt"]) ?? .now))
                } else {
                    itemStarted(item, agent: .main)
                    itemCompleted(item, agent: .main)
                }
            }
            let outcome: TurnOutcome =
                switch turn["status"]?.string {
                case "interrupted": .interrupted
                case "failed": .failed(Self.cleanError(turn["error"]?["message"]?.string ?? "Turn failed"))
                default: .completed
                }
            finishTurn(id, outcome, duration: turn["durationMs"]?.int.map { .milliseconds($0) })
        }
        return take().events
    }

    /// localImage / mention items of a user message.
    private static func attachments(_ content: JSONValue) -> [SentAttachment] {
        (content.array ?? []).compactMap { item in
            guard let path = item["path"]?.string, ["localImage", "mention"].contains(item["type"]?.string ?? "") else {
                return nil
            }
            let url = URL(fileURLWithPath: path)
            return SentAttachment(name: url.lastPathComponent, kind: Attachments.kind(of: url), url: url, image: nil)
        }
    }

    /// Codex times turns in Unix seconds (or milliseconds); ISO strings are taken too.
    private static func date(_ json: JSONValue?) -> Date? {
        if let n = json?.double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        return ClaudeTranslator.date(json)
    }

    // MARK: - Wording

    /// Codex wraps a shell command in `bash -lc`; `commandActions` carries the readable form.
    static func command(_ json: JSONValue) -> String? {
        if let actions = json["commandActions"]?.array, actions.count == 1, let c = actions[0]["command"]?.string {
            return c
        }
        return json["command"]?.string
    }

    /// Codex errors are often a JSON string like {"error":{"message":"..."}}.
    static func cleanError(_ raw: String) -> String {
        guard let json = try? JSONValue.parse(Data(raw.utf8)), let message = json["error"]?["message"]?.string else {
            return raw
        }
        return message
    }
}

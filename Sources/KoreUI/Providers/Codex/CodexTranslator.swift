import Foundation
import KoreCore

/// Turns Codex app-server notifications into `ChatEvent`s. A turn is a list of items, each
/// started → deltas → completed; sub-agents are child threads on the same connection, mapped
/// with `agent: .sub(threadId)`. A resumed thread's turns replay through the same item mapping.
package final class CodexTranslator {
    let files: TurnFiles
    private let folder: URL
    private(set) var threadId: String?
    /// Plan mode is on: a finished plan offers "Implement this plan?".
    var planMode = false
    /// The permissions preset last reported; nil until known. Codex changes modes only when a
    /// client asks (Kore, per turn): no agent switches them.
    private(set) var mode: String?
    private var planKnown = false
    /// Kore asked for the compaction now running (`compact()`); a compaction Codex starts by itself is auto.
    var compactRequested = false
    /// A request failed and Codex is trying it again (`error` with `willRetry`): said until the
    /// model streams.
    private var retrying = false
    private var compacting = false
    /// The context in use (`tokenUsage.last.totalTokens`) and the model's window.
    private var contextUsed: Int?
    private var contextWindow: Int?
    private var reportedContext: ContextUsage?
    private var replaying = false
    /// The model provider began recovering its login this turn and hasn't said it's done.
    private var authRecovering = false

    private var out: [ChatEvent] = []
    private var changeTasks: [(TurnID, Task<[FileChange], Never>)] = []
    /// Approvals waiting on the user, by request id.
    private var pending: [String: CodexApproval] = [:]

    private var turn: TurnID?
    /// The main thread's last item this turn: where a steered message lands.
    private var lastItem: String?
    /// Distinct user receipts in this turn, counted once across started/completed notifications.
    private var turnUserItems: Set<String> = []
    /// Messages Kore steered into the running turn, not yet taken (their `clientId` is Kore's id).
    var pendingSteer: Set<String> = []
    /// Requests still awaiting a transport reply. An earlier turn ending cannot drop them.
    private var queuedInFlight: Set<String> = []
    private var lastEndedTurn: String?
    /// A queued message sent with turn/start. It may instead join work already running.
    var nextTurnQueued: String?
    /// Per item: its phase (agentMessage), whether text or output streamed, its changes.
    private var phases: [String: String] = [:]
    private var streamedText: Set<String> = []
    private var streamedOutput: Set<String> = []
    /// What a running command printed in its turn, its last `inTurnTail` characters: a command
    /// that outlives the turn starts its row's output with it.
    private var inTurnOutput: [String: String] = [:]
    private static let inTurnTail = 16_384
    private var itemChanges: [String: [FileChange]] = [:]
    /// The main thread's messages and tool items this turn, to find the final answer when the
    /// model doesn't mark it.
    private var turnItems: [TurnItem] = []
    private enum TurnItem { case message(String), tool }
    private var finalMarked = false
    private var replayChanges: [FileChange] = []
    /// Replay: each recorded turn's changes (`TurnChangeLog`), by Codex turn id, decoded only
    /// for the turns replayed.
    private var recordedChanges: TurnChangeLog.Lookup?

    // Sub-agents: child thread id → its running turn, tool count, state.
    private var childTurns: [String: String] = [:]
    private var childTools: [String: Int] = [:]
    private var spawned: Set<String> = []
    private var finished: Set<String> = []
    /// Each child's spawning thread, and the children that outlived its turn (`outlived`).
    private var parents: [String: AgentID] = [:]
    private var background: Set<String> = []
    /// The `subAgentActivity` item that ended each child's latest run.
    private var finishedBy: [String: String] = [:]
    /// Children that have started a turn (or ran before this session): a later one is the child
    /// running again.
    private var childRan: Set<String> = []
    /// Each child's latest message: its result when it finishes.
    private var lastText: [String: String] = [:]
    /// Child threads' nicknames, roles and (in a replay) outcomes, which the backend looks up
    /// before the events that name them; `lookedUp` keeps it to once per thread.
    var agentThreads: [String: CodexAgentThread] = [:]
    private var lookedUp: Set<String> = []
    /// Where child threads' spawns and ends are logged (`AgentLog`). A replay logs none.
    var log: AgentLog = .shared
    /// Terminals that outlived their turn (`ActiveCommand`).
    private(set) var commands = CodexCommands()

    package init(folder: URL) {
        self.folder = folder
        files = TurnFiles(folder: folder)
    }

    /// Events waiting for `take`.
    var hasPending: Bool { !out.isEmpty }

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

    /// What only a running turn makes: an item, or streamed text.
    private static func isTurnWork(_ event: CodexEvent) -> Bool {
        switch event {
        case .itemStarted, .textDelta, .reasoningDelta, .planDelta: true
        default: false
        }
    }

    private func openTurn(_ id: TurnID, at date: Date) {
        turn = id
        lastItem = nil
        turnUserItems.removeAll()
        turnItems = []
        finalMarked = false
        if replaying { replayChanges = [] } else { files.begin() }
        out.append(.turnStarted(id, origin: .user, at: date))
    }

    private func finishTurn(_ id: TurnID, _ outcome: TurnOutcome, duration: Duration?) {
        if case .interrupted = outcome, !replaying { stopForeground() }
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
            // What Kore saw live (shell edits included) beats the turn's patch items.
            let changes = recordedChanges?.changes(id) ?? FileChange.mergedByPath(replayChanges)
            if !changes.isEmpty { out.append(.turnChanges(id, changes)) }
        } else {
            changeTasks.append((id, files.finish()))
        }
        turn = nil
        turnItems = []
    }

    // MARK: - Events

    func translate(_ event: CodexEvent, agent: AgentID = .main) {
        if retrying, agent == .main {
            switch event {
            case .textDelta, .reasoningDelta, .itemStarted, .turnCompleted:
                retrying = false
                out.append(.connection(.ok))
            default: break
            }
        }
        // The thread's work with no turn open: a turn Kore saw no start of (one already running
        // when Kore attached). One opens, so the chat is at work until turn/completed ends it.
        if agent == .main, turn == nil, !replaying, Self.isTurnWork(event) { openTurn(ToolText.newID(), at: .now) }
        switch event {
        case .threadStarted(let id, _, let raw):
            threadId = id
            out.append(.sessionIdentified(id))
            // Codex names a thread only when a client sets one (a rename, or the Codex app's own
            // generated title); until then the chat goes by its first prompt.
            if let name = Self.threadName(raw["thread"]?["name"]) { out.append(.titleChanged(name)) }
        case .turnStarted(let id):
            if case .sub(let thread) = agent {
                // A follow-up (followup_task, resume_agent) runs a child again as a turn of its own.
                if !childRan.insert(thread).inserted { resume(thread) }
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
        case .commandOutputDelta(let item, let text) where commands.isRow(item):
            // A terminal that outlived its turn: its output is the command's now, kept bounded.
            out.append(.commandOutput(id: item, text))
        case .commandOutputDelta(let item, let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { streamedOutput.insert(item) }
            if !replaying {
                let kept = inTurnOutput[item, default: ""] + text
                inTurnOutput[item] = kept.count > Self.inTurnTail ? String(kept.suffix(Self.inTurnTail)) : kept
            }
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
                if !replaying { commandsOutlived(agent: agent) }
                if result.status != "interrupted" { outlived(agent) }
                // One that outlived its parent's turn ends with its own: no item of the parent's
                // says so until the parent's next turn.
                if background.contains(thread) {
                    finish(
                        thread, result.status == "interrupted" ? .stopped : result.status == "failed" ? .failed : .completed,
                        source: .childTurn)
                }
                return
            }
            pending.removeAll()
            lastEndedTurn = result.turnId
            // A request awaiting its RPC reply may target the next turn instead.
            // Only accepted requests can be dropped by this turn ending.
            for id in pendingSteer.subtracting(queuedInFlight) { dropQueued(id, via: "turn-ended") }
            var outcome: TurnOutcome =
                switch result.status {
                case "interrupted": .interrupted
                case "failed": .failed(Self.cleanError(result.errorMessage ?? "Turn failed"))
                default: .completed
                }
            // The login was refused (a 401, or a recovery that never finished).
            if case .failed(let message) = outcome, CodexError.isUnauthorized(result.raw["turn"]?["error"]) || authRecovering {
                outcome = .authFailed(message)
            }
            if case .failed(let message) = outcome, let hit = PlanLimitHit.codex(result.raw["turn"]?["error"]) {
                outcome = .limited(message, resetsAt: hit.resetsAt)
            }
            authRecovering = false
            if compacting {
                // A compaction runs as a turn of its own: ending without its item completing is a
                // failure, said once, as "Couldn't compact: …" (its turn adds no line of its own).
                // `turn/interrupt` ends it "interrupted", its history not yet replaced (the
                // chat's Stop says it as stopped); one Codex started in the user's turn stops
                // that turn too.
                let ownTurn = compactRequested
                compacting = false
                compactRequested = false
                if result.status != "completed" {
                    out.append(.compactionFailed(Self.cleanError(result.errorMessage ?? "Compaction \(result.status)")))
                    if ownTurn || result.status != "interrupted" { outcome = .completed }
                }
            }
            finishTurn(turn ?? result.turnId, outcome, duration: result.durationMs.map { .milliseconds($0) })
            if outcome != .interrupted { outlived(.main) }
            commandsOutlived(agent: .main)
        case .raw(let method, let params):
            if method == "modelProvider/authRecoveryStarted" { authRecovering = true }
            if method == "modelProvider/authRecoveryCompleted" { authRecovering = false }
            if method == "thread/name/updated", agent == .main, let name = Self.threadName(params["threadName"]) {
                out.append(.titleChanged(name))
            }
            if method == "turn/diff/updated", agent == .main, let diff = params["diff"]?.string {
                files.setTurnDiff(UnifiedDiff.files(diff, root: folder))
            }
            // Sent as each turn starts, with the settings it runs under: Kore's own changes were
            // reported when made, so this adds only what differs (a relaunch in another preset).
            if method == "thread/settings/updated", agent == .main, let settings = CodexTurnSettings(params["threadSettings"] ?? .null) {
                apply(settings, .user, at: .now)
            }
            // A sub-agent's own count, as its card shows it: everything it has used so far.
            if method == "thread/tokenUsage/updated", case .sub(let thread) = agent, !replaying,
                let total = params["tokenUsage"]?["total"]?["totalTokens"]?.int
            {
                out.append(.agentProgress(id: thread, AgentProgress(tokens: total)))
            }
            // After each model call, and after a compaction: the context's size and the window.
            if method == "thread/tokenUsage/updated", agent == .main, let used = params["tokenUsage"]?["last"]?["totalTokens"]?.int {
                contextUsed = used
                contextWindow = params["tokenUsage"]?["modelContextWindow"]?.int ?? contextWindow
                reportContext(used, at: .now)
            }
        case .subThread(let thread, let method, let params):
            let child = CodexEvent(notification: method, params: params)
            if !spawned.contains(thread) { spawn(thread, parent: .main, toolId: nil, name: nil, prompt: nil, model: nil) }
            translate(child, agent: .sub(thread))
        case .exited(let status):
            pending.removeAll()
            for id in pendingSteer {
                SessionLog.shared.queue("dropped", "codex", chat: threadId, id: id, via: "exited")
                out.append(.queuedMessage(id: id, .dropped))
            }
            pendingSteer.removeAll()
            queuedInFlight.removeAll()
            nextTurnQueued = nil
            turn = nil
            commands.endAll(at: .now, into: &out)
            out.append(.exited(status: status))
        case .error(let message, let willRetry) where willRetry && agent == .main:
            // "stream disconnected - retrying turn (2/5 in 412ms)…": which try of how many.
            retrying = true
            let tries = Self.tries(message)
            out.append(.connection(.retrying(attempt: tries?.attempt, of: tries?.of)))
        case .error, .stderr:
            break
        }
    }

    /// "(2/5" in a Codex retry's message.
    static func tries(_ message: String) -> (attempt: Int, of: Int)? {
        guard let open = message.range(of: "("), let slash = message[open.upperBound...].firstIndex(of: "/"),
            let attempt = Int(message[open.upperBound..<slash])
        else { return nil }
        let rest = message[message.index(after: slash)...].prefix { $0.isNumber }
        return Int(rest).map { (attempt, $0) }
    }

    /// The turn ended: the commands it still runs become rows, their output so far with them.
    private func commandsOutlived(agent: AgentID) {
        let before = out.count
        commands.turnCompleted(agent: agent, folder: folder, at: .now, into: &out)
        for event in out[before...] {
            guard case .commandStarted(let command) = event, let printed = inTurnOutput.removeValue(forKey: command.id), !printed.isEmpty
            else { continue }
            out.append(.commandOutput(id: command.id, printed))
        }
    }

    private func itemStarted(_ item: CodexItem, agent: AgentID) {
        if !replaying { commands.started(item, agent: agent, at: .now) }
        if agent == .main, !replaying {
            if item.type == "userMessage" {
                // A steered message: Codex took it into the running turn.
                acknowledgeSteer(item, via: "item-started")
                return
            }
            lastItem = item.id
        }
        if item.type == "contextCompaction", agent == .main, !replaying {
            compacting = true
            out.append(.compactionStarted(auto: !compactRequested))
        }
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

    /// Register before writing. The RPC reply names the target but is not a delivery receipt.
    func queuedRequest(_ id: String, startsTurn: Bool = false) {
        pendingSteer.insert(id)
        queuedInFlight.insert(id)
        if startsTurn { nextTurnQueued = id }
    }

    func queuedAccepted(_ id: String, turn: String?) {
        queuedInFlight.remove(id)
        // Its receipt may already have arrived before the RPC resumed its caller.
        guard pendingSteer.contains(id), let turn, lastEndedTurn == turn else { return }
        dropQueued(id, via: "accepted-after-turn-ended")
    }

    func queuedRejected(_ id: String) {
        pendingSteer.remove(id)
        queuedInFlight.remove(id)
        if nextTurnQueued == id { nextTurnQueued = nil }
    }

    private func dropQueued(_ id: String, via: String) {
        queuedRejected(id)
        SessionLog.shared.queue("dropped", "codex", chat: threadId, id: id, via: via)
        out.append(.queuedMessage(id: id, .dropped))
    }

    private func acknowledgeSteer(_ item: CodexItem, via: String) {
        turnUserItems.insert(item.id)
        // Some versions use the supplied id directly; completed-only receipts count too.
        let candidates = [item.raw["clientId"]?.string, item.id].compactMap { $0 }
        guard let id = candidates.first(where: { pendingSteer.contains($0) }) else { return }
        // Only the matching user receipt proves this input arrived. A turn can start while
        // the request still waits for its snapshot, or belong to another client's input.
        let firstPrompt = nextTurnQueued == id && turnUserItems.count == 1 && lastItem == nil
        queuedRejected(id)  // clear transport bookkeeping; delivery is emitted below
        SessionLog.shared.queue("receipt", "codex", chat: threadId, id: id, via: via)
        if firstPrompt, let turn { out.append(.queuedMessage(id: id, .nextTurn(turn))) }
        else { out.append(.queuedMessage(id: id, .inTurn(after: lastItem))) }
    }

    private func itemCompleted(_ item: CodexItem, agent: AgentID) {
        if agent == .main, !replaying, item.type == "userMessage" { acknowledgeSteer(item, via: "item-completed") }
        let failed = ["failed", "declined"].contains(item.status ?? "")
        if !replaying { commands.completed(item, at: .now, into: &out) }
        inTurnOutput[item.id] = nil
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
            if failed, item.exitCode == -1 {
                // Killed by Stop (a thread read back gives these; live, nothing comes): stopped,
                // with what it printed before.
                if !streamedOutput.contains(item.id), !aggregated.isEmpty {
                    out.append(.toolOutput(id: item.id, aggregated, agent: agent))
                }
                out.append(.toolStopped(id: item.id, agent: agent))
                break
            }
            // A row's output after its turn went to the command, not its tool row.
            let output =
                streamedOutput.contains(item.id) || (commands.isRow(item.id) && !replaying)
                ? nil : (!aggregated.isEmpty ? aggregated : "exit \(item.exitCode ?? 0)")
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
            // Codex says nothing about who started it: automatic unless Kore asked.
            out.append(.compacted(at: .now, auto: !compactRequested))
            compacting = false
            compactRequested = false
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
            if let read = Self.fileRead(command, actions: actions, cwd: item.raw["cwd"]?.string ?? folder.path) {
                // A plain read of one file shows as Claude's Read does: the path, no output box.
                return ToolCall(
                    id: item.id, name: "Read", detail: ToolText.relative(read.path, in: folder),
                    input: read.range.map { "\(read.path):\($0)" } ?? read.path, path: read.path, readOnly: true)
            }
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
            case "completed": finish(thread, .completed, by: item.id, source: .agentItem)
            case "interrupted": finish(thread, .stopped, by: item.id, source: .agentItem)
            case "errored", "failed": finish(thread, .failed, by: item.id, source: .agentItem)
            default: break
            }
            return
        }
        let receivers = raw["receiverThreadIds"]?.array?.compactMap(\.string) ?? []
        if raw["tool"]?.string == "resumeAgent" {
            for thread in receivers where finished.contains(thread) { resume(thread) }
        }
        if raw["tool"]?.string == "spawnAgent" {
            for thread in receivers {
                spawn(thread, parent: agent, toolId: item.id, name: nil, prompt: raw["prompt"]?.string, model: raw["model"]?.string)
            }
        }
        for (thread, state) in raw["agentsStates"]?.object ?? [:] {
            switch state["status"]?.string {
            case "completed": finish(thread, .completed, source: .agentItem)
            case "errored", "failed": finish(thread, .failed, source: .agentItem)
            case "interrupted", "shutdown", "closed": finish(thread, .stopped, source: .agentItem)
            default: break
            }
        }
    }

    private func spawn(_ thread: String, parent: AgentID, toolId: String?, name: String?, prompt: String?, model: String?) {
        // A child's activity can name a thread above it (the chat's own, at agent path /root):
        // no agent of its own, and one that would never end.
        guard thread != threadId, !isAncestor(thread, of: parent) else { return }
        guard spawned.insert(thread).inserted else { return }
        parents[thread] = parent
        // Its nickname ("Hume") or role names it; else its task, from an agent path like
        // /root/count_lines. Beside the name goes what's left: the role, else the task.
        let info = agentThreads[thread]
        let task = name.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let shown = info?.nickname ?? info?.role ?? task ?? "Agent"
        let beside = info?.nickname != nil ? info?.role ?? task : info?.role != nil ? task : nil
        if !replaying { log.spawned("codex", chat: threadId, agent: thread, name: shown, background: false, parent: parent.sub) }
        out.append(
            .agentSpawned(
                AgentInfo(
                    id: thread, parent: parent, toolId: toolId, name: shown, type: beside, model: model, prompt: prompt,
                    background: false)))
    }

    private func isAncestor(_ thread: String, of agent: AgentID) -> Bool {
        var at = agent
        var seen: Set<String> = []
        while case .sub(let id) = at, seen.insert(id).inserted {
            if id == thread { return true }
            at = parents[id] ?? .main
        }
        return false
    }

    /// `by`: the activity item reporting it. Each run's end is an item of its own, so another
    /// one is a later run's (a replay has no child turns to say it ran again).
    private func finish(_ thread: String, _ status: AgentStatus, by item: String? = nil, source: AgentLog.Source, via: String? = nil) {
        if let item, let earlier = finishedBy.updateValue(item, forKey: thread), earlier != item {
            finished.remove(thread)
        }
        guard finished.insert(thread).inserted else { return }
        if !replaying {
            log.status("codex", chat: threadId, agent: thread, to: AgentLog.name(status), source: source, via: via)
        }
        // A replay carries no child messages: the result, tokens and time its rollout ended with.
        let info = agentThreads[thread]
        if info?.tokens != nil || info?.duration != nil {
            out.append(.agentProgress(id: thread, AgentProgress(tokens: info?.tokens, duration: info?.duration)))
        }
        out.append(.agentFinished(id: thread, status, result: lastText[thread] ?? info?.result))
    }

    func isFinished(_ thread: String) -> Bool { finished.contains(thread) }

    // MARK: - Commands

    /// A thread's `backgroundTerminals/list`.
    func terminalsListed(_ terminals: [JSONValue], owner: AgentID) { commands.listed(terminals, owner: owner, at: .now, into: &out) }

    /// Kore asked to terminate it: its kill is Kore's doing.
    func stopRequested(_ id: String) { commands.stopRequested(id) }

    func stopRefused(_ id: String) { commands.stopRefused(id) }

    /// `terminate` said it wasn't running any more.
    func commandGone(_ id: String) { commands.gone(id, at: .now, into: &out) }

    /// The app-server ends without an `.exited` (a relaunch): its terminals, and the messages
    /// steered or queued into it and not yet taken, end with it.
    func relaunched() {
        for id in pendingSteer { out.append(.queuedMessage(id: id, .dropped)) }
        pendingSteer.removeAll()
        queuedInFlight.removeAll()
        nextTurnQueued = nil
        commands.endAll(at: .now, into: &out)
    }

    /// Clear only the transport and work this app-server owned, retaining observed children.
    func accountStopped(observed: Set<String>) {
        for id in unfinishedAgents() where !observed.contains(id) {
            finish(id, .stopped, source: .accountSwitch)
        }
        pending.removeAll()
        pendingSteer.removeAll()
        queuedInFlight.removeAll()
        nextTurnQueued = nil
        turn = nil
        commands.endAll(at: .now, preserving: observed, state: .stopped(by: .user), into: &out)
        out.append(.exited(status: 0))
    }

    /// `parent`'s turn ended: the child threads it spawned that still run outlive it, and run on
    /// in the background, as a Claude agent run in the background does. One that finished within
    /// the turn stays where it is. Live and replayed alike: a child's end is an item of its
    /// parent's turn (`subAgentActivity`, a wait's states), so a replay sees it before the turn
    /// ends exactly when the live turn did.
    private func outlived(_ parent: AgentID) {
        for thread in spawned.subtracting(finished).sorted() where parents[thread] == parent {
            if background.insert(thread).inserted {
                out.append(.agentBackgrounded(id: thread))
                if !replaying { log.backgrounded("codex", chat: threadId, agent: thread) }
            }
        }
    }

    /// Child threads the history never saw end.
    func unfinishedAgents() -> [String] {
        spawned.subtracting(finished).sorted()
    }

    /// A child thread another client runs ended, as its rollout says: its last answer and
    /// totals come with it.
    func agentEnded(_ thread: String, _ status: AgentStatus, _ info: CodexAgentThread, source: AgentLog.Source, via: String? = nil) {
        guard spawned.contains(thread) else { return }
        agentThreads[thread] = info
        finish(thread, status, source: source, via: via)
    }

    /// A stopped turn stops the child threads it ran that hadn't outlived a turn, and theirs (the
    /// transcript shows them stopped with it); those in the background go on until they end.
    private func stopForeground() {
        let open = spawned.subtracting(finished).subtracting(background)
        var stopped: Set<String> = []
        var grew = true
        while grew {
            grew = false
            for thread in open.sorted() where !stopped.contains(thread) {
                let parent = parents[thread] ?? .main
                if parent == .main || parent.sub.map(stopped.contains) == true {
                    stopped.insert(thread)
                    grew = true
                }
            }
        }
        // Not marked finished: Codex may report one ending later (an item of the next turn).
        for thread in stopped.sorted() {
            log.status("codex", chat: threadId, agent: thread, to: "stopped", source: .turnInterrupt)
            out.append(.agentFinished(id: thread, .stopped, result: nil))
        }
    }

    private func resume(_ thread: String) {
        finished.remove(thread)
        finishedBy[thread] = nil
        out.append(.agentResumed(id: thread))
        if !replaying { log.resumed("codex", chat: threadId, agent: thread) }
    }

    /// Child threads this event names that haven't been looked up yet.
    func unseenAgents(in event: CodexEvent) -> [String] {
        let ids: [String] =
            switch event {
            case .itemStarted(let item), .itemCompleted(let item): Self.agents(in: item)
            case .subThread(let thread, _, _): [thread]
            default: []
            }
        return ids.filter { !spawned.contains($0) && lookedUp.insert($0).inserted }
    }

    /// Child threads a resumed thread's turns name.
    static func agents(in turns: [JSONValue]) -> [String] {
        turns.flatMap { $0["items"]?.array ?? [] }.flatMap { agents(in: CodexItem($0)) }
    }

    private static func agents(in item: CodexItem) -> [String] {
        switch item.type {
        case "subAgentActivity": item.raw["agentThreadId"]?.string.map { [$0] } ?? []
        case "collabAgentToolCall" where item.raw["tool"]?.string == "spawnAgent":
            item.raw["receiverThreadIds"]?.array?.compactMap(\.string) ?? []
        default: []
        }
    }

    // MARK: - Approvals

    /// One of request_user_input's questions, with its tab's `header`. Other only where it takes
    /// free text: `isOther`, read as true when it isn't sent.
    static func question(_ q: JSONValue) -> Approval.Question {
        Approval.Question(
            id: q["id"]?.string ?? "", text: q["question"]?.string ?? "", header: q["header"]?.string ?? "",
            options: ToolText.options(q["options"]), secret: q["isSecret"]?.bool ?? false, other: q["isOther"]?.bool ?? true)
    }

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
            var ask = make("Allow MCP request?")
            ask.signIn = true
            return ask
        case .userInput:
            return make("", questions: a.questions.map(Self.question))
        }
    }

    // MARK: - A sub-agent's thread

    /// A child thread's turns (`thread/read`) as events of that agent. Its instructions aren't
    /// among them (multi-agent v2 sends them encrypted); user messages are forked history.
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

    // MARK: - Context

    /// As the Codex extension shows it: `last.totalTokens` of the raw window. Codex doesn't say
    /// whether it compacts by itself. Sent only when something changed.
    private func reportContext(_ used: Int, at date: Date) {
        let usage = ContextUsage(used: used, window: contextWindow, autoCompacts: nil, at: date)
        if let last = reportedContext, last.used == usage.used, last.window == usage.window { return }
        reportedContext = usage
        out.append(.contextUsage(usage))
    }

    // MARK: - Modes

    /// The user picked a preset in Kore; Codex runs the next turn with it.
    func userChanged(mode id: String) { setMode(id, .user, at: .now) }

    /// The user picked a model: its window at once, before a turn on it reports one.
    func userChanged(window: Int) {
        contextWindow = window
        if let contextUsed { reportContext(contextUsed, at: .now) }
    }

    /// The user toggled Plan in Kore (the toggle or `/plan`).
    func userChanged(plan on: Bool) { setPlan(on, .user, at: .now) }

    private func apply(_ settings: CodexTurnSettings, _ source: ModeSource, at date: Date) {
        setMode(settings.permissions.rawValue, source, at: date)
        setPlan(settings.plan, source, at: date)
    }

    private func setMode(_ new: String, _ source: ModeSource, at date: Date) {
        guard new != mode else { return }
        let previous = mode
        mode = new
        out.append(.modeChanged(ModeChange(mode: new, previous: previous, source: previous == nil ? .session : source, at: date)))
    }

    private func setPlan(_ on: Bool, _ source: ModeSource, at date: Date) {
        guard !planKnown || on != planMode else { return }
        let first = !planKnown
        planKnown = true
        planMode = on
        out.append(.planModeChanged(PlanModeChange(on: on, source: first ? .session : source, at: date)))
    }

    // MARK: - Replay off the main thread

    /// What a replay leaves for the live session: the mode and plan toggle, and its agents.
    struct Carried: Sendable {
        var mode: String?
        var planMode: Bool
        var planKnown: Bool
        var spawned: Set<String>
        var finished: Set<String>
        var background: Set<String> = []
        var lastText: [String: String]
        var contextUsed: Int?
        var contextWindow: Int?
    }

    struct Replayed: Sendable {
        let events: [ChatEvent]
        let carried: Carried
    }

    /// Replays a page of turns (`thread/turns/list`) on a translator of its own, off the main thread.
    static func replayed(
        _ turns: [JSONValue], rollout: CodexRollout, folder: URL, agents: [String: CodexAgentThread] = [:]
    ) async -> Replayed {
        await Task.detached(priority: .userInitiated) {
            let translator = CodexTranslator(folder: folder)
            translator.agentThreads = agents
            translator.recordedChanges = TurnChangeLog.lookup(folder: folder)
            let context = rollout.lastTokens.map { (used: $0, window: rollout.contextWindow) }
            let events = translator.replay(turns, settings: rollout.turnSettings, context: context)
            return Replayed(
                events: events,
                carried: Carried(
                    mode: translator.mode, planMode: translator.planMode, planKnown: translator.planKnown,
                    spawned: translator.spawned, finished: translator.finished, background: translator.background,
                    lastText: translator.lastText, contextUsed: translator.contextUsed, contextWindow: translator.contextWindow))
        }.value
    }

    /// A child thread's turns as its card's events, on a translator of its own off the main
    /// thread: a child's history can be thousands of items.
    static func agentHistory(
        _ turns: [JSONValue], agent thread: String, folder: URL, agents: [String: CodexAgentThread]
    ) async -> Replayed {
        await Task.detached(priority: .userInitiated) {
            let translator = CodexTranslator(folder: folder)
            translator.agentThreads = agents
            let events = translator.agentTurns(turns, agent: thread)
            return Replayed(
                events: events,
                carried: Carried(
                    mode: nil, planMode: false, planKnown: false, spawned: translator.spawned, finished: translator.finished,
                    lastText: translator.lastText, contextUsed: nil, contextWindow: nil))
        }.value
    }

    /// `history`: an older page, which leaves the live mode, plan toggle and context alone.
    func adopt(_ replayed: Carried, history: Bool = false) {
        spawned.formUnion(replayed.spawned)
        finished.formUnion(replayed.finished)
        background.formUnion(replayed.background)
        // They ran in an earlier session: a turn of theirs now runs them again.
        childRan.formUnion(replayed.spawned)
        lastText.merge(replayed.lastText) { live, _ in live }
        guard !history else { return }
        if replayed.planKnown {
            planMode = replayed.planMode
            planKnown = true
        }
        mode = replayed.mode ?? mode
        contextUsed = replayed.contextUsed ?? contextUsed
        contextWindow = replayed.contextWindow ?? contextWindow
        // What the replay reported counts as reported (thread/resume sends the same count again).
        if let used = contextUsed { reportedContext = ContextUsage(used: used, window: contextWindow, autoCompacts: nil, at: .now) }
    }

    // MARK: - Replay

    /// Turns (`thread/turns/list`, oldest first) as events.
    /// `settings`: each turn's settings from the rollout (`CodexRolloutReader`), for the
    /// mode changes between turns.
    package func replay(_ turns: [JSONValue], settings: [String: CodexTurnSettings] = [:], context: (used: Int, window: Int?)? = nil) -> [ChatEvent] {
        replaying = true
        defer { replaying = false }
        for turn in turns {
            let id = turn["id"]?.string ?? ToolText.newID()
            let start = Self.date(turn["startedAt"]) ?? .now
            // A change between turns goes before the turn it applies to.
            if let settings = settings[id] { apply(settings, .user, at: start) }
            openTurn(id, at: start)
            var sawPrompt = false
            for item in (turn["items"]?.array ?? []).map(CodexItem.init) {
                if item.type == "userMessage" {
                    let content = item.raw["content"] ?? []
                    let text = content.array?.compactMap { $0["text"]?.string }.filter { !Attachments.isFileNote($0) }
                        .joined(separator: "\n") ?? ""
                    let attachments = Self.attachments(content)
                    // The turn's id is where a fork from its first message starts; a message steered
                    // into the turn later keeps its own item id.
                    let first = !sawPrompt
                    sawPrompt = true
                    if !text.isEmpty || !attachments.isEmpty {
                        out.append(.userMessage(text: text, attachments: attachments, id: first ? id : item.id))
                    }
                } else if item.type == "contextCompaction" {
                    // Its turn holds nothing else; resume keeps the turns before it.
                    out.append(.compacted(at: Self.date(turn["startedAt"]) ?? .now))
                } else {
                    itemStarted(item, agent: .main)
                    itemCompleted(item, agent: .main)
                    commands.replayed(item, turnStart: start, turnDuration: turn["durationMs"]?.int, owner: .main, folder: folder, into: &out)
                }
            }
            var outcome: TurnOutcome =
                switch turn["status"]?.string {
                case "interrupted": .interrupted
                case "failed": .failed(Self.cleanError(turn["error"]?["message"]?.string ?? "Turn failed"))
                default: .completed
                }
            // A compaction that failed keeps no item: its turn has no prompt and Codex's error names it.
            if case .failed(let message) = outcome, !sawPrompt,
                turn["error"]?["message"]?.string?.hasPrefix("Error running remote compact task") == true
                    || (turn["items"]?.array ?? []).contains(where: { $0["type"]?.string == "contextCompaction" })
            {
                out.append(.compactionFailed(message))
                outcome = .completed
            }
            finishTurn(id, outcome, duration: turn["durationMs"]?.int.map { .milliseconds($0) })
            // A turn another client still runs hasn't ended for its children either.
            if outcome != .interrupted, turn["status"]?.string != "inProgress" { outlived(.main) }
        }
        // The rollout's last token count: the fill when the chat was left.
        if let context {
            contextUsed = context.used
            contextWindow = context.window ?? contextWindow
            reportContext(context.used, at: Self.date(turns.last?["completedAt"]) ?? .now)
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
    static func date(_ json: JSONValue?) -> Date? {
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

    /// Programs whose plain use on one file only shows it.
    private static let readers: Set<String> = ["cat", "sed", "head", "tail", "nl"]

    /// The file (absolute) and line range a command only reads, when Codex parsed it as one
    /// read and the command is one reader on one file: no pipe, redirect or second command.
    static func fileRead(_ command: String, actions: [JSONValue], cwd: String) -> (path: String, range: String?)? {
        guard actions.count == 1, actions[0]["type"]?.string == "read", let path = actions[0]["path"]?.string,
            !path.isEmpty, command.rangeOfCharacter(from: CharacterSet(charactersIn: "|;&<>`$")) == nil
        else { return nil }
        let words = command.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        guard let program = words.first, readers.contains(program) else { return nil }
        // `sed` reads only with -n and a print range; anything else (-i, s///) changes or filters.
        if program == "sed", !(words.contains("-n") && words.contains { $0.hasSuffix("p") && $0.first?.isNumber == true }) {
            return nil
        }
        let absolute = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        // Codex reports `/tmp/…` where the folder is `/private/tmp/…`: resolve both the same way.
        return (realPath(absolute), lineRange(program, words))
    }

    /// "40–90" for `sed -n '40,90p'`, "1–20" for `head -n 20` / `head -20`.
    private static func lineRange(_ program: String, _ words: [String]) -> String? {
        switch program {
        case "sed":
            guard let spec = words.first(where: { $0.hasSuffix("p") && $0.first?.isNumber == true }) else { return nil }
            let bounds = spec.dropLast().split(separator: ",").compactMap { Int($0) }
            return bounds.count == 2 ? "\(bounds[0])–\(bounds[1])" : bounds.first.map(String.init)
        case "head":
            if let i = words.firstIndex(of: "-n"), i + 1 < words.count, let n = Int(words[i + 1]) { return "1–\(n)" }
            if let flag = words.first(where: { $0.hasPrefix("-") }), let n = Int(flag.dropFirst()) { return "1–\(n)" }
            return nil
        default:
            return nil
        }
    }

    /// A thread's name, when it has a usable one.
    static func threadName(_ json: JSONValue?) -> String? {
        guard let name = json?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// Codex errors often carry the API's JSON body: its message (`CodexError`).
    static func cleanError(_ raw: String) -> String { CodexError.readable(raw) }
}

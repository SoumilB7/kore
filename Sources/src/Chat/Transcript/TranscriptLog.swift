import Foundation
import KoreCore

/// The transcript's view side, as the log tells it of its changes: rows to build again, a fold
/// to keep in place, the send's own row, the chips of a message's files.
@MainActor
package protocol TranscriptLogView: AnyObject {
    /// The entry at `index` changed (nil: not known); drawn at the next frame.
    func changed(at index: Int?)
    /// Rows from `index` are due to be built again, with the next draw.
    func mark(_ index: Int?)
    /// Builds the changed rows now.
    func rebuild()
    /// Everything is built again on the next rebuild (entries shifted).
    func invalidateAll()
    /// The user turns above the shown window, counted again.
    func countHidden()
    /// A turn folded by itself: the view keeps its answer where it was.
    func announceFold(_ turn: String)
    /// A send waits for the CLI to take it (or no longer does).
    func sending(_ on: Bool, at date: Date)
    /// An agent's own work or details changed.
    func agentsChanged()
    /// A past session's history, before anything else.
    func replay(_ events: [ChatEvent])
    /// Earlier conversation can be read in (or not).
    func earlierHistory(_ available: Bool)
    /// A message's files, for its chips; `from`: the waiting message whose chips they are.
    func chips(_ files: [SentAttachment], for entry: UUID, from earlier: UUID?)
    /// A waiting message dropped: its chips go.
    func dropChips(_ entry: UUID)
}

/// The conversation as the CLI's events build it: entries in order (messages, text, tool
/// calls, agent cards, notices), grouped into turns, with each sub-agent's own work in its
/// lane. No rows and no drawing: its view (`TranscriptLogView`) builds those from it.
@MainActor
package final class TranscriptLog {
    package weak var view: (any TranscriptLogView)?
    /// How many agent marks there are: a new agent takes the next one no running agent has.
    package var agentShapes = 8

    package init() {}

    package struct Entry: Identifiable, Equatable {
        /// `divider`: a quiet line across the transcript ("Conversation compacted · 14:32",
        /// "Forked from …"), off the timeline.
        /// `mode`: a permission mode change (look.md §8): the user's is a divider between turns,
        /// the agent's (with `modeLead`) an item on its turn's timeline.
        /// `summary`: what a compaction left (Claude), under its divider, off the timeline.
        package enum Kind: Equatable { case user, answer, thinking, plan, tool, agent, notice, peer, divider, mode, summary }

        package let id = UUID()
        package var kind: Kind
        package var text: String
        package var toolName: String?
        package var toolId: String?
        /// A tool's full input (the IN box), its header text, and the file it works on.
        package var input: String?
        package var summary: String?
        package var path: String?
        package var result: String?
        package var done = false
        package var isError = false
        package var attachments: [SentAttachment] = []
        /// Who sent a `.peer` message.
        package var from: String?
        /// Files an edit tool changed.
        package var changes: [FileChange] = []
        /// Set for `.agent`: the sub-agent this card stands for.
        package var agent: AgentInfo?
        /// The turn the entry belongs to; nil for the user's own message.
        package var turn: String?
        /// Thinking: when it began, and how long it took once the next block started.
        package var startedAt: Date?
        package var duration: TimeInterval?
        /// A tool that only reads, searches or lists (grouped into "Explored N").
        package var readOnly = false
        /// A tool call cut off by Stop: no output, a muted dot.
        package var stopped = false
        /// `.mode`: the mode it became (or, for "Left", the one left), and the agent's words
        /// before it ("Entered", "Plan approved ·", "Left"); nil words: the user's divider.
        package var mode: ModeMark?
        package var modeLead: String?
        /// A user's divider: the mode before this run of changes (back on it, the divider goes).
        package var modeFrom: String?
        /// A notice with a warning dot (a mode the CLI refused).
        package var warning = false
        /// A user message the CLI took into a running turn (look.md §10): it doesn't open a section.
        package var inTurn = false
        /// A user's or peer's message's id in its CLI's history (where a fork or a rollback finds
        /// it); for one sent in this run, the id Kore sent it with. `forkSource` on a fork's
        /// "Forked from" line.
        package var source: String?
        /// Kore's own row, in no CLI's history: it can't be read back (`unloadPoint`).
        package var local = false

        package static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.kind == b.kind && a.text == b.text && a.result == b.result && a.done == b.done
                && a.isError == b.isError && a.stopped == b.stopped && a.toolName == b.toolName && a.from == b.from
                && a.mode == b.mode && a.modeLead == b.modeLead && a.warning == b.warning
                && a.changes == b.changes && a.agent == b.agent && a.input == b.input && a.summary == b.summary
                && a.duration == b.duration
        }
    }

    package struct AgentInfo: Equatable {
        package enum Status: Equatable { case running, finished, failed, stopped }
        package let id: String
        /// Spawn order in the chat: picks the agent's mark.
        package let index: Int
        package var name: String
        package var type: String?
        package var model: String?
        /// What it was asked to do.
        package var prompt: String?
        /// The agent that spawned it; nil for the chat's own agent.
        package var parent: String?
        /// A background agent: a Claude one's commands aren't on stdout; a Codex child thread
        /// outlived its parent's turn.
        package var background = false
        package var status = Status.running
        /// Approvals it's waiting on the user for.
        package var waiting = 0
        package var startedAt: Date
        package var duration: TimeInterval?
        package var tokens: Int?
        /// `tokens` were read from its transcript, not reported: "~239k".
        package var approximate = false
        package var tools = 0
        package var lastTool: String?
        package var result: String?
    }

    /// `authFailed`: the CLI's login was refused, in its own words. `slept`: it failed while the
    /// Mac slept, the CLI's line kept for the hover.
    package enum Outcome: Equatable { case completed, interrupted, failed(String), authFailed(String), slept(String) }

    package struct Turn {
        package let id: String
        package var startedAt: Date
        package var duration: TimeInterval?
        package var finished = false
        package var outcome = Outcome.completed
        /// Where the answer starts (Codex's first final-answer text). Unset, it's found when
        /// the turn finishes: the text after the turn's last piece of work.
        package var answerFrom: UUID?
        /// When the answer began, for the fold's label while the answer still streams.
        package var workEnded: Date?
        package var changes: [FileChange] = []
        /// The fold's open state once the user has set it; until then it's open while the turn
        /// works and closed once its answer starts.
        package var open = false
        package var touched = false
        package var denied = 0
        /// What the live fold row last said ("Running Bash…"); it stays until the next state.
        package var liveLabel: String?
        /// The mode it started in, and the one the agent last switched to during it.
        package var startMode: String?
        package var endMode: String?
        /// The entry before it began: where it shows when it has none of its own.
        package var after: UUID?
        /// The model's safeguards refused it (a failed turn).
        package var refusal: Refusal?
    }

    /// When the user last sent a message (live, not replayed): the view glides to the end for
    /// 2s after it, as the extension does.
    package var sentAt: Date?

    /// Local delivery is waiting for the CLI to acknowledge a real turn. Never replayed.
    package var pendingSendSince: Date?

    /// Cards of agents whose turns left memory: the map still lists them.
    package var parkedAgents: [String: AgentInfo] = [:]

    /// Agents whose own work was looked at: it stays when their turn leaves (an agent tab may show it).
    package var keptLanes: Set<String> = []

    /// The changes last read, for a modal open on a turn that left memory.
    package var changesRead: (turn: String, changes: [FileChange])?

    /// The latest turn's tools changed, so `fileTouches` is due again.
    package var touchesDirty = false

    /// The newest finished turn with an answer: its final answer's actions always show.
    package var lastAnswerTurn: String?

    /// Each turn's first entry. A turn can span sections (a message sent while it ran lands in
    /// the middle of it), so a change to the turn marks from here.
    package var turnFirst: [String: UUID] = [:]

    /// Turns that failed before they wrote anything (a refused login, a plan's limit, a sleep):
    /// their notice shows after the entry before them.
    package var refusedTurns: [String] = []

    /// Pending approvals of this chat: id → it's a question (AskUserQuestion, Codex user input).
    package var pendingApprovals: [String: Bool] = [:]

    /// A compaction is running, since when (the live row says "Compacting…"), and the point it
    /// was started at when Kore started it by itself (auto-compact).
    package var compactingSince: Date?

    /// The running turn's connection, said on its spinner while it isn't fine.
    package var connection = Connection.ok

    package var compactingAt: Int?

    /// The most recently started turn, for `turnChanges()`.
    package var latestTurn: String?

    package var retryDismissed: String?

    package var entries: [Entry] = []

    package var position: [UUID: Int] = [:]

    /// An entry's place in the chat (its index in `entries`); nil once it has gone.
    package func index(of id: UUID) -> Int? { position[id] }

    package var turns: [String: Turn] = [:]

    package var current: String?

    /// Only a live acknowledgement may create the otherwise empty working row.
    package var liveTurn: String?

    package var liveSendSince: Date?

    package var blocks: [String: UUID] = [:]

    package var tools: [String: UUID] = [:]

    /// Each sub-agent's own entries, keyed by agent id.
    package var lanes: [String: [Entry]] = [:]

    package var laneTools: [String: (agent: String, index: Int)] = [:]

    package var agentCards: [String: UUID] = [:]

    package var batching = false

    /// For notices: "Claude exited (1)".
    package var providerName = "The CLI"

    /// Cards of agents spawned by other sub-agents, in their parent's lane.
    package var laneAgents: [String: (parent: String, entry: UUID)] = [:]

    /// Every agent id in spawn order.
    package var agentOrder: [String] = []

    /// Agents whose history has been loaded (once is enough).
    package var loadedAgents: Set<String> = []

    package var loadingHistory = false

    /// Pending approvals asked for by sub-agents: approval id → agent id.
    package var askedBy: [String: String] = [:]

    /// When the chat's first turn began, and the time its finished turns took.
    package var workedBefore: TimeInterval = 0

    package var turnIsOpen: Bool { current.map { turns[$0]?.finished == false } ?? false }

    /// A past session's agents ended with its CLI. One the transcript never saw finish (a
    /// background agent whose turn completed without it) shows as stopped, not running, and so
    /// do its open calls and child agents, unless its own files say it still runs (another
    /// client's): the backend runs it on (`agentResumed`). A stopped turn's agents are closed
    /// by `turnFinished`. `from`: the first of the agents to look at, in spawn order.
    package func endUnfinishedAgents(from first: Int = 0) {
        for id in agentOrder[min(first, agentOrder.count)...] where agent(id)?.status == .running {
            updateAgent(id) { $0.status = .stopped }
            stopLane(id)
        }
    }

    /// A compaction is running: the live row says "Compacting…" (look §9), the running turn's
    /// or, when no turn shows one, a row of its own at the end, where its divider lands. `point`:
    /// Kore started it at the chat's auto-compact point.
    package func compacting(_ on: Bool, at point: Int? = nil) {
        guard (compactingSince != nil) != on else { return }
        compactingSince = on ? Date() : nil
        compactingAt = on ? point : nil
        changed(turn: turnShowsSpinner ? current : nil)
    }

    /// What the running turn's spinner says of its connection; nil when fine.
    package var connectionWord: String? { connection.word }

    /// The running turn has a tool or an agent at work: a quiet CLI is busy, not stalled.
    package var workRunning: Bool {
        guard let current else { return false }
        return entries.suffix(400).contains { $0.turn == current && (($0.kind == .tool && !$0.done) || $0.agent?.status == .running) }
    }

    /// The running turn's connection: its spinner says "Offline · …", "Connection unstable · …"
    /// or "No response · …" while it isn't fine, and goes back to its own word once it is.
    package func connected(_ state: Connection) {
        guard state != connection else { return }
        connection = state
        changed(turn: turnShowsSpinner ? current : nil)
    }

    /// The running turn draws its spinner: it has rows (a compaction's own turn has none).
    package var turnShowsSpinner: Bool { turnIsOpen && current.flatMap { turnFirst[$0] } != nil }

    /// "Conversation compacted · 14:32" above the summary that follows, in place of the live row.
    /// The divider names who started it: "Conversation compacted · 14:32" (the user, or not
    /// known), "Compacted automatically · 14:32" (the CLI), "Compacted at 80% · 14:32" (Kore, at
    /// the chat's point).
    package func compacted(at date: Date, auto: Bool? = nil) {
        let cause =
            if let point = compactingAt { "Compacted at \(point)%" }
            else { auto == true ? "Compacted automatically" : "Conversation compacted" }
        compacting(false)
        append(Entry(kind: .divider, text: cause + " · " + Self.time.string(from: date)))
    }

    /// "Couldn't compact: …", one line, in place of the live row.
    package func compactionFailed(_ reason: String) {
        compacting(false)
        notice("Couldn't compact: " + (reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason), isError: true)
    }

    /// What the compaction kept (Claude's summary), under its divider.
    package func compactionSummary(_ text: String, title: String? = nil) {
        var entry = Entry(kind: .summary, text: text)
        entry.result = title
        append(entry)
    }

    /// After a fork's history: "Forked from "Refactor theme tokens"".
    package func forkedFrom(_ title: String) {
        var entry = Entry(kind: .divider, text: "Forked from \u{201C}\(title)\u{201D}", source: Self.forkSource)
        entry.local = true
        append(entry)
    }

    /// After an imported chat's carried part: "Continued in Codex · gpt-6-luna · 24 Oct". The
    /// fork's line, so it reads and behaves as one.
    package func continued(_ text: String, help: String) {
        var entry = Entry(kind: .divider, text: text, source: Self.forkSource)
        entry.result = help
        append(entry)
    }

    /// Above an imported chat's oldest carried turn, when older ones weren't carried and no
    /// summary of theirs was: "Carried to Codex from here", what was left out in its help.
    package func carriedFrom(_ text: String, help: String) {
        var entry = Entry(kind: .divider, text: text)
        entry.result = help
        append(entry)
    }

    package static let forkSource = "fork"

    /// The turn id of a compaction's own live row.
    package static let compactionRow = "compaction"

    package static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    package func turnStarted(_ id: String, at date: Date = Date()) {
        if !batching {
            // The former current turn may have a cached spinner in an older section.
            if let current, current != id { mark(turnIndex(current)) }
            if let latestTurn, latestTurn != id { mark(turnIndex(latestTurn)) }
            liveTurn = id
            liveSendSince = pendingSendSince
            sending(false)
        }
        turns[id] = Turn(id: id, startedAt: date, startMode: effectiveMode, after: entries.last?.id)
        current = id
        latestTurn = id
        touchesDirty = true
        changed(at: entries.count - 1)
    }

    /// Codex: the final answer has begun, so the work above it folds now.
    package func finalAnswer(block: String) {
        guard let entry = blocks[block], let turn = entries[position[entry]!].turn, turns[turn]?.answerFrom == nil
        else { return }
        turns[turn]?.answerFrom = entry
        turns[turn]?.workEnded = Date()
        announceFold(turn)
        changed(turn: turn)
    }

    package func turnFinished(_ id: String?, _ outcome: Outcome, duration: TimeInterval? = nil, at date: Date = Date(), preserving observed: Set<String> = []) {
        if !batching {
            connection = .ok
            sending(false)
        }
        guard let id = id ?? current, var turn = turns[id] else { return }
        endThinking()
        // A page of earlier history read in says nothing of what's waiting now.
        if !batching {
            settleAll()
            pendingApprovals.removeAll()
        }
        // Its text has stopped streaming; after a stop, calls and agents the CLI never closed
        // (Codex sends nothing more for them) end as stopped. Replayed turns too.
        let interrupted = outcome == .interrupted
        let abandoned = outcome != .completed
        var answered = false
        for i in (turnIndex(id) ?? entries.count)..<entries.count where entries[i].turn == id {
            switch entries[i].kind {
            case .answer:
                entries[i].done = true
                answered = true
            case .tool where abandoned && !entries[i].done:
                entries[i].done = true
                entries[i].stopped = true
            case .agent where interrupted && entries[i].agent?.status == .running
                && entries[i].agent.map({ !observed.contains($0.id) }) == true:
                entries[i].agent?.status = .stopped
                // Live, it ran until now; a replayed one has no true end, so its meter says "stopped".
                if !batching, entries[i].agent?.duration == nil, let start = entries[i].agent?.startedAt {
                    entries[i].agent?.duration = date.timeIntervalSince(start)
                }
                if let agent = entries[i].agent?.id { stopLane(agent, at: batching ? nil : date, preserving: observed) }
            default:
                break
            }
        }
        turn.finished = true
        // A replayed turn's outcome isn't announced again (replay never showed it), except a
        // stop, so a stopped turn reads the same as it did live ("· Interrupted").
        turn.outcome = batching && outcome != .interrupted ? .completed : outcome
        // A replayed turn without the CLI's own measure has none: it reads "N previous messages".
        turn.duration = duration ?? (batching ? nil : date.timeIntervalSince(turn.startedAt))
        let hadAnswer = turn.answerFrom != nil
        turns[id] = turn
        if answered, lastAnswerTurn != id {
            // The older answer's actions stop showing always: its section is built again.
            if let old = lastAnswerTurn { mark(turnIndex(old)) }
            lastAnswerTurn = id
        }
        if current == id { current = nil }
        if liveTurn == id { (liveTurn, liveSendSince) = (nil, nil) }
        if !turnIsOpen, let held = heldModeChange {
            heldModeChange = nil
            userChanged(from: held.from, to: held.to)
        }
        workedBefore += turn.duration ?? 0
        if !hadAnswer { announceFold(id) }
        switch turn.outcome {
        case .authFailed, .slept, .failed: if turnFirst[id] == nil { refusedTurns.append(id) }
        case .completed, .interrupted: break
        }
        changed(turn: id)
    }

    package func turnChanges(_ id: String, _ changes: [FileChange]) {
        turns[id]?.changes = changes
        touchesDirty = true
        changed(turn: id)
    }

    package func changes(ofTurn id: String) -> [FileChange] {
        guard let turn = turns[id] else { return changesRead?.turn == id ? changesRead?.changes ?? [] : [] }
        changesRead = (id, turn.changes)
        return turn.changes
    }

    /// The latest turn ended because the Mac slept (the link's Continue).
    package var latestTurnSlept: Bool {
        guard let id = latestTurn, let turn = turns[id], case .slept = turn.outcome else { return false }
        return true
    }

    /// Claude frames a sub-agent's report with a first line of its own; the report is the rest.
    package static func handBack(_ output: String) -> String {
        guard output.hasPrefix("[Subagent hand-back]"), let newline = output.firstIndex(of: "\n") else { return output }
        return String(output[output.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A sub-agent asked the user for something.
    package func agentAsked(_ approval: String, agent: String) {
        askedBy[approval] = agent
        updateAgent(agent) { $0.waiting += 1 }
    }

    /// The CLI waits on the user: the live fold row says so, and the spinner hides.
    package func approvalAsked(_ approval: String, question: Bool) {
        pendingApprovals[approval] = question
        changed(turn: current)
    }

    /// The question was answered or withdrawn.
    package func approvalSettled(_ approval: String) {
        if pendingApprovals.removeValue(forKey: approval) != nil { changed(turn: current) }
        guard let agent = askedBy.removeValue(forKey: approval) else { return }
        updateAgent(agent) { $0.waiting = max(0, $0.waiting - 1) }
    }

    package func settleAll() {
        for approval in Array(askedBy.keys) { approvalSettled(approval) }
    }

    /// Time spent working across the chat's turns, the running one included.
    package var workedFor: TimeInterval {
        let running = current.flatMap { turns[$0] }.map { Date().timeIntervalSince($0.startedAt) } ?? 0
        return workedBefore + running
    }

    /// The agent a card key ("entry id") stands for, if it's an agent's card.
    package func agentID(forCard key: String) -> String? {
        guard let id = UUID(uuidString: key) else { return nil }
        if let i = position[id], let agent = entries[i].agent { return agent.id }
        return laneAgents.first { $0.value.entry == id }?.key
    }

    /// Its own work was opened: it's kept when its turn leaves memory.
    package func keepLane(of id: String) { keptLanes.insert(id) }

    /// An agent whose own work isn't here yet: from a replayed chat, or a Codex child.
    package func needsHistory(_ id: String) -> Bool {
        guard let info = agent(id), info.status != .running, !loadedAgents.contains(id) else { return false }
        return (lanes[id] ?? []).isEmpty
    }

    package func lane(_ id: String) -> [Entry] { lanes[id] ?? [] }

    /// A sub-agent's card details, for an approval it asks for.
    package func agent(_ id: String) -> AgentInfo? {
        if let card = agentCards[id], let i = position[card] { return entries[i].agent }
        if let (parent, card) = laneAgents[id], let found = lanes[parent]?.first(where: { $0.id == card })?.agent { return found }
        return parkedAgents[id]
    }

    /// `chipsFrom`: the waiting message it was, whose chips it keeps.
    package func user(_ text: String, attachments: [SentAttachment], source: String? = nil, chipsFrom earlier: UUID? = nil) {
        if let latestTurn { retryDismissed = latestTurn; mark(turnIndex(latestTurn)) }
        if !batching { sentAt = Date() }
        var entry = Entry(kind: .user, text: text, attachments: attachments)
        entry.source = source
        if !attachments.isEmpty { view?.chips(attachments, for: entry.id, from: earlier) }
        append(entry)
        // Sending is drawn at once (the view scrolls to it).
        if !batching { rebuild() }
    }

    /// A peer's message, placed where its turn began.
    package func peer(from: String, text: String, turn: String?, source: String? = nil) {
        var entry = Entry(kind: .peer, text: text, from: from)
        entry.turn = turn
        entry.source = source
        if let turn, let first = entries.firstIndex(where: { $0.turn == turn }) {
            insert(entry, at: first)
        } else {
            append(entry)
        }
    }

    package enum TextKind { case answer, thinking, plan }

    /// Appends to a text block, starting it if the id is new.
    package func text(_ block: String, _ kind: TextKind, _ text: String, agent: String? = nil) {
        let kind: Entry.Kind = switch kind {
        case .answer: .answer
        case .thinking: .thinking
        case .plan: .plan
        }
        if let agent {
            laneText(agent: agent, block: block, kind: kind, text: text)
            return
        }
        if let id = blocks[block], let i = position[id] {
            entries[i].text += text
            changed(at: i)
        } else {
            endThinking()
            endAnswer()
            var entry = Entry(kind: kind, text: text)
            entry.turn = current
            if kind == .thinking { entry.startedAt = Date() }
            blocks[block] = entry.id
            append(entry)
        }
    }

    package func toolStarted(
        id: String, name: String, detail: String, input: String? = nil, summary: String? = nil, path: String? = nil,
        readOnly: Bool = false, agent: String? = nil
    ) {
        var entry = Entry(kind: .tool, text: detail, toolName: name, toolId: id)
        entry.readOnly = readOnly
        // Most commands' input is their detail; keep one copy.
        entry.input = input == detail ? nil : input
        entry.summary = summary
        entry.path = path
        if agent == nil {
            endThinking()
            endAnswer()
        }
        if let agent {
            laneAppend(agent: agent, entry)
            laneTools[id] = (agent, lanes[agent]!.count - 1)
            if !loadingHistory, let card = agentCards[agent], let i = position[card], entries[i].agent != nil {
                entries[i].agent!.tools += 1
                entries[i].agent!.lastTool = name
            }
            touchesDirty = true
            changed(at: cardIndex(agent))
            return
        }
        entry.turn = current
        tools[id] = entry.id
        append(entry)
    }

    package func toolOutput(id: String, _ text: String) {
        update(tool: id, files: false) { $0.result = ($0.result ?? "") + text }
    }

    /// `output` nil keeps what streamed. On an agent's spawning call (Claude's foreground Agent
    /// tool) the output is the agent's report, which becomes its result.
    package func toolFinished(id: String, output: String?, isError: Bool) {
        if let card = tools[id], let i = position[card], entries[i].agent != nil {
            if entries[i].agent!.result == nil, let output { entries[i].agent!.result = Self.handBack(output) }
            changed(at: i)
            return
        }
        update(tool: id) {
            if let output { $0.result = output }
            $0.done = true
            $0.isError = isError
        }
    }

    /// An agent's open calls end as stopped, and its own agents with them. `date`: when, for the
    /// stopped agents' time (nil leaves it unknown, as for a replayed session).
    package func stopLane(_ agent: String, at date: Date? = nil, preserving observed: Set<String> = []) {
        guard var lane = lanes[agent] else { return }
        for i in lane.indices {
            if lane[i].kind == .tool, !lane[i].done {
                lane[i].done = true
                lane[i].stopped = true
            }
            if lane[i].agent?.status == .running, lane[i].agent.map({ !observed.contains($0.id) }) == true {
                lane[i].agent?.status = .stopped
                if let date, lane[i].agent?.duration == nil, let start = lane[i].agent?.startedAt {
                    lane[i].agent?.duration = date.timeIntervalSince(start)
                }
                if let child = lane[i].agent?.id { stopLane(child, at: date, preserving: observed) }
            }
        }
        lanes[agent] = lane
        agentsChanged()
    }

    /// The turn was stopped while the call ran; what it printed before stays.
    package func toolStopped(id: String) {
        update(tool: id) {
            $0.done = true
            $0.isError = false
            $0.stopped = true
        }
    }

    package func fileChanged(tool id: String, _ changes: [FileChange]) {
        update(tool: id) { $0.changes = changes }
    }

    /// Sent while a turn runs, in order, by Kore's id.
    package var queued: [(id: String, entry: Entry)] = []

    package func messageQueued(id: String, text: String, attachments: [SentAttachment]) {
        let entry = Entry(kind: .user, text: text, attachments: attachments)
        if !attachments.isEmpty { view?.chips(attachments, for: entry.id, from: nil) }
        queued.append((id, entry))
        changed(at: entries.count - 1)
    }

    /// Where a waiting message went: into the running turn after `after`, as the next turn's
    /// message, or nowhere (its text is back in the composer).
    package func queuedMessage(id: String, _ delivery: QueuedDelivery) {
        guard let i = queued.firstIndex(where: { $0.id == id }) else { return }
        var entry = queued.remove(at: i).entry
        switch delivery {
        case .inTurn(let after):
            entry.inTurn = true
            entry.turn = current
            let anchor = after.flatMap { tools[$0] ?? blocks[$0] }.flatMap { position[$0] }
            if let anchor, anchor + 1 < entries.count {
                insert(entry, at: anchor + 1)
            } else {
                append(entry)
            }
        case .nextTurn:
            // Sent with Kore's id, which the CLI keeps (or its backend maps): a rollback finds it by it.
            user(entry.text, attachments: entry.attachments, source: id, chipsFrom: entry.id)
        case .dropped:
            if !entry.attachments.isEmpty { view?.dropChips(entry.id) }
            changed(at: entries.count - 1)
        }
    }

    /// The provider, for its modes' names, icons and colours.
    package var provider: ProviderDescriptor?

    package var permissionsMode: String?

    package var planOn = false

    /// A change the user made while a turn ran: it shows when the turn ends, between turns.
    package var heldModeChange: (from: String, to: String)?

    /// The mode shown: a plan toggle that's on (Codex), else the permissions mode.
    package var effectiveMode: String? { planOn ? provider?.planToggle?.id ?? permissionsMode : permissionsMode }

    package func option(_ id: String) -> ModeOption? {
        provider?.modes.first { $0.id == id } ?? provider?.planToggle.flatMap { $0.id == id ? $0 : nil }
    }

    package func modeChanged(_ change: ModeChange) {
        let before = effectiveMode
        permissionsMode = change.mode
        if change.source == .refused {
            if let asked = change.previous { refused(asked: asked, kept: change.mode) }
            return
        }
        // A new chat's first turn opens before the CLI reports its mode: that's the mode the
        // turn started in.
        if change.previous == nil || change.source == .session, let current, turns[current]?.startMode == nil {
            turns[current]?.startMode = effectiveMode
        }
        // The first mode a chat learns isn't a change.
        guard change.previous != nil else { return }
        marked(change.source, from: before ?? change.previous, to: effectiveMode)
    }

    /// Codex's plan toggle, beside its permissions modes.
    package func planModeChanged(_ change: PlanModeChange) {
        let before = effectiveMode
        planOn = change.on
        guard change.source != .refused else { return }
        marked(change.source, from: before, to: effectiveMode)
    }

    package func marked(_ source: ModeSource, from: String?, to: String?) {
        guard let to, from != to else { return }
        switch source {
        case .session, .refused:
            break
        case .user:
            if let from { userChanged(from: from, to: to) }
        case .agent(let cause, let agent):
            agentChanged(cause, from: from, to: to, agent: agent)
        }
    }

    /// Between turns: one divider for a run of changes, gone when it comes back to where it was.
    package func userChanged(from: String, to: String) {
        if turnIsOpen {
            let start = heldModeChange?.from ?? from
            heldModeChange = start == to ? nil : (start, to)
            return
        }
        guard let option = option(to) else { return }
        if let last = entries.indices.last, entries[last].kind == .mode, entries[last].modeLead == nil {
            if entries[last].modeFrom == to {
                position[entries[last].id] = nil
                entries.removeLast()
                changed(at: entries.count)
            } else {
                entries[last].mode = ModeMark(option)
                entries[last].text = option.label
                changed(at: last)
            }
            return
        }
        var entry = Entry(kind: .mode, text: option.label)
        entry.mode = ModeMark(option)
        entry.modeFrom = from
        append(entry)
    }

    /// One of the agent's steps, on its turn's line (or its card's, for a sub-agent).
    package func agentChanged(_ cause: ModeCause, from: String?, to: String, agent: AgentID) {
        let (lead, shown): (String, String) =
            switch cause {
            case .enteredPlanMode: ("Entered", to)
            case .planApproved: ("Plan approved ·", to)
            case .other: option(to)?.rung == nil && from != nil ? ("Left", from!) : ("Entered", to)
            }
        guard let option = option(shown) else { return }
        var entry = Entry(kind: .mode, text: "\(lead) \(option.label)")
        entry.mode = ModeMark(option)
        entry.modeLead = lead
        if let sub = agent.sub {
            laneAppend(agent: sub, entry)
            changed(at: cardIndex(sub))
            return
        }
        entry.turn = current
        if let current { turns[current]?.endMode = to }
        append(entry)
    }

    /// "Couldn't switch to Auto · staying on Manual".
    package func refused(asked: String, kept: String) {
        guard let asked = option(asked), let kept = option(kept) else { return }
        var entry = Entry(kind: .notice, text: "Couldn't switch to \(asked.label) · staying on \(kept.label)")
        entry.warning = true
        entry.local = !batching
        entry.turn = current
        append(entry)
    }

    package func notice(_ text: String, isError: Bool) {
        var entry = Entry(kind: .notice, text: text, isError: isError)
        entry.turn = current
        entry.local = !batching
        append(entry)
    }

    /// A new agent's mark index: the next in spawn order, moved on to the first whose shape no running
    /// agent of this chat has, so two live agents never share a shape (with more than eight live,
    /// shapes repeat). Finished agents' shapes are free again; an agent keeps its index for life.
    package func freeAgentIndex() -> Int {
        let base = agentCards.count + laneAgents.count + parkedAgents.count
        let count = agentShapes
        let live = Set(agentOrder.compactMap { agent($0) }.filter { $0.status == .running }.map { $0.index % count })
        let step = (0..<count).first { !live.contains((base + $0) % count) } ?? 0
        return base + step
    }

    package func agentSpawned(
        id: String, name: String, type: String?, model: String? = nil, prompt: String? = nil, background: Bool = false,
        tool: String?, parent: String? = nil, at date: Date = Date()
    ) {
        var entry = Entry(kind: .agent, text: name, toolId: tool)
        entry.agent = AgentInfo(
            id: id, index: freeAgentIndex(), name: name, type: type, model: model, prompt: prompt,
            parent: parent, background: background, startedAt: date)
        // One read back from history stays in its place.
        if !agentOrder.contains(id) { agentOrder.append(id) }
        lanes[id] = lanes[id] ?? []
        if let parent {
            // A sub-agent's own agent: a card in its parent's lane, on the call that spawned it.
            if let tool, let (_, index) = laneTools[tool], lanes[parent]?.indices.contains(index) == true {
                lanes[parent]![index] = entry
                laneTools[tool] = nil
            } else {
                laneAppend(agent: parent, entry)
            }
            laneAgents[id] = (parent, entry.id)
            changed(at: cardIndex(parent))
            return
        }
        entry.turn = current
        agentCards[id] = entry.id
        // The spawning tool call becomes the card.
        if let tool, let existing = tools[tool], let i = position[existing] {
            entry.turn = entries[i].turn
            entries[i] = entry
            position[entry.id] = i
            position[existing] = nil
            if let turn = entry.turn, turnFirst[turn] == existing { turnFirst[turn] = entry.id }
            tools[tool] = entry.id
            touchesDirty = true
            changed(at: i)
        } else {
            append(entry)
        }
    }

    package func agentProgress(
        id: String, tokens: Int?, tools count: Int?, lastTool: String?, duration: TimeInterval?, approximate: Bool = false
    ) {
        updateAgent(id) {
            if let tokens {
                $0.tokens = tokens
                $0.approximate = approximate
            }
            if let count { $0.tools = count }
            if let lastTool { $0.lastTool = lastTool }
            if let duration { $0.duration = duration }
        }
    }

    package func agentFinished(id: String, status: AgentInfo.Status, result: String?, at date: Date = Date()) {
        // It can come twice (Claude background agents): the second carries the result.
        updateAgent(id) {
            $0.status = status
            if let result { $0.result = result }
            // A replayed agent has no timing of its own unless the CLI gave one.
            if $0.duration == nil, !self.batching { $0.duration = date.timeIntervalSince($0.startedAt) }
        }
    }

    /// It runs again: its clock carries on from where it ended, and its result stays until the
    /// next one.
    package func agentResumed(id: String, at date: Date = Date()) {
        guard let info = agent(id), info.status != .running else { return }
        updateAgent(id) {
            $0.status = .running
            if let duration = $0.duration { $0.startedAt = date.addingTimeInterval(-duration) }
            $0.duration = nil
        }
    }

    /// It outlived the turn that spawned it: it runs on in the background.
    package func agentBackgrounded(id: String) {
        guard let info = agent(id), !info.background else { return }
        updateAgent(id) { $0.background = true }
    }

    /// The user denied an action in the current turn (counted on its fold line).
    package func actionDenied() {
        guard let current else { return }
        turns[current]?.denied += 1
    }

    /// The answer block in progress ends when another block or a tool starts: it's no longer
    /// streaming, so all of it shows.
    package func endAnswer() {
        guard let last = entries.indices.last, entries[last].kind == .answer, !entries[last].done else { return }
        entries[last].done = true
        mark(last)
    }

    /// The thinking block in progress ends when anything else starts.
    package func endThinking() {
        guard let last = entries.indices.last, entries[last].kind == .thinking, entries[last].duration == nil,
            let start = entries[last].startedAt
        else { return }
        entries[last].duration = Date().timeIntervalSince(start)
        entries[last].done = true
        mark(last)
    }

    /// The model's safeguards refused the turn: its notice offers the ways on.
    package func refused(_ id: String, _ refusal: Refusal) { turns[id]?.refusal = refusal }

    /// The message that started a turn: the last of the user's before the turn's first entry.
    package func prompt(of turn: String) -> String? {
        guard let first = entries.firstIndex(where: { $0.turn == turn }) ?? turns[turn]?.after.flatMap({ after in
            entries.firstIndex { $0.id == after }.map { $0 + 1 }
        }) else { return nil }
        return entries[..<min(first, entries.count)].last { $0.kind == .user }?.text
    }

    /// The latest failed/interrupted attempt can be resumed until another message starts.
    package var retryableTurn: String? {
        guard !turnIsOpen, pendingSendSince == nil, let latestTurn, latestTurn != retryDismissed,
              let turn = turns[latestTurn], turn.finished else { return nil }
        switch turn.outcome {
        case .interrupted, .failed: return latestTurn
        case .completed, .authFailed, .slept: return nil
        }
    }

    /// A change to a turn: its rows are laid out together.
    package func changed(turn id: String?) {
        changed(at: turnIndex(id))
    }

    /// The turn's first entry, or the last entry for a turn with none yet; nil for no turn.
    package func turnIndex(_ id: String?) -> Int? {
        guard let id else { return entries.count - 1 }
        return turnFirst[id].flatMap { position[$0] } ?? (current == id ? entries.count - 1 : nil)
    }

    /// The chat's own card an agent's work shows in: its card, or its parent's, up to the one
    /// on the transcript.
    package func cardIndex(_ agent: String) -> Int? {
        var id = agent
        while true {
            if let card = agentCards[id], let i = position[card] { return i }
            guard let parent = laneAgents[id]?.parent else { return nil }
            id = parent
        }
    }

    package func append(_ entry: Entry) {
        position[entry.id] = entries.count
        entries.append(entry)
        if let turn = entry.turn, turnFirst[turn] == nil { turnFirst[turn] = entry.id }
        changed(at: entries.count - 1)
    }

    package func insert(_ entry: Entry, at index: Int) {
        entries.insert(entry, at: index)
        for i in index..<entries.count { position[entries[i].id] = i }
        if let turn = entry.turn, turnFirst[turn].flatMap({ position[$0] }).map({ index <= $0 }) ?? true {
            turnFirst[turn] = entry.id
        }
        invalidateAll()
        countHidden()
        changed()
    }

    package func update(tool id: String, files: Bool = true, _ change: (inout Entry) -> Void) {
        let at: Int?
        if let (agent, index) = laneTools[id] {
            if lanes[agent]?.indices.contains(index) == true { change(&lanes[agent]![index]) }
            agentsChanged()
            at = cardIndex(agent)
        } else if let entry = tools[id], let i = position[entry] {
            change(&entries[i])
            at = i
        } else {
            return
        }
        if files { touchesDirty = true }
        changed(at: at)
    }

    package func updateAgent(_ id: String, _ change: (inout AgentInfo) -> Void) {
        agentsChanged()
        if let card = agentCards[id], let i = position[card], entries[i].agent != nil {
            change(&entries[i].agent!)
            changed(at: i)
            return
        } else if let (parent, card) = laneAgents[id], let i = lanes[parent]?.firstIndex(where: { $0.id == card }),
            lanes[parent]![i].agent != nil
        {
            change(&lanes[parent]![i].agent!)
        } else if parkedAgents[id] != nil {
            change(&parkedAgents[id]!)
        } else {
            return
        }
        changed(at: cardIndex(id))
    }

    package func laneAppend(agent: String, _ entry: Entry) {
        lanes[agent, default: []].append(entry)
        agentsChanged()
        touchesDirty = true
    }

    package func laneText(agent: String, block: String, kind: Entry.Kind, text: String) {
        let key = "\(agent)/\(block)"
        if let id = blocks[key], let i = lanes[agent]?.firstIndex(where: { $0.id == id }) {
            lanes[agent]![i].text += text
            agentsChanged()
        } else {
            // A sub-agent's text isn't drawn as it streams (Claude's comes whole anyway).
            var entry = Entry(kind: kind, text: text)
            entry.done = true
            blocks[key] = entry.id
            laneAppend(agent: agent, entry)
        }
        changed(at: cardIndex(agent))
    }

    // MARK: The view's side

    func changed(at index: Int? = nil) { view?.changed(at: index) }
    func mark(_ index: Int?) { view?.mark(index) }
    func rebuild() { view?.rebuild() }
    func invalidateAll() { view?.invalidateAll() }
    func countHidden() { view?.countHidden() }
    func announceFold(_ turn: String) { view?.announceFold(turn) }
    func sending(_ on: Bool) { view?.sending(on, at: Date()) }
    func agentsChanged() { view?.agentsChanged() }
}

extension TranscriptLog.Entry {
    package init(kind: Kind, text: String, done: Bool) {
        self.init(kind: kind, text: text)
        self.done = done
    }
}

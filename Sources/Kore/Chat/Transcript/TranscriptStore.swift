import Foundation
import KoreCore
import Observation

/// The conversation as the transcript draws it. Entries arrive in order and are grouped into
/// turns; a finished turn folds its work into one "Worked for …" line above its answer.
/// `sections` is rebuilt from the entries after every change, and each row compares by value, so
/// SwiftUI redraws only the rows that changed. Views see only `sections`, `tail` and `folded`.
@MainActor @Observable
final class TranscriptStore {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case user, answer, thinking, plan, tool, agent, notice, peer }

        let id = UUID()
        var kind: Kind
        var text: String
        var toolName: String?
        var toolId: String?
        /// A tool's full input (the IN box), its header text, and the file it works on.
        var input: String?
        var summary: String?
        var path: String?
        var result: String?
        var done = false
        var isError = false
        var attachments: [Attachment] = []
        /// Who sent a `.peer` message.
        var from: String?
        /// Files an edit tool changed.
        var changes: [FileChange] = []
        /// Set for `.agent`: the sub-agent this card stands for.
        var agent: AgentInfo?
        /// The turn the entry belongs to; nil for the user's own message.
        var turn: String?
        /// Thinking: when it began, and how long it took once the next block started.
        var startedAt: Date?
        var duration: TimeInterval?

        static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.kind == b.kind && a.text == b.text && a.result == b.result && a.done == b.done
                && a.isError == b.isError && a.toolName == b.toolName && a.from == b.from
                && a.changes == b.changes && a.agent == b.agent && a.input == b.input && a.summary == b.summary
                && a.duration == b.duration && a.attachments.map(\.id) == b.attachments.map(\.id)
        }
    }

    struct AgentInfo: Equatable {
        typealias Status = AgentMark.Status
        let id: String
        /// Spawn order in the chat: picks the agent's mark.
        let index: Int
        var name: String
        var type: String?
        var model: String?
        /// A Claude background agent: its commands aren't on stdout.
        var background = false
        var status = Status.running
        var startedAt: Date
        var duration: TimeInterval?
        var tokens: Int?
        var tools = 0
        var lastTool: String?
        var result: String?
    }

    enum Outcome: Equatable { case completed, interrupted, failed(String) }

    struct Turn {
        let id: String
        var startedAt: Date
        var duration: TimeInterval?
        var finished = false
        var outcome = Outcome.completed
        /// Where the answer starts (Codex's first final-answer text). Unset, it's found when
        /// the turn finishes: the text after the turn's last piece of work.
        var answerFrom: UUID?
        /// When the answer began, for the fold's label while the answer still streams.
        var workEnded: Date?
        var changes: [FileChange] = []
        var open = false
        var denied = 0
    }

    /// One drawn row.
    enum Row: Identifiable, Equatable {
        case entry(Entry)
        /// A tool call; `open` shows its IN / OUT box unclipped.
        case tool(Entry, open: Bool)
        /// "Thought for 3s", opened to the thinking.
        case thinking(Entry, open: Bool)
        /// A file row, open or closed; `openFiles` are the paths opened inside a multi-file row.
        case file(Entry, open: Bool, openFiles: Set<String>)
        /// An agent card; `lane` (its own work, as rows) is filled while it's open, and holds the
        /// latest item while it runs closed.
        case agent(Entry, lane: [Row], open: Bool)
        case fold(Fold)
        case rule(turn: String)
        case outcome(turn: String, text: String)
        case changes(turn: String, files: Int, added: Int, removed: Int)

        var id: String {
            switch self {
            case .entry(let e), .tool(let e, _), .thinking(let e, _), .file(let e, _, _), .agent(let e, _, _):
                e.id.uuidString
            case .fold(let f): "fold-\(f.turn)"
            case .rule(let t): "rule-\(t)"
            case .outcome(let t, _): "outcome-\(t)"
            case .changes(let t, _, _, _): "changes-\(t)"
            }
        }
    }

    struct Fold: Equatable {
        let turn: String
        let label: String
        let outcome: WorkedFor.Outcome?
        let denied: Int
        let open: Bool
    }

    /// A drawn row and its place on the timeline: a dot (nil: off the timeline) and whether the
    /// line joins it to its neighbours.
    struct Item: Identifiable, Equatable {
        let row: Row
        let dot: TimelineDot?
        let above: Bool
        let below: Bool
        var id: String { row.id }
    }

    /// One user (or peer) message and what followed it. The header sticks to the top while
    /// its section scrolls by.
    struct Section: Identifiable, Equatable {
        let id: String
        let header: Entry?
        let items: [Item]
    }

    private(set) var sections: [Section] = []
    /// Changes whenever any row does, so the view can follow the end.
    private(set) var tail = 0
    @ObservationIgnored private(set) var rows: [Row] = []
    /// Bumped when a turn folds by itself, so the view can keep the answer where it was.
    private(set) var folded: (turn: String, answer: String, seq: Int)?

    @ObservationIgnored private(set) var entries: [Entry] = []
    @ObservationIgnored private var position: [UUID: Int] = [:]
    @ObservationIgnored private var turns: [String: Turn] = [:]
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var blocks: [String: UUID] = [:]
    @ObservationIgnored private var tools: [String: UUID] = [:]
    /// Each sub-agent's own entries, keyed by agent id.
    @ObservationIgnored private var lanes: [String: [Entry]] = [:]
    @ObservationIgnored private var laneTools: [String: (agent: String, index: Int)] = [:]
    @ObservationIgnored private var agentCards: [String: UUID] = [:]
    /// Opened file rows and agent cards (entry ids), and files inside a multi-file row
    /// ("id/path"). Kept in memory only: a reopened chat starts closed.
    @ObservationIgnored private var openKeys: Set<String> = []
    @ObservationIgnored private var batching = false
    @ObservationIgnored private var foldSeq = 0

    /// For notices: "Claude exited (1)".
    @ObservationIgnored var providerName = "The CLI"
    /// Cards of agents spawned by other sub-agents, in their parent's lane.
    @ObservationIgnored private var laneAgents: [String: (parent: String, entry: UUID)] = [:]

    var turnIsOpen: Bool { current.map { turns[$0]?.finished == false } ?? false }

    // MARK: Batches

    /// Applies many changes as one update (a replayed session). Replayed turns start folded.
    func batch(_ changes: () -> Void) {
        batching = true
        changes()
        batching = false
        // Replayed thinking has no timing; it's finished all the same.
        for i in entries.indices where entries[i].kind == .thinking && entries[i].startedAt == nil {
            entries[i].done = true
        }
        rebuild()
    }

    // MARK: Turns

    func turnStarted(_ id: String, at date: Date = Date()) {
        turns[id] = Turn(id: id, startedAt: date)
        current = id
        changed()
    }

    /// Codex: the final answer has begun, so the work above it folds now.
    func finalAnswer(block: String) {
        guard let entry = blocks[block], let turn = entries[position[entry]!].turn, turns[turn]?.answerFrom == nil
        else { return }
        turns[turn]?.answerFrom = entry
        turns[turn]?.workEnded = Date()
        announceFold(turn)
        changed()
    }

    func turnFinished(_ id: String?, _ outcome: Outcome, duration: TimeInterval? = nil, at date: Date = Date()) {
        guard let id = id ?? current, var turn = turns[id] else { return }
        endThinking()
        turn.finished = true
        turn.outcome = outcome
        // A replayed turn without the CLI's own measure has none: it reads "N previous messages".
        turn.duration = duration ?? (batching ? nil : date.timeIntervalSince(turn.startedAt))
        let hadAnswer = turn.answerFrom != nil
        turns[id] = turn
        if current == id { current = nil }
        if !hadAnswer { announceFold(id) }
        changed()
    }

    /// The files a turn changed (the git snapshot, or what the CLI reported), for its summary.
    func turnChanges(_ id: String, _ changes: [FileChange]) {
        turns[id]?.changes = changes
        changed()
    }

    func changes(ofTurn id: String) -> [FileChange] { turns[id]?.changes ?? [] }

    /// Opens or closes a sub-agent's card.
    func toggle(agent id: String) {
        if let card = agentCards[id] ?? laneAgents[id]?.entry { toggle(card.uuidString) }
    }

    /// A sub-agent's card details, for an approval it asks for.
    func agent(_ id: String) -> AgentInfo? {
        if let card = agentCards[id], let i = position[card] { return entries[i].agent }
        if let (parent, card) = laneAgents[id] { return lanes[parent]?.first { $0.id == card }?.agent }
        return nil
    }

    // MARK: Content

    func user(_ text: String, attachments: [Attachment]) {
        append(Entry(kind: .user, text: text, attachments: attachments))
    }

    /// A peer's message, placed where its turn began.
    func peer(from: String, text: String, turn: String?) {
        var entry = Entry(kind: .peer, text: text, from: from)
        entry.turn = turn
        if let turn, let first = entries.firstIndex(where: { $0.turn == turn }) {
            insert(entry, at: first)
        } else {
            append(entry)
        }
    }

    enum TextKind { case answer, thinking, plan }

    /// Appends to a text block, starting it if the id is new.
    func text(_ block: String, _ kind: TextKind, _ text: String, agent: String? = nil) {
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
        } else {
            endThinking()
            var entry = Entry(kind: kind, text: text)
            entry.turn = current
            if kind == .thinking { entry.startedAt = Date() }
            blocks[block] = entry.id
            append(entry, rebuild: false)
        }
        changed()
    }

    func toolStarted(
        id: String, name: String, detail: String, input: String? = nil, summary: String? = nil, path: String? = nil,
        agent: String? = nil
    ) {
        var entry = Entry(kind: .tool, text: detail, toolName: name, toolId: id)
        entry.input = input
        entry.summary = summary
        entry.path = path
        if agent == nil { endThinking() }
        if let agent {
            laneAppend(agent: agent, entry)
            laneTools[id] = (agent, lanes[agent]!.count - 1)
            if let card = agentCards[agent], let i = position[card], entries[i].agent != nil {
                entries[i].agent!.tools += 1
                entries[i].agent!.lastTool = name
            }
            changed()
            return
        }
        entry.turn = current
        tools[id] = entry.id
        append(entry)
    }

    func toolOutput(id: String, _ text: String) {
        update(tool: id) { $0.result = ($0.result ?? "") + text }
    }

    /// `output` nil keeps what streamed.
    func toolFinished(id: String, output: String?, isError: Bool) {
        update(tool: id) {
            if let output { $0.result = output }
            $0.done = true
            $0.isError = isError
        }
    }

    func fileChanged(tool id: String, _ changes: [FileChange]) {
        update(tool: id) { $0.changes = changes }
    }

    func notice(_ text: String, isError: Bool) {
        var entry = Entry(kind: .notice, text: text, isError: isError)
        entry.turn = current
        append(entry)
    }

    // MARK: Sub-agents

    func agentSpawned(
        id: String, name: String, type: String?, model: String? = nil, background: Bool = false, tool: String?,
        parent: String? = nil, at date: Date = Date()
    ) {
        var entry = Entry(kind: .agent, text: name, toolId: tool)
        entry.agent = AgentInfo(
            id: id, index: agentCards.count + laneAgents.count, name: name, type: type, model: model,
            background: background, startedAt: date)
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
            changed()
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
            tools[tool] = entry.id
            changed()
        } else {
            append(entry)
        }
    }

    func agentProgress(id: String, tokens: Int?, tools count: Int?, lastTool: String?, duration: TimeInterval?) {
        updateAgent(id) {
            if let tokens { $0.tokens = tokens }
            if let count { $0.tools = count }
            if let lastTool { $0.lastTool = lastTool }
            if let duration { $0.duration = duration }
        }
    }

    func agentFinished(id: String, status: AgentInfo.Status, result: String?, at date: Date = Date()) {
        updateAgent(id) {
            $0.status = status
            if let result { $0.result = result }
            if $0.duration == nil || status != .running { $0.duration = $0.duration ?? date.timeIntervalSince($0.startedAt) }
        }
    }

    // MARK: Opening and closing

    func toggle(turn id: String) {
        turns[id]?.open.toggle()
        changed()
    }

    func toggle(_ key: String) {
        if openKeys.remove(key) == nil { openKeys.insert(key) }
        changed()
    }

    /// The user denied an action in the current turn (counted on its fold line).
    func actionDenied() {
        guard let current else { return }
        turns[current]?.denied += 1
    }

    // MARK: Building rows

    private func rebuild() {
        var rows: [Row] = []
        rows.reserveCapacity(entries.count)
        var i = 0
        while i < entries.count {
            guard let turnID = entries[i].turn, let turn = turns[turnID] else {
                rows.append(row(entries[i]))
                i += 1
                continue
            }
            var end = i
            while end < entries.count, entries[end].turn == turnID { end += 1 }
            layout(turn, entries[i..<end], into: &rows)
            i = end
        }
        guard rows != self.rows else { return }
        self.rows = rows
        tail &+= 1
        let sections = Self.sections(rows)
        if sections != self.sections { self.sections = sections }
    }

    /// Splits rows at each user or peer message, and places them on the timeline.
    private static func sections(_ rows: [Row]) -> [Section] {
        var sections: [Section] = []
        var header: Entry?
        var id = "start"
        var run: [Row] = []
        func flush() {
            guard header != nil || !run.isEmpty else { return }
            let dots = run.map(dot)
            let items = run.indices.map { i in
                Item(
                    row: run[i], dot: dots[i],
                    above: dots[i] != nil && i > 0 && dots[i - 1] != nil,
                    below: dots[i] != nil && i + 1 < dots.count && dots[i + 1] != nil)
            }
            sections.append(Section(id: id, header: header, items: items))
        }
        for row in rows {
            if case .entry(let e) = row, e.kind == .user || e.kind == .peer {
                flush()
                header = e
                id = e.id.uuidString
                run = []
            } else {
                run.append(row)
            }
        }
        flush()
        return sections
    }

    static func dot(_ row: Row) -> TimelineDot? {
        func state(_ e: Entry) -> TimelineDot { !e.done ? .running : e.isError ? .failure : .success }
        switch row {
        case .entry(let e):
            switch e.kind {
            case .answer, .plan: return .plain
            case .notice: return e.isError ? .failure : .plain
            default: return nil
            }
        case .thinking: return .plain
        case .fold(let f):
            switch f.outcome {
            case .failed: return .failure
            case .interrupted: return .warning
            case nil: return .plain
            }
        case .rule: return TimelineDot.none
        case .outcome(_, let text): return text == "Interrupted" ? .warning : .failure
        case .changes: return .plain
        case .tool(let e, _): return state(e)
        case .file(let e, _, _): return state(e)
        case .agent(let e, _, _): return e.agent.map { .mark(index: $0.index, status: $0.status) }
        default: return nil
        }
    }

    /// The thinking block in progress ends when anything else starts.
    private func endThinking() {
        guard let last = entries.indices.last, entries[last].kind == .thinking, entries[last].duration == nil,
            let start = entries[last].startedAt
        else { return }
        entries[last].duration = Date().timeIntervalSince(start)
        entries[last].done = true
    }

    /// A turn: still working, everything shows; once its answer starts, the work folds.
    private func layout(_ turn: Turn, _ group: ArraySlice<Entry>, into rows: inout [Row]) {
        guard let split = answerStart(turn, group) else {
            rows.append(contentsOf: group.map(row))
            if turn.finished { trailer(turn, folded: false, into: &rows) }
            return
        }
        let work = group[group.startIndex..<split]
        let answer = group[split...]
        let foldable = work.filter { !Self.pinned($0) }
        if foldable.isEmpty {
            rows.append(contentsOf: group.map(row))
            if turn.finished { trailer(turn, folded: false, into: &rows) }
            return
        }
        // Prompts (a peer's message) stay above the fold.
        rows.append(contentsOf: work.prefix { $0.kind == .peer || $0.kind == .user }.map(row))
        let worked = turn.finished ? turn.duration : turn.workEnded.map { $0.timeIntervalSince(turn.startedAt) }
        let label = WorkedFor.label(duration: worked, items: foldable.count)
        rows.append(.fold(Fold(
            turn: turn.id, label: label, outcome: foldOutcome(turn), denied: turn.denied, open: turn.open)))
        for entry in work where entry.kind != .peer && entry.kind != .user {
            if turn.open || Self.pinned(entry) { rows.append(row(entry)) }
        }
        rows.append(.rule(turn: turn.id))
        rows.append(contentsOf: answer.map(row))
        if turn.finished { trailer(turn, folded: true, into: &rows) }
    }

    /// The outcome notice and the files-changed line, under the answer and never folded.
    private func trailer(_ turn: Turn, folded: Bool, into rows: inout [Row]) {
        switch turn.outcome {
        case .completed: break
        case .interrupted: if !folded { rows.append(.outcome(turn: turn.id, text: "Interrupted")) }
        case .failed(let message): rows.append(.outcome(turn: turn.id, text: message))
        }
        if !turn.changes.isEmpty {
            rows.append(.changes(
                turn: turn.id, files: turn.changes.count, added: turn.changes.reduce(0) { $0 + $1.added },
                removed: turn.changes.reduce(0) { $0 + $1.removed }))
        }
    }

    private func foldOutcome(_ turn: Turn) -> WorkedFor.Outcome? {
        switch turn.outcome {
        case .completed: nil
        case .interrupted: .interrupted
        case .failed: .failed
        }
    }

    /// Where the answer begins, or nil while the turn is still working.
    private func answerStart(_ turn: Turn, _ group: ArraySlice<Entry>) -> Int? {
        if let from = turn.answerFrom, let i = group.firstIndex(where: { $0.id == from }) { return i }
        guard turn.finished else { return nil }
        guard let lastWork = group.lastIndex(where: Self.isWork) else { return nil }
        let after = group.index(after: lastWork)
        if after < group.endIndex, group[after...].contains(where: { $0.kind == .answer }) { return after }
        // Ended on work: its last item stays in view.
        return lastWork
    }

    private static func isWork(_ e: Entry) -> Bool {
        e.kind == .tool || e.kind == .thinking || e.kind == .agent
    }

    /// Never hidden in a fold: plans, peer messages, errors.
    private static func pinned(_ e: Entry) -> Bool {
        e.kind == .plan || e.kind == .peer || e.kind == .user || (e.kind == .notice && e.isError)
    }

    private func row(_ entry: Entry) -> Row {
        switch entry.kind {
        case .tool where !entry.changes.isEmpty:
            let key = entry.id.uuidString
            let files = entry.changes.count > 1
                ? Set(entry.changes.map(\.path).filter { openKeys.contains("\(key)/\($0)") }) : []
            return .file(entry, open: openKeys.contains(key), openFiles: files)
        case .agent:
            let open = openKeys.contains(entry.id.uuidString)
            let lane = lanes[entry.agent?.id ?? ""] ?? []
            // Closed while running, the card shows its latest command.
            let shown = open ? lane : (entry.agent?.status == .running ? Array(lane.suffix(1)) : [])
            return .agent(entry, lane: shown.map(row), open: open)
        case .tool:
            return .tool(entry, open: openKeys.contains(entry.id.uuidString))
        case .thinking:
            return .thinking(entry, open: openKeys.contains(entry.id.uuidString))
        default:
            return .entry(entry)
        }
    }

    // MARK: Plumbing

    private func changed() {
        if !batching { rebuild() }
    }

    private func append(_ entry: Entry, rebuild: Bool = true) {
        position[entry.id] = entries.count
        entries.append(entry)
        if rebuild { changed() }
    }

    private func insert(_ entry: Entry, at index: Int) {
        entries.insert(entry, at: index)
        for i in index..<entries.count { position[entries[i].id] = i }
        changed()
    }

    private func update(tool id: String, _ change: (inout Entry) -> Void) {
        if let (agent, index) = laneTools[id] {
            if lanes[agent]?.indices.contains(index) == true { change(&lanes[agent]![index]) }
        } else if let entry = tools[id], let i = position[entry] {
            change(&entries[i])
        } else {
            return
        }
        changed()
    }

    private func updateAgent(_ id: String, _ change: (inout AgentInfo) -> Void) {
        if let card = agentCards[id], let i = position[card], entries[i].agent != nil {
            change(&entries[i].agent!)
        } else if let (parent, card) = laneAgents[id], let i = lanes[parent]?.firstIndex(where: { $0.id == card }),
            lanes[parent]![i].agent != nil
        {
            change(&lanes[parent]![i].agent!)
        } else {
            return
        }
        changed()
    }

    private func laneAppend(agent: String, _ entry: Entry) {
        lanes[agent, default: []].append(entry)
    }

    private func laneText(agent: String, block: String, kind: Entry.Kind, text: String) {
        let key = "\(agent)/\(block)"
        if let id = blocks[key], let i = lanes[agent]?.firstIndex(where: { $0.id == id }) {
            lanes[agent]![i].text += text
        } else {
            let entry = Entry(kind: kind, text: text)
            blocks[key] = entry.id
            laneAppend(agent: agent, entry)
        }
        changed()
    }

    private func announceFold(_ turn: String) {
        guard !batching, let t = turns[turn] else { return }
        let answer = t.answerFrom?.uuidString ?? "rule-\(turn)"
        foldSeq += 1
        folded = (turn, answer, foldSeq)
    }
}

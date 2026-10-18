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
        /// `divider`: a quiet line across the transcript ("Conversation compacted · 14:32",
        /// "Forked from …"), off the timeline.
        enum Kind: Equatable { case user, answer, thinking, plan, tool, agent, notice, peer, divider }

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
        /// A tool that only reads, searches or lists (grouped into "Explored N").
        var readOnly = false
        /// A tool call cut off by Stop: no output, a muted dot.
        var stopped = false
        /// A user message's id in its CLI's history (where a fork from it starts); nil for one
        /// sent in this run. `forkSource` on a fork's "Forked from" line.
        var source: String?

        static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.kind == b.kind && a.text == b.text && a.result == b.result && a.done == b.done
                && a.isError == b.isError && a.stopped == b.stopped && a.toolName == b.toolName && a.from == b.from
                && a.changes == b.changes && a.agent == b.agent && a.input == b.input && a.summary == b.summary
                && a.duration == b.duration && a.attachments.map(\.id) == b.attachments.map(\.id)
        }
    }

    struct AgentInfo: Equatable {
        typealias Status = AgentAvatar.Status
        let id: String
        /// Spawn order in the chat: picks the agent's mark.
        let index: Int
        var name: String
        var type: String?
        var model: String?
        /// What it was asked to do.
        var prompt: String?
        /// The agent that spawned it; nil for the chat's own agent.
        var parent: String?
        /// A Claude background agent: its commands aren't on stdout.
        var background = false
        var status = Status.running
        /// Approvals it's waiting on the user for.
        var waiting = 0
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
        /// The fold's open state once the user has set it; until then it's open while the turn
        /// works and closed once its answer starts.
        var open = false
        var touched = false
        var denied = 0
        /// What the live fold row last said ("Running Bash…"); it stays until the next state.
        var liveLabel: String?
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
        /// Two or more consecutive read-only tool calls, as one "Explored N" item.
        case explored([Entry], open: Bool)
        /// A user or peer message, first in its section; `expanded` shows a long one whole.
        case message(Entry, open: Bool, expanded: Bool)
        /// The running turn's last row: glyph and verb (look.md §12); `word` in place of the
        /// random verb ("Compacting").
        case spinner(turn: String, since: Date, claude: Bool, word: String?)

        var id: String {
            switch self {
            case .entry(let e), .tool(let e, _), .thinking(let e, _), .file(let e, _, _), .agent(let e, _, _),
                .message(let e, _, _):
                e.id.uuidString
            case .fold(let f): "fold-\(f.turn)"
            case .rule(let t): "rule-\(t)"
            case .outcome(let t, _): "outcome-\(t)"
            case .changes(let t, _, _, _): "changes-\(t)"
            // The first call's: a read-only call that becomes a group keeps its identity.
            case .explored(let entries, _): entries.first?.id.uuidString ?? "explored"
            case .spinner(let t, _, _, _): "spinner-\(t)"
            }
        }
    }

    struct Fold: Equatable {
        let turn: String
        let label: String
        let outcome: WorkedFor.Outcome?
        let denied: Int
        let open: Bool
        /// The turn is still working: the label says what's happening, and pulses.
        var live = false
        /// "3 tool calls · 1 failed"; nil before the first tool call.
        var count: String?
        /// Some tool call failed (its dot turns red once the turn ends).
        var failed = false
    }

    /// A file the latest turn changed, for the file explorer and editor (phase 09 §8).
    struct FileTouch: Equatable {
        /// Absolute, with symlinks resolved (as FSEvents reports it).
        let path: String
        var added: Int
        var removed: Int
        /// `changes(ofTurn:)` opens the changes modal on it.
        let turn: String
        /// Set when a sub-agent wrote it: its `AgentAvatar` index and name.
        var agentIndex: Int?
        var agentName: String?
        /// A tool writing this file hasn't finished.
        var writing: Bool
    }

    /// A drawn row and its place on the timeline: a dot (nil: off the timeline) and whether the
    /// line joins it to its neighbours.
    struct Item: Identifiable, Equatable {
        let row: Row
        let dot: TimelineDot?
        let above: Bool
        let below: Bool
        /// The row's id; a call listed under its open "Explored" group (which has the first
        /// call's id) gets "<id>/call".
        let id: String
    }

    /// One user (or peer) message and what followed it. The header sticks to the top while
    /// its section scrolls by. Its id is "s-<message id>" ("start" before the first message),
    /// distinct from the message row's own.
    struct Section: Identifiable, Equatable {
        let id: String
        let header: Entry?
        /// A peer's message starts as one line (owner, 2026-10-21); opened, it shows in full.
        let headerOpen: Bool
        let items: [Item]
    }

    /// A section as the view sees it: its own observable, so a streamed token re-renders only
    /// the section it lands in. `sections` itself changes only when sections come or go.
    @MainActor @Observable
    final class SectionModel: Identifiable {
        let id: String
        private(set) var header: Entry?
        private(set) var headerOpen: Bool
        private(set) var items: [Item]

        init(_ section: Section) {
            id = section.id
            header = section.header
            headerOpen = section.headerOpen
            items = section.items
        }

        /// Takes a rebuilt section's content, touching only what changed; whether anything did.
        func update(_ section: Section) -> Bool {
            var changed = false
            if header != section.header {
                header = section.header
                changed = true
            }
            if headerOpen != section.headerOpen {
                headerOpen = section.headerOpen
                changed = true
            }
            if items != section.items {
                items = section.items
                changed = true
            }
            return changed
        }
    }

    private(set) var sections: [SectionModel] = []
    /// Changes whenever any row does, so the view can follow the end.
    private(set) var tail = 0
    /// Changes whenever any agent's own work or details do (the map and agent tabs follow it;
    /// a closed card's lane isn't in `sections`).
    private(set) var agentsVersion = 0
    /// What the Agents button shows; changes only when an agent comes or goes or changes state.
    private(set) var agentSummary = AgentSummary()

    struct AgentSummary: Equatable {
        var count = 0
        /// Running agents' mark indexes and ids, in spawn order.
        var running: [AgentRef] = []
        /// Some agent is waiting for the user.
        var waiting = false
        /// The first few agents, for the idle stack.
        var first: [AgentRef] = []
        var failed: [String] = []
    }

    struct AgentRef: Equatable, Identifiable {
        let id: String
        let index: Int
        let name: String
        let status: AgentInfo.Status
    }

    /// One row of the agent map's tree.
    struct AgentNode: Identifiable, Equatable {
        let info: AgentInfo
        let depth: Int
        /// The last of its parent's children (└ rather than ├).
        let isLast: Bool
        /// For each ancestor level, whether a line continues below (│).
        let rails: [Bool]
        var id: String { info.id }
    }
    /// Bumped when a turn folds by itself, so the view can keep the answer where it was.
    private(set) var folded: (turn: String, answer: String, seq: Int)?
    /// User turns before the shown window: the "Load earlier turns" row shows while any are.
    private(set) var hiddenTurns = 0
    /// Conversation before what the CLI's history shows (before a compaction): once the shown
    /// turns are all in view, the top row loads it.
    private(set) var earlierAvailable = false
    private(set) var loadingEarlier = false
    /// The files the latest turn changed, by path (`turnChanges()`).
    private(set) var fileTouches: [String: FileTouch] = [:]

    /// When the user last sent a message (live, not replayed): the view glides to the end for
    /// 2s after it, as the extension does.
    @ObservationIgnored private(set) var sentAt: Date?
    /// Where the reader was when the chat's view went away (another tab), to come back to: the
    /// message row at or above the top and how far into it, or the end. Opened folds and rows
    /// stay in this store, so they need no saving.
    @ObservationIgnored var savedScroll: SavedScroll?

    struct SavedScroll {
        var row: String?
        var inRow: CGFloat
        /// The plain offset, when no message row was placed.
        var offset: CGFloat
        var atEnd: Bool
    }

    /// The first user message built; nil: from the first entry. A replayed chat opens on its
    /// last `openTurns` (T3 Code's paging); "Load earlier turns" moves it up. A send never moves
    /// it, so nothing above the reader goes away.
    @ObservationIgnored private var windowStart: UUID?
    @ObservationIgnored private var windowPlaced = false
    static let openTurns = 10
    /// The lowest entry index changed since the last rebuild: sections from the one holding it
    /// are built again, the ones above are kept. nil: nothing changed.
    @ObservationIgnored private var dirtyFrom: Int?
    /// Where each of `sections` starts in `entries`.
    @ObservationIgnored private var sectionStarts: [Int] = []
    /// The latest turn's tools changed, so `fileTouches` is due again.
    @ObservationIgnored private var touchesDirty = false
    /// Each turn's first entry. A turn can span sections (a message sent while it ran lands in
    /// the middle of it), so a change to the turn marks from here.
    @ObservationIgnored private var turnFirst: [String: UUID] = [:]
    /// Changes waiting to be drawn: streamed deltas are drawn once per `drawInterval`.
    @ObservationIgnored private var drawScheduled = false
    static let drawInterval: TimeInterval = 1.0 / 30
    /// Pending approvals of this chat: id → it's a question (AskUserQuestion, Codex user input).
    @ObservationIgnored private var pendingApprovals: [String: Bool] = [:]
    /// A compaction is running (the live row says "Compacting…").
    @ObservationIgnored private var compactingNow = false
    /// The most recently started turn, for `turnChanges()`.
    @ObservationIgnored private var latestTurn: String?

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
    /// Every agent id in spawn order.
    @ObservationIgnored private var agentOrder: [String] = []
    /// Agents whose history has been loaded (once is enough).
    @ObservationIgnored private var loadedAgents: Set<String> = []
    @ObservationIgnored private var loadingHistory = false
    /// Pending approvals asked for by sub-agents: approval id → agent id.
    @ObservationIgnored private var askedBy: [String: String] = [:]
    /// When the chat's first turn began, and the time its finished turns took.
    @ObservationIgnored private var workedBefore: TimeInterval = 0

    var turnIsOpen: Bool { current.map { turns[$0]?.finished == false } ?? false }

    // MARK: Batches

    /// Applies many changes as one update (a replayed session). Replayed turns start folded.
    func batch(_ changes: () -> Void) {
        batching = true
        changes()
        batching = false
        // Replayed thinking has no timing, and replayed text isn't streaming; both are finished.
        for i in entries.indices where entries[i].startedAt == nil && (entries[i].kind == .thinking || entries[i].kind == .answer) {
            entries[i].done = true
        }
        invalidateAll()
        rebuild()
    }

    /// A past session's history, before anything else: it opens on its last `openTurns` turns.
    func replay(_ events: [ChatEvent]) {
        batch {
            events.forEach(apply)
            placeWindow()
        }
    }

    private func placeWindow() {
        guard !windowPlaced else { return }
        windowPlaced = true
        var users = 0
        for i in entries.indices.reversed() where entries[i].kind == .user {
            users += 1
            if users == Self.openTurns {
                windowStart = entries[i].id
                break
            }
        }
        countHidden()
    }

    private var windowStartIndex: Int { windowStart.flatMap { position[$0] } ?? 0 }

    private func countHidden() {
        let hidden = entries[..<windowStartIndex].count { $0.kind == .user }
        if hidden != hiddenTurns { hiddenTurns = hidden }
    }

    /// The conversation before a compaction is being read.
    func startLoadingEarlier() {
        loadingEarlier = true
    }

    /// A page of earlier conversation goes above everything, shown; `more` says if there's
    /// more before it. A turn that's running stays the running one.
    func prepend(_ events: [ChatEvent], more: Bool) {
        let later = entries
        let (running, latest) = (current, latestTurn)
        entries = []
        position = [:]
        batching = true
        events.forEach(apply)
        for entry in later {
            position[entry.id] = entries.count
            entries.append(entry)
        }
        batching = false
        (current, latestTurn) = (running, latest)
        for i in entries.indices where entries[i].startedAt == nil && (entries[i].kind == .thinking || entries[i].kind == .answer) {
            entries[i].done = true
        }
        // Offered only with every turn shown, so the page shows too.
        if hiddenTurns == 0 { windowStart = nil }
        countHidden()
        earlierAvailable = more
        loadingEarlier = false
        invalidateAll()
        rebuild()
    }

    func earlierHistory(_ available: Bool) {
        earlierAvailable = available
    }

    /// A compaction is running: the live row says "Compacting…" (look §9).
    func compacting(_ on: Bool) {
        guard compactingNow != on else { return }
        compactingNow = on
        rebuild()
    }

    /// "Conversation compacted · 14:32" above the summary that follows.
    func compacted(at date: Date) {
        append(Entry(kind: .divider, text: "Conversation compacted · " + Self.time.string(from: date)))
    }

    /// After a fork's history: "Forked from "Refactor theme tokens"".
    func forkedFrom(_ title: String) {
        append(Entry(kind: .divider, text: "Forked from \u{201C}\(title)\u{201D}", source: Self.forkSource))
    }

    static let forkSource = "fork"

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Twenty more user turns above the window.
    func loadEarlier() {
        var users = 0
        var start: UUID?
        for i in entries[..<windowStartIndex].indices.reversed() where entries[i].kind == .user {
            users += 1
            start = entries[i].id
            if users == 20 { break }
        }
        windowStart = users == 20 ? start : nil
        countHidden()
        invalidateAll()
        rebuild()
    }

    // MARK: Turns

    func turnStarted(_ id: String, at date: Date = Date()) {
        turns[id] = Turn(id: id, startedAt: date)
        current = id
        latestTurn = id
        touchesDirty = true
        changed(at: entries.count - 1)
    }

    /// Codex: the final answer has begun, so the work above it folds now.
    func finalAnswer(block: String) {
        guard let entry = blocks[block], let turn = entries[position[entry]!].turn, turns[turn]?.answerFrom == nil
        else { return }
        turns[turn]?.answerFrom = entry
        turns[turn]?.workEnded = Date()
        announceFold(turn)
        changed(turn: turn)
    }

    func turnFinished(_ id: String?, _ outcome: Outcome, duration: TimeInterval? = nil, at date: Date = Date()) {
        guard let id = id ?? current, var turn = turns[id] else { return }
        endThinking()
        settleAll()
        pendingApprovals.removeAll()
        // Its text has stopped streaming; after a stop, calls and agents the CLI never closed
        // (Codex sends nothing more for them) end as stopped. Replayed turns too.
        let interrupted = outcome == .interrupted
        for i in (turnIndex(id) ?? entries.count)..<entries.count where entries[i].turn == id {
            switch entries[i].kind {
            case .answer:
                entries[i].done = true
            case .tool where interrupted && !entries[i].done:
                entries[i].done = true
                entries[i].stopped = true
            case .agent where interrupted && entries[i].agent?.status == .running:
                entries[i].agent?.status = .stopped
                if let agent = entries[i].agent?.id { stopLane(agent) }
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
        if current == id { current = nil }
        workedBefore += turn.duration ?? 0
        if !hadAnswer { announceFold(id) }
        changed(turn: id)
    }

    /// The files a turn changed (the git snapshot, or what the CLI reported), for its summary.
    func turnChanges(_ id: String, _ changes: [FileChange]) {
        turns[id]?.changes = changes
        touchesDirty = true
        changed(turn: id)
    }

    func changes(ofTurn id: String) -> [FileChange] { turns[id]?.changes ?? [] }

    /// The files the running turn changed, or else the latest finished turn's, by path; reading
    /// it from a view follows it.
    func turnChanges() -> [String: FileTouch] { fileTouches }

    /// Tools that write a file before reporting its change.
    private static let writeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private func touchedFiles() -> [String: FileTouch] {
        guard let id = latestTurn, let turn = turns[id] else { return [:] }
        var touches: [String: FileTouch] = [:]
        func touch(_ path: String, added: Int, removed: Int, writing: Bool, agent: AgentInfo?) {
            let path = Self.resolved(path)
            var t = touches[path] ?? FileTouch(
                path: path, added: 0, removed: 0, turn: id, agentIndex: agent?.index, agentName: agent?.name,
                writing: false)
            t.added += added
            t.removed += removed
            t.writing = t.writing || writing
            touches[path] = t
        }
        func add(_ e: Entry, agent: AgentInfo?) {
            guard e.kind == .tool else { return }
            if e.changes.isEmpty {
                if !e.done, Self.writeTools.contains(e.toolName ?? ""), let path = e.path {
                    touch(path, added: 0, removed: 0, writing: true, agent: agent)
                }
            } else {
                for c in e.changes { touch(c.path, added: c.added, removed: c.removed, writing: !e.done, agent: agent) }
            }
        }
        // The turn's entries sit together near the end (a peer's message may lead them).
        var i = entries.count - 1
        while i >= 0, entries[i].turn != id { i -= 1 }
        var first = i
        while first >= 0, entries[first].turn == id { first -= 1 }
        for e in entries[(first + 1)..<(i + 1)] where e.turn == id {
            add(e, agent: nil)
            if let info = e.agent { (lanes[info.id] ?? []).forEach { add($0, agent: info) } }
        }
        // The turn's own diff (git, or the CLI's), once it's in, has the final counts and any
        // file changed by a shell command.
        for c in turn.changes {
            let path = Self.resolved(c.path)
            var t = touches[path] ?? FileTouch(
                path: path, added: 0, removed: 0, turn: id, agentIndex: nil, agentName: nil, writing: false)
            t.added = c.added
            t.removed = c.removed
            touches[path] = t
        }
        return touches
    }

    /// Symlinks resolved (/tmp → /private/tmp), as FSEvents reports paths; each path once.
    private static func resolved(_ path: String) -> String {
        if let known = realPaths[path] { return known }
        let resolved: String
        if let real = realpath(path, nil) {
            resolved = String(cString: real)
            free(real)
        } else {
            // Not there (yet): asked again next time.
            return (path as NSString).standardizingPath
        }
        realPaths[path] = resolved
        return resolved
    }

    private static var realPaths: [String: String] = [:]

    // MARK: The agent map

    /// Every agent as a tree, parents before children, in spawn order.
    func agentTree() -> [AgentNode] {
        let infos = agentOrder.compactMap(agent)
        let children = Dictionary(grouping: infos, by: { $0.parent ?? "" })
        var nodes: [AgentNode] = []
        func walk(_ parent: String, depth: Int, rails: [Bool]) {
            let kids = children[parent] ?? []
            for (i, info) in kids.enumerated() {
                let last = i == kids.count - 1
                nodes.append(AgentNode(info: info, depth: depth, isLast: last, rails: rails))
                walk(info.id, depth: depth + 1, rails: rails + [!last])
            }
        }
        walk("", depth: 0, rails: [])
        return nodes
    }

    /// An agent's own items on their timeline, for the map's detail pane and an agent tab.
    func agentItems(_ id: String) -> [Item] {
        let rows = (lanes[id] ?? []).map(row)
        let dots = rows.map { Self.dot($0) ?? .plain }
        return rows.indices.map { i in
            Item(row: rows[i], dot: dots[i], above: i > 0, below: i + 1 < rows.count, id: rows[i].id)
        }
    }

    private func summarizeAgents() -> AgentSummary {
        guard !agentOrder.isEmpty else { return AgentSummary() }
        let infos = agentOrder.compactMap(agent)
        let refs = infos.map { AgentRef(id: $0.id, index: $0.index, name: $0.name, status: $0.status) }
        return AgentSummary(
            count: infos.count, running: refs.filter { $0.status == .running }, waiting: infos.contains { $0.waiting > 0 },
            first: Array(refs.prefix(3)), failed: infos.filter { $0.status == .failed }.map(\.id))
    }

    /// Claude frames a sub-agent's report with a first line of its own; the report is the rest.
    private static func handBack(_ output: String) -> String {
        guard output.hasPrefix("[Subagent hand-back]"), let newline = output.firstIndex(of: "\n") else { return output }
        return String(output[output.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Waiting agents

    /// A sub-agent asked the user for something.
    func agentAsked(_ approval: String, agent: String) {
        askedBy[approval] = agent
        updateAgent(agent) { $0.waiting += 1 }
    }

    /// The CLI waits on the user: the live fold row says so, and the spinner hides.
    func approvalAsked(_ approval: String, question: Bool) {
        pendingApprovals[approval] = question
        changed(turn: current)
    }

    /// The question was answered or withdrawn.
    func approvalSettled(_ approval: String) {
        if pendingApprovals.removeValue(forKey: approval) != nil { changed(turn: current) }
        guard let agent = askedBy.removeValue(forKey: approval) else { return }
        updateAgent(agent) { $0.waiting = max(0, $0.waiting - 1) }
    }

    private func settleAll() {
        for approval in Array(askedBy.keys) { approvalSettled(approval) }
    }

    /// Time spent working across the chat's turns, the running one included.
    var workedFor: TimeInterval {
        let running = current.flatMap { turns[$0] }.map { Date().timeIntervalSince($0.startedAt) } ?? 0
        return workedBefore + running
    }

    // MARK: Loading an agent's past

    /// The agent a card key ("entry id") stands for, if it's an agent's card.
    func agentID(forCard key: String) -> String? {
        guard let id = UUID(uuidString: key) else { return nil }
        if let i = position[id], let agent = entries[i].agent { return agent.id }
        return laneAgents.first { $0.value.entry == id }?.key
    }

    /// An agent whose own work isn't here yet: from a replayed chat, or a Codex child.
    func needsHistory(_ id: String) -> Bool {
        guard let info = agent(id), info.status != .running, !loadedAgents.contains(id) else { return false }
        return (lanes[id] ?? []).isEmpty
    }

    /// Replaces an agent's own work with its whole history (`ChatBackend.agentHistory`).
    func replaceLane(of id: String, with events: [ChatEvent]) {
        loadedAgents.insert(id)
        lanes[id] = []
        for (tool, ref) in laneTools where ref.agent == id { laneTools[tool] = nil }
        // The card's counts came with the agent; its history doesn't add to them.
        loadingHistory = true
        batch { events.forEach(apply) }
        loadingHistory = false
    }

    /// Opens or closes a sub-agent's card.
    func toggle(agent id: String) {
        if let card = agentCards[id] ?? laneAgents[id]?.entry { toggle(card.uuidString) }
    }

    /// An agent's result, unless its own last reply already says it (a loaded history ends with
    /// the reply the result repeats).
    static func distinctResult(_ info: AgentInfo, lane: [Entry]) -> String? {
        guard let result = info.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        let last = lane.last { $0.kind == .answer }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return last == result ? nil : result
    }

    func lane(_ id: String) -> [Entry] { lanes[id] ?? [] }

    /// A sub-agent's card details, for an approval it asks for.
    func agent(_ id: String) -> AgentInfo? {
        if let card = agentCards[id], let i = position[card] { return entries[i].agent }
        if let (parent, card) = laneAgents[id] { return lanes[parent]?.first { $0.id == card }?.agent }
        return nil
    }

    // MARK: Content

    func user(_ text: String, attachments: [Attachment], source: String? = nil) {
        if !batching { sentAt = Date() }
        var entry = Entry(kind: .user, text: text, attachments: attachments)
        entry.source = source
        append(entry)
        // Sending is drawn at once (the view scrolls to it).
        if !batching { rebuild() }
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

    func toolStarted(
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

    func toolOutput(id: String, _ text: String) {
        update(tool: id, files: false) { $0.result = ($0.result ?? "") + text }
    }

    /// `output` nil keeps what streamed. On an agent's spawning call (Claude's foreground Agent
    /// tool) the output is the agent's report, which becomes its result.
    func toolFinished(id: String, output: String?, isError: Bool) {
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

    /// An agent's open calls end as stopped, and its own agents with them.
    private func stopLane(_ agent: String) {
        guard var lane = lanes[agent] else { return }
        for i in lane.indices {
            if lane[i].kind == .tool, !lane[i].done {
                lane[i].done = true
                lane[i].stopped = true
            }
            if lane[i].agent?.status == .running {
                lane[i].agent?.status = .stopped
                if let child = lane[i].agent?.id { stopLane(child) }
            }
        }
        lanes[agent] = lane
        agentsVersion &+= 1
    }

    /// The turn was stopped while the call ran; what it printed before stays.
    func toolStopped(id: String) {
        update(tool: id) {
            $0.done = true
            $0.isError = false
            $0.stopped = true
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
        id: String, name: String, type: String?, model: String? = nil, prompt: String? = nil, background: Bool = false,
        tool: String?, parent: String? = nil, at date: Date = Date()
    ) {
        var entry = Entry(kind: .agent, text: name, toolId: tool)
        entry.agent = AgentInfo(
            id: id, index: agentCards.count + laneAgents.count, name: name, type: type, model: model, prompt: prompt,
            parent: parent, background: background, startedAt: date)
        agentOrder.append(id)
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

    func agentProgress(id: String, tokens: Int?, tools count: Int?, lastTool: String?, duration: TimeInterval?) {
        updateAgent(id) {
            if let tokens { $0.tokens = tokens }
            if let count { $0.tools = count }
            if let lastTool { $0.lastTool = lastTool }
            if let duration { $0.duration = duration }
        }
    }

    func agentFinished(id: String, status: AgentInfo.Status, result: String?, at date: Date = Date()) {
        // It can come twice (Claude background agents): the second carries the result.
        updateAgent(id) {
            $0.status = status
            if let result { $0.result = result }
            // A replayed agent has no timing of its own unless the CLI gave one.
            if $0.duration == nil, !self.batching { $0.duration = date.timeIntervalSince($0.startedAt) }
        }
    }

    // MARK: Opening and closing

    func toggle(turn id: String) {
        guard var turn = turns[id] else { return }
        turn.open = !Self.isOpen(turn)
        turn.touched = true
        turns[id] = turn
        mark(turnIndex(id))
        rebuild()
    }

    /// `key` is an entry id, maybe with a prefix or suffix ("explored-<id>", "<id>/all",
    /// "<id>/<path>").
    func toggle(_ key: String) {
        if openKeys.remove(key) == nil { openKeys.insert(key) }
        let id = key.hasPrefix("explored-") ? key.dropFirst("explored-".count) : Substring(key)
        mark(UUID(uuidString: String(id.prefix(36))).flatMap { position[$0] })
        rebuild()
    }

    /// A fold is open while its turn works, and closed once the answer starts, until the user
    /// opens or closes it.
    private static func isOpen(_ turn: Turn) -> Bool {
        turn.touched ? turn.open : !turn.finished && turn.answerFrom == nil
    }

    /// The user denied an action in the current turn (counted on its fold line).
    func actionDenied() {
        guard let current else { return }
        turns[current]?.denied += 1
    }

    // MARK: Building rows

    private func rebuild() {
        let signpost = RebuildStats.signposter.beginInterval("TranscriptRebuild")
        let began = DispatchTime.now().uptimeNanoseconds
        defer {
            RebuildStats.signposter.endInterval("TranscriptRebuild", signpost)
            RebuildStats.shared.record(Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6)
        }
        // Only the window is built (a long chat costs what its last turns cost), and of it only
        // the sections from the first change down; the ones above are kept as they are.
        let start = windowStartIndex
        let whole = sectionStarts.first != start
        guard whole || dirtyFrom != nil else { return }
        let from = whole ? start : max(dirtyFrom ?? entries.count, start)
        dirtyFrom = nil
        let kept = whole ? 0 : (sectionStarts.lastIndex { $0 <= from } ?? 0)
        let begin = whole ? start : sectionStarts[kept]

        var rows: [Row] = []
        var i = begin
        while i < entries.count {
            guard let turnID = entries[i].turn, let turn = turns[turnID] else {
                if let row = visibleRow(entries[i]) { rows.append(row) }
                i += 1
                continue
            }
            var end = i
            while end < entries.count, entries[end].turn == turnID { end += 1 }
            layout(turn, entries[i..<end], into: &rows)
            i = end
        }
        let summary = summarizeAgents()
        if summary != agentSummary { agentSummary = summary }
        if touchesDirty {
            touchesDirty = false
            let touches = touchedFiles()
            if touches != fileTouches { fileTouches = touches }
        }
        // Sections are the one built form of the transcript; nothing else keeps the rows. A
        // section that's still there keeps its model, so only its own view hears of a change.
        let old = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var models = Array(sections.prefix(kept))
        var starts = Array(sectionStarts.prefix(kept))
        var changed = false
        for section in Self.sections(rows, open: openKeys) {
            if let model = old[section.id] {
                if model.update(section) { changed = true }
                models.append(model)
            } else {
                models.append(SectionModel(section))
            }
            starts.append(section.header.flatMap { position[$0.id] } ?? begin)
        }
        sectionStarts = starts
        if models.count != sections.count || zip(models, sections).contains(where: { $0 !== $1 }) {
            sections = models
            changed = true
        }
        if changed { tail &+= 1 }
    }

    /// Everything is built again on the next rebuild (the window moved, or entries shifted).
    private func invalidateAll() {
        sectionStarts = []
        touchesDirty = true
    }

    /// Splits rows at each user or peer message, and places them on the timeline.
    private static func sections(_ rows: [Row], open: Set<String>) -> [Section] {
        var sections: [Section] = []
        var header: Entry?
        var id = "start"
        var run: [Row] = []
        func flush() {
            guard header != nil || !run.isEmpty else { return }
            let dots = run.map(dot)
            var ids: Set<String> = []
            let items = run.indices.map { i in
                let id = run[i].id
                return Item(
                    row: run[i], dot: dots[i],
                    above: dots[i] != nil && i > 0 && dots[i - 1] != nil,
                    below: dots[i] != nil && i + 1 < dots.count && dots[i + 1] != nil,
                    id: ids.insert(id).inserted ? id : id + "/call")
            }
            let headerOpen = header.map { $0.kind == .user || open.contains($0.id.uuidString) } ?? false
            sections.append(Section(id: id, header: header, headerOpen: headerOpen, items: items))
        }
        for row in rows {
            if case .entry(let e) = row, e.kind == .user || e.kind == .peer {
                flush()
                header = e
                id = "s-" + e.id.uuidString
                // The message itself is the section's first row; the pinned header is only its
                // first lines, once it has scrolled past.
                let opened = e.kind == .user || open.contains(e.id.uuidString)
                run = [.message(e, open: opened, expanded: open.contains(MessageHeader.expandKey(e)))]
            } else {
                run.append(row)
            }
        }
        flush()
        return sections
    }

    static func dot(_ row: Row) -> TimelineDot? {
        func state(_ e: Entry) -> TimelineDot { !e.done ? .running : e.stopped ? .plain : e.isError ? .failure : .success }
        switch row {
        case .entry(let e):
            switch e.kind {
            case .answer, .plan: return .plain
            case .notice: return e.isError ? .failure : .plain
            default: return nil
            }
        case .thinking: return .plain
        case .fold(let f):
            if f.live { return .running }
            switch f.outcome {
            case .failed: return .failure
            case .interrupted: return .warning
            case nil: return f.failed ? .failure : .plain
            }
        case .explored(let calls, _):
            if calls.contains(where: { !$0.done }) { return .running }
            return calls.contains(where: \.isError) ? .failure : .success
        case .spinner, .message: return nil
        case .rule: return TimelineDot.none
        case .outcome(_, let text): return text == "Interrupted" ? .warning : .failure
        case .changes: return .plain
        case .tool(let e, _): return state(e)
        case .file(let e, _, _): return state(e)
        case .agent(let e, _, _):
            return e.agent.map { .agent(index: $0.index, name: $0.name, status: $0.status, waiting: $0.waiting > 0) }
        }
    }

    /// The answer block in progress ends when another block or a tool starts: it's no longer
    /// streaming, so all of it shows.
    private func endAnswer() {
        guard let last = entries.indices.last, entries[last].kind == .answer, !entries[last].done else { return }
        entries[last].done = true
        mark(last)
    }

    /// The thinking block in progress ends when anything else starts.
    private func endThinking() {
        guard let last = entries.indices.last, entries[last].kind == .thinking, entries[last].duration == nil,
            let start = entries[last].startedAt
        else { return }
        entries[last].duration = Date().timeIntervalSince(start)
        entries[last].done = true
        mark(last)
    }

    /// A turn. While it works, a live fold row (look.md §12) heads its work, open, saying what's
    /// happening, and a spinner row ends it. Once its answer starts, the work folds above the
    /// answer.
    private func layout(_ turn: Turn, _ group: ArraySlice<Entry>, into rows: inout [Row]) {
        // A stopped or failed turn that ended on work keeps its last tool call in view, below
        // the fold; whatever came with or after it (late thinking) goes into the fold, the same
        // for both CLIs ("Worked for 8s · Interrupted").
        if turn.finished, turn.outcome != .completed, answerStart(turn, group) != nil,
            !group.contains(where: { $0.kind == .answer }),
            let kept = group.lastIndex(where: { $0.kind == .tool || $0.kind == .agent })
        {
            var reordered = Array(group)
            let call = reordered.remove(at: kept - group.startIndex)
            reordered.append(call)
            layout(turn, reordered[...], keepingLast: true, into: &rows)
            return
        }
        layout(turn, group, keepingLast: false, into: &rows)
    }

    private func layout(_ turn: Turn, _ group: ArraySlice<Entry>, keepingLast: Bool, into rows: inout [Row]) {
        let split = keepingLast ? group.endIndex - 1 : answerStart(turn, group)
        let work = split.map { group[group.startIndex..<$0] } ?? group
        let foldable = work.filter { !Self.pinned($0) }
        let live = !turn.finished && split == nil
        // A live turn's fold comes with its first piece of work; a finished turn's, when work
        // went before its answer, or when it stopped on work.
        let folds = live ? foldable.contains(where: Self.isWork) : split != nil && (!foldable.isEmpty || keepingLast)
        guard folds else {
            rows.append(contentsOf: grouped(group))
            finish(turn, folded: false, into: &rows)
            return
        }
        // Prompts (a peer's message) stay above the fold.
        let prompts = work.prefix { $0.kind == .peer || $0.kind == .user }
        rows.append(contentsOf: prompts.compactMap(visibleRow))
        let tools = group.filter { $0.kind == .tool || $0.kind == .agent }
        let failed = tools.filter { $0.isError || $0.agent?.status == .failed }.count
        let label: String
        if live {
            label = liveLabel(turn, group)
            turns[turn.id]?.liveLabel = label
        } else {
            let worked = turn.finished ? turn.duration : turn.workEnded.map { $0.timeIntervalSince(turn.startedAt) }
            label = WorkedFor.label(duration: worked, items: foldable.count)
        }
        let open = Self.isOpen(turn)
        rows.append(.fold(Fold(
            turn: turn.id, label: label, outcome: foldOutcome(turn), denied: turn.denied, open: open, live: live,
            count: live && !tools.isEmpty ? Self.count(tools.count, failed: failed) : nil, failed: failed > 0)))
        let rest = work.dropFirst(prompts.count)
        rows.append(contentsOf: open ? grouped(rest) : rest.filter(Self.pinned).compactMap(visibleRow))
        if let split {
            rows.append(.rule(turn: turn.id))
            rows.append(contentsOf: grouped(group[split...]))
        }
        finish(turn, folded: split != nil, into: &rows)
    }

    /// A running turn ends with the spinner (hidden while an approval waits: the fold says so);
    /// a finished one with its outcome and files.
    private func finish(_ turn: Turn, folded: Bool, into rows: inout [Row]) {
        if turn.finished {
            trailer(turn, folded: folded, into: &rows)
        } else if pendingApprovals.isEmpty {
            rows.append(
                .spinner(
                    turn: turn.id, since: turn.startedAt, claude: providerName == "Claude",
                    word: compactingNow ? "Compacting" : nil))
        }
    }

    /// What the live fold row says: waiting on the user, the tool that's running, thinking, or
    /// else what it said last.
    private func liveLabel(_ turn: Turn, _ group: ArraySlice<Entry>) -> String {
        if !pendingApprovals.isEmpty {
            return pendingApprovals.values.contains(true) ? "Waiting for your answer…" : "Waiting for permission…"
        }
        if let running = group.last(where: { ($0.kind == .tool && !$0.done) || $0.agent?.status == .running }) {
            // Codex calls every command "Run"; "Running Run…" would read oddly.
            let name = running.kind == .agent ? "Agent" : running.toolName == "Run" ? "command" : running.toolName ?? "tool"
            return "Running \(name)…"
        }
        if let last = group.last, last.kind == .thinking, !last.done { return "Thinking…" }
        return turn.liveLabel ?? "Thinking…"
    }

    /// "3 tool calls · 1 failed".
    private static func count(_ calls: Int, failed: Int) -> String {
        let text = calls == 1 ? "1 tool call" : "\(calls) tool calls"
        return failed > 0 ? "\(text) · \(failed) failed" : text
    }

    /// Rows for a run of entries, with two or more consecutive read-only tool calls grouped into
    /// one "Explored N" item (open, it's followed by the calls themselves).
    private func grouped(_ run: some Collection<Entry>) -> [Row] {
        let run = Array(run)
        var rows: [Row] = []
        var i = 0
        while i < run.count {
            var end = i
            while end < run.count, run[end].kind == .tool, run[end].readOnly, run[end].changes.isEmpty { end += 1 }
            if end - i >= 2 {
                let calls = Array(run[i..<end])
                let open = openKeys.contains("explored-\(calls[0].id.uuidString)")
                rows.append(.explored(calls, open: open))
                if open { rows.append(contentsOf: calls.map(row)) }
                i = end
            } else {
                if let row = visibleRow(run[i]) { rows.append(row) }
                i += 1
            }
        }
        return rows
    }

    /// A row as drawn now. A streaming answer shows up to its last blank line (the extension's
    /// settled blocks; `MarkdownView` cuts at the same place), so its row changes only when a
    /// block completes; before the first one, it has no row yet.
    private func visibleRow(_ entry: Entry) -> Row? {
        guard entry.kind == .answer, !entry.done else { return row(entry) }
        guard let blank = entry.text.range(of: "\n\n", options: .backwards) else { return nil }
        var settled = entry
        settled.text = String(entry.text[..<blank.upperBound])
        return .entry(settled)
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

    /// Draws the change: at once for a batch's end or a user's action, else at most once per
    /// `drawInterval`, so a fast stream of deltas costs one rebuild per frame, not one per token.
    /// `index` is the entry that changed; nil when it's not known (everything shown is built
    /// again).
    private func changed(at index: Int? = nil) {
        mark(index)
        guard !batching, !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drawInterval) { [weak self] in
            guard let self else { return }
            drawScheduled = false
            rebuild()
        }
    }

    private func mark(_ index: Int?) {
        let i = max(index ?? 0, 0)
        dirtyFrom = min(dirtyFrom ?? i, i)
    }

    /// A change to a turn: its rows are laid out together.
    private func changed(turn id: String?) {
        changed(at: turnIndex(id))
    }

    /// The turn's first entry, or the last entry for a turn with none yet; nil for no turn.
    private func turnIndex(_ id: String?) -> Int? {
        guard let id else { return entries.count - 1 }
        return turnFirst[id].flatMap { position[$0] } ?? (current == id ? entries.count - 1 : nil)
    }

    /// The chat's own card an agent's work shows in: its card, or its parent's, up to the one
    /// on the transcript.
    private func cardIndex(_ agent: String) -> Int? {
        var id = agent
        while true {
            if let card = agentCards[id], let i = position[card] { return i }
            guard let parent = laneAgents[id]?.parent else { return nil }
            id = parent
        }
    }

    private func append(_ entry: Entry) {
        position[entry.id] = entries.count
        entries.append(entry)
        if let turn = entry.turn, turnFirst[turn] == nil { turnFirst[turn] = entry.id }
        changed(at: entries.count - 1)
    }

    private func insert(_ entry: Entry, at index: Int) {
        entries.insert(entry, at: index)
        for i in index..<entries.count { position[entries[i].id] = i }
        if let turn = entry.turn, turnFirst[turn].flatMap({ position[$0] }).map({ index <= $0 }) ?? true {
            turnFirst[turn] = entry.id
        }
        invalidateAll()
        countHidden()
        changed()
    }

    private func update(tool id: String, files: Bool = true, _ change: (inout Entry) -> Void) {
        let at: Int?
        if let (agent, index) = laneTools[id] {
            if lanes[agent]?.indices.contains(index) == true { change(&lanes[agent]![index]) }
            agentsVersion &+= 1
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

    private func updateAgent(_ id: String, _ change: (inout AgentInfo) -> Void) {
        agentsVersion &+= 1
        if let card = agentCards[id], let i = position[card], entries[i].agent != nil {
            change(&entries[i].agent!)
            changed(at: i)
            return
        } else if let (parent, card) = laneAgents[id], let i = lanes[parent]?.firstIndex(where: { $0.id == card }),
            lanes[parent]![i].agent != nil
        {
            change(&lanes[parent]![i].agent!)
        } else {
            return
        }
        changed(at: cardIndex(id))
    }

    private func laneAppend(agent: String, _ entry: Entry) {
        lanes[agent, default: []].append(entry)
        agentsVersion &+= 1
        touchesDirty = true
    }

    private func laneText(agent: String, block: String, kind: Entry.Kind, text: String) {
        let key = "\(agent)/\(block)"
        if let id = blocks[key], let i = lanes[agent]?.firstIndex(where: { $0.id == id }) {
            lanes[agent]![i].text += text
            agentsVersion &+= 1
        } else {
            // A sub-agent's text isn't drawn as it streams (Claude's comes whole anyway).
            var entry = Entry(kind: kind, text: text)
            entry.done = true
            blocks[key] = entry.id
            laneAppend(agent: agent, entry)
        }
        changed(at: cardIndex(agent))
    }

    private func announceFold(_ turn: String) {
        guard !batching, let t = turns[turn] else { return }
        let answer = t.answerFrom?.uuidString ?? "rule-\(turn)"
        foldSeq += 1
        folded = (turn, answer, foldSeq)
    }
}

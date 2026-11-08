import AppKit
import Foundation
import KoreCore
import Observation
import src

/// The conversation as the transcript draws it. Entries arrive in order and are grouped into
/// turns; a finished turn folds its work into one "Worked for …" line above its answer.
/// `sections` is rebuilt from the entries after every change, and each row compares by value, so
/// SwiftUI redraws only the rows that changed. Views see only `sections`, `tail` and `folded`.
@MainActor @Observable
package final class TranscriptStore {
    /// The entries, turns and agents the rows are built from.
    package let log = TranscriptLog()

    init() {
        log.view = self
        log.agentShapes = AgentShape.allCases.count
    }

    // MARK: The log's state and calls, as the store's

    package typealias Entry = TranscriptLog.Entry
    package typealias AgentInfo = TranscriptLog.AgentInfo
    package typealias Outcome = TranscriptLog.Outcome
    package typealias Turn = TranscriptLog.Turn
    private(set) var sentAt: Date? {
        get { log.sentAt }
        _modify { yield &log.sentAt }
    }
    package private(set) var pendingSendSince: Date? {
        get { log.pendingSendSince }
        _modify { yield &log.pendingSendSince }
    }
    private var parkedAgents: [String: AgentInfo] {
        get { log.parkedAgents }
        _modify { yield &log.parkedAgents }
    }
    private var keptLanes: Set<String> {
        get { log.keptLanes }
        _modify { yield &log.keptLanes }
    }
    private var touchesDirty: Bool {
        get { log.touchesDirty }
        _modify { yield &log.touchesDirty }
    }
    private var lastAnswerTurn: String? {
        get { log.lastAnswerTurn }
        _modify { yield &log.lastAnswerTurn }
    }
    private var turnFirst: [String: UUID] {
        get { log.turnFirst }
        _modify { yield &log.turnFirst }
    }
    private var refusedTurns: [String] {
        get { log.refusedTurns }
        _modify { yield &log.refusedTurns }
    }
    private var pendingApprovals: [String: Bool] {
        get { log.pendingApprovals }
        _modify { yield &log.pendingApprovals }
    }
    private var compactingSince: Date? {
        get { log.compactingSince }
        _modify { yield &log.compactingSince }
    }
    private var connection: Connection {
        get { log.connection }
        _modify { yield &log.connection }
    }
    private var compactingAt: Int? {
        get { log.compactingAt }
        _modify { yield &log.compactingAt }
    }
    private var latestTurn: String? {
        get { log.latestTurn }
        _modify { yield &log.latestTurn }
    }
    private var retryDismissed: String? {
        get { log.retryDismissed }
        _modify { yield &log.retryDismissed }
    }
    package private(set) var entries: [Entry] {
        get { log.entries }
        _modify { yield &log.entries }
    }
    private var position: [UUID: Int] {
        get { log.position }
        _modify { yield &log.position }
    }
    func index(of id: UUID) -> Int? { log.index(of: id) }
    private var turns: [String: Turn] {
        get { log.turns }
        _modify { yield &log.turns }
    }
    private var current: String? {
        get { log.current }
        _modify { yield &log.current }
    }
    private var liveTurn: String? {
        get { log.liveTurn }
        _modify { yield &log.liveTurn }
    }
    private var liveSendSince: Date? {
        get { log.liveSendSince }
        _modify { yield &log.liveSendSince }
    }
    private var blocks: [String: UUID] {
        get { log.blocks }
        _modify { yield &log.blocks }
    }
    private var tools: [String: UUID] {
        get { log.tools }
        _modify { yield &log.tools }
    }
    private var lanes: [String: [Entry]] {
        get { log.lanes }
        _modify { yield &log.lanes }
    }
    private var laneTools: [String: (agent: String, index: Int)] {
        get { log.laneTools }
        _modify { yield &log.laneTools }
    }
    private var agentCards: [String: UUID] {
        get { log.agentCards }
        _modify { yield &log.agentCards }
    }
    private var batching: Bool {
        get { log.batching }
        _modify { yield &log.batching }
    }
    package var providerName: String {
        get { log.providerName }
        _modify { yield &log.providerName }
    }
    private var laneAgents: [String: (parent: String, entry: UUID)] {
        get { log.laneAgents }
        _modify { yield &log.laneAgents }
    }
    private var agentOrder: [String] {
        get { log.agentOrder }
        _modify { yield &log.agentOrder }
    }
    private var loadedAgents: Set<String> {
        get { log.loadedAgents }
        _modify { yield &log.loadedAgents }
    }
    private var loadingHistory: Bool {
        get { log.loadingHistory }
        _modify { yield &log.loadingHistory }
    }
    private var workedBefore: TimeInterval {
        get { log.workedBefore }
        _modify { yield &log.workedBefore }
    }
    var turnIsOpen: Bool { log.turnIsOpen }
    private func endUnfinishedAgents(from first: Int = 0) { log.endUnfinishedAgents(from: first) }
    package func compacting(_ on: Bool, at point: Int? = nil) { log.compacting(on, at: point) }
    var connectionWord: String? { log.connectionWord }
    package var workRunning: Bool { log.workRunning }
    package func connected(_ state: Connection) { log.connected(state) }
    private var turnShowsSpinner: Bool { log.turnShowsSpinner }
    func compacted(at date: Date, auto: Bool? = nil) { log.compacted(at: date, auto: auto) }
    func compactionFailed(_ reason: String) { log.compactionFailed(reason) }
    package func compactionSummary(_ text: String, title: String? = nil) { log.compactionSummary(text, title: title) }
    package func forkedFrom(_ title: String) { log.forkedFrom(title) }
    package func continued(_ text: String, help: String) { log.continued(text, help: help) }
    package func carriedFrom(_ text: String, help: String) { log.carriedFrom(text, help: help) }
    static let forkSource = TranscriptLog.forkSource
    static let compactionRow = TranscriptLog.compactionRow
    private static let time = TranscriptLog.time
    func turnStarted(_ id: String, at date: Date = Date()) { log.turnStarted(id, at: date) }
    func finalAnswer(block: String) { log.finalAnswer(block: block) }
    func turnFinished(_ id: String?, _ outcome: Outcome, duration: TimeInterval? = nil, at date: Date = Date(), preserving observed: Set<String> = []) { log.turnFinished(id, outcome, duration: duration, at: date, preserving: observed) }
    func turnChanges(_ id: String, _ changes: [FileChange]) { log.turnChanges(id, changes) }
    func changes(ofTurn id: String) -> [FileChange] { log.changes(ofTurn: id) }
    var latestTurnSlept: Bool { log.latestTurnSlept }
    func agentAsked(_ approval: String, agent: String) { log.agentAsked(approval, agent: agent) }
    func approvalAsked(_ approval: String, question: Bool) { log.approvalAsked(approval, question: question) }
    package func approvalSettled(_ approval: String) { log.approvalSettled(approval) }
    var workedFor: TimeInterval { log.workedFor }
    func agentID(forCard key: String) -> String? { log.agentID(forCard: key) }
    package func keepLane(of id: String) { log.keepLane(of: id) }
    package func needsHistory(_ id: String) -> Bool { log.needsHistory(id) }
    func lane(_ id: String) -> [Entry] { log.lane(id) }
    package func agent(_ id: String) -> AgentInfo? { log.agent(id) }
    func user(_ text: String, attachments: [SentAttachment], source: String? = nil) { log.user(text, attachments: attachments, source: source) }
    func peer(from: String, text: String, turn: String?, source: String? = nil) { log.peer(from: from, text: text, turn: turn, source: source) }
    typealias TextKind = TranscriptLog.TextKind
    func text(_ block: String, _ kind: TextKind, _ text: String, agent: String? = nil) { log.text(block, kind, text, agent: agent) }
    func toolStarted( id: String, name: String, detail: String, input: String? = nil, summary: String? = nil, path: String? = nil, readOnly: Bool = false, agent: String? = nil ) { log.toolStarted(id: id, name: name, detail: detail, input: input, summary: summary, path: path, readOnly: readOnly, agent: agent) }
    func toolOutput(id: String, _ text: String) { log.toolOutput(id: id, text) }
    func toolFinished(id: String, output: String?, isError: Bool) { log.toolFinished(id: id, output: output, isError: isError) }
    func toolStopped(id: String) { log.toolStopped(id: id) }
    func fileChanged(tool id: String, _ changes: [FileChange]) { log.fileChanged(tool: id, changes) }
    private var queued: [(id: String, entry: Entry)] {
        get { log.queued }
        _modify { yield &log.queued }
    }
    func messageQueued(id: String, text: String, attachments: [SentAttachment]) { log.messageQueued(id: id, text: text, attachments: attachments) }
    func queuedMessage(id: String, _ delivery: QueuedDelivery) { log.queuedMessage(id: id, delivery) }
    package var provider: ProviderDescriptor? {
        get { log.provider }
        _modify { yield &log.provider }
    }
    private var permissionsMode: String? {
        get { log.permissionsMode }
        _modify { yield &log.permissionsMode }
    }
    private var planOn: Bool {
        get { log.planOn }
        _modify { yield &log.planOn }
    }
    private func option(_ id: String) -> ModeOption? { log.option(id) }
    func modeChanged(_ change: ModeChange) { log.modeChanged(change) }
    func planModeChanged(_ change: PlanModeChange) { log.planModeChanged(change) }
    private func refused(asked: String, kept: String) { log.refused(asked: asked, kept: kept) }
    func notice(_ text: String, isError: Bool) { log.notice(text, isError: isError) }
    func freeAgentIndex() -> Int { log.freeAgentIndex() }
    func agentSpawned( id: String, name: String, type: String?, model: String? = nil, prompt: String? = nil, background: Bool = false, tool: String?, parent: String? = nil, at date: Date = Date() ) { log.agentSpawned(id: id, name: name, type: type, model: model, prompt: prompt, background: background, tool: tool, parent: parent, at: date) }
    func agentProgress( id: String, tokens: Int?, tools count: Int?, lastTool: String?, duration: TimeInterval?, approximate: Bool = false ) { log.agentProgress(id: id, tokens: tokens, tools: count, lastTool: lastTool, duration: duration, approximate: approximate) }
    func agentFinished(id: String, status: AgentInfo.Status, result: String?, at date: Date = Date()) { log.agentFinished(id: id, status: status, result: result, at: date) }
    func agentResumed(id: String, at date: Date = Date()) { log.agentResumed(id: id, at: date) }
    func agentBackgrounded(id: String) { log.agentBackgrounded(id: id) }
    package func actionDenied() { log.actionDenied() }
    func refused(_ id: String, _ refusal: Refusal) { log.refused(id, refusal) }
    package func prompt(of turn: String) -> String? { log.prompt(of: turn) }
    package var retryableTurn: String? { log.retryableTurn }
    private func changed(turn id: String?) { log.changed(turn: id) }
    private func turnIndex(_ id: String?) -> Int? { log.turnIndex(id) }
    private func cardIndex(_ agent: String) -> Int? { log.cardIndex(agent) }
    private func update(tool id: String, files: Bool = true, _ change: (inout Entry) -> Void) { log.update(tool: id, files: files, change) }

    package func apply(_ event: ChatEvent) { log.apply(event) }
    package func apply(_ event: ChatEvent, preserving observed: Set<String>) { log.apply(event, preserving: observed) }

    // MARK: Chips

    /// Each user message's file chips, by its entry: made as the message comes in, so a chip
    /// keeps its identity (and its decoded picture) for as long as its row.
    @ObservationIgnored private var chipsByEntry: [UUID: [Attachment]] = [:]

    package func chips(_ entry: Entry) -> [Attachment] { chipsByEntry[entry.id] ?? [] }

    package func chips(_ files: [SentAttachment], for entry: UUID, from earlier: UUID?) {
        if let earlier, let made = chipsByEntry.removeValue(forKey: earlier) {
            chipsByEntry[entry] = made
        } else {
            chipsByEntry[entry] = files.map(Self.chip)
        }
    }

    package func dropChips(_ entry: UUID) { chipsByEntry[entry] = nil }

    package func agentsChanged() { agentsVersion &+= 1 }

    static func chip(_ a: SentAttachment) -> Attachment {
        if let url = a.url, FileManager.default.fileExists(atPath: url.path) { return Attachment(url: url) }
        return Attachment(name: a.name, kind: a.kind, imageData: a.image)
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
        /// `continues`: the turn ended on its plan's limit, and the chat continues at the reset.
        case outcome(turn: String, text: String, continues: Date? = nil, sends: String? = nil, retry: Bool = false, refusal: Refusal? = nil)
        /// A turn the CLI's login refused: Kore's words, the CLI's line, and Sign in.
        case signIn(turn: String, said: String)
        /// A turn that failed while the Mac slept: Kore's words, the CLI's line, and Continue.
        case slept(turn: String, said: String)
        case changes(turn: String, files: Int, added: Int, removed: Int)
        /// Two or more consecutive read-only tool calls, as one "Explored N" item.
        case explored([Entry], open: Bool)
        /// A user or peer message, first in its section; `expanded` shows a long one whole.
        case message(Entry, open: Bool, expanded: Bool)
        /// A compaction's summary, collapsed until `expanded` (look.md §5).
        case summary(Entry, expanded: Bool)
        /// A message sent while the turn runs, waiting at the end (look.md §10).
        case queued(Entry)
        /// The running turn's last row: glyph and verb (look.md §12); `word` in place of the
        /// random verb ("Compacting").
        case spinner(turn: String, since: Date, claude: Bool, word: String?, connection: Connection = .ok)

        var id: String {
            switch self {
            case .entry(let e), .tool(let e, _), .thinking(let e, _), .file(let e, _, _), .agent(let e, _, _),
                .message(let e, _, _), .summary(let e, _):
                e.id.uuidString
            // Not the message's own id: once the CLI takes it, the row that shows it in the turn
            // is another view, and the waiting one (with its "Queued") goes.
            case .queued(let e): "queued-\(e.id.uuidString)"
            case .fold(let f): "fold-\(f.turn)"
            case .rule(let t): "rule-\(t)"
            case .outcome(let t, _, _, _, _, _), .signIn(let t, _), .slept(let t, _): "outcome-\(t)"
            case .changes(let t, _, _, _): "changes-\(t)"
            // The first call's: a read-only call that becomes a group keeps its identity.
            case .explored(let entries, _): entries.first?.id.uuidString ?? "explored"
            case .spinner(let t, _, _, _, _): "spinner-\(t)"
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
        /// The agent left the turn in another mode than it began in: " · now {mode}".
        var now: ModeMark?
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
        /// The action row under a message or a finished turn's final answer (look §11).
        var actions: MessageActions?
    }

    /// The chat's first message: nothing comes before it to roll back to.
    private var firstMessage: UUID? { hasUnloaded ? nil : entries.first { $0.kind == .user || $0.kind == .peer }?.id }

    struct MessageActions: Equatable {
        /// Always shown (the chat's newest finished answer); otherwise only under the pointer.
        let always: Bool
        /// False on the message of a turn that's still running.
        let canFork: Bool
        /// False where nothing would go or nothing would stay: the newest answer, the first message.
        let canRollBack: Bool
    }

    /// One user (or peer) message and what followed it. The header sticks to the top while
    /// its section scrolls by. Its id is "s-<message id>" ("start" before the first message),
    /// distinct from the message row's own. A message sent during a turn starts a section of its
    /// own in that turn, so the latest one sticks.
    struct Section: Identifiable, Equatable {
        let id: String
        let header: Entry?
        /// A peer's message starts as one line (owner, 2026-10-21); opened, it shows in full.
        let headerOpen: Bool
        let items: [Item]
        /// The message whose turn it's in: where a rebuild of it starts.
        var turn: UUID? = nil
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
    var agentSummary: AgentSummary {
        access(keyPath: \.agentSummary)
        return storedSummary
    }

    @ObservationIgnored private var storedSummary = AgentSummary()

    /// Stored first, then announced. Observers hear of a change before it's made, and SwiftUI
    /// can draw right then (an observer's change ends its update group, which carries out a
    /// scroll view's pending commit at once): the Agents button read the old summary, nothing
    /// came after, and it stayed hidden with agents in the chat.
    private func publish(_ summary: AgentSummary) {
        guard summary != storedSummary else { return }
        storedSummary = summary
        withMutation(keyPath: \.agentSummary) {}
    }

    struct AgentSummary: Equatable {
        /// Agents that did or are doing work: the stopped ones are counted apart.
        var count = 0
        var stopped = 0
        /// Every agent, the stopped ones too: what the Agents button and the map's header count.
        var total: Int { count + stopped }
        /// Running agents' mark indexes and ids, in spawn order.
        var running: [AgentRef] = []
        /// Some agent is waiting for the user.
        var waiting = false
        /// The first few agents, for the idle stack; the stopped ones when there are no others.
        var first: [AgentRef] = []
        var failed: [String] = []
    }

    /// Up to `limit` agents with different shapes, in order: a stack never shows one shape twice.
    static func distinctShapes(_ refs: [AgentRef], limit: Int = 3) -> [AgentRef] {
        var seen = Set<Int>(), picked: [AgentRef] = []
        for ref in refs where picked.count < limit && seen.insert(ref.index % AgentShape.allCases.count).inserted {
            picked.append(ref)
        }
        return picked
    }

    struct AgentRef: Equatable, Identifiable {
        let id: String
        let index: Int
        let name: String
        let status: AgentInfo.Status
        var background = false
    }

    /// One row of the agent map's tree.
    struct AgentNode: Identifiable, Equatable {
        let info: AgentInfo
        let depth: Int
        /// The last of its parent's children (└ rather than ├).
        let isLast: Bool
        /// For each ancestor level, whether a line continues below (│).
        let rails: [Bool]
        /// It runs behind the chat: it, or an agent above it, is a background agent.
        var background = false
        var id: String { info.id }
    }

    /// Bumped when a turn folds by itself, so the view can keep the answer where it was.
    private(set) var folded: (turn: String, answer: String, seq: Int)?

    /// User turns before the shown window: the "Load earlier turns" row shows while any are.
    private(set) var hiddenTurns = 0

    /// Every user message of the chat, loaded or not.
    private(set) var messageMarks: [MessageMark] = []

    /// The ones not loaded, oldest first.
    private(set) var earlierMarks: [EarlierMessage] = []

    var pendingMessage: (query: String, until: Date)?

    /// What a storyline presses on the scroller, once it's on screen.
    @ObservationIgnored package var storyRail: (jump: (Int) -> Void, hover: (Int?) -> Void, current: () -> Int?)?

    /// Conversation before what the CLI's history shows (before a compaction): once the shown
    /// turns are all in view, the top row loads it.
    package private(set) var earlierAvailable = false

    package private(set) var loadingEarlier = false

    /// The files the latest turn changed, by path (`turnChanges()`).
    private(set) var fileTouches: [String: FileTouch] = [:]

    package func sending(_ on: Bool, at date: Date = Date()) {
        guard !batching, on != (pendingSendSince != nil) else { return }
        pendingSendSince = on ? date : nil
        // Starting a send also suppresses an unfinished historical turn's spinner, which
        // can live in an earlier section than the new message.
        changed(at: turnIndex(current) ?? entries.count - 1)
    }

    /// Where the reader was when the chat's view went away (a tab switch past the kept chats),
    /// to come back to: the message or answer row nearest the top and how far below its top the
    /// top is, or the end. Opened folds and rows stay in this store, so they need no saving.
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

    /// The user turns a chat keeps in memory; older ones are read back from its CLI's history
    /// when the reader goes up to them (`unloadPoint`, `unload`).
    static let keptTurns = 15

    /// Turns of this chat left memory and haven't all come back.
    @ObservationIgnored private var hasUnloaded = false

    package var mayHaveLeft: Bool { hasUnloaded }

    /// Whether the reader is at the end, nothing moving the view: set by the timeline while it's
    /// up. Gone, `savedScroll` says.
    @ObservationIgnored var readerAtEnd: (() -> Bool)?

    /// Which view those are.
    @ObservationIgnored var readerView: ObjectIdentifier?

    /// The timeline's views showing this chat (a tab's, a board tile's), its covered window aside.
    /// On screen, turns never leave but the unbuilt ones as it opens: rows going from above change
    /// what the lazy stack estimates of all the rest, and can leave the view past its rows with
    /// nothing drawn.
    @ObservationIgnored var viewsOnScreen = 0

    /// Its tab is the one shown, in a window nothing shows.
    @ObservationIgnored var covered = false

    var isOnScreen: Bool { viewsOnScreen > 0 && !covered }

    /// Takes the view to the end, as it shows again after turns left.
    @ObservationIgnored var backAtEnd: (() -> Void)?

    @ObservationIgnored private var leftUnseen = false

    /// Changes when turns leave.
    private(set) var unloads = 0

    /// Seen again: at the end, if turns left meanwhile.
    func seenAgain() {
        guard leftUnseen else { return }
        leftUnseen = false
        DispatchQueue.main.async { [weak self] in self?.backAtEnd?() }
    }

    /// Until then nothing leaves: a page just read in, or a message searched for, is what its
    /// reader is on the way to.
    @ObservationIgnored private var staysUntil = Date.distantPast

    private static let readInStays: TimeInterval = 2

    /// What a turn that left memory knew beyond its CLI's history, by its id and its message's
    /// (one CLI's turn ids last, the other's message ids do), for when it's read back.
    @ObservationIgnored private var leftTurns: [String: LeftTurn] = [:]

    /// The time the turns that left took, still in `workedBefore`: reading them back doesn't add it twice.
    @ObservationIgnored private var leftWork: TimeInterval = 0

    private struct LeftTurn {
        let duration: TimeInterval?
        let outcome: Outcome
        let denied: Int
        let open: Bool
        let touched: Bool
        let startMode: String?
        let endMode: String?
    }

    /// The lowest entry index changed since the last rebuild: sections from the one holding it
    /// are built again, the ones above are kept. nil: nothing changed.
    @ObservationIgnored private var dirtyFrom: Int?

    /// Where each of `sections` starts in `entries`.
    @ObservationIgnored private var sectionStarts: [Int] = []

    /// Final answers' actions, by row id, filled while a rebuild lays out turns.
    @ObservationIgnored private var answerActions: [String: MessageActions] = [:]

    /// Changes waiting to be drawn: streamed deltas are drawn once per `drawInterval`.
    @ObservationIgnored private var drawScheduled = false

    static let drawInterval: TimeInterval = 1.0 / 30

    /// No one sees it (a tab under another, a covered or minimised window): its rows still
    /// follow the stream, a couple of times a second, and catch up at once when it shows.
    static let hiddenDrawInterval: TimeInterval = 0.5

    /// Set by the chat's view: off screen, rebuilds slow to `hiddenDrawInterval`.
    @ObservationIgnored var hidden = false {
        didSet {
            guard oldValue, !hidden, drawScheduled else { return }
            drawScheduled = false
            rebuild()
        }
    }

    /// The transcript's one text selection.
    @ObservationIgnored lazy var selection = TranscriptSelection(store: self)

    /// Scrolls the timeline to a row by its id: set by the timeline for storylines only
    /// (`StoryTranscript.show`).
    @ObservationIgnored var storyScroll: ((String) -> Void)?

    @ObservationIgnored var storyRebuild: (() -> Void)?

    @ObservationIgnored var storyScrollView: (() -> NSScrollView?)?

    /// Opened file rows and agent cards (entry ids), and files inside a multi-file row
    /// ("id/path"). Kept in memory only: a reopened chat starts closed.
    @ObservationIgnored private var openKeys: Set<String> = []

    @ObservationIgnored private var foldSeq = 0

    /// The chat's id for the logs, once it has one.
    @ObservationIgnored package var chatID: (() -> String?)?

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
    package func replay(_ events: [ChatEvent]) {
        batch {
            events.forEach(apply)
            // A past compaction that never finished isn't still running.
            compactingSince = nil
            compactingAt = nil
            endUnfinishedAgents()
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

    /// The user turns the store holds, shown or not.
    package var userTurns: Int { entries.count { $0.kind == .user } }

    package func countHidden() {
        let hidden = entries[..<windowStartIndex].count { $0.kind == .user }
        if hidden != hiddenTurns { hiddenTurns = hidden }
    }

    /// The conversation before a compaction is being read.
    package func startLoadingEarlier() {
        loadingEarlier = true
    }

    /// A page of earlier conversation goes above everything, shown; `more` says if there's
    /// more before it. A turn that's running stays the running one.
    package func prepend(_ events: [ChatEvent], more: Bool) {
        let later = entries
        staysUntil = Date().addingTimeInterval(Self.readInStays)
        let (running, latest, answered, dismissed) = (current, latestTurn, lastAnswerTurn, retryDismissed)
        let (mode, plan) = (permissionsMode, planOn)
        let worked = workedBefore
        let known = agentOrder.count
        entries = []
        position = [:]
        batching = true
        events.forEach(apply)
        restoreParked()
        // The page's agents that never finished in it are as stopped as a replay's.
        endUnfinishedAgents(from: known)
        restoreLeftTurns()
        for entry in later {
            position[entry.id] = entries.count
            entries.append(entry)
        }
        batching = false
        (current, latestTurn, lastAnswerTurn, retryDismissed) = (running, latest, answered, dismissed)
        (permissionsMode, planOn) = (mode, plan)
        let back = min(workedBefore - worked, leftWork)
        workedBefore -= back
        leftWork -= back
        hasUnloaded = hasUnloaded && more
        for i in entries.indices where entries[i].startedAt == nil && (entries[i].kind == .thinking || entries[i].kind == .answer) {
            entries[i].done = true
        }
        // Offered only with every turn shown, so the page shows too.
        if hiddenTurns == 0 { windowStart = nil }
        countHidden()
        earlierAvailable = more
        loadingEarlier = false
        // What just came in isn't "not loaded" any more; the list is read again after this.
        let came = entries.count { $0.kind == .user } - later.count { $0.kind == .user }
        earlierMarks.removeLast(min(max(came, 0), earlierMarks.count))
        invalidateAll()
        rebuild()
        updateMarks()
    }

    /// A message a turn starts at, as its CLI's history knows it.
    private static func startsTurn(_ entry: Entry) -> Bool {
        entry.kind == .user && !entry.inTurn && !entry.text.hasPrefix("<")
    }

    /// The message the newest `keptTurns` begin at, when what's before it can leave memory now;
    /// nil when nothing can: something's under way, the reader isn't at the end or has text
    /// selected, or no row before it would come back as it was. On screen, none of it can but what
    /// isn't built, `opening` the chat.
    package func unloadPoint(opening: Bool = false) -> Entry? {
        guard !isOnScreen || opening else { return nil }
        guard !turnIsOpen, queued.isEmpty, pendingSendSince == nil, compactingSince == nil, !loadingEarlier, pendingMessage == nil,
            Date() >= staysUntil,
            pendingApprovals.isEmpty, continuation == nil, !selection.hasSelection, readerAtEnd?() ?? savedScroll?.atEnd ?? true
        else { return nil }
        var start = entries.count
        var kept = 0
        while start > 0, kept < Self.keptTurns {
            start -= 1
            if Self.startsTurn(entries[start]) { kept += 1 }
        }
        guard kept == Self.keptTurns, start > 0 else { return nil }
        // Up to the first row that can't be read back, and at a turn's own start.
        let limit = min(start, firstUnreadable(before: start), isOnScreen ? windowStartIndex : start)
        var cut = limit
        while cut > 0 {
            if Self.startsTurn(entries[cut]), entries[cut].source != nil,
                entries[cut - 1].turn == nil || cut + 1 == entries.count || entries[cut - 1].turn != entries[cut + 1].turn
            {
                break
            }
            cut -= 1
        }
        guard cut > 0, entries[..<cut].contains(where: Self.startsTurn) else { return nil }
        return entries[cut]
    }

    /// The first row before `end` that its CLI's history can't give back as it is: Kore's own, a
    /// message no id finds, what still runs, a turn whose failure only Kore saw.
    private func firstUnreadable(before end: Int) -> Int {
        var first = end
        for id in agentOrder where agent(id)?.status == .running || (agent(id)?.waiting ?? 0) > 0 {
            if let card = cardIndex(id) { first = min(first, card) }
        }
        for id in refusedTurns where turnFirst[id] == nil {
            first = min(first, turns[id]?.after.flatMap { position[$0] } ?? 0)
        }
        for i in 0..<first {
            let entry = entries[i]
            if entry.local || (entry.kind == .user && entry.source == nil) || (entry.kind == .tool && !entry.done) { return i }
            guard let turn = entry.turn.flatMap({ turns[$0] }) else { continue }
            switch turn.outcome {
            case .completed, .interrupted: break
            case .failed, .authFailed, .slept: return i
            }
        }
        return first
    }

    /// What's before this message leaves memory, with all that's built from it. `marks`: the
    /// messages that are in the history before it now. It can be read back by the way earlier
    /// conversation always is.
    package func unload(before id: UUID, earlier marks: [EarlierMessage]) {
        guard let cut = position[id], cut > 0 else { return }
        let gone = entries[..<cut]
        let goneIDs = Set(gone.map(\.id))
        var message: String?
        var left: Set<String> = []
        var goneAgents: Set<String> = []
        for entry in gone {
            if entry.kind == .peer || Self.startsTurn(entry) { message = entry.source }
            if let agent = entry.agent { park(agent, gone: &goneAgents) }
            guard let id = entry.turn, left.insert(id).inserted, let turn = turns[id] else { continue }
            let facts = LeftTurn(
                duration: turn.duration, outcome: turn.outcome, denied: turn.denied, open: turn.open, touched: turn.touched,
                startMode: turn.startMode, endMode: turn.endMode)
            leftTurns[id] = facts
            if let message { leftTurns[message] = facts }
            leftWork += turn.duration ?? 0
        }
        for id in left {
            turns[id] = nil
            turnFirst[id] = nil
        }
        entries.removeFirst(cut)
        for id in goneIDs { chipsByEntry[id] = nil }
        position = Dictionary(uniqueKeysWithValues: entries.indices.map { (entries[$0].id, $0) })
        tools = tools.filter { !goneIDs.contains($0.value) }
        blocks = blocks.filter { block in
            !goneIDs.contains(block.value) && !goneAgents.contains { block.key.hasPrefix($0 + "/") }
        }
        laneTools = laneTools.filter { !goneAgents.contains($0.value.agent) }
        openKeys = openKeys.filter { key in
            let id = key.hasPrefix("explored-") ? key.dropFirst("explored-".count) : Substring(key)
            return UUID(uuidString: String(id.prefix(36))).map { !goneIDs.contains($0) } ?? true
        }
        if let start = windowStart, position[start] == nil { windowStart = nil }
        hasUnloaded = true
        earlierAvailable = true
        earlierMarks = marks
        countHidden()
        invalidateAll()
        rebuild()
        updateMarks()
        // It was left at the end: it comes back there.
        savedScroll?.atEnd = true
        if !isOnScreen { leftUnseen = true }
        unloads &+= 1
    }

    /// An agent's card goes with its turn: what it is stays for the map. Its own work, and that
    /// of the agents it spawned, is read back when it's opened, unless it's been looked at.
    private func park(_ info: AgentInfo, gone: inout Set<String>) {
        parkedAgents[info.id] = info
        agentCards[info.id] = nil
        guard !keptLanes.contains(info.id) else { return }
        for child in lanes[info.id] ?? [] {
            if let agent = child.agent {
                park(agent, gone: &gone)
                laneAgents[agent.id] = nil
            }
        }
        lanes[info.id] = nil
        loadedAgents.remove(info.id)
        gone.insert(info.id)
    }

    /// Agents read back take up what they were.
    private func restoreParked() {
        guard !parkedAgents.isEmpty else { return }
        for i in entries.indices {
            if let id = entries[i].agent?.id, let info = parkedAgents.removeValue(forKey: id) { entries[i].agent = info }
        }
    }

    /// Turns read back take up what only this run knew of them. Before the page's rows are joined
    /// by the ones after it.
    private func restoreLeftTurns() {
        guard !leftTurns.isEmpty else { return }
        var message: String?
        var seen: Set<String> = []
        for entry in entries {
            if entry.kind == .peer || Self.startsTurn(entry) { message = entry.source }
            guard let id = entry.turn, seen.insert(id).inserted, turns[id] != nil else { continue }
            guard let facts = leftTurns.removeValue(forKey: id) ?? message.flatMap({ leftTurns[$0] }) else { continue }
            if let message { leftTurns[message] = nil }
            if let duration = facts.duration { turns[id]?.duration = duration }
            turns[id]?.outcome = facts.outcome
            turns[id]?.denied = facts.denied
            turns[id]?.open = facts.open
            turns[id]?.touched = facts.touched
            turns[id]?.startMode = facts.startMode
            turns[id]?.endMode = facts.endMode
        }
    }

    /// The user's messages, oldest first, for the message scroller: where each one is.
    struct MessageMark: Equatable {
        enum Place: Equatable {
            /// In a built section: scrolled to.
            case built(section: String)
            /// In the store, above the built window: built, then scrolled to.
            case held(UUID)
            /// On disk: the index in `earlierMarks`.
            case earlier(Int)
        }
        let place: Place
    }

    private func updateMarks() {
        let earlier = (0..<earlierMarks.count).map { MessageMark(place: .earlier($0)) }
        // Not what another session or a notice sent as a message: `<…>` isn't the user's.
        let held = entries[..<windowStartIndex].filter { $0.kind == .user && !$0.text.hasPrefix("<") }.map { MessageMark(place: .held($0.id)) }
        let built = sections.compactMap { section in
            section.header.map { $0.kind == .user && !$0.text.hasPrefix("<") } == true ? MessageMark(place: .built(section: section.id)) : nil
        }
        let marks = earlier + held + built
        if marks != messageMarks { messageMarks = marks }
    }

    /// The list of what's not loaded arrived.
    package func earlierMessages(_ messages: [EarlierMessage]) {
        guard messages != earlierMarks else { return }
        earlierMarks = messages
        updateMarks()
    }

    /// The search found this in the chat: gone to once the chat's loaded far enough to hold it
    /// (for a while: a chat that never does stays at its end).
    func goToMessage(saying query: String, until: Date = Date().addingTimeInterval(8)) {
        pendingMessage = (query, until)
        staysUntil = until
    }

    /// The message whose turn last says `query`, in what the store holds.
    func message(saying query: String) -> UUID? {
        guard let hit = entries.lastIndex(where: {
            ($0.kind == .user || $0.kind == .answer) && $0.text.range(of: query, options: .caseInsensitive) != nil
        }) else { return nil }
        return entries[...hit].last { $0.kind == .user || $0.kind == .peer }?.id
    }

    /// Builds the window from `entry` on, keeping all the turns after it.
    func show(from entry: UUID) {
        guard let at = position[entry], at < windowStartIndex else { return }
        windowStart = entry
        countHidden()
        invalidateAll()
        rebuild()
    }

    /// Builds every turn the store holds.
    func showAll() {
        guard windowStart != nil else { return }
        windowStart = nil
        countHidden()
        invalidateAll()
        rebuild()
    }

    /// The oldest user message held.
    var firstUserMessage: UUID? { entries.first { $0.kind == .user }?.id }

    /// A message's words, and the answer its turn ended on, for the scroller's card.
    func messagePreview(_ section: String) -> (message: String, answer: String?)? {
        guard let id = UUID(uuidString: String(section.dropFirst(2))), let at = position[id] else { return nil }
        var answer: String?
        for entry in entries[(at + 1)...] {
            if entry.kind == .user && !entry.inTurn { break }
            if entry.kind == .answer, !entry.text.isEmpty { answer = entry.text }
        }
        return (entries[at].text, answer)
    }

    package func earlierHistory(_ available: Bool) {
        earlierAvailable = available
    }

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

    /// The files a turn changed (the git snapshot, or what the CLI reported), for its summary.
    /// The turn that ended on its plan's limit, and when the chat continues (with the message set
    /// to go then, if one is); shown after its notice until it continues or is cancelled.
    private(set) var continuation: (turn: String, at: Date, sends: String?)?

    package func continues(turn: String?, at: Date?, sends: String? = nil) {
        let old = continuation?.turn
        continuation = turn.flatMap { turn in at.map { (turn, $0, sends) } }
        if let old { changed(turn: old) }
        if let turn, turn != old { changed(turn: turn) }
    }

    /// Why the latest turn failed, or the chat's last word was an error; nil when it didn't (a
    /// board tile's red mark). Follows the drawn rows.
    var lastTurnFailed: String? {
        _ = tail
        if let last = entries.last, last.kind == .notice, last.isError { return last.text }
        guard let id = latestTurn, let turn = turns[id], turn.finished else { return nil }
        switch turn.outcome {
        case .failed(let message), .authFailed(let message): return message
        default: return nil
        }
    }

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

    /// The agent map's three groups (by state), parents before children. Running: every running
    /// agent of both kinds, and every failed one, which is never folded away, in spawn order,
    /// under its nearest ancestor in the group or the chat. Done (finished) and stopped: each agent
    /// under its nearest ancestor in the same group or the group's row, the group's top level
    /// newest first. An agent leaves running the moment it finishes or stops, and one that runs
    /// again goes back to its place.
    func agentTree() -> (running: [AgentNode], done: [AgentNode], stopped: [AgentNode]) {
        var seen: Set<String> = []
        let infos = agentOrder.compactMap(agent).filter { seen.insert($0.id).inserted }
        let byId = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        enum Group { case running, done, stopped }
        func group(_ info: AgentInfo) -> Group {
            switch info.status {
            case .running, .failed: .running
            case .stopped: .stopped
            case .finished: .done
            }
        }
        // Runs behind the chat: it, or an agent above it, is a background agent. Parents spawn
        // before their children, so each parent is settled first.
        var behind: Set<String> = []
        // The nearest ancestor in the same group ("" for the chat or the group's row).
        var up: [String: String] = [:]
        for info in infos {
            let own = group(info)
            var parent = info.parent.flatMap { byId[$0] == nil ? nil : $0 }
            if info.background || parent.map(behind.contains) == true { behind.insert(info.id) }
            // Bounded, so a malformed chain can't loop.
            var steps = 0
            while let p = parent, let above = byId[p], group(above) != own, steps < infos.count {
                parent = above.parent.flatMap { byId[$0] == nil ? nil : $0 }
                steps += 1
            }
            up[info.id] = parent.flatMap { byId[$0].map(group) == own ? $0 : nil } ?? ""
        }
        func walk(_ own: Group, newestFirst: Bool) -> [AgentNode] {
            Self.walk(infos.filter { group($0) == own }, newestFirst: newestFirst, behind: behind) { up[$0.id] ?? "" }
        }
        return (walk(.running, newestFirst: false), walk(.done, newestFirst: true), walk(.stopped, newestFirst: true))
    }

    /// `newestFirst`: the top level in reverse spawn order; children always in spawn order.
    private static func walk(
        _ infos: [AgentInfo], newestFirst: Bool, behind: Set<String>, parent: (AgentInfo) -> String
    ) -> [AgentNode] {
        let children = Dictionary(grouping: infos, by: parent)
        var nodes: [AgentNode] = []
        nodes.reserveCapacity(infos.count)
        func walk(_ parent: String, depth: Int, rails: [Bool]) {
            var kids = children[parent] ?? []
            if parent.isEmpty, newestFirst { kids.reverse() }
            for (i, info) in kids.enumerated() {
                let last = i == kids.count - 1
                nodes.append(AgentNode(info: info, depth: depth, isLast: last, rails: rails, background: behind.contains(info.id)))
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
        let refs = infos.map {
            AgentRef(id: $0.id, index: $0.index, name: $0.name, status: $0.status, background: $0.background)
        }
        let working = refs.filter { $0.status != .stopped }
        return AgentSummary(
            count: working.count, stopped: refs.count - working.count, running: refs.filter { $0.status == .running },
            waiting: infos.contains { $0.waiting > 0 }, first: Self.distinctShapes(working.isEmpty ? refs : working),
            failed: infos.filter { $0.status == .failed }.map(\.id))
    }

    /// Replaces an agent's own work with its whole history (`ChatBackend.agentHistory`).
    package func replaceLane(of id: String, with events: [ChatEvent]) {
        loadedAgents.insert(id)
        lanes[id] = []
        for (tool, ref) in laneTools where ref.agent == id { laneTools[tool] = nil }
        // The card's counts came with the agent; its history doesn't add to them.
        loadingHistory = true
        batch { events.forEach(apply) }
        loadingHistory = false
        // Agents it spawned, read back with it, take up what they were.
        guard !parkedAgents.isEmpty, var lane = lanes[id] else { return }
        for i in lane.indices {
            if let child = lane[i].agent?.id, let info = parkedAgents.removeValue(forKey: child) { lane[i].agent = info }
        }
        lanes[id] = lane
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

    /// The owner's messages with text, oldest first, the waiting ones last: what ↑ in an empty
    /// composer brings back (`ComposerView.recall`).
    var sentMessages: [String] {
        ((hasUnloaded ? earlierMarks.map(\.text) : []) + entries.lazy.filter { $0.kind == .user }.map(\.text) + queued.map(\.entry.text))
            .filter { !$0.allSatisfy(\.isWhitespace) }
    }

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

    package func rebuild() {
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
        // A turn's sections are built together: from its first.
        let last = sectionStarts.lastIndex { $0 <= from } ?? 0
        let kept = whole || sectionStarts.isEmpty ? 0 : (sectionStarts.firstIndex(of: sectionStarts[last]) ?? last)
        let begin = whole ? start : sectionStarts[kept]

        let rows = rows(from: begin)
        publish(summarizeAgents())
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
        for section in Self.sections(rows, open: openKeys, actions: answerActions, running: runningMessage, first: firstMessage) {
            if let model = old[section.id] {
                if model.update(section) { changed = true }
                models.append(model)
            } else {
                models.append(SectionModel(section))
            }
            starts.append(section.turn.flatMap { position[$0] } ?? begin)
        }
        sectionStarts = starts
        if models.count != sections.count || zip(models, sections).contains(where: { $0 !== $1 }) {
            sections = models
            changed = true
            updateMarks()
        }
        if changed { tail &+= 1 }
        if whole { prepareAnswers() }
    }

    /// The window's finished answers, parsed off the main thread ahead of their rows: newest
    /// first, as the reader starts at the end.
    private func prepareAnswers() {
        var replies: [(key: String, text: String)] = []
        for section in sections.reversed() {
            for item in section.items.reversed() {
                if case .entry(let e) = item.row, e.kind == .answer, e.done { replies.append((e.id.uuidString, e.text)) }
            }
        }
        MarkdownCache.shared.prepare(replies)
    }

    /// The rows of the entries from `begin` (a section's start) to the end, then the messages
    /// waiting for the running turn; final answers' actions are noted in `answerActions`.
    private func rows(from begin: Int) -> [Row] {
        var rows: [Row] = []
        answerActions = [:]
        // Refused turns with nothing of their own, by the entry they follow.
        var refused: [UUID?: [Turn]] = [:]
        for id in refusedTurns { if let turn = turns[id], turnFirst[id] == nil { refused[turn.after, default: []].append(turn) } }
        func refusedAfter(_ entry: UUID?) {
            for turn in refused[entry] ?? [] { finish(turn, folded: false, into: &rows) }
        }
        if begin == 0 { refusedAfter(nil) }
        var i = begin
        while i < entries.count {
            guard let turnID = entries[i].turn, let turn = turns[turnID] else {
                if let row = visibleRow(entries[i]) { rows.append(row) }
                if !refused.isEmpty { refusedAfter(entries[i].id) }
                i += 1
                continue
            }
            var end = i
            while end < entries.count, entries[end].turn == turnID { end += 1 }
            layout(turn, entries[i..<end], into: &rows)
            if !refused.isEmpty { refusedAfter(entries[end - 1].id) }
            i = end
        }
        // A compaction no turn shows has its own live row.
        if let since = compactingSince, !turnShowsSpinner {
            rows.append(.spinner(turn: Self.compactionRow, since: since, claude: providerName == "Claude", word: "Compacting"))
        }
        // Until the CLI acknowledges a send, show local delivery without inventing a turn.
        if let since = pendingSendSince, compactingSince == nil, (!turnIsOpen || current != liveTurn), pendingApprovals.isEmpty {
            rows.append(.spinner(turn: "pending-send", since: since, claude: providerName == "Claude",
                                 word: connection.word ?? "Sending", connection: connection))
        }
        // An acknowledged turn can be quiet while the model starts. It still needs its row;
        // once content exists, layout(_:) supplies exactly one spinner instead.
        if compactingSince == nil, !turnShowsSpinner, turnIsOpen, (connection.stuck || current == liveTurn),
            pendingSendSince == nil, pendingApprovals.isEmpty,
            let current, let turn = turns[current]
        {
            rows.append(
                .spinner(turn: current, since: liveSendSince ?? turn.startedAt, claude: providerName == "Claude", word: connection.word, connection: connection))
        }
        // Messages waiting for the running turn come last, after its spinner.
        rows.append(contentsOf: queued.map { .queued($0.entry) })
        return rows
    }

    /// The message whose turn still runs: it can't be forked from yet.
    private var runningMessage: UUID? {
        turnIsOpen ? entries.last(where: { ($0.kind == .user && !$0.inTurn) || $0.kind == .peer })?.id : nil
    }

    /// The window's sections built from the entries as they are now, none kept: what the
    /// incremental rebuild has to equal (phase 12's `TranscriptRebuildTests`).
    func sectionsFromScratch() -> [Section] {
        let kept = answerActions
        defer { answerActions = kept }
        let rows = rows(from: windowStartIndex)
        return Self.sections(rows, open: openKeys, actions: answerActions, running: runningMessage, first: firstMessage)
    }

    /// Runs a rebuild that's waiting for the next draw now, so a test doesn't wait on the clock.
    package func drawNow() { rebuild() }

    /// Everything is built again on the next rebuild (the window moved, or entries shifted).
    package func invalidateAll() {
        sectionStarts = []
        if LinkTaps.on {
            linkDirtyFrom = 0
            LinkTaps.dirty?()
        }
        touchesDirty = true
    }

    /// Splits rows at each user or peer message, and places them on the timeline.
    private static func sections(
        _ rows: [Row], open: Set<String>, actions: [String: MessageActions] = [:], running: UUID? = nil, first: UUID? = nil
    ) -> [Section] {
        var sections: [Section] = []
        var header: Entry?
        var id = "start"
        var run: [Row] = []
        func flush() {
            guard header != nil || !run.isEmpty else { return }
            let dots = run.map(dot)
            // A turn laid out more than once (split by a compaction in its middle, as Codex's
            // are) repeats its rows' ids: each repeat is numbered, as a list needs them unique.
            var seen: [String: Int] = [:]
            let items = run.indices.map { i in
                let id = run[i].id
                let rowActions: MessageActions? =
                    if case .message(let e, _, _) = run[i] { MessageActions(always: false, canFork: e.id != running, canRollBack: e.id != first && !e.inTurn) }
                    else { actions[id] }
                return Item(
                    row: run[i], dot: dots[i],
                    above: dots[i] != nil && i > 0 && dots[i - 1] != nil,
                    below: dots[i] != nil && i + 1 < dots.count && dots[i + 1] != nil,
                    id: Self.unique(id, &seen), actions: rowActions)
            }
            let headerOpen = header.map { $0.kind == .user || open.contains($0.id.uuidString) } ?? false
            // Split at each message sent during the turn; its rows still join up across.
            var (partID, partHeader, partOpen, from) = (id, header, headerOpen, 0)
            for (i, item) in items.enumerated() {
                guard case .entry(let e) = item.row, e.kind == .user, e.inTurn, i > from else { continue }
                sections.append(Section(id: partID, header: partHeader, headerOpen: partOpen, items: Array(items[from..<i]), turn: header?.id))
                (partID, partHeader, partOpen, from) = ("s-" + e.id.uuidString, e, true, i)
            }
            sections.append(Section(id: partID, header: partHeader, headerOpen: partOpen, items: Array(items[from...]), turn: header?.id))
        }
        for row in rows {
            if case .entry(let e) = row, (e.kind == .user && !e.inTurn) || e.kind == .peer {
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

    /// `id` the first time, then `id/2`, `id/3`…
    private static func unique(_ id: String, _ seen: inout [String: Int]) -> String {
        let n = seen[id, default: 0] + 1
        seen[id] = n
        return n == 1 ? id : "\(id)/\(n)"
    }

    static func dot(_ row: Row) -> TimelineDot? {
        func state(_ e: Entry) -> TimelineDot { !e.done ? .running : e.stopped ? .plain : e.isError ? .failure : .success }
        switch row {
        case .entry(let e):
            switch e.kind {
            case .answer, .plan: return .plain
            case .notice: return e.isError ? .failure : e.warning ? .warning : .plain
            case .mode: return e.modeLead == nil ? nil : e.mode.map { .mode($0) }
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
        case .spinner, .message, .summary, .queued: return nil
        case .rule: return TimelineDot.none
        // A limit that continues on its own at its reset isn't a failure: red only when nothing will.
        case .outcome(_, let text, let continues, _, _, _): return text == "Interrupted" || continues != nil ? .warning : .failure
        case .signIn: return .failure
        // The Mac slept: the turn was cut short, as an interrupted one is, not failed.
        case .slept: return .warning
        case .changes: return .plain
        case .tool(let e, _): return state(e)
        case .file(let e, _, _): return state(e)
        case .agent(let e, _, _):
            return e.agent.map {
                .agent(index: $0.index, name: $0.name, status: $0.status, waiting: $0.waiting > 0, background: $0.background)
            }
        }
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
            let answer = grouped(group)
            tagAnswer(turn, answer)
            rows.append(contentsOf: answer)
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
        let now = turn.finished ? turn.endMode.flatMap { $0 != turn.startMode ? option($0).map(ModeMark.init) : nil } : nil
        rows.append(.fold(Fold(
            turn: turn.id, label: label, outcome: foldOutcome(turn), denied: turn.denied, open: open, live: live,
            count: live && !tools.isEmpty ? Self.count(tools.count, failed: failed) : nil, failed: failed > 0, now: now)))
        let rest = work.dropFirst(prompts.count)
        // Completed assistant write-ups stay readable when commands and thinking fold away.
        // Keep their own entries and order so opening the work cannot duplicate the text.
        rows.append(contentsOf: open ? grouped(rest) : rest.filter {
            Self.pinned($0) || (turn.finished && $0.kind == .answer)
        }.compactMap(visibleRow))
        if let split {
            rows.append(.rule(turn: turn.id))
            let answer = grouped(group[split...])
            if !keepingLast { tagAnswer(turn, answer) }
            rows.append(contentsOf: answer)
        }
        finish(turn, folded: split != nil, into: &rows)
    }

    /// A finished turn's final answer (its last finished answer row) gets the action row.
    private func tagAnswer(_ turn: Turn, _ rows: [Row]) {
        guard turn.finished else { return }
        for row in rows.reversed() {
            if case .entry(let e) = row, e.kind == .answer, e.done {
                answerActions[row.id] = MessageActions(always: turn.id == lastAnswerTurn, canFork: true, canRollBack: turn.id != lastAnswerTurn)
                return
            }
        }
    }

    /// A running turn ends with the spinner (hidden while an approval waits: the fold says so);
    /// a finished one with its outcome and files.
    private func finish(_ turn: Turn, folded: Bool, into rows: inout [Row]) {
        if turn.finished {
            trailer(turn, folded: folded, into: &rows)
        } else if turn.id == current, pendingApprovals.isEmpty, pendingSendSince == nil || turn.id == liveTurn {
            rows.append(
                .spinner(
                    turn: turn.id, since: turn.id == liveTurn ? liveSendSince ?? turn.startedAt : turn.startedAt, claude: providerName == "Claude",
                    word: compactingSince != nil ? "Compacting" : connection.word, connection: compactingSince != nil ? .ok : connection))
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
        let retry = retryableTurn == turn.id
        switch turn.outcome {
        case .completed: break
        case .interrupted: if !folded || retry { rows.append(.outcome(turn: turn.id, text: "Interrupted", retry: retry)) }
        case .failed(let message):
            let continues = continuation.flatMap { $0.turn == turn.id ? $0 : nil }
            rows.append(.outcome(
                turn: turn.id, text: message, continues: continues?.at, sends: continues?.sends, retry: retry,
                refusal: retry ? turn.refusal : nil))
        case .authFailed(let said): rows.append(.signIn(turn: turn.id, said: said))
        case .slept(let said): rows.append(.slept(turn: turn.id, said: said))
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
        case .interrupted, .slept: .interrupted
        case .failed, .authFailed: .failed
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
        case .summary:
            return .summary(entry, expanded: openKeys.contains(MessageHeader.expandKey(entry)))
        default:
            return .entry(entry)
        }
    }

    /// Draws the change: at once for a batch's end or a user's action, else at most once per
    /// `drawInterval`, so a fast stream of deltas costs one rebuild per frame, not one per token.
    /// `index` is the entry that changed; nil when it's not known (everything shown is built
    /// again).
    package func changed(at index: Int? = nil) {
        mark(index)
        guard !batching, !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (hidden ? Self.hiddenDrawInterval : Self.drawInterval)) { [weak self] in
            guard let self else { return }
            drawScheduled = false
            rebuild()
        }
    }

    package func mark(_ index: Int?) {
        let i = max(index ?? 0, 0)
        dirtyFrom = min(dirtyFrom ?? i, i)
        if LinkTaps.on {
            linkDirtyFrom = min(linkDirtyFrom ?? i, i)
            LinkTaps.dirty?()
        }
    }

    /// The lowest entry index changed since the local link last looked; it clears it.
    @ObservationIgnored package var linkDirtyFrom: Int?

    /// A turn as it stands, for the local link.
    package func linkTurn(_ id: String) -> Turn? { turns[id] }

    package func announceFold(_ turn: String) {
        guard !batching, let t = turns[turn] else { return }
        let answer = t.answerFrom?.uuidString ?? "rule-\(turn)"
        foldSeq += 1
        folded = (turn, answer, foldSeq)
    }
}

// The built feedback rows, read by the startup storyline without inventing CLI events.
extension StoryTranscript {
    package var sendFeedback: [String] {
        store.sections.flatMap(\.items).compactMap {
            if case .spinner(_, _, _, let word, _) = $0.row { word ?? "Working" } else { nil }
        }
    }
}

extension TranscriptStore: TranscriptLogView {}

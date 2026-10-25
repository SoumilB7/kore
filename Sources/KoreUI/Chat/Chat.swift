import AppKit
import Foundation
import KoreCore
import Observation

/// One conversation with a CLI. It owns the backend and hands each `ChatEvent` to the stores,
/// one per feature: the transcript, approvals, controls (mode, model, commands), status and
/// context (how full it is, compacting). Views
/// read the store they show, so a streamed token re-renders the transcript alone and typing
/// re-renders the composer alone. The composer's draft and attachments live here, sent and
/// cleared by `send()`.
@MainActor @Observable
package final class Chat: Identifiable {
    package let id = UUID()
    let provider: ProviderDescriptor
    package let folder: URL
    /// Replaced only when a replayed history is corrected (`.historyReplaced`).
    private(set) var transcript = TranscriptStore()
    let approvals = ApprovalsStore()
    let controls: ControlsStore
    let status: ChatStatus
    let context = ContextStore()
    /// The agent map's own UI state (open, selection); not fed by events.
    let agentMap = AgentMapState()
    /// What it runs apart from its turns: background shells, monitors, scheduled jobs.
    let commands = CommandsStore()

    /// Waiting in the composer, sent with the next message.
    package private(set) var attachments: [Attachment] = [] {
        didSet { if attachments.map(\.id) != oldValue.map(\.id) { composerDraftChanged() } }
    }
    package var draft = "" {
        didSet { if draft != oldValue { composerDraftChanged() } }
    }
    /// The `/` command this message starts with, shown as a chip before the draft: one per
    /// message, as both CLIs run one.
    package var command: SlashCommand? {
        didSet { if command != oldValue { composerDraftChanged() } }
    }
    /// The window schedules its own debounced persistence, independently of SwiftUI bodies.
    @ObservationIgnored var onDraftChanged: (() -> Void)?
    @ObservationIgnored private var restoringComposerDraft = false
    /// The / menu was closed (Esc, a click away, another popup) for the "/word" at the caret;
    /// the next one opens it again.
    var slashClosed = false
    /// Launch with this model and effort instead of the CLI's defaults (a fork, the dev hook).
    @ObservationIgnored var launchModel: String?
    @ObservationIgnored var launchEffort: String?
    @ObservationIgnored var launchFastMode: Bool?

    @ObservationIgnored private var backend: (any ChatBackend)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// The latest send: each waits for the one before to reach the CLI, so a message sent while
    /// the CLI is still starting can't overtake the first.
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private let resume: SessionSummary?
    /// A fork the CLI makes when it starts (Codex) or on its first message (Claude).
    @ObservationIgnored let fork: ForkPoint?
    /// The chat this one was forked from, for the line after its history.
    @ObservationIgnored private var forkedFrom: String?
    /// An imported chat's carried part (`ImportedHistory`), shown above its own history, and
    /// its events once read.
    @ObservationIgnored let imported: ImportedHistory?
    @ObservationIgnored private var importedEvents: [ChatEvent]?
    /// A past session's history hasn't been shown yet; messages sent meanwhile wait in `held`,
    /// so they come after it rather than above it.
    @ObservationIgnored private var awaitingHistory: Bool
    @ObservationIgnored private var held: [ChatEvent] = []
    /// Messages sent while a turn ran, by Kore's id, until the CLI takes or drops them.
    @ObservationIgnored private var waiting: [String: (text: String, files: [Attachment])] = [:]
    @ObservationIgnored private var waitingOrder: [String] = []
    /// A message sent with no network waits for it (Stop gives it up); a running turn's spinner
    /// says when the network goes.
    @ObservationIgnored private var waitingForNetwork = false
    var isWaitingForNetwork: Bool { waitingForNetwork }
    @ObservationIgnored private var networkObserver: (any NSObjectProtocol)?
    /// The running turn's connection, as its spinner and tab show it (`Connection.stuck`: ⚠).
    package private(set) var connection = Connection.ok
    /// When the CLI last said anything, and the turn's watchdog (`checkStall`).
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// A Stop's fallback (`stop`), and which turn it was for: one sent since isn't ended by it.
    @ObservationIgnored private var stopFallback: Task<Void, Never>?
    @ObservationIgnored private var turnSerial = 0
    /// Online, waiting on the model (no tool, agent, approval or compaction under way), and
    /// nothing heard for this long: the turn's connection likely died unnoticed. A storyline
    /// sets it shorter.
    package static let stallAfter = HostSetting<TimeInterval>(90)
    /// That chat, while it's open (its "Forked from" line switches to it).
    @ObservationIgnored weak var original: Chat?
    /// The chat has been shown, so its CLI was started once (`startOnce`).
    @ObservationIgnored private var shown = false
    @ObservationIgnored private let compactMemory: AutoCompactMemory
    /// The auto-compact point is the chat's own (picked in it, kept for its session, or its
    /// original's when it's a fork), not the provider's: kept under its session id once known.
    @ObservationIgnored private var ownAutoCompact = false
    /// The user's turn may end in an auto-compact: set as it starts, cleared once a compaction
    /// starts or Kore asks for one. So a failed compaction, or one that leaves usage past the
    /// point, waits for the user's next turn.
    @ObservationIgnored private var autoCompactDue = false
    /// A compaction the user didn't ask for stopped work that was going on: Kore's own at its
    /// point, right after a turn that ran to its end, or the CLI's own in a turn that then ended
    /// with nothing after it. "Continue" goes once it's done; never after the wheel or /compact,
    /// a Stop, a failure or a limit.
    @ObservationIgnored private var continueAfterCompaction = false
    @ObservationIgnored private var lastTurnCompleted = false
    @ObservationIgnored private var compactedInTurn = false
    /// The turn the next starts is Kore's own Continue, and the one running is: neither counts
    /// as the user's, so it neither compacts at the point nor continues again (no loop).
    @ObservationIgnored private var continueSent = false
    @ObservationIgnored private var inContinueTurn = false
    /// The context card's presence: the wheel and the card share it.
    let contextCard = ContextCardPresence()
    /// The usage popup over the composer (the / menu's Usage).
    let usage = UsageState()
    /// The Account popup, in the same place (the / menu's Account).
    let account = AccountState()
    /// The import picker, in the same place, while the chat is empty.
    let importer = ImportState()
    /// The model and mode pickers, over the composer from their chips.
    let picker = PickerState()
    /// The CLI's account changed since its CLI started: it starts again (with resume) at the
    /// next turn boundary, so it runs as the new account.
    @ObservationIgnored private var relaunchDue = false
    @ObservationIgnored private var stoppedForAccount = false
    /// Every asynchronous send/start belongs to one transport lifetime. Cancelling the last
    /// task alone cannot stop earlier tasks waiting in the send chain.
    @ObservationIgnored private var workEpoch: UInt64 = 0
    private(set) var accountRestartPending = false

    private func currentWork(_ epoch: UInt64) -> Bool { !closed && workEpoch == epoch }
    /// The turn running now, and when it began: a failure is the sleep's when the Mac slept since.
    @ObservationIgnored private var turnBegan: (id: TurnID, at: Date)?
    /// Stay awake's continuation after the plan's limit (`LimitContinuation`).
    @ObservationIgnored private lazy var continuation = makeContinuation()
    /// When the chat continues after its plan's limit resets; nil when it won't.
    private(set) var continuesAt: Date?
    /// The last turn ended on the plan's limit, which resets `at`: a message can wait for it.
    private(set) var limitReset: (turn: TurnID, at: Date)?
    /// A message set to go when the limit resets (`sendAtReset`), out of the composer, and when
    /// it was set (the wait the composer's ring counts down).
    private(set) var sendsAtReset: (command: SlashCommand?, draft: String, attachments: [Attachment], since: Date)?
    /// Stay awake was turned on for that message; it goes off again once it's sent or cancelled.
    @ObservationIgnored private var awakeForReset = false
    /// Its tab closed: nothing of it counts as running any more.
    private var closed = false

    /// `fork` makes this chat a fork of `session` that its CLI creates; it has no session of its
    /// own until then. `forkedFrom` names the original chat.
    init(
        provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil, fork: ForkPoint? = nil,
        forkedFrom: String? = nil, imported: ImportedHistory? = nil, modeMemory: ModeMemory = .shared,
        compactMemory: AutoCompactMemory = .shared
    ) {
        self.provider = provider
        self.folder = folder
        resume = session
        self.fork = fork
        self.forkedFrom = forkedFrom
        // A reopened chat Kore made by an import has its record, and so does a fork of one (its
        // session is the original's until its own comes, when the record is kept for that too).
        self.imported = imported ?? session.flatMap { ImportedHistory.of(session: $0.id) }
        awaitingHistory = session != nil
        controls = ControlsStore(provider: provider, memory: modeMemory)
        self.compactMemory = compactMemory
        // A reopened chat (a restored tab, or from history) has its own point back; a fork's
        // session is its original's until its own comes (`inheritAutoCompact`). Any other starts
        // Off: a point is one chat's, not every chat's.
        if fork == nil, let id = session?.id, let own = compactMemory.point(chat: id) {
            context.autoCompactAt = own
            ownAutoCompact = true
        }
        status = ChatStatus(resume: fork == nil ? session : nil)
        if fork != nil { status.name = session?.title }
        transcript.providerName = provider.name
        transcript.provider = provider
        AccountStore.shared.register(self)
        StayAwake.register(self)
        ownPopups()
    }

    package var sessionId: String? { status.sessionId }
    var resumed: Bool { status.resumed }
    var hasConversation: Bool { status.hasConversation }
    var title: String { status.title(fallback: provider.name) }

    /// The CLI's current name for a past session (it may have been renamed elsewhere).
    func adoptName(_ newName: String) { status.name = newName }

    /// A user rename, saved by the CLI (Claude: custom title, Codex: thread name).
    func rename(_ newName: String) {
        Task { await applyRename(newName) }
    }

    /// Renames and waits until the CLI has it (starting the CLI if needed).
    func applyRename(_ newName: String) async {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        status.name = newName
        await start()
        try? await backend?.rename(newName)
    }

    // MARK: Events

    /// Every event goes to every store; each takes what it shows.
    private func dispatch(_ event: ChatEvent) {
        let event = sleptOutcome(event)
        if case .historyReplaced(let events) = event {
            replaceHistory(events)
            StorylineSeams.events?(self, event)
            return
        }
        let start = DevSnapshot.timeReplay && Self.isReplay(event) ? ContinuousClock.now : nil
        noteHeard(event)
        if case .replayed = event { showImported(in: transcript) }
        transcript.apply(event, preserving: backend?.observedAgents ?? [])
        commands.apply(event)
        noteSinceReplay(event)
        if case .replayed = event, let original = forkedFrom {
            // A fork's history ends with where it came from.
            forkedFrom = nil
            transcript.forkedFrom(original)
        }
        approvals.apply(event)
        controls.apply(event)
        noteAgentModeChange(event)
        dropUnofferedMode(event)
        restoreQueued(event)
        // A new chat's (or a fork's) session id comes with its first turn: its point is kept under it.
        if case .sessionIdentified(let id) = event, ownAutoCompact, id != status.sessionId {
            compactMemory.remember(context.autoCompactAt, chat: id)
        }
        if case .sessionIdentified(let id) = event, let record = imported?.record, record.target.session != id {
            Task.detached { HandoffRecords.alias(record, session: id) }
        }
        status.apply(event)
        context.apply(event)
        // Codex says a model's window only in a chat: kept for the next import into one.
        if case .contextUsage(let usage) = event, provider.id == "codex", !usage.approximate, let window = usage.window,
            let model = controls.modelId ?? launchModel
        {
            HandoffBudget.rememberCodexWindow(window, model: model)
        }
        seedImportedContext(event)
        autoCompactIfDue(event)
        afterAccountEvent(event)
        continueAfterLimit(event)
        showBeforeCompaction(event)
        if let start { DevSnapshot.logReplay(ContinuousClock.now - start) }
        if case .replayed = event { showHeld() }
        StorylineSeams.events?(self, event)
    }

    /// What the transcript took after a replay, until the backend has confirmed it
    /// (`.earlierHistory` follows that): a corrected history takes them again.
    @ObservationIgnored private var sinceReplay: [ChatEvent]?

    private func noteSinceReplay(_ event: ChatEvent) {
        switch event {
        case .replayed: sinceReplay = []
        case .earlierHistory: sinceReplay = nil
        default:
            guard sinceReplay != nil else { return }
            sinceReplay?.append(event)
            // A backend that never confirms (only Claude's long transcripts need it) stops it here.
            if (sinceReplay?.count ?? 0) > 200 { sinceReplay = nil }
        }
    }

    /// The history built again in a store of its own, then shown in place of the first one,
    /// with what came after the replay. The other stores take the history again too (each keeps
    /// what its latest events say).
    private func replaceHistory(_ events: [ChatEvent]) {
        let store = TranscriptStore()
        store.providerName = transcript.providerName
        store.provider = transcript.provider
        showImported(in: store)
        store.apply(.replayed(events))
        for event in sinceReplay ?? [] { store.apply(event) }
        if let since = transcript.pendingSendSince { store.sending(true, at: since) }
        transcript = store
        let replay = ChatEvent.replayed(events)
        approvals.apply(replay)
        controls.apply(replay)
        commands.apply(.historyReplaced(events))
        let running = status.isRunning
        status.apply(replay)
        status.setRunning(running)
        context.apply(replay)
        seedImportedContext(replay)
    }

    /// An imported chat's context before its CLI has reported any: Kore's estimate, marked as
    /// one. Not an event, so it never starts an auto-compact; the CLI's first reading replaces it.
    private func seedImportedContext(_ event: ChatEvent) {
        guard case .replayed = event, context.usage == nil, let imported else { return }
        context.apply(.contextUsage(imported.estimate))
    }

    /// An imported chat's carried part and its divider, before its own history.
    private func showImported(in store: TranscriptStore) {
        guard let imported, let events = importedEvents else { return }
        let product = provider.usage.product
        if let cut = imported.cutMark(product: product) { store.carriedFrom(cut.text, help: cut.help) }
        if let summary = imported.summary { store.compactionSummary(summary, title: "Summary of earlier turns") }
        store.apply(.replayed(events))
        store.continued(imported.divider(product: product), help: "Open the \(imported.record.sourceProduct) chat")
    }

    /// The user's messages that waited for the history. `late`: the history hasn't come after
    /// `heldPatience`, and they show without it rather than leave the chat blank.
    private func showHeld(late: Bool = false) {
        guard awaitingHistory else { return }
        awaitingHistory = false
        let waiting = held
        held = []
        waiting.forEach(dispatch)
        SessionLog.shared.shown(provider.id, chat: sessionId, rows: transcript.entries.count, held: waiting.count, late: late)
    }

    /// How long a message sent before the history came waits for it.
    static let heldPatience: Duration = .seconds(8)

    /// A message held for the history: shown after `heldPatience` if the history hasn't come.
    private func hold(_ message: ChatEvent) {
        held.append(message)
        guard held.count == 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.heldPatience)
            self?.showHeld(late: true)
        }
    }

    private static func isReplay(_ event: ChatEvent) -> Bool {
        if case .replayed = event { return true }
        return false
    }

    private static func isCorrection(_ event: ChatEvent) -> Bool {
        if case .historyReplaced = event { return true }
        return false
    }

    private func fail(_ message: String) {
        // No history is coming.
        showHeld()
        dispatch(.notice(message, isError: true))
    }

    // MARK: Lifecycle

    /// Starts the CLI the first time the chat shows. Showing it again (switching back to its
    /// tab) leaves the CLI be: one that failed to start, or has exited, starts again with the
    /// next send, not with a tab switch.
    func startOnce() async {
        guard !shown else { return }
        shown = true
        await start()
    }

    func start() async {
        guard !closed, !Task.isCancelled else { return }
        let epoch = workEpoch
        do {
            try await connect().start()
        } catch {
            guard currentWork(epoch), !Task.isCancelled else { return }
            fail(Self.reason(error))
        }
    }

    /// The backend, made on first use with the chat's current settings.
    private func connect() -> any ChatBackend {
        if let backend { return backend }
        let make: (BackendOptions) -> any ChatBackend
        if let seam = StorylineSeams.backend {
            let id = provider.id
            make = { seam(id, $0) }
        } else {
            make = FeedBackend.enabled ? FeedBackend.init : provider.makeBackend
        }
        var options = BackendOptions(
            folder: folder, resume: resume, mode: controls.mode, planMode: controls.planMode,
            model: launchModel, effort: launchEffort, fork: fork, forkTitle: fork == nil ? nil : status.name)
        options.fastMode = launchFastMode
        if let imported {
            options.hiddenRows = Set(imported.record.written)
            options.instructions = imported.record.instructions.map { URL(fileURLWithPath: $0) }
        }
        let backend = make(options)
        self.backend = backend
        pump = Task {
            for await event in backend.events {
                guard !Task.isCancelled, !closed else { break }
                let epoch = workEpoch
                // An imported chat's carried part is read before its own history shows.
                if let imported, importedEvents == nil, Self.isReplay(event) || Self.isCorrection(event) {
                    let events = await imported.events()
                    guard currentWork(epoch), !Task.isCancelled else { continue }
                    importedEvents = events
                }
                self.dispatch(event)
            }
        }
        return backend
    }

    /// Opens the usage popup and reads the account's limits once, through this chat's CLI.
    func openUsage() {
        closePopups(keeping: .usage)
        usage.open(
            provider: provider.id,
            read: { [weak self] in
                guard let self else { throw UsageUnavailable() }
                return try await self.connect().usage()
            },
            useReset: { [weak self] credit, attempt in
                guard let self else { throw UsageUnavailable() }
                return try await self.connect().useReset(credit: credit, attempt: attempt)
            },
            shares: { [weak self] reading in
                guard let self else { return nil }
                return await self.connect().koreShares(for: reading)
            })
    }

    /// Opens the Account popup for this chat's CLI.
    func openAccount() {
        closePopups(keeping: .account)
        account.open(provider: provider.id, folder: folder)
    }

    /// The model chip or the mode pill: its picker opens in the popups' place, or closes when
    /// it's the one open.
    func togglePicker(_ kind: PickerState.Kind) {
        if picker.open != kind { closePopups(keeping: kind.popup) }
        picker.toggle(kind)
    }

    /// The auth-failure notice's Sign in: Account opens, and the sign-in starts with the last
    /// method (the login lapsed), unless one is already under way.
    func signInAgain() {
        openAccount()
        let store = AccountStore.shared
        if case .signedIn(let identity) = store.status(provider.id), !identity.changeable { return }
        account.signIn()
    }

    // MARK: Account

    /// A turn or a background agent is running.
    var isWorking: Bool { !closed && (isBusy || !transcript.agentSummary.running.isEmpty) }

    /// A turn, a background agent or a command Stop applies to is running: what a sign-out or
    /// a switch of its login stops.
    var hasWork: Bool { !closed && (isWorking || waitingForNetwork || commands.summary.total > 0) }

    /// Its login is going (a sign-out) or moving (a switch): the turn, the background agents
    /// and the commands stop, and the CLI starts again as the new login once they have.
    func stopAllWork() {
        cancelContinue()
        stoppedForAccount = true
        if isBusy || waitingForNetwork { stop() }
        let observed = backend?.observedAgents ?? []
        for agent in transcript.agentSummary.running where !observed.contains(agent.id) { stopAgent(agent.id) }
        for command in commands.stoppable where command.owner.sub.map(observed.contains) != true { stopCommand(command.id) }
    }

    /// Its turn runs, or it compacts (Kore's own compaction, the wheel's, /compact): the chat is
    /// at work, as its tab shows, until the Continue after it, if any, starts its turn.
    var isBusy: Bool { status.isRunning || context.compacting }

    /// Starting the CLI again would end something: a turn, a background agent, or a command left
    /// live (a dev server, a port-forward, an armed scheduled job), which dies with its process.
    private var holdsCLI: Bool { isWorking || commands.summary.total > 0 }

    /// An explicit account switch closes old work even when a scheduled job or dead CLI
    /// cannot acknowledge Stop. Other credential refreshes wait for the next safe boundary.
    func accountChanged() {
        cancelContinue()
        guard backend != nil else { return }
        if stoppedForAccount || accountRestartPending {
            stoppedForAccount = false
            relaunchDue = false
            restartCLI(reason: "account changed", clearingWork: true)
            return
        }
        relaunchDue = true
        relaunchIfDue()
    }

    /// Ends the CLI's process between turns and starts it again as the new account, so its
    /// models, effort and commands are the new account's before the next send. It waits behind
    /// any send under way, and the next send waits for it.
    private func relaunchIfDue() {
        guard relaunchDue, !holdsCLI, let backend else { return }
        relaunchDue = false
        workEpoch &+= 1
        let epoch = workEpoch
        let previous = sending
        previous?.cancel()
        transcript.sending(false)
        for id in waitingOrder.reversed() { dispatch(.queuedMessage(id: id, .dropped)) }
        sending = Task {
            guard currentWork(epoch), !Task.isCancelled else { return }
            await previous?.value
            guard currentWork(epoch), !Task.isCancelled else { return }
            await backend.relaunch(reason: "account changed")
            guard currentWork(epoch), !Task.isCancelled else { return }
            try? await backend.start()
        }
    }

    /// ⌘R's reload of this chat, held while a turn, an agent or a command runs.
    @ObservationIgnored private var reloadWhenFree: (@MainActor () -> Void)?

    /// Runs `reload` now if nothing live would die with the CLI, else once the last thing ends.
    /// Asked again while it waits, it runs at once: a chat stuck at work comes back too.
    func whenFree(_ reload: @escaping @MainActor () -> Void) {
        if holdsCLI, reloadWhenFree == nil {
            reloadWhenFree = reload
        } else {
            reloadWhenFree = nil
            reload()
        }
    }

    private func afterAccountEvent(_ event: ChatEvent) {
        switch event {
        case .turnFinished(_, .authFailed, _):
            // The notice says "expired" or "isn't signed in": the status tells which.
            let provider = provider.id
            Task { await AccountStore.shared.refresh(provider) }
            relaunchIfDue()
        case .turnFinished, .agentFinished, .commandEnded:
            // An agent's end reaches the summary at the next draw: at once, when a start waits.
            if case .agentFinished = event, relaunchDue || reloadWhenFree != nil { transcript.drawNow() }
            relaunchIfDue()
            if !holdsCLI, let reload = reloadWhenFree {
                reloadWhenFree = nil
                reload()
            }
        case .exited:
            // Its process is gone: the next send starts a new one anyway.
            relaunchDue = false
        default:
            break
        }
    }

    // MARK: Connection

    /// What the CLI said keeps the watchdog fed; a turn's start and end, and its connection's
    /// changes, are logged.
    private func noteHeard(_ event: ChatEvent) {
        switch event {
        case .connection(let state):
            guard state != connection else { return }
            connection = state
            let attempt: String? = if case .retrying(let n?, let of?) = state { "\(n)/\(of)" } else { nil }
            SessionLog.shared.connection(provider.id, chat: sessionId, state: Self.name(state), attempt: attempt)
        case .turnStarted:
            turnSerial &+= 1
            lastHeard = Date()
            SessionLog.shared.turn("turn-start", provider.id, chat: sessionId)
            startWatchdog()
        case .turnFinished(_, let outcome, let duration):
            endWatch()
            SessionLog.shared.turn(
                "turn-end", provider.id, chat: sessionId, outcome: Self.name(outcome), seconds: duration.map { Int($0.components.seconds) })
        case .exited:
            endWatch()
        default:
            guard !Self.isReplay(event) else { return }
            lastHeard = Date()
            if connection == .stalled || connection == .quietWork {
                // It spoke again: the connection was fine after all.
                connection = .ok
                transcript.connected(.ok)
                SessionLog.shared.connection(provider.id, chat: sessionId, state: "ok")
            }
        }
    }

    private func endWatch() {
        watchdog?.cancel()
        watchdog = nil
        stopFallback?.cancel()
        stopFallback = nil
        connection = .ok
    }

    /// Every 10 s while a turn runs: `checkStall`. Started by a send too, in case the CLI never
    /// answers with the turn's start.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        lastHeard = Date()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(10, Self.stallAfter.value / 3)))
                guard let self, !Task.isCancelled else { return }
                guard self.status.isRunning else {
                    self.watchdog = nil
                    return
                }
                self.checkStall()
            }
        }
    }

    private func checkStall() {
        let quiet = Date().timeIntervalSince(lastHeard)
        guard quiet > Self.stallAfter.value, NetworkWatch.shared.isOnline, !waitingForNetwork,
            approvals.pending.isEmpty, !context.compacting else { return }
        let state: Connection = transcript.workRunning ? .quietWork : .stalled
        guard connection != state else { return }
        connection = state
        transcript.connected(state)
        SessionLog.shared.connection(provider.id, chat: sessionId, state: Self.name(state), quiet: Int(quiet))
    }

    /// A stalled turn's Retry: its CLI ends and starts again on the same chat, which is asked
    /// to carry on.
    func retryStalled() {
        guard !closed, !accountRestartPending, status.isRunning,
              connection == .stalled || connection == .quietWork,
              approvals.pending.isEmpty, !context.compacting else { return }
        let reason = connection == .quietWork ? "quiet work" : "stalled"
        SessionLog.shared.rescue(provider.id, chat: sessionId, action: "retry")
        cancelContinue()
        restartCLI(reason: reason)
        deliver("Continue", [])
    }

    /// Resumes only the latest unfinished attempt, not a historical turn or the command's
    /// raw input. `deliver` leaves the user's unsent composer and attachments intact.
    func retryTurn(_ id: String) {
        guard !closed, !accountRestartPending, !isBusy, approvals.pending.isEmpty,
              transcript.retryableTurn == id else { return }
        SessionLog.shared.rescue(provider.id, chat: sessionId, action: "retry-ended")
        restartCLI(reason: "retry ended")
        continueTurn()
    }

    /// Ends the CLI under a turn that won't end by itself and starts it again: the turn ends
    /// here, at once, and nothing waits for the send that hangs on it.
    private func restartCLI(reason: String, clearingWork: Bool = false) {
        guard !closed, let backend else { return }
        let clearingWork = clearingWork || accountRestartPending
        if clearingWork { accountRestartPending = true }
        workEpoch &+= 1
        let epoch = workEpoch
        relaunchDue = false
        sending?.cancel()
        transcript.sending(false)
        waitingForNetwork = false
        // Restore synchronously: another account switch can cancel this task before it runs.
        if clearingWork {
            for id in waitingOrder.reversed() { dispatch(.queuedMessage(id: id, .dropped)) }
        }
        if status.isRunning { dispatch(.turnFinished(nil, .interrupted, duration: nil)) }
        status.setRunning(false)
        sending = Task {
            guard currentWork(epoch), !Task.isCancelled else { return }
            if clearingWork {
                guard await backend.relaunchAfterAccountChange() else { return }
            } else {
                await backend.relaunch(reason: reason)
            }
            guard currentWork(epoch), !Task.isCancelled else { return }
            if clearingWork {
                // External file watchers can discover descendants while shutdown waits.
                let observed = backend.observedAgents
                // The old process is gone. Jobs and deaf agents cannot hold the switch;
                // agents merely observed in another process retain their live state.
                for approval in approvals.pending { dispatch(.approvalWithdrawn(approval.id)) }
                for command in commands.all where command.isLive && command.owner.sub.map(observed.contains) != true {
                    dispatch(.commandEnded(id: command.id, .stopped(by: .user), at: .now))
                }
                transcript.drawNow()
                for agent in transcript.agentSummary.running where !observed.contains(agent.id) {
                    dispatch(.agentFinished(id: agent.id, .stopped, result: nil))
                }
                context.end()
                dispatch(.exited(status: 0))
                transcript.drawNow()
                accountRestartPending = false
            }
            guard currentWork(epoch), !Task.isCancelled else { return }
            try? await backend.start()
        }
    }

    private static func name(_ state: Connection) -> String {
        switch state {
        case .ok: "ok"
        case .offline: "offline"
        case .retrying: "retrying"
        case .stalled: "stalled"
        case .quietWork: "quiet-work"
        }
    }

    private static func name(_ outcome: TurnOutcome) -> String {
        switch outcome {
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case .authFailed: "auth-failed"
        case .limited: "limited"
        case .slept: "slept"
        }
    }

    /// While a turn runs, the network going or coming back is said on its spinner.
    private func watchNetwork() {
        networkObserver = NotificationCenter.default.addObserver(forName: NetworkWatch.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status.isRunning, !self.waitingForNetwork else { return }
                self.dispatch(.connection(NetworkWatch.shared.isOnline ? .ok : .offline))
            }
        }
    }

    func close(reason: String = "tab closed") {
        onDraftChanged = nil
        if !closed, backend != nil { SessionLog.shared.closing(provider.id, chat: sessionId, reason: reason) }
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        networkObserver = nil
        closed = true
        transcript.sending(false)
        workEpoch &+= 1
        sending?.cancel()
        waitingForNetwork = false
        endWatch()
        cancelContinue()
        pump?.cancel()
        let backend = backend
        self.backend = nil
        Task { await backend?.close() }
    }

    // MARK: Composer

    /// A metadata-only snapshot: no trimming, command parsing, thumbnail reads or other IO.
    package var composerDraft: ChatDraft {
        ChatDraft(provider: provider.id, folder: folder, text: draft, command: command.map(ChatDraft.Command.init),
                  attachmentURLs: attachments.compactMap(\.url))
    }

    /// A closed tab may retain its attachments in memory to reuse their IDs and thumbnails;
    /// after relaunch, file URLs rebuild the chips. Metadata is sufficient before controls load.
    @discardableResult
    package func restoreComposerDraft(_ saved: ChatDraft, keeping files: [Attachment] = []) -> Bool {
        guard saved.provider == provider.id, saved.folder.isFileURL,
              saved.folder.standardizedFileURL == folder.standardizedFileURL else { return false }
        let before = composerDraft
        var available = files
        let restored: [Attachment] = saved.attachmentURLs.filter { $0.isFileURL && $0.path.hasPrefix("/") }.map { url in
            if let index = available.firstIndex(where: { $0.url == url }) { return available.remove(at: index) }
            return Attachment(url: url)
        }
        restoringComposerDraft = true
        draft = saved.text
        command = saved.command?.slashCommand
        attachments = restored
        restoringComposerDraft = false
        if composerDraft != before { composerDraftChanged() }
        return true
    }

    private func composerDraftChanged() {
        if !restoringComposerDraft { onDraftChanged?() }
    }

    /// Something to send, and no compaction under way (sending waits until it's done).
    var canSend: Bool {
        !accountRestartPending && !context.compacting
            && (command != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func attach(_ urls: [URL]) {
        attachments += urls.map(Attachment.init(url:))
    }

    func removeAttachment(_ id: Attachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    /// All of them at once: a whole draft cleared or pasted, or that undone.
    func setAttachments(_ list: [Attachment]) {
        attachments = list
    }

    /// Swaps in an edited copy (a marked-up image), keeping its place.
    func replaceAttachment(_ id: Attachment.ID, with url: URL) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index] = Attachment(url: url)
    }

    /// What goes to the CLI: the command first, then the draft.
    nonisolated static func message(command: SlashCommand?, draft: String) -> String {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command else { return text }
        return text.isEmpty ? "/\(command.name)" : "/\(command.name) \(text)"
    }

    /// A sent message as the composer holds it: a leading command among `commands` goes back to
    /// the chip, the rest to the draft.
    nonisolated static func split(_ text: String, commands: [SlashCommand]) -> (command: SlashCommand?, draft: String) {
        guard text.hasPrefix("/") else { return (nil, text) }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let command = commands.first(where: { $0.kind == .command && $0.name == name }) else { return (nil, text) }
        return (command, String(text.dropFirst(1 + name.count).drop(while: \.isWhitespace)))
    }

    /// Puts a message back in the composer (a fork's), its command in the chip.
    func restoreDraft(_ text: String, commands: [SlashCommand]) {
        (command, draft) = Self.split(text, commands: commands)
    }

    func send() {
        guard !closed, !accountRestartPending else { return }
        let text = Self.message(command: command, draft: draft)
        let sent = attachments
        guard !text.isEmpty || !sent.isEmpty, !context.compacting else { return }
        // A typed /compact compacts as the context wheel does, shown as the user's message (the
        // CLI isn't sent it as one). It waits in the composer while it can't (a turn running, no
        // session yet).
        if sent.isEmpty, let instructions = Self.compactCommand(text) {
            guard canCompact else { return }
            draft = ""
            command = nil
            let message = ChatEvent.userMessage(text: text, attachments: [])
            if awaitingHistory { hold(message) } else { dispatch(message) }
            compact(instructions: instructions)
            return
        }
        draft = ""
        command = nil
        attachments = []
        // The owner said something: the chat no longer continues by itself.
        cancelContinue()
        deliver(text, sent)
    }

    /// Sends a message the composer has given up (or Kore's own "Continue").
    private func deliver(_ text: String, _ sent: [Attachment]) {
        guard !closed, !accountRestartPending else { return }
        relaunchIfDue()
        let epoch = workEpoch
        if networkObserver == nil { watchNetwork() }
        // The Codex extension's /plan flips the plan toggle; it isn't a message.
        if text == "/plan" && sent.isEmpty && provider.planToggle != nil {
            setPlanMode(!controls.planMode)
            return
        }
        approvals.offerImplementPlan = false
        // Sent while a turn runs, it waits (look.md §10) until the CLI says where it went.
        let queued = status.isRunning ? UUID().uuidString : nil
        let shown = sent.map(SentAttachment.init)
        let message: ChatEvent =
            queued.map { .messageQueued(id: $0, text: text, attachments: shown) }
            ?? .userMessage(text: text, attachments: shown)
        if let queued {
            waiting[queued] = (text, sent)
            waitingOrder.append(queued)
        }
        if awaitingHistory { hold(message) } else { dispatch(message) }
        status.setRunning(true)
        if queued == nil { transcript.sending(true) }
        startWatchdog()
        let backend = connect()
        let previous = sending
        sending = Task {
            guard currentWork(epoch), !Task.isCancelled else { return }
            await previous?.value
            guard currentWork(epoch), !Task.isCancelled else { return }
            do {
                try await backend.start()
                guard currentWork(epoch), !Task.isCancelled else { return }
                if queued == nil, !NetworkWatch.shared.isOnline {
                    dispatch(.notice("Offline: this sends when the network is back"))
                    waitingForNetwork = true
                    await NetworkWatch.shared.online()
                    guard currentWork(epoch) else { return }
                    waitingForNetwork = false
                    if Task.isCancelled {
                        status.setRunning(false)
                        dispatch(.notice("Not sent: stopped while offline"))
                        return
                    }
                }
                guard currentWork(epoch), !Task.isCancelled else { return }
                let turn = try await backend.send(text, files: Attachments.files(sent), queued: queued)
                guard currentWork(epoch), !Task.isCancelled else { return }
                if !turn, queued == nil {
                    transcript.sending(false)
                    status.setRunning(false)
                }
            } catch {
                guard currentWork(epoch), !Task.isCancelled else { return }
                // A queued message that couldn't go goes back to the composer.
                if let queued {
                    dispatch(.queuedMessage(id: queued, .dropped))
                } else {
                    transcript.sending(false)
                    status.setRunning(false)
                }
                fail(Self.reason(error))
            }
        }
    }

    // MARK: Stay awake

    /// What this chat keeps awake for: its turn, and its running agents and Codex child threads.
    var awakeWork: Int {
        guard !closed else { return 0 }
        return (isBusy ? 1 : 0) + transcript.agentSummary.running.count
    }

    /// Sends "Continue": a slept turn's Continue, and the continuation at a limit's reset.
    func continueTurn() {
        cancelContinue()
        deliver("Continue", [])
    }

    /// The × after "Continues at …", Stay awake turned off, or the owner sending. A message set
    /// to go at the reset comes back to the composer when it's empty.
    func cancelContinue() {
        if let waiting = sendsAtReset {
            sendsAtReset = nil
            if draft.isEmpty, attachments.isEmpty, command == nil {
                (command, draft, attachments) = (waiting.command, waiting.draft, waiting.attachments)
            }
            releaseAwakeForReset()
        }
        // Cancels a first reset lookup too, before it has supplied a pending time.
        continuation.cancel()
    }

    /// At the plan's limit, with something typed and nothing set to go yet: it can go at the reset.
    var canSendAtReset: Bool {
        limitReset != nil && sendsAtReset == nil && !status.isRunning && canSend
    }

    /// The composer's ring: the draft goes when the limit resets, Stay awake on until then.
    func sendAtReset() {
        guard canSendAtReset, let reset = limitReset else { return }
        sendsAtReset = (command, draft, attachments, Date())
        draft = ""
        command = nil
        attachments = []
        if let awake = StayAwake.current, !awake.isOn {
            awake.choose(.whileAgentsWork)
            awakeForReset = true
        }
        continuation.schedule(turn: reset.turn, at: reset.at)
        // Already waiting there to send Continue: the row says the message now.
        showContinuation(continuation.pending)
    }

    /// Stay awake goes off again if it was turned on for the message, unless another chat waits
    /// on it.
    private func releaseAwakeForReset() {
        guard awakeForReset else { return }
        awakeForReset = false
        guard let awake = StayAwake.current, awake.isOn, !awake.othersContinue(besides: self) else { return }
        awake.turnOff()
    }

    private func makeContinuation() -> LimitContinuation {
        let continuation = LimitContinuation(clock: StayAwake.current?.clock ?? SystemClock())
        continuation.read = { [weak self] in
            guard let self, !closed, !accountRestartPending else { return nil }
            return try? await self.connect().usage()
        }
        continuation.send = { [weak self] in
            guard let self, !closed else { return }
            guard !accountRestartPending else { cancelContinue(); return }
            if let waiting = sendsAtReset {
                sendsAtReset = nil
                deliver(Self.message(command: waiting.command, draft: waiting.draft), waiting.attachments)
            } else {
                deliver("Continue", [])
            }
        }
        continuation.changed = { [weak self] pending in self?.showContinuation(pending) }
        return continuation
    }

    private func showContinuation(_ pending: LimitContinuation.Pending?) {
        continuesAt = pending?.at
        let message = sendsAtReset.map { Self.message(command: $0.command, draft: $0.draft) }
        transcript.continues(turn: pending?.turn, at: pending?.at, sends: pending == nil ? nil : message)
    }

    /// A turn that ended on the plan's limit continues at the reset, while Stay awake is on.
    private func continueAfterLimit(_ event: ChatEvent) {
        noteLimitReset(event)
        guard case .turnFinished(let id, .limited(_, let resetsAt), _) = event,
            StayAwake.current?.isOn == true, let turn = id ?? turnBegan?.id
        else { return }
        continuation.schedule(turn: turn, at: resetsAt)
    }

    /// Where the composer's ring comes from: the reset of the limit the last turn ended on, from
    /// the CLI or else the plan's limits. A turn starting ends it; the turn of a message sent at
    /// the reset ending lets Stay awake go.
    private func noteLimitReset(_ event: ChatEvent) {
        switch event {
        case .turnStarted:
            if limitReset != nil { limitReset = nil }
        case .turnFinished(let id, .limited(_, let resetsAt), _):
            guard let turn = id ?? turnBegan?.id else { return }
            if let resetsAt {
                limitReset = (turn, resetsAt)
                return
            }
            let epoch = workEpoch
            Task { [weak self] in
                guard let self, let reading = try? await connect().usage(),
                    currentWork(epoch), case .limited(let until?) = reading.limits?.blocked(now: Date()), !status.isRunning
                else { return }
                limitReset = (turn, until)
            }
        case .turnFinished:
            if sendsAtReset == nil, continuation.pending == nil { releaseAwakeForReset() }
        default:
            break
        }
    }

    /// A turn that failed while the Mac slept (or just after it woke) says so, in place of the
    /// CLI's line.
    private func sleptOutcome(_ event: ChatEvent) -> ChatEvent {
        switch event {
        case .turnStarted(let id, _, let at):
            turnBegan = (id, at)
        case .turnFinished(let id, .failed(let said), let duration):
            let began = turnBegan
            turnBegan = nil
            if let began, id == nil || id == began.id, StayAwake.current?.sleptThrough(since: began.at) == true {
                return .turnFinished(id, .slept(said), duration: duration)
            }
        case .turnFinished, .exited:
            turnBegan = nil
        default:
            break
        }
        return event
    }

    // MARK: Actions

    func stop() {
        if transcript.pendingSendSince != nil {
            sending?.cancel()
            transcript.sending(false)
        }
        // Not sent yet: there's no turn to interrupt, only the wait.
        if waitingForNetwork {
            // The cancelled network wait clears running and records why nothing was sent.
            // Keep that transition together so observers cannot see idle before the notice.
            sending?.cancel()
            return
        }
        continueAfterCompaction = false
        compactedInTurn = false
        let backend = backend
        Task { await backend?.interrupt() }
        // A CLI that doesn't answer (a dead connection, a wedged process) is ended after 5 s;
        // a turn sent since isn't this Stop's.
        let serial = turnSerial
        let epoch = workEpoch
        stopFallback?.cancel()
        stopFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.currentWork(epoch), self.status.isRunning, self.turnSerial == serial else { return }
            SessionLog.shared.rescue(self.provider.id, chat: self.sessionId, action: "stop-unanswered")
            self.restartCLI(reason: "stop unanswered")
        }
    }

    /// The context wheel's click (look §9): compacts at once, between turns only.
    var canCompact: Bool { status.sessionId != nil && !status.isRunning && !context.compacting }

    /// `instructions`: what the summary should keep (`/compact <instructions>`); empty for none.
    /// The transcript's live row shows from here, before the CLI says it started. `point`: Kore
    /// compacts by itself, at the chat's auto-compact point.
    func compact(instructions: String = "", at point: Int? = nil) {
        guard canCompact else { return }
        autoCompactDue = false
        // Kore's own, after a turn that ran to its end: the work goes on after it.
        continueAfterCompaction = point != nil && lastTurnCompleted
        context.begin()
        transcript.compacting(true, at: point)
        let backend = connect()
        Task {
            do {
                try await backend.start()
            } catch {
                // The CLI didn't start: no compaction was asked of it, so it's said as any start's.
                context.end()
                transcript.compacting(false)
                fail(Self.reason(error))
                return
            }
            do {
                try await backend.compact(instructions: instructions)
            } catch {
                dispatch(.compactionFailed(Self.reason(error)))
            }
        }
    }

    /// The card's auto-compact point: this chat's, kept for when it's reopened, and the
    /// provider's for new chats. Off is a point too.
    func setAutoCompact(_ point: Int?) {
        guard context.autoCompactAt != point || !ownAutoCompact else { return }
        context.autoCompactAt = point
        ownAutoCompact = true
        if let id = sessionId { compactMemory.remember(point, chat: id) }
    }

    /// A fork starts at its original's point, and keeps it as its own when the original had one.
    func inheritAutoCompact(from original: Chat) {
        context.autoCompactAt = original.context.autoCompactAt
        ownAutoCompact = original.ownAutoCompact
    }

    /// Auto-compact: Kore compacts between turns, when the user's turn ends at or past the
    /// chat's point, the same for both CLIs (their own auto-compact stays on, for a turn that
    /// overruns). The turn's last usage report may come just after it ends. A message queued
    /// meanwhile goes first, and its turn's end looks again.
    private func autoCompactIfDue(_ event: ChatEvent) {
        switch event {
        case .turnStarted(_, let origin, _):
            // A compaction's own turn (Kore's, as both CLIs run one) isn't the user's.
            if origin == .user && !context.compacting {
                inContinueTurn = continueSent
                continueSent = false
                if !inContinueTurn { autoCompactDue = true }
                compactedInTurn = false
            }
        case .compacted(_, _, let auto):
            autoCompactDue = false
            // The CLI's own, mid-turn: the turn goes on, unless it ends with nothing after it.
            if auto == true, status.isRunning { compactedInTurn = true }
            if continueAfterCompaction, !status.isRunning { sendContinueAfterCompaction() }
        case .text, .toolStarted:
            compactedInTurn = false
        case .compactionStarted:
            autoCompactDue = false
        case .compactionFailed, .exited:
            autoCompactDue = false
            continueAfterCompaction = false
            compactedInTurn = false
        case .turnFinished(_, let outcome, _):
            lastTurnCompleted = outcome == .completed && !context.compacting
            if continueAfterCompaction, !context.compacting {
                sendContinueAfterCompaction()
                return
            }
            let stoppedByCompaction = compactedInTurn && outcome == .completed && !inContinueTurn
            compactedInTurn = false
            if inContinueTurn { lastTurnCompleted = false }
            if autoCompactDue, context.pastPoint, canCompact, waiting.isEmpty, let point = context.autoCompactAt {
                compact(at: point)
            } else if stoppedByCompaction, waiting.isEmpty {
                continueSent = true
                deliver("Continue", [])
            }
        case .contextUsage:
            guard autoCompactDue, context.pastPoint, canCompact, waiting.isEmpty, let point = context.autoCompactAt
            else { return }
            compact(at: point)
        default:
            break
        }
    }

    private func sendContinueAfterCompaction() {
        continueAfterCompaction = false
        guard waiting.isEmpty else { return }
        continueSent = true
        deliver("Continue", [])
    }

    /// The instructions of a typed `/compact` (empty when it has none); nil for anything else.
    static func compactCommand(_ text: String) -> String? {
        let command = "/compact"
        guard text.hasPrefix(command), text.dropFirst(command.count).first.map(\.isWhitespace) ?? true else { return nil }
        return text.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An error as the chat says it: its own readable text (Codex's message, parsed), else its
    /// description. Never Foundation's "The operation couldn't be completed".
    static func reason(_ error: Error) -> String {
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        // Foundation's own errors have their sentence; Kore's and the CLIs' say themselves.
        return type(of: error) is NSError.Type ? error.localizedDescription : String(describing: error)
    }

    /// Loads a sub-agent's own transcript the first time it's opened, when the chat doesn't have
    /// it (a replayed chat's agents, Codex children).
    func loadAgentIfNeeded(_ id: String) {
        guard transcript.needsHistory(id) else { return }
        let backend = connect()
        Task {
            try? await backend.start()
            let events = await backend.agentHistory(id)
            if !events.isEmpty { transcript.replaceLane(of: id, with: events) }
        }
    }

    /// Where a fork from this user message starts (`ChatBackend.fork`); nil after a failure,
    /// which shows as "Couldn't fork: …" in this chat.
    func forkStart(_ entry: TranscriptStore.Entry) async -> ForkStart? {
        do {
            return try await connect().fork(message: entry.source, text: entry.text)
        } catch {
            fail("Couldn't fork: \(error.localizedDescription)")
            return nil
        }
    }

    /// Where a fork from an answer starts: through that answer's turn. That's the history before
    /// the next user message, or the whole conversation when the answer is in the last turn.
    func forkStart(after answer: TranscriptStore.Entry) async -> ForkStart? {
        let entries = transcript.entries
        let next = entries.firstIndex { $0.id == answer.id }.flatMap { index in
            // A message taken into a running turn isn't a new turn: forking there would cut it in half.
            entries[(index + 1)...].first { ($0.kind == .user || $0.kind == .peer) && !$0.inTurn }
        }
        do {
            let backend = connect()
            if let next { return try await backend.fork(message: next.source, text: next.text) }
            return try await backend.forkAtEnd()
        } catch {
            fail("Couldn't fork: \(error.localizedDescription)")
            return nil
        }
    }

    /// A history that starts at a compaction with little after it: the conversation before it
    /// shows too (a page), not just the summary under a "Load earlier" row.
    private func showBeforeCompaction(_ event: ChatEvent) {
        guard case .earlierHistory(true) = event, transcript.userTurns < 10 else { return }
        loadEarlierConversation()
    }

    /// The conversation before a compaction, ten turns at a time.
    func loadEarlierConversation() {
        guard transcript.earlierAvailable, !transcript.loadingEarlier else { return }
        transcript.startLoadingEarlier()
        let backend = connect()
        Task {
            let page = await backend.earlier()
            transcript.prepend(page?.events ?? [], more: page?.more ?? false)
        }
    }

    /// Dev hook (`KORE_QUEUE`): sends `text` the way a message sent mid-turn goes, with an id
    /// for `.queuedMessage`, until the composer queues (look.md §10).
    /// KORE_QUEUE: sends as the composer does (queued, since a turn runs).
    func devQueue(_ text: String) {
        draft = text
        send()
    }

    /// A queued message dropped by Stop: its text and files go back to the composer.
    private func restoreQueued(_ event: ChatEvent) {
        guard case .queuedMessage(let id, let delivery) = event, let message = waiting.removeValue(forKey: id) else { return }
        waitingOrder.removeAll { $0 == id }
        guard delivery == .dropped else { return }
        if command == nil, draft.isEmpty {
            restoreDraft(message.text, commands: controls.commands)
        } else {
            draft = draft.isEmpty ? message.text : message.text + "\n" + draft
        }
        attachments = message.files + attachments
    }

    // MARK: Commands

    /// Stop on a command's row, confirmed: the row says "stopped" when the CLI does.
    func stopCommand(_ id: String) {
        guard let command = commands.command(id), command.canStop, !command.stopping, let backend else { return }
        dispatch(.commandChanged(id: id, .stopping))
        Task {
            do {
                try await backend.stopCommand(id)
            } catch {
                dispatch(.commandChanged(id: id, .actionFailed("Couldn't stop it: \(Self.reason(error))")))
            }
        }
    }

    /// Stop all: every live command but the armed jobs.
    func stopAllCommands() {
        for command in commands.stoppable { stopCommand(command.id) }
    }

    /// A long foreground command's Run in background: the same row runs on.
    func runInBackground(_ id: String) {
        guard let command = commands.command(id), command.canBackground, let backend else { return }
        Task {
            do {
                try await backend.backgroundCommand(id)
            } catch {
                dispatch(.commandChanged(id: id, .actionFailed("Couldn't move it to the background: \(Self.reason(error))")))
            }
        }
    }

    /// The end of a command's output, for its opened row: its file read from the end off the
    /// main thread, or what streamed, or the CLI's own tail when Kore can't read the file. Read
    /// only while the row is open.
    func commandTail(_ id: String, lines: Int = 40) async -> OutputTail? {
        guard let command = commands.command(id) else { return nil }
        switch command.output {
        case .stream:
            return OutputTail(lines: commands.streamedTail(id, lines: lines), modified: command.lastOutputAt)
        case .file(let path):
            let file = URL(fileURLWithPath: path)
            if let tail = await Task.detached(priority: .utility, operation: { OutputTail.read(file, lines: lines) }).value { return tail }
            fallthrough
        case .none:
            guard command.isLive, let text = await backend?.commandOutput(id) else { return nil }
            return OutputTail(lines: OutputTail.lines(of: text, count: lines))
        }
    }

    /// A pane listing commands is showing (or not): the CLI is asked about them more often.
    func watchCommands(_ closely: Bool) {
        let backend = backend
        Task { await backend?.watchCommands(closely) }
    }

    func stopAgent(_ id: String) {
        let backend = backend
        Task { await backend?.stopAgent(id) }
    }

    /// A live mode change by the agent: the pill says who, and flashes (look.md §8).
    private func noteAgentModeChange(_ event: ChatEvent) {
        let source: ModeSource
        switch event {
        case .modeChanged(let change): source = change.source
        case .planModeChanged(let change): source = change.source
        default: return
        }
        guard case .agent(_, let agent) = source else { return }
        controls.changedBy = agent.sub.flatMap { transcript.agent($0)?.name } ?? provider.name
        controls.agentChangeSeq &+= 1
    }

    /// `remember`: the user picked it, so new chats start in it.
    func setMode(_ id: String, remember: Bool = true) {
        controls.changedBy = nil
        let previous = controls.mode
        controls.mode = id
        let backend = backend
        Task {
            do {
                try await backend?.setMode(id)
                if remember { controls.remember(id) }
            } catch {
                controls.mode = previous
                fail("Couldn't switch mode: \(error)")
            }
        }
    }

    func setPlanMode(_ on: Bool) {
        controls.changedBy = nil
        controls.planMode = on
        let backend = backend
        Task { await backend?.setPlanMode(on) }
    }

    /// A new chat's mode (the one last picked) that its model doesn't offer gives way to the first.
    private func dropUnofferedMode(_ event: ChatEvent) {
        guard case .controlsLoaded = event, resume == nil, !controls.modeOffered else { return }
        setMode(provider.modes[0].id, remember: false)
    }

    /// Shift+Tab, as in each CLI.
    func cycleMode() {
        switch provider.nextMode(controls.mode, controls.planMode, controls.availableModes) {
        case .mode(let next): setMode(next)
        case .togglePlan: setPlanMode(!controls.planMode)
        }
    }

    /// Codex CLI's "Yes, implement this plan": switch plan off and start coding.
    func implementPlan() {
        setPlanMode(false)
        draft = "Implement the plan."
        send()
    }

    func stayInPlanMode() {
        approvals.offerImplementPlan = false
    }

    /// A model without the current effort takes its nearest level below (the picker's thumb
    /// slides down to it).
    func setModel(_ option: ModelOption) {
        controls.modelId = option.id
        let level = EffortScale.fallback(controls.effort, offered: option.efforts, scale: controls.effortScale)
        if let level, level != controls.effort { setEffort(level) }
        let backend = backend
        Task {
            do {
                try await backend?.setModel(option.id)
            } catch {
                fail("Couldn't switch model: \(error)")
            }
        }
    }

    func setEffort(_ level: String) {
        controls.effort = level
        let backend = backend
        Task { await backend?.setEffort(level) }
    }

    /// The CLI's report follows and has the last word; one it refused puts the switch back.
    func setFastMode(_ on: Bool) {
        guard controls.fastModeEnabled, let backend else { return }
        let previous = controls.fastMode
        controls.fastChanging = true
        controls.fastMode = on
        UILog.event("fast-mode", ["cli": provider.id, "chat": status.sessionId, "on": on ? "yes" : "no"])
        Task {
            defer { controls.fastChanging = false }
            do {
                try await backend.setFastMode(on)
                launchFastMode = on
            } catch {
                controls.fastMode = previous
                fail("Couldn't switch fast mode: \(error)")
            }
        }
    }

    func answer(_ approval: Approval, _ decision: Decision) {
        approvals.remove(approval.id)
        transcript.approvalSettled(approval.id)
        if case .deny = decision { transcript.actionDenied() }
        let backend = backend
        Task { await backend?.respond(to: approval.id, decision) }
    }
}

extension SentAttachment {
    /// A composer attachment as the transcript shows it; the transcript reads it from `url`.
    init(_ attachment: Attachment) {
        let image: Data? = nil
        self.init(name: attachment.name, kind: attachment.kind, url: attachment.url, image: image)
    }
}

extension Chat {
    /// The transcript's entries as text, one per line: what `KORE_DUMP` and storyline
    /// `DumpRows` write, so replays compare across builds.
    package func dumpLines() -> [String] {
        transcript.entries.map { e in
            let files = e.attachments.map { "\($0.name):\($0.kind):\($0.thumbnail != nil)" }.joined(separator: ",")
            // Kinds keep their earlier names, so dumps compare across builds.
            let kind = e.kind == .answer ? "assistant" : "\(e.kind)"
            return [kind, e.toolName ?? "", e.text, e.result ?? "", "\(e.done)", "\(e.isError)", files, e.from ?? ""]
                .joined(separator: " | ").replacingOccurrences(of: "\n", with: "⏎")
        }
    }
}

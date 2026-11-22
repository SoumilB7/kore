import Foundation
import KoreCore
import Observation

/// One conversation with a CLI. Its engine (`ChatEngine`) runs the backend; it hands each
/// `ChatEvent` to the stores, one per feature: the transcript, approvals, controls (mode, model, commands), status and
/// context (how full it is, compacting). Views
/// read the store they show, so a streamed token re-renders the transcript alone and typing
/// re-renders the composer alone. The composer's draft and attachments live here, sent and
/// cleared by `send()`.
@MainActor @Observable
package final class Chat: Identifiable {
    package let id = UUID()
    package let provider: ProviderDescriptor
    package var folder: URL
    /// Replaced only when a replayed history is corrected (`.historyReplaced`).
    package private(set) var transcriptView: any ChatTranscript
    /// The chat's view state (popups, the agent map), as the app keeps it.
    package let ui: AnyObject
    /// What the app supplies: account, stay awake, network, logs and taps.
    @ObservationIgnored package let services: any ChatServices
    package let approvals = ApprovalsStore()
    package let controls: ControlsStore
    package let status: ChatStatus
    package let context = ContextStore()
    /// What it runs apart from its turns: background shells, monitors, scheduled jobs.
    package let commands = CommandsStore()

    /// Waiting in the composer, sent with the next message.
    package var attachments: [Attachment] = [] {
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
    @ObservationIgnored package var onDraftChanged: (() -> Void)?
    @ObservationIgnored package var restoringComposerDraft = false
    /// The / menu was closed (Esc, a click away, another popup) for the "/word" at the caret;
    /// the next one opens it again.
    package var slashClosed = false
    /// Launch with this model and effort instead of the CLI's defaults (a fork, the dev hook).
    @ObservationIgnored package var launchModel: String?
    @ObservationIgnored package var launchEffort: String?
    @ObservationIgnored package var launchFastMode: Bool?
    /// Variables its CLI starts with, read at each start (a box chat's Claude account,
    /// `CLAUDE_CONFIG_DIR`); throws when the CLI mustn't start (that account is gone).
    @ObservationIgnored package var launchEnvironment: (@MainActor () throws -> [String: String])?

    /// The backend, its events' pump and the send chain.
    @ObservationIgnored private let engine: ChatEngine
    /// Each of the backend's events as it came, before the chat takes it (`ChatEngine.rawTap`).
    package var backendTap: (@MainActor (ChatEvent) -> Void)? {
        get { engine.rawTap }
        set { engine.rawTap = newValue }
    }
    /// Each event the chat makes of its own (not its backend's): a message dropped as its CLI
    /// starts again, a turn it ends, a compaction it stops, a permission it allows itself. A box's
    /// chat logs them, so the clients following it see them too.
    @ObservationIgnored package var ownTap: (@MainActor (ChatEvent) -> Void)?
    /// A message going back to the composer, by its id when it has one: true when it went to
    /// another one (a box's chat returns it to the client that sent it), so this composer keeps
    /// what it has.
    @ObservationIgnored package var returnsToComposer: (@MainActor (_ id: String?, _ text: String) -> Bool)?
    /// It sends Kore's own "Continue" and compacts at its point by itself. Off for a box's chat
    /// while a Mac drives it: that Mac's chat does both, once.
    @ObservationIgnored package var automatic = true
    private var backend: (any ChatBackend)? { engine.backend }
    @ObservationIgnored private let resume: SessionSummary?
    /// When the session it resumed was last written (nil for a new chat).
    package var resumedUpdated: Date? { resume?.updated }
    /// A fork the CLI makes when it starts (Codex) or on its first message (Claude).
    @ObservationIgnored package let fork: ForkPoint?
    /// The chat this one was forked from, for the line after its history.
    @ObservationIgnored private var forkedFrom: String?
    /// A pasted copy's line above its history ("copied from “Repos” · mybox"), set before the
    /// history comes; shown once.
    @ObservationIgnored package var copiedFrom: String?
    /// An imported chat's carried part (`ImportedHistory`), shown above its own history, and
    /// its events once read.
    @ObservationIgnored package let imported: ImportedHistory?
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
    package var isWaitingForNetwork: Bool { waitingForNetwork }
    @ObservationIgnored private var networkObserver: (any NSObjectProtocol)?
    /// The running turn's connection, as its spinner and tab show it (`Connection.stuck`: ⚠).
    package private(set) var connection = Connection.ok
    /// When the CLI last said anything, and the turn's watchdog (`checkStall`).
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// A Stop's fallback (`stop`), and which turn it was for: one sent since isn't ended by it.
    @ObservationIgnored private var stopFallback: Task<Void, Never>?
    @ObservationIgnored private var turnSerial = 0
    /// The running turn, for its one `turn` line in sessions.log.
    @ObservationIgnored private var turnTally: TurnTally?
    /// Online, waiting on the model (no tool, agent, approval or compaction under way), and
    /// nothing heard for this long: the turn's connection likely died unnoticed. A storyline
    /// sets it shorter.
    package static let stallAfter = HostSetting<TimeInterval>(90)
    /// That chat, while it's open (its "Forked from" line switches to it).
    @ObservationIgnored package weak var original: Chat?
    /// The chat has been shown, so its CLI was started once (`startOnce`).
    @ObservationIgnored package private(set) var shown = false
    @ObservationIgnored private let compactMemory: AutoCompactMemory
    /// The auto-compact point is the chat's own (picked in it, kept for its session, or its
    /// original's when it's a fork), not the provider's: kept under its session id once known.
    @ObservationIgnored private var ownAutoCompact = false
    /// The point is the chat's own (`ChatSettings` carries it only then).
    package var ownsAutoCompact: Bool { ownAutoCompact }
    /// When its settings (mode, plan, model, effort, fast, auto-compact, Arsenal) last changed
    /// here: on a send back, the newer of the box's and this side's wins.
    @ObservationIgnored package var settingsChangedAt: Date?
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
    /// Arsenal's Own asked for a compaction during a turn (its agent asks from inside one).
    @ObservationIgnored package var compactAfterTurn = false
    /// The user said Always allow in this chat since Kore opened it: the CLI keeps a rule Arsenal
    /// can't see, so a chat without one doesn't drive it (`noFreer(than:)`).
    @ObservationIgnored package var alwaysAllowed = false
    @ObservationIgnored private var compactedInTurn = false
    /// Stop came while a compaction ran: however it ends short of done is said as stopped, not
    /// failed. Both CLIs report the cancel as a failure (`compactionFailed`).
    @ObservationIgnored private var stoppingCompaction = false
    /// The turn the next starts is Kore's own Continue, and the one running is: neither counts
    /// as the user's, so it neither compacts at the point nor continues again (no loop).
    @ObservationIgnored private var continueSent = false
    @ObservationIgnored private var inContinueTurn = false
    /// The CLI's account changed since its CLI started: it starts again (with resume) at the
    /// next turn boundary, so it runs as the new account.
    @ObservationIgnored private var relaunchDue = false
    @ObservationIgnored private var stoppedForAccount = false
    private var workEpoch: UInt64 { engine.workEpoch }
    package private(set) var accountRestartPending = false
    /// An account switch or sign-out stopped its work: its tab shows ⚠ until the next send.
    package private(set) var interruptedByAccount = false

    private func currentWork(_ epoch: UInt64) -> Bool { engine.currentWork(epoch) }
    /// The turn running now, and when it began: a failure is the sleep's when the Mac slept since.
    @ObservationIgnored private var turnBegan: (id: TurnID, at: Date)?
    /// Stay awake's continuation after the plan's limit (`LimitContinuation`).
    @ObservationIgnored private lazy var continuation = makeContinuation()
    /// When the chat continues after its plan's limit resets; nil when it won't.
    package private(set) var continuesAt: Date?
    /// The last turn ended on the plan's limit, which resets `at`: a message can wait for it.
    package private(set) var limitReset: (turn: TurnID, at: Date)?
    /// A message set to go when the limit resets (`sendAtReset`), out of the composer, and when
    /// it was set (the wait the composer's ring counts down).
    package private(set) var sendsAtReset: (command: SlashCommand?, draft: String, attachments: [Attachment], since: Date)?
    /// Stay awake was turned on for that message; it goes off again once it's sent or cancelled.
    @ObservationIgnored private var awakeForReset = false
    /// Its tab closed: nothing of it counts as running any more.
    private var closed = false

    /// `fork` makes this chat a fork of `session` that its CLI creates; it has no session of its
    /// own until then. `forkedFrom` names the original chat.
    package init(
        provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil, fork: ForkPoint? = nil,
        forkedFrom: String? = nil, imported: ImportedHistory? = nil, modeMemory: ModeMemory,
        compactMemory: AutoCompactMemory, services: any ChatServices
    ) {
        self.provider = provider
        self.services = services
        engine = ChatEngine(provider: provider, services: services)
        transcriptView = services.makeTranscript()
        ui = services.makeViewState()
        self.folder = folder
        resume = session
        self.fork = fork
        self.forkedFrom = forkedFrom
        // A reopened chat Kore made by an import has its record, and so does a fork of one (its
        // session is the original's until its own comes, when the record is kept for that too).
        self.imported = imported ?? session.flatMap { ImportedHistory.of(session: $0.id) }
        awaitingHistory = session != nil
        controls = ControlsStore(provider: provider, memory: modeMemory) { [services] in services.modelsListed($0, $1) }
        self.compactMemory = compactMemory
        // A reopened chat (a restored tab, or from history) has its own point back; a fork's
        // session is its original's until its own comes (`inheritAutoCompact`). Any other starts
        // Off: a point is one chat's, not every chat's.
        if fork == nil, let id = session?.id, let own = compactMemory.point(chat: id) {
            context.autoCompactAt = own
            ownAutoCompact = true
        }
        if fork == nil, let id = session?.id { controls.restorePlanAllow(chat: id) }
        status = ChatStatus(resume: fork == nil ? session : nil)
        if fork != nil { status.name = session?.title }
        transcriptView.providerName = provider.name
        transcriptView.chatID = { [weak self] in self?.sessionId }
        transcriptView.provider = provider
        services.register(self)
        if let imported = self.imported {
            // An imported chat's carried part is read before its own history shows.
            engine.beforeHistory = { [weak self] in
                let events = await imported.events()
                return {
                    self?.importedEvents = events
                    self?.engine.beforeHistory = nil
                }
            }
        }
    }

    /// What its CLI, and what runs under it, names this chat by on Kore's agent channel.
    package let agentPass = AgentPasses.make()
    /// Its Arsenal tier while on, and the one turning it on goes back to. Set through `Arsenal`.
    package var arsenal: ArsenalTier?
    package var arsenalLast = ArsenalTier.watch
    /// The tier the agent was last told of (nil: off, as its launch instructions say until told).
    @ObservationIgnored package var arsenalTold: ArsenalTier?
    /// What Kore keeps its tier under across restarts (`ArsenalMemory`), and whether a kept tier
    /// waits for the chat to be able to have it (a Codex chat's mode, not known yet).
    @ObservationIgnored package var arsenalKept: String?
    @ObservationIgnored package var arsenalWaiting = false
    /// Opened by an agent (Act unlimited's open): a kept tier isn't brought back for it.
    @ObservationIgnored package var arsenalByAgent = false
    /// The chats whose agents made it (a new chat, a fork, a woken one), nearest first, by
    /// `arsenalKey`, for as long as it's open: none of them allows its commands (`arsenalStarted`).
    @ObservationIgnored package var arsenalOrigins: [String] = []
    /// What `arsenalOrigins` names it by: its id; on kore-host, its box chat's (`hostKey`).
    package var arsenalKey: String { hostKey ?? id.uuidString }
    @ObservationIgnored package var hostKey: String?

    package var sessionId: String? { status.sessionId }
    /// The id the folder's history lists it under: its session's, or a fork's own before its
    /// CLI names one (`KoreForks`).
    package var listedId: String? { sessionId ?? fork?.id }
    package var resumed: Bool { status.resumed }
    package var hasConversation: Bool { status.hasConversation }
    package var title: String { status.title(fallback: provider.name) }
    /// Its CLI's id ("claude", "codex"), for storylines.
    package var providerID: String { provider.id }

    /// The CLI's current name for a past session (it may have been renamed elsewhere).
    package func adoptName(_ newName: String) { status.name = newName }

    /// A user rename, saved by the CLI (Claude: custom title, Codex: thread name).
    package func rename(_ newName: String) {
        Task { await applyRename(newName) }
    }

    /// Renames and waits until the CLI has it (starting the CLI if needed).
    package func applyRename(_ newName: String) async {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        status.name = newName
        await start()
        // A CLI started for it says its session's old title as it starts: once it has the new
        // one, that's the name again.
        guard let backend, (try? await backend.rename(newName)) != nil else { return }
        status.name = newName
    }

    /// The name a typed `/rename` gives (nil: not one, or this chat's CLI keeps no title).
    private func typedRename(_ text: String, files: Bool) -> String? {
        guard !files, provider.renames else { return nil }
        return SlashCommand.renameArgument(text)
    }

    /// A typed `/rename <name>` renames as the tab's Rename does; nothing goes to the CLI as a
    /// message. Without a name, the usage line.
    private func renameTyped(_ name: String) {
        let line = ChatEvent.notice(name.isEmpty ? SlashCommand.renameUsage : "Renamed to \(name)")
        if awaitingHistory { hold(line) } else { dispatch(line) }
        if !name.isEmpty { rename(name) }
    }

    /// A typed `/model`, `/effort` or `/fast`: Kore's own switch, as its pickers make it, so they
    /// never go stale (the CLI's own would switch without telling Kore). `/fast` is broken through
    /// the claude CLI headless anyway.
    package enum TypedControl: Equatable {
        case model(String), effort(String), fast(String)
    }

    package nonisolated static func typedControl(_ text: String) -> TypedControl? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = String(trimmed.dropFirst().prefix { !$0.isWhitespace })
        let rest = trimmed.dropFirst(1 + name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "model": return .model(rest)
        case "effort": return .effort(rest)
        case "fast": return .fast(rest.lowercased())
        default: return nil
        }
    }

    /// The model `name` picks from the CLI's list: by id, name or the model it resolves to.
    package nonisolated static func model(named name: String, in models: [ModelOption]) -> ModelOption? {
        let same = { (a: String) in a.caseInsensitiveCompare(name) == .orderedSame }
        return models.first { same($0.id) } ?? models.first { same($0.name) } ?? models.first { same($0.resolved) }
    }

    private func controlTyped(_ typed: TypedControl) {
        let line = ChatEvent.notice(typedControlLine(typed))
        if awaitingHistory { hold(line) } else { dispatch(line) }
    }

    /// Does what it says, when the chat offers it; the line saying what happened, or how to use it.
    private func typedControlLine(_ typed: TypedControl) -> String {
        switch typed {
        case .model(let name):
            let models = controls.models
            guard !models.isEmpty else { return "The models aren't listed yet; try again once the chat has started." }
            let names = models.map(\.id).joined(separator: ", ")
            guard !name.isEmpty else { return "Usage: /model <name>, one of: \(names)" }
            guard let option = Self.model(named: name, in: models) else { return "No model \(name) here; one of: \(names)" }
            setModel(option)
            return "Model set to \(option.name)"
        case .effort(let level):
            let offered = controls.currentModel?.efforts ?? []
            guard !offered.isEmpty else { return "This model takes no effort level." }
            let match = offered.first { $0.caseInsensitiveCompare(level) == .orderedSame }
            guard let match else { return "Usage: /effort <level>, one of: \(offered.joined(separator: ", "))" }
            setEffort(match)
            return "Effort set to \(match)"
        case .fast(let arg):
            let on: Bool
            switch arg {
            case "": on = !controls.fastMode
            case "on": on = true
            case "off": on = false
            default: return "Usage: /fast [on|off]"
            }
            guard controls.fastModeEnabled, backend != nil else { return "Fast mode isn't available here now." }
            setFastMode(on)
            return on ? "Fast mode on" : "Fast mode off"
        }
    }

    // MARK: Events

    /// Every event goes to every store; each takes what it shows. `own`: the chat made it, not its backend.
    private func dispatch(_ event: ChatEvent, own: Bool = true) {
        let event = stoppedCompaction(sleptOutcome(event))
        if own { ownTap?(event) }
        if case .historyReplaced(let events) = event {
            replaceHistory(events)
            services.tap(self, event)
            return
        }
        if case .conversationReset(let id) = event {
            resetConversation(to: id)
            return
        }
        let start = services.timeReplay && Self.isReplay(event) ? ContinuousClock.now : nil
        noteHeard(event)
        if case .replayed = event, let line = copiedFrom {
            copiedFrom = nil
            transcriptView.carriedFrom(line, help: line)
        }
        if case .replayed = event { showImported(in: transcriptView) }
        transcriptView.apply(event, preserving: backend?.observedAgents ?? [])
        commands.apply(event)
        noteSinceReplay(event)
        if case .replayed = event, let original = forkedFrom {
            // A fork's history ends with where it came from.
            forkedFrom = nil
            transcriptView.forkedFrom(original)
        }
        if case .approvalRequested(let ask) = event, autoAllows(ask) {
            // Allow commands in Plan: answered at once, no card; the tool's row still shows what ran.
            autoAllow(ask)
        } else {
            approvals.apply(event)
        }
        controls.apply(event)
        arsenalFollowMode()
        noteAgentModeChange(event)
        dropUnofferedMode(event)
        restoreQueued(event)
        // A new chat's (or a fork's) session id comes with its first turn: its point is kept under it.
        if case .sessionIdentified(let id) = event, ownAutoCompact, id != status.sessionId {
            compactMemory.remember(context.autoCompactAt, chat: id)
        }
        if case .sessionIdentified(let id) = event, controls.planAllow, id != status.sessionId, !(backend?.keepsPlanAllow ?? false) {
            controls.keepPlanAllow(chat: id)
        }
        if case .sessionIdentified(let id) = event, let record = imported?.record, record.target.session != id {
            Task.detached { HandoffRecords.alias(record, session: id) }
        }
        noteFork(event)
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
        sendHeldAfterCompaction(event)
        afterAccountEvent(event)
        continueAfterLimit(event)
        showBeforeCompaction(event)
        if let start { services.logReplay(ContinuousClock.now - start) }
        if case .replayed = event { showHeld() }
        services.tap(self, event)
        // A stopped turn took the compaction in it along, whether or not the CLI said so.
        if case .turnFinished = event, stoppingCompaction, context.compacting { dispatch(.compactionStopped) }
        noteModelList(event)
        switch event {
        case .earlierHistory: unloadOld(opening: true)
        case .turnFinished: unloadOld()
        default: break
        }
    }

    /// Kore's record of a fork it lists follows its CLI: the id the CLI names it by. That a
    /// message went out (from then the CLI has the session) is noted as the send returns: a
    /// fork whose CLI never started stays a fork through a reload.
    private func noteFork(_ event: ChatEvent) {
        guard let key = fork?.id else { return }
        switch event {
        case .sessionIdentified(let id): KoreForks.shared.identified(cli: provider.id, key: key, as: id)
        default: break
        }
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
        let store = services.makeTranscript()
        store.providerName = transcriptView.providerName
        store.chatID = transcriptView.chatID
        store.provider = transcriptView.provider
        showImported(in: store)
        store.apply(.replayed(events))
        if backend?.historiesWhole != true { for event in sinceReplay ?? [] { store.apply(event) } }
        if let since = transcriptView.pendingSendSince { store.sending(true, at: since) }
        transcriptView = store
        services.transcriptReplaced(self)
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
    private func showImported(in store: any ChatTranscript) {
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
        waiting.forEach { dispatch($0) }
        SessionLog.shared.shown(provider.id, chat: sessionId, rows: transcriptView.entries.count, held: waiting.count, late: late)
    }

    /// How long a message sent before the history came waits for it.
    package static let heldPatience: Duration = .seconds(8)

    /// A message held for the history: shown after `heldPatience` if the history hasn't come.
    private func hold(_ message: ChatEvent) {
        held.append(message)
        guard held.count == 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.heldPatience)
            self?.showHeld(late: true)
        }
    }

    private static func isReplay(_ event: ChatEvent) -> Bool { ChatEngine.isReplay(event) }

    private func fail(_ message: String) {
        // No history is coming.
        showHeld()
        dispatch(.notice(message, isError: true))
    }

    // MARK: Lifecycle

    /// Starts the CLI the first time the chat shows. Showing it again (switching back to its
    /// tab) leaves the CLI be: one that failed to start, or has exited, starts again with the
    /// next send, not with a tab switch.
    package func startOnce() async {
        guard !shown else { return }
        shown = true
        await start()
    }

    package func start() async {
        guard !closed, !Task.isCancelled else { return }
        let epoch = workEpoch
        if let error = await launchCLI() {
            guard currentWork(epoch), !Task.isCancelled, !(error is CancellationError) else { return }
            fail("Couldn't start \(provider.name): \(Self.reason(error))")
        }
    }

    /// Waits before each start again of a CLI that wouldn't start. A storyline sets them shorter.
    package static let startRetries = ChatEngine.startRetries

    /// Starts the CLI (`ChatEngine.launch`), saying once, at the first failure, that it tries again.
    private func launchCLI() async -> Error? {
        await engine.launch(connect) { [weak self] error in
            guard let self else { return }
            self.dispatch(.notice("Couldn't start \(self.provider.name): \(Self.reason(error)). Trying again…"))
        }
    }

    /// The backend, made on first use with the chat's current settings.
    package func connect() -> any ChatBackend {
        engine.connect({
            var options = BackendOptions(
                folder: folder, resume: resume, mode: controls.mode, planMode: controls.planMode,
                model: launchModel, effort: launchEffort, fork: fork, forkTitle: fork == nil ? nil : status.name)
            options.fastMode = launchFastMode
            options.environment = launchEnvironment
            if services.agentTools {
                options.agentPass = agentPass
            } else if let server = services.agentServer(self) {
                options.agentPass = agentPass
                options.agentServer = server
            }
            if let imported {
                options.hiddenRows = Set(imported.record.written)
                options.instructions = imported.record.instructions.map { URL(fileURLWithPath: $0) }
            }
            if options.instructions == nil { options.instructions = services.instructions }
            return options
        }) { [self] event in self.dispatch(event, own: false) }
    }

    // MARK: Account

    /// A turn or a background agent is running.
    package var isWorking: Bool { !closed && (isBusy || !transcriptView.runningAgents.isEmpty) }

    /// A turn, a background agent or a command Stop applies to is running: what a sign-out or
    /// a switch of its login stops.
    package var hasWork: Bool { !closed && (isWorking || waitingForNetwork || commands.summary.total > 0) }

    /// Its login is going (a sign-out) or moving (a switch): the turn, the background agents
    /// and the commands stop, and the CLI starts again as the new login once they have.
    package func stopAllWork() {
        cancelContinue()
        if hasWork { interruptedByAccount = true }
        stoppedForAccount = true
        if isBusy || waitingForNetwork { stop() }
        let observed = backend?.observedAgents ?? []
        for agent in transcriptView.runningAgents where !observed.contains(agent) { stopAgent(agent) }
        for command in commands.stoppable where command.owner.sub.map(observed.contains) != true { stopCommand(command.id) }
    }

    /// Its turn runs, or it compacts (Kore's own compaction, the wheel's, /compact): the chat is
    /// at work, as its tab shows, until the Continue after it, if any, starts its turn.
    package var isBusy: Bool { status.isRunning || context.compacting }

    /// Starting the CLI again would end something: a turn, a background agent, or a command left
    /// live (a dev server, a port-forward, an armed scheduled job), which dies with its process.
    private var holdsCLI: Bool { isWorking || commands.summary.total > 0 }

    /// An explicit account switch closes old work even when a scheduled job or dead CLI
    /// cannot acknowledge Stop. Other credential refreshes wait for the next safe boundary.
    package func accountChanged() {
        cancelContinue()
        guard let backend else { return }
        backend.endRemoteForAccountChange()
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
        let epoch = engine.newWork()
        let previous = engine.sending
        previous?.cancel()
        transcriptView.sending(false)
        for id in waitingOrder.reversed() { dispatch(.queuedMessage(id: id, .dropped)) }
        engine.chain(after: previous, epoch) { [self] in
            await backend.relaunch(reason: "account changed")
            guard currentWork(epoch), !Task.isCancelled else { return }
            try? await backend.start()
        }
    }

    /// ⌘R's reload of this chat, held while a turn, an agent or a command runs.
    @ObservationIgnored private var reloadWhenFree: (@MainActor () -> Void)?

    /// Runs `reload` now if nothing live would die with the CLI, else once the last thing ends.
    /// Asked again while it waits, it runs at once: a chat stuck at work comes back too.
    package func whenFree(_ reload: @escaping @MainActor () -> Void) {
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
            services.refreshAccount(provider)
            relaunchIfDue()
        case .turnFinished, .agentFinished, .commandEnded:
            // An agent's end reaches the summary at the next draw: at once, when a start waits.
            if case .agentFinished = event, relaunchDue || reloadWhenFree != nil { transcriptView.drawNow() }
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
            // Its id goes on the agents' and the CLI's lines until it ends.
            let tally = TurnTally()
            turnTally = tally
            LogTurns.set(tally.id, chat: sessionId)
            startWatchdog()
        case .turnFinished(_, let outcome, let duration):
            endWatch()
            endTurnLine(Self.name(outcome), duration: duration)
        case .exited:
            endWatch()
            endTurnLine("exited", duration: nil)
        default:
            guard !Self.isReplay(event) else { return }
            turnTally?.count(event)
            // A new chat's id comes with its first turn: the turn's lines carry it from here.
            if case .sessionIdentified(let id) = event, let turnTally { LogTurns.set(turnTally.id, chat: id) }
            lastHeard = Date()
            if connection == .stalled {
                // It spoke again: the connection was fine after all.
                connection = .ok
                transcriptView.connected(.ok)
                SessionLog.shared.connection(provider.id, chat: sessionId, state: "ok")
            }
        }
    }

    /// The running turn's one line, as it ends (or its CLI does). The CLI's own measure of its
    /// length when it gives one.
    private func endTurnLine(_ outcome: String, duration: Duration?) {
        // A turn Kore never saw start still gets its line, as it ends.
        guard let tally = turnTally ?? (duration == nil && outcome == "exited" ? nil : TurnTally()) else { return }
        turnTally = nil
        LogTurns.set(nil, chat: sessionId)
        let ms = duration.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) }
            ?? Int(Date().timeIntervalSince(tally.started) * 1000)
        SessionLog.shared.turn(tally, provider.id, chat: sessionId, model: controls.modelId ?? launchModel, outcome: outcome, ms: ms)
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
        guard services.watchesStall, quiet > Self.stallAfter.value, services.isOnline, !waitingForNetwork,
            approvals.pending.isEmpty, !context.compacting, connection != .stalled else { return }
        // A command or agent still running is busy, not stalled, however long it stays quiet.
        guard !transcriptView.workRunning else { return }
        connection = .stalled
        transcriptView.connected(.stalled)
        SessionLog.shared.connection(provider.id, chat: sessionId, state: Self.name(.stalled), quiet: Int(quiet))
    }

    /// A stalled turn's Retry: its CLI ends and starts again on the same chat, which is asked
    /// to carry on.
    package func retryStalled() {
        guard !closed, !accountRestartPending, status.isRunning,
              connection == .stalled,
              approvals.pending.isEmpty, !context.compacting else { return }
        SessionLog.shared.rescue(provider.id, chat: sessionId, action: "retry")
        cancelContinue()
        restartCLI(reason: "stalled")
        deliver("Continue", [])
    }

    /// Resumes only the latest unfinished attempt, not a historical turn or the command's
    /// raw input. `deliver` leaves the user's unsent composer and attachments intact.
    package func retryTurn(_ id: String) {
        guard !closed, !accountRestartPending, !isBusy, approvals.pending.isEmpty,
              transcriptView.retryableTurn == id else { return }
        SessionLog.shared.rescue(provider.id, chat: sessionId, action: "retry-ended")
        restartCLI(reason: "retry ended")
        continueTurn()
    }

    /// A refused turn's "Retry on …": the chat takes the fallback model, then goes on. The CLI is
    /// fine (a refusal isn't a hang), so it stays; the message waits for the switch.
    package func retryOn(_ id: String, model option: ModelOption) {
        guard !closed, !accountRestartPending, !isBusy, approvals.pending.isEmpty,
              transcriptView.retryableTurn == id, let backend else { return }
        SessionLog.shared.rescue(provider.id, chat: sessionId, action: "retry-on")
        controls.modelId = option.id
        let level = EffortScale.fallback(controls.effort, offered: option.efforts, scale: controls.effortScale)
        if let level, level != controls.effort { setEffort(level) }
        Task {
            do {
                try await backend.setModel(option.id)
            } catch {
                return fail("Couldn't switch model: \(error)")
            }
            guard transcriptView.retryableTurn == id, !isBusy else { return }
            continueTurn()
        }
    }

    /// A refused turn's "Add context": its message back in the composer, a line saying what the
    /// work is before it, for the owner to read, change and send. A draft already there stays,
    /// after it.
    package func addContext(_ id: String) {
        let message = transcriptView.prompt(of: id) ?? ""
        draft = [Refusal.context, message, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Ends the CLI under a turn that won't end by itself and starts it again: the turn ends
    /// here, at once, and nothing waits for the send that hangs on it.
    private func restartCLI(reason: String, clearingWork: Bool = false) {
        guard !closed, let backend else { return }
        let clearingWork = clearingWork || accountRestartPending
        if clearingWork { accountRestartPending = true }
        let epoch = engine.newWork()
        relaunchDue = false
        engine.cancelSending()
        transcriptView.sending(false)
        waitingForNetwork = false
        // Messages queued in the old process die with it, unseen: back to the composer, at
        // once, as another account switch can cancel this task before it runs.
        for id in waitingOrder.reversed() { dispatch(.queuedMessage(id: id, .dropped)) }
        if status.isRunning { dispatch(.turnFinished(nil, .interrupted, duration: nil)) }
        status.setRunning(false)
        engine.chain(after: nil, epoch) { [self] in
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
                transcriptView.drawNow()
                for agent in transcriptView.runningAgents where !observed.contains(agent) {
                    dispatch(.agentFinished(id: agent, .stopped, result: nil))
                }
                context.end()
                dispatch(.exited(status: 0))
                transcriptView.drawNow()
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
        case .away: "away"
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
        networkObserver = NotificationCenter.default.addObserver(forName: services.networkChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status.isRunning, !self.waitingForNetwork else { return }
                self.dispatch(.connection(self.services.isOnline ? .ok : .offline))
            }
        }
    }

    package func close(reason: String = "tab closed") {
        onDraftChanged = nil
        if !closed, backend != nil { SessionLog.shared.closing(provider.id, chat: sessionId, reason: reason) }
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        networkObserver = nil
        closed = true
        engine.close()
        transcriptView.sending(false)
        waitingForNetwork = false
        endWatch()
        cancelContinue()
        engine.shutDown()
        services.closed(self)
    }

    // MARK: Composer

    /// A metadata-only snapshot: no trimming, command parsing, thumbnail reads or other IO.
    package var composerDraft: ChatDraft {
        ChatDraft(provider: provider.id, folder: folder, text: draft, command: command.map(ChatDraft.Command.init),
                  attachmentURLs: attachments.compactMap(\.url))
    }

    package func composerDraftChanged() {
        if !restoringComposerDraft { onDraftChanged?() }
    }

    /// Something to send. During a compaction it waits, shown queued, and goes as the compaction ends.
    package var canSend: Bool {
        !accountRestartPending
            && (command != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// What goes to the CLI: the command first, then the draft.
    package nonisolated static func message(command: SlashCommand?, draft: String) -> String {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command else { return text }
        return text.isEmpty ? "/\(command.name)" : "/\(command.name) \(text)"
    }

    /// A sent message as the composer holds it: a leading command among `commands` goes back to
    /// the chip, the rest to the draft.
    package nonisolated static func split(_ text: String, commands: [SlashCommand]) -> (command: SlashCommand?, draft: String) {
        guard text.hasPrefix("/") else { return (nil, text) }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let command = commands.first(where: { $0.kind == .command && $0.name == name }) else { return (nil, text) }
        return (command, String(text.dropFirst(1 + name.count).drop(while: \.isWhitespace)))
    }

    /// Puts a message back in the composer (a fork's), its command in the chip.
    package func restoreDraft(_ text: String, commands: [SlashCommand]) {
        (command, draft) = Self.split(text, commands: commands)
    }

    package func send() {
        guard !closed, !accountRestartPending else { return }
        let text = Self.message(command: command, draft: draft)
        let sent = attachments
        guard !text.isEmpty || !sent.isEmpty else { return }
        // Without a name the composer keeps the command, ready for the name: its chip, or
        // "/rename " with the caret after it.
        if let name = typedRename(text, files: !sent.isEmpty) {
            if !name.isEmpty {
                (draft, command) = ("", nil)
            } else if command == nil {
                draft = "/\(SlashCommand.rename.name) "
            } else {
                draft = ""
            }
            renameTyped(name)
            return
        }
        if sent.isEmpty, let typed = Self.typedControl(text) {
            (draft, command) = ("", nil)
            controlTyped(typed)
            return
        }
        // Sent during a compaction: it waits for it, shown queued (a typed /compact has nothing to add).
        if context.compacting {
            guard !sent.isEmpty || Self.compactCommand(text) == nil else { return }
            draft = ""
            command = nil
            attachments = []
            holdForCompaction(text, sent)
            return
        }
        // A typed /compact compacts as the context wheel does, shown as the user's message (the
        // CLI isn't sent it as one). It waits in the composer while it can't (a turn running, no
        // session yet).
        if sent.isEmpty, let instructions = Self.compactCommand(text) {
            guard canCompact else { return }
            draft = ""
            command = nil
            showCompactRow(text)
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

    /// A message from outside the composer (the local link): sent as the composer's would be,
    /// queued while a turn runs, without touching the draft or its attachments on the Mac.
    /// False when it can't go now (a compaction, an account switch, a chat closed).
    /// `note`: a line its agent reads with this message only (`noteNextTurn`), never shown: an
    /// Arsenal ask's how-to-answer. `done`: once the CLI has it (whether a turn is under way), or
    /// why it didn't go (the CLI didn't start, the chat closed first); a message held for a
    /// compaction, or a /compact, is done at once.
    @discardableResult
    package func sendFromLink(
        _ text: String, files: [URL] = [], note: String? = nil, done: (@MainActor (Result<Bool, Error>) -> Void)? = nil
    ) -> Bool {
        guard !closed, !accountRestartPending else { return false }
        if let name = typedRename(text, files: !files.isEmpty) {
            renameTyped(name)
            done?(.success(false))
            return true
        }
        if files.isEmpty, let typed = Self.typedControl(text) {
            controlTyped(typed)
            done?(.success(false))
            return true
        }
        let sent = services.attachments(files)
        // During a compaction a phone's message waits for it, shown queued, as the composer's does.
        if context.compacting {
            guard !sent.isEmpty || Self.compactCommand(text) == nil else { return false }
            holdForCompaction(text, sent)
            done?(.success(true))
            return true
        }
        if sent.isEmpty, let instructions = Self.compactCommand(text) {
            guard canCompact else { return false }
            showCompactRow(text)
            compact(instructions: instructions)
            done?(.success(true))
            return true
        }
        cancelContinue()
        deliver(text, sent, note: note, done: done)
        return true
    }

    /// A message another Kore's chat sent through this one (a Mac driving a box's chat): it goes
    /// as that chat sent it, under its id and queued as it was, and `done` says whether a turn is
    /// under way once the CLI has it, or why it didn't go.
    package func sendForwarded(
        _ text: String, files: [URL], queued: String?, id: String?, done: @escaping @MainActor (Result<Bool, Error>) -> Void
    ) {
        guard !closed, !accountRestartPending else { return done(.failure(CallRefusal("The chat can't take a message right now."))) }
        cancelContinue()
        deliver(text, services.attachments(files), id: id, queued: .some(queued), done: done)
    }

    /// A typed /compact shows as the user's message (the CLI isn't sent it as one); a backend
    /// whose history lives elsewhere (a box's) keeps the row there too.
    private func showCompactRow(_ text: String) {
        let id = UUID().uuidString.lowercased()
        let message = ChatEvent.userMessage(text: text, attachments: [], id: id)
        if awaitingHistory { hold(message) } else { dispatch(message) }
        let backend = connect()
        Task { await backend.keepRow(text, id: id) }
    }

    /// A row another Kore's chat showed of its own (a Mac's typed /compact in a box's chat): this
    /// chat shows it too.
    package func showSent(_ text: String, id: String) {
        let message = ChatEvent.userMessage(text: text, attachments: [], id: id)
        if awaitingHistory { hold(message) } else { dispatch(message) }
    }

    /// Messages waiting while a turn runs.
    package var queuedCount: Int { waitingOrder.count }

    /// Sends a message the composer has given up (or Kore's own "Continue").
    private func deliver(
        _ text: String, _ sent: [Attachment], id given: String? = nil, queued forced: String?? = nil, note: String? = nil,
        done: (@MainActor (Result<Bool, Error>) -> Void)? = nil
    ) {
        let done = done.map(CallOnce.init)
        guard !closed, !accountRestartPending else {
            done?(.failure(CallRefusal("The chat can't take a message right now.")))
            return
        }
        // A rollback under way: the CLI it would reach is ending, and the rows are about to be
        // replaced. It goes once the rollback is done (`endRollback`), under the id and queued
        // state it was sent with: its sender knows its row by that id.
        if rollingBack {
            heldForRollback.append(HeldMessage(text: text, files: sent, id: given, queued: forced, note: note))
            transcriptView.sending(true)
            done?(.success(true))
            return
        }
        interruptedByAccount = false
        relaunchIfDue()
        let epoch = workEpoch
        if networkObserver == nil { watchNetwork() }
        // The Codex extension's /plan flips the plan toggle; it isn't a message.
        if text == "/plan" && sent.isEmpty && provider.planToggle != nil {
            setPlanMode(!controls.planMode)
            done?(.success(false))
            return
        }
        approvals.offerImplementPlan = false
        // Sent while a turn runs, it waits (look.md §10) until the CLI says where it went. Its id
        // is its row's too: the CLI keeps it (or its backend maps it), so a fork or a rollback
        // finds this very message, not another with the same text.
        let id = given ?? UUID().uuidString.lowercased()
        let queued = forced ?? (status.isRunning ? id : nil)
        let shown = sent.map(SentAttachment.init)
        let message: ChatEvent =
            queued.map { .messageQueued(id: $0, text: text, attachments: shown) }
            ?? .userMessage(text: text, attachments: shown, id: id)
        if let queued {
            waiting[queued] = (text, sent)
            waitingOrder.append(queued)
        }
        if awaitingHistory { hold(message) } else { dispatch(message) }
        status.setRunning(true)
        if queued == nil { transcriptView.sending(true) }
        startWatchdog()
        let backend = connect()
        engine.chain(after: engine.sending, epoch) { [self] in
            do {
                if let error = await launchCLI() {
                    done?(.failure(error))
                    guard currentWork(epoch), !Task.isCancelled else { return }
                    // Never sent: the message goes back to the composer, for a send that tries again.
                    if let queued {
                        dispatch(.queuedMessage(id: queued, .dropped))
                    } else {
                        transcriptView.sending(false)
                        status.setRunning(false)
                        giveBackToComposer(text, sent, id: id)
                    }
                    fail("Not sent: \(provider.name) didn't start (\(Self.reason(error))). The message is back in the composer.")
                    return
                }
                guard currentWork(epoch), !Task.isCancelled else { return }
                if queued == nil, !services.isOnline {
                    dispatch(.notice("Offline: this sends when the network is back"))
                    waitingForNetwork = true
                    await services.online()
                    guard currentWork(epoch) else { return }
                    waitingForNetwork = false
                    if Task.isCancelled {
                        status.setRunning(false)
                        dispatch(.notice("Not sent: stopped while offline"))
                        return
                    }
                }
                guard currentWork(epoch), !Task.isCancelled else { return }
                // Arsenal changed since the agent was last told: this message carries a line saying so,
                // with the message's own note after it.
                var notes = note.map { [$0] } ?? []
                if services.agentTools, arsenal != arsenalTold {
                    arsenalTold = arsenal
                    notes.insert(KoreReach.note(tier: arsenal?.title, chat: String(self.id.uuidString.prefix(8)).lowercased()), at: 0)
                }
                if !notes.isEmpty { backend.noteNextTurn(notes.joined(separator: "\n")) }
                let turn = try await backend.send(text, files: Attachments.files(sent), queued: queued, id: id)
                done?(.success(turn))
                // A fork's CLI has its session once a message went out, not when it was shown.
                if let key = fork?.id { KoreForks.shared.sent(cli: provider.id, key: key) }
                guard currentWork(epoch), !Task.isCancelled else { return }
                if !turn, queued == nil {
                    transcriptView.sending(false)
                    status.setRunning(false)
                }
            } catch {
                done?(.failure(error))
                guard currentWork(epoch), !Task.isCancelled else { return }
                // A message that couldn't go goes back to the composer, with its files.
                if let queued {
                    dispatch(.queuedMessage(id: queued, .dropped))
                    fail(Self.reason(error))
                } else {
                    transcriptView.sending(false)
                    status.setRunning(false)
                    giveBackToComposer(text, sent, id: id)
                    fail("Not sent: \(Self.reason(error)). The message is back in the composer.")
                }
            }
        }
    }

    // MARK: Stay awake

    /// What this chat keeps awake for: its turn, and its running agents and Codex child threads.
    package var awakeWork: Int {
        guard !closed else { return 0 }
        return (isBusy ? 1 : 0) + transcriptView.runningAgents.count
    }

    /// Sends "Continue": a slept turn's Continue, and the continuation at a limit's reset.
    package func continueTurn() {
        cancelContinue()
        deliver("Continue", [])
    }

    /// The × after "Continues at …", Stay awake turned off, or the owner sending. A message set
    /// to go at the reset comes back to the composer when it's empty.
    package func cancelContinue() {
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
    package var canSendAtReset: Bool {
        limitReset != nil && sendsAtReset == nil && !status.isRunning && !context.compacting && canSend
    }

    /// The composer's ring: the draft goes when the limit resets, Stay awake on until then.
    package func sendAtReset() {
        guard canSendAtReset, let reset = limitReset else { return }
        sendsAtReset = (command, draft, attachments, Date())
        draft = ""
        command = nil
        attachments = []
        if services.stayAwakeForReset() { awakeForReset = true }
        continuation.schedule(turn: reset.turn, at: reset.at)
        // Already waiting there to send Continue: the row says the message now.
        showContinuation(continuation.pending)
    }

    /// Stay awake goes off again if it was turned on for the message, unless another chat waits
    /// on it.
    private func releaseAwakeForReset() {
        guard awakeForReset else { return }
        awakeForReset = false
        services.releaseAwake(besides: self)
    }

    private func makeContinuation() -> LimitContinuation {
        let continuation = LimitContinuation(clock: services.awakeClock ?? SystemClock())
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
        transcriptView.continues(turn: pending?.turn, at: pending?.at, sends: pending == nil ? nil : message)
    }

    /// A turn that ended on the plan's limit continues at the reset, while Stay awake is on.
    private func continueAfterLimit(_ event: ChatEvent) {
        noteLimitReset(event)
        guard case .turnFinished(let id, .limited(_, let resetsAt), _) = event,
            services.stayingAwake, let turn = id ?? turnBegan?.id
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
            if let began, id == nil || id == began.id, services.sleptThrough(since: began.at) {
                return .turnFinished(id, .slept(said), duration: duration)
            }
        case .turnFinished, .exited:
            turnBegan = nil
        default:
            break
        }
        return event
    }

    /// A compaction the user stopped ends as stopped, whatever the CLI calls its end.
    private func stoppedCompaction(_ event: ChatEvent) -> ChatEvent {
        switch event {
        case .compactionFailed where stoppingCompaction:
            stoppingCompaction = false
            return .compactionStopped
        case .compacted, .compactionFailed, .compactionStopped, .exited:
            // Done before the Stop reached it: it stands, as any finished compaction does.
            stoppingCompaction = false
        default:
            break
        }
        return event
    }

    // MARK: Actions

    /// Stops the turn, or the compaction (the wheel's, /compact, Kore's own, or one the CLI
    /// started by itself): both CLIs cancel a compaction as they stop a turn. Claude's
    /// `interrupt` aborts the controller its compaction runs on: it says `compact_result`
    /// "failed", writes no `compact_boundary`, and keeps the conversation as it was. Codex runs
    /// a compaction as a turn (`thread/compact/start`, or within the user's): `turn/interrupt`
    /// ends it "interrupted" before its history is replaced. With nothing at work (the
    /// compaction finished as Stop was pressed) it does nothing.
    package func stop() {
        guard isBusy || waitingForNetwork || transcriptView.pendingSendSince != nil else { return }
        if context.compacting { stoppingCompaction = true }
        if transcriptView.pendingSendSince != nil {
            engine.cancelSending()
            transcriptView.sending(false)
        }
        // Not sent yet: there's no turn to interrupt, only the wait.
        if waitingForNetwork {
            // The cancelled network wait clears running and records why nothing was sent.
            // Keep that transition together so observers cannot see idle before the notice.
            engine.cancelSending()
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
            guard let self, !Task.isCancelled, self.currentWork(epoch), self.isBusy, self.turnSerial == serial else { return }
            SessionLog.shared.rescue(self.provider.id, chat: self.sessionId, action: "stop-unanswered")
            self.restartCLI(reason: "stop unanswered")
            // A compaction no turn shows ends with its process, unfinished.
            if self.context.compacting { self.dispatch(.compactionStopped) }
        }
    }

    /// The context wheel's click (look §9): compacts at once, between turns only.
    package var canCompact: Bool { status.sessionId != nil && !status.isRunning && !context.compacting && !rollingBack }

    /// `instructions`: what the summary should keep (`/compact <instructions>`); empty for none.
    /// The transcript's live row shows from here, before the CLI says it started. `point`: Kore
    /// compacts by itself, at the chat's auto-compact point.
    package func compact(instructions: String = "", at point: Int? = nil) {
        guard canCompact else { return }
        autoCompactDue = false
        stoppingCompaction = false
        // Kore's own, after a turn that ran to its end: the work goes on after it.
        continueAfterCompaction = point != nil && lastTurnCompleted
        context.begin()
        transcriptView.compacting(true, at: point)
        let backend = connect()
        Task {
            do {
                try await backend.start()
            } catch {
                // The CLI didn't start: no compaction was asked of it, so it's said as any start's.
                context.end()
                transcriptView.compacting(false)
                stoppingCompaction = false
                fail(Self.reason(error))
                sendHeldAfterCompaction()
                return
            }
            // Stopped while the CLI started: it's never asked.
            guard !stoppingCompaction else {
                dispatch(.compactionStopped)
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
    package func setAutoCompact(_ point: Int?) {
        guard context.autoCompactAt != point || !ownAutoCompact else { return }
        context.autoCompactAt = point
        ownAutoCompact = true
        settingsChangedAt = Date()
        if let id = sessionId { compactMemory.remember(point, chat: id) }
        backend?.keepAutoCompact(point)
    }

    /// A fork starts at its original's point, and keeps it as its own when the original had one.
    package func inheritAutoCompact(from original: Chat) {
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
            compactAfterTurn = false
        case .compactionFailed, .compactionStopped, .exited:
            autoCompactDue = false
            if case .exited = event { compactAfterTurn = false }
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
            if compactAfterTurn, waiting.isEmpty {
                compactAfterTurn = false
                if canCompact { return compact() }
            }
            guard automatic else { return }
            if autoCompactDue, context.pastPoint, canCompact, waiting.isEmpty, let point = context.autoCompactAt {
                compact(at: point)
            } else if stoppedByCompaction, waiting.isEmpty {
                continueSent = true
                deliver("Continue", [])
            }
        case .contextUsage:
            guard automatic, autoCompactDue, context.pastPoint, canCompact, waiting.isEmpty, let point = context.autoCompactAt
            else { return }
            compact(at: point)
        default:
            break
        }
    }

    private func sendContinueAfterCompaction() {
        continueAfterCompaction = false
        guard waiting.isEmpty, automatic else { return }
        continueSent = true
        deliver("Continue", [])
    }

    /// The instructions of a typed `/compact` (empty when it has none); nil for anything else.
    package nonisolated static func compactCommand(_ text: String) -> String? {
        let command = "/compact"
        guard text.hasPrefix(command), text.dropFirst(command.count).first.map(\.isWhitespace) ?? true else { return nil }
        return text.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An error as the chat says it: its own readable text (Codex's message, parsed), else its
    /// description. Never Foundation's "The operation couldn't be completed".
    package static func reason(_ error: Error) -> String {
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        // Foundation's own errors have their sentence; Kore's and the CLIs' say themselves.
        return type(of: error) is NSError.Type ? error.localizedDescription : String(describing: error)
    }

    /// Loads a sub-agent's own transcript the first time it's opened, when the chat doesn't have
    /// it (a replayed chat's agents, Codex children).
    package func loadAgentIfNeeded(_ id: String) {
        transcriptView.keepLane(of: id)
        guard transcriptView.needsHistory(id) else { return }
        let backend = connect()
        Task {
            try? await backend.start()
            let events = await backend.agentHistory(id)
            if !events.isEmpty { transcriptView.replaceLane(of: id, with: events) }
        }
    }

    /// Where a fork from this user message starts (`ChatBackend.fork`); nil after a failure,
    /// which shows as "Couldn't fork: …" in this chat.
    package func forkStart(_ entry: TranscriptLog.Entry) async -> ForkStart? {
        do {
            return try await connect().fork(message: entry.source, text: entry.text)
        } catch {
            fail("Couldn't fork: \(error.localizedDescription)")
            return nil
        }
    }

    /// The user message that starts the turn after this answer.
    private func nextMessage(after answer: TranscriptLog.Entry) -> TranscriptLog.Entry? {
        let entries = transcriptView.entries
        return entries.firstIndex { $0.id == answer.id }.flatMap { index in
            // A message taken into a running turn isn't a new turn: cutting there would cut it in half.
            entries[(index + 1)...].first { ($0.kind == .user || $0.kind == .peer) && !$0.inTurn }
        }
    }

    /// A rollback under way (`rollBack(to:)`).
    @ObservationIgnored private var rollingBack = false
    /// Messages sent while it runs, in order: they go once it's done.
    @ObservationIgnored private var heldForRollback: [HeldMessage] = []
    private struct HeldMessage {
        var text: String
        var files: [Attachment]
        var id: String?
        var queued: String??
        var note: String?
    }

    /// A rollback is under way: another is refused until it ends.
    package var isRollingBack: Bool { rollingBack }
    package static let rollbackUnderway = "A rollback is already under way."
    package static let rollbackBusy = "A turn is running. Stop it, then go back."
    /// Sent while a compaction ran, in order: they go as it ends and no turn runs.
    @ObservationIgnored private var heldForCompaction: [(id: String, text: String, files: [Attachment])] = []

    /// A message sent during a compaction: it waits, shown queued, and goes as the compaction ends.
    private func holdForCompaction(_ text: String, _ sent: [Attachment]) {
        cancelContinue()
        // The owner said something: it goes instead of Kore's own "Continue".
        continueAfterCompaction = false
        let id = UUID().uuidString.lowercased()
        heldForCompaction.append((id, text, sent))
        let message = ChatEvent.messageQueued(id: id, text: text, attachments: sent.map(SentAttachment.init))
        if awaitingHistory { hold(message) } else { dispatch(message) }
    }

    /// Messages sent during a compaction waiting for it to end.
    package var heldForCompactionCount: Int { heldForCompaction.count }

    /// The compaction is over (done, failed, stopped, or its CLI ended) and no turn runs: what was
    /// sent meanwhile goes now, under the ids its queued rows showed. A chat that can't take it
    /// (closed, an account switch) gives it back to the composer.
    private func sendHeldAfterCompaction(_ event: ChatEvent? = nil) {
        guard !heldForCompaction.isEmpty, !context.compacting, !status.isRunning else { return }
        if let event {
            switch event {
            case .compacted, .compactionFailed, .compactionStopped, .exited, .turnFinished: break
            default: return
            }
        }
        let held = heldForCompaction
        heldForCompaction = []
        for message in held { dispatch(.queuedMessage(id: message.id, .dropped)) }
        if closed || accountRestartPending {
            for message in held.reversed() { giveBackToComposer(message.text, message.files, id: message.id) }
            return
        }
        for message in held { deliver(message.text, message.files, id: message.id) }
    }

    /// Takes this chat back to before a user message: it and everything after it go, and it
    /// returns to the composer, with its files. A peer's message goes the same way, but its words
    /// aren't the owner's to send again. Files on disk stay as they are.
    package func rollBack(_ entry: TranscriptLog.Entry) { rollBack(to: entry, giveBack: entry.kind == .user) }

    /// Takes this chat back to this answer: what came after its turn goes.
    package func rollBack(after answer: TranscriptLog.Entry) {
        if let next = nextMessage(after: answer) { rollBack(to: next, giveBack: false) }
    }

    private func rollBack(to entry: TranscriptLog.Entry, giveBack: Bool) {
        // One at a time: a second one started meanwhile would cut the CLI at its own message while
        // the first one's rows replaced the transcript, so the two would disagree.
        guard !rollingBack, !closed else { return }
        // A message taken into a running turn isn't a turn's start: cutting there would cut the
        // turn in half (Claude), or take the whole turn (Codex).
        guard entry.kind == .peer || (entry.kind == .user && !entry.inTurn) else { return }
        let files = transcriptView.chips(entry)
        rollingBack = true
        Task {
            // A running turn ends first, as Stop ends it (at most 5 s: `stopFallback`).
            stop()
            for _ in 0..<60 where isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            guard !isBusy else {
                endRollback()
                dispatch(.notice("Couldn't roll back: the turn is still stopping. Try again once it has.", isError: true))
                return
            }
            do {
                _ = try await cutBack(message: entry.source, text: entry.text)
                dispatch(.notice("Rolled back. Files not changed."))
                if giveBack { giveBackToComposer(entry.text, services.reattach(files)) }
            } catch {
                fail("Couldn't roll back: \(Self.reason(error))")
            }
            endRollback()
        }
    }

    /// A rollback another Kore's chat asked through this one (a Mac's, holding a box's chat): the
    /// same one-at-a-time path as this chat's own, so what's sent meanwhile (a phone's message)
    /// waits for it and goes after its rows. Refused while a turn runs (the Mac ends its turn
    /// first) or another rollback is under way; the history left is the caller's too.
    package func rollBackForwarded(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        guard !closed else { throw CallRefusal("The chat can't roll back right now.") }
        guard !rollingBack else { throw CallRefusal(Self.rollbackUnderway) }
        guard !isBusy else { throw CallRefusal(Self.rollbackBusy) }
        rollingBack = true
        defer { endRollback() }
        try await connect().start()
        return try await cutBack(message: id, text: text)
    }

    /// The CLI cut back at a message and its history adopted: only inside a rollback
    /// (`rollingBack`), which holds what's sent meanwhile.
    private func cutBack(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        let left = try await connect().rollback(message: id, text: text)
        adoptRollback(left.events, more: left.more)
        return left
    }

    /// The one way a rollback's history comes in: this chat's own, or one another Kore's chat
    /// made through this one's backend (a Mac driving a box's chat). The history left replaces
    /// this one's as a `historyReplaced` the taps see, and the services follow the cut (a box
    /// starts its log again, so every follower takes it; a Mac holding a box's chat sends it
    /// back whole).
    package func adoptRollback(_ events: [ChatEvent], more: Bool) {
        sinceReplay = []
        dispatch(.historyReplaced(events))
        dispatch(.earlierHistory(more))
        services.rolledBack(self, to: events, more: more)
    }

    /// The CLI cleared the conversation (Claude's /clear): a fresh transcript on its new session,
    /// as a rollback to nothing is. The old session stays in History. A box starts its log again
    /// (`ChatServices.rolledBack`), then logs the new id, so every follower takes both.
    private func resetConversation(to id: String) {
        sinceReplay = []
        dispatch(.historyReplaced([]))
        dispatch(.earlierHistory(false))
        services.rolledBack(self, to: [], more: false)
        dispatch(.sessionIdentified(id))
    }

    /// The rollback is over, done or not: what was sent meanwhile goes now, after its rows.
    private func endRollback() {
        rollingBack = false
        let held = heldForRollback
        heldForRollback = []
        if !held.isEmpty, transcriptView.pendingSendSince != nil { transcriptView.sending(false) }
        for message in held { deliver(message.text, message.files, id: message.id, queued: message.queued, note: message.note) }
    }

    /// Where a fork from an answer starts: through that answer's turn. That's the history before
    /// the next user message, or the whole conversation when the answer is in the last turn.
    package func forkStart(after answer: TranscriptLog.Entry) async -> ForkStart? {
        let next = nextMessage(after: answer)
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
        guard case .earlierHistory(true) = event, transcriptView.userTurns < 10 else { return }
        loadEarlierConversation()
    }

    @ObservationIgnored private var unloading = false

    /// The turns before the newest `TranscriptStore.keptTurns` leave memory, once its history has
    /// said it can give them back: when the chat goes out of sight or a turn ends out of sight, and
    /// as it opens (`opening`), the rows it hasn't built. An imported chat's carried rows are in
    /// no history.
    package func unloadOld(opening: Bool = false) {
        guard !unloading, !closed, !rollingBack, !isBusy, !awaitingHistory, sinceReplay == nil, imported == nil, waitingOrder.isEmpty,
            let backend, let first = transcriptView.unloadPoint(opening: opening)
        else { return }
        unloading = true
        let store = transcriptView
        Task {
            defer { unloading = false }
            // Things may have moved on while the history was read.
            guard let point = await backend.unloadPoint(message: first.source, text: first.text), backend === self.backend, store === transcriptView,
                !closed, !rollingBack, !isBusy, store.unloadPoint(opening: opening)?.id == first.id
            else { return }
            backend.unloaded(to: point.earlier)
            store.unload(before: first.id, earlier: point.messages)
        }
    }

    /// The conversation before a compaction, ten turns at a time.
    package func loadEarlierConversation() {
        guard transcriptView.earlierAvailable, !transcriptView.loadingEarlier else { return }
        transcriptView.startLoadingEarlier()
        let backend = connect()
        Task {
            let page = await backend.earlier()
            // Not read (its CLI didn't start): what left memory is still there to ask for.
            transcriptView.prepend(page?.events ?? [], more: page?.more ?? transcriptView.mayHaveLeft)
        }
    }

    /// The message scroller's jump: as far back as `turns` turns, in one page.
    package func loadEarlier(turns: Int) async {
        guard transcriptView.earlierAvailable, !transcriptView.loadingEarlier else { return }
        transcriptView.startLoadingEarlier()
        let page = await connect().earlier(turns: turns)
        transcriptView.prepend(page?.events ?? [], more: page?.more ?? transcriptView.mayHaveLeft)
    }

    /// The user's messages not loaded yet, for the message scroller.
    package func readEarlierMessages() async {
        guard transcriptView.earlierAvailable else {
            transcriptView.earlierMessages([])
            return
        }
        transcriptView.earlierMessages(await connect().earlierMessages())
    }

    /// Dev hook (`KORE_QUEUE`): sends `text` the way a message sent mid-turn goes, with an id
    /// for `.queuedMessage`, until the composer queues (look.md §10).
    /// KORE_QUEUE: sends as the composer does (queued, since a turn runs).
    package func devQueue(_ text: String) {
        draft = text
        send()
    }

    /// A queued message dropped by Stop: its text and files go back to the composer.
    private func restoreQueued(_ event: ChatEvent) {
        guard case .queuedMessage(let id, let delivery) = event, let message = waiting.removeValue(forKey: id) else { return }
        waitingOrder.removeAll { $0 == id }
        guard delivery == .dropped else { return }
        giveBackToComposer(message.text, message.files, id: id)
    }

    /// Its CLI ends with messages still waiting (a box's chat put to sleep, closed or moved): each
    /// is dropped, back to its composer, as a CLI starting again drops them.
    package func dropQueued() {
        for id in waitingOrder.reversed() { dispatch(.queuedMessage(id: id, .dropped)) }
        let held = heldForCompaction
        heldForCompaction = []
        for message in held.reversed() {
            dispatch(.queuedMessage(id: message.id, .dropped))
            giveBackToComposer(message.text, message.files, id: message.id)
        }
    }

    /// A message back in the composer (one Stop dropped, one rolled back): as it was sent when
    /// the composer is empty, its command in the chip; otherwise ahead of what's there, which
    /// stays.
    private func giveBackToComposer(_ text: String, _ files: [Attachment], id: String? = nil) {
        if let returnsToComposer, returnsToComposer(id, text) { return }
        if command == nil, draft.isEmpty {
            restoreDraft(text, commands: controls.commands)
        } else if !text.isEmpty {
            draft = draft.isEmpty ? text : text + "\n" + draft
        }
        attachments = files + attachments
    }

    // MARK: Commands

    /// Stop on a command's row, confirmed: the row says "stopped" when the CLI does.
    package func stopCommand(_ id: String) {
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
    package func stopAllCommands() {
        for command in commands.stoppable { stopCommand(command.id) }
    }

    /// A long foreground command's Run in background: the same row runs on.
    package func runInBackground(_ id: String) {
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
    package func commandTail(_ id: String, lines: Int = 40) async -> OutputTail? {
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
    package func watchCommands(_ closely: Bool) {
        let backend = backend
        Task { await backend?.watchCommands(closely) }
    }

    package func stopAgent(_ id: String) {
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
        controls.changedBy = agent.sub.flatMap { transcriptView.agent($0)?.name } ?? provider.name
        controls.agentChangeSeq &+= 1
    }

    /// `remember`: the user picked it, so new chats start in it. Picks reach the CLI one at a
    /// time, in order: one made while another is under way (Full access starting the CLI again)
    /// waits for it, and only the latest of those waiting goes. The pill and the remembered mode
    /// end on the mode the CLI is in.
    package func setMode(_ id: String, remember: Bool = true) {
        controls.changedBy = nil
        settingsChangedAt = Date()
        if modeInEffect == nil { modeInEffect = controls.mode }
        controls.mode = id
        arsenalFollowMode()
        allowWaitingInPlan()
        modePicks &+= 1
        let pick = modePicks
        let before = modeChanging
        let backend = backend
        modeChanging = Task { [weak self] in
            await before?.value
            // A later pick replaces this one before it reached the CLI.
            guard let self, pick == self.modePicks else { return }
            do {
                try await backend?.setMode(id)
                self.modeInEffect = id
                if remember { self.controls.remember(id) }
            } catch {
                if pick == self.modePicks, let back = self.modeInEffect { self.controls.mode = back }
                self.fail("Couldn't switch mode: \(error)")
            }
            if pick == self.modePicks {
                self.modeInEffect = nil
                self.modeChanging = nil
            }
        }
    }

    /// The mode changes on their way to the CLI, one after another (`setMode`).
    @ObservationIgnored private var modeChanging: Task<Void, Never>?
    /// Counts picks: a change goes only while it's the latest.
    @ObservationIgnored private var modePicks = 0
    /// The mode the CLI was last known to be in while picks wait: the pill goes back to it if the
    /// latest fails.
    @ObservationIgnored private var modeInEffect: String?

    /// Until every mode pick made so far has reached the CLI.
    package func modeSettled() async {
        while let changing = modeChanging { await changing.value }
    }

    /// A quiet line of Kore's own in the transcript.
    package func note(_ text: String) { dispatch(.notice(text)) }

    /// A mode that can't reach Kore ends its Arsenal; one that can brings back a kept tier waiting for it.
    private func arsenalFollowMode() {
        if arsenal != nil || arsenalWaiting { services.arsenalFollowMode(self) }
    }

    package func setPlanMode(_ on: Bool) {
        controls.changedBy = nil
        settingsChangedAt = Date()
        controls.planMode = on
        let backend = backend
        Task { await backend?.setPlanMode(on) }
        allowWaitingInPlan()
    }

    /// "Allow commands in Plan", kept for this chat: where it runs when that's elsewhere (a box).
    package func setPlanAllow(_ on: Bool) {
        controls.planAllow = on
        settingsChangedAt = Date()
        services.log("plan-allow", ["cli": provider.id, "chat": status.sessionId, "on": on ? "yes" : "no"])
        if let backend, backend.keepsPlanAllow { return backend.keepPlanAllow(on) }
        if let id = status.sessionId { controls.keepPlanAllow(chat: id) }
        allowWaitingInPlan()
    }

    /// Permissions already waiting when planning with the switch on starts: answered as later ones are.
    private func allowWaitingInPlan() {
        for ask in approvals.pending where autoAllows(ask) { autoAllow(ask) }
    }

    /// This chat answers it itself (the switch is its own, not a box's).
    private func autoAllows(_ ask: Approval) -> Bool { controls.autoAllows(ask) && !(backend?.keepsPlanAllow ?? false) }

    /// Allowed with no card; the card's end is the chat's own word.
    private func autoAllow(_ ask: Approval) {
        answer(ask, .allow)
        ownTap?(.approvalWithdrawn(ask.id))
    }

    /// The CLI's model list: the one its session started with goes to its other chats, and a
    /// turn's end may read it again (`ModelCatalog`, throttled per CLI).
    private func noteModelList(_ event: ChatEvent) {
        switch event {
        case .controlsLoaded(let loaded):
            ModelCatalog.shared.started(self, cli: modelCLI, models: loaded.models)
        case .turnFinished:
            guard let backend else { return }
            ModelCatalog.shared.turnEnded(self, cli: modelCLI) { [weak backend] in await backend?.listModels() }
        default: break
        }
    }

    /// A new chat's mode (the one last picked) that its model doesn't offer gives way to the first.
    private func dropUnofferedMode(_ event: ChatEvent) {
        guard case .controlsLoaded = event, resume == nil, !controls.modeOffered else { return }
        setMode(provider.modes[0].id, remember: false)
    }

    /// Shift+Tab, as in each CLI.
    package func cycleMode() {
        switch provider.nextMode(controls.mode, controls.planMode, controls.availableModes) {
        case .mode(let next): setMode(next)
        case .togglePlan: setPlanMode(!controls.planMode)
        }
    }

    /// Codex CLI's "Yes, implement this plan": switch plan off and start coding.
    package func implementPlan() {
        setPlanMode(false)
        draft = "Implement the plan."
        send()
    }

    package func stayInPlanMode() {
        approvals.offerImplementPlan = false
    }

    /// A model without the current effort takes its nearest level below (the picker's thumb
    /// slides down to it).
    package func setModel(_ option: ModelOption) {
        controls.modelId = option.id
        settingsChangedAt = Date()
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

    package func setEffort(_ level: String) {
        controls.effort = level
        settingsChangedAt = Date()
        let backend = backend
        Task { await backend?.setEffort(level) }
    }

    /// The CLI's report follows and has the last word; one it refused puts the switch back.
    package func setFastMode(_ on: Bool) {
        guard controls.fastModeEnabled, let backend else { return }
        let previous = controls.fastMode
        settingsChangedAt = Date()
        controls.fastChanging = true
        controls.fastMode = on
        services.log("fast-mode", ["cli": provider.id, "chat": status.sessionId, "on": on ? "yes" : "no"])
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

    /// `/` → Remote control, or the mark's click: the CLI's own remote control of this chat.
    package func setRemoteControl(_ on: Bool) {
        guard !controls.remoteChanging, !on || controls.remoteUnavailable == nil else { return }
        controls.remoteChanging = true
        services.log("remote-control", ["cli": provider.id, "chat": status.sessionId, "on": on ? "yes" : "no"])
        let backend = connect()
        Task {
            defer { controls.remoteChanging = false }
            do {
                try await backend.setRemoteControl(on)
            } catch {
                fail("Couldn't turn \(on ? "on" : "off") remote control: \(error.localizedDescription)")
            }
        }
    }

    package func answer(_ approval: Approval, _ decision: Decision) {
        if approval.held != nil { return answerHeld(approval, allow: !Self.denies(decision), by: nil) }
        // Allow dim with a reason (a call Auto never runs): nothing, and the card stays.
        if approval.allowNote != nil, !Self.denies(decision) { return }
        if case .allowAlways = decision { alwaysAllowed = true }
        approvals.remove(approval.id)
        transcriptView.approvalSettled(approval.id)
        if case .deny = decision { transcriptView.actionDenied() }
        let backend = backend
        // Codex's one retry of a denied action, and a "Claude stopped" card's Run once or Always
        // allow: recorded first, then, if nothing's running, the agent is asked to go on (a running
        // turn sees the approval itself).
        if let retry = approval.retryMessage, Self.retries(approval, decision), backend?.followsUpThere != true {
            Task {
                await backend?.respond(to: approval.id, decision)
                if !self.status.isRunning { self.sendFromLink(retry) }
            }
            return
        }
        Task { await backend?.respond(to: approval.id, decision) }
    }

    /// The held-messages card answered: Allow lets them in, Deny refuses them; `by` the chat that
    /// did, when not the user. Not a turn's action: nothing in the turn is marked denied.
    package func answerHeld(_ approval: Approval, allow: Bool, by: String?) {
        // A hold no flag can lift: only Deny does anything, and the card stays.
        if allow, approval.allowNote != nil { return }
        approvals.remove(approval.id)
        transcriptView.approvalSettled(approval.id)
        let backend = backend
        Task { await backend?.answerHeld(allow: allow, by: by) }
    }

    private static func retries(_ approval: Approval, _ decision: Decision) -> Bool {
        if case .allow = decision { return true }
        if case .allowAlways = decision { return approval.id.hasPrefix(ClaudeAutoStops.idPrefix) }
        return false
    }

    private static func denies(_ decision: Decision) -> Bool {
        if case .deny = decision { return true }
        return false
    }

    /// This chat's address as other Claude sessions see it, while its CLI runs.
    package var peerAddress: String? { backend?.peerAddress }
}

extension SentAttachment {
    /// A composer attachment as the transcript shows it; the transcript reads it from `url`.
    package init(_ attachment: Attachment) {
        let image: Data? = nil
        self.init(name: attachment.name, kind: attachment.kind, url: attachment.url, image: image)
    }
}

extension Chat: ModelListHolder {
    /// The CLI's id, with the box's for a chat on one: lists from different machines never mix.
    package var modelCLI: String { services.modelScope.map { provider.id + "@" + $0 } ?? provider.id }
    package func listModels(_ models: [ModelOption]) { controls.listModels(models) }
}

/// Why a forwarded message didn't go, in a line.
package struct CallRefusal: LocalizedError, CustomStringConvertible {
    package let message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
    package var description: String { message }
}

/// A forwarded send's answer, given once: a send whose work ended without one (its chat started
/// again, or closed) answers that it didn't go.
private final class CallOnce: @unchecked Sendable {
    private var done: (@MainActor (Result<Bool, Error>) -> Void)?

    init(_ done: @escaping @MainActor (Result<Bool, Error>) -> Void) { self.done = done }

    @MainActor func callAsFunction(_ result: Result<Bool, Error>) {
        let done = self.done
        self.done = nil
        done?(result)
    }

    deinit {
        guard let done else { return }
        Task { @MainActor in done(.failure(CallRefusal("The message didn't go: the chat started again."))) }
    }
}

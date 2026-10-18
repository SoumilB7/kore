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

    /// Waiting in the composer, sent with the next message.
    private(set) var attachments: [Attachment] = []
    package var draft = ""
    /// The `/` command this message starts with, shown as a chip before the draft: one per
    /// message, as both CLIs run one.
    package var command: SlashCommand?
    /// The / menu was closed (Esc, a click away, another popup) for the "/word" at the caret;
    /// the next one opens it again.
    var slashClosed = false
    /// Launch with this model and effort instead of the CLI's defaults (a fork, the dev hook).
    @ObservationIgnored var launchModel: String?
    @ObservationIgnored var launchEffort: String?

    @ObservationIgnored private var backend: (any ChatBackend)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// The latest send: each waits for the one before to reach the CLI, so a message sent while
    /// the CLI is still starting can't overtake the first.
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private let resume: SessionSummary?
    /// A fork the CLI makes when it starts (Codex) or on its first message (Claude).
    @ObservationIgnored private let fork: ForkPoint?
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
    /// The turn running now, and when it began: a failure is the sleep's when the Mac slept since.
    @ObservationIgnored private var turnBegan: (id: TurnID, at: Date)?
    /// Stay awake's continuation after the plan's limit (`LimitContinuation`).
    @ObservationIgnored private lazy var continuation = makeContinuation()
    /// When the chat continues after its plan's limit resets; nil when it won't.
    private(set) var continuesAt: Date?
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
        // A reopened chat Kore made by an import has its record.
        self.imported = imported ?? (fork == nil ? session.flatMap { ImportedHistory.of(session: $0.id) } : nil)
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
        if case .replayed = event { showImported(in: transcript) }
        transcript.apply(event)
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
        status.apply(event)
        context.apply(event)
        seedImportedContext(event)
        autoCompactIfDue(event)
        afterAccountEvent(event)
        continueAfterLimit(event)
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
        transcript = store
        let replay = ChatEvent.replayed(events)
        approvals.apply(replay)
        controls.apply(replay)
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
        store.apply(.replayed(events))
        store.continued(imported.divider(product: product), help: "Open the \(imported.record.sourceProduct) chat")
    }

    /// The user's messages that waited for the history.
    private func showHeld() {
        awaitingHistory = false
        let waiting = held
        held = []
        waiting.forEach(dispatch)
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
        do {
            try await connect().start()
        } catch {
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
        if let imported {
            options.hiddenRows = Set(imported.record.written)
            options.instructions = imported.record.instructions.map { URL(fileURLWithPath: $0) }
        }
        let backend = make(options)
        self.backend = backend
        pump = Task {
            for await event in backend.events {
                // An imported chat's carried part is read before its own history shows.
                if let imported, importedEvents == nil, Self.isReplay(event) || Self.isCorrection(event) {
                    importedEvents = await imported.events()
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
    var isWorking: Bool { status.isRunning || !transcript.agentSummary.running.isEmpty }

    /// The account changed (a sign-in, a sign-out, a change outside Kore): the CLI starts again
    /// at the next turn boundary, at once when nothing runs.
    func accountChanged() {
        guard backend != nil else { return }
        relaunchDue = true
        relaunchIfDue()
    }

    /// Ends the CLI's process between turns, so the next send starts it again as the new
    /// account. It waits behind any send under way, and the next send waits for it.
    private func relaunchIfDue() {
        guard relaunchDue, !isWorking, let backend else { return }
        relaunchDue = false
        let previous = sending
        sending = Task {
            await previous?.value
            await backend.relaunch()
        }
    }

    private func afterAccountEvent(_ event: ChatEvent) {
        switch event {
        case .turnFinished(_, .authFailed, _):
            // The notice says "expired" or "isn't signed in": the status tells which.
            let provider = provider.id
            Task { await AccountStore.shared.refresh(provider) }
            relaunchIfDue()
        case .turnFinished, .agentFinished:
            relaunchIfDue()
        case .exited:
            // Its process is gone: the next send starts a new one anyway.
            relaunchDue = false
        default:
            break
        }
    }

    func close() {
        closed = true
        cancelContinue()
        pump?.cancel()
        let backend = backend
        self.backend = nil
        Task { await backend?.close() }
    }

    // MARK: Composer

    /// Something to send, and no compaction under way (sending waits until it's done).
    var canSend: Bool {
        !context.compacting
            && (command != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func attach(_ urls: [URL]) {
        attachments += urls.map(Attachment.init(url:))
    }

    func removeAttachment(_ id: Attachment.ID) {
        attachments.removeAll { $0.id == id }
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
            if awaitingHistory { held.append(message) } else { dispatch(message) }
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
        relaunchIfDue()
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
        if let queued { waiting[queued] = (text, sent) }
        if awaitingHistory { held.append(message) } else { dispatch(message) }
        status.setRunning(true)
        let backend = connect()
        let previous = sending
        sending = Task {
            await previous?.value
            do {
                try await backend.start()
                let turn = try await backend.send(text, files: Attachments.files(sent), queued: queued)
                if !turn, queued == nil { status.setRunning(false) }
            } catch {
                // A queued message that couldn't go goes back to the composer.
                if let queued { dispatch(.queuedMessage(id: queued, .dropped)) } else { status.setRunning(false) }
                fail(Self.reason(error))
            }
        }
    }

    // MARK: Stay awake

    /// What this chat keeps awake for: its turn, and its running agents and Codex child threads.
    var awakeWork: Int {
        guard !closed else { return 0 }
        return (status.isRunning ? 1 : 0) + transcript.agentSummary.running.count
    }

    /// Sends "Continue": a slept turn's Continue, and the continuation at a limit's reset.
    func continueTurn() {
        cancelContinue()
        deliver("Continue", [])
    }

    /// The × after "Continues at …", Stay awake turned off, or the owner sending.
    func cancelContinue() {
        guard continuesAt != nil || continuation.pending != nil else { return }
        continuation.cancel()
    }

    private func makeContinuation() -> LimitContinuation {
        let continuation = LimitContinuation(clock: StayAwake.current?.clock ?? SystemClock())
        continuation.read = { [weak self] in
            guard let self else { return nil }
            return try? await self.connect().usage()
        }
        continuation.send = { [weak self] in self?.deliver("Continue", []) }
        continuation.changed = { [weak self] pending in
            guard let self else { return }
            continuesAt = pending?.at
            transcript.continues(turn: pending?.turn, at: pending?.at)
        }
        return continuation
    }

    /// A turn that ended on the plan's limit continues at the reset, while Stay awake is on.
    private func continueAfterLimit(_ event: ChatEvent) {
        guard case .turnFinished(let id, .limited(_, let resetsAt), _) = event,
            StayAwake.current?.isOn == true, let turn = id ?? turnBegan?.id
        else { return }
        continuation.schedule(turn: turn, at: resetsAt)
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
        let backend = backend
        Task { await backend?.interrupt() }
    }

    /// The context wheel's click (look §9): compacts at once, between turns only.
    var canCompact: Bool { status.sessionId != nil && !status.isRunning && !context.compacting }

    /// `instructions`: what the summary should keep (`/compact <instructions>`); empty for none.
    /// The transcript's live row shows from here, before the CLI says it started. `point`: Kore
    /// compacts by itself, at the chat's auto-compact point.
    func compact(instructions: String = "", at point: Int? = nil) {
        guard canCompact else { return }
        autoCompactDue = false
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
            if origin == .user && !context.compacting { autoCompactDue = true }
        case .compactionStarted, .compacted, .exited:
            autoCompactDue = false
        case .turnFinished, .contextUsage:
            guard autoCompactDue, context.pastPoint, canCompact, waiting.isEmpty, let point = context.autoCompactAt
            else { return }
            compact(at: point)
        default:
            break
        }
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
        guard delivery == .dropped else { return }
        if command == nil, draft.isEmpty {
            restoreDraft(message.text, commands: controls.commands)
        } else {
            draft = draft.isEmpty ? message.text : message.text + "\n" + draft
        }
        attachments = message.files + attachments
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

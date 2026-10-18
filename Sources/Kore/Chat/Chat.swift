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
final class Chat: Identifiable {
    let id = UUID()
    let provider: ProviderDescriptor
    let folder: URL
    let transcript = TranscriptStore()
    let approvals = ApprovalsStore()
    let controls: ControlsStore
    let status: ChatStatus
    let context = ContextStore()
    /// The agent map's own UI state (open, selection); not fed by events.
    let agentMap = AgentMapState()

    /// Waiting in the composer, sent with the next message.
    private(set) var attachments: [Attachment] = []
    var draft = ""
    /// Launch with this model and effort instead of the CLI's defaults (a fork, the dev hook).
    @ObservationIgnored var launchModel: String?
    @ObservationIgnored var launchEffort: String?

    @ObservationIgnored private var backend: (any ChatBackend)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private let resume: SessionSummary?
    /// A fork the CLI makes when it starts (Codex) or on its first message (Claude).
    @ObservationIgnored private let fork: ForkPoint?
    /// The chat this one was forked from, for the line after its history.
    @ObservationIgnored private var forkedFrom: String?
    /// A past session's history hasn't been shown yet; messages sent meanwhile wait in `held`,
    /// so they come after it rather than above it.
    @ObservationIgnored private var awaitingHistory: Bool
    @ObservationIgnored private var held: [ChatEvent] = []
    /// That chat, while it's open (its "Forked from" line switches to it).
    @ObservationIgnored weak var original: Chat?

    /// `fork` makes this chat a fork of `session` that its CLI creates; it has no session of its
    /// own until then. `forkedFrom` names the original chat.
    init(
        provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil, fork: ForkPoint? = nil,
        forkedFrom: String? = nil
    ) {
        self.provider = provider
        self.folder = folder
        resume = session
        self.fork = fork
        self.forkedFrom = forkedFrom
        awaitingHistory = session != nil
        controls = ControlsStore(provider: provider)
        status = ChatStatus(resume: fork == nil ? session : nil)
        if fork != nil { status.name = session?.title }
        transcript.providerName = provider.name
        transcript.provider = provider
    }

    var sessionId: String? { status.sessionId }
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
        let start = DevSnapshot.timeReplay && Self.isReplay(event) ? ContinuousClock.now : nil
        transcript.apply(event)
        if case .replayed = event, let original = forkedFrom {
            // A fork's history ends with where it came from.
            forkedFrom = nil
            transcript.forkedFrom(original)
        }
        approvals.apply(event)
        controls.apply(event)
        noteAgentModeChange(event)
        status.apply(event)
        context.apply(event)
        if let start { DevSnapshot.logReplay(ContinuousClock.now - start) }
        if case .replayed = event { showHeld() }
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

    private func fail(_ message: String) {
        // No history is coming.
        showHeld()
        dispatch(.notice(message, isError: true))
    }

    // MARK: Lifecycle

    func start() async {
        do {
            try await connect().start()
        } catch {
            fail(String(describing: error))
        }
    }

    /// The backend, made on first use with the chat's current settings.
    private func connect() -> any ChatBackend {
        if let backend { return backend }
        let make: (BackendOptions) -> any ChatBackend = FeedBackend.enabled ? FeedBackend.init : provider.makeBackend
        let backend = make(
            BackendOptions(
                folder: folder, resume: resume, mode: controls.mode, planMode: controls.planMode,
                model: launchModel, effort: launchEffort, fork: fork, forkTitle: fork == nil ? nil : status.name))
        self.backend = backend
        pump = Task {
            for await event in backend.events { self.dispatch(event) }
        }
        return backend
    }

    func close() {
        pump?.cancel()
        let backend = backend
        self.backend = nil
        Task { await backend?.close() }
    }

    // MARK: Composer

    /// Something to send, and no compaction under way (sending waits until it's done).
    var canSend: Bool {
        !context.compacting && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
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

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = attachments
        guard !text.isEmpty || !sent.isEmpty, !context.compacting else { return }
        draft = ""
        attachments = []
        // The Codex extension's /plan flips the plan toggle; it isn't a message.
        if text == "/plan" && sent.isEmpty && provider.planToggle != nil {
            setPlanMode(!controls.planMode)
            return
        }
        approvals.offerImplementPlan = false
        let message = ChatEvent.userMessage(text: text, attachments: sent.map(SentAttachment.init))
        if awaitingHistory { held.append(message) } else { dispatch(message) }
        status.setRunning(true)
        let backend = connect()
        Task {
            do {
                try await backend.start()
                if try await !backend.send(text, files: Attachments.files(sent)) { status.setRunning(false) }
            } catch {
                status.setRunning(false)
                fail(String(describing: error))
            }
        }
    }

    // MARK: Actions

    func stop() {
        let backend = backend
        Task { await backend?.interrupt() }
    }

    /// The context wheel's click (look §9): compacts at once, between turns only.
    var canCompact: Bool { status.sessionId != nil && !status.isRunning && !context.compacting }

    func compact() {
        guard canCompact else { return }
        context.begin()
        let backend = connect()
        Task {
            do {
                try await backend.start()
                try await backend.compact()
            } catch {
                dispatch(.compactionFailed(Self.reason(error)))
            }
        }
    }

    /// An error as a short line for "Couldn't compact: …".
    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    func setMode(_ id: String) {
        controls.changedBy = nil
        let previous = controls.mode
        controls.mode = id
        let backend = backend
        Task {
            do {
                try await backend?.setMode(id)
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

    func setModel(_ option: ModelOption) {
        controls.modelId = option.id
        if let current = controls.effort, !option.efforts.isEmpty, !option.efforts.contains(current) {
            setEffort(option.efforts.contains("high") ? "high" : option.efforts[0])
        }
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

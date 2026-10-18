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
    let transcript = TranscriptStore()
    let approvals = ApprovalsStore()
    let controls: ControlsStore
    let status: ChatStatus
    let context = ContextStore()
    /// The agent map's own UI state (open, selection); not fed by events.
    let agentMap = AgentMapState()

    /// Waiting in the composer, sent with the next message.
    private(set) var attachments: [Attachment] = []
    package var draft = ""
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

    /// `fork` makes this chat a fork of `session` that its CLI creates; it has no session of its
    /// own until then. `forkedFrom` names the original chat.
    init(
        provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil, fork: ForkPoint? = nil,
        forkedFrom: String? = nil, modeMemory: ModeMemory = .shared
    ) {
        self.provider = provider
        self.folder = folder
        resume = session
        self.fork = fork
        self.forkedFrom = forkedFrom
        awaitingHistory = session != nil
        controls = ControlsStore(provider: provider, memory: modeMemory)
        status = ChatStatus(resume: fork == nil ? session : nil)
        if fork != nil { status.name = session?.title }
        transcript.providerName = provider.name
        transcript.provider = provider
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
        dropUnofferedMode(event)
        restoreQueued(event)
        status.apply(event)
        context.apply(event)
        if let start { DevSnapshot.logReplay(ContinuousClock.now - start) }
        if case .replayed = event { showHeld() }
        StorylineSeams.events?(self, event)
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
            fail(String(describing: error))
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
        // A typed /compact compacts as the context wheel does, shown as the user's message (the
        // CLI isn't sent it as one). It waits in the composer while it can't (a turn running, no
        // session yet).
        if sent.isEmpty, let instructions = Self.compactCommand(text) {
            guard canCompact else { return }
            draft = ""
            let message = ChatEvent.userMessage(text: text, attachments: [])
            if awaitingHistory { held.append(message) } else { dispatch(message) }
            compact(instructions: instructions)
            return
        }
        draft = ""
        attachments = []
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

    /// `instructions`: what the summary should keep (`/compact <instructions>`); empty for none.
    /// The transcript's live row shows from here, before the CLI says it started.
    func compact(instructions: String = "") {
        guard canCompact else { return }
        context.begin()
        transcript.compacting(true)
        let backend = connect()
        Task {
            do {
                try await backend.start()
                try await backend.compact(instructions: instructions)
            } catch {
                dispatch(.compactionFailed(Self.reason(error)))
            }
        }
    }

    /// The instructions of a typed `/compact` (empty when it has none); nil for anything else.
    static func compactCommand(_ text: String) -> String? {
        let command = "/compact"
        guard text.hasPrefix(command), text.dropFirst(command.count).first.map(\.isWhitespace) ?? true else { return nil }
        return text.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
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
        draft = draft.isEmpty ? message.text : message.text + "\n" + draft
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

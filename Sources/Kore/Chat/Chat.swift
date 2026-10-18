import AppKit
import Foundation
import KoreCore
import Observation

/// One conversation with a CLI. It owns the backend and hands each `ChatEvent` to the stores,
/// one per feature: the transcript, approvals, controls (mode, model, commands) and status. Views
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

    /// Waiting in the composer, sent with the next message.
    private(set) var attachments: [Attachment] = []
    var draft = ""
    /// Launch with this model instead of the CLI's default (set by the dev hook).
    @ObservationIgnored var launchModel: String?

    @ObservationIgnored private var backend: (any ChatBackend)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private let resume: SessionSummary?

    init(provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil) {
        self.provider = provider
        self.folder = folder
        resume = session
        controls = ControlsStore(provider: provider)
        status = ChatStatus(resume: session)
        transcript.providerName = provider.name
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
        transcript.apply(event)
        approvals.apply(event)
        controls.apply(event)
        status.apply(event)
    }

    private func fail(_ message: String) {
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
        let backend = provider.makeBackend(
            BackendOptions(
                folder: folder, resume: resume, mode: controls.mode, planMode: controls.planMode, model: launchModel))
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

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

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
        guard !text.isEmpty || !sent.isEmpty else { return }
        draft = ""
        attachments = []
        // The Codex extension's /plan flips the plan toggle; it isn't a message.
        if text == "/plan" && sent.isEmpty && provider.planToggle != nil {
            setPlanMode(!controls.planMode)
            return
        }
        approvals.offerImplementPlan = false
        dispatch(.userMessage(text: text, attachments: sent.map(SentAttachment.init)))
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

    func stopAgent(_ id: String) {
        let backend = backend
        Task { await backend?.stopAgent(id) }
    }

    func setMode(_ id: String) {
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

import AppKit
import Foundation
import KoreCore
import Observation
import SwiftUI

/// One conversation with a CLI, as a flat transcript. It runs on a `ChatBackend` and applies
/// its `ChatEvent`s; the feature stores of phase 07 take this over.
@MainActor @Observable
final class ChatModel: Identifiable {
    struct Entry: Identifiable {
        enum Kind { case user, assistant, thinking, plan, tool, notice, peer }

        let id = UUID()
        var kind: Kind
        var text: String
        var toolName: String?
        /// The tool call or text block it shows.
        var toolId: String?
        var result: String?
        var done = false
        var isError = false
        /// Files and images sent with a user message.
        var attachments: [Attachment] = []
        /// Who sent a `.peer` message (another Claude session's name).
        var from: String?
    }

    let id = UUID()
    let provider: ProviderDescriptor
    let folder: URL
    private(set) var entries: [Entry] = []
    private(set) var approvals: [Approval] = []
    private(set) var isRunning = false
    /// The provider's mode id (Claude permission mode / Codex permissions preset).
    private(set) var mode: String
    /// The provider's plan toggle (Codex); Claude's plan is a mode.
    private(set) var planMode = false
    /// A plan finished in plan mode: offer "Implement this plan?" like the Codex CLI.
    private(set) var offerImplementPlan = false
    private(set) var models: [ModelOption] = []
    private(set) var modelId: String?
    private(set) var effort: String?
    private(set) var commands: [SlashCommand] = []
    /// Waiting in the composer, sent with the next message.
    private(set) var attachments: [Attachment] = []
    var draft = ""

    /// The CLI's name for the conversation (AI title or rename); nil until there is one.
    private(set) var name: String?

    private var backend: (any ChatBackend)?
    private var pump: Task<Void, Never>?
    private let resume: SessionSummary?
    private var resumeId: String?
    /// Opened from a past session (history, or restored tabs).
    let resumed: Bool
    /// Launch with this model instead of the CLI's default (set by the dev hook).
    var launchModel: String?
    /// Where each block, tool call and turn sits in `entries`.
    private var blockIndex: [BlockID: Int] = [:]
    private var toolIndex: [String: Int] = [:]
    private var turnIndex: [TurnID: Int] = [:]
    /// Applying a resumed session's past: its turns' outcomes aren't announced again.
    private var replaying = false

    init(provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil) {
        self.provider = provider
        self.folder = folder
        mode = provider.modes[0].id
        resume = session
        resumeId = session?.id
        name = session?.title
        resumed = session != nil
    }

    /// Claude session id / Codex thread id, once known.
    var sessionId: String? { resumeId }

    /// A past session, or one where something was said: `sessionId` can be resumed.
    var hasConversation: Bool { resumed || entries.contains { $0.kind == .user || $0.kind == .peer } }

    var title: String {
        if let name { return name }
        guard let first = entries.first(where: { $0.kind == .user }) else { return provider.name }
        return first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
    }

    /// The CLI's current name for a past session (it may have been renamed elsewhere).
    func adoptName(_ newName: String) { name = newName }

    /// A user rename, saved by the CLI (Claude: custom title, Codex: thread name).
    func rename(_ newName: String) {
        Task { await applyRename(newName) }
    }

    /// Renames and waits until the CLI has it (starting the CLI if needed).
    func applyRename(_ newName: String) async {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        name = newName
        await start()
        try? await backend?.rename(newName)
    }

    var availableModes: [ModeOption] { provider.availableModes(currentModel) }

    var activeMode: ModeOption {
        if planMode, let plan = provider.planToggle { return plan }
        return permissionsMode
    }

    /// The mode apart from a plan toggle.
    var permissionsMode: ModeOption { provider.modes.first { $0.id == mode } ?? provider.modes[0] }

    /// The chat's highlight color for the active mode; nil when neutral.
    var tint: Color? { activeMode.tint }

    var currentModel: ModelOption? { models.first { $0.id == modelId } }

    var modelLabel: String { currentModel?.name ?? modelId ?? provider.name }

    var effortLabel: String? {
        guard let effort else { return nil }
        return effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    // MARK: - Actions

    func start() async {
        do {
            try await connect().start()
        } catch {
            append(.notice, String(describing: error), isError: true)
        }
    }

    /// The backend, made on first use with the chat's current settings.
    private func connect() -> any ChatBackend {
        if let backend { return backend }
        let backend = provider.makeBackend(
            BackendOptions(folder: folder, resume: resume, mode: mode, planMode: planMode, model: launchModel))
        self.backend = backend
        pump = Task {
            for await event in backend.events { self.apply(event) }
        }
        return backend
    }

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
            setPlanMode(!planMode)
            return
        }
        offerImplementPlan = false
        var entry = Entry(kind: .user, text: text)
        entry.attachments = sent
        entries.append(entry)
        isRunning = true
        let backend = connect()
        Task {
            do {
                try await backend.start()
                if try await !backend.send(text, files: Attachments.files(sent)) { isRunning = false }
            } catch {
                isRunning = false
                append(.notice, String(describing: error), isError: true)
            }
        }
    }

    func stop() {
        let backend = backend
        Task { await backend?.interrupt() }
    }

    func setMode(_ id: String) {
        let previous = mode
        mode = id
        let backend = backend
        Task {
            do {
                try await backend?.setMode(id)
            } catch {
                mode = previous
                append(.notice, "Couldn't switch mode: \(error)", isError: true)
            }
        }
    }

    func setPlanMode(_ on: Bool) {
        planMode = on
        let backend = backend
        Task { await backend?.setPlanMode(on) }
    }

    /// Shift+Tab, as in each CLI.
    func cycleMode() {
        switch provider.nextMode(mode, planMode, availableModes) {
        case .mode(let next): setMode(next)
        case .togglePlan: setPlanMode(!planMode)
        }
    }

    /// Codex CLI's "Yes, implement this plan": switch plan off and start coding.
    func implementPlan() {
        setPlanMode(false)
        draft = "Implement the plan."
        send()
    }

    func stayInPlanMode() {
        offerImplementPlan = false
    }

    func setModel(_ option: ModelOption) {
        modelId = option.id
        if let current = effort, !option.efforts.isEmpty, !option.efforts.contains(current) {
            setEffort(option.efforts.contains("high") ? "high" : option.efforts[0])
        }
        let backend = backend
        Task {
            do {
                try await backend?.setModel(option.id)
            } catch {
                append(.notice, "Couldn't switch model: \(error)", isError: true)
            }
        }
    }

    func setEffort(_ level: String) {
        effort = level
        let backend = backend
        Task { await backend?.setEffort(level) }
    }

    func answer(_ approval: Approval, _ decision: Decision) {
        approvals.removeAll { $0.id == approval.id }
        let backend = backend
        Task { await backend?.respond(to: approval.id, decision) }
    }

    func close() {
        pump?.cancel()
        let backend = backend
        self.backend = nil
        Task { await backend?.close() }
    }

    // MARK: - Events

    private func apply(_ event: ChatEvent) {
        switch event {
        case .sessionIdentified(let id):
            resumeId = id
        case .titleChanged(let title):
            if name == nil { name = title }
        case .controlsLoaded(let controls):
            models = controls.models
            modelId = controls.model
            effort = controls.effort
            commands = controls.commands
        case .modeChanged(let id):
            mode = id
        case .planModeChanged(let on):
            planMode = on
        case .turnStarted(let turn, _, _):
            isRunning = true
            offerImplementPlan = false
            turnIndex[turn] = entries.count
        case .turnFinished(_, let outcome, _):
            isRunning = false
            approvals.removeAll()
            guard !replaying else { return }
            switch outcome {
            case .completed: break
            case .interrupted: append(.notice, "Interrupted")
            case .failed(let message): append(.notice, message, isError: true)
            }
        case .userMessage(let text, let sent):
            var entry = Entry(kind: .user, text: text)
            entry.attachments = sent.map(Attachment.init(sent:))
            entries.append(entry)
        case .peerMessage(let from, let text, let turn):
            var entry = Entry(kind: .peer, text: text)
            entry.from = from
            insert(entry, at: turn.flatMap { turnIndex[$0] } ?? entries.count)
        case .text(let block, let kind, let text, .main):
            if let i = blockIndex[block], entries.indices.contains(i) {
                entries[i].text += text
            } else {
                var entry = Entry(kind: kind == .thinking ? .thinking : kind == .plan ? .plan : .assistant, text: text)
                entry.toolId = block
                entries.append(entry)
                blockIndex[block] = entries.count - 1
            }
        case .toolStarted(let tool, .main):
            var entry = Entry(kind: .tool, text: tool.detail)
            entry.toolName = tool.name
            entry.toolId = tool.id
            entries.append(entry)
            toolIndex[tool.id] = entries.count - 1
        case .toolOutput(let id, let text, .main):
            if let i = toolIndex[id], entries.indices.contains(i) { entries[i].result = (entries[i].result ?? "") + text }
        case .toolFinished(let id, let output, let isError, .main):
            guard let i = toolIndex[id], entries.indices.contains(i) else { return }
            entries[i].result = output ?? entries[i].result?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries[i].done = true
            entries[i].isError = isError
        case .notice(let text, let isError):
            append(.notice, text, isError: isError)
        case .approvalRequested(let approval):
            approvals.append(approval)
        case .approvalWithdrawn(let id):
            approvals.removeAll { $0.id == id }
        case .planReady:
            offerImplementPlan = true
        case .exited(let status):
            isRunning = false
            approvals.removeAll()
            if status != 0 && status != 15 { append(.notice, "\(provider.name) exited (\(status))", isError: true) }
        case .replayed(let events):
            replaying = true
            for event in events { apply(event) }
            replaying = false
            offerImplementPlan = false
        default:
            break  // sub-agents' content, agent cards, final answers, turn origins and changes: phase 08's views
        }
    }

    private func append(_ kind: Entry.Kind, _ text: String, isError: Bool = false) {
        var entry = Entry(kind: kind, text: text)
        entry.isError = isError
        entries.append(entry)
    }

    /// Inserts before later entries, keeping the indexes pointing at the same entries.
    private func insert(_ entry: Entry, at index: Int) {
        let index = min(index, entries.count)
        entries.insert(entry, at: index)
        func shift(_ map: inout [String: Int]) {
            for (key, i) in map where i >= index { map[key] = i + 1 }
        }
        shift(&blockIndex)
        shift(&toolIndex)
        shift(&turnIndex)
    }
}

extension Attachment {
    init(sent: SentAttachment) {
        if let url = sent.url {
            self.init(url: url)
        } else {
            self.init(name: sent.name, kind: sent.kind, thumbnail: sent.image.flatMap(NSImage.init(data:)))
        }
    }
}

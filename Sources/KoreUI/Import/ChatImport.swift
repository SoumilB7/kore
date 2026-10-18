import Foundation
import KoreCore

/// Why an import didn't happen. `notImportable` is said quietly (the picker just doesn't offer
/// it): a file no format recognises, one damaged part-way, or one with nothing to carry.
package enum ImportRefusal: Equatable, Sendable {
    case notImportable
    /// The chat already has a conversation of its own, or something running.
    case chatInUse
    /// The source chat is open here with a turn, an agent or a question under way.
    case sourceBusy
    case folderMissing
    /// The target CLI isn't signed in: its product name.
    case signedOut(String)
    case failed(String)

    /// What to say; nil for the quiet one.
    package var reason: String? {
        switch self {
        case .notImportable: nil
        case .chatInUse: "This chat already has a conversation."
        case .sourceBusy: "That chat is still working. Import it once it's idle."
        case .folderMissing: "This folder no longer exists."
        case .signedOut(let product): "\(product) isn't signed in. Sign in from Account in the / menu."
        case .failed(let why): "Couldn't import: \(why)"
        }
    }
}

/// The settings an imported chat runs with: the new chat's own unless the picker chose others
/// (`ImportMapping.settings` gives the source's, in the target's terms).
package struct ImportSettings: Equatable, Sendable {
    package var mode: String
    package var planMode: Bool
    package var model: String?
    package var effort: String?

    package init(mode: String, planMode: Bool, model: String? = nil, effort: String? = nil) {
        self.mode = mode
        self.planMode = planMode
        self.model = model
        self.effort = effort
    }
}

extension Workspace {
    /// What importing `source` into `chat` would carry, for the picker; nil, quietly, when it
    /// can't be imported. Reads the file off the main thread (the import then reads it again
    /// only if it changed).
    package func importPreview(_ source: HandoffSource, into chat: Chat) async -> HandoffPreview? {
        guard let writer = HandoffWriters.writer(chat.provider.id), let file = await historyFile(source) else { return nil }
        let model = chat.controls.modelId ?? chat.launchModel
        return await Task.detached(priority: .userInitiated) { HandoffImport.preview(file, for: writer, model: model) }.value
    }

    /// Imports a chat's history into `chat`, a new chat with nothing in it yet: the history is
    /// written as a new session of `chat`'s CLI, and the tab carries on in it, the imported part
    /// above a divider and the draft kept. Nil when it's done.
    package func importChat(_ source: HandoffSource, into chat: Chat, settings: ImportSettings? = nil) async -> ImportRefusal? {
        guard let tab = tab(of: chat) else { return .failed("the chat isn't open") }
        guard !chat.hasConversation, !chat.isWorking, chat.approvals.pending.isEmpty else { return .chatInUse }
        guard FileManager.default.fileExists(atPath: folder.path) else { return .folderMissing }
        guard let writer = HandoffWriters.writer(chat.provider.id), let file = await historyFile(source) else { return .notImportable }
        let store = AccountStore.shared
        if case .unknown = store.status(chat.provider.id) { await store.refresh(chat.provider.id) }
        if case .signedOut = store.status(chat.provider.id) { return .signedOut(chat.provider.usage.product) }
        let settings = settings ?? ImportSettings(
            mode: chat.controls.mode, planMode: chat.controls.planMode, model: chat.controls.modelId ?? chat.launchModel,
            effort: chat.controls.effort ?? chat.launchEffort)
        let model = settings.model
        guard let (segment, plan) = await Task.detached(priority: .userInitiated, operation: { HandoffImport.plan(file, for: writer, model: model) }).value
        else { return .notImportable }
        if busy(segment.sessionId) { return .sourceBusy }
        let target = HandoffTarget(
            folder: folder, title: segment.shownTitle, model: settings.model, effort: settings.effort, mode: settings.mode,
            planMode: settings.planMode, instructions: HandoffWriters.instructions(for: writer, in: folder))
        let record: HandoffRecord
        do {
            record = try await HandoffImport.write(segment, plan, file: file, into: target, writer: writer)
        } catch {
            return .failed(Chat.reason(error))
        }
        let imported = Chat(
            provider: chat.provider, folder: folder,
            resume: SessionSummary(id: record.target.session, agent: chat.provider.historyAgent, title: target.title, updated: .now),
            imported: ImportedHistory(record: record, turns: plan.entries.map(\.turn)))
        imported.controls.mode = settings.mode
        imported.controls.planMode = settings.planMode
        imported.launchModel = settings.model
        imported.launchEffort = settings.effort
        imported.inheritAutoCompact(from: chat)
        imported.restoreDraft(chat.draft, commands: chat.controls.commands)
        // The tab carries on in the imported chat; the empty one it replaces ends.
        tab.chat = imported
        chat.close()
        return nil
    }

    /// The source's history file: the one given, or a chat's own.
    private func historyFile(_ source: HandoffSource) async -> URL? {
        switch source {
        case .file(let url): url
        case .session(let provider, let id): await Registry.provider(provider)?.historyFile(id, folder)
        }
    }

    /// A chat of that session open here is mid-turn, running agents, or waiting on the user.
    private func busy(_ session: String) -> Bool {
        tabs.contains { tab in
            guard tab.agent == nil, let chat = tab.chat, chat.sessionId == session else { return false }
            return chat.isWorking || !chat.approvals.pending.isEmpty
        }
    }
}

/// A source's mode and effort in the target CLI's terms (chat-handoff.md §10), by the mode's
/// rung on the ladder, so no CLI is named here: the same rung where the target has it, else the
/// next one down (Full access → Edit automatically, Approve for me → Auto where the model allows
/// it); Plan stays Plan (a toggle or a mode).
enum ImportMapping {
    static func settings(_ preview: HandoffPreview, into target: Provider, model: ModelOption?) -> ImportSettings? {
        guard let source = Registry.provider(preview.format) else { return nil }
        let options = source.modes + [source.planToggle].compactMap { $0 }
        let rung = preview.mode.flatMap { mode in options.first { $0.id == mode } }?.rung
        let available = target.availableModes(model)
        var settings = ImportSettings(mode: available.first?.id ?? target.modes[0].id, planMode: false, model: model?.id)
        if rung == .plan {
            if target.planToggle != nil {
                settings.planMode = true
            } else if let plan = available.first(where: { $0.rung == .plan }) {
                settings.mode = plan.id
            }
        } else {
            let ladder: [Rung?] =
                switch rung {
                case .danger?: [.danger, .edits, nil]
                case .auto?: [.auto, .edits, nil]
                case .edits?: [.edits, nil]
                default: [nil]
                }
            if let mode = ladder.lazy.compactMap({ step in available.first { $0.rung == step } }).first { settings.mode = mode.id }
        }
        settings.effort = effort(preview.effort, offered: model?.efforts ?? [])
        return settings
    }

    /// Codex's `minimal` is Claude's `low` and `ultra` its `max`; a level the model doesn't offer
    /// becomes the highest it does below it.
    static func effort(_ effort: String?, offered: [String]) -> String? {
        guard var effort else { return nil }
        effort = ["minimal": "low", "ultra": "max"][effort] ?? effort
        guard !offered.isEmpty, !offered.contains(effort) else { return effort }
        let order = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        let rank = order.firstIndex(of: effort) ?? 0
        return offered.filter { (order.firstIndex(of: $0) ?? 0) <= rank }.max { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            ?? offered.first
    }
}

import AppKit
import Foundation
import KoreCore
import src
import SwiftUI

/// A chat's view state: the popups over its composer and the agent map. The chat (`src`) keeps
/// it for the app (`ChatServices.makeViewState`); nothing in it is fed by events.
@MainActor
final class ChatViewState {
    /// The agent map's own UI state (open, selection).
    let agentMap = AgentMapState()
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
}

extension Chat {
    /// A chat with the app's services, its modes and auto-compact points kept as the app keeps them.
    convenience init(
        provider: ProviderDescriptor, folder: URL, resume session: SessionSummary? = nil, fork: ForkPoint? = nil,
        forkedFrom: String? = nil, imported: ImportedHistory? = nil, modeMemory: ModeMemory = .shared,
        compactMemory: AutoCompactMemory = .shared
    ) {
        self.init(
            provider: provider, folder: folder, resume: session, fork: fork, forkedFrom: forkedFrom, imported: imported,
            modeMemory: modeMemory, compactMemory: compactMemory, services: AppChatServices.shared)
    }

    private var viewState: ChatViewState { unsafeDowncast(ui, to: ChatViewState.self) }

    /// The transcript as the app shows it.
    package var transcript: TranscriptStore { unsafeDowncast(transcriptView, to: TranscriptStore.self) }
    var agentMap: AgentMapState { viewState.agentMap }
    var contextCard: ContextCardPresence { viewState.contextCard }
    var usage: UsageState { viewState.usage }
    var account: AccountState { viewState.account }
    var importer: ImportState { viewState.importer }
    var picker: PickerState { viewState.picker }

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
            },
            // A box's chat reads the box's login through its CLI there: kept apart from this Mac's.
            cacheScope: (services as? BoxChatServices).map { "box:" + $0.connection.alias })
    }

    /// The logins this chat's CLI uses: this Mac's, or its box's.
    var accountStore: AccountStore {
        (services as? BoxChatServices).map { BoxAccountStores.store($0.connection) } ?? .shared
    }

    /// Opens the Account popup for this chat's CLI.
    func openAccount() {
        closePopups(keeping: .account)
        account.open(provider: provider.id, folder: folder, store: accountStore)
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
        // A box's login signs in on the box (its own store), never this Mac's.
        let store = accountStore
        if case .signedIn(let identity) = store.status(provider.id), !identity.changeable { return }
        account.signIn()
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

    /// A sent message's files, to attach again: those still on disk, and pictures known only as
    /// they were sent (a past message's), saved again. Others can't be sent again.
    static func reattach(_ sent: [Attachment]) -> [Attachment] {
        sent.compactMap { file in
            if let url = file.url, FileManager.default.fileExists(atPath: url.path) { return Attachment(url: url) }
            if file.kind == .image, let data = file.imageData, let url = Attachments.saveImage(data) { return Attachment(url: url) }
            return nil
        }
    }

    /// The transcript's entries as text, one per line: what `KORE_DUMP` and storyline
    /// `DumpRows` write, so replays compare across builds.
    package func dumpLines() -> [String] {
        transcript.entries.map { e in
            let files = transcript.chips(e).map { "\($0.name):\($0.kind):\($0.thumbnail != nil)" }.joined(separator: ",")
            // Kinds keep their earlier names, so dumps compare across builds.
            let kind = e.kind == .answer ? "assistant" : "\(e.kind)"
            return [kind, e.toolName ?? "", e.text, e.result ?? "", "\(e.done)", "\(e.isError)", files, e.from ?? ""]
                .joined(separator: " | ").replacingOccurrences(of: "\n", with: "⏎")
        }
    }
}

extension ModeMemory {
    /// Dev runs (any KORE_ hook) and storylines start where a fresh install does, and leave
    /// the owner's choice alone.
    @MainActor static var shared: ModeMemory {
        let dev = StoryHost.installed || KoreReach.isDevRun(ProcessInfo.processInfo.environment)
        return ModeMemory(defaults: dev ? nil : .standard)
    }
}

extension AutoCompactMemory {
    @MainActor static var shared: AutoCompactMemory { AutoCompactMemory(defaults: ModeMemory.shared.defaults) }
}

extension ControlsStore {
    /// The chat's highlight colour for the active mode; nil when neutral.
    var tint: Color? { activeMode.tint }
}

extension TranscriptStore: ChatTranscript {
    package var runningAgents: [String] { agentSummary.running.map(\.id) }
}

import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import SwiftUI

// A window whose chats live on a box: the folder window as for this Mac, its chats run on the
// box. Nothing here runs until such a window opens.

/// The scene's value: the alias, and the box's folder once picked.
struct BoxPlace: Codable, Hashable {
    var alias: String
    var folder: String?
}

extension BoxPlace {
    /// A window restored from before its box was rekeyed opens under the box's id now.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = NodeRenames().map(try c.decode(String.self, forKey: .alias))
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
    }
}

/// One box folder's window: its connection, its chats made and closed there, and the title row's
/// one cue.
@MainActor
final class BoxBinding {
    let alias: String
    /// As the box names it.
    let folder: String
    let connection: HostConnection
    /// When the window's link-down card shows (`BoxOfflineDialog`).
    let linkCard: LinkDownCard

    init(alias: String, folder: String) {
        self.alias = alias
        self.folder = folder
        connection = Self.connection(alias)
        linkCard = LinkDownCard(stableAfter: connection.stableAfter)
    }

    static func connection(_ alias: String) -> HostConnection {
        HostConnection.named(alias, grant: grant(alias), command: command(alias))
    }

    /// The Mac's grant name on the box: the one its setup made, else this Mac's name.
    static func grant(_ alias: String) -> String { BoxSetup.grant(for: alias) }

    /// kore-host's path on the box: `defaults write <Kore> boxKoreHost.<alias> <path>`, else
    /// `~/.local/bin/kore-host`.
    static func command(_ alias: String) -> String { BoxSetup.command(for: alias) }

    /// The window's key among the open workspaces: never a folder on this Mac's.
    var key: String { "box:" + alias + ":" + folder }

    /// A stand-in path whose last part is the folder's name: the window's title and the chats'
    /// folder. Nothing on this Mac is read or written there.
    var folderURL: URL { URL(fileURLWithPath: "/" + alias + "/" + folder.replacingOccurrences(of: "~", with: "home")) }

    /// The folder's files as the window's explorer shows them (made when it first shows).
    private(set) lazy var files: BoxExplorerStore = {
        filesMade = true
        let store = BoxExplorerStore(root: folder, source: connection)
        store.onMoved = { [weak self] old, new in self?.workspace?.boxMoved(old, to: new) }
        store.onTrashed = { [weak self] gone in
            for tab in self?.workspace?.tabs ?? [] {
                guard let file = tab.file, let path = file.box?.path, gone.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                file.boxGone()
            }
        }
        store.onChanged = { [weak self] change in self?.workspace?.boxFoldersChanged(change) }
        return store
    }()
    /// Search in the box folder (the explorer's Search, Find in Folder…).
    private(set) lazy var search = BoxSearchStore(root: folder, source: connection)
    private(set) var filesMade = false

    /// A store made elsewhere (a snapshot's fake box) as this window's files.
    func adopt(_ store: BoxExplorerStore) {
        files = store
        filesMade = true
    }

    /// The folder's git (link 1.8): the explorer's colours, the editor's bars, the diffs.
    private(set) lazy var git: BoxGitStatus = makeGit()

    /// A box path's stand-in under `folderURL`, for a file tab's path row.
    func standIn(_ path: String) -> URL {
        let inside = path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count)) : "/" + BoxFolder.lastPart(path)
        return URL(fileURLWithPath: folderURL.standardizedFileURL.path + inside)
    }

    /// A path a box window's link or recent names, as the box's own: one under the box folder, or
    /// its stand-in here. Nil for anything else.
    func boxPath(_ path: String) -> String? {
        if path == folder || path.hasPrefix(folder + "/") { return path }
        let base = folderURL.standardizedFileURL.path
        if path.hasPrefix(base + "/") { return folder + path.dropFirst(base.count) }
        return nil
    }

    /// The window's workspace, for the chats the box opens in this folder meanwhile.
    weak var workspace: Workspace?
    /// Chats whose tabs closed here: never adopted again, even before the box confirms.
    private var closedIds: Set<String> = []

    /// The folder as the box's window names it ("~/Code"), else its path.
    var shownFolder: String {
        let window = connection.windowId(of: folder)
        return connection.windows.first { $0.id == window }?.path ?? folder
    }

    /// The folder's two-way sync with a Mac folder, while this window is open.
    private(set) var sync: HostSync?
    private var focus: NSObjectProtocol?

    func windowOpened() {
        BoxBinding.opened(alias: alias, folder: folder)
        // The folder's chats opened anywhere (the box, the phone, another Mac, an agent) as tabs,
        // as the box lists them: on each snapshot and each delta.
        connection.onTabs(key) { [weak self] in self?.adoptChats() }
        // 1.10: where each chat lives (a replica's dimmed tab and pill).
        let alias = alias
        connection.onChatMeta(key) { [weak connection] ids in
            for id in ids { if let meta = connection?.chats[id] { ChatPlaces.shared.heard(alias, meta) } }
        }
        connection.retain()
        followPair()
        Workspace.boxLinkChanged(alias)
    }

    func windowClosed() {
        connection.onTabs(key, nil)
        connection.onChatMeta(key, nil)
        if filesMade { files.stop() }
        stopSync()
        connection.release()
        Workspace.boxLinkChanged(alias)
    }

    /// The Mac folder this one syncs with, as the panel and tooltip show it (`~/Desktop/app`).
    var syncedTo: String? { SyncPairList.shared.pair(alias: alias, box: folder).map { SyncPairs.shown(mac: $0.mac) } }

    /// The sync follows the folder's pair: started once it's made, stopped once it's gone.
    func followPair() {
        let pair = SyncPairList.shared.pair(alias: alias, box: folder)
        guard pair?.mac != sync?.pair.mac || pair?.box != sync?.pair.box else { return }
        stopSync()
        guard let pair, let sync = HostSync(pair: pair, connection: connection) else { return }
        self.sync = sync
        sync.start()
        // A box that can't watch its copy lists it again as the window comes forward.
        focus = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let mine = self.workspace?.window, ObjectIdentifier(mine) == window else { return }
                self.sync?.refresh()
            }
        }
    }

    private func stopSync() {
        sync?.stop()
        sync = nil
        if let focus { NotificationCenter.default.removeObserver(focus) }
        focus = nil
    }

    /// Every open box window's sync follows the pairs (one was made or stopped).
    static func pairsChanged() {
        for workspace in Workspace.all.allObjects where !workspace.isClosed {
            workspace.box?.followPair()
            workspace.followPairedBox()
        }
    }

    /// Chats in this folder the window doesn't show yet (opened on the box or elsewhere, or none
    /// known when the window opened) get tabs at the end; a lone empty tab gives way to them.
    func adoptChats() {
        guard let workspace, !workspace.isClosed else { return }
        let services = workspace.tabs.flatMap { tab in
            ([tab.chat] + (tab.board.map { Array($0.chats.values) } ?? [])).compactMap { $0?.services as? BoxChatServices }
        }
        // A chat made here that the box may list before its id comes back: adopted once it has it.
        guard !services.contains(where: \.creating) else { return }
        let shown = Set(services.compactMap(\.chatId))
        let tabs: [ChatTab] = connection.chats(in: folder).filter { !shown.contains($0.id) && !closedIds.contains($0.id) }.compactMap { meta in
            guard let provider = Registry.provider(meta.provider) else { return nil }
            let tab = ChatTab()
            tab.chat = chat(provider, id: meta.id, title: meta.title)
            return tab
        }
        guard let first = tabs.first else { return }
        if workspace.tabs.count == 1, workspace.tabs[0].isEmpty {
            workspace.tabs = tabs
            workspace.select(first)
        } else {
            workspace.tabs += tabs
        }
    }

    /// A box chat in front here: its tab, made when the window doesn't show it yet (a chat that
    /// came back from this Mac as a new one).
    func show(_ chatId: String) {
        adoptChats()
        guard let workspace, let tab = workspace.tabs.first(where: { ($0.chat?.services as? BoxChatServices)?.chatId == chatId }) else { return }
        workspace.select(tab)
    }

    /// The folder label's hover line: "mybox · ~/Code/app · synced locally to ~/Desktop/app".
    var label: String { alias + " · " + shownFolder + (syncedTo.map { " · synced locally to " + $0 } ?? "") }

    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    // MARK: Chats

    /// The box's chats in this folder, a tab each, as it last said (from the local copy offline).
    func openTabs() -> [ChatTab]? {
        let chats = connection.chats(in: folder).compactMap { meta -> Chat? in
            guard let provider = Registry.provider(meta.provider) else { return nil }
            return chat(provider, id: meta.id, title: meta.title)
        }
        guard !chats.isEmpty else { return nil }
        return chats.map { chat in
            let tab = ChatTab()
            tab.chat = chat
            return tab
        }
    }

    /// A new chat, made on the box when its tab first starts it.
    func newChat(_ provider: Provider) -> Chat { chat(provider, id: nil, title: nil) }

    /// A fork of a chat here, made on the box from where it starts: its CLI shows the history
    /// before that point, as a fork on this Mac does.
    func forkChat(of original: Chat, from: String, at: String, title: String) -> Chat {
        let making = LinkChatBackend.Making(
            model: original.controls.modelId ?? original.launchModel, forkFrom: from, forkAt: at, title: title, mode: original.controls.mode,
            effort: original.controls.effort)
        return chat(original.provider, id: nil, title: title, making: making, forkedFrom: original.title)
    }

    private func chat(_ provider: Provider, id: String?, title: String?, making: LinkChatBackend.Making? = nil, forkedFrom: String? = nil) -> Chat {
        let services = BoxChatServices(binding: self, chatId: id, making: making)
        let chat = Chat(
            provider: provider, folder: folderURL, forkedFrom: forkedFrom, modeMemory: ModeMemory(defaults: nil),
            compactMemory: AutoCompactMemory(defaults: nil), services: services)
        if let title, !title.isEmpty { chat.adoptName(title) }
        return chat
    }

    /// Its tab closed here: it closes on the box too.
    /// Box tabs closed in this window, last closed last: ⇧⌘T reopens them on the box.
    private var closedTabs: [(id: String, provider: Provider, title: String, index: Int)] = []

    var canReopen: Bool { !closedTabs.isEmpty }

    func rememberClosed(_ chat: Chat, at index: Int) {
        guard let id = (chat.services as? BoxChatServices)?.chatId else { return }
        closedTabs.append((id, chat.provider, chat.title, index))
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }

    /// The last closed tab's chat, back on the box, and where its tab was.
    func reopenLast() async -> (chat: Chat, index: Int)? {
        while let entry = closedTabs.popLast() {
            if let chat = await reopen(entry.id, provider: entry.provider, title: entry.title) { return (chat, entry.index) }
        }
        return nil
    }

    /// A closed chat back on the box, as a chat for a tab here; nil when the box no longer keeps it.
    func reopen(_ id: String, provider: Provider, title: String) async -> Chat? {
        guard case .success(let chatId) = await connection.reopen(id) else { return nil }
        closedIds.remove(chatId)
        return chat(provider, id: chatId, title: title)
    }

    private var windowId: String? { connection.windowId(of: folder) }

    /// The folder's history on the box, for the History popup: its closed chats (by box chat id)
    /// and, from 1.9, the past sessions its CLIs keep there, archived ones too.
    func closedHistory() async -> [SessionSummary] {
        guard let window = windowId else { return [] }
        let keeps = connection.keepsHistory
        async let open = connection.closedChats(windowId: window)
        async let archived = keeps ? connection.closedChats(windowId: window, archived: true) : []
        return (await open + archived).compactMap { session in
            guard let provider = Registry.provider(session.provider) else { return nil }
            return SessionSummary(
                id: session.id, agent: provider.historyAgent, title: session.title,
                updated: Date(timeIntervalSince1970: Double(session.updatedAt) / 1000), archived: session.archived)
        }
    }

    /// Why the History popup can't rename or archive here: a box older than 1.9. Nil when it can.
    var historyLocked: String? { connection.keepsHistory ? nil : "Update kore-host on \(alias) to rename or archive here" }

    /// A past chat back as a box chat (a closed one, or a session its CLI keeps), for a tab here.
    func openSession(_ session: SessionSummary) async -> Chat? {
        let provider = Registry.provider(for: session.agent)
        guard connection.keepsHistory else { return await reopen(session.id, provider: provider, title: session.title) }
        let args = ControlArgs(windowId: windowId, title: session.title, provider: provider.id, sessionId: session.id)
        guard case .success(let result) = await connection.history(.historyOpen, args), let chatId = result.chatId else { return nil }
        closedIds.remove(chatId)
        return chat(provider, id: chatId, title: session.title)
    }

    /// Renames or archives a past chat on the box; false when the box refused.
    func renameSession(_ id: String, to title: String) async -> Bool {
        if case .success = await connection.history(.historyRename, ControlArgs(windowId: windowId, title: title, sessionId: id)) { return true }
        return false
    }

    func archiveSession(_ id: String, _ on: Bool) async -> Bool {
        if case .success = await connection.history(.historyArchive, ControlArgs(windowId: windowId, on: on, sessionId: id)) { return true }
        return false
    }

    func tabClosed(_ chat: Chat) {
        guard let id = (chat.services as? BoxChatServices)?.chatId else { return }
        let connection = connection
        closedIds.insert(id)
        Task {
            // Through the chat's own call: the box closes it for good, so it doesn't come back.
            let result = await connection.call(id, .close)
            if result.ok || result.code == .goneChat { connection.cache.forget(chat: id) } else { closedIds.remove(id) }
        }
    }
}

/// The app's services for a chat on a box: the link is its backend; the rest is the app's, less
/// what belongs to this Mac's own CLIs (their account, Stay awake).
@MainActor
final class BoxChatServices: ChatServices {
    private let app = AppChatServices.shared
    private weak var binding: BoxBinding?
    let connection: HostConnection
    private let folder: String
    private(set) var chatId: String?
    /// Its chat, for the box's renames.
    private weak var chat: Chat?
    /// What a chat new from here is made with on the box (a fork's start).
    private let making: LinkChatBackend.Making?
    /// Its backend, for what the box keeps with the chat (1.9), and the draft the box last had.
    private weak var backend: LinkChatBackend?
    /// Being made on the box: its id isn't known here yet.
    var creating: Bool { backend?.creating ?? false }
    private var boxDraft = ""
    /// The CLI runs on the box, which sets its own instructions and gives it the `kore_app` server
    /// while Arsenal is on; the tier and Arsenal's notes go with each message (`LinkChatBackend`).
    var agentTools: Bool { true }
    var instructions: URL? { nil }

    init(binding: BoxBinding, chatId: String?, making: LinkChatBackend.Making? = nil) {
        self.binding = binding
        connection = binding.connection
        folder = binding.folder
        self.chatId = chatId
        self.making = making
    }

    func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend {
        var making = making ?? LinkChatBackend.Making(mode: options.mode, effort: options.effort)
        making.model = making.model ?? options.model
        let backend = LinkChatBackend(connection: connection, provider: provider, folder: folder, chatId: chatId, making: making)
        // A rename on the box (from another Mac, or its CLI's own title) shows in this tab.
        backend.onTitle = { [weak self] title in
            guard let chat = self?.chat, chat.title != title else { return }
            chat.adoptName(title)
        }
        backend.onCreated = { [weak self, weak backend] id in
            self?.chatId = id
            // What the box listed meanwhile, now this chat is known.
            self?.binding?.adoptChats()
            // A chat made here (a fork) keeps the point it started with on the box.
            if let chat = self?.chat, chat.context.autoCompactAt != nil { backend?.keepAutoCompact(chat.context.autoCompactAt) }
        }
        // 1.9: what the box keeps with the chat, changed by another client (or kept from before).
        backend.onAutoCompact = { [weak self] point in
            guard let chat = self?.chat, chat.context.autoCompactAt != point else { return }
            chat.setAutoCompact(point)
        }
        backend.onDraft = { [weak self, weak backend] text in
            guard let self, let chat else { return }
            let mine = Self.draftText(chat)
            defer { boxDraft = text }
            // What's typed here and not yet said to the box stays; an empty composer takes the box's.
            if mine.isEmpty || mine == boxDraft {
                if mine != text { chat.restoreDraft(text, commands: chat.controls.commands) }
            } else if text.isEmpty {
                backend?.keepDraft(mine)
            }
        }
        backend.onArsenal = { [weak self] tier in
            guard let chat = self?.chat, chat.arsenal?.rawValue != tier else { return }
            _ = Arsenal.shared.linkSet(tier.flatMap(ArsenalTier.init(rawValue:)), chat)
        }
        self.backend = backend
        // A turn's changed files under the folder, named as this window's file tabs name them.
        if let binding {
            let folder = binding.folder
            backend.localPath = { [weak binding] path in path.hasPrefix(folder + "/") ? binding?.standIn(path).path ?? path : path }
        }
        backend.arsenal = { [weak self] in self?.chat?.arsenal?.rawValue }
        return backend
    }

    /// The composer as one line of text: its command, then the draft (files stay on this Mac).
    static func draftText(_ chat: Chat) -> String {
        guard let command = chat.command else { return chat.draft }
        return "/" + command.name + (chat.draft.isEmpty ? "" : " " + chat.draft)
    }

    /// The composer changed: the box keeps it (half a second after typing stops).
    func draftChanged(_ chat: Chat) {
        let text = Self.draftText(chat)
        guard text != boxDraft else { return }
        boxDraft = text
        backend?.keepDraft(text)
    }

    /// The chat's Arsenal tier changed here: the box says it to its other clients.
    func arsenalChanged(_ chat: Chat) { backend?.sayArsenal(chat.arsenal?.rawValue) }

    func register(_ chat: Chat) {
        self.chat = chat
        if let chatId, let line = ChatPlaces.shared.takeNote(connection.alias, chatId) { chat.note(line) }
        chat.ownPopups()
        // Modes above Auto are set on the box itself: the picker doesn't offer them.
        chat.controls.levelCap = LinkPolicy.raiseCap.rawValue
        chat.controls.levelCapNote = "Set on \(connection.alias) itself"
    }
    func closed(_ chat: Chat) { app.closed(chat) }
    func planWindows(_ cli: String, _ snapshot: PlanSnapshot?) {}
    func makeTranscript() -> any ChatTranscript { app.makeTranscript() }
    func makeViewState() -> AnyObject { app.makeViewState() }
    func refreshAccount(_ cli: String) {}
    func modelsListed(_ cli: String, _ models: [ModelOption]) {}
    /// The box's own lists: its chats' pickers never take this Mac's, nor give it theirs.
    var modelScope: String? { connection.alias }
    /// The box runs the turn and watches it; a link that drops says so as the box's cue.
    var watchesStall: Bool { false }
    var onBox: Bool { true }
    func arsenalFollowMode(_ chat: Chat) { app.arsenalFollowMode(chat) }
    func tap(_ chat: Chat, _ event: ChatEvent) {
        app.tap(chat, event)
        // A turn may have changed files on a box that can't watch its copy, and in its explorer.
        if case .turnFinished = event {
            binding?.sync?.refresh()
            binding?.workspace?.boxTurnEnded()
        }
    }
    func log(_ name: String, _ fields: KeyValuePairs<String, String?>) { app.log(name, fields) }
    var timeReplay: Bool { app.timeReplay }
    func logReplay(_ took: Duration) { app.logReplay(took) }
    var isOnline: Bool { app.isOnline }
    var networkChanged: Notification.Name { app.networkChanged }
    func online() async { await app.online() }
    var awakeClock: (any AwakeClock)? { nil }
    var stayingAwake: Bool { false }
    func stayAwakeForReset() -> Bool { false }
    func releaseAwake(besides chat: Chat) {}
    func sleptThrough(since date: Date) -> Bool { false }
    func attachments(_ urls: [URL]) -> [Attachment] { app.attachments(urls) }
    func reattach(_ sent: [Attachment]) -> [Attachment] { app.reattach(sent) }
}

// MARK: - The window

/// A box folder's window. A place without a folder (none opens one now) closes.
struct BoxWindow: View {
    @Binding var place: BoxPlace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let folder = place.folder {
            FolderWindow(box: BoxBinding(alias: place.alias, folder: folder))
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

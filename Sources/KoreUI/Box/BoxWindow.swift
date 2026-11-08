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

/// One box folder's window: its connection, its chats made and closed there, and the title row's
/// one cue.
@MainActor
final class BoxBinding {
    let alias: String
    /// As the box names it.
    let folder: String
    let connection: HostConnection

    init(alias: String, folder: String) {
        self.alias = alias
        self.folder = folder
        connection = Self.connection(alias)
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

    /// The window's workspace, for the chats the box opens in this folder meanwhile.
    weak var workspace: Workspace?
    /// Chats whose tabs closed here: never adopted again, even before the box confirms.
    private var closedIds: Set<String> = []

    /// The folder as the box's window names it ("~/Code"), else its path.
    var shownFolder: String {
        let window = connection.folders.first { $0.path == folder }?.windowId
        return connection.windows.first { $0.id == window }?.path ?? folder
    }

    /// The folder's two-way sync with a Mac folder, while this window is open.
    private(set) var sync: HostSync?
    private var focus: NSObjectProtocol?

    func windowOpened() {
        connection.onSnapshot(key) { [weak self] in self?.adoptChats() }
        connection.retain()
        followPair()
    }

    func windowClosed() {
        connection.onSnapshot(key, nil)
        stopSync()
        connection.release()
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
        for workspace in Workspace.all.allObjects where !workspace.isClosed { workspace.box?.followPair() }
    }

    /// Chats in this folder the window doesn't show yet (opened on the box or elsewhere, or none
    /// known when the window opened) get tabs at the end; a lone empty tab gives way to them.
    private func adoptChats() {
        guard let workspace, !workspace.isClosed else { return }
        let shown = Set(workspace.tabs.compactMap { ($0.chat?.services as? BoxChatServices)?.chatId })
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

    /// The title row's cue: the box's name, or how long ago it last spoke while it can't be reached.
    var line: String {
        switch connection.phase {
        case .online, .idle: return alias
        case .refused(let why): return why.line(alias)
        case .connecting where connection.lastHeard == nil: return alias + " · connecting"
        case .connecting, .offline:
            guard let heard = connection.lastHeard else { return alias + " offline" }
            return alias + " offline · " + Self.when(heard)
        }
    }

    var online: Bool { connection.phase == .online }

    /// The folder label's hover line: "mybox · ~/Code/app · synced locally to ~/Desktop/app".
    var label: String { alias + " · " + shownFolder + (syncedTo.map { " · synced locally to " + $0 } ?? "") }

    /// The window's one cue, on the title row's box button: its line, marked while the box is
    /// offline or its sync has something to say.
    var cue: (line: String, marked: Bool) {
        if let notice = sync?.notice { return (alias + " · " + notice, true) }
        guard online else { return (line, true) }
        return (alias + " · " + (sync != nil ? "in sync" : shownFolder), false)
    }

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

    /// The folder's closed chats on the box, for the History popup: its sessions, by box chat id.
    func closedHistory() async -> [SessionSummary] {
        let window = connection.folders.first { $0.path == folder }?.windowId ?? connection.windows.first { $0.path == folder }?.id
        guard let window else { return [] }
        return await connection.closedChats(windowId: window).compactMap { session in
            guard let provider = Registry.provider(session.provider) else { return nil }
            return SessionSummary(
                id: session.id, agent: provider.historyAgent, title: session.title,
                updated: Date(timeIntervalSince1970: Double(session.updatedAt) / 1000))
        }
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
    /// The CLI runs on the box, which sets its own instructions; nothing of this Mac's reaches it.
    var agentTools: Bool { false }
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
        backend.onCreated = { [weak self] in self?.chatId = $0 }
        return backend
    }

    func register(_ chat: Chat) {
        self.chat = chat
        chat.ownPopups()
        // Modes above Auto are set on the box itself: the picker doesn't offer them.
        chat.controls.levelCap = LinkPolicy.raiseCap.rawValue
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
        // A turn may have changed files on a box that can't watch its copy.
        if case .turnFinished = event { binding?.sync?.refresh() }
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

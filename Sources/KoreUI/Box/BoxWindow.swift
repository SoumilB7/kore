import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import SwiftUI

// A window whose chats live on a box: File ▸ New Window on <alias>…, a folder picked from the
// box's list, then the folder window as for this Mac, its chats run through the link. Nothing here
// runs until such a window opens.

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

    /// The Mac's grant name on the box: `defaults write <Kore> boxGrant.<alias> <name>`, else
    /// `laptop`.
    static func grant(_ alias: String) -> String {
        UserDefaults.standard.string(forKey: "boxGrant." + alias) ?? HostConnection.defaultGrant
    }

    /// kore-host's path on the box: `defaults write <Kore> boxKoreHost.<alias> <path>`, else
    /// `~/.local/bin/kore-host`.
    static func command(_ alias: String) -> String {
        UserDefaults.standard.string(forKey: "boxKoreHost." + alias) ?? SSHTransport.defaultCommand
    }

    /// The window's key among the open workspaces: never a folder on this Mac's.
    var key: String { "box:" + alias + ":" + folder }

    /// A stand-in path whose last part is the folder's name: the window's title and the chats'
    /// folder. Nothing on this Mac is read or written there.
    var folderURL: URL { URL(fileURLWithPath: "/" + alias + "/" + folder.replacingOccurrences(of: "~", with: "home")) }

    /// The window's workspace, for the chats the box opens in this folder meanwhile.
    weak var workspace: Workspace?

    func windowOpened() {
        connection.onSnapshot(key) { [weak self] in self?.adoptChats() }
        connection.retain()
    }

    func windowClosed() {
        connection.onSnapshot(key, nil)
        connection.release()
    }

    /// Chats in this folder the window doesn't show yet (opened on the box or elsewhere, or none
    /// known when the window opened) get tabs at the end; a lone empty tab gives way to them.
    private func adoptChats() {
        guard let workspace, !workspace.isClosed else { return }
        let shown = Set(workspace.tabs.compactMap { ($0.chat?.services as? BoxChatServices)?.chatId })
        let tabs: [ChatTab] = connection.chats(in: folder).filter { !shown.contains($0.id) }.compactMap { meta in
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
        case .refused(let why): return why
        case .connecting where connection.lastHeard == nil: return alias + " · connecting"
        case .connecting, .offline:
            guard let heard = connection.lastHeard else { return alias + " offline" }
            return alias + " offline · " + Self.when(heard)
        }
    }

    var online: Bool { connection.phase == .online }

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

    private func chat(_ provider: Provider, id: String?, title: String?) -> Chat {
        let services = BoxChatServices(binding: self, chatId: id)
        let chat = Chat(
            provider: provider, folder: folderURL, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
            services: services)
        if let title, !title.isEmpty { chat.adoptName(title) }
        return chat
    }

    /// Its tab closed here: it closes on the box too.
    func tabClosed(_ chat: Chat) {
        guard let id = (chat.services as? BoxChatServices)?.chatId else { return }
        let connection = connection
        Task {
            _ = await connection.command { HostWire.command(id: $0, .control(.chatClose, ControlArgs(chatId: id, force: true))) }
            connection.cache.forget(chat: id)
        }
    }
}

/// The app's services for a chat on a box: the link is its backend; the rest is the app's, less
/// what belongs to this Mac's own CLIs (their account, Stay awake).
@MainActor
final class BoxChatServices: ChatServices {
    private let app = AppChatServices.shared
    private weak var binding: BoxBinding?
    private let connection: HostConnection
    private let folder: String
    private(set) var chatId: String?

    init(binding: BoxBinding, chatId: String?) {
        self.binding = binding
        connection = binding.connection
        folder = binding.folder
        self.chatId = chatId
    }

    func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend {
        let backend = LinkChatBackend(connection: connection, provider: provider, folder: folder, chatId: chatId, model: options.model)
        backend.onCreated = { [weak self] in self?.chatId = $0 }
        return backend
    }

    func register(_ chat: Chat) { chat.ownPopups() }
    func closed(_ chat: Chat) { app.closed(chat) }
    func planWindows(_ cli: String, _ snapshot: PlanSnapshot?) {}
    func makeTranscript() -> any ChatTranscript { app.makeTranscript() }
    func makeViewState() -> AnyObject { app.makeViewState() }
    func refreshAccount(_ cli: String) {}
    func modelsListed(_ cli: String, _ models: [ModelOption]) {}
    func arsenalFollowMode(_ chat: Chat) { app.arsenalFollowMode(chat) }
    func tap(_ chat: Chat, _ event: ChatEvent) { app.tap(chat, event) }
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

/// File ▸ New Window on <alias>…: the box's folders first, then that folder's window.
struct BoxWindow: View {
    @Binding var place: BoxPlace

    var body: some View {
        if let folder = place.folder {
            FolderWindow(box: BoxBinding(alias: place.alias, folder: folder))
        } else {
            BoxFolders(alias: place.alias) { place.folder = $0.path }
        }
    }
}

/// The box's folders, as `folders.list` gives them: a click opens one.
private struct BoxFolders: View {
    let alias: String
    let pick: (BoxFolder) -> Void
    @StateObject private var connection: Local<HostConnection>
    @StateObject private var folders: Local<[BoxFolder]>

    init(alias: String, pick: @escaping (BoxFolder) -> Void) {
        self.alias = alias
        self.pick = pick
        let connection = BoxBinding.connection(alias)
        _connection = StateObject(wrappedValue: Local(connection))
        _folders = StateObject(wrappedValue: Local(connection.folders))
    }

    var body: some View {
        let connection = connection.value
        VStack(spacing: Layout.Welcome.sectionGap) {
            VStack(spacing: Space.sm) {
                Text(alias).font(Chrome.display).foregroundStyle(Theme.text)
                Text(status(connection)).font(Chrome.body).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(folders.value, id: \.self) { folder in
                    Button { pick(folder) } label: {
                        HStack(spacing: Space.lg) {
                            Image(systemName: "folder").font(Chrome.label).foregroundStyle(Theme.secondary)
                            Text(folder.name).font(Chrome.bodyMedium).foregroundStyle(Theme.text)
                            Spacer(minLength: Space.xl)
                            Text(folder.path).font(Chrome.label).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
            }
            .frame(width: Layout.Welcome.contentWidth)
        }
        .padding(.vertical, Layout.Welcome.paddingV)
        .padding(.horizontal, Layout.Welcome.paddingH)
        .frame(minWidth: Layout.Welcome.width, minHeight: Layout.Welcome.minHeight)
        .navigationTitle(alias)
        .onAppear { connection.retain() }
        // A moment later, so the folder's window takes the link over without it dropping.
        .onDisappear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { connection.release() } }
        .task(id: connection.phase) {
            if connection.phase == .online { folders.value = await connection.listFolders() }
        }
    }

    private func status(_ connection: HostConnection) -> String {
        switch connection.phase {
        case .online: folders.value.isEmpty ? "No folders on \(alias)" : "Pick a folder"
        case .refused(let why): why
        case .offline: connection.lastHeard.map { "Offline · " + BoxBinding.when($0) } ?? "Can't reach \(alias)"
        case .idle, .connecting: "Connecting…"
        }
    }
}

/// The title row's one cue in a box's window, where a folder window names its folder: the box's
/// name, or "<alias> offline · 14:32" while it can't be reached.
struct BoxCue: View {
    let box: BoxBinding

    var body: some View {
        Text(box.line)
            .font(Chrome.label)
            .foregroundStyle(box.online ? Theme.secondary : Theme.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
            .help(box.folder)
    }
}

/// File ▸ New Window on <alias>…, one per host in `~/.ssh/config` (read, never written); more than
/// a few go in a submenu.
struct BoxWindowCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let aliases = SSHHosts.aliases()
        if aliases.count > 3 {
            Menu("New Window on Host") {
                ForEach(aliases, id: \.self) { alias in
                    Button("\(alias)…") { openWindow(value: BoxPlace(alias: alias)) }
                }
            }
        } else {
            ForEach(aliases, id: \.self) { alias in
                Button("New Window on \(alias)…") { openWindow(value: BoxPlace(alias: alias)) }
            }
        }
    }
}

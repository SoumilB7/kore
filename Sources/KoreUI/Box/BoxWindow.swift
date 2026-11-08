import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import SwiftUI

// A window whose chats live on a box: a folder picked from the box's list, then the folder window as for this Mac, its chats run through the link. Nothing here
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

    /// The folder as the box's window names it ("~/Code"), else its path.
    var shownFolder: String {
        let window = connection.folders.first { $0.path == folder }?.windowId
        return connection.windows.first { $0.id == window }?.path ?? folder
    }

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
    let connection: HostConnection
    private let folder: String
    private(set) var chatId: String?
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
    /// The box's own lists: its chats' pickers never take this Mac's, nor give it theirs.
    var modelScope: String? { connection.alias }
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

/// A box's window: its folders first, then that folder's window.
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
    /// Add folder…'s path while it's a field; nil while it's a row.
    @StateObject private var adding = Local<String?>(nil)
    /// Why the last path couldn't be added.
    @StateObject private var addFailed = Local<String?>(nil)
    @FocusState private var pathFocused: Bool

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
                if unreachable(connection) {
                    Button("Try again") { connection.retry() }.buttonStyle(SubtleButtonStyle(prominent: true)).padding(.top, Space.sm)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(folders.value, id: \.self) { folder in
                    row(icon: "folder", folder.name, detail: folder.path) { pick(folder) }
                }
                if connection.isOnline { addRow(connection) }
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

    private func row(icon: String, _ title: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.lg) {
                Image(systemName: icon).font(Chrome.label).foregroundStyle(Theme.secondary)
                Text(title).font(Chrome.bodyMedium).foregroundStyle(Theme.text)
                Spacer(minLength: Space.xl)
                if let detail { Text(detail).font(Chrome.label).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(SubtleButtonStyle())
    }

    /// Add folder…: a row, and clicked, a path field in its place (there's no Finder for the box),
    /// with one line under it.
    @ViewBuilder private func addRow(_ connection: HostConnection) -> some View {
        if let path = adding.value {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    TextField("", text: Binding(get: { path }, set: { adding.value = $0; addFailed.value = nil }), prompt: Text("~/Code/project").foregroundStyle(Theme.tertiary))
                        .textFieldStyle(.plain)
                        .font(Chrome.body)
                        .focused($pathFocused)
                        .fieldWell(focused: pathFocused)
                        .onSubmit { add(connection) }
                        .onExitCommand { adding.value = nil }
                    Button("Open") { add(connection) }.smallButton(prominent: true).disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(addFailed.value ?? "A folder already on \(alias)")
                    .font(Chrome.caption)
                    .foregroundStyle(addFailed.value == nil ? Theme.tertiary : Theme.danger)
                    .padding(.leading, Space.sm)
            }
            .onAppear { pathFocused = true }
        } else {
            row(icon: "plus", "Add folder…") { adding.value = "" }
        }
    }

    private func add(_ connection: HostConnection) {
        guard let path = adding.value, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            switch await connection.addFolder(path) {
            case .success(let folder):
                folders.value = connection.folders
                adding.value = nil
                pick(folder)
            case .failure(let refusal):
                addFailed.value = refusal.message
            }
        }
    }

    /// It can't be reached, or it refused this Mac: Try again shows.
    private func unreachable(_ connection: HostConnection) -> Bool {
        switch connection.phase {
        case .refused, .offline: true
        case .idle, .connecting, .online: false
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

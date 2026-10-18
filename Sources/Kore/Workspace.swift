import AppKit
import Foundation
import KoreCore
import Observation

/// A tab: empty (provider picker), showing a chat, one of a chat's sub-agents, or a file.
/// An agent tab holds its parent's chat and reads its stores, so it can't drift from it.
@MainActor @Observable
final class ChatTab: Identifiable {
    let id = UUID()
    var chat: Chat?
    /// Set for an agent tab: the sub-agent of `chat` it shows.
    var agent: String?
    /// Set for a file tab.
    var file: FileDocument?
    /// A file opened by a single click in the tree: the next one replaces it (italic title).
    var isPreview = false

    var isEmpty: Bool { chat == nil && file == nil }

    var title: String {
        if let file { return file.name }
        if let agent, let name = chat?.transcript.agent(agent)?.name { return name }
        return chat?.title ?? "New tab"
    }
}

/// The tabs of one folder window. The folder's chats live in the CLIs' own stores, so every
/// app (Kore, the VS Code extensions, the CLIs) sees the same list, shown in the history
/// popover. The tabs are what was open in this folder last time, restored as they were.
@MainActor @Observable
final class Workspace {
    let folder: URL
    private(set) var tabs: [ChatTab]
    private(set) var activeID: UUID
    /// Every chat the CLIs have for this folder, newest first, archived ones flagged.
    private(set) var chats: [SessionSummary] = []
    private(set) var loaded = false
    private var refreshing: Task<Void, Never>?
    /// The explorer's files; made when the explorer first opens or a file first shows.
    private(set) var files: FilesStore?
    var explorerOpen = false {
        didSet {
            if explorerOpen { _ = filesStore() }
            saveExplorer()
        }
    }
    var explorerWidth = Layout.Explorer.width {
        didSet { saveExplorer() }
    }
    /// ⌘P: files, or go to line (⌃G).
    var quickOpen: QuickOpenMode?
    /// What the sidebar shows: the tree, or Search (⇧⌘F).
    var sidebar = SidebarMode.explorer
    /// The Search view's state; made when Search first shows.
    private(set) var search: SearchStore?
    /// Files opened, most recent first (quick open's empty state).
    private(set) var recentFiles: [String] = []

    init(folder: URL, restore: Bool = true) {
        self.folder = folder
        let saved = restore ? Self.saved(for: folder) : nil
        var restored = saved?.tabs.map { Self.tab($0, in: folder) } ?? []
        // A file open twice (saved under two spellings of its path) comes back once.
        var seen: Set<String> = []
        restored.removeAll { tab in
            guard let path = tab.file?.path else { return false }
            return !seen.insert(path).inserted
        }
        if restored.isEmpty { restored = [ChatTab()] }
        tabs = restored
        activeID = restored[min(max(saved?.active ?? 0, 0), restored.count - 1)].id
        if restore, let explorer = Self.savedExplorer(for: folder) {
            explorerWidth = explorer.width
            explorerOpen = explorer.open
        }
        Self.all.add(self)
        // Restored file tabs follow the disk too.
        if tabs.contains(where: { $0.file != nil }) { _ = filesStore() }
    }

    var activeTab: ChatTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    func select(_ tab: ChatTab) {
        activeID = tab.id
        if let file = tab.file, explorerOpen, let files {
            Task { await files.reveal(file.path) }
        }
    }

    func newTab() {
        let tab = ChatTab()
        tabs.append(tab)
        activeID = tab.id
    }

    func start(_ provider: Provider, in tab: ChatTab) {
        tab.chat = Chat(provider: provider, folder: folder)
    }

    /// Shows a chat: its tab if already open, else the empty active tab or a new one.
    func open(_ session: SessionSummary) {
        if let tab = tab(for: session.id) {
            select(tab)
            return
        }
        if !activeTab.isEmpty { newTab() }
        activeTab.chat = chat(session)
    }

    /// Shows a chat's sub-agent in its own tab: its tab if already open, else a new one right
    /// after the parent's tab (or the parent's last agent tab), so the family sits together.
    func openAgent(_ id: String, of chat: Chat) {
        if let tab = tabs.first(where: { $0.chat === chat && $0.agent == id }) {
            select(tab)
            return
        }
        let tab = ChatTab()
        tab.chat = chat
        tab.agent = id
        let family = tabs.indices.filter { tabs[$0].chat === chat }
        tabs.insert(tab, at: (family.last ?? tabs.count - 1) + 1)
        activeID = tab.id
    }

    /// A fork of `chat` from one of its user messages, in a new tab right after it: the history
    /// before that message, the message itself in the composer (not sent), the same mode, and
    /// "<title> (fork)" (the Claude Code extension's fork).
    func fork(_ chat: Chat, _ start: ForkStart, text: String) {
        let title = "\(chat.title) (fork)"
        let fork: Chat
        switch start {
        case .pending(let point):
            fork = Chat(
                provider: chat.provider, folder: folder,
                resume: SessionSummary(id: point.from, agent: chat.provider.historyAgent, title: title, updated: .now),
                fork: point, forkedFrom: chat.title)
        case .fresh:
            fork = Chat(provider: chat.provider, folder: folder)
        }
        fork.controls.mode = chat.controls.mode
        fork.controls.planMode = chat.controls.planMode
        fork.draft = text
        if let probe = DevSnapshot.forkSend {
            // Test hook: send a probe in the fork, once its CLI is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                fork.draft = probe
                fork.send()
            }
        }
        let tab = ChatTab()
        tab.chat = fork
        let index = tabs.firstIndex { $0.chat === chat && $0.agent == nil } ?? tabs.count - 1
        tabs.insert(tab, at: index + 1)
        activeID = tab.id
    }

    /// The tab showing a chat itself (not one of its agents).
    func tab(of chat: Chat) -> ChatTab? {
        tabs.first { $0.chat === chat && $0.agent == nil }
    }

    /// Ends the tab's chat, and closes its agents' tabs with it. Closing an agent tab only
    /// closes the view. Closing the last tab leaves a fresh empty one.
    func close(_ tab: ChatTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let file = tab.file, file.isDirty, !Self.confirmClose(file) { return }
        if tab.agent == nil, let chat = tab.chat {
            for agentTab in tabs where agentTab.chat === chat && agentTab.agent != nil { remove(agentTab) }
        }
        remove(tab, at: tabs.firstIndex(where: { $0.id == tab.id }) ?? index)
    }

    private func remove(_ tab: ChatTab, at index: Int? = nil) {
        guard let index = index ?? tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.agent == nil, tab.file == nil { tab.chat?.close() }
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [ChatTab()] }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
    }

    func closeAll() {
        for tab in tabs where tab.agent == nil && tab.file == nil { tab.chat?.close() }
        files?.stop()
    }

    // MARK: - Files

    enum SidebarMode { case explorer, search }

    func searchStore() -> SearchStore {
        if let search { return search }
        let store = SearchStore(folder: folder)
        search = store
        return store
    }

    /// ⇧⌘F: the sidebar on Search, with the caret in its field and any one-line editor
    /// selection as the query.
    func showSearch() {
        explorerOpen = true
        sidebar = .search
        let store = searchStore()
        if let text = activeFile?.editor.textView, text.selectedRange().length > 0, text.selectedRange().length < 200 {
            let selected = (text.string as NSString).substring(with: text.selectedRange())
            if !selected.contains("\n") { store.text = selected }
        }
        store.focus()
    }

    func filesStore() -> FilesStore {
        if let files { return files }
        let store = FilesStore(folder: folder)
        store.onChange = { [weak self] paths in self?.diskChanged(paths) }
        files = store
        return store
    }

    /// Shows a file: its tab if open, else the preview tab (single click in the tree) or a
    /// new tab after the active one.
    /// `select`: a place to select once the editor shows (a search hit).
    func openFile(_ url: URL, preview: Bool = false, select place: FileDocument.Place? = nil) {
        _ = filesStore()
        // The real path, as the watcher and the tree see it.
        let path = realPath(url.path)
        remember(path)
        if let tab = tabs.first(where: { $0.file?.path == path }) {
            if !preview { tab.isPreview = false }
            if let place, let file = tab.file { file.reveal(place) }
            select(tab)
            return
        }
        let document = FileDocument(url: URL(fileURLWithPath: path))
        if let place { document.reveal(place) }
        if preview, let tab = tabs.first(where: { $0.isPreview && $0.file?.isDirty != true }) {
            tab.file = document
            select(tab)
            return
        }
        let tab = ChatTab()
        tab.file = document
        tab.isPreview = preview
        if tabs.count == 1, activeTab.isEmpty {
            // A lone empty tab gives its place to the file.
            tabs = [tab]
        } else {
            let index = tabs.firstIndex { $0.id == activeID } ?? tabs.count - 1
            tabs.insert(tab, at: index + 1)
        }
        select(tab)
    }

    func keep(_ tab: ChatTab) { tab.isPreview = false }

    // MARK: - Files the agents' turns changed

    /// A file changed by the running or latest turn of this window's chats (look §8): the
    /// counts add up across chats, and each chat that wrote it is named.
    struct Touch: Equatable {
        var added = 0
        var removed = 0
        var writing = false
        var agentIndex: Int?
        var agentName: String?
        var sources: [Source] = []

        struct Source: Equatable {
            let chat: String
            let turn: String
            let tab: UUID
        }

        var help: String { sources.map(\.chat).joined(separator: ", ") }
    }

    /// By real path; reading it tracks every open chat's turn.
    var turnTouches: [String: Touch] {
        var touches: [String: Touch] = [:]
        for tab in tabs where tab.agent == nil && tab.file == nil {
            guard let chat = tab.chat else { continue }
            for (path, file) in chat.transcript.turnChanges() {
                var touch = touches[path] ?? Touch()
                touch.added += file.added
                touch.removed += file.removed
                touch.writing = touch.writing || file.writing
                if let index = file.agentIndex {
                    touch.agentIndex = index
                    touch.agentName = file.agentName
                }
                touch.sources.append(Touch.Source(chat: "\(chat.provider.name) · \(chat.title)", turn: file.turn, tab: tab.id))
                touches[path] = touch
            }
        }
        return touches
    }

    /// The folders above changed files, for the tree's change points.
    static func folders(of touches: [String: Touch]) -> Set<String> {
        var folders: Set<String> = []
        for path in touches.keys {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > 1, folders.insert(folder).inserted {
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return folders
    }

    /// The changes a turn made to one file, for the changes modal.
    func changes(of path: String, in source: Touch.Source) -> [FileChange] {
        guard let chat = tabs.first(where: { $0.id == source.tab })?.chat else { return [] }
        return chat.transcript.changes(ofTurn: source.turn).filter { realPath($0.path) == path }
    }

    /// A file or folder was renamed in the explorer: open files under it follow.
    func renamed(_ old: String, to new: String) {
        for tab in tabs {
            guard let file = tab.file else { continue }
            if file.path == old {
                file.moved(to: URL(fileURLWithPath: new))
            } else if file.path.hasPrefix(old + "/") {
                file.moved(to: URL(fileURLWithPath: new + file.path.dropFirst(old.count)))
            }
        }
    }

    var activeFile: FileDocument? { activeTab.file }

    /// A path inside the folder, relative to it (resolving /tmp-style links).
    func relativePath(_ path: String) -> String {
        for root in [realPath(folder.path), folder.standardizedFileURL.path]
        where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    func saveAll() {
        for tab in tabs { if let file = tab.file, file.isDirty { file.save() } }
    }

    var hasUnsavedFiles: Bool { tabs.contains { $0.file?.isDirty == true } }

    var unsavedFiles: [FileDocument] { tabs.compactMap { $0.file?.isDirty == true ? $0.file : nil } }

    /// Every open folder window's workspace, for the quit check.
    static let all = NSHashTable<Workspace>.weakObjects()

    private func remember(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 20 { recentFiles.removeLast() }
    }

    private func diskChanged(_ paths: [String]) {
        let changed = Set(paths)
        for tab in tabs {
            guard let file = tab.file else { continue }
            if changed.contains(file.path) { file.diskChanged() }
        }
    }

    /// Save, don't save, or cancel; true when the tab may close.
    private static func confirmClose(_ file: FileDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(file.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return file.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private struct ExplorerState: Codable {
        var open: Bool
        var width: CGFloat
    }

    private static let explorerKey = "explorer"

    private func saveExplorer() {
        var all = UserDefaults.standard.dictionary(forKey: Self.explorerKey) ?? [:]
        all[folder.standardizedFileURL.path] = try? JSONEncoder().encode(ExplorerState(open: explorerOpen, width: explorerWidth))
        UserDefaults.standard.set(all, forKey: Self.explorerKey)
    }

    private static func savedExplorer(for folder: URL) -> ExplorerState? {
        let data = UserDefaults.standard.dictionary(forKey: explorerKey)?[folder.standardizedFileURL.path] as? Data
        return data.flatMap { try? JSONDecoder().decode(ExplorerState.self, from: $0) }
    }

    // MARK: - The folder's chats

    /// Re-reads both CLIs' chats for the folder (for the history popover).
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        let folder = folder
        var lists: [String: [SessionSummary]] = [:]
        await withTaskGroup(of: (String, [SessionSummary]?).self) { group in
            for provider in Registry.all {
                group.addTask { (provider.id, await provider.sessions(folder)) }
            }
            // Each CLI's list shows as it comes (Claude's is a quick file read; Codex asks its
            // app-server). A CLI that hasn't answered keeps what was shown.
            for await (id, list) in group {
                if let list { lists[id] = list }
                let shown = chats
                chats = Registry.all.flatMap { provider in
                    lists[provider.id] ?? shown.filter { $0.agent == provider.historyAgent }
                }
                .sorted { $0.updated > $1.updated }
            }
        }
        if !loaded { reconcileRestored(listed: Set(lists.keys)) }
        loaded = true
    }

    /// Restored tabs against the CLIs' lists: chats archived or deleted elsewhere since last
    /// time are dropped, and titles renamed elsewhere are taken up. (Tabs of a CLI whose list
    /// couldn't be read are left alone.)
    private func reconcileRestored(listed: Set<String>) {
        let byId = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tab in tabs where tab.agent == nil {
            guard let chat = tab.chat, chat.resumed, let id = chat.sessionId else { continue }
            if let session = byId[id] {
                if session.archived { close(tab) } else { chat.adoptName(session.title) }
            } else if listed.contains(chat.provider.id) {
                close(tab)
            }
        }
    }

    /// Archives a chat in its CLI (Codex: `thread/archive`; Claude has no archive of its own, so
    /// Kore keeps a hidden list, as the Claude Code extension does) and closes its tab.
    func archive(_ session: SessionSummary) async {
        if let tab = tab(for: session.id) { close(tab) }
        await Registry.provider(for: session.agent).setArchived(session.id, true, folder)
        setArchived(session.id, true)
    }

    /// Renames a chat through its CLI. An open tab's chat does it directly; a chat that isn't
    /// open is resumed just long enough to rename it.
    func rename(_ session: SessionSummary, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = chats.firstIndex(where: { $0.id == session.id }) {
            let old = chats[index]
            chats[index] = SessionSummary(id: old.id, agent: old.agent, title: name, updated: old.updated, archived: old.archived)
        }
        if let chat = tab(for: session.id)?.chat {
            await chat.applyRename(name)
        } else {
            let chat = chat(session)
            await chat.applyRename(name)
            chat.close()
        }
    }

    /// Brings an archived chat back and opens it.
    func unarchive(_ session: SessionSummary) async {
        await Registry.provider(for: session.agent).setArchived(session.id, false, folder)
        setArchived(session.id, false)
        open(session)
    }

    private func setArchived(_ id: String, _ archived: Bool) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].archived = archived
    }

    private func tab(for sessionId: String) -> ChatTab? {
        tabs.first { $0.chat?.sessionId == sessionId && $0.agent == nil }
    }

    private func chat(_ session: SessionSummary) -> Chat {
        Chat(provider: Registry.provider(for: session.agent), folder: folder, resume: session)
    }

    // MARK: - Open tabs

    /// The folder's open tabs, kept so its window reopens with what was open last time, not
    /// every chat. A restored chat starts its CLI only once its tab is shown.
    struct Saved: Codable, Equatable {
        struct Tab: Codable, Equatable {
            /// `Provider` raw value; nil for an empty tab.
            var provider: String?
            /// nil for a chat with nothing in it yet: it comes back as a fresh chat.
            var session: String?
            var title: String?
            /// A file tab's path.
            var file: String?
        }

        var tabs: [Tab]
        var active: Int
    }

    /// Agent tabs and preview tabs aren't saved: they come back by opening them again.
    var saved: Saved {
        let kept = tabs.filter { $0.agent == nil && !$0.isPreview }
        return Saved(
            tabs: kept.map { tab in
                if let file = tab.file { return Saved.Tab(file: file.path) }
                guard let chat = tab.chat else { return Saved.Tab() }
                let resumable = chat.hasConversation ? chat.sessionId : nil
                return Saved.Tab(provider: chat.provider.rawValue, session: resumable, title: resumable.map { _ in chat.title })
            },
            active: kept.firstIndex { $0.id == activeID } ?? kept.firstIndex { $0.chat === activeTab.chat } ?? 0)
    }

    func save() {
        var all = UserDefaults.standard.dictionary(forKey: Self.savedKey) ?? [:]
        all[folder.standardizedFileURL.path] = try? JSONEncoder().encode(saved)
        UserDefaults.standard.set(all, forKey: Self.savedKey)
    }

    private static let savedKey = "openTabs"

    private static func saved(for folder: URL) -> Saved? {
        let data = UserDefaults.standard.dictionary(forKey: savedKey)?[folder.standardizedFileURL.path] as? Data
        return data.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    private static func tab(_ saved: Saved.Tab, in folder: URL) -> ChatTab {
        let tab = ChatTab()
        if let file = saved.file {
            tab.file = FileDocument(url: URL(fileURLWithPath: file))
            return tab
        }
        guard let provider = saved.provider.flatMap(Provider.init(rawValue:)) else { return tab }
        let session = saved.session.map {
            SessionSummary(
                id: $0, agent: provider.historyAgent, title: saved.title ?? provider.name, updated: .now)
        }
        tab.chat = Chat(provider: provider, folder: folder, resume: session)
        return tab
    }
}

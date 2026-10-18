import Foundation
import KoreCore
import Observation

/// A tab: empty (provider picker) or showing a chat.
@MainActor @Observable
final class ChatTab: Identifiable {
    let id = UUID()
    var chat: ChatModel?

    var title: String { chat?.title ?? "New tab" }
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

    init(folder: URL, restore: Bool = true) {
        self.folder = folder
        let saved = restore ? Self.saved(for: folder) : nil
        var restored = saved?.tabs.map { Self.tab($0, in: folder) } ?? []
        if restored.isEmpty { restored = [ChatTab()] }
        tabs = restored
        activeID = restored[min(max(saved?.active ?? 0, 0), restored.count - 1)].id
    }

    var activeTab: ChatTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    func select(_ tab: ChatTab) { activeID = tab.id }

    func newTab() {
        let tab = ChatTab()
        tabs.append(tab)
        activeID = tab.id
    }

    func start(_ provider: Provider, in tab: ChatTab) {
        tab.chat = ChatModel(provider: provider, folder: folder)
    }

    /// Shows a chat: its tab if already open, else the empty active tab or a new one.
    func open(_ session: SessionSummary) {
        if let tab = tab(for: session.id) {
            select(tab)
            return
        }
        if activeTab.chat != nil { newTab() }
        activeTab.chat = chat(session)
    }

    /// Ends the tab's chat. Closing the last tab leaves a fresh empty one.
    func close(_ tab: ChatTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.chat?.close()
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [ChatTab()] }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
    }

    func closeAll() {
        for tab in tabs { tab.chat?.close() }
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
        let hidden = ClaudeArchive.ids
        let claude = await Task.detached { ClaudeHistory.sessions(in: folder) }.value.map { session in
            var session = session
            session.archived = hidden.contains(session.id)
            return session
        }
        // Claude's list is a quick file read; show it before Codex's app-server answers.
        if !loaded {
            chats = (claude + chats.filter { $0.agent == .codex }).sorted { $0.updated > $1.updated }
        }
        let codexThreads = try? await CodexHistory.threads(in: folder)
        chats = (claude + (codexThreads ?? [])).sorted { $0.updated > $1.updated }
        if !loaded { reconcileRestored(codexListed: codexThreads != nil) }
        loaded = true
    }

    /// Restored tabs against the CLIs' list: chats archived or deleted elsewhere since last
    /// time are dropped, and titles renamed elsewhere are taken up. (Codex tabs are left alone
    /// if its list couldn't be read.)
    private func reconcileRestored(codexListed: Bool) {
        let byId = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tab in tabs {
            guard let chat = tab.chat, chat.resumed, let id = chat.sessionId else { continue }
            if let session = byId[id] {
                if session.archived { close(tab) } else { chat.adoptName(session.title) }
            } else if chat.provider == .claude || codexListed {
                close(tab)
            }
        }
    }

    /// Archives a chat in its CLI (Codex: `thread/archive`; Claude has no archive of its own, so
    /// Kore keeps a hidden list, as the Claude Code extension does) and closes its tab.
    func archive(_ session: SessionSummary) async {
        if let tab = tab(for: session.id) { close(tab) }
        switch session.agent {
        case .claude: ClaudeArchive.set(session.id, archived: true)
        case .codex: try? await CodexHistory.archive(session.id, in: folder)
        }
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
        switch session.agent {
        case .claude: ClaudeArchive.set(session.id, archived: false)
        case .codex: try? await CodexHistory.unarchive(session.id, in: folder)
        }
        setArchived(session.id, false)
        open(session)
    }

    private func setArchived(_ id: String, _ archived: Bool) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].archived = archived
    }

    private func tab(for sessionId: String) -> ChatTab? {
        tabs.first { $0.chat?.sessionId == sessionId }
    }

    private func chat(_ session: SessionSummary) -> ChatModel {
        ChatModel(provider: session.agent == .claude ? .claude : .codex, folder: folder, resume: session)
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
        }

        var tabs: [Tab]
        var active: Int
    }

    var saved: Saved {
        Saved(
            tabs: tabs.map { tab in
                guard let chat = tab.chat else { return Saved.Tab() }
                let resumable = chat.hasConversation ? chat.sessionId : nil
                return Saved.Tab(provider: chat.provider.rawValue, session: resumable, title: resumable.map { _ in chat.title })
            },
            active: tabs.firstIndex { $0.id == activeID } ?? 0)
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
        guard let provider = saved.provider.flatMap(Provider.init(rawValue:)) else { return tab }
        let session = saved.session.map {
            SessionSummary(
                id: $0, agent: provider == .claude ? .claude : .codex, title: saved.title ?? provider.name, updated: .now)
        }
        tab.chat = ChatModel(provider: provider, folder: folder, resume: session)
        return tab
    }
}

/// Archived Claude sessions. The Claude CLI has no archive for local sessions (each of its
/// clients keeps a hidden list; the VS Code extension's is `hiddenSessionIds`), so this is Kore's.
enum ClaudeArchive {
    private static let key = "archivedClaudeSessions"

    static var ids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func set(_ id: String, archived: Bool) {
        var ids = ids
        if archived { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}

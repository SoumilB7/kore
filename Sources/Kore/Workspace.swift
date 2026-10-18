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
/// app (Kore, the VS Code extensions, the CLIs) sees the same list: each one that isn't
/// archived is a tab. Closing a tab only hides it for this window; archiving is the CLIs'.
@MainActor @Observable
final class Workspace {
    let folder: URL
    private(set) var tabs: [ChatTab]
    private(set) var activeID: UUID
    /// Every chat the CLIs have for this folder, newest first, archived ones flagged.
    private(set) var chats: [SessionSummary] = []
    private(set) var loaded = false
    /// Chats whose tab was closed in this window; a refresh doesn't bring them back.
    private var closed: Set<String> = []
    private var refreshing: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        let tab = ChatTab()
        tabs = [tab]
        activeID = tab.id
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
        closed.remove(session.id)
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
        if let id = tab.chat?.sessionId { closed.insert(id) }
        tab.chat?.close()
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [ChatTab()] }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
    }

    func closeAll() {
        for tab in tabs { tab.chat?.close() }
    }

    // MARK: - The folder's chats

    /// Re-reads both CLIs' chats for the folder and adds a tab for each new one (newest first,
    /// before the others). A chat starts its CLI only once its tab is shown.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        let folder = folder
        let claude = await Task.detached { ClaudeHistory.sessions(in: folder) }.value
        let codex = (try? await CodexHistory.threads(in: folder)) ?? []
        let hidden = ClaudeArchive.ids
        chats = (claude.map { session in
            var session = session
            session.archived = hidden.contains(session.id)
            return session
        } + codex).sorted { $0.updated > $1.updated }

        let fresh = chats.filter { !$0.archived && !closed.contains($0.id) && tab(for: $0.id) == nil }
        defer { loaded = true }
        guard !fresh.isEmpty else { return }
        // The window's untouched starting tab gives way to the folder's chats.
        let placeholder = !loaded && tabs.count == 1 && tabs[0].chat == nil ? tabs[0] : nil
        let added = fresh.map { session in
            let tab = ChatTab()
            tab.chat = chat(session)
            return tab
        }
        tabs.insert(contentsOf: added, at: 0)
        if let placeholder {
            tabs.removeAll { $0.id == placeholder.id }
            activeID = added[0].id
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

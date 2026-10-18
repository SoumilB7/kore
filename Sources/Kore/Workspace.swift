import Foundation
import KoreCore
import Observation

/// A tab: empty (provider picker), showing a chat, or showing one of a chat's sub-agents.
/// An agent tab holds its parent's chat and reads its stores, so it can't drift from it.
@MainActor @Observable
final class ChatTab: Identifiable {
    let id = UUID()
    var chat: Chat?
    /// Set for an agent tab: the sub-agent of `chat` it shows.
    var agent: String?

    var title: String {
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
        tab.chat = Chat(provider: provider, folder: folder)
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

    /// The tab showing a chat itself (not one of its agents).
    func tab(of chat: Chat) -> ChatTab? {
        tabs.first { $0.chat === chat && $0.agent == nil }
    }

    /// Ends the tab's chat, and closes its agents' tabs with it. Closing an agent tab only
    /// closes the view. Closing the last tab leaves a fresh empty one.
    func close(_ tab: ChatTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.agent == nil, let chat = tab.chat {
            for agentTab in tabs where agentTab.chat === chat && agentTab.agent != nil { remove(agentTab) }
        }
        remove(tab, at: tabs.firstIndex(where: { $0.id == tab.id }) ?? index)
    }

    private func remove(_ tab: ChatTab, at index: Int? = nil) {
        guard let index = index ?? tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.agent == nil { tab.chat?.close() }
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [ChatTab()] }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
    }

    func closeAll() {
        for tab in tabs where tab.agent == nil { tab.chat?.close() }
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
        }

        var tabs: [Tab]
        var active: Int
    }

    /// Agent tabs aren't saved: they come back by opening the agent again.
    var saved: Saved {
        let kept = tabs.filter { $0.agent == nil }
        return Saved(
            tabs: kept.map { tab in
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
        guard let provider = saved.provider.flatMap(Provider.init(rawValue:)) else { return tab }
        let session = saved.session.map {
            SessionSummary(
                id: $0, agent: provider.historyAgent, title: saved.title ?? provider.name, updated: .now)
        }
        tab.chat = Chat(provider: provider, folder: folder, resume: session)
        return tab
    }
}

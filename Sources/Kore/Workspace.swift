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

/// The tabs of one folder window.
@MainActor @Observable
final class Workspace {
    let folder: URL
    private(set) var tabs: [ChatTab]
    private(set) var activeID: UUID

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

    /// Shows a past session: its tab if already open, else the empty active tab or a new one.
    func open(_ session: SessionSummary) {
        if let tab = tabs.first(where: { $0.chat?.sessionId == session.id }) {
            select(tab)
            return
        }
        if activeTab.chat != nil { newTab() }
        tab(activeTab, resume: session)
    }

    private func tab(_ tab: ChatTab, resume session: SessionSummary) {
        let provider: Provider = session.agent == .claude ? .claude : .codex
        tab.chat = ChatModel(provider: provider, folder: folder, resume: session)
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
}

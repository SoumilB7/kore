import Foundation
import HostClient
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// A chat renamed in History is renamed in its open tab, and a tab renamed shows in History: on a
/// box window and on a Mac folder's.
@Suite("history rename and tab title") @MainActor
struct HistoryRenameTests {
    /// A box that never answers (nothing dials over SSH): calls to it wait.
    final class Silent: HostTransport, @unchecked Sendable {
        let events = AsyncStream<TransportEvent> { $0.finish() }
        struct Down: Error {}
        func start() throws { throw Down() }
        func send(_ payload: Data) {}
        func close() {}
    }

    private func boxRig(_ alias: String) -> (Workspace, ChatTab) {
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: FileManager.default.temporaryDirectory.appendingPathComponent("kore-rename-\(UUID().uuidString)"))) { Silent() }
        HostConnection.adopt(connection)
        let box = BoxBinding(alias: alias, folder: "/home/me/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        box.workspace = workspace
        let tab = ChatTab()
        tab.chat = Chat(
            provider: .claude, folder: box.folderURL, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
            services: BoxChatServices(binding: box, chatId: "c1"))
        tab.chat?.adoptName("ComplianceOS basecamp")
        workspace.tabs = [tab]
        return (workspace, tab)
    }

    @Test func aBoxChatRenamedInHistoryRenamesItsOpenTab() async throws {
        let (workspace, tab) = boxRig("renamebox-\(UUID().uuidString.prefix(6))")
        let row = SessionSummary(id: "c1", agent: .claude, title: "ComplianceOS basecamp", updated: .now)
        #expect(workspace.openTab(for: "c1") === tab)
        // The box answers later (it never does here); the tab has the name at once.
        let renaming = Task { await workspace.rename(row, to: "Main-struc") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(tab.chat?.title == "Main-struc")
        renaming.cancel()
        // A row of another chat leaves the tab alone.
        #expect(workspace.openTab(for: "c9") == nil)
    }

    @Test func aBoxTabRenamedShowsInHistory() {
        let (workspace, tab) = boxRig("renamebox-\(UUID().uuidString.prefix(6))")
        let rows = [
            SessionSummary(id: "c1", agent: .claude, title: "ComplianceOS basecamp", updated: .now),
            SessionSummary(id: "s2", agent: .claude, title: "Other work", updated: .now),
        ]
        tab.chat?.adoptName("Main-struc")
        #expect(workspace.historyTitles(rows).map(\.title) == ["Main-struc", "Other work"])
    }

    @Test func aMacTabRenamedShowsInHistoryAndHistoryFindsItsTab() {
        let workspace = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-history-rename"), restore: false)
        let tab = ChatTab()
        let chat = Chat(provider: .claude, folder: workspace.folder)
        chat.status.apply(.sessionIdentified("s1"))
        tab.chat = chat
        workspace.tabs = [tab]
        let rows = [SessionSummary(id: "s1", agent: .claude, title: "First ask", updated: .now)]
        // Not named yet: the CLI's own title stays.
        #expect(workspace.historyTitles(rows).map(\.title) == ["First ask"])
        chat.adoptName("Renamed in the tab")
        #expect(workspace.historyTitles(rows).map(\.title) == ["Renamed in the tab"])
        // History's rename goes to this tab's chat (`applyRename`).
        #expect(workspace.openTab(for: "s1") === tab)
        // A Mac window has no box chat ids.
        #expect(workspace.openTab(for: "c1") == nil)
    }
}

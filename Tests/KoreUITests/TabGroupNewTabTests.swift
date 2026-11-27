import Foundation
@testable import src
import Testing

@testable import KoreUI

/// A new tab opened from a tab in a group goes right after the group, which stays whole (owner,
/// 0.3.10: "whenever I open a file or add a chat in between of a chat of a group, the rest of the
/// chats of that group are unloaded"). Before, the new tab went in after the front tab, and the
/// group's tidy-up let every member after it go.
@MainActor
@Suite(.serialized)
struct TabGroupNewTabTests {
    /// Four tabs, the first three grouped, the middle one in front.
    private func grouped() -> (Workspace, UUID) {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        for _ in 1..<4 { workspace.newTab() }
        let tabs = workspace.tabs
        workspace.group(tabs[1], onto: tabs[0])
        workspace.group(tabs[2], onto: tabs[1])
        workspace.select(tabs[1])
        return (workspace, workspace.tabGroups.member[tabs[0].id]!)
    }

    private func members(_ workspace: Workspace, _ group: UUID) -> [Int] {
        workspace.tabs.indices.filter { workspace.tabGroups.member[workspace.tabs[$0].id] == group }
    }

    private func index(_ workspace: Workspace, _ tab: ChatTab) -> Int? { workspace.tabs.firstIndex { $0 === tab } }

    @Test func aFileOpenedFromTheGroupsMiddleGoesRightAfterTheGroup() throws {
        let (workspace, group) = grouped()
        let members = workspace.tabs.prefix(3).map(\.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString).md")
        try "# Notes\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        workspace.openFile(url)
        #expect(index(workspace, workspace.activeTab) == 3)
        #expect(workspace.activeTab.file != nil && workspace.tabGroups.member[workspace.activeTab.id] == nil)
        #expect(self.members(workspace, group) == [0, 1, 2])
        #expect(workspace.tabs.prefix(3).map(\.id) == members)
        workspace.closeAll()
    }

    @Test func aNewChatFromTheGroupGoesRightAfterItNotAtTheEnd() {
        let (workspace, group) = grouped()
        workspace.newTab()
        #expect(index(workspace, workspace.activeTab) == 3)
        #expect(workspace.tabs.count == 5)
        #expect(members(workspace, group) == [0, 1, 2])
        workspace.closeAll()
    }

    @Test func aFoldedGroupStaysFoldedAndWhole() {
        let (workspace, group) = grouped()
        workspace.tabGroups.update(group) { $0.folded = true }
        workspace.newTab()
        #expect(workspace.tabGroups.group(group)?.folded == true)
        #expect(members(workspace, group) == [0, 1, 2])
        workspace.closeAll()
    }

    @Test func fromATabOutsideAGroupNewTabsGoWhereTheyDid() {
        let (workspace, group) = grouped()
        workspace.select(workspace.tabs[3])
        workspace.newTab()
        #expect(index(workspace, workspace.activeTab) == 4)
        #expect(members(workspace, group) == [0, 1, 2])
        workspace.closeAll()
    }

    @Test func aPlaceInsideAGroupBecomesJustPastIt() {
        let (workspace, group) = grouped()
        #expect(workspace.newTabIndex(1) == 3)
        #expect(workspace.newTabIndex(2) == 3)
        // At its edges, outside it already.
        #expect(workspace.newTabIndex(0) == 0)
        #expect(workspace.newTabIndex(3) == 3)
        #expect(workspace.newTabIndex(4) == 4)
        // From a member, past the group wherever it was wanted.
        #expect(workspace.newTabIndex(4, from: workspace.tabs[0]) == 3)
        #expect(members(workspace, group) == [0, 1, 2])
        workspace.closeAll()
    }

    @Test func aSubAgentsTabJoinsItsChatsGroupBesideIt() {
        let (workspace, group) = grouped()
        let chat = Chat(provider: .claude, folder: workspace.folder)
        workspace.tabs[1].chat = chat
        workspace.openAgent("agent-1", of: chat)
        #expect(index(workspace, workspace.activeTab) == 2)
        #expect(workspace.tabGroups.member[workspace.activeTab.id] == group)
        #expect(members(workspace, group) == [0, 1, 2, 3])
        workspace.closeAll()
    }

    @Test func anArsenalGroupStillPutsTheTabInside() {
        let (workspace, group) = grouped()
        workspace.newTab()
        let tab = workspace.activeTab
        workspace.add(tab, to: group)
        #expect(workspace.tabGroups.member[tab.id] == group)
        #expect(members(workspace, group) == [0, 1, 2, 3])
        workspace.closeAll()
    }
}

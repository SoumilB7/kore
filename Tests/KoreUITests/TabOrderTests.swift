import Foundation
import Testing

@testable import KoreUI

/// Moving tabs: a drag in the tab bar, ⌃⇧⇟ and ⌃⇧⇞.
@MainActor
struct TabOrderTests {
    private func workspace(tabs count: Int) -> Workspace {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        for _ in 1..<count { workspace.newTab() }
        return workspace
    }

    @Test func movingRightAndLeftKeepsEveryTab() {
        let workspace = workspace(tabs: 4)
        let ids = workspace.tabs.map(\.id)
        workspace.moveTab(workspace.tabs[0], to: 2)
        #expect(workspace.tabs.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
        workspace.moveTab(workspace.tabs[3], to: 0)
        #expect(workspace.tabs.map(\.id) == [ids[3], ids[1], ids[2], ids[0]])
    }

    @Test func movesStopAtTheEnds() {
        let workspace = workspace(tabs: 3)
        let ids = workspace.tabs.map(\.id)
        workspace.moveTab(workspace.tabs[1], to: 9)
        #expect(workspace.tabs.map(\.id) == [ids[0], ids[2], ids[1]])
        workspace.moveTab(workspace.tabs[2], to: -4)
        #expect(workspace.tabs.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func theActiveTabMovesOneStep() {
        let workspace = workspace(tabs: 3)
        let active = workspace.tabs[2]
        workspace.select(active)
        workspace.moveActive(by: -1)
        #expect(workspace.tabs[1].id == active.id)
        workspace.moveActive(by: -1)
        workspace.moveActive(by: -1)
        #expect(workspace.tabs[0].id == active.id)
        workspace.moveActive(by: 1)
        #expect(workspace.tabs[1].id == active.id)
    }

    @Test func aMovedPreviewTabIsKept() {
        let workspace = workspace(tabs: 2)
        let tab = workspace.tabs[1]
        tab.isPreview = true
        workspace.moveTab(tab, to: 0)
        #expect(!tab.isPreview)
    }
}

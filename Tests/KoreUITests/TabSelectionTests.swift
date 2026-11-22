import AppKit
import Foundation
import Testing

@testable import KoreUI

/// Browser-style multi-select in the strip: ⇧-click a range from the active tab, ⌘-click one
/// tab, a plain click or Esc clears; the picked tabs close, group and move as one.
@MainActor @Suite(.serialized)
struct TabSelectionTests {
    private func workspace(tabs count: Int) -> Workspace {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        for _ in 1..<count { workspace.newTab() }
        return workspace
    }

    private func picked(_ workspace: Workspace) -> [Int] {
        workspace.tabs.indices.filter { workspace.selection.contains(workspace.tabs[$0].id) }
    }

    @Test func clicksReadTheirKeys() {
        #expect(Workspace.TabClick.of([]) == .select)
        #expect(Workspace.TabClick.of(nil) == .select)
        #expect(Workspace.TabClick.of(.shift) == .range)
        #expect(Workspace.TabClick.of(.command) == .toggle)
        #expect(Workspace.TabClick.of([.command, .shift]) == .select)
        #expect(Workspace.TabClick.of([.shift, .capsLock]) == .range)
        #expect(TabKey.of("\u{1b}", keyCode: 53, modifiers: []) == .escape)
        #expect(TabKey.of("\u{1b}", keyCode: 53, modifiers: .shift) == nil)
    }

    @Test func shiftClickPicksTheRangeFromTheActiveTabEitherWay() {
        let workspace = workspace(tabs: 6)
        let t = workspace.tabs
        workspace.select(t[2])
        workspace.click(t[4], .range)
        #expect(picked(workspace) == [2, 3, 4])
        #expect(workspace.activeTab === t[2])
        // Another ⇧-click: a new range from the same active tab, not added to the last.
        workspace.click(t[0], .range)
        #expect(picked(workspace) == [0, 1, 2])
        #expect(workspace.selectedTabs.map(\.id) == [t[0].id, t[1].id, t[2].id])
        // ⇧-click on the active tab itself: one tab, none picked.
        workspace.click(t[2], .range)
        #expect(workspace.selection.isEmpty)
        #expect(workspace.selectedTabs.map(\.id) == [t[2].id])
    }

    @Test func commandClickTogglesOneTabWithNoRange() {
        let workspace = workspace(tabs: 5)
        let t = workspace.tabs
        workspace.select(t[0])
        workspace.click(t[2], .toggle)
        #expect(picked(workspace) == [0, 2])
        workspace.click(t[4], .toggle)
        #expect(picked(workspace) == [0, 2, 4])
        workspace.click(t[2], .toggle)
        #expect(picked(workspace) == [0, 4])
        // The active tab stays: ⌘-click on it changes nothing.
        workspace.click(t[0], .toggle)
        #expect(picked(workspace) == [0, 4])
        // The last other one taken away: none picked.
        workspace.click(t[4], .toggle)
        #expect(workspace.selection.isEmpty)
    }

    @Test func aPlainClickASwitchOrEscClears() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        workspace.select(t[0])
        workspace.click(t[2], .range)
        // A plain click on a picked tab: that tab alone.
        workspace.click(t[1], .select)
        #expect(workspace.selection.isEmpty && workspace.activeTab === t[1])
        workspace.click(t[3], .range)
        // A plain click on the active tab clears too.
        workspace.click(t[1], .select)
        #expect(workspace.selection.isEmpty)
        workspace.click(t[3], .range)
        workspace.selectAdjacent(1)
        #expect(workspace.selection.isEmpty)
        workspace.click(t[0], .toggle)
        workspace.clearSelection()
        #expect(workspace.selection.isEmpty)
    }

    @Test func aRangeRunsAcrossGroupsAndSkipsAFoldedGroupsHiddenTabs() {
        let workspace = workspace(tabs: 7)
        let t = workspace.tabs
        let a = workspace.group(t[2], onto: t[1])!
        let b = workspace.group(t[5], onto: t[4])!
        workspace.select(t[0])
        workspace.click(t[5], .range)
        #expect(picked(workspace) == [0, 1, 2, 3, 4, 5])
        workspace.toggleFold(b)
        workspace.click(t[6], .range)
        // Group b folded: its tabs aren't in the strip.
        #expect(picked(workspace) == [0, 1, 2, 3, 6])
        #expect(workspace.tabGroups.group(a)?.folded == false)
    }

    @Test func groupingPicksMakesOneGroupSideBySide() {
        let workspace = workspace(tabs: 5)
        let t = workspace.tabs
        workspace.select(t[0])
        workspace.click(t[3], .toggle)
        let made = workspace.newGroup(with: workspace.selectedTabs)!
        #expect(workspace.members(of: made).map(\.id) == [t[0].id, t[3].id])
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[3].id, t[1].id, t[2].id, t[4].id])
        // A range into that group.
        workspace.click(t[2], .toggle)
        workspace.click(t[4], .toggle)
        workspace.add(workspace.selectedTabs.filter { workspace.tabGroups.member[$0.id] == nil }, to: made)
        #expect(workspace.members(of: made).count == 4)
        #expect(workspace.tabGroups.groups.count == 1)
        workspace.removeFromGroup(workspace.selectedTabs)
        #expect(workspace.tabGroups.isEmpty)
    }

    @Test func picksDraggedLandTogetherInTheirOrder() {
        let workspace = workspace(tabs: 6)
        let t = workspace.tabs
        workspace.select(t[1])
        workspace.click(t[3], .toggle)
        // t[3] dragged to the end: t[1] goes just before it.
        workspace.moveTabs(workspace.selectedTabs, with: t[3], to: 5, group: nil)
        #expect(workspace.tabs.map(\.id) == [t[0], t[2], t[4], t[5], t[1], t[3]].map(\.id))
        // Dragged to the front by t[1]: t[3] just after it.
        workspace.moveTabs(workspace.selectedTabs, with: t[1], to: 0, group: nil)
        #expect(workspace.tabs.map(\.id) == [t[1], t[3], t[0], t[2], t[4], t[5]].map(\.id))
        #expect(picked(workspace) == [0, 1])
    }

    @Test func closingPicksClosesThemAllAndReopenBringsThemAllBack() throws {
        let workspace = Workspace(folder: URL(fileURLWithPath: "/tmp/tab-select-tests"), restore: false)
        defer { workspace.closeAll() }
        for (n, provider) in ["claude", "codex", "claude", "codex", "claude"].enumerated() {
            if n > 0 { workspace.newTab() }
            #expect(workspace.start(provider: provider))
            workspace.activeTab.chat?.draft = "tab \(n)"
        }
        let t = workspace.tabs
        workspace.select(t[1])
        workspace.click(t[3], .range)
        workspace.perform(.closeTab)
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[4].id])
        #expect(workspace.selection.isEmpty)
        workspace.reopenClosedTab()
        #expect(workspace.tabs.count == 5)
        #expect(workspace.tabs.map { $0.chat?.draft } == (0..<5).map { "tab \($0)" })
        #expect(workspace.tabs.map { $0.chat?.provider.id } == ["claude", "codex", "claude", "codex", "claude"])
        #expect(!workspace.canReopenClosedTab)
        // Picks not side by side, by ⌘: each back where it was.
        let u = workspace.tabs
        workspace.select(u[0])
        workspace.click(u[2], .toggle)
        workspace.click(u[4], .toggle)
        workspace.requestClose(workspace.selectedTabs)
        #expect(workspace.tabs.map(\.id) == [u[1].id, u[3].id])
        // A single close after them reopens alone first.
        workspace.close(u[3])
        workspace.reopenClosedTab()
        #expect(workspace.tabs.count == 2)
        workspace.reopenClosedTab()
        #expect(workspace.tabs.map { $0.chat?.draft } == (0..<5).map { "tab \($0)" })
    }

    @Test func closedTabsLeaveTheSelection() {
        let workspace = workspace(tabs: 5)
        let t = workspace.tabs
        workspace.select(t[0])
        workspace.click(t[2], .toggle)
        workspace.click(t[3], .toggle)
        workspace.close(t[2])
        #expect(picked(workspace) == [0, 2])
        workspace.close(t[3])
        #expect(workspace.selection.isEmpty)
    }
}

import Foundation
import Testing

@testable import KoreUI

/// Browser-style tab groups: made by resting a tab on another, folded to a chip, moved, closed
/// at once, and kept with the window.
@MainActor
struct TabGroupTests {
    private func workspace(tabs count: Int, folder: URL = FileManager.default.temporaryDirectory) -> Workspace {
        let workspace = Workspace(folder: folder, restore: false)
        for _ in 1..<count { workspace.newTab() }
        return workspace
    }

    private func group(_ workspace: Workspace, _ tab: ChatTab) -> UUID? { workspace.tabGroups.member[tab.id] }

    @Test func restingATabOnAnotherGroupsThemWithTheHeldOneAfter() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        let made = workspace.group(t[3], onto: t[1])
        #expect(made != nil)
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[1].id, t[3].id, t[2].id])
        #expect(group(workspace, t[1]) == made && group(workspace, t[3]) == made)
        #expect(group(workspace, t[0]) == nil && group(workspace, t[2]) == nil)
        #expect(workspace.tabGroups.group(made)?.color == .blue)
        #expect(workspace.tabGroups.group(made)?.name == "")
    }

    @Test func restingOnAGroupedTabJoinsItsGroup() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        let made = workspace.group(t[1], onto: t[0])
        #expect(workspace.group(t[3], onto: t[1]) == nil)
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[1].id, t[3].id, t[2].id])
        #expect(workspace.members(of: made!).count == 3)
        #expect(workspace.tabGroups.groups.count == 1)
    }

    @Test func newGroupsTakeTheFirstColourNotInUse() {
        let workspace = workspace(tabs: 6)
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        let b = workspace.group(t[3], onto: t[2])!
        #expect(workspace.tabGroups.group(a)?.color == .blue)
        #expect(workspace.tabGroups.group(b)?.color == .teal)
        workspace.recolor(group: a, .rose)
        let c = workspace.group(t[5], onto: t[4])!
        #expect(workspace.tabGroups.group(c)?.color == .blue)
    }

    @Test func aTabMovedInsideAGroupJoinsAndOneMovedPastItsEndLeaves() {
        let workspace = workspace(tabs: 5)
        let t = workspace.tabs
        let g = workspace.group(t[1], onto: t[0])!
        workspace.group(t[2], onto: t[1])
        // [0 1 2] 3 4: 4 into the middle of the group.
        workspace.moveTab(t[4], to: 1)
        #expect(group(workspace, t[4]) == g)
        // A member moved to the far end leaves.
        workspace.moveTab(t[0], to: 4)
        #expect(group(workspace, t[0]) == nil)
        #expect(workspace.members(of: g).map(\.id) == [t[4].id, t[1].id, t[2].id])
    }

    @Test func aDropOutsideAnyGroupNeverLandsInsideOne() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        workspace.group(t[1], onto: t[0])
        workspace.group(t[2], onto: t[1])
        // Let go in no group at a place inside the run: it goes to just past the run.
        workspace.moveTab(t[3], to: 1, group: nil)
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[1].id, t[2].id, t[3].id])
        #expect(group(workspace, t[3]) == nil)
    }

    @Test func aDropInAGroupLandsInItsRun() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        let g = workspace.group(t[2], onto: t[1])!
        workspace.moveTab(t[0], to: 3, group: g)
        #expect(workspace.tabs.map(\.id) == [t[1].id, t[2].id, t[0].id, t[3].id])
        #expect(group(workspace, t[0]) == g)
    }

    @Test func aGroupMovesAsOneBlockAndNeverIntoAnother() {
        let workspace = workspace(tabs: 6)
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        workspace.group(t[4], onto: t[3])
        // [0 1] 2 [3 4] 5: a after 2 (index among the other four tabs).
        workspace.moveGroup(a, to: 1)
        #expect(workspace.tabs.map(\.id) == [t[2].id, t[0].id, t[1].id, t[3].id, t[4].id, t[5].id])
        // Into the other group's middle: just past it instead.
        workspace.moveGroup(a, to: 2)
        #expect(workspace.tabs.map(\.id) == [t[2].id, t[3].id, t[4].id, t[0].id, t[1].id, t[5].id])
    }

    @Test func foldingHidesTheTabsButTheOpenOneUntilASwitch() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        let g = workspace.group(t[2], onto: t[1])!
        workspace.select(t[1])
        workspace.toggleFold(g)
        #expect(workspace.stripTabs.map(\.id) == [t[0].id, t[1].id, t[3].id])
        workspace.select(t[3])
        #expect(workspace.stripTabs.map(\.id) == [t[0].id, t[3].id])
        // ⌃⇥ passes the folded tabs.
        workspace.selectAdjacent(1)
        #expect(workspace.activeID == t[0].id)
        workspace.selectAdjacent(-1)
        #expect(workspace.activeID == t[3].id)
        // A folded tab picked from elsewhere opens its group.
        workspace.select(t[2])
        #expect(workspace.tabGroups.group(g)?.folded == false)
        #expect(workspace.stripTabs.count == 4)
    }

    @Test func closingAGroupClosesEveryTabInIt() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        let g = workspace.group(t[2], onto: t[1])!
        workspace.closeGroup(g)
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[3].id])
        #expect(workspace.tabGroups.isEmpty)
    }

    @Test func removingAMiddleTabPutsItPastTheGroup() {
        let workspace = workspace(tabs: 4)
        let t = workspace.tabs
        let g = workspace.group(t[1], onto: t[0])!
        workspace.group(t[2], onto: t[1])
        workspace.removeFromGroup(t[1])
        #expect(workspace.tabs.map(\.id) == [t[0].id, t[2].id, t[1].id, t[3].id])
        #expect(workspace.members(of: g).map(\.id) == [t[0].id, t[2].id])
        workspace.ungroup(g)
        #expect(workspace.tabGroups.isEmpty)
    }

    @Test func newTabInGroupOpensAtItsEnd() {
        let workspace = workspace(tabs: 3)
        let t = workspace.tabs
        let g = workspace.group(t[1], onto: t[0])!
        workspace.toggleFold(g)
        workspace.newTab(in: g)
        #expect(workspace.tabs[2].id == workspace.activeID)
        #expect(workspace.tabGroups.member[workspace.activeID] == g)
        #expect(workspace.tabGroups.group(g)?.folded == false)
    }

    @Test func aClosedTabLeavesItsGroupAndAnEmptyGroupGoes() {
        let workspace = workspace(tabs: 3)
        let t = workspace.tabs
        let g = workspace.group(t[1], onto: t[0])!
        workspace.close(t[0])
        #expect(workspace.members(of: g).map(\.id) == [t[1].id])
        workspace.close(t[1])
        #expect(workspace.tabGroups.isEmpty)
    }

    @Test func groupsAreSavedAndComeBackWithTheWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-groups-\(UUID().uuidString)")
        let workspace = workspace(tabs: 4, folder: folder)
        let t = workspace.tabs
        let g = workspace.group(t[2], onto: t[1])!
        workspace.rename(group: g, to: "  Release 2.4 ")
        workspace.recolor(group: g, .violet)
        workspace.toggleFold(g)
        let saved = workspace.persistenceSnapshot()
        #expect(saved.groups?.count == 1)
        #expect(saved.tabs.map(\.group) == [nil, g, g, nil])

        let data = try JSONEncoder().encode(saved)
        #expect(Workspace.storyRestore(folder: folder, saved: data))
        let reopened = Workspace(folder: folder, restore: true)
        let back = reopened.tabGroups.groups
        #expect(back.count == 1)
        #expect(back.first?.name == "Release 2.4" && back.first?.color == .violet && back.first?.folded == true)
        #expect(reopened.tabs.map { reopened.tabGroups.member[$0.id] } == [nil, g, g, nil])
    }

    @Test func anOldSaveWithoutGroupsStillOpens() throws {
        let json = #"{"tabs":[{},{}],"active":1}"#
        let saved = try JSONDecoder().decode(Workspace.Saved.self, from: Data(json.utf8))
        #expect(saved.groups == nil && saved.tabs.allSatisfy { $0.group == nil })
    }

    @Test func normalizingDropsMembersPastTheFirstRun() {
        var groups = TabGroups()
        let g = TabGroup(color: .teal)
        groups.add(g)
        let ids = (0..<4).map { _ in UUID() }
        groups.set(ids[0], to: g.id)
        groups.set(ids[1], to: g.id)
        groups.set(ids[3], to: g.id)
        groups.normalize(order: ids)
        #expect(groups.member[ids[3]] == nil && groups.member[ids[1]] == g.id)
        groups.normalize(order: [ids[2]])
        #expect(groups.isEmpty)
    }

    @Test func chipsTakeTheirRoomBeforeTheTabs() {
        let chip = TabStrip.Chip(id: UUID(), before: 1, named: 80, folded: false)
        let strip = TabStrip(count: 3, width: 3 * (Size.tabMaxWidth + Size.tabGap) + 80 + Size.tabGap, chips: [chip])
        #expect(strip.label == .name)
        #expect(strip.chipMinX(0) == strip.maxX(0) + Size.tabGap)
        #expect(strip.minX(1) == strip.chipMaxX(0) + Size.tabGap)
        // Narrow: an open group's chip is its dot alone.
        let narrow = TabStrip(count: 3, width: 260, chips: [chip])
        #expect(narrow.label != .name)
        #expect(narrow.chipWidths == [Size.TabGroup.dotChip])
        let folded = TabStrip(count: 3, width: 260, chips: [TabStrip.Chip(id: UUID(), before: 1, named: 80, folded: true)])
        #expect(folded.chipWidths == [80])
    }
}

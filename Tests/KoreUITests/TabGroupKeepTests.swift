import Foundation
import Testing

@testable import KoreUI

/// Tab groups through a window's close and its next open: every way a group changes, saved as
/// the close saves it and read back as an open reads it.
@MainActor
@Suite(.serialized)
struct TabGroupKeepTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("group-keep-\(UUID().uuidString)")
    }

    /// The window closed (its own close saves) and the folder opened again from what it kept.
    private func reopen(_ workspace: Workspace) -> Workspace {
        let folder = workspace.folder
        Workspace.storyLaunch = [:]
        defer {
            Workspace.storyLaunch = nil
            UserDefaults.standard.removeObject(forKey: "openTabs." + folder.standardizedFileURL.path)
        }
        workspace.closeAll()
        return Workspace(folder: folder, restore: true)
    }

    private struct Picture: Equatable {
        var name: String
        var color: TabGroupColor
        var folded: Bool
        var members: [Int]
    }

    /// The groups, in order, each with its tabs by place.
    private func picture(_ workspace: Workspace) -> [Picture] {
        workspace.tabGroups.groups.map { group in
            Picture(
                name: group.name, color: group.color, folded: group.folded,
                members: workspace.tabs.indices.filter { workspace.tabGroups.member[workspace.tabs[$0].id] == group.id })
        }
    }

    private func chats(_ count: Int, _ provider: Provider = .claude, folder: URL) -> Workspace {
        let workspace = Workspace(folder: folder, restore: false)
        workspace.start(provider, in: workspace.activeTab)
        for _ in 1..<count { _ = workspace.start(provider: provider.id) }
        return workspace
    }

    @Test func madeRenamedRecolouredFoldedComesBack() {
        let workspace = chats(5, folder: folder())
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        let b = workspace.newGroup(with: t[3])
        workspace.add(t[4], to: b)
        workspace.rename(group: a, to: "Docs")
        workspace.recolor(group: a, .violet)
        workspace.rename(group: b, to: "Release")
        workspace.toggleFold(b)
        let before = picture(workspace)
        #expect(before.count == 2)
        let back = reopen(workspace)
        #expect(picture(back) == before)
        #expect(back.tabGroups.groups.map(\.id) == [a, b])
    }

    @Test func bothCLIsAndEmptyTabsComeBack() {
        let workspace = Workspace(folder: folder(), restore: false)
        workspace.start(.codex, in: workspace.activeTab)
        _ = workspace.start(provider: "claude")
        workspace.newTab()
        workspace.newTab()
        let t = workspace.tabs
        workspace.group(t[1], onto: t[0])
        workspace.group(t[3], onto: t[2])
        workspace.toggleFold(workspace.tabGroups.groups[1].id)
        let before = picture(workspace)
        let back = reopen(workspace)
        #expect(picture(back) == before)
        #expect(back.tabs.map { $0.chat?.provider } == [.codex, .claude, nil, nil])
    }

    @Test func aTabTakenOutAndAnUngroupedGroupStayThatWay() {
        let workspace = chats(5, folder: folder())
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        workspace.add(t[2], to: a)
        workspace.removeFromGroup(t[1])
        let b = workspace.group(t[4], onto: t[3])!
        workspace.ungroup(b)
        let before = picture(workspace)
        #expect(before.count == 1 && before[0].members.count == 2)
        #expect(picture(reopen(workspace)) == before)
    }

    @Test func dragsInAndOutAndGroupMovesKeepTheirOrder() {
        let workspace = chats(6, folder: folder())
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        let b = workspace.group(t[3], onto: t[2])!
        workspace.moveTab(t[5], to: 1, group: a)
        workspace.moveTab(t[3], to: 6, group: nil)
        workspace.moveGroup(b, to: 0)
        let before = picture(workspace)
        let order = workspace.tabs.map(\.id)
        let back = reopen(workspace)
        #expect(picture(back) == before)
        #expect(back.tabs.count == order.count)
    }

    @Test func manyPickedTabsGroupedAndAddedComeBack() {
        let workspace = chats(6, folder: folder())
        let t = workspace.tabs
        let a = workspace.newGroup(with: [t[0], t[2], t[4]])!
        workspace.rename(group: a, to: "Picked")
        let b = workspace.newGroup(with: t[5])
        workspace.add([t[1], t[3]], to: b)
        workspace.toggleFold(b)
        let before = picture(workspace)
        #expect(before.map(\.members.count) == [3, 3])
        #expect(picture(reopen(workspace)) == before)
    }

    @Test func aClosedTabLeavesItsGroupAndAGroupWithNoTabsLeftIsGone() {
        let workspace = chats(5, folder: folder())
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        let b = workspace.group(t[3], onto: t[2])!
        workspace.close(t[0])
        workspace.closeGroup(b)
        let before = picture(workspace)
        #expect(before.count == 1 && before[0].members.count == 1)
        let back = reopen(workspace)
        #expect(picture(back) == before)
        #expect(back.tabGroups.groups.map(\.id) == [a])
    }

    @Test func fileTabsAndTabsNotSavedKeepTheRestTrue() throws {
        let folder = folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let workspace = chats(3, folder: folder)
        let fileTab = ChatTab()
        fileTab.file = FileDocument(url: file)
        workspace.tabs.insert(fileTab, at: 1)
        // An agent's tab is never saved: the tabs after it must keep their groups.
        let agentTab = ChatTab()
        agentTab.chat = workspace.tabs[0].chat
        agentTab.agent = "agent-1"
        workspace.tabs.insert(agentTab, at: 0)
        let t = workspace.tabs
        let a = workspace.group(t[2], onto: t[1])!
        workspace.group(t[4], onto: t[3])
        workspace.rename(group: a, to: "With file")
        let back = reopen(workspace)
        let groups = picture(back)
        #expect(groups.count == 2)
        #expect(groups.first?.name == "With file")
        #expect(back.tabs.count == 4)
        #expect(groups.map(\.members) == [[0, 1], [2, 3]])
        #expect(back.tabs[1].file?.name == "notes.txt")
    }

    @Test func reopenedAgainFromTheClosedWindowsSnapshotToo() throws {
        let workspace = chats(4, folder: folder())
        let t = workspace.tabs
        let a = workspace.group(t[1], onto: t[0])!
        workspace.toggleFold(a)
        let before = picture(workspace)
        let data = try JSONEncoder().encode(workspace.persistenceSnapshot())
        workspace.closeAll()
        #expect(Workspace.storyRestore(folder: workspace.folder, saved: data))
        let back = Workspace(folder: workspace.folder, restore: false)
        #expect(picture(back) == before)
    }

    // MARK: A box window: the box keeps the tabs, this Mac their groups by box chat id

    private struct BoxWindow {
        var groups = TabGroups()
        var tabs: [(id: UUID, chat: String?)] = []
        var taken: Set<String> = []

        init(_ chats: [String?]) { tabs = chats.map { (UUID(), $0) } }

        mutating func adopt(_ kept: KeptTabGroups) {
            if let order = groups.adopt(kept, tabs: tabs, taken: &taken) {
                let byId = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                tabs = order.compactMap { byId[$0] }
            }
        }

        /// Each group as its name and its tabs' chats, in the strip's order.
        var picture: [String: [String]] {
            var out: [String: [String]] = [:]
            for tab in tabs { if let g = groups.group(of: tab.id), let chat = tab.chat { out[g.name, default: []].append(chat) } }
            return out
        }
    }

    /// Two groups (one folded) made in a box window, kept as the close keeps them.
    private func keptBox() throws -> KeptTabGroups {
        var window = BoxWindow(["a", "b", "c", "d", "e"])
        let docs = TabGroup(name: "Docs", color: .violet)
        let release = TabGroup(name: "Release", color: .rose, folded: true)
        window.groups.add(docs)
        window.groups.add(release)
        for (i, g) in [(0, docs), (1, docs), (3, release), (4, release)] { window.groups.set(window.tabs[i].id, to: g.id) }
        window.groups.normalize(order: window.tabs.map(\.id))
        let kept = KeptTabGroups(window.groups, tabs: window.tabs)
        #expect(kept.members.map(\.chat) == ["a", "b", "d", "e"])
        // Kept through the defaults' bytes.
        return try JSONDecoder().decode(KeptTabGroups.self, from: JSONEncoder().encode(kept))
    }

    @Test func aBoxWindowsGroupsComeBackByChatInTheBoxsOrder() throws {
        let kept = try keptBox()
        // The box lists its chats in an order of its own.
        var window = BoxWindow(["e", "c", "a", "d", "b"])
        window.adopt(kept)
        #expect(window.picture == ["Docs": ["a", "b"], "Release": ["d", "e"]])
        #expect(window.groups.groups.map(\.name).sorted() == ["Docs", "Release"])
        #expect(window.groups.groups.first { $0.name == "Release" }?.folded == true)
        #expect(window.groups.groups.first { $0.name == "Docs" }?.color == .violet)
        #expect(window.tabs.map(\.chat) == ["d", "e", "c", "a", "b"])
    }

    @Test func aBoxChatListedLaterJoinsItsGroup() throws {
        let kept = try keptBox()
        var window = BoxWindow([nil, "a", "c"])
        window.adopt(kept)
        #expect(window.picture == ["Docs": ["a"]])
        window.tabs += [(UUID(), "e"), (UUID(), "b"), (UUID(), "d")]
        window.adopt(kept)
        #expect(window.picture == ["Docs": ["a", "b"], "Release": ["d", "e"]])
        // Taken up once: a chat ungrouped here stays out.
        window.groups.set(window.tabs.first { $0.chat == "b" }!.id, to: nil)
        window.adopt(kept)
        #expect(window.picture["Docs"] == ["a"])
    }

    @Test func aBoxGroupWithNoChatLeftIsDroppedAndOneNotShownYetIsKept() throws {
        let kept = try keptBox()
        var window = BoxWindow(["a", "b", "c"])
        window.adopt(kept)
        #expect(window.groups.groups.map(\.name) == ["Docs"])
        // Closed again before d and e came: Release is kept for them, Docs as it is now.
        let waiting = kept.members.filter { !window.taken.contains($0.chat) }
        let again = KeptTabGroups(window.groups, tabs: window.tabs, waiting: waiting, waitingGroups: kept.groups)
        #expect(again.members.map(\.chat) == ["a", "b", "d", "e"])
        #expect(again.groups.map(\.name) == ["Docs", "Release"])
        // Every tab of a group closed: nothing kept for it.
        var closed = window
        closed.tabs.removeAll { $0.chat == "a" || $0.chat == "b" }
        closed.groups.normalize(order: closed.tabs.map(\.id))
        #expect(KeptTabGroups(closed.groups, tabs: closed.tabs).isEmpty)
    }
}

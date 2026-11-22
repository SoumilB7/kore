import Foundation
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// Tab groups and the strip as an Arsenal ability (the owner via Kore-main, 2026-11-24): a chat
/// groups the tabs it opens, moves, folds, renames and shows them in its own window; the user's
/// own groups stay as they are unless the user asked in that chat; nothing closes or reloads.
@MainActor
@Suite("Arsenal tabs", .serialized)
struct ArsenalTabsTests {
    /// A window of chat tabs a…, the first one the caller, the window never brought forward for real.
    private func window(_ count: Int, file: Bool = false) -> (Workspace, [Chat]) {
        ArsenalWindows.front = { _ in }
        let workspace = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-arsenal-tabs"), restore: false)
        let chats = (0..<count).map { _ in Chat(provider: .claude, folder: workspace.folder) }
        var tabs = chats.map { chat in
            let tab = ChatTab()
            tab.chat = chat
            return tab
        }
        if file { tabs.append(ChatTab()) }
        workspace.tabs = tabs
        workspace.select(tabs[0])
        return (workspace, chats)
    }

    private func id(_ chat: Chat) -> String { Workspace.arsenalShort(chat) }
    private func order(_ w: Workspace) -> [String] { w.tabs.map(w.arsenalTabID) }

    private func ok(_ result: Result<String, ArsenalRefusal>) -> String? {
        if case .success(let line) = result { return line }
        if case .failure(let refusal) = result { Issue.record("refused: \(refusal.message)") }
        return nil
    }

    private func refused(_ result: Result<String, ArsenalRefusal>) -> String {
        if case .failure(let refusal) = result { return refusal.message }
        return "(done)"
    }

    @Test func silentOpensJoinAGroupTheCallerMadeByNameAndAFoldedOneStaysFolded() throws {
        let (w, c) = window(4)
        #expect(ok(w.arsenalJoin(c[2], group: "Workers", by: c[0], front: false)) == "In group “Workers”.")
        let group = try #require(w.tabGroups.group(of: w.tabs[2].id))
        #expect(group.madeBy == c[0].id.uuidString && !group.folded)
        w.toggleFold(group.id)
        // Any case joins the same group; its tabs sit together; folded, it stays so for a silent open.
        #expect(ok(w.arsenalJoin(c[3], group: "workers", by: c[0], front: false)) != nil)
        #expect(w.members(of: group.id).compactMap(\.chat).map(id) == [c[2], c[3]].map(id))
        #expect(w.tabGroups.group(group.id)?.folded == true && w.activeTab.chat === c[0])
        // An open in front opens it.
        #expect(ok(w.arsenalJoin(c[1], group: "Workers", by: c[0], front: true)) != nil)
        #expect(w.tabGroups.group(group.id)?.folded == false && w.members(of: group.id).count == 3)
    }

    @Test func aGroupLeftEmptyGoesAndTheAnswerIsTheNewOrder() {
        let (w, c) = window(3)
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[1]), id(c[2])], group: "Scan"), by: c[0]))
        #expect(w.tabGroups.groups.count == 1)
        let line = ok(w.arsenalArrange(.init(tabs: [id(c[1]), id(c[2])], group: ""), by: c[0]))
        #expect(w.tabGroups.groups.isEmpty)
        #expect(line == "kore-arsenal-tabs: *\(id(c[0])) \(id(c[1])) \(id(c[2]))")
    }

    @Test func tabsMoveBeforeAfterStartAndEndAndAGroupMovesWhole() {
        let (w, c) = window(5)
        let line = ok(w.arsenalArrange(.init(tabs: [id(c[4]), id(c[3])], to: "before:\(id(c[1]))"), by: c[0]))
        #expect(order(w) == [c[0], c[4], c[3], c[1], c[2]].map(id))
        #expect(line?.hasSuffix(order(w).enumerated().map { $0.offset == 0 ? "*" + $0.element : $0.element }.joined(separator: " ")) == true)
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[0])], to: "end"), by: c[0]))
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[2])], to: "start"), by: c[0]))
        #expect(order(w) == [c[2], c[4], c[3], c[1], c[0]].map(id))
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[4]), id(c[3])], group: "Pair"), by: c[0]))
        _ = ok(w.arsenalArrange(.init(group: "Pair", to: "after:\(id(c[0]))"), by: c[0]))
        #expect(order(w) == [c[2], c[1], c[0], c[4], c[3]].map(id))
        // A tab placed inside a group joins it; one placed past its group's edge leaves it.
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[2])], to: "after:\(id(c[4]))"), by: c[0]))
        #expect(w.tabGroups.group(of: w.tabs[3].id)?.name == "Pair" && w.tabs[3].chat === c[2])
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[2])], to: "start"), by: c[0]))
        #expect(w.tabGroups.group(of: w.tabs[0].id) == nil && w.members(of: w.tabGroups.groups[0].id).count == 2)
    }

    @Test func theUsersOwnGroupStaysAsItIsUnlessTheyAskedButMayTakeATab() throws {
        let (w, c) = window(4)
        let mine = w.newGroup(with: w.tabs[1])
        w.rename(group: mine, to: "Mine")
        w.add(w.tabs[2], to: mine)
        #expect(w.tabGroups.group(mine)?.madeBy == nil)
        let owned = "“Mine” is the user's group"
        #expect(refused(w.arsenalArrange(.init(tabs: [id(c[1])], group: ""), by: c[0])).hasPrefix(owned))
        #expect(refused(w.arsenalArrange(.init(tabs: [id(c[2])], to: "start"), by: c[0])).hasPrefix(owned))
        #expect(refused(w.arsenalArrange(.init(group: "Mine", name: "Theirs"), by: c[0])).hasPrefix(owned))
        #expect(refused(w.arsenalArrange(.init(group: "Mine", fold: true), by: c[0])).hasPrefix(owned))
        #expect(refused(w.arsenalArrange(.init(group: "Mine", ungroup: true), by: c[0])).hasPrefix(owned))
        #expect(refused(w.arsenalArrange(.init(group: "Mine", to: "end"), by: c[0])).hasPrefix(owned))
        #expect(refused(w.arsenalJoin(c[1], group: "Elsewhere", by: c[0], front: false)).hasPrefix(owned))
        #expect(w.members(of: mine).count == 2 && w.tabGroups.group(mine)?.name == "Mine")
        // A tab may join it: nothing of theirs moves.
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[3])], group: "Mine"), by: c[0]))
        #expect(w.members(of: mine).compactMap(\.chat).map(id) == [c[1], c[2], c[3]].map(id))
        // Asked in this chat: done.
        _ = ok(w.arsenalArrange(.init(group: "Mine", name: "Ours", asked: true), by: c[0]))
        #expect(w.tabGroups.group(mine)?.name == "Ours")
    }

    @Test func theUsersRenameMakesAChatsGroupTheirs() {
        let (w, c) = window(2)
        _ = ok(w.arsenalJoin(c[1], group: "Workers", by: c[0], front: false))
        let group = w.tabGroups.groups[0].id
        w.rename(group: group, to: "Kept")
        #expect(w.tabGroups.group(group)?.madeBy == nil)
    }

    @Test func showTakesATabOutOfAChatsGroupButOpensTheUsersAndBringsTheWindowForward() throws {
        let (w, c) = window(4)
        var fronted = 0
        ArsenalWindows.front = { _ in fronted += 1 }
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[1]), id(c[2])], group: "Workers"), by: c[0]))
        let workers = w.tabGroups.groups[0].id
        w.toggleFold(workers)
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[2])], show: true), by: c[0]))
        #expect(w.activeTab.chat === c[2] && w.tabGroups.group(of: w.activeTab.id) == nil && fronted == 1)
        let mine = w.newGroup(with: w.tabs.first { $0.chat === c[3] }!)
        w.toggleFold(mine)
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[3])], show: true), by: c[0]))
        #expect(w.activeTab.chat === c[3] && w.tabGroups.group(of: w.activeTab.id)?.id == mine && w.tabGroups.group(mine)?.folded == false)
        // A group alone: opened, its first tab selected.
        _ = ok(w.arsenalArrange(.init(group: "Workers", fold: true), by: c[0]))
        _ = ok(w.arsenalArrange(.init(group: "Workers", show: true), by: c[0]))
        #expect(w.activeTab.chat === c[1] && w.tabGroups.group(workers)?.folded == false && fronted == 3)
    }

    @Test func anotherWindowsTabAndNamesThatArentHereAreRefusedInOneLine() {
        let (w, c) = window(2)
        #expect(refused(w.arsenalArrange(.init(tabs: ["abcdef12"], group: "X"), by: c[0], elsewhere: { $0 == "abcdef12" }))
            == "abcdef12 is in another window: tabs move only within this chat's window.")
        #expect(refused(w.arsenalArrange(.init(tabs: ["0badc0de"], to: "end"), by: c[0])) == "No tab 0badc0de in this window.")
        #expect(refused(w.arsenalArrange(.init(group: "Nope", fold: true), by: c[0])) == "No group “Nope” in this window.")
        #expect(refused(w.arsenalArrange(.init(tabs: [id(c[1])], to: "middle"), by: c[0])).hasPrefix("to is start, end"))
        #expect(refused(w.arsenalArrange(.init(), by: c[0])) == "Name the tabs, or a group.")
        #expect(w.tabs.count == 2, "never closes a tab")
    }

    @Test func theWindowViewListsTabsOnceAndGroupsAsIdListsWithWhoMadeThem() throws {
        let (w, c) = window(3, file: true)
        _ = ok(w.arsenalArrange(.init(tabs: [id(c[1]), id(c[2])], group: "Workers"), by: c[0]))
        let mine = w.newGroup(with: w.tabs[0])
        let view = w.arsenalView()
        let file = w.arsenalTabID(w.tabs[3])
        #expect(view.tabs == [id(c[0]), id(c[1]), id(c[2]), file] && view.selected == id(c[0]) && file.hasPrefix("t"))
        #expect(view.other == [file: "New tab"])
        #expect(view.groups.map(\.name) == ["Workers", "@" + id(c[0])])
        #expect(view.groups.map(\.by) == [id(c[0]), "user"] && view.groups[0].tabs == [id(c[1]), id(c[2])])
        _ = mine
        // Another window: only the chats it may read, no other tabs.
        let narrow = w.arsenalView(whole: false) { $0 !== c[1] }
        #expect(narrow.tabs == [id(c[0]), id(c[2])] && narrow.other.isEmpty && narrow.groups.first { $0.name == "Workers" }?.tabs == [id(c[2])])
    }

    @Test func groupsAChatMadeComeBackWithTheWindow() throws {
        let (w, c) = window(2)
        _ = ok(w.arsenalJoin(c[1], group: "Workers", by: c[0], front: false))
        let saved = try JSONDecoder().decode(Workspace.Saved.self, from: JSONEncoder().encode(w.saved))
        #expect(saved.groups?.first?.madeBy == c[0].id.uuidString && saved.groups?.first?.name == "Workers")
        // A save from before groups knew their maker reads as the user's.
        let old = try JSONDecoder().decode(TabGroup.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","color":"blue","folded":false}"#.utf8))
        #expect(old.madeBy == nil)
    }
}

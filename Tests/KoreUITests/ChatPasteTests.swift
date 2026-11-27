import Foundation
import HostClient
import KoreCore
import AppKit
import Testing

@testable import KoreUI
@testable import src

/// A chat copied or cut in one window's History and pasted in another's (link 1.11): what each
/// pair of places does, the clipboard's ⌘C/⌘V model, and the menus' items.
@MainActor
@Suite("chat paste", .serialized)
struct ChatPasteTests {
    static let macA = ChatSpot.mac("/Users/me/Code/app")
    static let macB = ChatSpot.mac("/Users/me/Code/web")
    static let box1 = ChatSpot.box(alias: "mybox", folder: "/home/me/app")
    static let box1b = ChatSpot.box(alias: "mybox", folder: "/home/me/web")
    static let box2 = ChatSpot.box(alias: "other", folder: "/home/me/app")

    func clip(_ spot: ChatSpot, cut: Bool) -> ChatClipboard.Clip {
        ChatClipboard.Clip(spot: spot, id: "s1", provider: "claude", title: "Repos", cut: cut)
    }

    func plan(_ from: ChatSpot, _ to: ChatSpot, cut: Bool, held: MovedChat? = nil, open: Bool = false) -> ChatPastePlan {
        ChatPastePlan.of(clip(from, cut: cut), to: to, held: held, boxChatOpen: open)
    }

    @Test func aCopyIsANewChatAnywhereAndADuplicateInItsOwnFolder() {
        for (from, to) in [(Self.macA, Self.macB), (Self.macA, Self.box1), (Self.box1, Self.macA), (Self.box1, Self.box2), (Self.box1, Self.box1b)] {
            #expect(plan(from, to, cut: false) == .copy, "\(from) → \(to)")
            #expect(plan(from, to, cut: false, open: true) == .copy)
        }
        for spot in [Self.macA, Self.box1] { #expect(plan(spot, spot, cut: false) == .duplicate) }
    }

    @Test func aCutTakesEachPairsOwnWay() {
        // Mac folder → Mac folder: copy, then the original to Kore's trash.
        #expect(plan(Self.macA, Self.macB, cut: true) == .copyThenRemove)
        // Mac → box: chat.adopt as a new chat there (1.10's machinery), then the Mac's original aside.
        #expect(plan(Self.macA, Self.box1, cut: true) == .adopt)
        // A chat this Mac holds from a box: back to that very folder is a send back; elsewhere, refused with why.
        let held = MovedChat(alias: "mybox", boxChat: "c1", boxFolder: "/home/me/app", macFolder: "/Users/me/Code/app", provider: "claude", session: "s1", gen: 1)
        #expect(plan(Self.macA, Self.box1, cut: true, held: held) == .sendBack)
        guard case .refuse(let why) = plan(Self.macA, Self.box2, cut: true, held: held) else { Issue.record("a held chat cut elsewhere"); return }
        #expect(why == "“Repos” belongs to mybox · send it back there, or copy it")
        if case .refuse = plan(Self.macA, Self.macB, cut: true, held: held) {} else { Issue.record("a held chat cut to another Mac folder") }
        // Box → Mac: an open box chat by release (owner, gen); a closed one or a past session by copy, then its box's trash.
        #expect(plan(Self.box1, Self.macA, cut: true, open: true) == .bring)
        #expect(plan(Self.box1, Self.macA, cut: true, open: false) == .copyThenRemove)
        // Box → box (another box, or another folder of the same one): copy, then the source released.
        #expect(plan(Self.box1, Self.box2, cut: true, open: true) == .copyThenRemove)
        #expect(plan(Self.box1, Self.box1b, cut: true) == .copyThenRemove)
        // Where it is already: it just opens.
        #expect(plan(Self.macA, Self.macA, cut: true) == .open && plan(Self.box1, Self.box1, cut: true, open: true) == .open)
    }

    @Test func aCutIsTakenByItsPasteACopyStaysAndTextCopiedSinceWinsTheKeys() {
        let board = ChatClipboard()
        var count = 7
        board.changeCount = { count }
        board.put(clip(Self.macA, cut: false))
        board.taken()
        #expect(board.clip != nil && board.pastesChat)
        board.put(clip(Self.box1, cut: true))
        board.taken()
        #expect(board.clip == nil && !board.pastesChat)
        board.put(clip(Self.macA, cut: false))
        count += 1  // text copied since
        #expect(board.clip != nil && !board.pastesChat)
    }

    @Test func linesSayWhereFromAndWhereTo() {
        #expect(Self.macA.shown == "app" && Self.macA.destination == "app")
        #expect(Self.box1.shown == "app on mybox" && Self.box1.destination == "mybox")
    }

    @Test func pasteShowsInTheMenusOnlyWhileAChatIsHeld() {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        let saved = ChatClipboard.shared.clip
        defer { if let saved { ChatClipboard.shared.put(saved) } else { ChatClipboard.shared.clear() } }
        ChatClipboard.shared.clear()
        #expect(ChatPasting.menuItems(workspace).isEmpty)
        #expect(!TabMenu.items(workspace.activeTab, in: workspace) {}.map(\.title).contains("Paste Chat"))
        ChatClipboard.shared.put(clip(Self.macA, cut: false))
        #expect(ChatPasting.menuItems(workspace).map(\.title) == ["Paste Chat"])
        #expect(TabMenu.items(workspace.activeTab, in: workspace) {}.map(\.title).contains("Paste Chat"))
        let row = SessionSummary(id: "s1", agent: .claude, title: "Repos", updated: .now)
        #expect(HistoryMenu.items(row, locked: nil, open: {}, rename: {}, archive: {}, paste: {}).map(\.title).suffix(3) == ["Copy", "Cut", "Paste Chat"])
        // A window's own place, and a row's.
        #expect(workspace.spot == .mac(FileManager.default.temporaryDirectory.path) && workspace.spot(of: "s1") == workspace.spot)
    }

    @Test func aCopysLineIsKeptByItsSession() throws {
        let marks = ChatCopyMarks()
        let url = URL(fileURLWithPath: "/tmp/kcm-\(UUID().uuidString.prefix(6)).json")
        defer { try? FileManager.default.removeItem(at: url) }
        marks.url = url
        marks.set("claude", "n1", "Copied from “Repos” · app on mybox")
        let again = ChatCopyMarks()
        again.url = url
        #expect(again.line("claude", "n1") == "Copied from “Repos” · app on mybox" && again.line("codex", "n1") == nil)
    }

    // MARK: Tabs (0.3.10)

    @Test func aTabsMenuCopiesAndCutsItsChatOnceItHasOne() {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        defer { workspace.closeAll() }
        // An empty tab: nothing to copy.
        #expect(ChatPasting.tabItems(workspace.activeTab, in: workspace).isEmpty)
        workspace.activeTab.chat = Chat(provider: .claude, folder: workspace.folder)
        // A chat with nothing sent yet: the items, off.
        let items = ChatPasting.tabItems(workspace.activeTab, in: workspace)
        #expect(items.map(\.title) == ["Copy Chat", "Cut Chat"] && items.allSatisfy { !$0.enabled })
        #expect(ChatPasting.clip(of: workspace.activeTab, in: workspace, cut: false) == nil)
        #expect(TabMenu.items(workspace.activeTab, in: workspace) {}.map(\.title).contains("Copy Chat"))
    }

    @Test func theKeysGoToAChatOnlyOutsideText() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let text = NSTextView(frame: .zero)
        let plain = NSView(frame: .zero)
        #expect(ChatPasting.outsideText(nil, in: window))
        #expect(ChatPasting.outsideText(window, in: window))
        #expect(ChatPasting.outsideText(plain, in: window))
        #expect(!ChatPasting.outsideText(text, in: window))
        // Held, and nothing copied since: ⌘V means the chat; text copied after it wins.
        let saved = (ChatClipboard.shared.clip, ChatClipboard.shared.changeCount)
        defer {
            ChatClipboard.shared.changeCount = saved.1
            if let clip = saved.0 { ChatClipboard.shared.put(clip) } else { ChatClipboard.shared.clear() }
        }
        var count = 1
        ChatClipboard.shared.changeCount = { count }
        ChatClipboard.shared.put(clip(Self.macA, cut: false))
        #expect(ChatPasting.pastesOnKey(plain, in: window) && !ChatPasting.pastesOnKey(text, in: window))
        count = 2
        #expect(!ChatPasting.pastesOnKey(plain, in: window))
    }

    @Test func aPastedTabGoesRightAfterTheOneClickedPastItsGroup() {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        defer { workspace.closeAll() }
        for _ in 1..<5 { workspace.newTab() }
        let tabs = workspace.tabs
        workspace.group(tabs[2], onto: tabs[1])
        workspace.group(tabs[3], onto: tabs[2])
        workspace.select(tabs[0])
        // After a tab outside a group: right after it.
        workspace.newTab(after: tabs[0])
        #expect(workspace.tabs.firstIndex { $0 === workspace.activeTab } == 1)
        // After a group's middle: past the group, which stays whole.
        workspace.newTab(after: tabs[2])
        let group = workspace.tabGroups.member[tabs[1].id]
        #expect(workspace.tabs.firstIndex { $0 === workspace.activeTab } == 5)
        #expect(workspace.tabs.indices.filter { workspace.tabGroups.member[workspace.tabs[$0].id] == group } == [2, 3, 4])
        // A tab moved beside one (a box's listed chat): the same place.
        let last = workspace.tabs[workspace.tabs.count - 1]
        workspace.move(last, after: tabs[1])
        #expect(workspace.tabs.firstIndex { $0 === last } == 5)
        #expect(workspace.tabs.indices.filter { workspace.tabGroups.member[workspace.tabs[$0].id] == group } == [2, 3, 4])
    }
}

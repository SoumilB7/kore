import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// Link 1.10 in the windows: a box chat offers Bring to this Mac; once here it runs in a local
/// window on the pair's Mac folder with "from <box>", the box window keeps a read-only replica,
/// and both offer Send back. The moves are kept in a scratch store, never the app's.
@Suite("chat moves in the windows", .serialized) @MainActor
struct ChatMoveUITests {
    static let session = "7d1e3c40-0000-4000-8000-00000000abcd"

    @MainActor struct Rig {
        let root: URL
        let store: MovedChats
        let box: BoxBinding
        let boxWindow: Workspace
        let boxTab: ChatTab
        let mac: URL
        var moved: MovedChat {
            MovedChat(alias: "mybox", boxChat: "c1", boxFolder: "/home/me/app", macFolder: mac.path, provider: "claude", session: ChatMoveUITests.session, gen: 1, title: "Repos")
        }

        func finish() {
            try? FileManager.default.removeItem(at: root)
            ChatPlaces.shared.use(MovedChats(root: root.appendingPathComponent("gone")))
        }
    }

    func rig() throws -> Rig {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kore-moves-\(UUID().uuidString.prefix(6))")
        let mac = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let store = MovedChats(root: root.appendingPathComponent("hosts"))
        ChatPlaces.shared.use(store)
        let box = BoxBinding(alias: "mybox", folder: "/home/me/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        box.workspace = workspace
        let tab = ChatTab()
        tab.chat = Chat(
            provider: .claude, folder: box.folderURL, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
            services: BoxChatServices(binding: box, chatId: "c1"))
        tab.chat?.adoptName("Repos")
        workspace.tabs = [tab]
        return Rig(root: root, store: store, box: box, boxWindow: workspace, boxTab: tab, mac: mac)
    }

    private func titles(_ tab: ChatTab, _ workspace: Workspace) -> [String] { TabMenu.items(tab, in: workspace) {}.map(\.title) }

    @Test func aBoxChatOffersBringAndAMovedOneSendBack() throws {
        let r = try rig()
        defer { r.finish() }
        // On the box: Bring to this Mac; a box chat not made yet doesn't.
        #expect(titles(r.boxTab, r.boxWindow).contains("Bring to this Mac"))
        let fresh = ChatTab()
        fresh.chat = r.box.newChat(.claude)
        #expect(!titles(fresh, r.boxWindow).contains("Bring to this Mac"))
        #expect(ChatPlaces.shared.replica(r.boxTab.chat!) == nil)

        // Brought here: the box tab is a replica with Send back, and no Bring.
        r.store.keep(r.moved)
        let menu = titles(r.boxTab, r.boxWindow)
        #expect(menu.contains("Send back to mybox") && !menu.contains("Bring to this Mac"))
        #expect(ChatPlaces.shared.replica(r.boxTab.chat!) == ChatPlaces.Replica(here: true, name: "this Mac"))
        #expect(ChatView.sendBack(r.boxTab.chat!, in: r.boxWindow) != nil)

        // The local tab: Send back, and its box as the tab's mark.
        let local = Workspace(folder: r.mac, restore: false)
        let tab = ChatTab()
        tab.chat = Chat(provider: .claude, folder: r.mac, resume: SessionSummary(id: Self.session, agent: .claude, title: "Repos", updated: .now))
        local.tabs = [tab]
        #expect(titles(tab, local).contains("Send back to mybox"))
        #expect(ChatPlaces.shared.moved(tab.chat!)?.alias == "mybox")
        #expect(ChatPlaces.shared.replica(tab.chat!) == nil)

        // Back on the box: plain again.
        r.store.forget(session: Self.session)
        #expect(titles(r.boxTab, r.boxWindow).contains("Bring to this Mac") && !titles(tab, local).contains("Send back to mybox"))
    }

    @Test func aChatAnotherMacHoldsIsReadOnlyWithNoAction() throws {
        let r = try rig()
        defer { r.finish() }
        let replica = ChatPlaces.shared.replica(
            alias: "mybox", chatId: "c9", meta: nil)
        #expect(replica == nil)
        // Heard from the box: it lives on another Mac.
        ChatPlaces.shared.heard("mybox", "c1", owner: ChatOwner(host: "studio", gen: 3, since: 0, name: "Studio"), moving: false)
        #expect(ChatPlaces.shared.replica(r.boxTab.chat!) == ChatPlaces.Replica(here: false, name: "Studio"))
        #expect(ChatPlaces.shared.gen("mybox", "c1") == 3)
        // Not this Mac's: nothing to send back, and no Bring.
        #expect(ChatView.sendBack(r.boxTab.chat!, in: r.boxWindow) == nil)
        #expect(ChatMoving.menuItems(r.boxTab, in: r.boxWindow).isEmpty)
    }

    @Test func theSheetSaysWhatHoldsTheMove() throws {
        let r = try rig()
        defer { r.finish() }
        // The box can't be reached: no move, one line.
        ChatMoving.bring(r.boxTab, in: r.boxWindow)
        let sheet = try #require(r.boxWindow.moveSheet)
        #expect(sheet.heading == "Bring “Repos” to this Mac")
        #expect(sheet.line == "Can't reach mybox · the chat stays there" && !sheet.ready)
        sheet.onClose()
        #expect(r.boxWindow.moveSheet == nil)

        // The checks one by one.
        let s = MoveSheet(way: .bring, alias: "mybox", title: "Repos", chat: r.boxTab.chat)
        #expect(s.idleLine == "Chat is idle" && s.syncLine == "Checking the folder's sync…" && !s.ready)
        s.sync = .pending(3)
        #expect(s.syncLine == "3 changes still syncing…")
        s.sync = .pending(0)
        #expect(s.syncLine == "Changes still syncing…")
        s.sync = .noPair
        #expect(s.folderLine == nil && !s.ready)
        s.sync = .settled
        s.folder = "~/Code/app"
        #expect(s.folderLine == "Local folder: ~/Code/app" && s.syncLine == "Folder is in sync" && s.ready && s.button == "Bring here")
        s.moving = true
        #expect(!s.ready)
        let back = MoveSheet(way: .back, alias: "mybox", title: "Repos", chat: nil)
        back.folder = "/home/me/app"
        #expect(back.heading == "Send “Repos” back to mybox" && back.folderLine == "Folder on mybox: /home/me/app" && back.button == "Send back")
    }

    @Test func aBroughtChatLandsInItsFoldersWindowAndReturnsToTheBoxWindow() throws {
        let r = try rig()
        defer { r.finish() }
        var opened: [URL] = []
        var boxOpened: [(BoxPlace, String?)] = []
        ChatMoving.openLocal = { opened.append($0) }
        ChatMoving.openBox = { boxOpened.append(($0, $1)) }
        defer {
            ChatMoving.openLocal = { AppModel.shared?.openFolder($0) }
            ChatMoving.openBox = { AppModel.shared?.openBox($0, chat: $1) }
        }
        r.store.keep(r.moved)

        // No window on the folder yet: the chat waits for it, and lands as it opens.
        ChatMoving.land(r.moved, title: "Repos", modelId: "haiku", effort: "low", mode: nil)
        let canonical = AppModel.canonical(r.mac)
        #expect(opened == [canonical])
        let local = Workspace.forWindow(canonical, restore: false)
        let tab = try #require(local.tabs.first { $0.chat?.status.sessionId == Self.session })
        #expect(local.activeTab === tab)
        // The box's model when this Mac's CLI lists it (or hasn't listed yet), else the default.
        let model = Workspace.usable("haiku", among: ArsenalModels.seen["claude"] ?? []) ? "haiku" : nil
        #expect(tab.chat?.launchModel == model && tab.chat?.launchEffort == "low" && tab.chat?.title == "Repos")
        #expect(ChatPlaces.shared.moved(tab.chat!)?.alias == "mybox")
        #expect(Workspace.localTab(session: Self.session)?.1 === tab)

        // Brought again while it's open: the same tab, in front.
        local.newTab()
        ChatMoving.land(r.moved, title: "Repos", modelId: nil, effort: nil, mode: nil)
        #expect(local.tabs.filter { $0.chat?.status.sessionId == Self.session }.count == 1 && local.activeTab === tab)

        // Back: the box window comes forward with the chat.
        ChatMoving.returned(alias: "mybox", boxFolder: "/home/me/app", chatId: "c1")
        #expect(boxOpened.count == 1 && boxOpened[0].0 == BoxPlace(alias: "mybox", folder: "/home/me/app") && boxOpened[0].1 == "c1")
        #expect(r.boxWindow.activeTab === r.boxTab)
    }

    @Test func aModelThisMacDoesntListFallsBackToTheDefault() {
        let listed = [ModelOption(id: "sonnet", name: "Sonnet", resolved: "Sonnet", efforts: [])]
        #expect(Workspace.usable("sonnet", among: listed) && Workspace.usable("Sonnet", among: listed))
        #expect(!Workspace.usable("opus-x", among: listed))
        // Nothing listed yet: the box's model is tried.
        #expect(Workspace.usable("opus-x", among: []))
    }
}

import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// A box chat's menus offer what a Mac chat's do (link 1.9): enabled, and what can't be done on a
/// box dim with why, never left out.
@Suite("box chat operations") @MainActor
struct BoxChatOpsUITests {
    private func boxTab() -> (Workspace, ChatTab, BoxBinding) {
        let box = BoxBinding(alias: "mybox", folder: "/home/me/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        let tab = ChatTab()
        tab.chat = box.newChat(.claude)
        workspace.tabs = [tab]
        return (workspace, tab, box)
    }

    private func item(_ items: [OptionItem], _ title: String) -> OptionItem? { items.first { $0.title.hasPrefix(title) } }

    @Test func aBoxChatsTabMenuOffersTheLocalItemsEnabled() {
        let (workspace, tab, _) = boxTab()
        let items = TabMenu.items(tab, in: workspace) {}
        for title in ["Rename…", "Arsenal", "Add to New Group", "Close Tab"] {
            #expect(item(items, title)?.enabled == true, "\(title)")
        }
        // The same items as a Mac chat's tab.
        let local = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-box-ops"), restore: false)
        let mac = ChatTab()
        mac.chat = Chat(provider: .claude, folder: local.folder)
        local.tabs = [mac]
        #expect(TabMenu.items(mac, in: local) {}.map(\.title) == items.map(\.title))
    }

    @Test func historyRowsAreEnabledOnABoxThatKeepsItsHistoryAndDimWithWhyOnAnOlderOne() {
        let session = SessionSummary(id: "s1", agent: .claude, title: "Old work", updated: .now)
        let open = HistoryMenu.items(session, locked: nil, open: {}, rename: {}, archive: {})
        #expect(open.map(\.title) == ["Open", "Rename…", "Archive", "", "Copy", "Cut"] && open.allSatisfy(\.enabled))
        // A box not linked yet (or older than 1.9) says why, and Open still works.
        let (_, _, box) = boxTab()
        let why = box.historyLocked
        #expect(why == "Update kore-host on mybox to rename or archive here")
        let locked = HistoryMenu.items(session, locked: why, open: {}, rename: {}, archive: {})
        #expect(item(locked, "Open")?.enabled == true)
        #expect(item(locked, "Rename…")?.enabled == false && item(locked, "Archive")?.enabled == false)
        #expect(locked.last?.title == why && locked.last?.enabled == false)
    }

    @Test func modesPastAutoShowDimWithWhereTheyreSet() throws {
        // Codex's Full access is past Auto: on a box it shows dim, saying where it's set.
        let box = BoxBinding(alias: "mybox", folder: "/home/me/app")
        let chat = box.newChat(.codex)
        #expect(!chat.controls.availableModes.contains { $0.id == CodexModes.fullAccess })
        #expect(chat.controls.cappedModes.map(\.id) == [CodexModes.fullAccess])
        #expect(chat.controls.levelCapNote == "Box chats go up to Auto")
        // A Mac chat offers it, with none dim. Claude's Full access the same, in the same words.
        let mac = Chat(provider: .codex, folder: URL(fileURLWithPath: "/tmp"))
        #expect(mac.controls.availableModes.contains { $0.id == CodexModes.fullAccess } && mac.controls.cappedModes.isEmpty)
        #expect(box.newChat(.claude).controls.cappedModes.map(\.label) == ["Full access"])
        let macClaude = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp"))
        #expect(macClaude.controls.availableModes.contains { $0.id == ClaudeModes.fullAccess } && macClaude.controls.cappedModes.isEmpty)
    }

    @Test func aMacWithFullControlOfABoxThatTakesItOffersFullAccess() {
        let box = BoxBinding(alias: "mybox-\(UUID().uuidString.prefix(6))", folder: "/home/me/app")
        for (provider, full) in [(ProviderDescriptor.claude, ClaudeModes.fullAccess), (.codex, CodexModes.fullAccess)] {
            let chat = box.newChat(provider)
            // A box that takes it, full control: offered, nothing dim; Arsenal still stops at Auto.
            box.connection.welcomed(caps: [LinkPolicy.fullAccessCap], control: .full)
            #expect(chat.controls.availableModes.contains { $0.id == full } && chat.controls.cappedModes.isEmpty)
            let caller = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp"))
            caller.controls.mode = full
            let mac = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp"))
            #expect(!chat.arsenalMayMove(to: full, under: caller) && mac.arsenalMayMove(to: full, under: caller))
            // An older box, or a grant without full control: dim, with the line as before.
            for (caps, control) in [([String](), LinkControlLevel.full), ([LinkPolicy.fullAccessCap], .standard)] {
                box.connection.welcomed(caps: caps, control: control)
                #expect(chat.controls.cappedModes.map(\.id) == [full] && chat.controls.levelCapNote == "Box chats go up to Auto")
            }
        }
    }
}

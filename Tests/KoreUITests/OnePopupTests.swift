import Foundation
import Testing

@testable import KoreUI

/// One popup over the composer at a time: whatever opens closes the rest.
@MainActor
struct OnePopupTests {
    private func chat() throws -> Chat {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        _ = workspace.start(provider: "claude")
        return try #require(workspace.activeTab.chat)
    }

    @Test func theContextCardClosesTheMapAndTheMenu() throws {
        let chat = try chat()
        chat.agentMap.open()
        #expect(chat.hasPopup)
        chat.contextCard.open()
        #expect(chat.contextCard.shown && !chat.agentMap.isOpen)
        #expect(chat.slashClosed)
    }

    @Test func theMapClosesTheCard() throws {
        let chat = try chat()
        chat.contextCard.open()
        chat.agentMap.open()
        #expect(chat.agentMap.isOpen && !chat.contextCard.shown)
    }

    @Test func theSlashMenuOrAMenuClosesTheRest() throws {
        let chat = try chat()
        chat.contextCard.open()
        chat.slashClosed = false
        chat.closePopups(keeping: .slash)
        #expect(!chat.contextCard.shown && !chat.slashClosed)
        chat.agentMap.open()
        chat.closePopups(keeping: .menu)
        #expect(!chat.hasPopup && chat.slashClosed)
    }

    @Test func theImportPickerToo() throws {
        let chat = try chat()
        chat.importer.open()
        chat.contextCard.open()
        #expect(!chat.importer.isOpen)
        chat.closePopups(keeping: .importer)
        #expect(!chat.contextCard.shown)
    }
}

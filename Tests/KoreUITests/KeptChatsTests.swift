import Foundation
import Testing

@testable import KoreUI

/// Which chats' transcripts stay mounted as tabs switch (`KeptChats`).
@MainActor
struct KeptChatsTests {
    /// A window with `count` Claude chats, each in its own tab.
    private func workspace(chats count: Int) -> Workspace {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        for _ in 0..<count { _ = workspace.start(provider: "claude") }
        return workspace
    }

    private func chats(_ workspace: Workspace) -> [Chat] { workspace.tabs.compactMap(\.chat) }

    @Test func nothingIsKeptUntilAChatShows() {
        let workspace = workspace(chats: 2)
        let kept = KeptChats()
        #expect(kept.update(nil, tabs: workspace.tabs).isEmpty)
        #expect(kept.latest == nil)
    }

    @Test func theLastThreeShownStayAndTheLongestUnseenGoes() {
        let workspace = workspace(chats: 4)
        let chats = chats(workspace)
        let kept = KeptChats()
        for chat in [chats[0], chats[1], chats[2], chats[0]] { _ = kept.update(chat, tabs: workspace.tabs) }
        #expect(kept.update(chats[0], tabs: workspace.tabs).map(\.id) == [chats[0], chats[1], chats[2]].map(\.id))
        // The fourth sends the second away (the first was seen again since); the rest keep their places.
        #expect(kept.update(chats[3], tabs: workspace.tabs).map(\.id) == [chats[0], chats[2], chats[3]].map(\.id))
    }

    @Test func aRunningChatStays() {
        let workspace = workspace(chats: 4)
        let chats = chats(workspace)
        let kept = KeptChats()
        for chat in chats.prefix(3) { _ = kept.update(chat, tabs: workspace.tabs) }
        chats[0].status.setRunning(true)
        #expect(kept.update(chats[3], tabs: workspace.tabs).map(\.id) == [chats[0], chats[2], chats[3]].map(\.id))
    }

    @Test func aClosedTabsChatGoes() {
        let workspace = workspace(chats: 2)
        let chats = chats(workspace)
        let kept = KeptChats()
        for chat in chats { _ = kept.update(chat, tabs: workspace.tabs) }
        workspace.close(workspace.tabs[1])
        #expect(kept.update(nil, tabs: workspace.tabs).map(\.id) == [chats[0].id])
        #expect(kept.latest == nil)
    }

    @Test func anotherKindOfTabKeepsTheLatestForTheComposer() {
        let workspace = workspace(chats: 2)
        let chats = chats(workspace)
        let kept = KeptChats()
        for chat in chats { _ = kept.update(chat, tabs: workspace.tabs) }
        #expect(kept.update(nil, tabs: workspace.tabs).count == 2)
        #expect(kept.latest === chats[1])
    }
}

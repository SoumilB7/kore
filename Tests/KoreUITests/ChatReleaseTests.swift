import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// A closed tab gives its chat back: the chat, its transcript and what was drawn from it are
/// freed, so Kore's memory follows the chats open, not every chat ever opened.
@MainActor
struct ChatReleaseTests {
    private func workspace(chats count: Int) -> Workspace {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        for _ in 0..<count { _ = workspace.start(provider: "claude") }
        return workspace
    }

    /// A conversation of `turns` turns, as a resumed chat's history arrives.
    private func history(turns: Int) -> [ChatEvent] {
        var events: [ChatEvent] = []
        for turn in 0..<turns {
            let id = "t\(turn)"
            events.append(.userMessage(text: "Question \(turn) " + String(repeating: "word ", count: 40), attachments: [], id: "u\(turn)"))
            events.append(.turnStarted(id, origin: .user, at: .now))
            events.append(.text("a\(turn)", .answer, String(repeating: "An answer with `code` and prose. ", count: 60)))
            events.append(.turnFinished(id, .completed, duration: .seconds(3)))
        }
        return events
    }

    /// Waits for released objects: a chat's tasks end on their next turn of the run loop.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aClosedChatIsFreedWithItsTranscript() async {
        let workspace = workspace(chats: 2)
        weak var chat: Chat?
        weak var transcript: TranscriptStore?
        do {
            let closing = workspace.tabs[1].chat!
            closing.transcript.apply(.replayed(history(turns: 30)))
            closing.transcript.drawNow()
            #expect(!closing.transcript.sections.isEmpty)
            chat = closing
            transcript = closing.transcript
            workspace.close(workspace.tabs[1])
        }
        await settle { chat == nil && transcript == nil }
        #expect(chat == nil, "a closed tab's chat is still alive")
        #expect(transcript == nil, "a closed tab's transcript is still alive")
        #expect(workspace.tabs.count == 1)
    }

    @Test func closingAndOpeningAgainKeepsOneChatsWorth() async {
        let workspace = workspace(chats: 1)
        var freed = 0
        for _ in 0..<5 {
            weak var chat: Chat?
            do {
                _ = workspace.start(provider: "claude")
                let opened = workspace.activeTab.chat!
                opened.transcript.apply(.replayed(history(turns: 10)))
                opened.transcript.drawNow()
                chat = opened
                if let tab = workspace.tab(of: opened) { workspace.close(tab) }
            }
            await settle { chat == nil }
            if chat == nil { freed += 1 }
        }
        #expect(freed == 5)
    }
}

import Foundation
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// `chat.close` (the owner, 2026-11-17): a chat closes as its tab's close closes it, and only when
/// nothing in it would be lost; each hold is refused, never asked.
@MainActor
@Suite("Arsenal close", .serialized)
struct ArsenalCloseTests {
    private func window(_ count: Int) -> (Workspace, [Chat]) {
        let workspace = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-arsenal-close"), restore: false)
        let chats = (0..<count).map { n -> Chat in
            let chat = Chat(provider: .claude, folder: workspace.folder)
            chat.status.apply(.sessionIdentified("5e55\(n)abc-0000-4000-8000-000000000000"))
            return chat
        }
        workspace.tabs = chats.map { chat in
            let tab = ChatTab()
            tab.chat = chat
            return tab
        }
        return (workspace, chats)
    }

    private func refusal(_ result: Result<String, ArsenalRefusal>) -> String? {
        if case .failure(let refusal) = result { return refusal.message }
        return nil
    }

    @Test func eachHoldRefusesWithItsReason() {
        let holds: [(WritableKeyPath<ArsenalCloseHold, Bool>, String)] = [
            (\.turn, "It's working"), (\.network, "waits for the network"), (\.card, "A card in it waits"),
            (\.draft, "text not sent"), (\.attachments, "files not sent"), (\.agents, "sub-agents are running"),
            (\.commands, "Commands it started still run"), (\.boxAway, "box can't be reached"), (\.lastTab, "last tab"),
        ]
        #expect(ArsenalCloseHold().refusal == nil)
        for (flag, says) in holds {
            var hold = ArsenalCloseHold()
            hold[keyPath: flag] = true
            #expect(hold.refusal?.contains(says) == true, "\(says)")
        }
        // The first says why: a running turn before a draft.
        var both = ArsenalCloseHold()
        both.turn = true
        both.draft = true
        #expect(both.refusal?.hasPrefix("It's working") == true)
    }

    @Test func anIdleChatClosesAsItsTabDoesAndSaysHowToOpenItAgain() {
        let (workspace, chats) = window(2)
        let result = workspace.arsenalClose(chats[1])
        guard case .success(let said) = result else {
            Issue.record("refused: \(refusal(result) ?? "")")
            return
        }
        #expect(workspace.tabs.count == 1 && workspace.tabs[0].chat === chats[0])
        #expect(said.contains("kore open 5e551abc"))
    }

    @Test func unsentTextOrACommandChipHoldsIt() {
        let (workspace, chats) = window(2)
        chats[1].draft = "half a thought"
        #expect(refusal(workspace.arsenalClose(chats[1]))?.contains("text not sent") == true)
        chats[1].draft = "   "
        chats[1].command = SlashCommand(name: "review", description: "", hint: "", kind: .command)
        #expect(refusal(workspace.arsenalClose(chats[1]))?.contains("text not sent") == true)
        #expect(workspace.tabs.count == 2)
    }

    @Test func theWindowsLastTabIsTheUsers() {
        let (workspace, chats) = window(1)
        #expect(refusal(workspace.arsenalClose(chats[0]))?.contains("last tab") == true)
        #expect(workspace.tabs.count == 1 && workspace.tabs[0].chat === chats[0])
    }

    @Test func aBoxChatWaitsForItsBox() {
        let box = BoxBinding(alias: "closebox-\(UUID().uuidString.prefix(6))", folder: "/home/me/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        let chats = [box.newChat(.claude), box.newChat(.codex)]
        workspace.tabs = chats.map { chat in
            let tab = ChatTab()
            tab.chat = chat
            return tab
        }
        #expect(!box.connection.isOnline)
        #expect(refusal(workspace.arsenalClose(chats[1]))?.contains("box can't be reached") == true)
        #expect(workspace.tabs.count == 2)
    }
}

import Foundation
import KoreCore
import Testing

@testable import KoreUI

@MainActor @Suite("Tabs follow their own live work")
struct TabWorkTests {
    private func makeChat(_ provider: String) throws -> Chat {
        Chat(provider: try #require(Registry.provider(provider)), folder: URL(fileURLWithPath: "/tmp/tab-work-tests"))
    }

    private func spawn(_ id: String, in chat: Chat) {
        chat.transcript.agentSpawned(id: id, name: id, type: nil, background: true, tool: nil)
        chat.transcript.drawNow()
    }

    private func command(_ id: String, owner: AgentID = .main, kind: ActiveCommand.Kind = .shell) -> ActiveCommand {
        ActiveCommand(id: id, kind: kind, title: id, startedAt: .now, owner: owner)
    }

    @Test(arguments: ["claude", "codex"])
    func backgroundWorkKeepsItsChatMarkedUntilItsLastOwnerEnds(_ provider: String) throws {
        let chat = try makeChat(provider)
        defer { chat.close() }
        chat.status.setRunning(true)
        spawn("scout", in: chat)
        chat.status.setRunning(false)
        #expect(TabWork.running(chat))
        #expect(TabWork.running(chat, agent: "scout"))
        chat.commands.apply(.commandStarted(command("shell", owner: .sub("scout"))))
        chat.transcript.agentFinished(id: "scout", status: .finished, result: nil)
        chat.transcript.drawNow()
        #expect(TabWork.running(chat))
        #expect(TabWork.running(chat, agent: "scout"))
        chat.commands.apply(.commandEnded(id: "shell", .completed, at: .now))
        #expect(!TabWork.running(chat))
        #expect(!TabWork.running(chat, agent: "scout"))
    }

    @Test(arguments: ["claude", "codex"])
    func anotherChatAndSiblingAgentNeverInheritWork(_ provider: String) throws {
        let chat = try makeChat(provider), other = try makeChat(provider)
        defer { chat.close(); other.close() }
        spawn("done", in: chat)
        spawn("busy", in: chat)
        chat.transcript.agentFinished(id: "done", status: .finished, result: nil)
        chat.transcript.drawNow()
        chat.commands.apply(.commandStarted(command("sibling-shell", owner: .sub("busy"))))
        #expect(TabWork.running(chat))
        #expect(TabWork.running(chat, agent: "busy"))
        #expect(!TabWork.running(chat, agent: "done"))
        #expect(!TabWork.running(chat, agent: "missing"))
        #expect(!TabWork.running(other))
    }

    @Test(arguments: ["claude", "codex"])
    func armedSchedulesDoNotSpinAndClosingClearsAllMarks(_ provider: String) throws {
        let chat = try makeChat(provider)
        defer { chat.close() }
        chat.commands.apply(.commandStarted(command("later", kind: .scheduled)))
        #expect(chat.hasWork)
        #expect(!TabWork.running(chat))
        spawn("scout", in: chat)
        #expect(TabWork.running(chat))
        chat.close()
        #expect(!TabWork.running(chat))
        #expect(!TabWork.running(chat, agent: "scout"))
    }

    @Test(arguments: ["claude", "codex"])
    func stoppedAndFailedAgentsDoNotLeavePhantomLoading(_ provider: String) throws {
        let chat = try makeChat(provider)
        defer { chat.close() }
        for status in [TranscriptStore.AgentInfo.Status.stopped, .failed, .finished] {
            spawn("helper", in: chat)
            #expect(TabWork.running(chat))
            chat.transcript.agentFinished(id: "helper", status: status, result: nil)
            chat.transcript.drawNow()
            #expect(!TabWork.running(chat))
            #expect(!TabWork.running(chat, agent: "helper"))
        }
    }
}

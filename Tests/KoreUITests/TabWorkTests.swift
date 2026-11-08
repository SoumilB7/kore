import Foundation
import KoreCore
@testable import src
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

    /// bg-command-cue.html C: ">_" only while background commands run and the model is idle or
    /// waits on an approval; the model at work (or offline mid-turn) keeps the spinner.
    @Test func kindMapsTheModelAndItsBackgroundCommands() {
        typealias K = TabWork.Kind
        func kind(_ working: Bool, _ network: Bool, _ approval: Bool, _ commands: Bool) -> K {
            TabWork.kind(working: working, waitingForNetwork: network, approvalWaiting: approval, commands: commands)
        }
        #expect(kind(false, false, false, false) == .idle)
        #expect(kind(true, false, false, false) == .working)
        #expect(kind(false, true, false, false) == .working)
        #expect(kind(true, false, false, true) == .working)
        #expect(kind(false, true, false, true) == .working)
        #expect(kind(false, false, false, true) == .background)
        #expect(kind(true, false, true, true) == .background)
        #expect(kind(true, false, true, false) == .working)
        #expect(kind(false, false, true, false) == .idle)
    }

    @Test(arguments: ["claude", "codex"])
    func aShellOutlivingItsTurnTurnsTheSpinnerIntoThePrompt(_ provider: String) throws {
        let chat = try makeChat(provider)
        defer { chat.close() }
        chat.status.setRunning(true)
        chat.commands.apply(.commandStarted(command("build")))
        #expect(TabWork.kind(chat) == .working)
        chat.status.setRunning(false)
        #expect(TabWork.kind(chat) == .background)
        #expect(TabWork.running(chat))
        spawn("scout", in: chat)
        #expect(TabWork.kind(chat) == .working)
        chat.transcript.agentFinished(id: "scout", status: .finished, result: nil)
        chat.transcript.drawNow()
        #expect(TabWork.kind(chat) == .background)
        chat.commands.apply(.commandEnded(id: "build", .completed, at: .now))
        #expect(TabWork.kind(chat) == .idle)
        chat.commands.apply(.commandStarted(command("later", kind: .scheduled)))
        #expect(TabWork.kind(chat) == .idle)
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

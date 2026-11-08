import Foundation
import KoreCore
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// Link 1.13: a chat's meta says what it has going in the background, live sub-agents and running
/// background commands, as the tab's spinner counts them (an armed schedule isn't one), and leaves
/// the field out once nothing does.
@MainActor
@Suite("link background work")
struct LinkBackgroundTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-link-background-tests")

    @Test(arguments: ["claude", "codex"])
    func theMetaCountsLiveAgentsAndRunningCommands(_ provider: String) throws {
        let chat = Chat(provider: try #require(Registry.provider(provider)), folder: Self.folder)
        defer { chat.close() }
        #expect(LinkSnapshot.meta(chat).background == nil)

        chat.transcript.agentSpawned(id: "scout", name: "Scout", type: nil, background: true, tool: nil)
        chat.transcript.drawNow()
        chat.commands.apply(.commandStarted(ActiveCommand(id: "loop", kind: .shell, title: "loop", startedAt: .now, owner: .main)))
        chat.commands.apply(.commandStarted(ActiveCommand(id: "hourly", kind: .scheduled, title: "hourly", startedAt: .now, owner: .main)))
        #expect(LinkSnapshot.meta(chat).background == ChatBackground(agents: 1, commands: 1))
        #expect(LinkSnapshot.meta(chat, view: .full).background == ChatBackground(agents: 1, commands: 1))

        chat.transcript.agentFinished(id: "scout", status: .finished, result: nil)
        chat.transcript.drawNow()
        #expect(LinkSnapshot.meta(chat).background == ChatBackground(agents: 0, commands: 1))
        chat.commands.apply(.commandEnded(id: "loop", .completed, at: .now))
        #expect(LinkSnapshot.meta(chat).background == nil)
    }

    @Test func nothingRunningLeavesTheFieldOut() throws {
        #expect(ChatBackground.of(agents: 0, commands: 0) == nil)
        #expect(ChatBackground.of(agents: 0, commands: 2) == ChatBackground(agents: 0, commands: 2))
        let chat = Chat(provider: try #require(Registry.provider("claude")), folder: Self.folder)
        defer { chat.close() }
        let json = String(decoding: try JSONEncoder().encode(LinkSnapshot.meta(chat)), as: UTF8.self)
        #expect(!json.contains("background"))
    }
}

import Foundation
import Testing
@testable import KoreCore

@testable import KoreUI

/// The CLIs' own remote control in a chat: its "/" entry, its mark's line, and messages typed
/// on the remote side showing as the user's own.
@MainActor
@Suite("CLI remote control")
struct RemoteControlTests {
    // MARK: The / menu entry

    static let compact = SlashCommand(name: "compact", description: "", hint: "", kind: .command)
    static let cliRemote = SlashCommand(name: "remote-control", description: "the CLI's own", hint: "", kind: .command)

    func names(_ query: String, on: Bool = false, unavailable: String? = nil) -> [String] {
        SlashCommand.matches(
            [Self.compact, Self.cliRemote], sigil: "/", query: query, remote: .remote(on: on, unavailable: unavailable)
        ).map(\.label)
    }

    @Test func itFollowsAccountInPlaceOfTheCLIsOwn() {
        #expect(names("") == ["Usage", "Account", "Remote control", "/compact"])
        #expect(names("rem") == ["Remote control"])
        #expect(names("rc") == ["Remote control"])
        #expect(names("phone") == ["Remote control"])
    }

    @Test func itIsCheckedWhileOnAndDimWithTheReasonWhenTheCLICant() {
        #expect(SlashCommand.remote(on: true, unavailable: nil).on)
        let off = SlashCommand.remote(on: false, unavailable: "Not available for this login")
        #expect(off.unavailable && off.description == "Not available for this login")
        #expect(SlashCommand.remote(on: false, unavailable: nil).summary == "Continue on your phone or web")
    }

    // MARK: The mark

    @Test func theMarkSaysWhichCLIAndWhereInOneLine() {
        #expect(RemoteControl(state: .connected, place: "claude.ai/code").line(cli: "claude") == "Remote control · claude CLI · claude.ai/code")
        #expect(
            RemoteControl(state: .connected, place: "acme-mac.local", code: "LZSS-EREL").line(cli: "codex")
                == "Remote control · codex CLI · acme-mac.local · pairing code LZSS-EREL")
        #expect(RemoteControl(state: .connecting).line(cli: "codex") == "Remote control · codex CLI · connecting")
        #expect(RemoteControl(state: .failed("offline")).line(cli: "claude") == "Remote control · claude CLI · offline")
    }

    // MARK: Claude: messages from claude.ai/code

    static func echo(_ uuid: String, _ text: String, synthetic: Bool = false) -> ClaudeEvent {
        .userEcho(uuid: uuid, content: .string(text), synthetic: synthetic)
    }

    @Test(arguments: [true, false])
    func claudeShowsARemoteMessageAsItsTurnsPrompt(echoFirst: Bool) {
        let translator = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        translator.remoteActive = true
        let script = Script(.claude)
        if echoFirst { translator.translate(Self.echo("r1", "Add the check")) }
        translator.translate(.commandStarted(id: "r1", sessionId: nil))
        if !echoFirst { translator.translate(Self.echo("r1", "Add the check")) }
        translator.translate(.textDelta("Done.\n\n", parentToolUseId: nil))
        translator.take().events.forEach(script.store.apply)
        // The prompt heads the turn, as a sent message does, the answer under it.
        #expect(Array(script.lines.prefix(3)) == ["§ Add the check", "message Add the check", "answer Done.\n\n"])
    }

    @Test func claudeKeepsItsOwnSendsAndTheCLIsOwnMessagesOutOfIt() {
        let translator = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        translator.remoteActive = true
        translator.openTurn(.user)
        guard let own = translator.ownSend() else {
            Issue.record("no id for Kore's own send")
            return
        }
        translator.translate(Self.echo(own, "my own message"))
        translator.translate(Self.echo("peer", "a peer's note", synthetic: true))
        #expect(!translator.take().events.contains { if case .userMessage = $0 { true } else if case .messageQueued = $0 { true } else { false } })
    }

    @Test func claudeAddsARemoteMessageTakenMidTurnToTheTurn() {
        let translator = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        translator.remoteActive = true
        let script = Script(.claude)
        script.send("first")
        translator.openTurn(.user)
        translator.translate(.assistant(messageId: "m", content: [.toolUse(id: "t", name: "Bash", input: ["command": "true"])], parentToolUseId: nil, usage: nil))
        translator.translate(Self.echo("r2", "also the iOS client"))
        translator.take().events.forEach(script.store.apply)
        #expect(script.lines.contains("user also the iOS client"))
    }

    @Test func claudeIgnoresEchoesWhileItsOff() {
        let translator = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        #expect(translator.ownSend() == nil)
        translator.translate(.commandStarted(id: "r1", sessionId: nil))
        translator.translate(Self.echo("r1", "Add the check"))
        #expect(!translator.take().events.contains { if case .userMessage = $0 { true } else { false } })
    }

    // MARK: Codex: messages from its remote clients

    static func userItem(_ id: String, _ text: String) -> CodexEvent {
        .itemStarted(CodexItem(["type": "userMessage", "id": .string(id), "content": [["type": "text", "text": .string(text)]]]))
    }

    @Test func codexShowsARemoteTurnsFirstMessageAsItsPrompt() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.remoteActive = true
        let script = Script(.codex)
        translator.translate(.turnStarted(turnId: "remote"))
        translator.translate(Self.userItem("u1", "Add the check"))
        translator.translate(.textDelta(itemId: "a", "Done.\n\n"))
        translator.take().events.forEach(script.store.apply)
        // The prompt heads the turn, as a sent message does, the answer under it.
        #expect(Array(script.lines.prefix(3)) == ["§ Add the check", "message Add the check", "answer Done.\n\n"])
    }

    @Test func codexLeavesKoresOwnPromptAloneButShowsARemoteSteer() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.remoteActive = true
        let script = Script(.codex)
        script.send("mine")
        translator.ownTurnSent = true
        translator.translate(.turnStarted(turnId: "own"))
        translator.translate(Self.userItem("u1", "mine"))
        translator.translate(.itemStarted(CodexItem(["type": "commandExecution", "id": "c", "command": "true"])))
        translator.translate(Self.userItem("u2", "also the iOS client"))
        let events = translator.take().events
        #expect(!events.contains { if case .userMessage = $0 { true } else { false } })
        events.forEach(script.store.apply)
        #expect(script.lines.contains("user also the iOS client"))
    }
}

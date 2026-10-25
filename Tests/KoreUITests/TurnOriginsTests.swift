import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// A chat is at work whatever started its turn: each CLI's output in a turn Kore saw no start
/// of opens one, and the CLI's end of it closes it.
@MainActor
@Suite("Turn origins")
struct TurnOriginsTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-tests-turn-origins")

    static let answer = #"{"type":"assistant","parent_tool_use_id":null,"message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Looking."}]}}"#
    static let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#

    @Test func claudeOutputWithNoTurnOpenOpensOneTheResultEnds() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let started = try ActiveCommandsTests.claude(t, [Self.answer])
        #expect(started.contains { if case .turnStarted(_, .cli, _) = $0 { true } else { false } })
        let ended = try ActiveCommandsTests.claude(t, [Self.result])
        #expect(ended.contains { if case .turnFinished(_, .completed, _) = $0 { true } else { false } })
    }

    @Test func claudeOpensOneTurnForItsModelRequestAndTheOutputAfter() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try ActiveCommandsTests.claude(
            t, [#"{"type":"system","subtype":"status","status":"requesting"}"#, Self.answer, Self.answer])
        #expect(events.count { if case .turnStarted = $0 { true } else { false } } == 1)
    }

    @Test func aClaudeSubAgentsOutputOpensNoTurn() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let line = #"{"type":"assistant","parent_tool_use_id":"call-1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Sub."}]}}"#
        let events = try ActiveCommandsTests.claude(t, [line])
        #expect(!events.contains { if case .turnStarted = $0 { true } else { false } })
    }

    @Test func codexWorkWithNoTurnOpenOpensOneTurnCompletedEnds() {
        let t = CodexTranslator(folder: Self.folder)
        ActiveCommandsTests.codex(t, "item/started", ActiveCommandsTests.codexItem("i1", "inProgress", process: "11"))
        #expect(t.take().events.contains { if case .turnStarted = $0 { true } else { false } })
        ActiveCommandsTests.codex(t, "turn/completed", #"{"turn":{"id":"t1","status":"completed"}}"#)
        #expect(t.take().events.contains { if case .turnFinished(_, .completed, _) = $0 { true } else { false } })
    }

    @Test func aCodexTurnItStartedOpensOnce() {
        let t = CodexTranslator(folder: Self.folder)
        ActiveCommandsTests.codex(t, "turn/started", #"{"turn":{"id":"t1"}}"#)
        ActiveCommandsTests.codex(t, "item/started", ActiveCommandsTests.codexItem("i1", "inProgress", process: "11"))
        #expect(t.take().events.count { if case .turnStarted = $0 { true } else { false } } == 1)
    }
}

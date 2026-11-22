import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// The "/" commands Kore takes itself or keeps from the link: /clear's fresh transcript (the
/// chat's and a box's log), typed /model, /effort and /fast through Kore's own switches, the
/// Claude entries hidden, Codex's /review, /init and /goal, and a chat's list before its CLI starts.
@Suite("slash command fixes", .serialized)
@MainActor
struct SlashFixesTests {
    let box = BoxStateTests()

    // MARK: /clear

    @Test func claudesConversationResetIsParsedAndTranslated() {
        let json: JSONValue = ["type": "conversation_reset", "new_conversation_id": "s2", "uuid": "u1", "session_id": "s1", "trigger": "clear"]
        guard case .conversationReset("s2", "clear") = ClaudeEvent(message: json) else {
            Issue.record("not a reset")
            return
        }
        let translator = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp/reset"), sessionId: "s1")
        translator.translate(ClaudeEvent(message: json))
        #expect(translator.sessionId == "s2")
        #expect(translator.take().events.contains { if case .conversationReset("s2") = $0 { true } else { false } })
    }

    @Test(arguments: ["claude", "codex"])
    func clearStartsAFreshTranscriptOnTheNewSession(provider: String) async throws {
        let (rig, hc, made) = try box.rig(provider)
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        made.last.sink.yield(.text("b1", .answer, "before the clear"))
        try await until { chat.transcriptView.entries.contains { $0.text == "before the clear" } }
        let log = hc.stream.id
        made.last.sink.yield(.conversationReset("s2"))
        try await until { chat.sessionId == "s2" && hc.record.session == "s2" }
        #expect(!chat.transcriptView.entries.contains { $0.text == "before the clear" })
        // The box's log starts again, so its followers rebuild, and says the new session last.
        #expect(hc.stream.id != log)
        let items = await box.logged(hc)
        let sessions = items.compactMap { if case .sessionIdentified(let id)? = $0.e { id } else { nil } }
        #expect(sessions.last == "s2")
        #expect(!items.contains { if case .conversationReset? = $0.e { true } else { false } })
        #expect(!items.contains { if case .text(_, _, "before the clear", _)? = $0.e { true } else { false } })
    }

    // MARK: Typed controls

    @Test(arguments: ["claude", "codex"])
    func typedModelEffortAndFastMoveKoresControls(provider: String) async throws {
        let (rig, hc, made) = try box.rig(provider)
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { !chat.controls.models.isEmpty && chat.controls.fastKnown }
        chat.draft = "/model tiny"
        chat.send()
        try await until { made.last.calls.contains("model tiny") }
        #expect(chat.controls.modelId == "tiny" && chat.draft.isEmpty)
        // Not in the CLI's list: nothing switches, the line says what is.
        chat.draft = "/model huge"
        chat.send()
        #expect(chat.controls.modelId == "tiny")
        #expect(chat.transcriptView.entries.contains { $0.kind == .notice && $0.text == "No model huge here; one of: big, tiny" })
        // By its name too, then an effort the model offers.
        #expect(chat.sendFromLink("/model Big"))
        try await until { made.last.calls.contains("model big") }
        #expect(chat.sendFromLink("/effort LOW"))
        try await until { made.last.calls.contains("effort low") }
        #expect(chat.controls.effort == "low")
        chat.draft = "/effort max"
        chat.send()
        #expect(chat.controls.effort == "low" && !made.last.calls.contains("effort max"))
        // /fast: Kore's own switch.
        chat.draft = "/fast"
        chat.send()
        try await until { made.last.calls.contains("fast true") }
        try await until { chat.controls.fastMode && !chat.controls.fastChanging }
        chat.draft = "/fast off"
        chat.send()
        try await until { made.last.calls.contains("fast false") }
        #expect(!made.last.calls.contains { $0.hasPrefix("send") })
    }

    @Test func typedControlsAreReadOnce() {
        #expect(Chat.typedControl("/model opus") == .model("opus"))
        #expect(Chat.typedControl("  /effort  high ") == .effort("high"))
        #expect(Chat.typedControl("/fast ON") == .fast("on"))
        #expect(Chat.typedControl("/models") == nil && Chat.typedControl("model x") == nil && Chat.typedControl("/fast-forward") == nil)
    }

    // MARK: Lists

    @Test func claudesBrokenAndInternalEntriesAreHidden() {
        let live = ClaudeBackend.commands([
            ["name": "focus"], ["name": "color"], ["name": "heapdump"], ["name": "__debug"], ["name": "workflow-launch-exec"],
            ["name": "old", "description": "Does a thing (removed)"], ["name": "fast", "description": "Toggle fast mode"], ["name": "context"],
            ["name": "clear"],
        ])
        #expect(live.map(\.name) == ["fast", "context", "clear", "rename"])
    }

    // MARK: Codex

    @Test func codexsOwnCommandsMapToItsRequests() {
        let names = CodexBackend.builtinCommands.map(\.name)
        #expect(names.contains("review") && names.contains("init") && !names.contains("clear"))
        #expect(CodexBackend.typed("/review") == .review(["type": "uncommittedChanges"]))
        #expect(CodexBackend.typed("/review the auth change") == .review(["type": "custom", "instructions": "the auth change"]))
        #expect(CodexBackend.typed("/init") == .prompt(CodexBackend.initPrompt))
        #expect(CodexBackend.initPrompt.hasPrefix("Generate a file named AGENTS.md") && CodexBackend.initPrompt.hasSuffix("Agent-Specific Instructions."))
        #expect(CodexBackend.typed("/goal") == .goalShow)
        #expect(CodexBackend.typed("/goal clear") == .goalClear)
        #expect(CodexBackend.typed("/goal ship 0.3.9") == .goal("ship 0.3.9"))
        #expect(CodexBackend.typed("/plan") == .plan && CodexBackend.typed("/compact") == .compact)
        #expect(CodexBackend.typed("/rename") == .rename("") && CodexBackend.typed("hello /goal") == nil && CodexBackend.typed("/skill-x") == nil)
    }

    @Test func aBareGoalSaysTheGoalOrHowToSetOne() {
        #expect(CodexBackend.goalLine(nil) == "No goal set. Usage: /goal <objective>, or /goal clear")
        #expect(CodexBackend.goalLine(["objective": "ship it", "status": "active", "threadId": "th1"]) == "Goal: ship it (active)")
    }

    @Test func aReviewsFindingsAreTheTurnsAnswer() {
        let t = CodexTranslator(folder: URL(fileURLWithPath: "/tmp/codex-review"))
        t.translate(CodexEvent(notification: "turn/started", params: ["threadId": "th1", "turn": ["id": "t1", "status": "inProgress"]]))
        t.translate(CodexEvent(notification: "item/completed", params: ["threadId": "th1", "turnId": "t1", "item": ["type": "exitedReviewMode", "id": "r1", "review": "No issues found."]]))
        let events = t.take().events
        #expect(events.contains { if case .text("r1", .answer, "No issues found.", .main) = $0 { true } else { false } })
        #expect(events.contains { if case .finalAnswer("r1", .main) = $0 { true } else { false } })
    }
}

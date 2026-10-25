import Foundation
import Testing

@testable import KoreUI

/// The transcript's placement rules (look.md §5, §8, §10, §11), from short event sequences.
@MainActor
@Suite("Transcript rules")
struct TranscriptRulesTests {
    private func label(_ id: String) -> String { ProviderDescriptor.claude.modes.first { $0.id == id }?.label ?? id }

    private func mode(_ to: String, from: String?, _ source: ModeSource = .user) -> ChatEvent {
        .modeChanged(ModeChange(mode: to, previous: from, source: source, at: Date()))
    }

    /// A first turn finished, a second running a Bash call.
    private func running() -> Script {
        let s = Script()
        s.turn("t1", "first")
        s.send("second")
        s.start("t2")
        s.tool("b1")
        return s
    }

    // MARK: Queued messages (§10)

    @Test func aQueuedMessageWaitsAfterTheSpinner() {
        let s = running()
        let before = s.sections.count
        s.on(.messageQueued(id: "q", text: "waiting", attachments: []))
        #expect(s.lines.suffix(2) == ["spinner", "queued waiting"])
        #expect(s.sections.count == before)
    }

    /// It lands after its anchor, in the turn, and starts a section there: the latest message
    /// is the one that sticks (owner, 2026-10-26).
    @Test func inTurnLandsAfterItsAnchorInASectionOfItsOwn() {
        let s = running()
        s.on(.messageQueued(id: "q", text: "waiting", attachments: []))
        let before = s.sections.count
        s.on(.queuedMessage(id: "q", .inTurn(after: "b1")))
        #expect(s.lines.suffix(4) == ["tool Bash running", "§ waiting", "user waiting", "spinner"])
        #expect(s.sections.count == before + 1)
        // Pinned: it stays in sight, above the answer, when the turn folds.
        s.done("b1")
        s.say("a2", "answer")
        s.finish("t2")
        #expect(Array(s.lines.suffix(5)) == ["fold", "rule", "§ waiting", "user waiting", "answer answer"])
    }

    @Test func nextTurnOpensItsOwnSection() {
        let s = running()
        s.on(.messageQueued(id: "q", text: "next one", attachments: []))
        s.done("b1")
        s.finish("t2")
        s.on(.queuedMessage(id: "q", .nextTurn("t3")))
        s.start("t3")
        #expect(s.sections.last?.header?.text == "next one")
        #expect(!s.lines.contains("queued next one"))
    }

    @Test func aDroppedMessageGoes() {
        let s = running()
        s.on(.messageQueued(id: "q", text: "never sent", attachments: []))
        s.on(.queuedMessage(id: "q", .dropped))
        #expect(!s.lines.contains { $0.hasSuffix("never sent") })
    }

    // MARK: Stop

    /// Both CLIs fold interrupted work alike. Any earlier assistant write-up stays readable;
    /// Codex's command completes after the turn ends and stays stopped.
    @Test func aStoppedTurnFoldsTheSameForBothCLIs() throws {
        func folded(_ name: String) throws -> [String] {
            let s = Script(name.hasPrefix("codex") ? .codex : .claude)
            try Recorded.events(name).forEach(s.store.apply)
            return s.lines.dropFirst(2).map { $0.replacingOccurrences(of: "tool Run", with: "tool Bash") }
        }
        let claude = try folded("claude-stop")
        #expect(claude == ["fold interrupted", "rule", "tool Bash stopped"])
        let codex = try folded("codex-stop")
        #expect(codex.filter { !$0.hasPrefix("answer ") } == claude)
        #expect(codex.contains("answer I’ll run that exact loop in the foreground."))
    }

    @Test func anInterruptClosesOpenCalls() {
        let s = running()
        s.finish("t2", .interrupted)
        #expect(s.lines.contains("tool Bash stopped"))
        #expect(!s.lines.contains("spinner"))
    }

    // MARK: Modes (§8)

    @Test func theUsersChangesMergeAndCancelOut() {
        let s = Script()
        s.on(mode("default", from: nil, .session))
        s.turn("t1", "first")
        s.on(mode("acceptEdits", from: "default"), mode("plan", from: "acceptEdits"))
        #expect(s.lines.filter { $0.hasPrefix("mode") } == ["mode \(label("plan"))"])
        s.on(mode("default", from: "plan"))
        #expect(!s.lines.contains { $0.hasPrefix("mode") })
    }

    @Test func aChangeDuringATurnShowsAfterIt() {
        let s = running()
        s.on(mode("acceptEdits", from: "default"))
        #expect(!s.lines.contains { $0.hasPrefix("mode") })
        s.done("b1")
        s.finish("t2")
        #expect(s.lines.last == "mode \(label("acceptEdits"))")
    }

    @Test func theAgentsChangeIsATimelineItemAndMarksTheFold() {
        let s = Script()
        s.on(mode("default", from: nil, .session))
        s.send("plan it")
        s.start("t1")
        s.tool("e1", "EnterPlanMode")
        s.done("e1")
        s.on(mode("plan", from: "default", .agent(.enteredPlanMode, .main)))
        #expect(s.lines.contains("mode Entered \(label("plan"))"))
        s.say("a", "planned")
        s.finish("t1")
        #expect(s.lines.contains("fold now \(label("plan"))"))
    }

    /// A new chat's first turn starts before the CLI names its mode. Plan entered and approved
    /// back to that mode is no change: no " · now".
    @Test func aRoundTripOnTheFirstTurnIsNoChange() throws {
        let s = Script()
        try Recorded.events("claude-plan").forEach(s.store.apply)
        #expect(s.lines.contains("fold"))
        #expect(!s.lines.contains { $0.contains(" now ") })
    }

    @Test func aRefusedChangeIsAWarning() {
        let s = Script()
        s.on(mode("default", from: nil, .session))
        s.on(mode("default", from: "acceptEdits", .refused))
        #expect(s.lines.contains("notice Couldn't switch to \(label("acceptEdits")) · staying on \(label("default"))"))
    }

    // MARK: Compaction, fork, actions (§5, §11)

    @Test func aCompactionLeavesItsDividerThenTheSummary() throws {
        let s = Script()
        try Recorded.events("claude-compact").forEach(s.store.apply)
        let lines = s.lines
        let divider = try #require(lines.firstIndex { $0.hasPrefix("divider Conversation compacted · ") })
        #expect(lines[divider + 1].hasPrefix("summary "))
        #expect(s.items.last.map { if case .summary = $0.row { true } else { false } } == true)
    }

    @Test func aForkMarksWhereItsOwnPartBegins() {
        let s = Script()
        s.on(.replayed([
            .userMessage(text: "old", attachments: [], id: "u1"),
            .turnStarted("r1", origin: .user, at: Date()), .text("a", .answer, "hi"), .turnFinished("r1", .completed, duration: nil),
        ]))
        s.store.forkedFrom("Old chat")
        s.send("new")
        #expect(s.lines.contains("divider Forked from \u{201C}Old chat\u{201D}"))
        let divider = s.items.lazy.compactMap { if case .entry(let e) = $0.row, e.kind == .divider { e } else { nil } }.first
        #expect(divider?.source == TranscriptStore.forkSource)
    }

    /// One answer shows its actions always: the newest finished one. The running turn's message
    /// can't be forked from.
    @Test func actionsFollowTheNewestAnswer() {
        let s = Script()
        s.turn("t1", "first")
        s.send("second")
        s.start("t2")
        func actions(_ text: String) -> TranscriptStore.MessageActions? {
            s.items.first { item in
                switch item.row {
                case .message(let e, _, _), .entry(let e): e.text == text
                default: false
                }
            }?.actions
        }
        #expect(actions("answer t1")?.always == true)
        #expect(actions("first")?.canFork == true)
        #expect(actions("second")?.canFork == false)
        s.say("t2-answer", "answer t2")
        s.on(.finalAnswer("t2-answer"))
        s.finish("t2")
        #expect(actions("answer t1")?.always == false)
        #expect(actions("answer t2")?.always == true)
        #expect(actions("second")?.canFork == true)
        #expect(s.items.filter { $0.actions?.always == true }.count == 1)
    }
}

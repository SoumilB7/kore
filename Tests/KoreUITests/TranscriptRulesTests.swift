import Foundation
@testable import src
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
        #expect(claude == ["fold interrupted", "rule", "tool Bash stopped", "outcome Interrupted"])
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

    /// A second width step with the reader's row kept: its frames still at the width before are
    /// the lazy stack's guesses and move nobody; its first frame at the new width moves the view
    /// by as much as it moved.
    @Test func quickWidthStepWaitsForTheRowsNewWidth() {
        let hold = WidthHold()
        let offset: CGFloat = 4257
        func y(_ put: WidthHold.Put?) -> CGFloat? {
            if case .hold(.offset(let y)) = put { return y }
            return nil
        }
        _ = hold.placed("row", CGRect(x: 44, y: 2800, width: 912, height: 2374), offset: offset, inset: 0, visible: 623, following: false)
        hold.rest = (offset, false)
        #expect(y(hold.placed("row", CGRect(x: 40, y: 360, width: 820, height: 2374), offset: offset, inset: 0, visible: 623, following: false)) == offset - 2440)
        hold.resized()
        #expect(hold.placed("row", CGRect(x: 36, y: 1962, width: 820, height: 2374), offset: 1817, inset: 0, visible: 623, following: false) == nil)
        #expect(hold.holding)
        #expect(y(hold.placed("row", CGRect(x: 36, y: 2398, width: 728, height: 2374), offset: 1817, inset: 0, visible: 623, following: false)) == offset - 402)
    }

    /// The first width step: another row's frame still at the old width comes between, and the
    /// row kept's next frame at the old width is a guess too; its first at the new width says.
    @Test func firstWidthStepWaitsForTheRowsNewWidth() {
        let hold = WidthHold()
        let offset: CGFloat = 4267
        func y(_ put: WidthHold.Put?) -> CGFloat? {
            if case .hold(.offset(let y)) = put { return y }
            return nil
        }
        _ = hold.placed("row", CGRect(x: 40, y: 2800, width: 912, height: 2374), offset: offset, inset: 0, visible: 623, following: false)
        hold.rest = (offset, false)
        #expect(y(hold.placed("other", CGRect(x: 40, y: 5300, width: 820, height: 900), offset: offset, inset: 0, visible: 623, following: false)) == offset)
        _ = hold.placed("next", CGRect(x: 40, y: 6300, width: 912, height: 900), offset: offset, inset: 0, visible: 623, following: false)
        #expect(hold.placed("row", CGRect(x: 40, y: 4400, width: 912, height: 2374), offset: offset, inset: 0, visible: 623, following: false) == nil)
        #expect(hold.holding)
        // Carried out of the built rows before it's laid out at the new width: held, not sought.
        #expect(hold.left("row") == nil)
        #expect(hold.seeking == nil)
        #expect(y(hold.placed("row", CGRect(x: 36, y: 2400, width: 820, height: 2374), offset: offset, inset: 0, visible: 623, following: false)) == offset - 400)
    }

    /// The row kept leaves the built rows before it's laid out at the new width, the rows above
    /// it laid out anew by estimates: the rows after it, laid out at the old width some time
    /// (their heights known), say where it went by where they are at the new one.
    @Test func rowsAfterTheRowKeptSayWhereItWent() {
        let hold = WidthHold()
        hold.order = { ["a1", "u2", "row", "u3", "a3"] }
        let offset: CGFloat = 4417
        func y(_ put: WidthHold.Put?) -> CGFloat? {
            if case .hold(.offset(let y)) = put { return y }
            return nil
        }
        // Laid out at the old width, the end first: the rows after it aren't built any more.
        _ = hold.placed("u3", CGRect(x: 40, y: 5330, width: 912, height: 68), offset: 5000, inset: 0, visible: 623, following: false)
        _ = hold.placed("a3", CGRect(x: 40, y: 5398, width: 912, height: 2374), offset: 5000, inset: 0, visible: 623, following: false)
        _ = hold.left("u3")
        _ = hold.left("a3")
        _ = hold.placed("row", CGRect(x: 40, y: 2956, width: 912, height: 2374), offset: offset, inset: 0, visible: 623, following: false)
        hold.rest = (offset, false)
        hold.resized()
        // The new width: a row after it first, at a place of the lazy stack's.
        #expect(y(hold.placed("a4", CGRect(x: 40, y: 5244, width: 820, height: 2374), offset: offset, inset: 0, visible: 623, following: false)) == offset)
        // Its own frame still at the old width, a guess, and the view carried off it.
        #expect(hold.placed("row", CGRect(x: 40, y: 4557, width: 912, height: 2374), offset: offset, inset: 0, visible: 623, following: false) == nil)
        #expect(hold.left("row") == nil)
        // The row after it, laid out at the new width: the view goes as far as that row went.
        #expect(y(hold.placed("a3", CGRect(x: 40, y: 2802, width: 820, height: 2374), offset: offset, inset: 0, visible: 623, following: false)) == offset - 2596)
        // And then by its own frame at the new width.
        #expect(y(hold.placed("row", CGRect(x: 40, y: 360, width: 820, height: 2374), offset: 1821, inset: 0, visible: 623, following: false)) == offset - 2596)
    }
}

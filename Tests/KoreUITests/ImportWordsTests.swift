import Foundation
import Testing

@testable import KoreCore
@testable import KoreUI

/// An import's settings in the target CLI's terms, and the picker's footer words.
@MainActor
@Suite("Import mapping and words")
struct ImportWordsTests {
    private func preview(format: String, mode: String? = nil, effort: String? = nil, turns: Int = 23, carried: Int? = nil, summary: Bool = false)
        -> HandoffPreview
    {
        var segment = HandoffSegment(source: format, product: format == "claude" ? "Claude Code" : "Codex", sessionId: "s")
        segment.mode = mode
        segment.effort = effort
        segment.summary = summary ? "earlier" : nil
        segment.turns = (0..<turns).map { HandoffTurn(id: "t\($0)", prompt: String(repeating: "p", count: 4000)) }
        let window = carried.map { _ in 30_000 } ?? 1_000_000
        return HandoffPreview(segment, HandoffBudget.plan(segment, window: window), file: URL(fileURLWithPath: "/tmp/x.jsonl"))
    }

    @Test func modesFollowTheirRung() {
        // Edit automatically has no Codex rung: Ask for approval.
        #expect(ImportMapping.settings(preview(format: "claude", mode: "acceptEdits"), into: .codex, model: nil)?.mode == "askForApproval")
        #expect(ImportMapping.settings(preview(format: "claude", mode: "auto"), into: .codex, model: nil)?.mode == "approveForMe")
        let plan = ImportMapping.settings(preview(format: "claude", mode: "plan"), into: .codex, model: nil)
        #expect(plan?.planMode == true)
        // Full access: Bypass isn't offered, so Edit automatically.
        #expect(ImportMapping.settings(preview(format: "codex", mode: "fullAccess"), into: .claude, model: nil)?.mode == "acceptEdits")
        #expect(ImportMapping.settings(preview(format: "codex", mode: "plan"), into: .claude, model: nil)?.mode == "plan")
        #expect(ImportMapping.settings(preview(format: "codex", mode: "askForApproval"), into: .claude, model: nil)?.mode == "default")
    }

    @Test func effortsMeetWhatTheModelOffers() {
        #expect(ImportMapping.effort("minimal", offered: []) == "low")
        #expect(ImportMapping.effort("ultra", offered: ["low", "medium", "high", "xhigh", "max"]) == "max")
        #expect(ImportMapping.effort("max", offered: ["low", "medium", "high", "xhigh"]) == "xhigh")
        #expect(ImportMapping.effort(nil, offered: ["low"]) == nil)
    }

    @Test func theFooterCountsWhatIsCarried() {
        #expect(ImportState.count(preview(format: "claude")) == "23 turns")
        let big = preview(format: "claude", carried: 0)
        #expect(ImportState.count(big).contains(" of 23 turns"))
        #expect(ImportState.breakdown(big).contains("earlier not carried"))
        #expect(ImportState.count(preview(format: "claude", turns: 3, summary: true)) == "Summary + 3 turns")
        #expect(ImportState.tokens(preview(format: "claude", turns: 1)).hasPrefix("~"))
    }

    @Test func carriedTurnsShowAsPromptStepsAndReply() {
        var turn = HandoffTurn(id: "t", prompt: "Check the build.")
        turn.steps = [HandoffStep(kind: .command, tool: "Bash", title: "cat BUILD", output: "Build 7781")]
        turn.reply = "7781."
        turn.end = .interrupted
        let events = ImportedEvents.events([turn])
        #expect(events.contains { if case .userMessage(let text, _, _) = $0 { text == "Check the build." } else { false } })
        #expect(events.contains { if case .toolFinished(_, let output, false, _) = $0 { output == "Build 7781" } else { false } })
        #expect(events.contains { if case .text(_, .answer, "7781.", _) = $0 { true } else { false } })
        #expect(events.contains { if case .turnFinished(_, .interrupted, _) = $0 { true } else { false } })
    }
}

import Foundation
import Testing

@testable import KoreUI

@MainActor
struct FoldedWriteupsTests {
    @Test(arguments: [ProviderDescriptor.claude, .codex])
    func earlierWriteupsStayCompleteAndOrdered(_ provider: ProviderDescriptor) {
        let s = Script(provider)
        let first = "First findings\n\n" + String(repeating: "Detail line.\n", count: 12)
        let second = "Second findings with **important detail**."
        s.send("Review the changes")
        s.start("t1")
        s.say("a1", first)
        s.tool("check")
        s.done("check")
        s.say("a2", second)
        s.tool("verify")
        s.done("verify")
        s.say("a3", "Final result")
        s.on(.finalAnswer("a3"))
        s.finish("t1")

        func answers() -> [String] {
            s.items.compactMap { if case .entry(let e) = $0.row, e.kind == .answer { e.text } else { nil } }
        }
        #expect(answers() == [first, second, "Final result"])
        #expect(!s.items.contains { if case .tool = $0.row { true } else { false } })
        #expect(s.items.filter { $0.actions?.always == true }.count == 1)
        s.store.toggle(turn: "t1")
        #expect(answers() == [first, second, "Final result"])
        #expect(s.items.filter { if case .tool = $0.row { true } else { false } }.count == 2)
        s.store.toggle(turn: "t1")
        #expect(answers() == [first, second, "Final result"])
    }

    @Test(arguments: [ProviderDescriptor.claude, .codex])
    func interruptedWorkStillKeepsTheWriteup(_ provider: ProviderDescriptor) {
        let s = Script(provider)
        s.send("Investigate")
        s.start("t1")
        s.say("a1", "A finding before interruption")
        s.tool("check")
        s.finish("t1", .interrupted)
        #expect(s.lines.contains("answer A finding before interruption"))
        #expect(s.lines.contains("tool Bash stopped"))
        #expect(!s.lines.contains("spinner"))
    }

    @Test func expandingALiveTurnKeepsEveryEntryOnce() {
        let s = Script()
        s.send("Investigate")
        s.start("t1")
        s.say("a1", "Progress so far")
        s.tool("check")
        _ = s.items
        s.store.toggle(turn: "t1")
        #expect(!s.lines.contains("answer Progress so far"))
        s.store.toggle(turn: "t1")
        #expect(s.lines.filter { $0 == "answer Progress so far" }.count == 1)
    }
}

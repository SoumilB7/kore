import Foundation
import Testing
@testable import KoreUI

@MainActor @Suite("Retry after unfinished work")
struct TurnRetryTests {
    private func retryRows(_ script: Script) -> [String] {
        script.sections.flatMap(\.items).compactMap {
            if case .outcome(let turn, _, _, _, true) = $0.row { turn } else { nil }
        }
    }

    @Test func foldedInterruptedToolStillOffersRetryAndANewMessageRemovesIt() {
        let script = Script()
        script.send("Work")
        script.start("stopped")
        script.tool("tool")
        script.finish("stopped", .interrupted)
        #expect(retryRows(script) == ["stopped"])
        #expect(script.store.retryableTurn == "stopped")
        #expect(script.lines.contains("tool Bash stopped"))
        script.send("Continue")
        #expect(retryRows(script).isEmpty && script.store.retryableTurn == nil)
        script.start("next")
        script.say("answer", "Done")
        script.finish("next")
        #expect(retryRows(script).isEmpty)
        #expect(script.sections.map(\.id) == script.store.sectionsFromScratch().map(\.id))
    }

    @Test func terminalFailureSettlesAbandonedToolAndOffersRetryWithoutAnAnswer() {
        let script = Script()
        script.send("Work")
        script.start("failed")
        script.tool("tool")
        script.finish("failed", .failed("Connection lost"))
        #expect(retryRows(script) == ["failed"])
        #expect(script.lines.contains("tool Bash stopped"))
        #expect(!script.store.workRunning)
    }

    @Test func quietWorkRemainsRunningUntilAnExplicitEnd() {
        let script = Script()
        script.send("Work")
        script.start("working")
        script.tool("tool")
        #expect(script.store.workRunning && script.store.turnIsOpen)
        #expect(script.lines.contains("tool Bash running"))
        #expect(retryRows(script).isEmpty)
        script.on(.exited(status: 1))
        #expect(retryRows(script) == ["working"])
        #expect(script.lines.contains("tool Bash stopped"))
    }

    @Test func completedAndSpecialRecoveryStatesKeepTheirOwnActions() {
        for outcome in [TurnOutcome.completed, .authFailed("Sign in"), .slept("Mac slept")] {
            let script = Script()
            script.send("Work")
            script.start("turn")
            script.finish("turn", outcome)
            #expect(retryRows(script).isEmpty && script.store.retryableTurn == nil)
        }
    }
}

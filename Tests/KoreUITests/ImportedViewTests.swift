import Foundation
import KoreCore
import Testing

@testable import KoreUI

@Suite("An imported chat as its model got it")
struct ImportedViewTests {
    func turn(_ id: String, _ level: HandoffPlan.Level) -> HandoffTurn {
        var turn = HandoffTurn(id: id, prompt: "p \(id)")
        turn.reply = "r"
        turn.carriedAs = level
        return turn
    }

    @Test func oneQuietLineWhereTheCarriedDetailChanges() {
        let events = ImportedEvents.events([turn("a", .bare), turn("b", .bare), turn("c", .condensed), turn("d", .full)])
        let notices = events.compactMap { event -> String? in
            if case .notice(let text, _) = event { return text } else { return nil }
        }
        #expect(notices == [
            "Carried as prompt and reply only from here", "Carried shortened from here: steps one line each", "Carried in full from here",
        ])
        // Every turn in full: no line at all.
        #expect(!ImportedEvents.events([turn("a", .full), turn("b", .full)]).contains { if case .notice = $0 { true } else { false } })
    }
}

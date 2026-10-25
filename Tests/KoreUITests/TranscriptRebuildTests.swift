import Foundation
import Testing

@testable import KoreUI

/// Package C's incremental rebuild keeps the sections above the first change and builds the
/// rest again. Whatever arrives, and however it's batched, the result has to equal building
/// every section from scratch.
@MainActor
@Suite("Transcript: incremental rebuild equals a full one")
struct TranscriptRebuildTests {
    private func shown(_ store: TranscriptStore) -> [TranscriptStore.Section] {
        store.sections.map { .init(id: $0.id, header: $0.header, headerOpen: $0.headerOpen, items: $0.items) }
    }

    /// Draws what's pending and compares; `step` says where in the run it failed.
    private func check(_ store: TranscriptStore, _ step: @autoclosure () -> String) {
        store.drawNow()
        let incremental = shown(store)
        // As the view has them: where a section's turn starts is the store's own bookkeeping.
        let full = store.sectionsFromScratch().map { TranscriptStore.Section(id: $0.id, header: $0.header, headerOpen: $0.headerOpen, items: $0.items) }
        #expect(incremental == full, "\(step())")
    }

    @Test(arguments: Recorded.claude + Recorded.codex)
    func afterEveryEvent(_ name: String) throws {
        let store = TranscriptStore()
        for (i, event) in try Recorded.events(name).enumerated() {
            store.apply(event)
            check(store, "\(name), event \(i): \(tag(event))")
        }
    }

    @Test(arguments: [1, 2, 3, 42, 2026] as [UInt64])
    func inRandomBatches(seed: UInt64) throws {
        var random = Seeded(seed)
        let events = try Recorded.all()
        let store = TranscriptStore()
        var i = 0
        while i < events.count {
            let n = Int.random(in: 1...12, using: &random)
            for event in events[i..<min(i + n, events.count)] { store.apply(event) }
            i += n
            check(store, "seed \(seed), through event \(i)")
        }
    }

    /// Opening and closing rows and folds between events marks only part of the transcript
    /// dirty: the kept sections must still match.
    @Test(arguments: [7, 99] as [UInt64])
    func withToggles(seed: UInt64) throws {
        var random = Seeded(seed)
        let store = TranscriptStore()
        for (i, event) in try Recorded.all().enumerated() {
            store.apply(event)
            if Int.random(in: 0..<4, using: &random) == 0 {
                store.drawNow()
                let items = store.sections.flatMap(\.items)
                if let item = items.randomElement(using: &random) {
                    if case .fold(let fold) = item.row {
                        store.toggle(turn: fold.turn)
                    } else {
                        store.toggle(item.id)
                    }
                }
            }
            check(store, "seed \(seed), event \(i)")
        }
    }

    /// A resumed chat opens on its last turns; Load earlier shows the rest, and live events
    /// after it still rebuild in step.
    @Test func loadEarlierThenLive() throws {
        // Some unanswered messages first, so there are more user turns than the window's ten.
        let past = (1...6).map { ChatEvent.userMessage(text: "earlier \($0)", attachments: []) }
            + (try Recorded.claude.flatMap(Recorded.events))
        let live = try Recorded.codex.flatMap(Recorded.events)
        let store = TranscriptStore()
        store.replay(past)
        check(store, "replayed")
        #expect(store.hiddenTurns > 0)
        store.loadEarlier()
        check(store, "loaded earlier")
        #expect(store.hiddenTurns == 0)
        for (i, event) in live.enumerated() {
            store.apply(event)
            check(store, "live event \(i) after Load earlier")
        }
    }

    /// An earlier page goes above what's there: everything shifts, and the next events must
    /// still land right.
    @Test func prependThenLive() throws {
        let store = TranscriptStore()
        let earlier = try Recorded.events("claude-tool") + Recorded.events("codex-tool")
        let later = try Recorded.events("claude-queued-inturn")
        let next = try Recorded.events("codex-steer")
        later.forEach(store.apply)
        check(store, "before the page")
        store.startLoadingEarlier()
        store.prepend(earlier, more: false)
        check(store, "page prepended")
        for (i, event) in next.enumerated() {
            store.apply(event)
            check(store, "event \(i) after the page")
        }
    }
}

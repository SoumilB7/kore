import Foundation
import Testing

@testable import KoreUI

/// The composer's wheel: usage from the CLI, and a compaction from its start to its end.
@MainActor
@Suite("Context store")
struct ContextStoreTests {
    private func usage(_ used: Int, _ window: Int?) -> ChatEvent {
        .contextUsage(ContextUsage(used: used, window: window, autoCompacts: true, at: Date()))
    }

    @Test func usageFillsTheWheel() {
        let store = ContextStore()
        #expect(store.fraction == nil)
        store.apply(usage(500, nil))
        #expect(store.fraction == nil)
        store.apply(usage(50_000, 200_000))
        #expect(store.fraction == 0.25)
        store.apply(usage(300_000, 200_000))
        #expect(store.fraction == 1)
    }

    @Test func aCompactionRunsFromStartToEnd() {
        for end: ChatEvent in [.compacted(at: Date()), .compactionFailed("no"), .exited(status: 1)] {
            let store = ContextStore()
            store.apply(.compactionStarted(auto: false))
            #expect(store.compacting)
            store.apply(end)
            #expect(!store.compacting)
        }
    }

    /// A replay ends with no compaction running, and with its last usage.
    @Test func aReplayLeavesNothingRunning() {
        let store = ContextStore()
        store.apply(.replayed([usage(10, 100), .compactionStarted(auto: true)]))
        #expect(!store.compacting)
        #expect(store.usage?.used == 10)
    }

    /// The recorded `/compact` run: compacting while it runs, done after.
    @Test func theRecordedCompaction() throws {
        let store = ContextStore()
        var seen = false
        for event in try Drive.claude("claude-compact") {
            store.apply(event)
            if store.compacting { seen = true }
        }
        #expect(seen)
        #expect(!store.compacting)
        #expect(store.fraction != nil)
    }

    @Test func labels() {
        #expect([999, 1_234, 18_400, 1_100_000].map(ContextStore.tokens) == ["999", "1.2k", "18k", "1.1M"])
    }

    /// One count everywhere, at most three figures: 403k, not 402.9k; no "1000k" or "10.0k".
    @Test func tokenCountsKeepThreeFigures() {
        #expect([6_240, 9_960, 64_000, 402_900, 999_600, 9_960_000, 12_340_000].map(ContextStore.tokens)
            == ["6.2k", "10k", "64k", "403k", "1M", "10M", "12M"])
        #expect([0.004, 0.62, 0].map(ContextStore.percent) == ["<1%", "62%", "0%"])
    }

    /// The wheel's slot always has a ring: before any usage (a thread resumed with none), and
    /// after a compaction that failed before one came. An empty slot took the hover fill alone.
    @Test func theWheelDrawsARingWithoutUsage() {
        let store = ContextStore()
        #expect(ContextWheel.face(store) == .ring)
        store.begin()
        #expect(ContextWheel.face(store) == .spinning)
        store.apply(.compactionFailed("The model is not supported"))
        #expect(store.usage == nil)
        #expect(ContextWheel.face(store) == .ring)
    }
}

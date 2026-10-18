import Foundation
import Observation
import Testing

@testable import KoreUI

/// The Agents button's summary is stored before observers hear of it: SwiftUI can draw while
/// it's told (a scroll view's pending commit), and what it reads then has to be the new one.
@MainActor
@Suite("Transcript: the agent summary")
struct AgentSummaryTests {
    @MainActor final class Heard {
        var counts: [Int] = []
    }

    @Test func observerReadsTheNewSummary() {
        let script = Script()
        script.send("Use a helper")
        script.start("t1")
        _ = script.sections
        let store = script.store
        let heard = Heard()
        withObservationTracking {
            _ = store.agentSummary
        } onChange: {
            MainActor.assumeIsolated { heard.counts.append(store.agentSummary.count) }
        }
        script.on(.agentSpawned(AgentInfo(
            id: "scout", parent: .main, toolId: nil, name: "Scout", type: nil, model: nil, prompt: nil, background: false)))
        _ = script.sections
        #expect(heard.counts == [1])
        #expect(store.agentSummary.count == 1)
    }
}

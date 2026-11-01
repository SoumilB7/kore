import Foundation
import Testing

@testable import KoreUI

@MainActor
@Suite("Agent shapes")
struct AgentShapeTests {
    private func shape(_ store: TranscriptStore, _ id: String) -> Int? {
        store.agent(id).map { $0.index % AgentShape.allCases.count }
    }

    @Test func liveAgentsNeverShareAShape() {
        let store = TranscriptStore()
        let count = AgentShape.allCases.count
        // One agent stays running while a full cycle of others spawn and finish: the next one's turn
        // in spawn order lands on the running agent's shape, which is the case the map showed twice.
        store.agentSpawned(id: "long", name: "long", type: nil, tool: nil)
        for i in 1..<count {
            store.agentSpawned(id: "done\(i)", name: "done \(i)", type: nil, tool: nil)
            store.agentFinished(id: "done\(i)", status: .finished, result: nil)
        }
        store.agentSpawned(id: "new", name: "new", type: nil, tool: nil)
        store.agentSpawned(id: "newer", name: "newer", type: nil, tool: nil)
        let live = ["long", "new", "newer"].compactMap { shape(store, $0) }
        #expect(live.count == 3)
        #expect(Set(live).count == 3)
    }

    @Test func aFinishedAgentsShapeIsFreeAgain() {
        let store = TranscriptStore()
        let count = AgentShape.allCases.count
        for i in 0..<count {
            store.agentSpawned(id: "a\(i)", name: "a\(i)", type: nil, tool: nil)
        }
        #expect(Set((0..<count).compactMap { shape(store, "a\($0)") }).count == count)
        store.agentFinished(id: "a3", status: .finished, result: nil)
        store.agentSpawned(id: "next", name: "next", type: nil, tool: nil)
        #expect(shape(store, "next") == shape(store, "a3"))
    }

    @Test func anAgentKeepsItsShapeForLife() {
        let store = TranscriptStore()
        store.agentSpawned(id: "a", name: "a", type: nil, tool: nil)
        let before = store.agent("a")?.index
        store.agentSpawned(id: "b", name: "b", type: nil, tool: nil)
        store.agentFinished(id: "a", status: .finished, result: nil)
        #expect(store.agent("a")?.index == before)
    }

    @Test func stacksNeverShowAShapeTwice() {
        let count = AgentShape.allCases.count
        let refs = [0, count, 1, count + 1, 2].map {
            TranscriptStore.AgentRef(id: "a\($0)", index: $0, name: "a\($0)", status: .finished)
        }
        let stack = TranscriptStore.distinctShapes(refs)
        #expect(stack.map(\.index) == [0, 1, 2])
    }

    @Test func theIdleStackSkipsRepeatedShapes() {
        let store = TranscriptStore()
        let count = AgentShape.allCases.count
        for i in 0..<(count + 2) {
            store.agentSpawned(id: "a\(i)", name: "a\(i)", type: nil, tool: nil)
            store.agentFinished(id: "a\(i)", status: .finished, result: nil)
        }
        store.drawNow()
        let shapes = store.agentSummary.first.map { $0.index % count }
        #expect(shapes.count == 3)
        #expect(Set(shapes).count == shapes.count)
    }
}

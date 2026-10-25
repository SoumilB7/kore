import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// A failed agent is never folded away: it hangs off the chat with the running ones, in spawn
/// order, while the finished and the stopped wait in their closed groups. The Agents button and
/// the map's header count the same agents, the stopped ones included.
@MainActor
@Suite("Failed agents")
struct FailedAgentsTests {
    private func spawn(_ id: String, under parent: AgentID = .main, background: Bool = false) -> ChatEvent {
        .agentSpawned(AgentInfo(id: id, parent: parent, toolId: nil, name: id, type: nil, model: nil, prompt: nil, background: background))
    }

    private func names(_ nodes: [TranscriptStore.AgentNode]) -> [String] {
        nodes.map { String(repeating: ".", count: $0.depth) + $0.id }
    }

    /// One turn: notes finishes, cut stops, scan fails, watch (background) fails, lead runs on
    /// with a failed child.
    private func turn() -> Script {
        let script = Script()
        script.send("Use some helpers")
        script.start("t1")
        script.on(
            spawn("notes"), spawn("cut"), spawn("scan"), spawn("watch", background: true), spawn("lead"),
            spawn("probe", under: .sub("lead")),
            .agentFinished(id: "notes", .completed, result: "Read"),
            .agentFinished(id: "cut", .stopped, result: nil),
            .agentFinished(id: "scan", .failed, result: "The log is missing"),
            .agentFinished(id: "watch", .failed, result: "The build broke"),
            .agentFinished(id: "probe", .failed, result: "No access"))
        _ = script.sections
        return script
    }

    @Test func failedAgentsHangOffTheChatWithTheRunningOnes() {
        let map = turn().store.agentTree()
        #expect(names(map.running) == ["scan", "watch", "lead", ".probe"])
        #expect(names(map.done) == ["notes"])
        #expect(names(map.stopped) == ["cut"])
        #expect(map.running.first { $0.id == "watch" }?.background == true)
    }

    @Test func theyStayAfterTheTurnEnds() {
        let script = turn()
        script.on(.agentFinished(id: "lead", .completed, result: "Led"))
        script.finish("t1")
        _ = script.sections
        let map = script.store.agentTree()
        // The failed child of a finished agent hangs off the chat; its parent folds into Done.
        #expect(names(map.running) == ["scan", "watch", "probe"])
        #expect(names(map.done) == ["lead", "notes"])
        let rows = AgentMapRows(map, folded: [], open: [])
        #expect(rows.stops == [.agent("scan"), .agent("watch"), .agent("probe"), .fold(.done), .fold(.stopped)])
        #expect(rows.fold(of: "scan") == nil)
    }

    @Test func theButtonAndTheHeaderCountTheSameAgents() {
        let script = turn()
        var summary = script.store.agentSummary
        #expect(summary.total == 6)
        #expect(AgentsButton.label(summary) == "1 running")
        #expect(MapHeader.counts(summary) == ("6 · 1 running", " · 3 failed"))

        script.on(.agentFinished(id: "lead", .completed, result: "Led"))
        _ = script.sections
        summary = script.store.agentSummary
        #expect(AgentsButton.label(summary) == "6 agents")
        #expect(MapHeader.counts(summary) == ("6", " · 3 failed"))
    }

    @Test func onlyStoppedAgentsAreCountedToo() {
        let script = Script()
        script.send("Go")
        script.start("t1")
        script.on(spawn("scout"), spawn("reader"))
        script.finish("t1", .interrupted)
        _ = script.sections
        let summary = script.store.agentSummary
        #expect(AgentsButton.label(summary) == "2 stopped")
        #expect(MapHeader.counts(summary).counts == "2")
    }

    @Test func noCountAtZero() {
        let summary = Script().store.agentSummary
        #expect(summary.total == 0)
        #expect(MapHeader.counts(summary) == ("", ""))
    }
}

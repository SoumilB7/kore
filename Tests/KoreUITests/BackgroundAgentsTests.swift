import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Background agents read back from a chat's transcript (`Fixtures/transcripts`, trimmed from a
/// real session another client ran): two spawned in the background, the turn ending before them,
/// and their notifications coming later, one taken mid-turn and one written to the transcript
/// only. A fork's copy of the history kept only the second call's result.
@MainActor
@Suite("Background agents")
struct BackgroundAgentsTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/transcripts/claude-background-agents.jsonl")

    private let lines: [JSONValue]
    /// Up to the turn's end: neither agent has finished.
    private var spawned: [JSONValue] { Array(lines.prefix(6)) }

    init() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        lines = try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
    }

    private func translator() -> ClaudeTranslator {
        ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: "s")
    }

    private func notification(_ index: Int) -> String {
        ClaudeHistory.notificationText(lines[index]) ?? ""
    }

    @Test func bothCallsAreAgentsAndNeitherHasEnded() {
        let translator = translator()
        let events = translator.replay(spawned)
        let agents = events.compactMap { if case .agentSpawned(let info) = $0 { info } else { nil } }
        #expect(agents.map(\.id) == ["toolu_bgA", "toolu_bgB"])
        #expect(agents.allSatisfy { $0.background })
        let open = translator.unfinishedAgents().sorted { $0.id < $1.id }
        #expect(open.map(\.id) == ["toolu_bgA", "toolu_bgB"])
        #expect(open.allSatisfy { $0.background })
    }

    /// The backend runs on the one whose files still grow; its notification ends it later.
    @Test func oneStillRunningIsFollowedToItsEnd() {
        let translator = translator()
        let script = Script()
        script.on(.replayed(translator.replay(spawned)))
        _ = script.sections
        #expect(script.store.agentSummary.stopped == 2)

        script.on(.agentResumed(id: "toolu_bgA"))
        _ = script.sections
        #expect(script.store.agentSummary.running.map(\.id) == ["toolu_bgA"])
        #expect(script.store.agentSummary.stopped == 1)

        translator.taskNotification(text: notification(6))
        translator.take().events.forEach(script.store.apply)
        _ = script.sections
        let agent = script.store.agent("toolu_bgA")
        #expect(agent?.status == .finished)
        #expect(agent?.result == "Uploads fail on a stale index.")
        #expect(agent?.tokens == 41200)
        #expect(script.store.agentSummary.running.isEmpty)
    }

    /// Read back whole, both end, each as its notification says, and neither shows as a message.
    @Test func theirNotificationsEndThemOnReadBack() {
        let translator = translator()
        let script = Script()
        script.on(.replayed(translator.replay(lines)))
        _ = script.sections
        #expect(script.store.agent("toolu_bgA")?.status == .finished)
        #expect(script.store.agent("toolu_bgB")?.status == .failed)
        #expect(translator.unfinishedAgents().isEmpty)
        #expect(!script.lines.contains { $0.contains("task-notification") })
    }

    /// Its meta file can say it finished before the notification comes: that ends it once, and
    /// the notification still brings the status and result.
    @Test func endedByItsFilesThenByItsNotification() {
        let translator = translator()
        _ = translator.replay(spawned)
        translator.agentEnded("toolu_bgB", .completed)
        translator.agentEnded("toolu_bgB", .completed)
        translator.taskNotification(text: notification(7))
        let ends = translator.take().events.compactMap { event -> String? in
            if case .agentFinished(let id, let status, let result) = event { "\(id) \(status) \(result ?? "-")" } else { nil }
        }
        #expect(ends == ["toolu_bgB completed -", "toolu_bgB failed The publish step timed out."])
    }
}

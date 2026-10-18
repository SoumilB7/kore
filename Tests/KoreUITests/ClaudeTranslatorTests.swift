import Foundation
import Testing

@testable import KoreUI

/// Recorded Claude runs (haiku) through `ClaudeTranslator`, fed as `ClaudeBackend` feeds it.
@MainActor
@Suite("Claude translator")
struct ClaudeTranslatorTests {
    @Test func aToolTurn() throws {
        let events = try Drive.claude("claude-tool")
        #expect(
            shape(events) == [
                "user", "turnStarted user", "session", "mode default", "tool Bash", "toolFinished", "text answer", "final",
                "turnFinished completed",
            ])
        let call = events.lazy.compactMap { if case .toolStarted(let call, _) = $0 { call } else { nil } }.first
        #expect(call?.detail.contains("echo hi") == true)
    }

    /// Stop during a Bash call: the call shows stopped, not failed, and the turn interrupted.
    @Test func aStoppedTurn() throws {
        let shape = shape(try Drive.claude("claude-stop"))
        #expect(shape.contains("toolStopped"))
        #expect(!shape.contains("toolFailed") && !shape.contains("toolFinished"))
        #expect(!shape.contains("final"))
        #expect(shape.last == "turnFinished interrupted")
    }

    /// EnterPlanMode and an approved ExitPlanMode change the mode, each with the agent as its
    /// cause; the plan file's Write is a file change.
    @Test func planModeByTheAgent() throws {
        let events = try Drive.claude("claude-plan")
        let modes = events.compactMap { if case .modeChanged(let change) = $0 { change } else { nil } }
        #expect(modes.map(\.mode) == ["default", "plan", "default"])
        #expect(modes.map(\.source) == [.session, .agent(.enteredPlanMode, .main), .agent(.planApproved, .main)])
        #expect(modes.dropFirst().map(\.previous) == ["default", "plan"])
        let shape = shape(events)
        #expect(shape.contains("fileChanged"))
        #expect(shape.last == "turnFinished completed")
    }

    /// `/compact`: started (asked for, so not auto), the divider, the summary.
    @Test func aCompaction() throws {
        let events = try Drive.claude("claude-compact")
        let shape = shape(events)
        let tail = Array(shape.drop { $0 != "compactionStarted false" })
        #expect(tail == ["compactionStarted false", "compacted", "summary", "turnFinished completed"])
        let auto = events.lazy.compactMap { if case .compacted(_, _, let auto) = $0 { auto } else { nil } }.first
        #expect(auto == false)
        let summary = events.lazy.compactMap { if case .compactionSummary(let text) = $0 { text } else { nil } }.first
        #expect(summary?.isEmpty == false)
    }

    /// A message sent mid-turn is taken at the next tool boundary: after the Bash call.
    @Test func queuedIntoTheRunningTurn() throws {
        let events = try Drive.claude("claude-queued-inturn")
        let queued = events.compactMap { if case .messageQueued(let id, _, _) = $0 { id } else { nil } }
        let delivered = events.compactMap { if case .queuedMessage(let id, .inTurn(let after)) = $0 { (id, after) } else { nil } }
        let bash = events.lazy.compactMap { if case .toolStarted(let call, _) = $0 { call.id } else { nil } }.first
        #expect(delivered.count == 1)
        #expect(delivered.first?.0 == queued.first)
        #expect(delivered.first?.1 == bash)
        #expect(shape(events).filter { $0.hasPrefix("turnStarted") }.count == 1)
    }

    /// A message sent while the answer streams (no tool boundary) becomes the next turn.
    @Test func queuedAsTheNextTurn() throws {
        let events = try Drive.claude("claude-queued-nextturn")
        guard let at = events.firstIndex(where: { if case .queuedMessage(_, .nextTurn) = $0 { true } else { false } }),
            case .queuedMessage(_, .nextTurn(let turn)) = events[at]
        else {
            Issue.record("no next-turn delivery")
            return
        }
        let next = events[(at + 1)...].lazy.compactMap { if case .turnStarted(let id, _, _) = $0 { id } else { nil } }.first
        #expect(next == turn)
        #expect(shape(events).filter { $0 == "turnFinished completed" }.count == 2)
    }
}

import Foundation
import KoreCore
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
    /// The mode a session reads back in is the one the user's last prompt was sent in: a
    /// background task's notification or a peer's message records the mode the CLI was launched
    /// in, and doesn't count.
    @Test func theModeReadBackIsTheUsersLastPrompts() async throws {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-21T10:00:00Z","permissionMode":"auto","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"text","text":"Go on."}]}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-21T10:00:01Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"OK"}]}}"#,
            #"{"type":"user","uuid":"p1","timestamp":"2026-10-21T10:01:00Z","permissionMode":"default","isMeta":true,"origin":{"kind":"peer"},"message":{"role":"user","content":"A peer's report."}}"#,
            #"{"type":"user","uuid":"n1","timestamp":"2026-10-21T10:02:00Z","permissionMode":"default","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification> <task-id>b1</task-id> </task-notification>"}}"#,
            #"{"type":"user","uuid":"n2","timestamp":"2026-10-21T10:03:00Z","permissionMode":"default","message":{"role":"user","content":"<task-notification> <task-id>b2</task-id> </task-notification>"}}"#,
        ]
        let messages = try lines.map { try JSONValue.parse(Data($0.utf8)) }
        let replayed = await ClaudeTranslator.replayed(messages, folder: URL(fileURLWithPath: "/tmp"), sessionId: "s")
        let modes = replayed.events.compactMap { if case .modeChanged(let change) = $0 { change.mode } else { nil } }
        #expect(modes == ["auto"])
        #expect(replayed.carried.mode == "auto")
    }

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

    /// A /compact typed in the terminal, read back: the divider and the summary, and none of the
    /// command's caveat, name or output as a message.
    @Test func aTypedCompactReadBack() throws {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-21T10:00:00Z","message":{"role":"user","content":"Reply with just OK."}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-21T10:00:01Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"OK"}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","uuid":"b1","timestamp":"2026-10-21T10:01:00Z","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":35104}}"#,
            #"{"type":"user","uuid":"s1","timestamp":"2026-10-21T10:01:00Z","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"Summary: the user asked for OK."}}"#,
            #"{"type":"user","uuid":"c1","timestamp":"2026-10-21T10:01:00Z","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: run locally.</local-command-caveat>"}}"#,
            #"{"type":"user","uuid":"c2","timestamp":"2026-10-21T10:01:00Z","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"}}"#,
            #"{"type":"user","uuid":"c3","timestamp":"2026-10-21T10:01:00Z","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}"#,
        ]
        let messages = try lines.map { try JSONValue.parse(Data($0.utf8)) }
        let events = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: "s").replay(messages)
        let users = events.compactMap { if case .userMessage(let text, _, _) = $0 { text } else { nil } }
        #expect(users == ["Reply with just OK."])
        let tail = Array(shape(events).drop { $0 != "compacted" })
        #expect(tail == ["compacted", "summary"])
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

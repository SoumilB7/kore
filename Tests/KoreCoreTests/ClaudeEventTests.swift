import Foundation
import Testing

@testable import KoreCore

/// Recorded stdout (haiku) read the way `ClaudeSession` reads it.
@Suite("Claude stream-json events")
struct ClaudeEventTests {
    /// The events a session yields for a cassette's stdout (its control traffic stays inside).
    static func events(_ name: String) throws -> [ClaudeEvent] {
        try Cassette(name).out.compactMap { message in
            switch message["type"]?.string {
            case "control_response", "control_cancel_request": nil
            case "control_request":
                message["request"]?["subtype"]?.string == "can_use_tool"
                    ? .permissionRequest(PermissionRequest(id: message["request_id"]?.string ?? "", message["request"] ?? .null))
                    : nil
            default: ClaudeEvent(message: message)
            }
        }
    }

    @Test func aToolTurn() throws {
        let events = try Self.events("claude-tool")
        #expect(events.contains { if case .sessionStarted = $0 { true } else { false } })
        let calls = events.flatMap { event -> [String] in
            guard case .assistant(_, let blocks, _, _) = event else { return [] }
            return blocks.compactMap { if case .toolUse(_, let name, _) = $0 { name } else { nil } }
        }
        #expect(calls == ["Bash"])
        let results = events.flatMap { event -> [Bool] in
            guard case .user(let blocks, _, _) = event else { return [] }
            return blocks.compactMap { if case .toolResult(_, _, let isError) = $0 { isError } else { nil } }
        }
        #expect(results == [false])
        let last = events.last { if case .turnCompleted = $0 { true } else { false } }
        if case .turnCompleted(let result) = last { #expect(!result.isError) } else { Issue.record("no result") }
        #expect(events.contains { if case .textDelta = $0 { true } else { false } })
    }

    @Test func aStopMidToolEndsAsAnErrorDuringExecution() throws {
        let events = try Self.events("claude-stop")
        let stopped = events.flatMap { event -> [String] in
            guard case .user(let blocks, _, _) = event else { return [] }
            return blocks.compactMap {
                if case .toolResult(_, let content, true) = $0 { content.string ?? content.compact } else { nil }
            }
        }
        #expect(stopped.contains { $0.contains("doesn't want to proceed") })
        let last = events.last { if case .turnCompleted = $0 { true } else { false } }
        if case .turnCompleted(let result) = last {
            #expect(result.isError)
            #expect(result.subtype == "error_during_execution")
        } else {
            Issue.record("no result")
        }
    }

    @Test func aToolNeedsPermission() throws {
        let events = try Self.events("claude-stop")
        #expect(events.contains { if case .permissionRequest(let request) = $0 { request.toolName == "Bash" } else { false } })
    }

    @Test func aQueuedMessageIsEchoedInTheTurnWithItsUUID() throws {
        let cassette = try Cassette("claude-queued-inturn")
        let queued = cassette.sent.first { $0["type"]?.string == "user" && $0["uuid"] != nil }?["uuid"]?.string
        #expect(queued != nil)
        let events = try Self.events("claude-queued-inturn")
        #expect(events.contains { if case .userEcho(let uuid) = $0 { uuid == queued } else { false } })
    }

    @Test func aQueuedMessageStartsTheNextTurnAsACommand() throws {
        let cassette = try Cassette("claude-queued-nextturn")
        let queued = cassette.sent.first { $0["type"]?.string == "user" && $0["uuid"] != nil }?["uuid"]?.string
        let events = try Self.events("claude-queued-nextturn")
        #expect(events.contains { if case .commandStarted(let id, _) = $0 { id == queued } else { false } })
        #expect(events.filter { if case .turnCompleted = $0 { true } else { false } }.count == 2)
    }

    @Test func everyStdoutLineParses() throws {
        for name in ["claude-tool", "claude-stop", "claude-plan", "claude-compact", "claude-queued-inturn", "claude-queued-nextturn"] {
            let cassette = try Cassette(name)
            #expect(cassette.lines.filter { $0.dir == "out" }.allSatisfy { $0.json != nil }, "\(name)")
        }
    }
}

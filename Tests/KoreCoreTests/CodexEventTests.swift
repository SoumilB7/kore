import Foundation
import Testing

@testable import KoreCore

/// Recorded app-server traffic (gpt-6-luna) read the way `CodexSession` reads it.
@Suite("Codex app-server events")
struct CodexEventTests {
    /// The thread's own events, in order: its notifications and server requests (a sub-agent's
    /// thread would be `.subThread`; these recordings have none).
    static func events(_ name: String) throws -> [CodexEvent] {
        let cassette = try Cassette(name)
        let thread = cassette.out.lazy.compactMap { $0["result"]?["thread"]?["id"]?.string }.first
        return cassette.out.compactMap { message in
            if let method = message["method"]?.string {
                let params = message["params"] ?? .null
                if let id = message["id"] { return CodexApproval(id: id, method: method, params: params).map { .approvalRequest($0) } }
                if let other = params["threadId"]?.string, let thread, other != thread {
                    return .subThread(threadId: other, method: method, params: params)
                }
                return CodexEvent(notification: method, params: params)
            }
            return nil
        }
    }

    private func items(_ events: [CodexEvent], completed: Bool = true) -> [CodexItem] {
        events.compactMap { event in
            switch event {
            case .itemCompleted(let item) where completed: item
            case .itemStarted(let item) where !completed: item
            default: nil
            }
        }
    }

    @Test func aCommandTurn() throws {
        let events = try Self.events("codex-tool")
        let commands = items(events).filter { $0.type == "commandExecution" }
        #expect(commands.count == 1)
        #expect(commands.first?.status == "completed")
        #expect(commands.first?.command?.contains("echo hi") == true)
        let done = events.compactMap { if case .turnCompleted(let result) = $0 { result } else { nil } }
        #expect(done.map(\.status) == ["completed"])
        #expect(events.contains { if case .textDelta = $0 { true } else { false } })
    }

    @Test func aSteeredMessageJoinsTheRunningTurn() throws {
        let events = try Self.events("codex-steer")
        let started = events.filter { if case .turnStarted = $0 { true } else { false } }
        #expect(started.count == 1)
        let users = items(events).filter { $0.type == "userMessage" }
        #expect(users.count == 2)
        #expect(users.last?.raw["clientId"]?.string == "steer-1")
    }

    @Test func aStopEndsTheTurnInterrupted() throws {
        let events = try Self.events("codex-stop")
        let done = events.compactMap { if case .turnCompleted(let result) = $0 { result } else { nil } }
        #expect(done.map(\.status) == ["interrupted"])
        // The command's own completion comes after the turn's, as recorded live.
        let order = events.compactMap { event -> String? in
            switch event {
            case .turnCompleted: "turn"
            case .itemCompleted(let item) where item.type == "commandExecution": "command"
            default: nil
            }
        }
        #expect(order == ["turn", "command"])
    }

    /// Codex passes the API's error body through: alone, after its own words, or not at all.
    @Test func errorsReadAsTheirMessage() {
        let model = "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
        let compact = #"Error running remote compact task: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"\#(model)"}}"#
        #expect(CodexError.readable(compact) == model)
        #expect(CodexError.readable(#"{"error":{"message":"Rate limit reached"}}"#) == "Rate limit reached")
        #expect(CodexError.readable(#"{"message":"Bad gateway"}"#) == "Bad gateway")
        #expect(CodexError.readable("stream disconnected before completion") == "stream disconnected before completion")
        #expect(CodexError.readable("unbalanced { brace") == "unbalanced { brace")
        #expect(CodexAppServer.Failure.rpc(code: -32603, message: compact).localizedDescription == model)
        let failed = CodexTurnResult(["turn": ["id": "t", "status": "failed", "error": ["message": .string(compact)]]])
        #expect(failed.errorMessage == model)
    }
}

import Foundation
import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// Arsenal's auto-compact point: the wheel's points or off, set as the wheel sets them.
extension HostOverrideTests {
@MainActor @Suite("Arsenal sets the auto-compact point", .serialized)
struct ArsenalAutoCompactTests {
    @Test(arguments: ["claude", "codex"])
    func pointsAsTheWheelHasThem(_ cli: String) throws {
        StorylineSeams.backend = { _, _ in ParityStub() }
        defer { StorylineSeams.backend = nil }
        let chat = Chat(provider: try #require(Registry.provider(cli)), folder: URL(fileURLWithPath: "/tmp/arsenal-autocompact"))
        defer { chat.close() }
        #expect(try chat.arsenalAutoCompact("50").get() == "Auto-compact at 50%.")
        #expect(chat.context.autoCompactAt == 50)
        #expect(try chat.arsenalAutoCompact("50").get() == "Already: auto-compact at 50%.")
        #expect(try chat.arsenalAutoCompact(" 70% ").get() == "Auto-compact at 70%.")
        #expect(chat.context.autoCompactAt == 70)
        for bad in ["55", "100", "fifty", ""] {
            guard case .failure(let refusal) = chat.arsenalAutoCompact(bad) else { Issue.record("\(bad) taken"); continue }
            #expect(refusal.message == "Auto-compact points: 50, 60, 70, 80, 90 or off.")
        }
        #expect(chat.context.autoCompactAt == 70)
        #expect(try chat.arsenalAutoCompact("OFF").get() == "Auto-compact off.")
        #expect(chat.context.autoCompactAt == nil)
        chat.transcript.drawNow()
        let lines = chat.transcript.entries.filter { $0.kind == .notice }.map(\.text)
        #expect(lines.contains("Arsenal · auto-compact 50%") && lines.contains("Arsenal · auto-compact off"), "\(lines)")
    }

    @MainActor private final class ParityStub: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { nil }
        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {}
        func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { true }
        func interrupt() async {}
        func respond(to approvalID: String, _ decision: Decision) async {}
        func setMode(_ id: String) async throws {}
        func setPlanMode(_ on: Bool) async {}
        func setModel(_ id: String) async throws {}
        func setEffort(_ level: String) async {}
        func rename(_ title: String) async throws {}
        func stopAgent(_ id: String) async {}
        func agentHistory(_ id: String) async -> [ChatEvent] { [] }
        func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
        func forkAtEnd() async throws -> ForkStart { .fresh }
        func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
        func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
        func close() async { sink.finish() }
    }
}
}

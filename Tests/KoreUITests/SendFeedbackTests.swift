import Foundation
import KoreCore
import Testing

@testable import KoreUI

extension HostOverrideTests {
@MainActor @Suite("SendFeedback: visible before the CLI acknowledges", .serialized)
struct SendFeedbackTests {
    private func spinners(_ store: TranscriptStore) -> [(id: String, since: Date, word: String?)] {
        store.drawNow()
        return store.sections.flatMap(\.items).compactMap {
            if case .spinner(let id, let since, _, let word, _) = $0.row { (id, since, word) } else { nil }
        }
    }

    @Test func localDeliverySurvivesReplayAndTransfersWithoutDuplicates() {
        let store = TranscriptStore()
        store.user("Hello", attachments: [])
        let sent = Date(timeIntervalSince1970: 123)
        store.sending(true, at: sent)
        store.sending(true, at: sent.addingTimeInterval(9))
        #expect(!store.turnIsOpen)
        #expect(spinners(store).map(\.word) == ["Sending"])
        #expect(spinners(store).first?.since == sent)
        store.apply(.replayed([
            .turnStarted("past", origin: .user, at: sent.addingTimeInterval(-20)),
            .turnFinished("past", .completed, duration: nil),
        ]))
        #expect(store.pendingSendSince == sent)
        #expect(spinners(store).count == 1)
        store.apply(.turnStarted("live", origin: .user, at: sent.addingTimeInterval(3)))
        #expect(store.pendingSendSince == nil)
        #expect(spinners(store).map(\.id) == ["live"])
        #expect(spinners(store).first?.word == nil)
        #expect(spinners(store).first?.since == sent)
        store.apply(.text("answer", .answer, "Hello back"))
        #expect(spinners(store).map(\.id) == ["live"])
        store.apply(.turnFinished("live", .completed, duration: nil))
        #expect(spinners(store).isEmpty)
    }

    @Test func historyDoesNotInventAnAcknowledgedEmptyTurn() {
        let store = TranscriptStore()
        store.apply(.replayed([.turnStarted("past", origin: .user, at: .now)]))
        #expect(spinners(store).isEmpty)
    }

    @Test func unfinishedHistoryCannotHideOrDuplicateANewSend() {
        for hasText in [false, true] {
            let store = TranscriptStore()
            var past: [ChatEvent] = [.turnStarted("past", origin: .user, at: .now)]
            if hasText { past.append(.text("old", .answer, "Earlier reply")) }
            store.apply(.replayed(past))
            store.user("A new question", attachments: [])
            store.sending(true)
            #expect(spinners(store).map(\.word) == ["Sending"])
            store.turnStarted("live")
            #expect(spinners(store).map(\.id) == ["live"])
            store.text("answer", .answer, "A new reply")
            #expect(spinners(store).map(\.id) == ["live"])
        }
    }

    @Test func unfinishedHistoryStillShowsAReportedConnectionProblem() {
        let store = TranscriptStore()
        store.apply(.replayed([.turnStarted("past", origin: .user, at: .now)]))
        store.apply(.connection(.stalled))
        #expect(spinners(store).map(\.word) == [Connection.stalled.word])
    }

    @Test func pendingFeedbackYieldsToApprovalsAndCompaction() {
        let store = TranscriptStore()
        store.user("Hello", attachments: [])
        store.sending(true)
        store.approvalAsked("question", question: true)
        #expect(spinners(store).isEmpty)
        store.approvalSettled("question")
        #expect(spinners(store).map(\.word) == ["Sending"])
        store.compacting(true)
        #expect(spinners(store).map(\.word) == ["Compacting"])
        store.compacting(false)
        store.turnStarted("live")
        store.approvalAsked("permission", question: false)
        #expect(spinners(store).isEmpty)
        store.approvalSettled("permission")
        #expect(spinners(store).map(\.id) == ["live"])
    }

    @Test func failedOrExitedBeforeAcknowledgementClearsDelivery() {
        for end in [ChatEvent.exited(status: 15), .turnFinished(nil, .failed("Could not send"), duration: nil)] {
            let store = TranscriptStore()
            store.user("Hello", attachments: [])
            store.sending(true)
            store.apply(end)
            #expect(store.pendingSendSince == nil)
            #expect(spinners(store).isEmpty)
        }
    }

    private enum Failed: Error { case start }
    @MainActor private final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "feedback" }
        var gate: CheckedContinuation<Void, Never>?
        var returned = false
        var accepted = true
        var failStart = false
        var sent = 0
        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {
            await withCheckedContinuation { gate = $0 }
            returned = true
            if failStart { throw Failed.start }
        }
        func release() { gate?.resume(); gate = nil }
        func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool { sent += 1; return accepted }
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
        func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
        func close() async { release(); sink.finish() }
    }

    private func make(_ provider: String, _ backend: Backend) throws -> Chat {
        StorylineSeams.backend = { _, _ in backend }
        NetworkWatch.shared.pin(true)
        return Chat(provider: try #require(Registry.provider(provider)), folder: URL(fileURLWithPath: "/tmp/send-feedback"))
    }
    private func finish(_ chat: Chat, _ backend: Backend) {
        backend.release()
        chat.close()
        StorylineSeams.backend = nil
        NetworkWatch.shared.pin(nil)
    }
    private func until(_ check: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !check() {
            guard ContinuousClock.now < end else { throw Failed.start }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test(arguments: ["claude", "codex"])
    func feedbackIsImmediateAcrossStartupAndEmptyAcknowledgement(_ provider: String) async throws {
        let backend = Backend(), chat = try make(provider, backend)
        defer { finish(chat, backend) }
        chat.storySend("Hello")
        #expect(spinners(chat.transcript).map(\.word) == ["Sending"])
        #expect(!chat.transcript.turnIsOpen)
        try await until { backend.gate != nil }
        #expect(spinners(chat.transcript).count == 1)
        backend.release()
        try await until { backend.sent == 1 }
        #expect(spinners(chat.transcript).map(\.word) == ["Sending"])
        backend.sink.yield(.turnStarted("live", origin: .user, at: .now))
        try await until { chat.transcript.turnIsOpen }
        #expect(spinners(chat.transcript).map(\.id) == ["live"])
        backend.sink.yield(.turnFinished("live", .completed, duration: nil))
        try await until { !chat.status.isRunning }
        #expect(spinners(chat.transcript).isEmpty)
    }

    @Test(arguments: ["claude", "codex"])
    func stopDuringStartupClearsFeedbackAndPreventsLateSend(_ provider: String) async throws {
        let backend = Backend(), chat = try make(provider, backend)
        defer { finish(chat, backend) }
        chat.storySend("Hello")
        try await until { backend.gate != nil }
        chat.stop()
        #expect(spinners(chat.transcript).isEmpty)
        backend.release()
        try await until { backend.returned }
        try await Task.sleep(for: .milliseconds(10))
        #expect(backend.sent == 0)
        #expect(spinners(chat.transcript).isEmpty)
    }

    @Test(arguments: ["claude", "codex"])
    func rejectedSendOrFailedStartupClearsFeedback(_ provider: String) async throws {
        for failure in [false, true] {
            let backend = Backend()
            backend.accepted = false
            backend.failStart = failure
            let chat = try make(provider, backend)
            chat.storySend("Hello")
            try await until { backend.gate != nil }
            backend.release()
            try await until { !chat.status.isRunning }
            #expect(spinners(chat.transcript).isEmpty)
            finish(chat, backend)
        }
    }
}
}

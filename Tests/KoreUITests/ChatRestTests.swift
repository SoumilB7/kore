import Foundation
import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// An idle Mac chat's CLI rests (its process ends quietly) and the next send, or a key typed,
/// starts it again on the same session, the transcript as it was. Live work keeps it up.
extension HostOverrideTests {
@MainActor @Suite("an idle chat's CLI rests", .serialized)
struct ChatRestTests {
    @MainActor private final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "rest-test" }
        var running = false
        var starts = 0
        var rests = 0
        var sent: [String] = []
        var observedAgents: Set<String> = []

        var started: (@MainActor @Sendable () -> Void)?

        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {
            guard !running else { return }
            running = true
            starts += 1
            started?()
        }
        func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
            try await start()
            sent.append(text)
            return true
        }
        func rest() async -> Bool {
            guard running else { return false }
            running = false
            rests += 1
            return true
        }
        func relaunch(reason: String) async { running = false }
        func relaunchAfterAccountChange() async -> Bool { true }
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

    private static let wait = Duration.milliseconds(40)

    private func make(_ backend: Backend) throws -> Chat {
        StorylineSeams.backend = { _, options in
            backend.started = options.started
            return backend
        }
        NetworkWatch.shared.pin(true)
        Chat.restAfter.value = Self.wait
        return Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/chat-rest"))
    }
    private func done(_ chat: Chat) {
        chat.close()
        StorylineSeams.backend = nil
        NetworkWatch.shared.pin(nil)
        Chat.restAfter.value = .seconds(600)
    }
    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < end else { Issue.record("never settled"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    /// Longer than a rest's wait, so one that was due has happened.
    private func pastTheWait() async throws { try await Task.sleep(for: Self.wait * 4) }

    /// The rows after a wake are exactly the rows before it and what was sent since. No backend
    /// replays its history at a wake (`RestRealBackendTests`): the chat would show it twice.
    @Test func anIdleChatRestsAndItsNextSendStartsItAgain() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        let history: [ChatEvent] = [
            .userMessage(text: "hi", attachments: [], id: "u1"), .turnStarted("t1", origin: .user, at: .now),
            .text("b1", .answer, "hello"), .turnFinished("t1", .completed, duration: nil),
        ]
        await chat.startOnce()
        history.forEach { backend.sink.yield($0) }
        try await until { chat.resting }
        #expect(backend.rests == 1)
        func rows() -> [String] {
            chat.transcript.drawNow()
            return chat.transcript.entries.map { "\($0.kind) \($0.text)" }
        }
        let before = rows()
        #expect(before.contains { $0.hasSuffix(" hi") } && before.contains { $0.hasSuffix(" hello") })
        chat.draft = "again"
        chat.send()
        try await until { backend.sent == ["again"] }
        #expect(backend.starts == 2 && !chat.resting)
        backend.sink.yield(.turnStarted("t2", origin: .user, at: .now))
        backend.sink.yield(.text("b2", .answer, "sure"))
        try await until { rows().contains { $0.hasSuffix(" sure") } }
        let after = rows()
        #expect(Array(after.prefix(before.count)) == before, "\(after)")
        #expect(after.dropFirst(before.count).map { $0.split(separator: " ").last.map(String.init) } == ["again", "sure"], "\(after)")
    }

    /// A call that starts the CLI by itself (Codex's earlier page, a fork, a rename) wakes the
    /// chat too, so it rests again later.
    @Test func aBackendStartingItsOwnCLIWakesTheChatAndItRestsAgain() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.startOnce()
        try await until { chat.resting }
        try await backend.start()
        #expect(!chat.resting && backend.starts == 2)
        try await until { chat.resting }
        #expect(backend.rests == 2)
    }

    @Test func aRunningTurnKeepsItsCLI() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.startOnce()
        backend.sink.yield(.turnStarted("t1", origin: .user, at: .now))
        try await until { chat.status.isRunning }
        try await pastTheWait()
        #expect(backend.rests == 0)
        backend.sink.yield(.turnFinished("t1", .completed, duration: nil))
        try await until { chat.resting }
    }

    @Test func aQueuedMessageOrALiveCommandKeepsItsCLI() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.startOnce()
        let command = ActiveCommand(id: "c1", kind: .shell, title: "dev server", startedAt: .now, owner: .main)
        backend.sink.yield(.commandStarted(command))
        try await until { chat.commands.summary.total == 1 }
        #expect(chat.hasLiveWork)
        try await pastTheWait()
        #expect(backend.rests == 0)
        backend.sink.yield(.commandEnded(id: "c1", .ended, at: .now))
        try await until { chat.resting }
    }

    @Test func aKeyTypedInARestingChatStartsItsCLI() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.startOnce()
        try await until { chat.resting }
        chat.draft = "h"
        chat.composerDraftChanged()
        try await until { backend.starts == 2 }
        #expect(!chat.resting)
        #expect(backend.sent.isEmpty)
    }

    @Test func typingPutsTheRestOff() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.startOnce()
        for key in "hello" {
            chat.draft.append(key)
            chat.composerDraftChanged()
            try await Task.sleep(for: Self.wait / 2)
        }
        #expect(backend.rests == 0)
        try await until { chat.resting }
    }
}
}

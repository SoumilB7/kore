import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Deliberately deaf awaits ignore task cancellation: old send-chain continuations must still
/// be unable to send or change the new account's state when they eventually return.
extension HostOverrideTests {
@MainActor @Suite("chat work stays on its transport", .serialized)
struct ChatWorkEpochTests {
    private struct OldFailure: Error {}

    @MainActor private final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "test" }
        var starts = 0
        var sent: [String] = []
        var firstStartWaits = false
        var firstSendWaits = false
        var firstRelaunchWaits = false
        var failOld = false
        var oldReturned = false
        var relaunches = 0
        var forceWaits = false
        var forced = 0
        var observedAgents: Set<String> = []
        var startGate: CheckedContinuation<Void, Never>?
        var sendGate: CheckedContinuation<Void, Never>?
        var relaunchGate: CheckedContinuation<Void, Never>?
        var forceGates: [CheckedContinuation<Void, Never>] = []

        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {
            starts += 1
            if starts == 1, firstStartWaits {
                await withCheckedContinuation { startGate = $0 }
                oldReturned = true
                if failOld { throw OldFailure() }
            }
        }
        func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool {
            sent.append(text)
            if sent.count == 1, firstSendWaits {
                await withCheckedContinuation { sendGate = $0 }
                oldReturned = true
                if failOld { throw OldFailure() }
                return false
            }
            return true
        }
        func relaunch(reason: String) async {
            relaunches += 1
            if relaunches == 1, firstRelaunchWaits {
                await withCheckedContinuation { relaunchGate = $0 }
            }
        }
        func relaunchAfterAccountChange() async -> Bool {
            forced += 1
            if forceWaits { await withCheckedContinuation { forceGates.append($0) } }
            return true
        }
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
        func close() async { sink.finish() }
    }

    private func make(_ backend: Backend) throws -> Chat {
        StorylineSeams.backend = { _, _ in backend }
        NetworkWatch.shared.pin(true)
        return Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/chat-work-epochs"))
    }
    private func done(_ chat: Chat) {
        chat.close()
        StorylineSeams.backend = nil
        NetworkWatch.shared.pin(nil)
    }
    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < end else { Issue.record("A controlled backend await did not settle"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func send(_ text: String, _ chat: Chat) { chat.draft = text; chat.send() }

    @Test(arguments: [false, true])
    func queuedChainCannotWakeUpOnAnotherAccount(_ oldFails: Bool) async throws {
        let backend = Backend()
        backend.firstStartWaits = true
        backend.failOld = oldFails
        let chat = try make(backend)
        defer { done(chat) }
        send("original", chat)
        try await until { backend.startGate != nil }
        send("queued one", chat)
        send("queued two", chat)
        chat.stopAllWork()
        chat.accountChanged()
        #expect(chat.draft == "queued one\nqueued two")
        try await until { backend.starts == 2 }
        send("new account", chat)
        try await until { backend.sent == ["new account"] }
        backend.startGate?.resume()
        try await until { backend.oldReturned }
        try await Task.sleep(for: .milliseconds(10))
        #expect(backend.sent == ["new account"])
        #expect(chat.status.isRunning)
        chat.transcript.drawNow()
        #expect(!chat.transcript.entries.contains { $0.kind == .notice })
    }

    @Test(arguments: [false, true])
    func staleSendResultCannotClearOrFailTheNewTurn(_ oldFails: Bool) async throws {
        let backend = Backend()
        backend.firstSendWaits = true
        backend.failOld = oldFails
        let chat = try make(backend)
        defer { done(chat) }
        send("old account", chat)
        try await until { backend.sendGate != nil }
        chat.stopAllWork()
        chat.accountChanged()
        try await until { backend.starts == 2 }
        send("new account", chat)
        try await until { backend.sent.count == 2 }
        backend.sendGate?.resume()
        try await until { backend.oldReturned }
        try await Task.sleep(for: .milliseconds(10))
        #expect(chat.status.isRunning)
        chat.transcript.drawNow()
        #expect(!chat.transcript.entries.contains { $0.kind == .notice })
    }

    @Test func closingInvalidatesEveryWaitingSend() async throws {
        let backend = Backend()
        backend.firstStartWaits = true
        backend.failOld = true
        let chat = try make(backend)
        defer { done(chat) }
        send("original", chat)
        try await until { backend.startGate != nil }
        send("queued", chat)
        chat.close()
        backend.startGate?.resume()
        try await until { backend.oldReturned }
        try await Task.sleep(for: .milliseconds(10))
        #expect(backend.starts == 1 && backend.sent.isEmpty)
        chat.transcript.drawNow()
        #expect(!chat.transcript.entries.contains { $0.kind == .notice })
    }

    @Test func rapidForcedSwitchesOnlyStartTheLatestLifetime() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.start()
        backend.forceWaits = true
        chat.stopAllWork()
        chat.accountChanged()
        try await until { backend.forced == 1 }
        // The first task is cancelled while shutdown is pending, but cleanup remains due.
        chat.accountChanged()
        try await until { backend.forced == 2 }
        for gate in backend.forceGates { gate.resume() }
        backend.forceGates = []
        try await until { backend.starts == 2 }
        try await Task.sleep(for: .milliseconds(10))
        #expect(backend.starts == 2)
    }

    @Test func obsoleteBoundaryRelaunchCannotStartAgain() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.start()
        backend.firstRelaunchWaits = true
        chat.accountChanged()
        try await until { backend.relaunchGate != nil }
        chat.accountChanged()
        backend.relaunchGate?.resume()
        try await until { backend.relaunches == 2 && backend.starts == 2 }
        #expect(backend.starts == 2)
    }

    @Test func externalRefreshLetsAPendingSendReachItsSafeBoundary() async throws {
        let backend = Backend()
        backend.firstStartWaits = true
        let chat = try make(backend)
        defer { done(chat) }
        send("pending", chat)
        try await until { backend.startGate != nil }
        chat.accountChanged()
        backend.startGate?.resume()
        try await until { backend.sent == ["pending"] }
        #expect(backend.relaunches == 0 && backend.forced == 0)
    }

    @Test func externalWorkDiscoveredDuringShutdownStaysLive() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.start()
        backend.forceWaits = true
        chat.stopAllWork()
        chat.accountChanged()
        try await until { backend.forced == 1 }
        backend.observedAgents.insert("external-child")
        backend.sink.yield(.agentSpawned(AgentInfo(id: "external-child", parent: .main, toolId: nil,
            name: "External child", type: nil, model: nil, prompt: nil, background: true)))
        backend.sink.yield(.commandStarted(ActiveCommand(id: "external-command", kind: .shell,
            title: "External command", startedAt: .now, owner: .sub("external-child"))))
        try await until {
            chat.transcript.drawNow()
            return chat.transcript.agentSummary.running.contains { $0.id == "external-child" }
                && chat.commands.command("external-command") != nil
        }
        for gate in backend.forceGates { gate.resume() }
        backend.forceGates = []
        try await until { backend.starts == 2 }
        chat.transcript.drawNow()
        #expect(chat.transcript.agentSummary.running.contains { $0.id == "external-child" })
        #expect(chat.commands.command("external-command")?.isLive == true)
    }

    @Test func aDraftStaysIntactUntilOldAccountCleanupCompletes() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.start()
        backend.forceWaits = true
        chat.stopAllWork()
        chat.accountChanged()
        try await until { backend.forced == 1 }
        chat.draft = "for the new account"
        #expect(!chat.canSend)
        chat.send()
        #expect(chat.draft == "for the new account" && backend.sent.isEmpty)
        chat.continueTurn()
        #expect(chat.draft == "for the new account" && backend.sent.isEmpty)
        for gate in backend.forceGates { gate.resume() }
        backend.forceGates = []
        try await until { backend.starts == 2 }
        #expect(chat.canSend)
        chat.send()
        try await until { backend.sent == ["for the new account"] }
    }

    @Test func stopWhileOfflineKeepsItsNotice() async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        NetworkWatch.shared.pin(false)
        send("offline", chat)
        try await until {
            chat.transcript.drawNow()
            return chat.transcript.entries.contains { $0.text.contains("Offline: this sends") }
        }
        chat.stop()
        try await until { !chat.status.isRunning }
        chat.transcript.drawNow()
        #expect(backend.sent.isEmpty)
        #expect(chat.transcript.entries.contains { $0.text.contains("Not sent: stopped while offline") })
    }

    @Test(arguments: [false, true])
    func switchingCancelsAScheduledSendAndRestoresItsDraft(_ explicitStop: Bool) async throws {
        let backend = Backend()
        let chat = try make(backend)
        defer { done(chat) }
        await chat.start()
        chat.draft = "send after reset"
        backend.sink.yield(.turnFinished("limited", .limited("Limit reached", resetsAt: .distantFuture), duration: nil))
        try await until { chat.canSendAtReset }
        chat.sendAtReset()
        #expect(chat.sendsAtReset != nil && chat.draft.isEmpty)
        if explicitStop { chat.stopAllWork() }
        chat.accountChanged()
        #expect(chat.sendsAtReset == nil && chat.continuesAt == nil)
        #expect(chat.draft == "send after reset" && backend.sent.isEmpty)
    }

    @Test(arguments: ["stop", "exit", "switch"])
    func anInterruptedTurnKeepsObservedAgentsRunning(_ boundary: String) async throws {
        let backend = Backend()
        backend.observedAgents = ["external"]
        let chat = try make(backend)
        defer { done(chat) }
        await chat.start()
        backend.sink.yield(.turnStarted("live", origin: .user, at: .now))
        for id in ["owned", "external"] {
            backend.sink.yield(.agentSpawned(AgentInfo(id: id, parent: .main, toolId: nil,
                name: id, type: nil, model: nil, prompt: nil, background: true)))
        }
        try await until {
            chat.transcript.drawNow()
            return chat.transcript.agentSummary.running.count == 2 && chat.status.isRunning
        }
        switch boundary {
        case "stop":
            chat.stop()
            backend.sink.yield(.turnFinished("live", .interrupted, duration: nil))
        case "exit":
            backend.sink.yield(.exited(status: 0))
        default:
            chat.stopAllWork()
            chat.accountChanged()
            try await until { backend.starts == 2 }
        }
        try await until { !chat.status.isRunning }
        chat.transcript.drawNow()
        #expect(chat.transcript.agent("external")?.status == .running)
        #expect(chat.transcript.agentSummary.running.map(\.id) == ["external"])
        #expect(chat.transcript.agent("owned")?.status == .stopped)
        #expect(chat.isWorking && chat.hasWork)
        chat.close()
        #expect(!chat.isWorking && !chat.hasWork)
        #expect(chat.transcript.agent("external")?.status == .running)
    }

}
}

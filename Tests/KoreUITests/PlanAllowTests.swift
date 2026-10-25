import Foundation
import Testing

@testable import KoreUI

/// "Allow commands in Plan": while planning with the switch on, Kore answers each permission
/// with allow and shows no card; plan approvals, questions and sign-ins still wait for the user.
extension HostOverrideTests {
    @MainActor @Suite("Allow commands in Plan", .serialized)
    struct PlanAllowTests {
        @MainActor private final class Backend: ChatBackend {
            let events: AsyncStream<ChatEvent>
            let sink: AsyncStream<ChatEvent>.Continuation
            var sessionId: String? { "test" }
            var answered: [(id: String, decision: Decision)] = []

            init() { (events, sink) = AsyncStream.makeStream() }
            func start() async throws {}
            func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool { true }
            func interrupt() async {}
            func respond(to approvalID: String, _ decision: Decision) async { answered.append((approvalID, decision)) }
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

        private let folder = URL(fileURLWithPath: "/tmp/plan-allow-tests")

        private func chat(_ provider: String, _ backend: Backend, memory: ModeMemory = ModeMemory(defaults: nil)) async throws -> Chat {
            StorylineSeams.backend = { _, _ in backend }
            let chat = Chat(provider: try #require(Registry.provider(provider)), folder: folder, modeMemory: memory)
            await chat.start()
            return chat
        }

        private func done(_ chat: Chat) {
            chat.close()
            StorylineSeams.backend = nil
        }

        /// Lets the pump take what the backend sent, and the answer's task reach the backend.
        private func settle() async throws {
            for _ in 0..<20 {
                await Task.yield()
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        private static func permission(_ id: String) -> Approval {
            Approval(id: id, title: "Allow Bash?", detail: nil, body: "ls", canAlwaysAllow: true, questions: [])
        }
        private static let plan = Approval(id: "plan", title: "Ready to code?", detail: nil, body: nil, canAlwaysAllow: false, questions: [], plan: "Do it")
        private static let question = Approval(
            id: "q", title: "", detail: nil, body: nil, canAlwaysAllow: false,
            questions: [.init(id: "Which?", text: "Which?", options: [.init(label: "A", description: "")])])
        private static var signIn: Approval {
            var ask = Approval(id: "login", title: "Allow MCP request?", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
            ask.signIn = true
            return ask
        }

        private func plan(_ chat: Chat, on: Bool) {
            if chat.provider.planToggle != nil { chat.setPlanMode(on) } else { chat.setMode(on ? "plan" : "default") }
        }

        @Test(arguments: ["claude", "codex"])
        func permissionsAreAllowedWithoutACardWhilePlanning(_ provider: String) async throws {
            let backend = Backend()
            let chat = try await chat(provider, backend)
            defer { done(chat) }
            plan(chat, on: true)
            chat.setPlanAllow(true)

            backend.sink.yield(.approvalRequested(Self.permission("p1")))
            try await settle()
            #expect(backend.answered.map(\.id) == ["p1"])
            if case .allow = backend.answered.first?.decision {} else { Issue.record("not answered allow") }
            #expect(chat.approvals.pending.isEmpty)

            // The plan approval, a question and a sign-in still show their cards.
            for ask in [Self.plan, Self.question, Self.signIn] { backend.sink.yield(.approvalRequested(ask)) }
            try await settle()
            #expect(chat.approvals.pending.map(\.id) == ["plan", "q", "login"])
            #expect(backend.answered.count == 1)
        }

        @Test(arguments: ["claude", "codex"])
        func outsidePlanOrWithTheSwitchOffCardsShowAsBefore(_ provider: String) async throws {
            let backend = Backend()
            let chat = try await chat(provider, backend)
            defer { done(chat) }
            // The switch on, but not planning.
            chat.setPlanAllow(true)
            backend.sink.yield(.approvalRequested(Self.permission("p1")))
            try await settle()
            // Planning, the switch off.
            chat.setPlanAllow(false)
            plan(chat, on: true)
            backend.sink.yield(.approvalRequested(Self.permission("p2")))
            try await settle()
            #expect(chat.approvals.pending.map(\.id) == ["p1", "p2"])
            #expect(backend.answered.isEmpty)

            // The switch on while planning: the cards waiting are answered too.
            chat.setPlanAllow(true)
            try await settle()
            #expect(chat.approvals.pending.isEmpty)
            #expect(Set(backend.answered.map(\.id)) == ["p1", "p2"])
        }

        @Test func theSwitchIsKeptPerChat() async throws {
            let memory = ModeMemory(defaults: ScratchBools())
            let backend = Backend()
            let chat = try await chat("claude", backend, memory: memory)
            defer { done(chat) }
            chat.setPlanAllow(true)
            backend.sink.yield(.sessionIdentified("s1"))
            try await settle()
            #expect(memory.planAllow(chat: "s1"))
            #expect(!memory.planAllow(chat: "s2"))
            chat.setPlanAllow(false)
            #expect(!memory.planAllow(chat: "s1"))
        }
    }
}

/// Defaults that stay in memory: nothing reaches a preferences file.
private final class ScratchBools: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

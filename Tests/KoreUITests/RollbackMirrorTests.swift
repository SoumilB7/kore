import Foundation
import HostClient
@testable import src
import Testing

@testable import KoreUI

/// A rollback on this Mac of a chat it holds from a box goes through the one rollback path:
/// its history is replaced as an event the taps see, and the mirror is told, so its return
/// sends it back whole (`ChatMirrors.count` says none). Claude and Codex both.
extension HostOverrideTests {
    @MainActor @Suite("a rollback here reaches the mirror", .serialized)
    struct RollbackMirrorTests {
        @MainActor private final class Backend: ChatBackend {
            let events: AsyncStream<ChatEvent>
            let sink: AsyncStream<ChatEvent>.Continuation
            var sessionId: String? { RollbackMirrorTests.session }
            var cut: String?

            init() { (events, sink) = AsyncStream.makeStream() }
            func start() async throws {
                sink.yield(.sessionIdentified(RollbackMirrorTests.session))
                sink.yield(
                    .replayed([
                        .userMessage(text: "kept", attachments: [], id: "k1"), .text("a1", .answer, "ok"),
                        .userMessage(text: "gone", attachments: [], id: "g1"), .text("a2", .answer, "ok too"),
                    ]))
            }
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
            func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
                cut = id
                return ([.userMessage(text: "kept", attachments: [], id: "k1"), .text("a1", .answer, "ok")], false)
            }
            func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
            func close() async { sink.finish() }
        }

        static let session = "7d1e3c40-0000-4000-8000-00000000f00d"

        private func until(_ condition: () -> Bool) async -> Bool {
            let end = ContinuousClock.now + .seconds(30)
            while !condition() {
                guard ContinuousClock.now < end else { return false }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return true
        }

        @Test(arguments: ["claude", "codex"])
        func aRollbackOfAHeldChatSendsItBackWhole(_ cli: String) async throws {
            let root = URL(fileURLWithPath: "/tmp/krm-\(UUID().uuidString.prefix(6))")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = MovedChats(root: root)
            let moved = MovedChat(
                alias: "rollback-test", boxChat: "c1", boxFolder: "/home/dev/work", macFolder: root.path, provider: cli, session: Self.session, gen: 1)
            store.keep(moved)
            let kept = ChatMirrors.shared.store
            ChatMirrors.shared.store = store
            let backend = Backend()
            StorylineSeams.backend = { _, _ in backend }
            NetworkWatch.shared.pin(true)
            let chat = Chat(provider: try #require(Registry.provider(cli)), folder: root, modeMemory: ModeMemory(defaults: nil))
            defer {
                chat.close()
                StorylineSeams.backend = nil
                NetworkWatch.shared.pin(nil)
                ChatMirrors.shared.ended(session: Self.session)
                ChatMirrors.shared.store = kept
            }
            await chat.startOnce()
            #expect(await until { chat.sessionId == Self.session && chat.transcriptView.entries.filter { $0.kind == .user }.count == 2 })
            #expect(ChatMirrors.shared.count(moved) != nil)

            let gone = try #require(chat.transcriptView.entries.first { $0.kind == .user && $0.text == "gone" })
            chat.rollBack(gone)
            #expect(await until { chat.transcriptView.entries.filter { $0.kind == .user }.map(\.text) == ["kept"] })
            #expect(backend.cut == "g1")
            #expect(store.session(Self.session)?.rolledBack == true)
            #expect(ChatMirrors.shared.count(moved) == nil)
        }
    }
}

import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// The hooks Kore keeps for the phone remote cost nothing unused and never touch what the owner
/// is doing on the Mac: a message from outside leaves the draft alone, a chat started from outside
/// doesn't take the window's tab, nothing listens to chat events by default, and transcripts mark
/// changes for the remote only while it follows them.
extension HostOverrideTests {
    @MainActor @Suite("remote hooks", .serialized)
    struct RemoteHooksTests {
        @MainActor private final class Backend: ChatBackend {
            let events: AsyncStream<ChatEvent>
            let sink: AsyncStream<ChatEvent>.Continuation
            var sessionId: String? { "remote-hooks" }
            var sent: [String] = []

            init() { (events, sink) = AsyncStream.makeStream() }
            func start() async throws {}
            func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool {
                sent.append(text)
                return false
            }
            func relaunch(reason: String) async {}
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

        private func until(_ condition: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(3)
            while !condition() {
                guard ContinuousClock.now < end else { Issue.record("timed out"); return }
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        @Test func aRemoteMessageLeavesTheDraftAlone() async throws {
            let backend = Backend()
            StorylineSeams.backend = { _, _ in backend }
            NetworkWatch.shared.pin(true)
            let chat = Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/remote-hooks"))
            defer {
                chat.close()
                StorylineSeams.backend = nil
                NetworkWatch.shared.pin(nil)
            }
            chat.draft = "half-written note"
            let file = URL(fileURLWithPath: "/tmp/remote-hooks/shot.png")
            chat.attach([file])
            #expect(chat.sendRemote("From the phone"))
            try await until { backend.sent == ["From the phone"] }
            #expect(chat.draft == "half-written note")
            #expect(chat.attachments.map(\.url) == [file])
        }

        @Test func aRemoteChatDoesntTakeTheTab() throws {
            let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
            let before = workspace.activeTab.id
            let chat = try #require(workspace.startRemote(provider: "codex"))
            #expect(workspace.activeTab.id == before)
            #expect(workspace.tabs.last?.chat === chat)
            #expect(chat.controls.mode == Registry.provider("codex")?.modes.first?.id)
            #expect(workspace.startRemote(provider: "nope") == nil)
        }

        @Test func nothingListensByDefault() {
            #expect(!RemoteTaps.active)
            let id = RemoteTaps.add { _, _ in }
            #expect(RemoteTaps.active)
            RemoteTaps.remove(id)
            #expect(!RemoteTaps.active)
        }

        @Test func transcriptsMarkChangesForTheRemoteOnlyWhileFollowed() {
            let store = TranscriptStore()
            store.apply(.userMessage(text: "one", attachments: []))
            #expect(store.remoteDirtyFrom == nil)
            TranscriptStore.remoteTracking = true
            defer { TranscriptStore.remoteTracking = false }
            store.apply(.userMessage(text: "two", attachments: []))
            #expect(store.remoteDirtyFrom == 1)
            #expect(!store.hidden, "the remote never changes how Kore draws a chat")
        }

        @Test func modeLevelsOrderWhatAnAgentMayDoAlone() throws {
            let claude = try #require(Registry.provider("claude"))
            let level = Dictionary(claude.modes.map { ($0.id, $0.level) }, uniquingKeysWith: { a, _ in a })
            #expect(level["plan"] == 0)
            #expect(level["default"] == 1)
            #expect(level["acceptEdits"] == 2)
            #expect(level["auto"] == 3)
            #expect(level["bypassPermissions"] == 4)
            let codex = try #require(Registry.provider("codex"))
            #expect(codex.modes.map(\.level) == [1, 3, 4])
            #expect(codex.planToggle?.level == 0)
        }
    }
}

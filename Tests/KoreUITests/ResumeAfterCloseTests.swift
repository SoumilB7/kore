import Foundation
import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// Resume after a close (the owner via Kore-main, 2026-11-24): what a window notes as its chats
/// work, what a quit keeps, what a reopened window offers, and what Resume and × do.
@MainActor
@Suite("Resume after a close", .serialized)
struct ResumeAfterCloseTests {
    @MainActor private final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "resume-test" }
        var sent: [String] = []
        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {}
        func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
            sent.append(text)
            return true
        }
        func relaunch(reason: String) async {}
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

    private static let folder = URL(fileURLWithPath: "/tmp/kore-resume-after-close")

    /// A window whose one chat runs on `backend`, started.
    private func window(_ backend: Backend) async -> (Workspace, Chat) {
        StorylineSeams.backend = { _, _ in backend }
        NetworkWatch.shared.pin(true)
        let workspace = Workspace(folder: Self.folder, restore: false)
        let chat = Chat(provider: .claude, folder: Self.folder)
        workspace.tabs[0].chat = chat
        await chat.start()
        return (workspace, chat)
    }

    private func done(_ workspace: Workspace) {
        workspace.closeAll()
        Workspace.ending = false
        StorylineSeams.backend = nil
        NetworkWatch.shared.pin(nil)
    }

    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < end else { Issue.record("never settled"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func helper(_ id: String) -> ChatEvent {
        .agentSpawned(AgentInfo(id: id, parent: .main, toolId: nil, name: id, type: nil, model: nil, prompt: nil, background: true))
    }

    @Test func theNoteFollowsTheWorkAsItHappensSoACrashLeavesIt() async throws {
        let backend = Backend()
        let (w, chat) = await window(backend)
        defer { done(w) }
        var changes = 0
        let bound = chat.onWorkChanged
        chat.onWorkChanged = { changes += 1; bound?() }
        #expect(w.work(of: w.tabs[0]) == nil, "idle: nothing to carry on")
        backend.sink.yield(.turnStarted("t1", origin: .user, at: .now))
        try await until { chat.isBusy }
        #expect(w.work(of: w.tabs[0]) == SavedWork(agents: nil, commands: nil))
        // Its turn ends with a helper still running: still working, with one sub-agent.
        backend.sink.yield(helper("scan"))
        backend.sink.yield(.turnFinished("t1", .completed, duration: nil))
        try await until {
            chat.transcript.drawNow()
            return !chat.isBusy && chat.transcript.agentSummary.running.count == 1
        }
        #expect(w.work(of: w.tabs[0]) == SavedWork(agents: 1, commands: nil))
        backend.sink.yield(.agentFinished(id: "scan", .completed, result: "Done"))
        try await until {
            chat.transcript.drawNow()
            return !chat.hasLiveWork
        }
        #expect(w.work(of: w.tabs[0]) == nil)
        // Each start and end was said: the window saves its note again each time.
        #expect(changes == 4)
    }

    @Test func aQuitKeepsTheNoteAsItWasWhenTheQuitBegan() async throws {
        let backend = Backend()
        let (w, chat) = await window(backend)
        defer { done(w) }
        backend.sink.yield(.turnStarted("t1", origin: .user, at: .now))
        try await until { chat.isBusy }
        Workspace.ending = true
        #expect(w.work(of: w.tabs[0]) != nil)
        // The CLIs end with Kore: the note stays as it was.
        backend.sink.yield(.turnFinished("t1", .interrupted, duration: nil))
        backend.sink.yield(.exited(status: 0))
        try await until { !chat.isBusy }
        #expect(w.work(of: w.tabs[0]) != nil)
        // A Stop before the close: the turn's over, nothing noted.
        Workspace.ending = false
        w.workAtEnd = nil
        #expect(w.work(of: w.tabs[0]) == nil)
    }

    @Test func aReopenedWindowOffersOnlyChatsThatWereWorkingAndCanResume() throws {
        func tab(_ session: String?, _ work: SavedWork?) -> Workspace.Saved.Tab {
            var tab = Workspace.Saved.Tab(provider: "claude", session: session, title: "Chat \(session ?? "new")")
            tab.working = work
            return tab
        }
        let saved = Workspace.Saved(
            tabs: [
                tab("5e550001-0000-4000-8000-000000000000", SavedWork(agents: 2, commands: 1)), tab(nil, SavedWork()),
                tab("5e550003-0000-4000-8000-000000000000", nil), tab("5e550004-0000-4000-8000-000000000000", SavedWork()),
            ],
            active: 2)
        Workspace.restoreOnNextOpen(folder: Self.folder, snapshot: saved)
        let w = Workspace(folder: Self.folder)
        defer { w.closeAll() }
        let offer = try #require(w.resumeOffer)
        #expect(offer.items.map(\.tab) == [w.tabs[0].id, w.tabs[3].id])
        #expect(offer.line == "2 chats were working when Kore closed" && offer.action == "Resume with sub-agents")
        // Unticked, the one with sub-agents doesn't make it "with sub-agents".
        w.toggleResume(w.tabs[0].id)
        #expect(w.resumeOffer?.action == "Resume" && w.resumeOffer?.picked == 1)
        // A closed tab leaves the offer; × lets the rest go.
        w.tabs.remove(at: 3)
        #expect(w.resumeOffer?.items.map(\.tab) == [w.tabs[0].id])
        w.dismissResume()
        #expect(w.resumeOffer == nil)
    }

    @Test func resumeSendsEachPickedChatItsNoteAndAChatTheUserSentToLeavesTheOffer() async throws {
        let backend = Backend()
        let (w, chat) = await window(backend)
        defer { done(w) }
        let other = ChatTab()
        w.tabs.append(other)
        w.resumeOffer = ResumeOffer(items: [.init(tab: w.tabs[0].id, agents: 1, commands: 2), .init(tab: other.id, agents: 0, commands: 0)])
        // The user sent the first something: it's going again, so it leaves the offer.
        backend.sink.yield(.turnStarted("t2", origin: .user, at: .now))
        try await until { chat.isBusy }
        #expect(w.resumeOffer?.items.map(\.tab) == [other.id])
        backend.sink.yield(.turnFinished("t2", .completed, duration: nil))
        try await until { !chat.isBusy }
        w.resumeOffer = ResumeOffer(items: [.init(tab: w.tabs[0].id, agents: 1, commands: 2)])
        w.resumeWork()
        try await until { !backend.sent.isEmpty }
        #expect(backend.sent == [
            "Kore closed while you were working. Continue where you left off. Your sub-agents were stopped too; start them again where they were. Background commands stopped; rerun any you still need."
        ])
        #expect(w.resumeOffer == nil)
    }

    @Test func theNoteIsShortAndTheSameForEitherCLI() {
        #expect(Workspace.resumeText(agents: 0, commands: 0) == "Kore closed while you were working. Continue where you left off.")
        #expect(Workspace.resumeText(agents: 3, commands: 0).hasSuffix("start them again where they were."))
        #expect(Workspace.resumeText(agents: 0, commands: 1).hasSuffix("rerun any you still need."))
        #expect(ResumeOffer(items: [.init(tab: UUID(), agents: 0, commands: 0)]).line == "1 chat was working when Kore closed")
    }
}

import Foundation
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// A fork keeps its "(fork)" name: the name its CLI says as it starts (its original's, carried in
/// the fork's session) never replaces it, and the CLI is told the fork's. Forks are numbered.
@MainActor
@Suite("fork titles")
struct ForkTitleTests {
    static let folder = URL(fileURLWithPath: "/tmp/fork-title-tests")

    static func titleFrame(_ title: String) -> String {
        #"{"type":"system","subtype":"session_title_changed","title":""# + title + #"","session_id":"s1"}"#
    }
    static let result = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":100}"#

    static func announced(_ events: [ChatEvent], _ title: String) -> Bool {
        events.contains { if case .titleAnnounced(title) = $0 { true } else { false } }
    }
    static func renamed(_ events: [ChatEvent], _ title: String) -> Bool {
        events.contains { if case .titleChanged(title, true) = $0 { true } else { false } }
    }

    // MARK: What the CLIs say

    /// Claude: a name before this process's first turn ends is only said; after it, or one Kore
    /// asked for, is a rename. A new process says it again.
    @Test func claudesStartTimeNameIsAnnouncedNotARename() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let start = try ActiveCommandsTests.claude(t, [Self.titleFrame("Slive")])
        #expect(Self.announced(start, "Slive") && !Self.renamed(start, "Slive"))
        t.askedTitles.append("Slive (fork)")
        #expect(Self.renamed(try ActiveCommandsTests.claude(t, [Self.titleFrame("Slive (fork)")]), "Slive (fork)"))
        #expect(t.askedTitles.isEmpty)
        _ = try ActiveCommandsTests.claude(t, [Self.result])
        // Mid-session, a rename the CLI made (no Kore ask) still renames.
        #expect(Self.renamed(try ActiveCommandsTests.claude(t, [Self.titleFrame("Device")]), "Device"))
        t.launching()
        #expect(Self.announced(try ActiveCommandsTests.claude(t, [Self.titleFrame("Device")]), "Device"))
    }

    /// Codex: the name in a thread's start (a fork's is its original's) is said; a name update
    /// is a rename.
    @Test func codexsThreadStartNameIsAnnounced() {
        let t = CodexTranslator(folder: Self.folder)
        t.translate(.threadStarted(threadId: "th2", model: nil, raw: .object(["thread": .object(["name": "Slive"])])))
        let start = t.take().events
        #expect(Self.announced(start, "Slive") && !Self.renamed(start, "Slive"))
        t.translate(CodexEvent(notification: "thread/name/updated", params: .object(["threadId": "th2", "threadName": "Device"])))
        #expect(Self.renamed(t.take().events, "Device"))
    }

    /// An announced name is only the name of a chat that has none; it crosses the link as a
    /// titleChanged an older Mac takes the same way.
    @Test func anAnnouncedNameNeverReplacesOneAndIsCoded() throws {
        let fork = ChatStatus(resume: nil)
        fork.name = "Slive (fork)"
        fork.apply(.titleAnnounced("Slive"))
        #expect(fork.name == "Slive (fork)")
        fork.apply(.titleChanged("Device", rename: true))
        #expect(fork.name == "Device")
        let new = ChatStatus(resume: nil)
        new.apply(.titleAnnounced("Slive"))
        #expect(new.name == "Slive")
        let data = try JSONEncoder().encode(ChatEvent.titleAnnounced("Slive"))
        #expect({ if case .titleAnnounced("Slive") = try? JSONDecoder().decode(ChatEvent.self, from: data) { true } else { false } }())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "titleChanged" && json["rename"] == nil)
    }

    // MARK: A chat with a name tells its CLI

    @MainActor final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "s2" }
        var renames: [String] = []

        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {}
        func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { true }
        func interrupt() async {}
        func respond(to approvalID: String, _ decision: Decision) async {}
        func setMode(_ id: String) async throws {}
        func setPlanMode(_ on: Bool) async {}
        func setModel(_ id: String) async throws {}
        func setEffort(_ level: String) async {}
        func rename(_ title: String) async throws { renames.append(title) }
        func stopAgent(_ id: String) async {}
        func agentHistory(_ id: String) async -> [ChatEvent] { [] }
        func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
        func forkAtEnd() async throws -> ForkStart { .fresh }
        func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
        func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
        func close() async { sink.finish() }
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { await Task.yield() }
    }

    private func chat(_ provider: String, _ backend: Backend, resume: SessionSummary, fork: ForkPoint?) async throws -> Chat {
        StorylineSeams.backend = { _, _ in backend }
        let chat = Chat(
            provider: try #require(Registry.provider(provider)), folder: Self.folder, resume: resume, fork: fork,
            forkedFrom: fork == nil ? nil : "Slive", modeMemory: ModeMemory(defaults: nil))
        await chat.start()
        return chat
    }

    /// A fork, Claude's and Codex's: its CLI says its original's name as it starts; the fork
    /// keeps "(fork)" and its CLI is told so.
    @Test(arguments: ["claude", "codex"])
    func aForkKeepsItsNameAndTellsTheCLI(_ provider: String) async throws {
        let backend = Backend()
        let agent = try #require(Registry.provider(provider)).historyAgent
        let chat = try await chat(
            provider, backend, resume: SessionSummary(id: "s1", agent: agent, title: "Slive (fork)", updated: .now),
            fork: ForkPoint(from: "s1", at: "m1"))
        defer {
            chat.close()
            StorylineSeams.backend = nil
        }
        backend.sink.yield(.titleAnnounced("Slive"))
        await until { !backend.renames.isEmpty }
        #expect(chat.title == "Slive (fork)" && backend.renames == ["Slive (fork)"])
        // A rename mid-session still renames.
        backend.sink.yield(.titleChanged("Device", rename: true))
        await until { chat.title == "Device" }
        #expect(chat.title == "Device" && backend.renames == ["Slive (fork)"])
    }

    /// A resumed chat whose name is its CLI's: nothing changes, nothing is sent.
    @Test func aResumedChatWithTheCLIsNameIsUnchanged() async throws {
        let backend = Backend()
        let chat = try await chat(
            "claude", backend, resume: SessionSummary(id: "s1", agent: .claude, title: "Slive", updated: .now), fork: nil)
        defer {
            chat.close()
            StorylineSeams.backend = nil
        }
        backend.sink.yield(.titleAnnounced("Slive"))
        backend.sink.yield(.turnStarted("t1", origin: .user, at: .now))
        await until { chat.status.isRunning }
        #expect(chat.title == "Slive" && backend.renames.isEmpty)
    }

    // MARK: Numbered forks

    @Test func forksAreNumberedAmongTheFoldersChats() {
        #expect(Workspace.forkTitle(of: "Slive", taken: ["Slive"]) == "Slive (fork)")
        #expect(Workspace.forkTitle(of: "Slive", taken: ["Slive", "Slive (fork)"]) == "Slive (fork 2)")
        #expect(Workspace.forkTitle(of: "Slive", taken: ["Slive (fork)", "Slive (fork 2)", "Other (fork 3)"]) == "Slive (fork 3)")
        // A fork of a fork counts from its base title.
        #expect(Workspace.forkTitle(of: "Slive (fork)", taken: ["Slive", "Slive (fork)"]) == "Slive (fork 2)")
        #expect(Workspace.forkTitle(of: "Slive (fork 2)", taken: ["Slive (fork)", "Slive (fork 2)"]) == "Slive (fork 3)")
        // Titles that only look like one keep their whole text.
        #expect(Workspace.forkTitle(of: "Notes (fork 1)", taken: []) == "Notes (fork 1) (fork)")
        #expect(Workspace.forkTitle(of: "Notes (forked)", taken: []) == "Notes (forked) (fork)")
        #expect(Workspace.forkBase("Slive (fork 12)") == "Slive" && Workspace.forkBase("Slive") == nil)
    }
}

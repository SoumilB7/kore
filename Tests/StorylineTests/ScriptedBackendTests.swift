import Foundation
import Testing

import KoreCore
@testable import KoreStorylines
@testable import KoreUI

@MainActor
@Suite("the scripted CLI", .serialized)
final class ScriptedBackendTests {
    let world = ScriptedWorld()
    var backend: ScriptedBackend!
    var seen: [ChatEvent] = []
    var tap: Task<Void, Never>?

    func make(_ script: CLIScript, options: BackendOptions? = nil) async throws -> ScriptedBackend {
        world.script = script
        world.install()
        let made = StorylineSeams.backend!("claude", options ?? BackendOptions(folder: URL(fileURLWithPath: "/tmp"), mode: "default"))
        let backend = try #require(made as? ScriptedBackend)
        self.backend = backend
        seen = []
        tap = Task { [weak self] in
            for await event in backend.events { self?.seen.append(event) }
        }
        try await backend.start()
        return backend
    }

    /// Waits (on run-loop passes, as storylines do) until an event matches.
    func until(_ what: String, _ match: (ChatEvent) -> Bool) async throws {
        for _ in 0..<2000 {
            if seen.contains(where: match) { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what); saw \(seen.map(Self.kind))")
        throw CancellationError()
    }

    static func kind(_ event: ChatEvent) -> String {
        String(String(describing: event).prefix { $0 != "(" })
    }

    func kinds() -> [String] {
        seen.compactMap { if case .text = $0 { nil } else { Self.kind($0) } }
    }

    func text() -> String {
        seen.compactMap { if case .text(_, .answer, let t, _) = $0 { t } else { nil } }.joined()
    }

    @Test func repliesToEachSendWithItsTurn() async throws {
        let backend = try await make(CLIScript(turns: [CLIScript.reply("Hello there, nice to meet you")]))
        _ = try await backend.send("Say hello", files: [])
        try await until("turnFinished") { if case .turnFinished = $0 { true } else { false } }
        #expect(kinds() == ["sessionIdentified", "controlsLoaded", "turnStarted", "turnFinished"])
        #expect(text() == "Hello there, nice to meet you")
        // A send past the script's end plays its last turn again.
        _ = try await backend.send("again", files: [])
        try await until("second turn") { _ in self.seen.filter { if case .turnFinished = $0 { true } else { false } }.count == 2 }
        #expect(text() == "Hello there, nice to meet you" + "Hello there, nice to meet you")
        #expect(backend.log == [.send("Say hello"), .send("again")])
    }

    @Test func stopEndsTheTurnWithItsToolStopped() async throws {
        let backend = try await make(CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "sleep 30", wait: .interrupt), .finishTurn(.completed)]]))
        _ = try await backend.send("long", files: [])
        try await until("tool running") { if case .toolStarted = $0 { true } else { false } }
        await backend.interrupt()
        try await until("turn ended") { if case .turnFinished = $0 { true } else { false } }
        #expect(kinds().suffix(3) == ["toolStarted", "toolStopped", "turnFinished"])
        #expect(seen.contains { if case .turnFinished(_, .interrupted, _) = $0 { true } else { false } })
    }

    @Test func aQueuedMessageGoesIntoTheTurnAfterTheTool() async throws {
        let backend = try await make(CLIScript(turns: [
            [.startTurn, .tool(name: "Bash", detail: "ls", output: "a.txt"), .takeQueued] + Beat.answer("done") + [.finishTurn(.completed)]
        ]))
        _ = try await backend.send("list", files: [])
        try await until("turn started") { if case .turnStarted = $0 { true } else { false } }
        _ = try await backend.send("and also", files: [], queued: "Q1")
        try await until("taken") { if case .queuedMessage = $0 { true } else { false } }
        let tool = seen.compactMap { if case .toolStarted(let call, _) = $0 { call.id } else { nil } }.first
        #expect(seen.contains { if case .queuedMessage("Q1", .inTurn(after: tool)) = $0 { true } else { false } })
        try await until("finished") { if case .turnFinished = $0 { true } else { false } }
        #expect(backend.log == [.send("list"), .queued("and also")])
    }

    @Test func aQueuedMessageNotTakenStartsTheNextTurn() async throws {
        let backend = try await make(CLIScript(turns: [
            [.startTurn, .wait(.queued(""))] + Beat.answer("first") + [.finishTurn(.completed)],
            CLIScript.reply("second"),
        ]))
        _ = try await backend.send("one", files: [])
        try await until("turn started") { if case .turnStarted = $0 { true } else { false } }
        _ = try await backend.send("two", files: [], queued: "Q2")
        try await until("second turn ends") { _ in self.seen.filter { if case .turnFinished = $0 { true } else { false } }.count == 2 }
        let next = seen.firstIndex { if case .queuedMessage("Q2", .nextTurn) = $0 { true } else { false } }
        let index = try #require(next)
        guard case .queuedMessage(_, .nextTurn(let turn)) = seen[index], case .turnStarted(let started, .user, _) = seen[index + 1] else {
            Issue.record("expected .nextTurn then its .turnStarted, saw \(kinds())")
            return
        }
        #expect(turn == started)
        #expect(text() == "firstsecond")
    }

    @Test func stopDropsWhatWasQueued() async throws {
        let backend = try await make(CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "sleep", wait: .interrupt)]]))
        _ = try await backend.send("long", files: [])
        try await until("tool") { if case .toolStarted = $0 { true } else { false } }
        _ = try await backend.send("later", files: [], queued: "Q3")
        await backend.interrupt()
        try await until("ended") { if case .turnFinished = $0 { true } else { false } }
        #expect(seen.contains { if case .queuedMessage("Q3", .dropped) = $0 { true } else { false } })
        #expect(!seen.contains { if case .turnStarted = $0 { true } else { false } } || seen.filter { if case .turnStarted = $0 { true } else { false } }.count == 1)
    }

    @Test func anApprovalPlaysTheBranchForTheAnswer() async throws {
        let approval = Approval(id: "A1", title: "Run ls?", detail: "ls", body: nil, canAlwaysAllow: true, questions: [])
        let script = CLIScript(turns: [
            [.startTurn, .approval(approval, allow: Beat.answer("ran it"), deny: Beat.answer("didn't")), .finishTurn(.completed)],
            [.startTurn, .approval(approval, allow: Beat.answer("ran it"), deny: Beat.answer("didn't")), .finishTurn(.completed)],
        ])
        let backend = try await make(script)
        _ = try await backend.send("one", files: [])
        try await until("approval") { if case .approvalRequested = $0 { true } else { false } }
        await backend.respond(to: "A1", .deny)
        try await until("first ends") { if case .turnFinished = $0 { true } else { false } }
        #expect(text() == "didn't")
        _ = try await backend.send("two", files: [])
        try await until("second approval") { _ in self.seen.filter { if case .approvalRequested = $0 { true } else { false } }.count == 2 }
        await backend.respond(to: "A1", .allow)
        try await until("second ends") { _ in self.seen.filter { if case .turnFinished = $0 { true } else { false } }.count == 2 }
        #expect(text() == "didn'tran it")
        #expect(backend.log.contains(.respond(approval: "A1", allowed: false)) && backend.log.contains(.respond(approval: "A1", allowed: true)))
    }

    @Test func aForkReplaysTheSessionUpToTheMessage() async throws {
        let backend = try await make(CLIScript(turns: [CLIScript.reply("red"), CLIScript.reply("blue")]))
        _ = try await backend.send("first colour", files: [])
        try await until("one") { if case .turnFinished = $0 { true } else { false } }
        _ = try await backend.send("second colour", files: [])
        try await until("two") { _ in self.seen.filter { if case .turnFinished = $0 { true } else { false } }.count == 2 }
        guard case .pending(let point) = try await backend.fork(message: "m1", text: "second colour") else {
            Issue.record("expected a pending fork")
            return
        }
        let original = backend
        // As `Workspace.fork` makes it: the original as `resume` too.
        let original_ = try #require(backend.sessionId)
        let fork = try await make(.echo, options: BackendOptions(
            folder: URL(fileURLWithPath: "/tmp"), resume: SessionSummary(id: original_, agent: .claude, title: "x", updated: Date()),
            mode: "default", fork: point, forkTitle: "x (fork)"))
        try await until("replay") { if case .replayed = $0 { true } else { false } }
        guard case .replayed(let history) = seen.first else {
            Issue.record("expected the fork's history first, saw \(kinds())")
            return
        }
        let users = history.compactMap { if case .userMessage(let t, _, _) = $0 { t } else { nil } }
        #expect(users == ["first colour"])
        #expect(fork.sessionId != original.sessionId)
        // The first message: nothing before it, a fresh chat.
        guard case .fresh = try await original.fork(message: "m0", text: "first colour") else {
            Issue.record("expected a fresh fork")
            return
        }
    }

    @Test func aResumeReplaysTheWholeSession() async throws {
        let backend = try await make(CLIScript(turns: [CLIScript.reply("hello")]))
        _ = try await backend.send("hi", files: [])
        try await until("done") { if case .turnFinished = $0 { true } else { false } }
        let id = try #require(backend.sessionId)
        _ = try await make(.echo, options: BackendOptions(folder: URL(fileURLWithPath: "/tmp"), resume: SessionSummary(id: id, agent: .claude, title: "t", updated: Date()), mode: "default"))
        try await until("replay") { if case .replayed = $0 { true } else { false } }
        guard case .replayed(let history) = seen.first else {
            Issue.record("expected a replay")
            return
        }
        #expect(history.contains { if case .userMessage("hi", _, _) = $0 { true } else { false } })
        #expect(history.contains { if case .text(_, .answer, "hello", _) = $0 { true } else { false } })
    }

    @Test func aFileEditWritesTheFileAndReportsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scripted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "one\ntwo\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let backend = try await make(
            CLIScript(turns: [[.startTurn, .fileEdit(path: "a.txt", content: "one\nTWO\nthree\n"), .fileEdit(path: "new/b.txt", content: "hi\n"), .finishTurn(.completed)]]),
            options: BackendOptions(folder: folder, mode: "default"))
        _ = try await backend.send("edit", files: [])
        try await until("turn changes") { if case .turnChanges = $0 { true } else { false } }
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "one\nTWO\nthree\n")
        #expect(try String(contentsOf: folder.appendingPathComponent("new/b.txt"), encoding: .utf8) == "hi\n")
        let edited = seen.compactMap { if case .fileChanged(_, let changes, _) = $0 { changes } else { nil } }.flatMap { $0 }
        #expect(edited.map { $0.path.hasSuffix("a.txt") || $0.path.hasSuffix("new/b.txt") } == [true, true])
        #expect(edited.first.map { ($0.added, $0.removed) } ?? (0, 0) == (3, 2))
        guard case .turnChanges(_, let files)? = seen.last else {
            Issue.record("turnChanges should come after turnFinished, saw \(kinds())")
            return
        }
        #expect(files.count == 2)
    }

    @Test func anAgentHasACardAndAHistory() async throws {
        let backend = try await make(CLIScript(turns: [[.startTurn, .agent(id: "ag1", name: "count_lines", says: "There are 3 lines"), .finishTurn(.completed)]]))
        _ = try await backend.send("spawn", files: [])
        try await until("finished") { if case .turnFinished = $0 { true } else { false } }
        #expect(kinds().contains("agentSpawned") && kinds().contains("agentFinished"))
        let history = await backend.agentHistory("ag1")
        #expect(history.count == 1)
        if case .text(_, _, let said, .sub("ag1"))? = history.first { #expect(said == "There are 3 lines") } else { Issue.record("no agent text") }
    }

    @Test func sendsPastTheScriptPlayItsLastTurn() async throws {
        let backend = try await make(CLIScript(turns: [CLIScript.reply("first"), CLIScript.reply("again")]))
        for text in ["a", "b", "c"] { _ = try await backend.send(text, files: []) }
        try await until("three turns") { _ in self.seen.filter { if case .turnFinished = $0 { true } else { false } }.count == 3 }
        #expect(text() == "firstagainagain")
    }
}

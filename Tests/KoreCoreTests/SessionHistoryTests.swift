import Foundation
import Testing

@testable import KoreCore

/// `ClaudeHistory` paging over small transcripts written in the test (the CLI's entry shapes),
/// under a scratch `CLAUDE_CONFIG_DIR`, never the real one.
@Suite("Claude session history paging", .serialized)
struct SessionHistoryTests {
    let folder: URL
    let config: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kore-history-\(UUID().uuidString)")
        folder = base.appendingPathComponent("work", isDirectory: true)
        config = base.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("CLAUDE_CONFIG_DIR", config.path, 1)
    }

    /// Writes a transcript: `entries` are (uuid, parent, kind, text), "user" / "assistant" /
    /// "boundary(logical)".
    private func write(_ session: String, _ entries: [[String: Any]]) throws {
        let dir = ClaudeHistory.projectDirectory(for: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(session + ".jsonl"), atomically: true, encoding: .utf8)
    }

    private func user(_ id: String, _ parent: String?, _ text: String) -> [String: Any] {
        ["type": "user", "uuid": id, "parentUuid": parent as Any, "message": ["role": "user", "content": text]]
    }

    private func answer(_ id: String, _ parent: String?, _ text: String) -> [String: Any] {
        ["type": "assistant", "uuid": id, "parentUuid": parent as Any,
         "message": ["id": "m-" + id, "role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    private func boundary(_ id: String, logical: String) -> [String: Any] {
        ["type": "system", "subtype": "compact_boundary", "uuid": id, "parentUuid": NSNull(), "logicalParentUuid": logical]
    }

    /// n user/answer turns chained from `parent`, ids "<prefix>u<i>" / "<prefix>a<i>".
    private func turns(_ n: Int, prefix: String, from parent: String?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var last = parent
        for i in 1...n {
            out.append(user("\(prefix)u\(i)", last, "\(prefix) prompt \(i)"))
            out.append(answer("\(prefix)a\(i)", "\(prefix)u\(i)", "\(prefix) answer \(i)"))
            last = "\(prefix)a\(i)"
        }
        return out
    }

    private func prompts(_ page: ClaudeHistory.Page) -> [String] {
        page.messages.compactMap { $0["type"]?.string == "user" ? $0["message"]?["content"]?.string : nil }
    }

    @Test func theCurrentPageStopsAtTheLastCompaction() throws {
        var entries = turns(3, prefix: "old", from: nil)
        entries.append(boundary("b1", logical: "olda3"))
        entries += turns(2, prefix: "new", from: "b1")
        try write("s1", entries)
        let page = ClaudeHistory.page(sessionId: "s1", in: folder)
        #expect(prompts(page) == ["new prompt 1", "new prompt 2"])
        #expect(page.messages.first.map(ClaudeHistory.isBoundary) == true)
        #expect(page.earlier == "olda3")
    }

    @Test func earlierPagesCrossCompactionsTenTurnsAtATime() throws {
        var entries = turns(15, prefix: "old", from: nil)
        entries.append(boundary("b1", logical: "olda15"))
        entries += turns(1, prefix: "new", from: "b1")
        try write("s2", entries)
        let first = ClaudeHistory.page(sessionId: "s2", in: folder)
        let earlier = ClaudeHistory.page(sessionId: "s2", in: folder, before: first.earlier, userTurns: 10)
        #expect(prompts(earlier) == (6...15).map { "old prompt \($0)" })
        let earliest = ClaudeHistory.page(sessionId: "s2", in: folder, before: earlier.earlier, userTurns: 10)
        #expect(prompts(earliest) == (1...5).map { "old prompt \($0)" })
        #expect(earliest.earlier == nil)
    }

    @Test func aMissingLogicalParentContinuesFromTheEntryBeforeTheBoundary() throws {
        var entries = turns(2, prefix: "old", from: nil)
        entries.append(boundary("b1", logical: "gone"))
        entries += turns(1, prefix: "new", from: "b1")
        try write("s3", entries)
        #expect(ClaudeHistory.page(sessionId: "s3", in: folder).earlier == "olda2")
    }

    @Test func aStopMarkerIsNotCountedAsATurn() throws {
        let entries: [[String: Any]] = [
            user("u1", nil, "first"), answer("a1", "u1", "one"),
            user("u2", "a1", "second"), user("stop", "u2", "[Request interrupted by user for tool use]"),
            user("u3", "stop", "third"), answer("a3", "u3", "three"),
        ]
        try write("s4", entries)
        let page = ClaudeHistory.page(sessionId: "s4", in: folder, before: "a3", userTurns: 2)
        #expect(prompts(page).contains("second"))
        #expect(prompts(page).contains("third"))
    }

    // MARK: Sub-agents another client runs

    /// An agent's transcript and meta file under `session`'s subagents folder.
    private func agent(_ id: String, session: String, tool: String, meta: [String: Any] = [:], last: [String: Any]? = nil)
        throws -> URL
    {
        let dir = ClaudeHistory.projectDirectory(for: folder).appendingPathComponent(session).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [user("x1", nil, "Find why uploads fail."), answer("x2", "x1", "Looking.")] + (last.map { [$0] } ?? [])
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let file = dir.appendingPathComponent("agent-\(id).jsonl")
        try (text.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let info = meta.merging(["toolUseId": tool, "requestShape": "background"]) { mine, _ in mine }
        try JSONSerialization.data(withJSONObject: info).write(to: dir.appendingPathComponent("agent-\(id).meta.json"))
        return file
    }

    @Test func anAgentsOwnFilesSayWhetherItStillRuns() throws {
        let running = ClaudeHistory.Subagent.read(try agent("r", session: "s5", tool: "t1"))
        #expect(running.outcome(quiet: 900) == .running)
        // Quiet past the limit with no end written: stopped.
        #expect(running.outcome(at: Date().addingTimeInterval(1000), quiet: 900) == .stopped)
        let done = ClaudeHistory.Subagent.read(try agent("d", session: "s5", tool: "t2", meta: ["finished": true]))
        #expect(done.outcome(at: Date().addingTimeInterval(1000), quiet: 900) == .finished)
        let killed = ClaudeHistory.Subagent.read(try agent("k", session: "s5", tool: "t3", meta: ["stoppedByUser": true]))
        #expect(killed.outcome(quiet: 900) == .stopped)
        // Its parent's turn was stopped: no meta says so, the last line does.
        let interrupted = ClaudeHistory.Subagent.read(
            try agent("i", session: "s5", tool: "t4", last: user("x3", "x2", "[Request interrupted by user]")))
        #expect(interrupted.interrupted)
        #expect(interrupted.outcome(quiet: 900) == .stopped)
    }

    /// The chat's own folder first; a fork's copied calls ran in the session it was made from.
    @Test func agentsAreFoundInTheirSessionOrTheOneAForkCameFrom() throws {
        let own = try agent("own", session: "s6", tool: "t1")
        let elsewhere = try agent("away", session: "s0", tool: "t2")
        let found = ClaudeHistory.subagents(toolUseIds: ["t1", "t2", "t9"], agentIds: [:], sessionId: "s6", in: folder)
        #expect(found["t1"]?.transcript.lastPathComponent == own.lastPathComponent)
        #expect(found["t2"]?.transcript.lastPathComponent == elsewhere.lastPathComponent)
        #expect(found["t9"] == nil)
    }

    /// Only whole lines written after `from`, in whichever entry carries the notification.
    @Test func notificationsAreReadFromWhereTheChatWas() throws {
        let note = "<task-notification><tool-use-id>t1</tool-use-id><status>completed</status></task-notification>"
        try write("s7", [user("u1", nil, "Start them.")])
        let file = ClaudeHistory.transcript(sessionId: "s7", in: folder)
        let from = ClaudeHistory.size(of: file)
        let queued: [String: Any] = ["type": "attachment", "uuid": "n1", "attachment": ["type": "queued_command", "prompt": note]]
        let only: [String: Any] = ["type": "user", "uuid": "n2", "queueTranscriptOnly": true, "message": ["role": "user", "content": note]]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        for entry in [queued, only] { try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: entry) + Data("\n".utf8)) }
        try handle.write(contentsOf: Data(#"{"type":"user","message":{"content":"<task-notif"#.utf8))  // still being written
        try handle.close()
        let read = ClaudeHistory.taskNotifications(in: file, from: from)
        #expect(read.texts == [note, note])
        #expect(ClaudeHistory.taskNotifications(in: file, from: read.next).texts.isEmpty)
    }
}

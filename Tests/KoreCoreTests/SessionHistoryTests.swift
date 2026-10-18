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
}

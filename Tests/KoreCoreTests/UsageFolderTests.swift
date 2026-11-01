import Foundation
import Testing
@testable import KoreCore

/// A chat's folder in the usage list is where its session began, not where a later turn's shell
/// had moved, nor where one of its agents worked.
@Suite struct UsageFolderTests {
    private static func line(_ cwd: String, _ id: String, _ stamp: String) -> String {
        #"{"type":"assistant","entrypoint":"sdk-cli","cwd":"\#(cwd)","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"claude-haiku","usage":{"input_tokens":10,"output_tokens":5}}}"#
    }

    @Test func aChatKeepsItsRootFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-folder-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-p-OnFinance")
        let agents = project.appendingPathComponent("chat1/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            #"{"type":"user","cwd":"/p/OnFinance","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
            Self.line("/p/OnFinance/ChangeManagement/trials", "m1", "2026-11-01T10:01:00.000Z"),
            Self.line("/p/OnFinance/ChangeManagement/trials", "m2", "2026-11-01T10:02:00.000Z"),
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: project.appendingPathComponent("chat1.jsonl"), atomically: true, encoding: .utf8)
        try (Self.line("/p/elsewhere", "a1", "2026-11-01T09:59:00.000Z") + "\n")
            .write(to: agents.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

        var index = ClaudeUsageIndex()
        _ = index.refresh(root: root, since: Date(timeIntervalSince1970: 0))
        let requests = index.requests(known: KoreSessions.Known(since: nil, ids: ["claude": ["chat1"]]))
        #expect(requests.count == 3)
        let chats = UsageAttribution.rollup(requests, points: requests.map { _ in 1 })
        #expect(chats.first?.id == "chat1")
        #expect(chats.first?.folder == "/p/OnFinance")
    }

    @Test func anAgentNeverNamesTheFolder() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let requests = [
            UsageRequest(time: at, chat: "a", agent: "x", folder: "/p/elsewhere", units: 1, kore: true),
            UsageRequest(time: at.addingTimeInterval(1), chat: "a", folder: "/p/OnFinance", units: 1, kore: true),
        ]
        #expect(UsageAttribution.rollup(requests, points: [1, 1]).first?.folder == "/p/OnFinance")
    }
}

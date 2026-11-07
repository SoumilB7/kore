import Foundation
import Testing

@testable import KoreCore

@Suite struct ChatTextIndexTests {
    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-text-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func user(_ text: String, side: Bool = false) -> String {
        let body = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"parentUuid":null,"isSidechain":\#(side),"type":"user","message":{"role":"user","content":\#(body)},"uuid":"u"}"#
    }

    /// As the CLI writes them: the message before the entry's own type.
    private func answer(_ text: String) -> String {
        #"{"parentUuid":"u","isSidechain":false,"message":{"model":"m","id":"i","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"type":"assistant","uuid":"a"}"#
    }

    private func indexed(_ url: URL, _ format: ChatTextIndex.Format = .claude) async -> ChatTextIndex {
        let index = ChatTextIndex()
        await index.index([.init(id: "c", file: url, format: format)]) { _ in }
        return index
    }

    @Test func findsWordsInMessagesOnlyAnyCase() async throws {
        let url = try file([
            user("Fix the Checkout totals"),
            answer("The ROUNDING was wrong"),
            // Tool traffic, thinking, API bodies and sub-agents aren't the chat's words.
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"zebra output"}]},"uuid":"r"}"#,
            #"{"message":{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"zebra"}}]},"type":"assistant","uuid":"b"}"#,
            #"{"message":{"type":"message","role":"assistant","content":[{"type":"thinking","thinking":"zebra"}]},"type":"assistant","uuid":"th"}"#,
            #"{"type":"api-request-blob","body":{"type":"user","text":"zebra"}}"#,
            user("zebra from a sub-agent", side: true),
            user("<command-name>zebra</command-name>"),
        ])
        let index = await indexed(url)
        #expect(index.search("checkout", in: ["c"]).first?.snippet == "Fix the Checkout totals")
        #expect(index.search("rounding", in: ["c"]).count == 1)
        #expect(index.search("zebra", in: ["c"]).isEmpty)
        #expect(index.search("nowhere", in: ["c"]).isEmpty)
        #expect(index.search("", in: ["c"]).isEmpty)
    }

    @Test func snippetMarksTheNewestMatchAndCountsAll() async throws {
        let long = String(repeating: "word ", count: 60)
        let url = try file([user("needle first"), answer("\(long)Needle é here \(long)"), user("after"), user("after again")])
        let hit = try #require(await indexed(url).search("needle", in: ["c"]).first)
        #expect(hit.count == 2)
        let found = (hit.snippet as NSString).substring(with: NSRange(location: hit.match.lowerBound, length: hit.match.count))
        #expect(found == "Needle")
        #expect(hit.snippet.hasPrefix("…") && hit.snippet.hasSuffix("…"))
        #expect(hit.snippet.utf8.count < 240)
    }

    @Test func aMessageSentDuringATurnIsFoundButNotAnotherSessions() async throws {
        let url = try file([
            #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"also check the walrus"},"uuid":"q"}"#,
            #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"<cross-session-message>zebra</cross-session-message>"},"uuid":"p"}"#,
            #"{"type":"attachment","attachment":{"type":"file","content":"zebra"},"uuid":"f"}"#,
        ])
        let index = await indexed(url)
        #expect(index.search("walrus", in: ["c"]).count == 1)
        #expect(index.search("zebra", in: ["c"]).isEmpty)
    }

    @Test func aMatchNeverSpansTwoMessages() async throws {
        let url = try file([user("end of one"), user("two starts")])
        #expect(await indexed(url).search("one two", in: ["c"]).isEmpty)
    }

    @Test func aGrownFileReadsOnlyWhatsNew() async throws {
        let url = try file([user("first words")])
        let index = await indexed(url)
        #expect(index.search("second", in: ["c"]).isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((answer("second words") + "\n").utf8))
        try handle.close()
        // The stamp's time can't be trusted to move within a test: the size says it grew.
        final class Changed: @unchecked Sendable {
            let lock = NSLock()
            var ids: [String] = []
        }
        let changed = Changed()
        await index.index([.init(id: "c", file: url, format: .claude)]) { id in changed.lock.withLock { changed.ids.append(id) } }
        #expect(changed.lock.withLock { changed.ids } == ["c"])
        #expect(index.search("second", in: ["c"]).count == 1)
        #expect(index.search("first", in: ["c"]).first?.count == 1)
    }

    @Test func anUnfinishedLastLineWaits() async throws {
        let url = try file([user("whole")])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let half = answer("half")
        try handle.write(contentsOf: Data(half.prefix(30).utf8))
        let index = ChatTextIndex()
        await index.index([.init(id: "c", file: url, format: .claude)]) { _ in }
        #expect(index.search("half", in: ["c"]).isEmpty)
        try handle.write(contentsOf: Data((half.dropFirst(30) + "\n").utf8))
        try handle.close()
        await index.index([.init(id: "c", file: url, format: .claude)]) { _ in }
        #expect(index.search("half", in: ["c"]).count == 1)
        #expect(index.search("whole", in: ["c"]).first?.count == 1)
    }

    @Test func aHugeLineThatIsntAMessageIsSkipped() async throws {
        let blob = #"{"type":"api-request-blob","body":""# + String(repeating: "x", count: 3 << 20) + #"zebra"}"#
        let url = try file([blob, user("after the blob")])
        let index = await indexed(url)
        #expect(index.search("zebra", in: ["c"]).isEmpty)
        #expect(index.search("after the", in: ["c"]).count == 1)
        #expect(index.heldBytes < 100)
    }

    @Test func codexRolloutsSkipTheHarnessAndTools() async throws {
        func item(_ role: String, _ kind: String, _ text: String) -> String {
            #"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"\#(role)","content":[{"type":"\#(kind)","text":"\#(text)"}]}}"#
        }
        let url = try file([
            #"{"timestamp":"t","type":"session_meta","payload":{"id":"x"}}"#,
            item("developer", "input_text", "zebra rules"),
            item("user", "input_text", "# AGENTS.md instructions zebra"),
            item("user", "input_text", "Port the parser"),
            item("assistant", "output_text", "Ported it"),
            #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"zebra"}}"#,
        ])
        let index = await indexed(url, .codex)
        #expect(index.search("parser", in: ["c"]).count == 1)
        #expect(index.search("ported", in: ["c"]).count == 1)
        #expect(index.search("zebra", in: ["c"]).isEmpty)
    }
}

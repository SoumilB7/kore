import Foundation
import Testing

@testable import KoreCore

/// `TailLines` against a forward split of the same bytes, at every chunk size small enough to
/// put each line edge (and each byte of a multi-byte character) at a chunk's edge.
@Suite("Reading lines from a file's end")
struct TailLinesTests {
    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-tail-\(UUID().uuidString).jsonl")
        try Data(bytes).write(to: url)
        return url
    }

    /// The whole non-empty lines, newest first, with their offsets: what a forward read finds.
    private func expected(_ bytes: [UInt8]) -> [(UInt64, [UInt8])] {
        guard let last = bytes.lastIndex(of: 0x0A) else { return [] }
        var lines: [(UInt64, [UInt8])] = []
        var start = 0
        for i in 0...last where bytes[i] == 0x0A {
            if i > start { lines.append((UInt64(start), Array(bytes[start..<i]))) }
            start = i + 1
        }
        return lines.reversed()
    }

    private func read(_ url: URL, chunk: Int) -> [(UInt64, [UInt8])] {
        guard var lines = TailLines(file: url, chunk: chunk) else { return [] }
        var out: [(UInt64, [UInt8])] = []
        while let (offset, line) = lines.next() { out.append((offset, Array(line))) }
        return out
    }

    private func check(_ text: String, chunks: [Int] = Array(1...9) + [16, 1 << 20]) throws {
        let bytes = Array(text.utf8)
        let url = try file(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let want = expected(bytes)
        for chunk in chunks {
            let got = read(url, chunk: chunk)
            #expect(got.map(\.0) == want.map(\.0), "offsets, chunk \(chunk)")
            #expect(got.map(\.1) == want.map(\.1), "lines, chunk \(chunk)")
        }
        var end: UInt64?
        if let lines = TailLines(file: url, chunk: 3) { end = lines.end }
        #expect(end == UInt64(bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0))
    }

    @Test func lineBoundaries() throws {
        try check("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n")
        try check("\n\n{\"a\":1}\n\n\n{\"b\":2}\n\n")
        try check("x\n")
        try check("\n")
        try check("")
    }

    @Test func crlfLinesKeepTheirCarriageReturn() throws {
        try check("{\"a\":1}\r\n{\"b\":2}\r\n\r\n{\"c\":3}\r\n")
    }

    /// A line still being written (no newline yet) is left out, as a forward read leaves it.
    @Test func aPartialLastLineIsLeftOut() throws {
        try check("{\"a\":1}\n{\"b\":2}\n{\"c\":")
        try check("{\"only\": \"partial\"")
    }

    @Test func multiByteCharactersAtChunkEdges() throws {
        try check("{\"t\":\"héllo wörld\"}\n{\"t\":\"日本語のテキスト\"}\n{\"t\":\"🧪🚀👩🏽‍💻\"}\nascii\n")
    }

    @Test func linesLongerThanAChunk() throws {
        let long = String(repeating: "abcdefghij", count: 2_000)
        try check("short\n\(long)\nmid\n\(long)🧪\n", chunks: [1, 7, 64, 1000, 1 << 20])
    }

    @Test func aMissingFileIsNil() {
        var opened = false
        if TailLines(file: URL(fileURLWithPath: "/nonexistent/kore-\(UUID().uuidString)")) != nil { opened = true }
        #expect(!opened)
    }
}

/// The newest page read from a transcript's end is the page the whole file gives, or `confirm`
/// says it isn't and gives that one.
@Suite("The newest page from a transcript's end")
struct LatestPageTests {
    private func write(_ entries: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-latest-\(UUID().uuidString).jsonl")
        let lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func user(_ id: String, _ parent: String?, _ text: String) -> [String: Any] {
        ["type": "user", "uuid": id, "parentUuid": parent.map { $0 as Any } ?? NSNull(), "message": ["role": "user", "content": text]]
    }

    private func answer(_ id: String, _ parent: String?, _ text: String, meta: String = "") -> [String: Any] {
        [
            "type": "assistant", "uuid": id, "parentUuid": parent.map { $0 as Any } ?? NSNull(), "meta": meta,
            "message": ["id": "m-" + id, "role": "assistant", "content": [["type": "text", "text": text]]],
        ]
    }

    private func boundary(_ id: String, logical: String?) -> [String: Any] {
        [
            "type": "system", "subtype": "compact_boundary", "uuid": id, "parentUuid": NSNull(),
            "logicalParentUuid": logical.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// Lines no page reads, as long transcripts have between entries.
    private let filler: [String: Any] = ["type": "api-request", "body": String(repeating: "z", count: 300)]

    private func uuids(_ page: ClaudeHistory.Page) -> [String] { page.messages.compactMap { $0["uuid"]?.string } }

    @Test func itIsThePageTheWholeFileGives() throws {
        var entries: [[String: Any]] = [user("u0", nil, "first"), answer("a0", "u0", "one")]
        entries += [filler, boundary("b1", logical: "a0"), user("u1", "b1", "second"), filler, answer("a1", "u1", "two")]
        entries += [filler, boundary("b2", logical: "a1"), user("u2", "b2", "third"), answer("a2", "u2", "three"), filler]
        let url = try write(entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = ClaudeTranscript(file: url).page()
        let reader = ClaudeTranscript(file: url)
        let latest = try #require(reader.latest(from: 0))
        #expect(uuids(latest.page) == uuids(whole))
        #expect(uuids(latest.page) == ["b2", "u2", "a2"])
        #expect(latest.from > 0)
        let confirmed = reader.confirm(latest)
        #expect(confirmed.page == nil)
        #expect(confirmed.earlier == whole.earlier)
        #expect(confirmed.earlier == "a1")
        // Indexed up to where the page ended: what's written after is new.
        #expect(reader.length == latest.end)
    }

    /// A boundary off the branch (another branch's) doesn't end the read: it goes back to the
    /// branch's own.
    @Test func aBoundaryOffTheBranchIsReadPast() throws {
        let entries: [[String: Any]] = [
            boundary("b1", logical: nil), user("u1", "b1", "kept"), answer("a1", "u1", "yes"),
            boundary("bx", logical: nil), user("ux", "bx", "other branch"),
            user("u2", "a1", "go on"), answer("a2", "u2", "done"),
        ]
        let url = try write(entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = ClaudeTranscript(file: url)
        let latest = try #require(reader.latest(from: 0))
        #expect(uuids(latest.page) == uuids(ClaudeTranscript(file: url).page()))
        #expect(uuids(latest.page) == ["b1", "u1", "a1", "u2", "a2"])
        #expect(reader.confirm(latest).page == nil)
    }

    /// History written twice: the end's copy of an entry isn't the one the whole file keeps, so
    /// `confirm` gives the whole file's page.
    @Test func historyWrittenTwiceIsCorrected() throws {
        let entries: [[String: Any]] = [
            boundary("b1", logical: nil), user("u1", "b1", "hello"), answer("a1", "u1", "hi", meta: "first copy"),
            filler,
            boundary("b1", logical: nil), user("u1", "b1", "hello"), answer("a1", "u1", "hi", meta: "second copy"),
            user("u2", "a1", "more"), answer("a2", "u2", "sure"),
        ]
        let url = try write(entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = ClaudeTranscript(file: url).page()
        let reader = ClaudeTranscript(file: url)
        let latest = try #require(reader.latest(from: 0))
        let confirmed = reader.confirm(latest)
        let corrected = try #require(confirmed.page)
        #expect(corrected.messages == whole.messages)
        #expect(corrected.messages.first { $0["uuid"]?.string == "a1" }?["meta"]?.string == "first copy")
    }

    @Test func aShortFileIsLeftToPage() throws {
        let url = try write([user("u1", nil, "hi"), answer("a1", "u1", "hello")])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeTranscript(file: url).latest() == nil)
        #expect(ClaudeTranscript(file: url).latest(from: 0) != nil)
    }

    @Test func parsingAPageInParallelKeepsItsOrder() {
        let lines = (0..<500).map { Data("{\"n\":\($0)}".utf8) } + [Data("not json".utf8)]
        let parsed = ClaudeHistory.parseAll(lines)
        #expect(parsed.count == 501)
        #expect(parsed.prefix(500).map { $0?["n"]?.int } == (0..<500).map { $0 })
        #expect(parsed.last == .some(nil))
    }
}

@Suite("CLI timestamps")
struct TimestampTests {
    @Test func theSameDateAsTheFormatter() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var random = SystemRandomNumberGenerator()
        var samples = ["2026-10-20T08:43:46.741Z", "2024-02-29T23:59:59.999Z", "1970-01-01T00:00:00.000Z", "2000-12-31T12:00:00.001Z"]
        for _ in 0..<3000 {
            samples.append(
                String(
                    format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int.random(in: 1971...2099, using: &random),
                    Int.random(in: 1...12, using: &random), Int.random(in: 1...28, using: &random), Int.random(in: 0...23, using: &random),
                    Int.random(in: 0...59, using: &random), Int.random(in: 0...59, using: &random), Int.random(in: 0...999, using: &random)))
        }
        for text in samples {
            #expect(Timestamp.parse(text) == formatter.date(from: text), "\(text)")
        }
    }

    /// Other forms are the formatter's to read.
    @Test func otherFormsAreNil() {
        for text in [
            "2026-10-20T08:43:46Z", "2026-10-20T08:43:46.741+05:30", "2026-10-20T08:43:46.741123Z", "2026-02-30T08:43:46.741Z",
            "2026-10-20 08:43:46.741Z", "", "2026-13-01T00:00:00.000Z", "2026-10-20T24:00:00.000Z",
        ] {
            #expect(Timestamp.parse(text) == nil, "\(text)")
        }
    }
}

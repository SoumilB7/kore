import Foundation
import KoreCore
import Testing

@Suite("Command output followed as it grows")
struct OutputFollowerTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kore-follow-\(UUID()).output")
    }

    private func append(_ bytes: [UInt8], to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes))
    }

    private func lines(_ range: Range<Int>) -> String { range.map { "line \($0)\n" }.joined() }

    @Test func openedMidRunItHasEverythingThenOnlyWhatsNew() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Array(lines(0..<250).utf8), to: url)
        var follower = OutputFollower()
        let read = follower.read(url)
        let first = try #require(read)
        #expect(first == .reset(lines(0..<250).replacingOccurrences(of: "\n", with: "\r\n"), cut: false))
        #expect(follower.read(url) == OutputFollower.Step.none)
        try append(Array(lines(250..<500).utf8), to: url)
        #expect(follower.read(url) == .append(lines(250..<500).replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(!follower.empty)
    }

    @Test func aCharacterSplitAcrossWritesWaitsForItsLastByte() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let euro = Array("€".utf8), emoji = Array("😀".utf8)
        try append(Array("a".utf8) + euro.prefix(2), to: url)
        var follower = OutputFollower()
        #expect(follower.read(url) == .reset("a", cut: false))
        try append(Array(euro.suffix(1)) + Array(emoji.prefix(1)), to: url)
        #expect(follower.read(url) == .append("€"))
        try append(Array(emoji.suffix(3)) + Array("\n".utf8), to: url)
        #expect(follower.read(url) == .append("😀\r\n"))
    }

    @Test func lineEndsBecomeTerminalLineEndsAndALoneReturnStays() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Array("10%\r20%\rdone\r\nnext\n\nlast\r".utf8), to: url)
        var follower = OutputFollower()
        #expect(follower.read(url) == .reset("10%\r20%\rdone\r\nnext\r\n\r\nlast\r", cut: false))
        // The CR of a CRLF split across reads stays one line end.
        try append(Array("\n".utf8), to: url)
        #expect(follower.read(url) == .append("\n"))
    }

    @Test func aFileThatShrankOrWasReplacedIsReadWholeAgain() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Array("one\ntwo\n".utf8), to: url)
        var follower = OutputFollower()
        _ = follower.read(url)
        try Data("x\n".utf8).write(to: url, options: .atomic)  // a new file in its place
        #expect(follower.read(url) == .reset("x\r\n", cut: false))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        #expect(follower.read(url) == .reset("", cut: false))
        #expect(follower.empty)
    }

    @Test func anEmptyFileIsEmptyUntilItsFirstByte() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try append([], to: url)
        var follower = OutputFollower()
        #expect(follower.read(url) == .reset("", cut: false))
        #expect(follower.empty)
        try append(Array("hi\n".utf8), to: url)
        #expect(follower.read(url) == .append("hi\r\n"))
        #expect(!follower.empty)
    }

    @Test func aLongOutputKeepsItsEndAndSaysTheRestWasCut() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Array(("ééé" + lines(0..<10)).utf8), to: url)
        var follower = OutputFollower(maxBytes: 40)
        let step = follower.read(url)
        guard case .reset(let text, let cut) = try #require(step) else { Issue.record("not a reset"); return }
        #expect(cut)
        #expect(text.hasSuffix("line 9\r\n"))
        #expect(!text.unicodeScalars.contains("\u{FFFD}"))
    }

    @Test func aStreamIsFollowedThroughItsTrimming() {
        var bytes: [UInt8] = Array(lines(0..<5).utf8)
        var follower = OutputFollower()
        #expect(follower.read(stream: bytes[...], base: 0) == .reset(lines(0..<5).replacingOccurrences(of: "\n", with: "\r\n"), cut: false))
        bytes += Array(lines(5..<7).utf8)
        #expect(follower.read(stream: bytes[...], base: 0) == .append(lines(5..<7).replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(follower.read(stream: bytes[...], base: 0) == .none)
        // Trimmed past what was read: read whole again, cut.
        let trimmed = bytes.count + 10
        guard case .reset(_, let cut) = follower.read(stream: Array(lines(20..<22).utf8)[...], base: UInt64(trimmed)) else { Issue.record("not a reset"); return }
        #expect(cut)
    }
}

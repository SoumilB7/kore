import Foundation
import KoreCore
import Testing

@Suite("Bounded command output tails")
struct OutputTailTests {
    private func read(_ bytes: Data, lines: Int = 3, maxBytes: UInt64 = 256 * 1024) throws -> OutputTail {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kore-output-tail-\(UUID()).output")
        defer { try? FileManager.default.removeItem(at: file) }
        try bytes.write(to: file)
        return try #require(OutputTail.read(file, lines: lines, maxBytes: maxBytes))
    }

    @Test(arguments: [false, true])
    func anOversizedLineKeepsOnlyItsBoundedSuffix(terminated: Bool) throws {
        let cap = 256 * 1024
        var bytes = Data(repeating: 0x78, count: 16 * 1024 * 1024)
        if terminated { bytes[bytes.count - 1] = 0x0A }
        let tail = try read(bytes, maxBytes: UInt64(cap))
        #expect(tail.lines == [String(repeating: "x", count: cap - (terminated ? 1 : 0))])
        #expect(tail.truncated)
    }

    @Test func theNewestLinesSurviveAnOversizedEarlierLine() throws {
        var bytes = Data(repeating: 0x78, count: 16 * 1024 * 1024)
        bytes.append(contentsOf: "\nlatest\npartial".utf8)
        let tail = try read(bytes, lines: 2)
        #expect(tail.lines == ["latest", "partial"])
        #expect(tail.truncated)
    }

    @Test func normalTailsIncludeTheUnfinishedLineAndMetadata() throws {
        let bytes = Data("first\nsecond\nthird\npartial".utf8)
        let tail = try read(bytes)
        #expect(tail.lines == ["second", "third", "partial"])
        #expect(tail.modified != nil)
        #expect(tail.truncated)
        let whole = try read(bytes, lines: Int.max)
        #expect(whole.lines == ["first", "second", "third", "partial"])
        #expect(!whole.truncated)
    }

    @Test func completeEmptyLFLinesAreSkipped() throws {
        let tail = try read(Data("\nfirst\n\nlast\n\n".utf8))
        #expect(tail.lines == ["first", "last"])
        #expect(!tail.truncated)
        #expect(try read(Data("\n\n".utf8)).lines.isEmpty)
    }

    @Test func CRLFAndAnUnfinishedCarriageReturnKeepTheirExistingBehavior() throws {
        let tail = try read(Data("first\r\n\r\nlast\r\npartial\r".utf8), lines: 4)
        #expect(tail.lines == ["first", "", "last", "partial"])
        #expect(!tail.truncated)
    }

    @Test(arguments: [
        (UInt64(1), [String]()),
        (UInt64(2), ["Z"]),
        (UInt64(3), ["Z"]),
        (UInt64(4), ["éZ"]),
        (UInt64(5), ["éZ"]),
        (UInt64(6), ["éZ"]),
        (UInt64(7), ["éZ"]),
        (UInt64(8), ["🙂éZ"]),
        (UInt64(9), ["A🙂éZ"]),
    ])
    func aByteBoundaryDoesNotInventReplacementCharacters(cap: UInt64, expected: [String]) throws {
        let tail = try read(Data("old\nA🙂éZ\n".utf8), maxBytes: cap)
        #expect(tail.lines == expected)
        #expect(tail.truncated)
    }

    @Test func aBudgetTooSmallForTheLastScalarReturnsAnEmptyTruncatedTail() throws {
        let tail = try read(Data("🙂".utf8), maxBytes: 2)
        #expect(tail.lines.isEmpty)
        #expect(tail.truncated)
    }

    @Test(arguments: [UInt64(4), UInt64(5), UInt64.max])
    func exactAndLargerBudgetsKeepTheWholeFile(cap: UInt64) throws {
        let tail = try read(Data("a\nb\n".utf8), maxBytes: cap)
        #expect(tail.lines == ["a", "b"])
        #expect(!tail.truncated)
    }

    @Test(arguments: [Int.min, -1, 0])
    func nonpositiveLineCountsReturnNothing(count: Int) throws {
        let tail = try read(Data("some output\n".utf8), lines: count)
        #expect(tail.lines.isEmpty)
        #expect(tail.truncated)
        #expect(OutputTail.lines(of: "a\nb\n", count: count).isEmpty)
    }

    @Test func zeroBudgetAndEmptyFilesAreSafe() throws {
        let limited = try read(Data("some output\n".utf8), maxBytes: 0)
        #expect(limited.lines.isEmpty)
        #expect(limited.truncated)
        for cap in [UInt64(0), 1, .max] {
            let empty = try read(Data(), maxBytes: cap)
            #expect(empty.lines.isEmpty)
            #expect(!empty.truncated)
        }
    }

    @Test func malformedFileBytesStillUseReplacementCharacters() throws {
        let tail = try read(Data([0xFF, 0x0A]))
        #expect(tail.lines == ["�"])
        #expect(!tail.truncated)
    }

    @Test func aMissingFileIsNil() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kore-output-tail-missing-\(UUID())")
        #expect(OutputTail.read(file, lines: 3) == nil)
    }
}

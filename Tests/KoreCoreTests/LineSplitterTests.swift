import Foundation
import Testing

@testable import KoreCore

@Suite("splitting a CLI's output into lines")
struct LineSplitterTests {
    private func split(_ chunks: [String]) -> [String] {
        var splitter = LineSplitter()
        var lines = chunks.flatMap { splitter.feed(Data($0.utf8)) }
        if let last = splitter.finish() { lines.append(last) }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The splitter before it searched only new bytes, as the reference.
    private func reference(_ chunks: [Data]) -> [Data] {
        var buffer = Data()
        var lines: [Data] = []
        for chunk in chunks {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { lines.append(Data(line)) }
            }
        }
        if !buffer.isEmpty, !buffer.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { lines.append(buffer) }
        return lines
    }

    @Test func joinsALineSplitAcrossChunks() {
        #expect(split(["ab", "c\nd", "e\n"]) == ["abc", "de"])
        #expect(split(["a", "\nb\n"]) == ["a", "b"])
    }

    @Test func splitsSeveralLinesInOneChunk() {
        #expect(split(["a\nb\nc\n"]) == ["a", "b", "c"])
    }

    @Test func keepsTheCarriageReturnOfACRLFSplitAcrossChunks() {
        #expect(split(["x\r", "\ny\r\n"]) == ["x\r", "y\r"])
    }

    @Test func dropsEmptyAndBlankLines() {
        #expect(split(["a\n\n \r\n", "\nb\n"]) == ["a", "b"])
        #expect(split(["one\n  \r"]) == ["one"])
        #expect(split([]) == [] && split([""]) == [])
    }

    @Test func keepsAFinalLineWithoutANewline() {
        #expect(split(["one\ntw", "o"]) == ["one", "two"])
        var splitter = LineSplitter()
        _ = splitter.feed(Data("x\ny".utf8))
        #expect(splitter.finish() == Data("y".utf8))
        #expect(splitter.finish() == nil)
    }

    @Test func doesNotSplitOnLineSeparatorsInsideJSONStrings() {
        #expect(split(["a\u{2028}b\u{2029}c\n"]) == ["a\u{2028}b\u{2029}c"])
    }

    @Test func matchesTheOldSplitterOnRandomStreams() {
        var rng = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = [0x0A, 0x0A, 0x0D, 0x20, 0x61, 0x62, 0x7B, 0xE2]
        for _ in 0..<2000 {
            let bytes = (0..<Int.random(in: 0..<300, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            var chunks: [Data] = []
            var i = 0
            while i < bytes.count {
                let n = Int.random(in: 1...40, using: &rng)
                chunks.append(Data(bytes[i..<min(i + n, bytes.count)]))
                i += n
            }
            var splitter = LineSplitter()
            var lines = chunks.flatMap { splitter.feed($0) }
            if let last = splitter.finish() { lines.append(last) }
            #expect(lines == reference(chunks), "chunks: \(chunks.map { Array($0) })")
            if lines != reference(chunks) { return }
        }
    }

    @Test func splitsA40MBLineIn64KBChunksQuickly() {
        let big = Data(repeating: 0x61, count: 40_000_000) + Data("\nnext\n".utf8)
        var splitter = LineSplitter()
        let start = Date()
        var lines: [Data] = []
        var offset = 0
        while offset < big.count {
            lines += splitter.feed(big[offset..<min(offset + 65_536, big.count)])
            offset += 65_536
        }
        // Rescanning the whole buffer per chunk took minutes; a linear pass takes a fraction of a second.
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(lines.count == 2 && lines[0].count == 40_000_000 && lines[1] == Data("next".utf8))
    }
}

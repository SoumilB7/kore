import Foundation
import Testing

@testable import KoreCore

@Suite("stdout split into lines")
struct LineSplitterTests {
    private func strings(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    @Test func aLineSplitAcrossChunksComesOutWhole() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("ab".utf8)).isEmpty)
        #expect(strings(splitter.feed(Data("c\nde".utf8))) == ["abc"])
        #expect(strings(splitter.feed(Data("f\n".utf8))) == ["def"])
    }

    @Test func blankLinesAreDropped() {
        var splitter = LineSplitter()
        #expect(strings(splitter.feed(Data("a\n\n  \n\r\nb\n".utf8))) == ["a", "b"])
    }

    @Test func aLastLineWithoutNewlineComesOutAtTheEnd() {
        var splitter = LineSplitter()
        #expect(strings(splitter.feed(Data("x\ny".utf8))) == ["x"])
        #expect(splitter.finish().map { String(decoding: $0, as: UTF8.self) } == "y")
        #expect(splitter.finish() == nil)
    }

    @Test func aLongLineFedInSmallChunks() {
        let long = String(repeating: "0123456789", count: 100_000)
        var splitter = LineSplitter()
        var out: [Data] = []
        let bytes = Data((long + "\nend\n").utf8)
        var at = 0
        while at < bytes.count {
            let next = min(at + 4096, bytes.count)
            out += splitter.feed(bytes.subdata(in: at..<next))
            at = next
        }
        #expect(out.count == 2)
        #expect(out.first?.count == long.utf8.count)
    }
}

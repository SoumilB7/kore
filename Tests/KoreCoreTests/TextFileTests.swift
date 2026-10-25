import Foundation
import Testing

@testable import KoreCore

@Suite("opening and saving text files")
struct TextFileTests {
    @Test(arguments: [
        ("a\n\tb\n\tc\n", TextFile.Indent.tabs),
        ("a\n  b\n    c\n  d\n", TextFile.Indent.spaces(2)),
        ("a {\n    b\n        c\n    d\n}\n", TextFile.Indent.spaces(4)),
        ("no indent at all\n", TextFile.Indent.spaces(4)),
    ])
    func detectsIndentation(text: String, indent: TextFile.Indent) {
        #expect(TextFile.detectIndent(text) == indent)
    }

    @Test func keepsCRLFAndBOMThroughASave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-textfile-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8)).write(to: url)

        var file = TextFile.read(url)
        #expect(file.content == .text("one\ntwo\n"))
        #expect(file.lineEnding == .crlf)
        #expect(file.hasBOM)

        _ = try file.write("one\ntwo\nthree\n", to: url)
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree\r\n".utf8)))
        file = TextFile.read(url)
        #expect(file.content == .text("one\ntwo\nthree\n"))
    }

    /// The stamp a save returns is the file it wrote, even when the same URL was stamped just
    /// before (URLs keep resource values they read): else the next save sees its own write as
    /// a change on disk.
    @Test func aSaveStampsTheFileItWrote() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-textfile-\(UUID()).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let file = TextFile.read(url)
        #expect(TextFile.Stamp.of(url)?.size == 0)
        let stamp = try file.write("# Black Eye\n", to: url)
        #expect(stamp?.size == 12)
        #expect(stamp == TextFile.Stamp.of(URL(fileURLWithPath: url.path)))
        #expect(TextFile.Stamp.of(url) == stamp)
    }

    @Test func nulBytesMeanBinary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-textfile-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x41, 0x00, 0x42]).write(to: url)
        #expect(TextFile.read(url).content == .binary)
    }

    @Test func aMissingFileSaysSo() {
        #expect(TextFile.read(URL(fileURLWithPath: "/nonexistent/\(UUID())")).content == .missing)
    }
}

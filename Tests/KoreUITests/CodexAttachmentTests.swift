import Foundation
import Testing

@testable import KoreUI

@Suite("Codex attachments")
struct CodexAttachmentTests {
    @Test func theModelIsToldOfEachAttachedFileAfterTheText() throws {
        let file = Attachments.File(url: URL(fileURLWithPath: "/tmp/notes.txt"), name: "notes.txt", kind: .text)
        let image = Attachments.File(url: URL(fileURLWithPath: "/tmp/shot.png"), name: "shot.png", kind: .image)
        let items = try #require(Attachments.codexInput(text: "Look", files: [file, image]).array)
        #expect(items.map { $0["type"]?.string } == ["mention", "localImage", "text", "text"])
        #expect(items[2]["text"]?.string == "Look")
        // Not on disk: named by its path.
        #expect(items[3]["text"]?.string == "[file: /tmp/notes.txt] (attached: open it with your tools)")
        #expect(Attachments.isFileNote("[file: /tmp/notes.txt]\nhello\n[/file]"))
        #expect(!Attachments.isFileNote("Look at [file: /tmp/notes.txt]"))
        #expect(!Attachments.isFileNote(""))
    }

    @Test func aSmallTextFileComesWhole() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-note-\(UUID().uuidString).txt")
        try "The codeword is X.".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let note = Attachments.fileNote(Attachments.File(url: url, name: "n.txt", kind: .text))
        #expect(note == "[file: \(url.path)]\nThe codeword is X.\n[/file]")
    }
}

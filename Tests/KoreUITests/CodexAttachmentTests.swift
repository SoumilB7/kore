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
        #expect(items[3]["text"]?.string == "[file: /tmp/notes.txt]")
        #expect(Attachments.isFileNote("[file: /tmp/notes.txt]\n[file: /tmp/b c.md]"))
        #expect(!Attachments.isFileNote("Look at [file: /tmp/notes.txt]"))
        #expect(!Attachments.isFileNote(""))
    }
}

import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import KoreUI

/// A whole composer draft (⌘A ⌘C) on a pasteboard of the tests' own, and back (⌘V).
@MainActor
@Suite("Copying a whole draft", .serialized)
final class DraftClipboardTests {
    let board = NSPasteboard(name: .init("kore-tests-draft"))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-draft-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// A 6×4 JPEG turned on its side by its EXIF orientation (6: 90° clockwise).
    private func rotatedJPEG() throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try #require(rep.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func orientation(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyOrientation] as? Int
    }

    private func files() throws -> (image: URL, file: URL, second: URL, bytes: Data) {
        let bytes = try rotatedJPEG()
        let image = folder.appendingPathComponent("Photo 1.jpg")
        try bytes.write(to: image)
        let file = folder.appendingPathComponent("notes.md")
        try Data("# notes\n".utf8).write(to: file)
        let second = folder.appendingPathComponent("b.swift")
        try Data("let b = 1\n".utf8).write(to: second)
        return (image, file, second, bytes)
    }

    /// Everything a composer can hold: a command chip, text with its pasted block and its
    /// "$skill" and "@path" tokens, and files of every kind (text, image, PDF, binary, folder).
    @Test func everythingComesBackInItsOrder() throws {
        let (image, file, second, bytes) = try files()
        let pdf = folder.appendingPathComponent("spec.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdf)
        let binary = folder.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 255]).write(to: binary)
        let directory = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let order = [file, image, pdf, binary, directory, second]
        let text = "look at these $review-skill and @src/a.swift\n```\nlet pasted = \"block\"\n```\n  trailing  "
        let command = SlashCommand(name: "review", description: "Review", hint: "objective", kind: .command)
        let copied = DraftClipboard(provider: "claude", text: text, command: command, attachments: order.map(Attachment.init(url:)))
        copied.write(to: board)

        let pasted = try #require(DraftClipboard.read(from: board))
        #expect(pasted == copied)
        #expect(pasted.text == text)
        #expect(pasted.command?.slashCommand == command)
        #expect(pasted.files.map(\.name) == ["notes.md", "Photo 1.jpg", "spec.pdf", "blob.bin", "src", "b.swift"])
        #expect(pasted.urls().map(\.standardizedFileURL.path) == order.map(\.standardizedFileURL.path))
        #expect(pasted.urls().map(Attachments.kind(of:)) == [.text, .image, .pdf, .other, .other, .text])
        #expect(pasted.files.filter { $0.image != nil }.count == 1)
        // The image byte for byte, its EXIF orientation with it.
        #expect(pasted.files[1].image == bytes)
        #expect(orientation(try #require(pasted.files[1].image)) == 6)
    }

    /// A pasted image's temp file cleaned up before the paste: its bytes come back in a file of
    /// its own name, unchanged, still in its place among the others.
    @Test func anImageWhoseFileHasGoneComesBackFromItsBytes() throws {
        let (image, file, _, bytes) = try files()
        DraftClipboard(provider: "codex", text: "", command: nil, attachments: [image, file].map(Attachment.init(url:)))
            .write(to: board)
        try FileManager.default.removeItem(at: image)

        let urls = try #require(DraftClipboard.read(from: board)).urls()
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        #expect(urls.count == 2)
        #expect(urls[0].lastPathComponent == "Photo 1.jpg")
        #expect(try Data(contentsOf: urls[0]) == bytes)
        #expect(urls[1] == file)
    }

    /// Other apps get the text, the files and the picture.
    @Test func otherAppsGetTextFilesAndImages() throws {
        let (image, file, _, bytes) = try files()
        let command = SlashCommand(name: "review", description: "Review", hint: "", kind: .command)
        DraftClipboard(provider: "claude", text: "this PR", command: command, attachments: [image, file].map(Attachment.init(url:)))
            .write(to: board)

        #expect(board.string(forType: .string) == "/review this PR")
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls == [image, file])
        #expect(board.pasteboardItems?[1].data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) == bytes)
        #expect(try #require(DraftClipboard.read(from: board)).command?.name == "review")
    }

    @Test func plainTextIsNoDraft() {
        board.clearContents()
        board.setString("just text", forType: .string)
        #expect(DraftClipboard.read(from: board) == nil)
        #expect(!DraftClipboard.isOn(board))
    }
}

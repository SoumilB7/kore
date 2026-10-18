import AppKit
import Foundation
import Testing

@testable import KoreUI

/// What ⌘V in the composer attaches, on a pasteboard of the tests' own (never the clipboard).
@MainActor
@Suite("Pasting attachments", .serialized)
final class PasteAttachmentsTests {
    let board = NSPasteboard(name: .init("kore-tests-paste"))

    private func png() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    private func jpeg() -> Data {
        NSBitmapImageRep(data: png())?.representation(using: .jpeg, properties: [:]) ?? Data()
    }

    /// The board holding these, then how many images a paste attaches (nil: pastes as text).
    /// The saved images are removed again.
    private func paste(_ items: [(NSPasteboard.PasteboardType, Data)]) -> Int? {
        board.clearContents()
        board.declareTypes(items.map(\.0), owner: nil)
        for (type, data) in items { board.setData(data, forType: type) }
        guard let urls = Attachments.fromPasteboard(board) else { return nil }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        return urls.filter { NSImage(contentsOf: $0) != nil }.count
    }

    private func text(_ string: String) -> (NSPasteboard.PasteboardType, Data) { (.string, Data(string.utf8)) }

    @Test func anImageAloneIsAttached() {
        #expect(paste([(.png, png())]) == 1)
    }

    /// Browsers and Slack put the image's address or name next to it.
    @Test func anImageWithItsAddressOrNameIsAttached() {
        #expect(paste([(.tiff, png()), text("https://example.com/cat.png")]) == 1)
        #expect(paste([(.png, png()), text("Screenshot 2026-10-21 at 10.15.32.png")]) == 1)
        #expect(paste([(.png, png()), text("  ")]) == 1)
    }

    @Test func aJPEGIsAttached() {
        #expect(paste([(NSPasteboard.PasteboardType("public.jpeg"), jpeg())]) == 1)
    }

    /// A spreadsheet's or editor's copy can carry a picture of the text: the text is what was meant.
    @Test func textWithAPictureOfItPastesAsText() {
        #expect(paste([text("let a = 1\nlet b = 2"), (.png, png())]) == nil)
        #expect(paste([text("Total"), (.tiff, png())]) == nil)
        #expect(paste([text("plain text")]) == nil)
    }

    @Test func copiedFilesAreAttached() {
        board.clearContents()
        let file = URL(fileURLWithPath: "/tmp/notes.txt")
        board.writeObjects([file as NSURL])
        #expect(Attachments.fromPasteboard(board) == [file])
    }
}

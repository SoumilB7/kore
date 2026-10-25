import AppKit
import Foundation
import Testing

@testable import KoreUI

/// An image's or a file's right-click menu in a chat: what it offers, and what its copies leave
/// on a pasteboard (a named one, never the owner's clipboard). On a temp folder.
@MainActor
@Suite("Media menu")
final class MediaMenuTests {
    let folder: URL
    nonisolated(unsafe) let board = NSPasteboard(name: .init("kore-media-menu-tests-\(UUID().uuidString)"))

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        board.releaseGlobally()
    }

    private func png(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try #require(rep?.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func titles(_ items: [OptionItem]) -> [String] { items.filter { !$0.separator }.map(\.title) }

    @Test func imagesAndFilesOfferTheirOwnActions() throws {
        let image = try png("shot.png")
        let file = folder.appendingPathComponent("notes.md")
        try "# notes".write(to: file, atomically: true, encoding: .utf8)
        #expect(titles(MediaMenu.items(.init(url: image), openInKore: {}))
            == ["Copy Image", "Copy Path", "Save As…", "Open", "Reveal in Finder", "Open in Kore Tab"])
        let fileItems = MediaMenu.items(.init(url: file), openInKore: {})
        #expect(titles(fileItems) == ["Copy File", "Copy Path", "Open", "Reveal in Finder", "Open in Kore"])
        #expect(fileItems.allSatisfy { $0.enabled })
    }

    @Test func aHistoryPictureWithNoFileStillCopiesAndViews() throws {
        let thumbnail = try #require(NSImage(contentsOf: try png("thumb.png")))
        let items = MediaMenu.items(.init(name: "pasted", url: nil, image: thumbnail), openInKore: {})
        let enabled = Dictionary(uniqueKeysWithValues: items.filter { !$0.separator }.map { ($0.title, $0.enabled) })
        #expect(enabled["Copy Image"] == true && enabled["Save As…"] == true && enabled["Open in Kore Tab"] == true)
        #expect(enabled["Copy Path"] == false && enabled["Open"] == false && enabled["Reveal in Finder"] == false)
        #expect(MediaMenu.copyImage(.init(name: "pasted", url: nil, image: thumbnail), to: board))
        #expect(board.data(forType: .png) != nil && board.data(forType: .tiff) != nil)
    }

    @Test func copyImageCarriesTheFilesOwnBytes() throws {
        let image = try png("shot.png")
        #expect(MediaMenu.copyImage(.init(url: image), to: board))
        let bytes = try Data(contentsOf: image)
        #expect(board.data(forType: .png) == bytes)
        #expect(board.data(forType: .tiff) != nil)
    }

    @Test func copyFileIsAFileURLAndCopyPathIsText() throws {
        let file = folder.appendingPathComponent("notes.md")
        try "# notes".write(to: file, atomically: true, encoding: .utf8)
        #expect(MediaMenu.copyFile(file, to: board))
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.lastPathComponent) == ["notes.md"])
        MediaMenu.copyPath(file, to: board)
        #expect(board.string(forType: .string) == file.path)
    }

    @Test func onlyLinksToFilesThatAreThereGetTheMenu() throws {
        try "x".write(to: folder.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        var opened: [URL] = []
        let link = try #require(URL(string: "main.swift:12"))
        let items = try #require(MediaMenu.items(link: link, folder: folder) { opened.append($0) })
        #expect(titles(items).first == "Copy File")
        items.last?.action?()
        #expect(opened.map(\.lastPathComponent) == ["main.swift"])
        let gone = try #require(URL(string: "gone.swift")), web = try #require(URL(string: "https://example.com"))
        #expect(MediaMenu.items(link: gone, folder: folder) { _ in } == nil)
        #expect(MediaMenu.items(link: web, folder: folder) { _ in } == nil)
    }

    @Test func aMissingFileOffersOnlyItsPath() {
        let gone = folder.appendingPathComponent("gone.txt")
        let items = MediaMenu.items(.init(url: gone), openInKore: nil).filter { !$0.separator }
        #expect(items.filter(\.enabled).map(\.title) == ["Copy Path"])
    }
}

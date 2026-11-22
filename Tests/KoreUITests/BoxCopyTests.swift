import Foundation
import HostClient
import LinkProtocol
import Testing

@testable import KoreUI

/// A box file whose renderer needs it on this Mac (Quick Look's workbooks, PDFs, films, an image
/// past what `fs.read` sends): copied over the link into `BoxFileCache`, shown from there, read
/// again when it changes, kept under the caps, gone with its window.
@MainActor
@Suite(.serialized)
struct BoxCopyTests {
    private static let sheet = Data([0x50, 0x4B, 3, 4, 0, 0, 1, 2, 3, 4])

    private func fake() -> BoxExplorerTests.FakeBox {
        let box = BoxExplorerTests.FakeBox()
        for name in ["t.xlsx", "r.pdf", "m.mp4", "a.xlsx", "b.xlsx", "c.xlsx"] {
            box.files["/w/" + name] = BoxFileRead(path: "/w/" + name, kind: .binary, size: 10, text: nil, image: nil, truncated: false, stamp: FileStamp(size: 10, mtime: 5))
            box.raw["/w/" + name] = Self.sheet
        }
        box.files["/w/big.png"] = BoxFileRead(path: "/w/big.png", kind: .image, size: 10, text: nil, image: nil, truncated: true, stamp: FileStamp(size: 10, mtime: 5))
        box.raw["/w/big.png"] = Self.sheet
        return box
    }

    private func cache() -> BoxFileCache {
        BoxFileCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("kore-box-files-\(UUID().uuidString)", isDirectory: true))
    }

    private func open(_ name: String, _ box: BoxExplorerTests.FakeBox, _ cache: BoxFileCache, window: String = "box:fakebox:/w") -> FileDocument {
        let document = FileDocument(box: "/w/" + name, source: box, standIn: URL(fileURLWithPath: "/fakebox/w/" + name), window: window, cache: cache)
        document.load()
        return document
    }

    private func shown(_ document: FileDocument) async throws -> URL {
        try await until { document.preview != nil }
        await document.rendering.resolve(document.renderURL)
        return try #require(document.preview)
    }

    @Test func aBoxWorkbookComesHereAndOpensInQuickLook() async throws {
        let (box, cache) = (fake(), cache())
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let sheet = open("t.xlsx", box, cache)
        let url = try await shown(sheet)
        #expect(url.path.hasPrefix(cache.root.path) && url.lastPathComponent == "t.xlsx")
        #expect(try Data(contentsOf: url) == Self.sheet)
        #expect(sheet.boxCopy == nil && sheet.renderURL == url)
        #expect(sheet.rendering.renderer?.id == QuickLookRenderer.id && sheet.rendering.showsRenderer)
        // Opened again in the window: the copy kept, the box asked only whether it changed.
        let asked = box.bytesAsked.count
        let again = open("t.xlsx", box, cache)
        #expect(try await shown(again) == url)
        #expect(box.bytesAsked.count == asked + 1)
        // PDFs, films and an image past what the box sends: the same way, each its renderer.
        for (name, renderer) in [("r.pdf", PDFRenderer.id), ("m.mp4", MediaRenderer.id), ("big.png", ImageRenderer.id)] {
            let document = open(name, box, cache)
            _ = try await shown(document)
            #expect(document.rendering.renderer?.id == renderer, "\(name)")
        }
        // A PDF the box read as text, as best it could: its bytes all the same.
        box.files["/w/t.pdf"] = BoxFileRead(path: "/w/t.pdf", kind: .text, size: 10, text: "%PDF-1.4 \u{FFFD}", image: nil, truncated: false, stamp: FileStamp(size: 10, mtime: 5))
        box.raw["/w/t.pdf"] = Data("%PDF-1.4\n".utf8) + Data([0xE2, 0xE3])
        let lossy = open("t.pdf", box, cache)
        #expect(try Data(contentsOf: try await shown(lossy)) == box.raw["/w/t.pdf"])
        #expect(lossy.rendering.renderer?.id == PDFRenderer.id)
        // Text never: it comes with the read.
        box.files["/w/n.md"] = BoxFileRead(path: "/w/n.md", kind: .text, size: 2, text: "hi", image: nil, truncated: false, stamp: FileStamp(size: 2, mtime: 1))
        let note = open("n.md", box, cache)
        try await until { note.loaded && note.isText }
        #expect(!box.bytesAsked.contains { $0.hasPrefix("/w/n.md") } && !cache.holds("fakebox", "/w/n.md"))
    }

    @Test func itSaysLoadingUntilTheCopyIsIn() async throws {
        let (box, cache) = (fake(), cache())
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let (open, opened) = AsyncStream<Void>.makeStream()
        box.gate = Task { for await _ in open { break } }
        let sheet = self.open("t.xlsx", box, cache)
        try await until { sheet.boxCopy == .loading }
        #expect(sheet.loaded && sheet.preview == nil)
        opened.yield(())
        _ = try await shown(sheet)
        #expect(sheet.boxCopy == nil)
    }

    @Test func pastTheCapItSaysSoAndKeepsNothing() async throws {
        let (box, cache) = (fake(), cache())
        defer { try? FileManager.default.removeItem(at: cache.root) }
        cache.fileCap = 4
        let sheet = open("t.xlsx", box, cache)
        try await until { sheet.boxCopy == .tooLarge(10) }
        #expect(sheet.preview == nil && !cache.holds("fakebox", "/w/t.xlsx") && cache.bytes == 0)
        #expect(box.bytesAsked == ["/w/t.xlsx@0"])
    }

    @Test func aChangeOnTheBoxShowsInPlace() async throws {
        let (box, cache) = (fake(), cache())
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let sheet = open("t.xlsx", box, cache)
        let url = try await shown(sheet)
        // The box says nothing changed: nothing comes, nothing reloads.
        let revision = sheet.revision
        let reads = box.reads
        sheet.reloadFromBox()
        try await until { box.reads == reads + 1 }
        #expect(sheet.revision == revision)
        // Changed: the new bytes where the old were, and the renderer reloads.
        box.raw["/w/t.xlsx"] = Data("PK new sheet".utf8)
        box.files["/w/t.xlsx"]?.stamp = FileStamp(size: 12, mtime: 6)
        box.files["/w/t.xlsx"]?.size = 12
        sheet.reloadFromBox()
        try await until { sheet.revision > revision }
        #expect(sheet.preview == url)
        #expect(try Data(contentsOf: url) == Data("PK new sheet".utf8))
    }

    @Test func anOlderBoxStillSaysWhy() async throws {
        let (box, cache) = (fake(), cache())
        defer { try? FileManager.default.removeItem(at: cache.root) }
        box.saysBytes = false
        let sheet = open("t.xlsx", box, cache)
        try await until { sheet.boxCopy == .failed("fakebox needs an update to preview this") }
        #expect(sheet.file.content == .binary && sheet.preview == nil)
    }

    @Test func copiesGoWithTheirWindowAndPastTheTotal() async throws {
        let (box, cache) = (fake(), cache())
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let one = try await shown(open("t.xlsx", box, cache, window: "one"))
        _ = try await shown(open("r.pdf", box, cache, window: "one"))
        _ = try await shown(open("r.pdf", box, cache, window: "two"))
        cache.windowClosed("one")
        // Only that window's: one the other still shows stays.
        #expect(!FileManager.default.fileExists(atPath: one.path) && !cache.holds("fakebox", "/w/t.xlsx"))
        #expect(cache.holds("fakebox", "/w/r.pdf"))
        cache.windowClosed("two")
        #expect(cache.bytes == 0)
        // Past the total, the least lately used go first.
        cache.totalCap = 25
        let a = try await shown(open("a.xlsx", box, cache))
        _ = try await shown(open("b.xlsx", box, cache))
        _ = try await shown(open("a.xlsx", box, cache))
        _ = try await shown(open("c.xlsx", box, cache))
        #expect(cache.holds("fakebox", "/w/a.xlsx") && !cache.holds("fakebox", "/w/b.xlsx") && cache.holds("fakebox", "/w/c.xlsx"))
        #expect(FileManager.default.fileExists(atPath: a.path) && cache.bytes == 20)
    }

    private func until(_ check: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while !check() {
            guard ContinuousClock.now < end else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

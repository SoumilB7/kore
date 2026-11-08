import AppKit
import Foundation
import HostClient
import LinkProtocol
import Testing

@testable import KoreUI

/// A box window's explorer and file tabs on a fake box: folders listed when opened, listed again
/// on refresh, files read read-only over the link.
@MainActor
struct BoxExplorerTests {
    final class FakeBox: BoxFileSource {
        let alias = "fakebox"
        var folders: [String: [FileEntry]] = [:]
        var refusals: [String: String] = [:]
        var files: [String: BoxFileRead] = [:]
        var listed: [String] = []
        var reads = 0

        func list(_ path: String?, hidden: Bool) async -> Result<BoxListing, HostRefusal> {
            let path = path ?? "/home/me"
            listed.append(path)
            if let why = refusals[path] { return .failure(HostRefusal(message: why)) }
            guard let entries = folders[path] else { return .failure(HostRefusal(message: "Not there on this box.")) }
            return .success(BoxListing(path: path, entries: entries, more: false))
        }

        func read(_ path: String, max: Int?) async -> Result<BoxFileRead, HostRefusal> {
            reads += 1
            guard let file = files[path] else { return .failure(HostRefusal(message: "Not there on this box.")) }
            return .success(file)
        }

        func makeFolder(_ path: String) async -> Result<String, HostRefusal> { .success(path) }
    }

    private static func fake() -> FakeBox {
        let box = FakeBox()
        box.folders["/w"] = [
            FileEntry(name: ".git", kind: .dir), FileEntry(name: "src", kind: .dir), FileEntry(name: "out", kind: .link, dir: true),
            FileEntry(name: ".env", kind: .file, size: 3), FileEntry(name: "README.md", kind: .file, size: 6),
        ]
        box.folders["/w/src"] = [FileEntry(name: "a.swift", kind: .file, size: 10)]
        box.refusals["/w/out"] = "A link out of the folder, not followed."
        return box
    }

    @Test func listsTheFolderThenEachFolderAsItOpens() async throws {
        let box = Self.fake()
        let store = BoxExplorerStore(root: "/w/", source: box)
        await store.start()
        #expect(store.rows.map(\.name) == ["src", "out", ".env", "README.md"])
        #expect(store.rows[1].isLink && store.rows[1].isFolder)
        #expect(box.listed == ["/w"])
        store.expand("/w/src")
        try await until { store.rows.count == 5 }
        #expect(store.rows[1] == .init(id: "/w/src/a.swift", name: "a.swift", depth: 1, isFolder: false, isOpen: false))
        // A link the box won't follow: one dim line under it, asked again when opened again.
        store.expand("/w/out")
        try await until { store.rows.contains { $0.kind == .note("A link out of the folder, not followed.") } }
        store.collapse("/w/out")
        box.refusals["/w/out"] = nil
        box.folders["/w/out"] = [FileEntry(name: "x", kind: .file)]
        store.expand("/w/out")
        try await until { store.rows.contains { $0.id == "/w/out/x" } }
        store.collapseAll()
        #expect(store.rows.count == 4)
    }

    @Test func refreshListsTheOpenFoldersAgainAndDropsOnesThatWent() async throws {
        let box = Self.fake()
        let store = BoxExplorerStore(root: "/w", source: box)
        await store.start()
        store.expand("/w/src")
        try await until { store.rows.count == 5 }
        box.folders["/w/src"]?.append(FileEntry(name: "b.swift", kind: .file))
        box.listed = []
        await store.refresh()
        #expect(Set(box.listed) == ["/w", "/w/src"])
        #expect(store.rows.map(\.name).contains("b.swift"))
        // The agent removed the folder: its rows go, and it isn't asked for.
        box.folders["/w"]?.removeAll { $0.name == "src" }
        box.folders["/w/src"] = nil
        box.listed = []
        await store.refresh()
        #expect(box.listed == ["/w"])
        #expect(!store.rows.contains { $0.id.hasPrefix("/w/src") })
    }

    @Test func aFolderTheBoxCantListSaysWhy() async {
        let box = Self.fake()
        box.refusals["/w"] = "fakebox needs an update to show files"
        let store = BoxExplorerStore(root: "/w", source: box)
        await store.start()
        #expect(store.rootLoaded)
        #expect(store.rootError == "fakebox needs an update to show files")
        box.refusals["/w"] = nil
        await store.refresh()
        #expect(store.rootError == nil)
        #expect(!store.isEmpty)
    }

    @Test func aBoxFileOpensReadOnlyWithItsTextOrImage() async throws {
        let box = Self.fake()
        box.files["/w/README.md"] = BoxFileRead(path: "/w/README.md", kind: .text, size: 6, text: "hi\r\nyo", image: nil, truncated: false)
        let text = FileDocument(box: "/w/README.md", standIn: URL(fileURLWithPath: "/fakebox/w/README.md")) { await box.read($0, max: nil) }
        #expect(text.readOnly)
        text.loadIfNeeded()
        try await until { text.loaded }
        #expect(text.storage.string == "hi\nyo")
        #expect(text.file.lineEnding == .crlf)
        #expect(text.boxCut == nil)
        // Read again after a turn: the same text changes nothing.
        let revision = text.revision
        text.reloadFromBox()
        try await until { box.reads == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(text.revision == revision)

        box.files["/w/big.log"] = BoxFileRead(path: "/w/big.log", kind: .text, size: 9_000_000, text: "start", image: nil, truncated: true)
        let big = FileDocument(box: "/w/big.log", standIn: URL(fileURLWithPath: "/fakebox/w/big.log")) { await box.read($0, max: nil) }
        big.load()
        try await until { big.loaded }
        #expect(big.boxCut == 9_000_000)

        let png = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true }.tiffRepresentation
        box.files["/w/p.png"] = BoxFileRead(path: "/w/p.png", kind: .image, size: 10, text: nil, image: png, truncated: false)
        let image = FileDocument(box: "/w/p.png", standIn: URL(fileURLWithPath: "/fakebox/w/p.png")) { await box.read($0, max: nil) }
        image.load()
        try await until { image.loaded }
        #expect(image.boxImage != nil)
        #expect(image.file.content == .image)

        let gone = FileDocument(box: "/w/nope", standIn: URL(fileURLWithPath: "/fakebox/w/nope")) { await box.read($0, max: nil) }
        gone.load()
        try await until { gone.loaded }
        #expect(gone.file.content == .unreadable("Not there on this box."))
    }

    private func until(_ check: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !check() {
            guard ContinuousClock.now < end else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

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

        func read(_ path: String, max: Int?, base: FileStamp?) async -> Result<BoxFileRead, HostRefusal> {
            reads += 1
            guard var file = files[path] else { return .failure(HostRefusal(message: "Not there on this box.")) }
            if let base, base == file.stamp { file.unchanged = true }
            return .success(file)
        }

        func makeFolder(_ path: String) async -> Result<String, HostRefusal> { .success(path) }

        // 1.8: an in-memory box folder.
        var trashed: [String] = []
        var watched: [String: Set<String>] = [:]
        var changedHandlers: [String: (@MainActor (BoxChange) -> Void)] = [:]
        var watching = true
        var refuseEdits: String?
        /// Edits take this long to answer, as over a link.
        var lag: Duration = .zero

        private func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        private func name(_ path: String) -> String { (path as NSString).lastPathComponent }

        func write(_ path: String, _ bytes: Data, base: FileStamp?) async -> Result<FileStamp, BoxWriteFailure> {
            if let why = refuseEdits { return .failure(.refused(why)) }
            let now = files[path]?.stamp
            if let base, base != now { return .failure(.conflict(now)) }
            let stamp = FileStamp(size: Int64(bytes.count), mtime: (now?.mtime ?? 0) + 1)
            files[path] = BoxFileRead(path: path, kind: .text, size: stamp.size, text: String(decoding: bytes, as: UTF8.self), image: nil, truncated: false, stamp: stamp)
            if folders[parent(path)]?.contains(where: { $0.name == name(path) }) == false { folders[parent(path)]?.append(FileEntry(name: name(path), kind: .file)) }
            return .success(stamp)
        }

        func create(_ path: String, folder: Bool) async -> Result<String, HostRefusal> {
            if lag > .zero { try? await Task.sleep(for: lag) }
            if let why = refuseEdits { return .failure(HostRefusal(message: why)) }
            folders[parent(path), default: []].append(FileEntry(name: name(path), kind: folder ? .dir : .file))
            if folder { folders[path] = [] } else { files[path] = BoxFileRead(path: path, kind: .text, size: 0, text: "", image: nil, truncated: false, stamp: FileStamp(size: 0, mtime: 1)) }
            return .success(path)
        }

        func rename(_ from: String, to: String) async -> Result<String, HostRefusal> {
            if lag > .zero { try? await Task.sleep(for: lag) }
            if let why = refuseEdits { return .failure(HostRefusal(message: why)) }
            guard var entry = folders[parent(from)]?.first(where: { $0.name == name(from) }) else { return .failure(HostRefusal(message: "Not there.")) }
            folders[parent(from)]?.removeAll { $0.name == name(from) }
            entry.name = name(to)
            folders[parent(to), default: []].append(entry)
            for key in folders.keys where key == from || key.hasPrefix(from + "/") { folders[to + key.dropFirst(from.count)] = folders.removeValue(forKey: key) }
            for key in files.keys where key == from || key.hasPrefix(from + "/") { files[to + key.dropFirst(from.count)] = files.removeValue(forKey: key) }
            return .success(to)
        }

        func trash(_ path: String) async -> Result<Void, HostRefusal> {
            if lag > .zero { try? await Task.sleep(for: lag) }
            if let why = refuseEdits { return .failure(HostRefusal(message: why)) }
            folders[parent(path)]?.removeAll { $0.name == name(path) }
            trashed.append(path)
            return .success(())
        }

        func search(_ root: String, _ query: String, text: Bool, max: Int, pages: (@MainActor ([FileHit]) -> Void)?)
            async -> Result<(hits: [FileHit], more: Bool), HostRefusal>
        {
            let hits = files.keys.sorted().filter { $0.hasPrefix(root + "/") }.flatMap { path -> [FileHit] in
                if !text { return name(path).lowercased().contains(query.lowercased()) ? [FileHit(path: path)] : [] }
                let lines = (files[path]?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                return lines.enumerated().compactMap { $0.element.lowercased().contains(query.lowercased()) ? FileHit(path: path, line: $0.offset + 1, text: String($0.element)) : nil }
            }
            return .success((Array(hits.prefix(max)), hits.count > max))
        }

        func watch(_ key: String, _ folders: Set<String>, changed: (@MainActor (BoxChange) -> Void)?) async -> Bool {
            watched[key] = folders.isEmpty ? nil : folders
            changedHandlers[key] = changed
            return watching
        }

        /// The box says these folders changed.
        func say(_ folders: Set<String>, names: [String: [String]] = [:]) {
            for handler in changedHandlers.values { handler(BoxChange(folders: folders, names: names)) }
        }
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
        try await until { store.rows.count == 5 && store.rows[1].kind == .node }
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
        try await until { store.rows.count == 5 && store.rows[1].kind == .node }
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
        let text = FileDocument(box: "/w/README.md", source: box, standIn: URL(fileURLWithPath: "/fakebox/w/README.md"))
        text.loadIfNeeded()
        try await until { text.loaded }
        // A box that can't say when it was read: read-only.
        #expect(text.readOnly)
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
        let big = FileDocument(box: "/w/big.log", source: box, standIn: URL(fileURLWithPath: "/fakebox/w/big.log"))
        big.load()
        try await until { big.loaded }
        #expect(big.boxCut == 9_000_000)

        let png = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true }.tiffRepresentation
        box.files["/w/p.png"] = BoxFileRead(path: "/w/p.png", kind: .image, size: 10, text: nil, image: png, truncated: false)
        let image = FileDocument(box: "/w/p.png", source: box, standIn: URL(fileURLWithPath: "/fakebox/w/p.png"))
        image.load()
        try await until { image.loaded }
        #expect(image.boxImage != nil)
        #expect(image.file.content == .image)

        let gone = FileDocument(box: "/w/nope", source: box, standIn: URL(fileURLWithPath: "/fakebox/w/nope"))
        gone.load()
        try await until { gone.loaded }
        #expect(gone.file.content == .unreadable("Not there on this box."))
    }

    func until(_ check: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !check() {
            guard ContinuousClock.now < end else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

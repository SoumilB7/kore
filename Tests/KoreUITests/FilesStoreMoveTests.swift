import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Drag-moves in the tree, on a temp folder. Only paths that leave nothing in the Trash are
/// run: a replace that's undone, or whose move fails, brings its item back from it.
@MainActor
@Suite("Files: moves and undo", .serialized)
final class FilesStoreMoveTests {
    let root: String
    let store: FilesStore
    var moves: [(String, String)] = []

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-moves-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("docs/guides"), withIntermediateDirectories: true)
        root = realPath(url.path)
        try "notes".write(toFile: root + "/notes.md", atomically: true, encoding: .utf8)
        try "old".write(toFile: root + "/docs/notes.md", atomically: true, encoding: .utf8)
        try "readme".write(toFile: root + "/readme.md", atomically: true, encoding: .utf8)
        store = FilesStore(folder: url)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: root + "/" + path, encoding: .utf8) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root + "/" + path) }

    private func transfer(
        _ names: [String], into folder: String, copy: Bool = false, collision: FilesStore.Collision = .cancel
    ) -> (done: [FilesStore.Transfer], failure: FilesStore.Failure?) {
        store.transfer(names.map { root + "/" + $0 }, into: folder.isEmpty ? root : root + "/" + folder, copy: copy,
                       collision: { _ in collision }, moved: { self.moves.append(($0, $1)) })
    }

    @Test func refusesAFolderIntoItselfOrBelowAndANoOpMove() {
        #expect(!store.canDrop(root + "/docs", into: root + "/docs", copy: false))
        #expect(!store.canDrop(root + "/docs", into: root + "/docs/guides", copy: true))
        #expect(!store.canDrop(root + "/readme.md", into: root, copy: false))
        #expect(store.canDrop(root + "/readme.md", into: root, copy: true))
        #expect(store.canDrop(root + "/readme.md", into: root + "/docs", copy: false))
    }

    @Test func aMoveAndItsUndoAndRedo() {
        let (done, failure) = transfer(["readme.md"], into: "docs/guides")
        #expect(failure == nil)
        #expect(read("docs/guides/readme.md") == "readme")
        #expect(!exists("readme.md"))
        #expect(moves.map(\.1) == [root + "/docs/guides/readme.md"])
        #expect(store.selection == root + "/docs/guides/readme.md")
        #expect(store.undo(done) { self.moves.append(($0, $1)) } == nil)
        #expect(read("readme.md") == "readme")
        #expect(!exists("docs/guides/readme.md"))
        let again = store.redo(done) { self.moves.append(($0, $1)) }
        #expect(again.failure == nil)
        #expect(read("docs/guides/readme.md") == "readme")
    }

    @Test func aCopyIntoItsOwnFolderIsACopy() {
        let (done, _) = transfer(["readme.md"], into: "", copy: true)
        #expect(done.map(\.to) == [root + "/readme copy.md"])
        #expect(read("readme.md") == "readme")
        #expect(moves.isEmpty)
        let second = transfer(["readme.md"], into: "", copy: true)
        #expect(second.done.map(\.to) == [root + "/readme copy 2.md"])
    }

    @Test func keepBothNamesTheNewOne() {
        let (done, _) = transfer(["notes.md"], into: "docs", collision: .keepBoth)
        #expect(done.map(\.to) == [root + "/docs/notes copy.md"])
        #expect(read("docs/notes.md") == "old")
        #expect(read("docs/notes copy.md") == "notes")
    }

    @Test func cancelStopsTheRest() {
        let (done, _) = transfer(["notes.md", "readme.md"], into: "docs", collision: .cancel)
        #expect(done.isEmpty)
        #expect(exists("readme.md"))
    }

    /// Replace sends the old item to the Trash; undo moves the new one home and brings the old
    /// one back.
    @Test func aReplaceUndone() {
        let (done, failure) = transfer(["notes.md"], into: "docs", collision: .replace)
        #expect(failure == nil)
        #expect(read("docs/notes.md") == "notes")
        #expect(done.first?.replaced != nil)
        #expect(store.undo(done) { _, _ in } == nil)
        #expect(read("notes.md") == "notes")
        #expect(read("docs/notes.md") == "old")
    }

    /// A replace whose move fails (its source is gone) puts the original back.
    @Test func aFailedReplacePutsTheOriginalBack() throws {
        try FileManager.default.removeItem(atPath: root + "/notes.md")
        let (done, failure) = transfer(["notes.md"], into: "docs", collision: .replace)
        #expect(done.isEmpty)
        #expect(failure != nil)
        #expect(read("docs/notes.md") == "old")
    }

    @Test func unusedNames() throws {
        #expect(FilesStore.unusedName(for: "notes.md", in: root) == root + "/notes copy.md")
        #expect(FilesStore.unusedName(for: "docs", in: root) == root + "/docs copy")
        #expect(FilesStore.unusedName(for: ".env", in: root) == root + "/.env copy")
        try "x".write(toFile: root + "/notes copy.md", atomically: true, encoding: .utf8)
        #expect(FilesStore.unusedName(for: "notes.md", in: root) == root + "/notes copy 2.md")
    }
}

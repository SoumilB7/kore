import Foundation
import HostClient
import LinkProtocol
import Testing

@testable import KoreUI

/// A box window's explorer and editor changing the box's files (link 1.8) on a fake box: new,
/// rename, move, Move to Trash, Finder drops, watched folders, saves and their conflicts.
@MainActor
struct BoxEditTests {
    private static func fake() -> BoxExplorerTests.FakeBox {
        let box = BoxExplorerTests.FakeBox()
        box.folders["/w"] = [FileEntry(name: "src", kind: .dir), FileEntry(name: "a.txt", kind: .file)]
        box.folders["/w/src"] = [FileEntry(name: "b.swift", kind: .file)]
        box.files["/w/a.txt"] = BoxFileRead(path: "/w/a.txt", kind: .text, size: 3, text: "hi\n", image: nil, truncated: false, stamp: FileStamp(size: 3, mtime: 5))
        box.files["/w/src/b.swift"] = BoxFileRead(
            path: "/w/src/b.swift", kind: .text, size: 4, text: "let\n", image: nil, truncated: false, stamp: FileStamp(size: 4, mtime: 5))
        return box
    }

    private func until(_ check: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !check() {
            guard ContinuousClock.now < end else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func newRenameMoveAndTrashGoToTheBox() async throws {
        let box = Self.fake()
        let store = BoxExplorerStore(root: "/w", source: box)
        var moved: [(String, String)] = []
        var gone: [String] = []
        store.onMoved = { moved.append(($0, $1)) }
        store.onTrashed = { gone += $0 }
        await store.start()
        // New File… in the selected folder: its field, then the file, selected.
        store.pickOnly("/w/src")
        store.startNew(folder: false)
        #expect(store.edit == .newFile(parent: "/w/src"))
        #expect(store.rows.contains { $0.kind == .newFile && $0.depth == 1 })
        store.edit = nil
        #expect(try await store.create("c.swift", in: "/w/src", folder: false).get() == "/w/src/c.swift")
        #expect(store.selection == "/w/src/c.swift")
        #expect(store.rows.map(\.id).contains("/w/src/c.swift"))
        // A taken or bad name never reaches the box.
        if case .success = await store.create("B.swift", in: "/w/src", folder: false) { Issue.record("a taken name went") }
        #expect(BoxExplorerStore.refusal("a/b") != nil)
        // Rename: open tabs follow.
        #expect(try await store.rename("/w/a.txt", to: "b.txt").get() == "/w/b.txt")
        #expect(moved.last! == ("/w/a.txt", "/w/b.txt"))
        // ⌘X ⌘V: a move.
        #expect(await store.move(["/w/b.txt"], into: "/w/src") == nil)
        #expect(store.rows.map(\.id).contains("/w/src/b.txt"))
        // Move to Trash: the box's trash, the selection gone with it.
        store.pickOnly("/w/src/b.txt")
        #expect(await store.trash(["/w/src/b.txt"]) == nil)
        #expect(box.trashed == ["/w/src/b.txt"])
        #expect(gone == ["/w/src/b.txt"])
        #expect(store.selection == nil)
        // The box refuses: said, nothing changes here.
        box.refuseEdits = "Can't move it to the trash on this box."
        #expect(await store.trash(["/w/src"]) == "Can't move it to the trash on this box.")
        #expect(store.rows.map(\.id).contains("/w/src"))
    }

    @Test func choosingSeveralWorksAsTheFilesExplorer() async {
        let box = Self.fake()
        let store = BoxExplorerStore(root: "/w", source: box)
        await store.start()
        store.pickOnly("/w/src")
        store.pickRange(to: "/w/a.txt")
        #expect(store.chosenTops == ["/w/src", "/w/a.txt"])
        store.pickToggle("/w/src")
        #expect(store.chosenTops == ["/w/a.txt"])
        #expect(store.targetFolder() == "/w")
    }

    @Test func theOpenFoldersAreWatchedAndTheirChangesShow() async throws {
        let box = Self.fake()
        let store = BoxExplorerStore(root: "/w", source: box)
        var changed: Set<String> = []
        store.onChanged = { changed.formUnion($0) }
        await store.start()
        try await until { box.watched.values.contains(["/w"]) }
        store.expand("/w/src")
        try await until { box.watched.values.contains(["/w", "/w/src"]) }
        #expect(store.watching)
        box.folders["/w/src"]?.append(FileEntry(name: "new.swift", kind: .file))
        box.say(["/w/src"])
        try await until { store.rows.map(\.id).contains("/w/src/new.swift") }
        #expect(changed == ["/w/src"])
        store.collapse("/w/src")
        try await until { box.watched.values.contains(["/w"]) }
        store.stop()
        try await until { box.watched.isEmpty }
    }

    @Test func aDropFromThisMacUploadsAndAskedNamesKeepBoth() async {
        let box = Self.fake()
        let store = BoxExplorerStore(root: "/w", source: box)
        await store.start()
        let failure = await store.upload([("a.txt", Data("new".utf8)), ("d.txt", Data("d".utf8))], into: "/w") { _ in .keepBoth }
        #expect(failure == nil)
        #expect(box.files["/w/a copy.txt"]?.text == "new")
        #expect(box.files["/w/a.txt"]?.text == "hi\n")
        #expect(box.files["/w/d.txt"]?.text == "d")
    }

    @Test func aSaveChecksTheBoxAndAConflictAsks() async throws {
        let box = Self.fake()
        let document = FileDocument(box: "/w/a.txt", source: box, standIn: URL(fileURLWithPath: "/fakebox/w/a.txt"))
        document.load()
        try await until { document.loaded }
        #expect(!document.readOnly)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "hello")
        document.edited()
        #expect(document.isDirty)
        document.save()
        try await until { !document.isDirty }
        #expect(box.files["/w/a.txt"]?.text == "hello\n")
        // Changed on the box meanwhile: the save is refused and the notice asks.
        box.files["/w/a.txt"] = BoxFileRead(path: "/w/a.txt", kind: .text, size: 6, text: "theirs", image: nil, truncated: false, stamp: FileStamp(size: 6, mtime: 99))
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        document.edited()
        document.save()
        try await until { document.notice == .changed }
        #expect(box.files["/w/a.txt"]?.text == "theirs")
        // Keep Mine writes over theirs.
        document.keepMine()
        try await until { document.notice == nil && !document.isDirty }
        #expect(box.files["/w/a.txt"]?.text == "mine hello\n")
        // Reload takes theirs.
        box.files["/w/a.txt"] = BoxFileRead(path: "/w/a.txt", kind: .text, size: 2, text: "t2", image: nil, truncated: false, stamp: FileStamp(size: 2, mtime: 200))
        document.reloadFromBox()
        try await until { document.storage.string == "t2" }
        #expect(!document.isDirty)
    }
}

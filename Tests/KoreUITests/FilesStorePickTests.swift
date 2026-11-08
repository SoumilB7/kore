import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Choosing several rows in the tree (⌘ and ⇧ clicks), on a temp folder.
@MainActor
@Suite("Files: choosing several", .serialized)
final class FilesStorePickTests {
    let root: String
    let store: FilesStore

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-picks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("docs"), withIntermediateDirectories: true)
        root = realPath(url.path)
        for name in ["a.md", "b.md", "c.md", "docs/d.md"] {
            try name.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
        }
        store = FilesStore(folder: url)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func loaded() async {
        for _ in 0..<200 where store.rows.count < 4 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aSpanRunsEitherWayAndFallsBackToTheTarget() {
        let ids = ["a", "b", "c", "d"]
        #expect(FilesStore.span(ids, from: "b", to: "d") == ["b", "c", "d"])
        #expect(FilesStore.span(ids, from: "d", to: "b") == ["b", "c", "d"])
        #expect(FilesStore.span(ids, from: "x", to: "c") == ["c"])
    }

    @Test func topsDropWhatSitsInsideAnotherChosenFolder() {
        #expect(FilesStore.tops(["/r/docs", "/r/docs/d.md", "/r/a.md", "/r/docsx"]) == ["/r/docs", "/r/a.md", "/r/docsx"])
    }

    @Test func commandClicksAddAndDropAndOneLeftIsASingleChoice() {
        store.pickOnly(root + "/a.md")
        store.pickToggle(root + "/c.md")
        #expect(store.picked == [root + "/a.md", root + "/c.md"])
        #expect(store.selection == root + "/c.md")
        store.pickToggle(root + "/c.md")
        #expect(store.picked.isEmpty)
        #expect(store.selection == root + "/a.md")
    }

    @Test func shiftTakesTheRowsFromTheAnchorAndAPlainPickEndsIt() async {
        await loaded()
        store.pickOnly(root + "/a.md")
        store.pickRange(to: root + "/c.md")
        #expect(store.chosen == [root + "/a.md", root + "/b.md", root + "/c.md"])
        // The anchor stays: a shorter range from it.
        store.pickRange(to: root + "/b.md")
        #expect(store.chosen == [root + "/a.md", root + "/b.md"])
        store.pickOnly(root + "/c.md")
        #expect(store.chosen == [root + "/c.md"])
    }

    @Test func movingTheSelectionOffTheChoiceEndsIt() {
        store.pickOnly(root + "/a.md")
        store.pickToggle(root + "/b.md")
        store.selection = root + "/docs"
        #expect(store.picked.isEmpty)
    }

    @Test func aTrashOfSeveralComesBackWhole() async throws {
        let paths = [root + "/a.md", root + "/b.md"]
        let result = store.trash(paths)
        #expect(result.failure == nil && result.done.count == 2)
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(store.restore(result.done) == nil)
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test func escStepsBackToNothingChosenAndNewItemsGoToTheRoot() {
        store.pickOnly(root + "/a.md")
        store.pickToggle(root + "/b.md")
        // Several chosen: down to the one with the keys.
        #expect(store.stepBack())
        #expect(store.picked.isEmpty && store.selection == root + "/b.md")
        // One chosen: nothing.
        #expect(store.stepBack())
        #expect(store.selection == nil && store.chosen.isEmpty)
        #expect(store.targetFolder() == root)
        // Nothing left to clear: Esc goes on to the rest.
        #expect(!store.stepBack())
        store.startNew(folder: false)
        #expect(store.edit == .newFile(parent: root))
        store.edit = nil
        store.startNew(folder: true)
        #expect(store.edit == .newFolder(parent: root))
        store.edit = nil
    }
}

/// Sticky folders: which open folders pin over the tree for a top row.
@Suite("Files: sticky folders")
struct StickyFoldersTests {
    struct R: TreeRowShape, Equatable {
        let id: String
        let depth: Int
        var isFolder = false
        var isOpen = false
    }

    private func ids(_ rows: [R], top: Int) -> [String] { FilesStore.stickyFolders(rows: rows, top: top).map(\.id) }

    /// src/ (open) > ui/ (open) > a.swift, b.swift; z.txt
    private let nested = [
        R(id: "src", depth: 0, isFolder: true, isOpen: true),
        R(id: "src/ui", depth: 1, isFolder: true, isOpen: true),
        R(id: "src/ui/a.swift", depth: 2),
        R(id: "src/ui/b.swift", depth: 2),
        R(id: "src/main.swift", depth: 1),
        R(id: "z.txt", depth: 0),
    ]

    @Test func nestedRowsPinTheirOpenFoldersRootFirst() {
        #expect(ids(nested, top: 2) == ["src", "src/ui"])
        #expect(ids(nested, top: 3) == ["src", "src/ui"])
        // Out of ui: only src stays.
        #expect(ids(nested, top: 4) == ["src"])
        // An open folder at the top shows its own row: only the folders above it.
        #expect(ids(nested, top: 1) == ["src"])
    }

    @Test func depthZeroAndOutOfRangePinNothing() {
        #expect(ids(nested, top: 0).isEmpty)
        #expect(ids(nested, top: 5).isEmpty)
        #expect(ids(nested, top: 6).isEmpty)
        #expect(ids([], top: 0).isEmpty)
    }

    @Test func aCompactChainIsOneRow() {
        // "a / b / c" shown as one row (its id the last folder), its files one level in.
        let rows = [
            R(id: "a/b/c", depth: 0, isFolder: true, isOpen: true),
            R(id: "a/b/c/x.txt", depth: 1),
            R(id: "a/b/c/y.txt", depth: 1),
        ]
        #expect(ids(rows, top: 2) == ["a/b/c"])
    }

    @Test func aCollapsedFolderPinsItsParentNotItself() {
        let rows = [
            R(id: "src", depth: 0, isFolder: true, isOpen: true),
            R(id: "src/closed", depth: 1, isFolder: true, isOpen: false),
            R(id: "src/open", depth: 1, isFolder: true, isOpen: true),
            R(id: "src/open/f", depth: 2),
        ]
        #expect(ids(rows, top: 1) == ["src"])
        #expect(ids(rows, top: 3) == ["src", "src/open"])
        // A parent that isn't an open folder (rows out of step) stops the walk.
        let broken = [R(id: "x", depth: 0, isFolder: true, isOpen: false), R(id: "x/f", depth: 1)]
        #expect(ids(broken, top: 1).isEmpty)
    }

    @Test func atMostFiveInnermostFolders() {
        var rows: [R] = []
        for depth in 0..<8 { rows.append(R(id: "d\(depth)", depth: depth, isFolder: true, isOpen: true)) }
        rows.append(R(id: "leaf", depth: 8))
        #expect(ids(rows, top: 8) == ["d3", "d4", "d5", "d6", "d7"])
    }
}

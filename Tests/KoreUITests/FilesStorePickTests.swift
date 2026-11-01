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
}

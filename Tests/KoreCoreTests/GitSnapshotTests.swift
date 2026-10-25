import Foundation
import Testing

@testable import KoreCore

/// A turn's changes read back from two snapshots, with the repo lookup remembered per folder:
/// a folder that isn't a repo yet, or whose repo went, is asked again.
@Suite("git snapshots")
struct GitSnapshotTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func git(_ args: String..., in folder: URL) async {
        _ = await Git.run(Array(args), in: folder)
    }

    private func write(_ text: String, _ name: String, in folder: URL) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func aTurnsEditIsAChange() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        await git("init", "-q", in: dir)
        try write("one\n", "notes.md", in: dir)
        let before = try #require(await GitSnapshot.take(dir))
        try write("one\ntwo\n", "notes.md", in: dir)
        let after = try #require(await GitSnapshot.take(dir))
        let changes = await before.changes(to: after)
        #expect(changes.map { $0.path.hasSuffix("notes.md") } == [true])
        #expect(changes.first?.added == 1)
    }

    @Test func aFolderMadeARepoLaterIsSeen() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await GitSnapshot.take(dir) == nil)
        await git("init", "-q", in: dir)
        try write("x\n", "a.txt", in: dir)
        #expect(await GitSnapshot.take(dir) != nil)
    }

    @Test func aRepoMadeAgainInTheSameFolderStillSnapshots() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        await git("init", "-q", in: dir)
        try write("x\n", "a.txt", in: dir)
        #expect(await GitSnapshot.take(dir) != nil)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".git"))
        await git("init", "-q", in: dir)
        try write("y\n", "b.txt", in: dir)
        let before = try #require(await GitSnapshot.take(dir))
        try write("z\n", "b.txt", in: dir)
        let after = try #require(await GitSnapshot.take(dir))
        #expect(await before.changes(to: after).map { $0.path.hasSuffix("b.txt") } == [true])
    }
}

import Foundation
import Testing

@testable import KoreCore

@Suite("Turn change log")
struct TurnChangeLogTests {
    private func change(_ path: String, lines: Int = 1) -> FileChange {
        let hunk = FileChange.Hunk(
            oldStart: 0, newStart: 1, lines: (1...lines).map { .init(kind: .add, text: "line \($0)", old: nil, new: $0) })
        return FileChange(path: path, kind: .add, hunks: [hunk])
    }

    private func line(_ key: String, _ changes: [FileChange]) throws -> Data {
        var data = Data(key.utf8)
        data.append(0x09)
        data.append(try JSONEncoder().encode(changes))
        data.append(0x0A)
        return data
    }

    private func temp() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("kore-log-\(UUID().uuidString).log").path
    }

    @Test func readsByKeyTheLastRecordWinning() throws {
        let path = temp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var data = try line("t1", [change("/a")])
        data += try line("t2", [change("/b")])
        data += try line("t1", [change("/c")])
        try data.write(to: URL(fileURLWithPath: path))
        let index = TurnChangeLog.Index(path: path)
        index.refresh()
        #expect(index.count == 2)
        #expect(index.changes("t1")?.map(\.path) == ["/c"])
        #expect(index.changes("t2")?.map(\.path) == ["/b"])
        #expect(index.changes("t3") == nil)
    }

    /// A line still being written isn't read until its newline arrives.
    @Test func aTornLastLineWaits() throws {
        let path = temp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let whole = try line("t1", [change("/a")]) + line("t2", [change("/b")])
        let cut = whole.count - 5
        try whole.prefix(cut).write(to: URL(fileURLWithPath: path))
        let index = TurnChangeLog.Index(path: path)
        index.refresh()
        #expect(index.changes("t1")?.map(\.path) == ["/a"])
        #expect(index.changes("t2") == nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: whole.suffix(5))
        try handle.close()
        index.refresh()
        #expect(index.changes("t2")?.map(\.path) == ["/b"])
    }

    @Test func aReplacedFileIsIndexedAgain() throws {
        let path = temp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try line("t1", [change("/a")]).write(to: URL(fileURLWithPath: path))
        let index = TurnChangeLog.Index(path: path)
        index.refresh()
        try line("t9", [change("/z")]).write(to: URL(fileURLWithPath: path), options: .atomic)
        index.refresh()
        #expect(index.changes("t1") == nil)
        #expect(index.changes("t9")?.map(\.path) == ["/z"])
    }

    /// `record` then `lookup` through the real file (removed afterwards).
    @Test func recordsAndLooksUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-log-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: TurnChangeLog.file(for: folder))
            try? FileManager.default.removeItem(at: folder)
        }
        TurnChangeLog.record([change("/a")], key: "msg_1", folder: folder)
        TurnChangeLog.record([change("/b")], key: "bad\tkey", folder: folder)
        TurnChangeLog.record([], key: "empty", folder: folder)
        let lookup = TurnChangeLog.lookup(folder: folder)
        #expect(lookup.changes("msg_1")?.map(\.path) == ["/a"])
        #expect(lookup.changes("empty") == nil)
        #expect(lookup.index.count == 1)
    }

    @Test func aRecordKeepsAtMostTheLineLimit() {
        let capped = TurnChangeLog.capped([change("/a", lines: 1500), change("/b", lines: 1500)])
        #expect(capped.flatMap(\.hunks).flatMap(\.lines).count == TurnChangeLog.lineLimit)
        #expect(capped.map(\.isTruncated) == [false, true])
        #expect(capped.map(\.added) == [1500, 1500])
    }
}

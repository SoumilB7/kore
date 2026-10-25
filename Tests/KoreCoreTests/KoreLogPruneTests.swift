import Foundation
import Testing

@testable import KoreCore

/// The logs folder keeps a week and a size at most.
struct KoreLogPruneTests {
    private func make(_ folder: URL, _ name: String, bytes: Int, created: Date, modified: Date) throws {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func oldFilesGoAndTheFolderStaysUnderItsCap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("logprune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let day: TimeInterval = 86400
        // Begun 9 days ago, written today: moves aside, kept until it's a week old.
        try make(folder, "sessions.log", bytes: 100, created: now - 9 * day, modified: now)
        // Last written 8 days ago: goes.
        try make(folder, "agents.log.1", bytes: 100, created: now - 10 * day, modified: now - 8 * day)
        // Fresh, but the folder is past its cap: the oldest of these goes first.
        try make(folder, "ui.log.1", bytes: 600, created: now - 2 * day, modified: now - 2 * day)
        try make(folder, "ui.log", bytes: 600, created: now - day, modified: now - 60)
        KoreLog.prune(folder, ttl: 7 * day, cap: 1000, now: now)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["sessions.log.1", "ui.log"])
    }
}

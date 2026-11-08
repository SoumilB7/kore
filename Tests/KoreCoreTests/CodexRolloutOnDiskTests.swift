import Foundation
import Testing

@testable import KoreCore

/// Codex's "no rollout found" can come from a search a busy Mac cut short: Kore looks for the
/// thread's rollout itself before it starts a new thread in the chat's place.
@Suite struct CodexRolloutOnDiskTests {
    @Test func aThreadsRolloutIsFoundInItsDayOrArchived() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "01a15a98-f6e9-7e80-8674-0e104d71eb49"
        let day = home.appendingPathComponent("sessions/2026/10/21")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        #expect(!CodexSession.rolloutOnDisk(id, home: home))
        try Data().write(to: day.appendingPathComponent("rollout-2026-10-21T00-05-37-\(id).jsonl"))
        #expect(CodexSession.rolloutOnDisk(id, home: home))
        #expect(!CodexSession.rolloutOnDisk("01a15a98-0000-0000-0000-000000000000", home: home))
        let archived = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try Data().write(to: archived.appendingPathComponent("rollout-2026-10-22T00-00-00-other.jsonl"))
        #expect(CodexSession.rolloutOnDisk("other", home: home))
    }
}

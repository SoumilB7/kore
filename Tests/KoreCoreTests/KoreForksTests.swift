import Foundation
import Testing

@testable import KoreCore

/// Kore's record of the forks it made: listed until the CLI lists them under their title, one
/// entry either way, and kept across a restart.
@Suite("Kore forks")
struct KoreForksTests {
    let folder = URL(fileURLWithPath: "/tmp/kore-forks-project")

    func store() -> (KoreForks, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-forks-\(UUID().uuidString).json")
        return (KoreForks(url: url), url)
    }

    func fork(_ cli: String, key: String, title: String = "Refactor (fork)") -> KoreForks.Fork {
        KoreForks.Fork(cli: cli, folder: folder, key: key, title: title, from: "source", at: "m3", source: "Refactor")
    }

    func session(_ id: String, _ title: String, agent: SessionSummary.Agent = .claude) -> SessionSummary {
        SessionSummary(id: id, agent: agent, title: title, updated: Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func unlistedForkIsAddedUnderItsTitle() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("claude", key: "f1"))
        let shown = forks.merged([session("other", "Other")], cli: "claude", agent: .claude, folder: folder)
        #expect(shown.map(\.id) == ["other", "f1"])
        #expect(shown.last?.title == "Refactor (fork)")
        // Another CLI's list or another folder's has none of it.
        #expect(forks.merged([], cli: "codex", agent: .codex, folder: folder).isEmpty)
        #expect(forks.merged([], cli: "claude", agent: .claude, folder: URL(fileURLWithPath: "/tmp/elsewhere")).isEmpty)
        #expect(forks.find(cli: "claude", id: "f1")?.made == false)
    }

    @Test func listedUnderItsTitleTheRecordGoes() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("claude", key: "f1"))
        forks.sent(cli: "claude", key: "f1")
        let shown = forks.merged([session("f1", "Refactor (fork)")], cli: "claude", agent: .claude, folder: folder)
        #expect(shown.count == 1)
        #expect(forks.find(cli: "claude", id: "f1") == nil)
    }

    @Test func listedUnderAnotherTitleKeepsTheFork() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("claude", key: "f1"))
        // The CLI wrote the first message before the fork's name.
        let shown = forks.merged([session("f1", "fix the theme")], cli: "claude", agent: .claude, folder: folder)
        #expect(shown.map(\.title) == ["Refactor (fork)"])
        // Listed: the CLI has the session, so it opens as itself from here.
        #expect(forks.find(cli: "claude", id: "f1")?.made == true)
    }

    @Test func codexThreadIdReplacesKoresAndMerges() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("codex", key: "k1"))
        #expect(forks.merged([], cli: "codex", agent: .codex, folder: folder).map(\.id) == ["k1"])
        forks.identified(cli: "codex", key: "k1", as: "thread-9")
        // Found by either id, made once the CLI named it.
        #expect(forks.find(cli: "codex", id: "k1")?.id == "thread-9")
        #expect(forks.find(cli: "codex", id: "thread-9")?.made == true)
        let shown = forks.merged([session("thread-9", "Refactor (fork)", agent: .codex)], cli: "codex", agent: .codex, folder: folder)
        #expect(shown.map(\.id) == ["thread-9"])
        #expect(forks.find(cli: "codex", id: "thread-9") == nil)
    }

    @Test func claudeIdentifiedUnderKoresIdStaysUnmade() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("claude", key: "f1"))
        forks.identified(cli: "claude", key: "f1", as: "f1")
        #expect(forks.find(cli: "claude", id: "f1")?.made == false)
        forks.sent(cli: "claude", key: "f1")
        #expect(forks.find(cli: "claude", id: "f1")?.made == true)
    }

    @Test func renameAndForget() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("claude", key: "f1"))
        forks.rename(cli: "claude", id: "f1", to: "Theme work")
        #expect(forks.merged([], cli: "claude", agent: .claude, folder: folder).map(\.title) == ["Theme work"])
        forks.forget(cli: "claude", id: "f1")
        #expect(forks.merged([], cli: "claude", agent: .claude, folder: folder).isEmpty)
    }

    @Test func keptAcrossARestart() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        forks.add(fork("claude", key: "f1"))
        forks.sync()
        let again = KoreForks(url: url)
        #expect(again.find(cli: "claude", id: "f1")?.title == "Refactor (fork)")
        #expect(again.forks(cli: "claude", folder: URL(fileURLWithPath: "/tmp/kore-forks-project/")).count == 1)
    }

    @Test func oldRecordsAreLetGo() {
        let (forks, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        var old = fork("claude", key: "old")
        old.t = Date().addingTimeInterval(-KoreForks.keep - 60).timeIntervalSince1970
        forks.add(old)
        forks.add(fork("claude", key: "new"))
        #expect(forks.forks(cli: "claude", folder: folder).map(\.key) == ["new"])
    }
}

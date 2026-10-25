import Foundation
import Testing

@testable import KoreCore
@testable import KoreUI

/// A Codex chat's app-server started again (the account changed, or it exited), against
/// `kore-fake-cli` playing written cassettes: a thread Codex never wrote starts fresh with the
/// chat's settings, Codex's "no rollout found" does the same, a refused resume isn't tried again
/// at every send, and none of it reads as a compaction.
@MainActor
@Suite("a Codex chat started again", .serialized)
struct CodexRelaunchTests {
    static let unturned = "01a16a16-2ab7-73b1-ae1a-402d276d7899"
    static let fresh = "01a16a17-5c10-7d21-9e3f-1b2c3d4e5f60"

    private static let fake: URL? = {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("kore-fake-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    private final class Marker {}

    private static let cassettes = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/cassettes")

    /// A scratch folder (with a Codex home of its own, where no rollout is ever written), and
    /// `kore-fake-cli` standing in for codex with `cassette`.
    private func standIn(_ cassette: String) throws -> URL {
        let fake = try #require(Self.fake, "kore-fake-cli isn't built beside the tests")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("codex-relaunch-\(UUID().uuidString)")
        let home = work.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        CLIExecutable.standIns.value = [
            "codex": .init(
                executable: fake,
                environment: [
                    "KORE_FAKE_AS": "codex", "KORE_FAKE_CASSETTE": Self.cassettes.appendingPathComponent(cassette).path,
                    "KORE_FAKE_CLAIMS": work.appendingPathComponent(".claims").path, "CODEX_HOME": home.path,
                ])
        ]
        return work
    }

    private func done(_ work: URL) {
        CLIExecutable.standIns.value = [:]
        try? FileManager.default.removeItem(at: work)
    }

    /// Every event the backend gives, as it gives them.
    private final class Heard {
        var events: [ChatEvent] = []
        var notices: [String] { events.compactMap { if case .notice(let text, true) = $0 { text } else { nil } } }
        var finished: Bool { events.contains { if case .turnFinished(_, .completed, _) = $0 { true } else { false } } }
        var answer: String {
            events.compactMap { if case .text(_, .answer, let text, .main) = $0 { text } else { nil } }.joined()
        }
    }

    private func listen(_ backend: CodexBackend) -> Heard {
        let heard = Heard()
        Task { for await event in backend.events { heard.events.append(event) } }
        return heard
    }

    private func until(_ what: String, _ done: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !done() {
            guard ContinuousClock.now < end else { throw Timeout(what: what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Timeout: Error { let what: String }

    /// The owner's case: a new chat's thread (no turn yet, so no rollout) relaunched when the
    /// account changed, then "hey". The cassette's second app-server expects `thread/start`: a
    /// `thread/resume` would end it.
    @Test func aThreadThatNeverRanATurnStartsFresh() async throws {
        let work = try standIn("codex-relaunch-unturned.jsonl")
        defer { done(work) }
        let backend = CodexBackend(BackendOptions(folder: work, mode: "askForApproval"))
        let heard = listen(backend)
        try await backend.start()
        try await until("the thread named") { backend.sessionId == Self.unturned }
        await backend.setEffort("low")
        await backend.relaunch(reason: "account changed")
        #expect(try await backend.send("hey", files: [], queued: nil))
        try await until("the turn's end") { heard.finished }
        #expect(backend.sessionId == Self.fresh)
        #expect(heard.answer == "Hi.")
        #expect(heard.notices.isEmpty)
        #expect(heard.events.contains { if case .sessionIdentified(Self.fresh) = $0 { true } else { false } })
        await backend.close()
    }

    /// Kore thought the thread was written (it was opened from history), but Codex has no
    /// rollout for it: a fresh thread on the same app-server, and the send goes through.
    @Test func noRolloutFoundStartsAFreshThread() async throws {
        let work = try standIn("codex-resume-no-rollout.jsonl")
        defer { done(work) }
        let past = SessionSummary(id: Self.unturned, agent: .codex, title: "hey", updated: .now)
        let backend = CodexBackend(BackendOptions(folder: work, resume: past, mode: "askForApproval"))
        let heard = listen(backend)
        try await backend.start()
        #expect(try await backend.send("hey", files: [], queued: nil))
        try await until("the turn's end") { heard.finished }
        #expect(backend.sessionId == Self.fresh)
        #expect(heard.notices.isEmpty)
        await backend.close()
    }

    /// Codex refuses the resume for another reason: each send says so, readable and without
    /// the thread's id, and no app-server starts again for it (the cassette has one: another
    /// launch would end with a different error).
    @Test func aRefusedResumeIsNotTriedAgainAtEachSend() async throws {
        let work = try standIn("codex-resume-refused.jsonl")
        defer { done(work) }
        let past = SessionSummary(id: Self.unturned, agent: .codex, title: "hey", updated: .now)
        let backend = CodexBackend(BackendOptions(folder: work, resume: past, mode: "askForApproval"))
        var said: [String] = []
        for _ in 0..<3 {
            do {
                _ = try await backend.send("hey", files: [], queued: nil)
            } catch {
                said.append(Chat.reason(error))
            }
        }
        #expect(said == ["thread not found", "thread not found", "thread not found"])
        await backend.close()
    }

    /// A compaction asked for while the CLI can't start says why it can't start, not
    /// "Couldn't compact"; the wheel stops turning; the send after it says the same.
    @Test func aStartFailureIsNotACompactionFailure() async throws {
        let work = try standIn("codex-resume-refused.jsonl")
        defer { done(work) }
        let past = SessionSummary(id: Self.unturned, agent: .codex, title: "hey", updated: .now)
        let chat = Chat(provider: .codex, folder: work, resume: past)
        defer { chat.close() }
        #expect(chat.canCompact)
        chat.compact()
        let notices = { chat.transcript.entries.filter { $0.kind == .notice && $0.isError }.map(\.text) }
        try await until("the notice") { !notices().isEmpty }
        #expect(notices() == ["thread not found"])
        #expect(!chat.context.compacting)
        chat.draft = "hey"
        chat.send()
        try await until("the send's notice") { notices().count == 2 }
        #expect(notices() == ["thread not found", "thread not found"])
        #expect(!chat.transcript.entries.contains { $0.text.contains("Couldn't compact") })
    }
}

/// Codex's errors as the chat says them: parsed, and without the thread ids it names.
@Suite("Codex errors without ids")
struct CodexErrorIdsTests {
    @Test func dropsTheThreadId() {
        let id = "01a16a16-2ab7-73b1-ae1a-402d276d7899"
        #expect(CodexError.readable("no rollout found for thread id \(id)") == "no rollout found")
        #expect(CodexError.readable("thread not found: \(id)") == "thread not found")
        #expect(CodexError.readable("thread \(id) is busy") == "thread is busy")
        #expect(CodexError.readable(#"{"error":{"message":"no rollout found for thread id \#(id)"}}"#) == "no rollout found")
        #expect(CodexAppServer.Failure.rpc(code: -32600, message: "no rollout found for thread id \(id)").errorDescription == "no rollout found")
        #expect(CodexError.readable("Rate limit reached") == "Rate limit reached")
    }
}

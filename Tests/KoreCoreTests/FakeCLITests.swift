import Foundation
import Testing

@testable import KoreCore

/// Sessions run end to end against `kore-fake-cli` playing recorded cassettes
/// (`Tests/Fixtures/cassettes`): no model, no network.
@Suite("the fake CLI plays recorded sessions", .serialized)
struct FakeCLITests {
    /// `kore-fake-cli`, built beside the test bundle (a test dependency).
    private static let fake: URL? = {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("kore-fake-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    private final class Marker {}

    private static let cassettes = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/cassettes")

    /// A scratch folder to run in, and `kore-fake-cli` standing in for `cli` with `cassette`.
    private func standIn(_ cli: String, _ cassette: String) throws -> URL {
        let fake = try #require(Self.fake, "kore-fake-cli isn't built beside the tests")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        CLIExecutable.standIns.value = [
            cli: .init(
                executable: fake,
                environment: [
                    "KORE_FAKE_AS": cli, "KORE_FAKE_CASSETTE": Self.cassettes.appendingPathComponent(cassette).path,
                    "KORE_FAKE_CLAIMS": work.appendingPathComponent(".claims").path,
                ])
        ]
        return work
    }

    private func done(_ work: URL) {
        CLIExecutable.standIns.value = [:]
        try? FileManager.default.removeItem(at: work)
    }

    @Test func playsACodexCommandTurn() async throws {
        let work = try standIn("codex", "codex-command-turn.jsonl")
        defer { done(work) }
        let session = try await CodexSession.start(.init(cwd: work, model: "gpt-6-luna", permissions: .fullAccess))
        try await session.send("Run the shell command: echo hi. Then reply: done.")
        var kinds: [String] = []
        for await event in session.events {
            switch event {
            case .turnStarted: kinds.append("turnStarted")
            case .itemCompleted(let item): kinds.append("\(item.type) \(item.text ?? "")")
            case .turnCompleted: kinds.append("turnCompleted")
            default: break
            }
            if case .turnCompleted = event { break }
        }
        await session.close()
        #expect(kinds == [
            "turnStarted", "userMessage ", "agentMessage I’ll run the requested command.", "commandExecution ", "agentMessage done.",
            "turnCompleted",
        ])
    }

    @Test func playsAClaudeToolTurn() async throws {
        let work = try standIn("claude", "claude-bash-turn.jsonl")
        defer { done(work) }
        // Kore's `initialize` request id is new each run: the reply only arrives if the player
        // put this run's id in place of the recorded one.
        let session = try await ClaudeSession.start(.init(cwd: work, model: "haiku"))
        try await session.send("Run the shell command echo hi with the Bash tool, then reply with just: done.")
        var kinds: [String] = []
        for await event in session.events {
            switch event {
            case .sessionStarted(let info): kinds.append("sessionStarted \(info.cwd == nil ? "" : "cwd")")
            case .assistant(_, let content, _, _):
                for block in content {
                    switch block {
                    case .text(let text): kinds.append("text \(text)")
                    case .toolUse(_, let name, _): kinds.append("tool \(name)")
                    default: break
                    }
                }
            case .user(let content, _, _):
                for case .toolResult(_, let output, let isError) in content { kinds.append("result \(output.string ?? "") \(isError)") }
            case .turnCompleted: kinds.append("turnCompleted")
            default: break
            }
            if case .turnCompleted = event { break }
        }
        await session.close()
        #expect(kinds == ["sessionStarted cwd", "tool Bash", "result hi false", "text done", "turnCompleted"])
    }

    @Test func endsWithAReasonWhenKoreSendsSomethingElse() async throws {
        let work = try standIn("codex", "codex-command-turn.jsonl")
        defer { done(work) }
        let session = try await CodexSession.start(.init(cwd: work, model: "gpt-6-luna", permissions: .fullAccess))
        try? await session.send("A prompt the cassette never saw")
        var stderr = ""
        var status: Int32?
        for await event in session.events {
            if case .stderr(let text) = event { stderr += text }
            if case .exited(let s) = event { status = s }
        }
        #expect(status == 2)
        #expect(stderr.contains("A prompt the cassette never saw") && stderr.contains("the cassette expects"))
    }
}

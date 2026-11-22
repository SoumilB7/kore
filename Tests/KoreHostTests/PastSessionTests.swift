import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A past session the box never kept (opened from History, or run in a terminal on the box):
/// it opens with its history, read without starting its CLI, and the CLI's own replay at its
/// first start sends nothing again.
@Suite("kore-host, past sessions read in", .serialized)
@MainActor
struct PastSessionTests {
    /// The page each CLI's reader gives (the readers themselves are tested below).
    nonisolated static func page(_ provider: String) -> [ChatEvent] {
        [
            .userMessage(text: "Where were we on \(provider)?", attachments: [], id: "u1"),
            .turnStarted("t0", origin: .user, at: .now),
            .text("b0", .answer, "On the Slack bot."),
            .turnFinished("t0", .completed, duration: .seconds(1)),
        ]
    }

    func rig(_ provider: String, _ backend: StreamStandIn) throws -> HostRig {
        let rig = try HostRig()
        try rig.host.start()
        rig.host.services.backend = { _, _ in backend }
        rig.sessions[provider] = [
            SessionSummary(id: "past1", agent: provider == "codex" ? .codex : .claude, title: "Slack", updated: .now)
        ]
        rig.host.pastPage = { provider, id, _ in id == "past1" ? PastPage(events: Self.page(provider.id), more: true) : nil }
        return rig
    }

    func entries(_ client: StreamClient, _ chatId: String, where match: ([LinkEntry]) -> Bool) async throws {
        try await until {
            client.frames.contains {
                guard case .txPage(let id, _, let entries, _, _)? = try? LinkMessage.decode($0), id == chatId else { return false }
                return match(entries)
            }
        }
    }

    @Test(arguments: ["claude", "codex"])
    func aPastSessionOpensWithItsHistoryAndNoCLI(provider: String) async throws {
        let backend = StreamStandIn()
        let rig = try rig(provider, backend)
        defer { rig.finish() }
        let window = HostDaemon.windowID(rig.folder.path)
        var later: LinkMessage.Result?
        let now = rig.host.apply(
            .control(.historyOpen, ControlArgs(windowId: window, provider: provider, sessionId: "past1")), id: "h", control: .act,
            reply: { later = $0 })
        if now == nil { try await until { later != nil } }
        let hc = try #require((now ?? later)?.chatId.flatMap(rig.host.chat))

        let act = try GrantStore(rig.paths.grants).allow("phone-ish", control: .act, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: act)
        client.socket.send(.txOpen(chatId: hc.id, last: 60))
        try await entries(client, hc.id) { $0.contains { $0.text == "On the Slack bot." } }
        // Read straight from the session: no CLI started, and the log and event stream hold it.
        #expect(!backend.calls.contains("start") && !hc.cliRunning)
        #expect(hc.entries.map(\.text).contains("Where were we on \(provider)?"))
        #expect(!hc.stream.isEmpty && !hc.neverLogged)

        // A send starts the CLI, whose replay of the same history is the wake: nothing twice.
        backend.replay = Self.page(provider)
        let before = hc.entries.count
        #expect(rig.host.apply(.send(chatId: hc.id, text: "go on"), id: "s", control: .act) { _ in }?.ok == true)
        try await until { hc.entries.contains { $0.text == "Hi: go on" } && hc.idle }
        #expect(backend.calls.contains("start"))
        #expect(hc.entries.filter { $0.text == "On the Slack bot." }.count == 1)
        #expect(hc.entries.count > before)
        rig.restart()
        #expect(try #require(rig.host.chat(hc.id)).entries.filter { $0.text == "On the Slack bot." }.count == 1, "the log keeps it once")
    }

    /// A chat opened before the box read history in (as on mybox): its first `tx.open` reads it.
    @Test func anEmptyChatOnItsSessionReadsInAtOpen() async throws {
        let backend = StreamStandIn()
        let rig = try rig("claude", backend)
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil, title: "Slack", session: "past1"))
        #expect(hc.entries.isEmpty && hc.neverLogged)
        let act = try GrantStore(rig.paths.grants).allow("phone-ish", control: .act, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: act)
        client.socket.send(.txOpen(chatId: hc.id, last: 60))
        try await entries(client, hc.id) { $0.contains { $0.text == "On the Slack bot." } }
        #expect(!backend.calls.contains("start"))

        // A chat with a log of its own, or a new one, is never read over.
        let fresh = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        #expect(!fresh.neverLogged)
        rig.host.readInPast(hc)
        #expect(!hc.neverLogged)
    }

    // MARK: The readers

    /// Claude's: the transcript's newest page as events, a long file read from its end.
    @Test func claudesReaderTakesTheNewestPageOfALongTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("past-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Past the size read from its end (`ClaudeTranscript.tailFrom`), with a compaction near
        // the end: only what's after it is read.
        func transcript(_ name: String, compactAt: Int?) throws -> URL {
            let file = dir.appendingPathComponent(name)
            var data = Data()
            let filler = String(repeating: "x", count: 2000)
            var parent = "null"
            for i in 0..<3000 {
                let user = "u\(i)", answer = "a\(i)"
                if i == compactAt {
                    data += Data((#"{"type":"system","subtype":"compact_boundary","uuid":"c\#(i)","parentUuid":null,"logicalParentUuid":\#(parent),"timestamp":"2026-11-20T10:00:00.000Z","content":"Conversation compacted"}"# + "\n").utf8)
                    parent = "\"c\(i)\""
                }
                data += Data((#"{"type":"user","uuid":"\#(user)","parentUuid":\#(parent),"timestamp":"2026-11-20T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"ask \#(i) \#(filler)"}]}}"# + "\n").utf8)
                data += Data((#"{"type":"assistant","uuid":"\#(answer)","parentUuid":"\#(user)","timestamp":"2026-11-20T10:00:01.000Z","message":{"id":"m\#(i)","type":"message","role":"assistant","content":[{"type":"text","text":"answer \#(i)"}],"stop_reason":"end_turn"}}"# + "\n").utf8)
                parent = "\"\(answer)\""
            }
            try data.write(to: file)
            #expect(ClaudeHistory.size(of: file) > ClaudeTranscript.tailFrom)
            return file
        }
        func answers(_ page: PastPage) -> [String] {
            page.events.compactMap { if case .text(_, .answer, let text, _) = $0 { text } else { nil } }
        }
        // No compaction: its newest turns only.
        let plain = try transcript("plain.jsonl", compactAt: nil)
        var began = ContinuousClock.now
        let newest = try #require(await PastPage.claude(ClaudeTranscript(file: plain), id: "s", folder: dir))
        let plainTook = ContinuousClock.now - began
        #expect(answers(newest) == (2990..<3000).map { "answer \($0)" })
        #expect(newest.more, "earlier history stays to be read")
        // A compaction near the end: read back to it, from the end of the file.
        let compacted = try transcript("compacted.jsonl", compactAt: 2980)
        began = ContinuousClock.now
        let tail = try #require(await PastPage.claude(ClaudeTranscript(file: compacted), id: "s", folder: dir))
        let tailTook = ContinuousClock.now - began
        #expect(answers(tail).last == "answer 2999" && !answers(tail).contains("answer 2979"))
        #expect(tail.more)
        #expect(plainTook < .seconds(2) && tailTook < .milliseconds(500), "12 MB: \(plainTook), from its end: \(tailTook)")
        print("past page read: 12 MB whole \(plainTook), from its end \(tailTook)")
    }

    /// Codex's: a page of turns as events.
    @Test func codexsReaderMakesEventsOfItsTurns() async throws {
        let turns: [JSONValue] = [
            [
                "id": "turn1", "status": "completed", "startedAt": 1_763_600_000,
                "items": [
                    ["type": "userMessage", "id": "i1", "content": [["type": "text", "text": "Where were we?"]]],
                    ["type": "agentMessage", "id": "i2", "text": "On the Slack bot."],
                ],
            ]
        ]
        let page = try #require(await PastPage.codex(turns, more: false, rollout: nil, folder: URL(fileURLWithPath: "/tmp")))
        #expect(page.events.contains { if case .userMessage(let text, _, _) = $0 { text == "Where were we?" } else { false } })
        #expect(page.events.contains { if case .text(_, .answer, let text, _) = $0 { text == "On the Slack bot." } else { false } })
        #expect(!page.more)
        let none = await PastPage.codex([], more: false, rollout: nil, folder: URL(fileURLWithPath: "/tmp"))
        #expect(none == nil)
    }
}

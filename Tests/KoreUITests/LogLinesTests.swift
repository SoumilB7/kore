import Foundation
import HostClient
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// The wide lines and what goes in them: one `turn` line per turn with its counts and tokens, its
/// id on the agents' lines while it runs, no model-written title, a link's end in a word; and the
/// Devices pane's sash, which grows the other way.
@MainActor
@Suite(.serialized)
struct LogLinesTests {
    private func scratch() -> (KoreLog, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-lines-\(UUID().uuidString).log")
        return (KoreLog(url: url, level: .debug), url)
    }

    private func bodies(_ log: KoreLog, _ url: URL) -> [String] {
        log.sync()
        defer { try? FileManager.default.removeItem(at: url) }
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
    }

    @Test func aTurnIsOneLineWithWhatItDid() {
        var tally = TurnTally(id: "a91f03", started: Date())
        tally.count(.toolStarted(ToolCall(id: "t1", name: "Bash", detail: "ls")))
        tally.count(.toolStarted(ToolCall(id: "t2", name: "Read", detail: "a.swift"), agent: .sub("toolu_1")))
        tally.count(.agentSpawned(AgentInfo(id: "toolu_1", parent: .main, toolId: "t3", name: "Scout", type: nil, model: nil, prompt: "secret prompt", background: false)))
        tally.count(.requestUsage(RequestUsage(id: "r1", at: Date(), model: nil, input: 10, output: 200, cacheRead: 3000)))
        tally.count(.requestUsage(RequestUsage(id: "r2", at: Date(), model: nil, input: 2, output: 280)))
        tally.count(.text("b", .answer, "the answer's words"))
        let (log, url) = scratch()
        SessionLog(log).turn(tally, "claude", chat: "4fb9", model: "haiku", outcome: "completed", ms: 9500)
        SessionLog(log).turn(TurnTally(id: "b00000"), "codex", chat: nil, model: nil, outcome: "failed", ms: 12)
        #expect(
            bodies(log, url) == [
                "info turn id=a91f03 chat=4fb9 cli=claude model=haiku outcome=completed dur_ms=9500 tools=2 agents=1 in_tok=12 out_tok=480 cache_tok=3000",
                "warn turn id=b00000 chat=- cli=codex outcome=failed dur_ms=12 tools=0 agents=0",
            ])
    }

    @Test func agentLinesCarryTheRunningTurnAndNoTitle() {
        let (log, url) = scratch()
        LogTurns.set("c0ffee", chat: "chat-lines")
        AgentLog(log).spawned("claude", chat: "chat-lines", agent: "toolu_9", name: "Read the owner's secret plan", background: true, parent: nil)
        LogTurns.set(nil, chat: "chat-lines")
        AgentLog(log).status("claude", chat: "chat-lines", agent: "toolu_9", to: "failed", source: .toolResultError)
        #expect(
            bodies(log, url) == [
                "info spawned cli=claude chat=chat-lines turn=c0ffee agent=toolu_9 mode=background parent=main",
                #"warn status cli=claude chat=chat-lines agent=toolu_9 from=running to=failed source="tool_result error""#,
            ])
        #expect(LogTurns.make().count == 6)
    }

    @Test func aLinksEndInAWord() {
        #expect(HostLog.ending(nil) == "closed")
        #expect(HostLog.ending("moving to KoreNet") == "switch")
        #expect(HostLog.ending("no answer to a check (wake)") == "no-answer")
        #expect(HostLog.ending("couldn't start: The file “ssh” couldn't be opened") == "start-failed")
        #expect(HostLog.ending("mybox took this Mac's newer link") == "replaced")
        #expect(HostLog.ending("mybox said version") == "version")
        #expect(HostLog.ending("Connection reset by peer at /home/me") == "connection-reset-by-peer-at-me")
        #expect(HostLog.ending("mybox said kore-host 0.31 is too old") == "kore-host-0.31-is-too-old")
        #expect(HostLog.word("stalled") == "stalled")
        // A detail of many words stays, as one token: never dropped.
        #expect(HostLog.word("the box's identity key changed") == "the-boxs-identity-key-changed")
        #expect(HostLog.word("box record missing · re-enrolling") == "box-record-missing-re-enrolling")
        #expect(HostLog.word("token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123") == "token-redacted")
        #expect(HostLog.word("refused: Bearer abc.def-123") == "refused:-redacted")
        #expect(HostLog.word(" · ") == nil)
    }

    // MARK: The sash

    /// The explorer's sash follows the pointer; Devices', on the other side, grows as it goes left.
    @Test func aTrailingPaneGrowsAsThePointerGoesLeft() {
        let leading: ClosedRange<CGFloat> = 180...480
        #expect(PaneSash.width(base: 260, moved: 40, edge: .leading, range: leading) == 300)
        #expect(PaneSash.width(base: 260, moved: -200, edge: .leading, range: leading) == 180)
        let range = Layout.Devices.minWidth...Layout.Devices.maxWidth
        #expect(PaneSash.width(base: 290, moved: -40, edge: .trailing, range: range) == 330)
        #expect(PaneSash.width(base: 290, moved: 30, edge: .trailing, range: range) == 260)
        #expect(PaneSash.width(base: 290, moved: -500, edge: .trailing, range: range) == 420)
        #expect(PaneSash.width(base: 290, moved: 500, edge: .trailing, range: range) == 240)
        #expect(Layout.Devices.width == 290)
    }
}

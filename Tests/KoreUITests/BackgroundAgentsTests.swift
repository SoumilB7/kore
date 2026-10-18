import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Background agents read back from a chat's transcript (`Fixtures/transcripts`, trimmed from a
/// real session another client ran): two spawned in the background, the turn ending before them,
/// and their notifications coming later, one taken mid-turn and one written to the transcript
/// only. A fork's copy of the history kept only the second call's result.
@MainActor
@Suite("Background agents")
struct BackgroundAgentsTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/transcripts/claude-background-agents.jsonl")

    private let lines: [JSONValue]
    /// Up to the turn's end: neither agent has finished.
    private var spawned: [JSONValue] { Array(lines.prefix(6)) }

    init() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        lines = try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
    }

    private func translator() -> ClaudeTranslator {
        ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: "s")
    }

    private func notification(_ index: Int) -> String {
        ClaudeHistory.notificationText(lines[index]) ?? ""
    }

    @Test func bothCallsAreAgentsAndNeitherHasEnded() {
        let translator = translator()
        let events = translator.replay(spawned)
        let agents = events.compactMap { if case .agentSpawned(let info) = $0 { info } else { nil } }
        #expect(agents.map(\.id) == ["toolu_bgA", "toolu_bgB"])
        #expect(agents.allSatisfy { $0.background })
        let open = translator.unfinishedAgents().sorted { $0.id < $1.id }
        #expect(open.map(\.id) == ["toolu_bgA", "toolu_bgB"])
        #expect(open.allSatisfy { $0.background })
    }

    /// The backend runs on the one whose files still grow; its notification ends it later.
    @Test func oneStillRunningIsFollowedToItsEnd() {
        let translator = translator()
        let script = Script()
        script.on(.replayed(translator.replay(spawned)))
        _ = script.sections
        #expect(script.store.agentSummary.stopped == 2)

        script.on(.agentResumed(id: "toolu_bgA"))
        _ = script.sections
        #expect(script.store.agentSummary.running.map(\.id) == ["toolu_bgA"])
        #expect(script.store.agentSummary.stopped == 1)

        translator.taskNotification(text: notification(6))
        translator.take().events.forEach(script.store.apply)
        _ = script.sections
        let agent = script.store.agent("toolu_bgA")
        #expect(agent?.status == .finished)
        #expect(agent?.result == "Uploads fail on a stale index.")
        #expect(agent?.tokens == 41200)
        #expect(script.store.agentSummary.running.isEmpty)
    }

    /// Read back whole, both end, each as its notification says, and neither shows as a message.
    @Test func theirNotificationsEndThemOnReadBack() {
        let translator = translator()
        let script = Script()
        script.on(.replayed(translator.replay(lines)))
        _ = script.sections
        #expect(script.store.agent("toolu_bgA")?.status == .finished)
        #expect(script.store.agent("toolu_bgB")?.status == .failed)
        #expect(translator.unfinishedAgents().isEmpty)
        #expect(!script.lines.contains { $0.contains("task-notification") })
    }

    /// Its meta file can say it finished before the notification comes: that ends it once, and
    /// the notification still brings the status and result.
    @Test func endedByItsFilesThenByItsNotification() {
        let translator = translator()
        _ = translator.replay(spawned)
        translator.agentEnded("toolu_bgB", .completed)
        translator.agentEnded("toolu_bgB", .completed)
        translator.taskNotification(text: notification(7))
        let ends = translator.take().events.compactMap { event -> String? in
            if case .agentFinished(let id, let status, let result) = event { "\(id) \(status) \(result ?? "-")" } else { nil }
        }
        #expect(ends == ["toolu_bgB completed -", "toolu_bgB failed The publish step timed out."])
    }

    /// Its card's avatar, the Agents button's stack and the map's row all know it runs in the
    /// background (their rings are dashed).
    @Test func aBackgroundAgentCarriesTheCue() {
        let script = Script()
        script.on(.replayed(translator().replay(lines)))
        for item in script.items { if case .fold(let fold) = item.row, !fold.open { script.store.toggle(turn: fold.turn) } }
        let cards = script.items.compactMap { item -> Bool? in
            if case .agent(_, _, _, _, let background)? = item.dot { background } else { nil }
        }
        #expect(cards == [true, true])
        #expect(script.store.agentSummary.first.allSatisfy { $0.background })
    }

    /// The map lists the chat's background agents still running apart, below the tree, each
    /// with its own agents; those that finished (done or failed) wait in a group of their own
    /// with theirs, a stopped one with the stopped, and one another agent runs in the background
    /// stays under it.
    @Test func theMapListsBackgroundAgentsApart() {
        let script = Script()
        script.send("Go")
        script.start("t1")
        script.on(
            spawn("done", background: true), spawn("note", under: .sub("done")), spawn("writer"),
            spawn("helper", under: .sub("writer"), background: true), spawn("scout", background: true),
            spawn("reader", under: .sub("scout")), spawn("gone", background: true), spawn("broke", background: true),
            spawn("left", under: .sub("broke")),
            .agentFinished(id: "note", .completed, result: "Noted"), .agentFinished(id: "done", .completed, result: "Done"),
            .agentFinished(id: "writer", .completed, result: "Written"), .agentFinished(id: "broke", .failed, result: nil),
            .agentFinished(id: "gone", .stopped, result: nil))
        _ = script.sections
        let map = script.store.agentTree()
        #expect(names(map.tree) == ["writer", ".helper", "left"])
        #expect(names(map.background) == ["scout", ".reader"])
        #expect(names(map.done) == ["done", ".note", "broke"])
        #expect(names(map.stopped) == ["gone"])
        // Counted as the agents that did work, as before.
        #expect(script.store.agentSummary.count == 8)
        #expect(script.store.agentSummary.stopped == 1)

        // Run again, it's back in the Background section with its own.
        script.on(.agentResumed(id: "done"))
        _ = script.sections
        let resumed = script.store.agentTree()
        #expect(names(resumed.background) == ["done", ".note", "scout", ".reader"])
        #expect(names(resumed.done) == ["broke"])
    }

    private func spawn(_ id: String, under parent: AgentID = .main, background: Bool = false) -> ChatEvent {
        .agentSpawned(AgentInfo(
            id: id, parent: parent, toolId: nil, name: id, type: nil, model: nil, prompt: nil, background: background))
    }

    private func names(_ nodes: [TranscriptStore.AgentNode]) -> [String] {
        nodes.map { String(repeating: ".", count: $0.depth) + $0.id }
    }

    /// One its own files say ended, with no notification in the transcript (a fork's copy of
    /// the call, its notification in the session it came from): it ends with the time its
    /// transcript spans, not the moment the chat was read back.
    @Test func oneEndedByItsFilesKeepsItsTime() {
        let translator = translator()
        let script = Script()
        script.on(.replayed(translator.replay(spawned)))
        translator.agentEnded("toolu_bgA", .completed, duration: .seconds(4175))
        translator.agentEnded("toolu_bgB", .completed)
        translator.take().events.forEach(script.store.apply)
        _ = script.sections
        #expect(script.store.agent("toolu_bgA")?.duration == 4175)
        #expect(script.store.agent("toolu_bgA")?.tokens == nil)
        #expect(names(script.store.agentTree().done) == ["toolu_bgA", "toolu_bgB"])
    }

    /// Its tokens, read from its transcript's last model call, are marked approximate; a
    /// notification's own count, read later, is exact.
    @Test func oneEndedByItsFilesHasApproximateTokens() {
        let translator = translator()
        let script = Script()
        script.on(.replayed(translator.replay(spawned)))
        translator.agentEnded("toolu_bgA", .completed, duration: .seconds(7660), tokens: 239_412)
        translator.take().events.forEach(script.store.apply)
        _ = script.sections
        let agent = script.store.agent("toolu_bgA")
        #expect(agent?.tokens == 239_412)
        #expect(agent?.approximate == true)
        #expect(agent.flatMap(AgentMeter.tokens(of:)) == "~239.4k")
        script.on(.agentProgress(id: "toolu_bgA", AgentProgress(tokens: 241_000)))
        #expect(script.store.agent("toolu_bgA")?.approximate == false)
        #expect(script.store.agent("toolu_bgA").flatMap(AgentMeter.tokens(of:)) == "241k")
    }

    // MARK: Codex

    private func activity(_ kind: String, _ id: String, thread: String = "child") -> CodexItem {
        CodexItem(.object([
            "id": .string(id), "type": .string("subAgentActivity"), "kind": .string(kind),
            "agentThreadId": .string(thread), "agentPath": .string("/root/\(thread)"),
        ]))
    }

    private func turnParams(_ id: String, _ status: String = "completed") -> JSONValue {
        .object(["turn": .object(["id": .string(id), "status": .string(status)])])
    }

    private func turnCompleted(_ id: String, _ status: String = "completed") -> CodexEvent {
        CodexEvent(notification: "turn/completed", params: turnParams(id, status))
    }

    /// A Codex child thread that finished within its parent's turn (its end an item of that
    /// turn) is no background agent: it keeps its place in the tree with its totals.
    @Test func aCodexChildThatFinishedInItsTurnStaysInTheTree() {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        let script = Script()
        script.send("Go")
        translator.translate(CodexEvent(notification: "turn/started", params: .object(["turn": .object(["id": .string("t1")])])))
        translator.translate(.itemCompleted(activity("started", "call_1")))
        var info = CodexAgentThread(nickname: "Scout")
        info.tokens = 900
        info.duration = .seconds(75)
        translator.agentThreads["child"] = info
        translator.translate(.itemCompleted(activity("completed", "subagent-completed-1")))
        translator.translate(turnCompleted("t1"))
        let events = translator.take().events
        #expect(!events.contains { if case .agentBackgrounded = $0 { true } else { false } })
        events.forEach(script.store.apply)
        _ = script.sections
        let map = script.store.agentTree()
        #expect(names(map.tree) == ["child"])
        #expect(map.done.isEmpty && map.background.isEmpty)
        #expect(script.store.agent("child")?.background == false)
        #expect(script.store.agent("child")?.tokens == 900)
    }

    /// One still running when its parent's turn ends runs on in the background, as a Claude agent
    /// run in the background does: the Background section while it runs, ended by its own turn,
    /// then the done group.
    @Test func aCodexChildRunningAtItsTurnsEndRunsInTheBackground() {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        let script = Script()
        func on(_ event: CodexEvent) {
            translator.translate(event)
            translator.take().events.forEach(script.store.apply)
        }
        script.send("Go")
        on(CodexEvent(notification: "turn/started", params: .object(["turn": .object(["id": .string("t1")])])))
        on(.itemCompleted(activity("started", "call_1")))
        on(.itemCompleted(activity("started", "call_2", thread: "quick")))
        on(.itemCompleted(activity("completed", "subagent-completed-2", thread: "quick")))
        on(turnCompleted("t1"))
        _ = script.sections
        var map = script.store.agentTree()
        #expect(names(map.tree) == ["quick"])
        #expect(names(map.background) == ["child"])
        #expect(script.store.agent("child")?.background == true)
        #expect(script.store.agent("child")?.status == .running)

        let said: JSONValue = .object([
            "item": .object(["id": .string("m1"), "type": .string("agentMessage"), "text": .string("Found it.")]),
        ])
        on(.subThread(threadId: "child", method: "item/completed", params: said))
        on(.subThread(threadId: "child", method: "turn/completed", params: turnParams("c1")))
        _ = script.sections
        map = script.store.agentTree()
        #expect(map.background.isEmpty)
        #expect(names(map.done) == ["child"])
        #expect(script.store.agent("child")?.status == .finished)
        #expect(script.store.agent("child")?.result == "Found it.")
    }

    /// Read back, the same: a child whose end the turn's items hold stays in the tree; one whose
    /// end comes in a later turn ran on in the background. A turn stopped, or still running in
    /// another client, leaves its children as they are.
    @Test func aCodexReadBackMarksTheSameChildrenBackground() {
        func turn(_ id: String, _ status: String, _ items: [CodexItem]) -> JSONValue {
            .object(["id": .string(id), "status": .string(status), "items": .array(items.map(\.raw))])
        }
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        let events = translator.replay([
            turn("t1", "completed", [
                activity("started", "call_1", thread: "quick"), activity("started", "call_2", thread: "long"),
                activity("completed", "subagent-completed-1", thread: "quick"),
            ]),
            turn("t2", "completed", [activity("completed", "subagent-completed-2", thread: "long")]),
            turn("t3", "interrupted", [activity("started", "call_3", thread: "cut")]),
            turn("t4", "inProgress", [activity("started", "call_4", thread: "live")]),
        ])
        let backgrounded = events.compactMap { if case .agentBackgrounded(let id) = $0 { id } else { nil } }
        #expect(backgrounded == ["long"])
        let script = Script()
        script.on(.replayed(events))
        _ = script.sections
        let map = script.store.agentTree()
        #expect(names(map.done) == ["long"])
        #expect(map.tree.map(\.id).contains("quick"))
    }

    /// A child thread another client runs outlives its parent's turn: its rollout says it still
    /// runs until its turn's end is written there, with its last answer.
    @Test func aCodexChildIsReadFromItsRollout() throws {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        let item = CodexItem(.object([
            "id": .string("call_1"), "type": .string("subAgentActivity"), "kind": .string("started"),
            "agentThreadId": .string("child"), "agentPath": .string("/root/scout"),
        ]))
        translator.translate(.itemStarted(item))
        translator.translate(.itemCompleted(item))
        _ = translator.take()
        #expect(translator.unfinishedAgents() == ["child"])

        let rollout = FileManager.default.temporaryDirectory.appendingPathComponent("kore-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rollout) }
        func write(_ events: [String]) throws {
            let lines = events.map { #"{"timestamp":"2026-10-23T06:30:00Z","type":"event_msg","payload":"# + $0 + "}" }
            try (lines.joined(separator: "\n") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        }
        let started = #"{"type":"task_started","turn_id":"t1"}"#
        try write([started, #"{"type":"token_count","info":{"total_token_usage":{"total_tokens":900}}}"#])
        var info = CodexAgentThread(nickname: "Scout")
        info.readOutcome(rollout: rollout.path)
        #expect(info.outcome() == .running)
        #expect(info.outcome(at: Date().addingTimeInterval(AgentOutcome.quietLimit + 60)) == .stopped)

        try write([started, #"{"type":"task_complete","turn_id":"t1","last_agent_message":"Found it."}"#])
        info = CodexAgentThread(nickname: "Scout")
        info.readOutcome(rollout: rollout.path)
        #expect(info.outcome() == .finished)
        translator.agentEnded("child", .completed, info)
        let ends = translator.take().events.compactMap { event -> String? in
            if case .agentFinished(let id, let status, let result) = event { "\(id) \(status) \(result ?? "-")" } else { nil }
        }
        #expect(ends == ["child completed Found it."])
        #expect(translator.unfinishedAgents().isEmpty)

        try write([started, #"{"type":"turn_aborted","turn_id":"t1"}"#])
        info.readOutcome(rollout: rollout.path)
        #expect(info.outcome() == .stopped)
    }
}

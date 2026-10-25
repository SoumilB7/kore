import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Stopped agents wait in the agent map's Stopped group, and come back to the running rows when
/// they run again; each CLI's way of running one again reaches the transcript as `agentResumed`.
/// Every ended agent's meter says how it ended.
@MainActor
@Suite("Stopped agents")
struct StoppedAgentsTests {
    private func spawn(_ id: String, under parent: AgentID = .main) -> ChatEvent {
        .agentSpawned(AgentInfo(id: id, parent: parent, toolId: nil, name: id, type: nil, model: nil, prompt: nil, background: false))
    }

    private func names(_ nodes: [TranscriptStore.AgentNode]) -> [String] {
        nodes.map { String(repeating: ".", count: $0.depth) + $0.id }
    }

    /// scout (with reader under it) and writer; the turn is stopped while scout and reader run.
    private func stoppedTurn() -> Script {
        let script = Script()
        script.send("Use some helpers")
        script.start("t1")
        script.on(
            spawn("scout"), spawn("reader", under: .sub("scout")), spawn("writer"),
            .agentFinished(id: "writer", .completed, result: "Written"))
        script.finish("t1", .interrupted)
        _ = script.sections
        return script
    }

    @Test func aStoppedAgentFoldsIntoStoppedWithItsOwn() {
        let store = stoppedTurn().store
        let map = store.agentTree()
        #expect(map.running.isEmpty)
        #expect(names(map.done) == ["writer"])
        #expect(names(map.stopped) == ["scout", ".reader"])
        #expect(store.agentSummary.count == 1)
        #expect(store.agentSummary.stopped == 2)
        #expect(store.agentSummary.first.map(\.id) == ["writer"])
        // Stopped live, each has the time it ran.
        #expect(store.agent("scout")?.duration != nil)
        #expect(store.agent("reader")?.duration != nil)
    }

    @Test func aResumedAgentGoesBackToTheRunningRows() {
        let script = stoppedTurn()
        script.on(.agentResumed(id: "scout"))
        _ = script.sections
        let map = script.store.agentTree()
        // Its stopped reader stays in the group.
        #expect(names(map.running) == ["scout"])
        #expect(map.running.map(\.isLast) == [true])
        #expect(script.store.agent("scout")?.status == .running)
        #expect(names(map.stopped) == ["reader"])
        #expect(script.store.agentSummary.count == 2)
        #expect(script.store.agentSummary.running.map(\.id) == ["scout"])

        script.on(.agentFinished(id: "scout", .completed, result: "Scouted"))
        _ = script.sections
        // Newest first: writer spawned after scout.
        #expect(names(script.store.agentTree().done) == ["writer", "scout"])
        #expect(script.store.agentTree().running.isEmpty)
        #expect(script.store.agent("scout")?.duration != nil)
    }

    /// A running agent under a stopped one hangs off the chat.
    @Test func aLiveChildOfAStoppedAgentRunsUnderTheChat() {
        let script = stoppedTurn()
        script.on(.agentResumed(id: "reader"))
        _ = script.sections
        let map = script.store.agentTree()
        #expect(names(map.running) == ["reader"])
        #expect(names(map.stopped) == ["scout"])
    }

    @Test func onlyStoppedAgentsStillShowTheButton() {
        let script = Script()
        script.send("Go")
        script.start("t1")
        script.on(spawn("scout"))
        script.finish("t1", .interrupted)
        _ = script.sections
        let summary = script.store.agentSummary
        #expect(summary.count == 0)
        #expect(summary.stopped == 1)
        #expect(summary.first.map(\.id) == ["scout"])
    }

    // MARK: Meters

    private func info(
        _ status: TranscriptStore.AgentInfo.Status, duration: TimeInterval? = nil, tokens: Int? = nil
    ) -> TranscriptStore.AgentInfo {
        var info = TranscriptStore.AgentInfo(id: "a", index: 0, name: "Audit tests", startedAt: Date())
        info.status = status
        info.duration = duration
        info.tokens = tokens
        return info
    }

    private func meter(_ info: TranscriptStore.AgentInfo, waiting: Bool = false, hidden: Int = 0, background: Bool = false) -> String {
        AgentNodeMeter.text(info, duration: info.duration, waiting: waiting, hidden: hidden, background: background)
    }

    /// Every ended agent's meter starts with how it ended; a running background one says so.
    @Test func theMeterSaysHowAnAgentEnded() {
        #expect(meter(info(.running, duration: 72, tokens: 18_400)) == "1:12 · 18k")
        #expect(meter(info(.running, duration: 495, tokens: 64_000), waiting: true, background: true) == "background · waiting · 8:15 · 64k")
        #expect(meter(info(.running, duration: 134, tokens: 31_000), background: true) == "background · 2:14 · 31k")
        #expect(meter(info(.finished, duration: 164, tokens: 15_400)) == "done · 2:44 · 15k")
        #expect(meter(info(.finished, duration: 242, tokens: 40_200), background: true) == "background · done · 4:02 · 40k")
        #expect(meter(info(.failed, duration: 27, tokens: 9_000)) == "failed · 0:27")
        #expect(meter(info(.stopped, duration: 15, tokens: 3_200)) == "stopped · 0:15 · 3.2k")
        #expect(meter(info(.stopped, duration: 15, tokens: 3_200), background: true) == "background · stopped · 0:15 · 3.2k")
        #expect(meter(info(.running, duration: 72, tokens: 18_400), hidden: 3) == "1:12 · 18k · +3 folded")
    }

    /// Read back, a stopped turn's agent has no true end: no time, no tokens, and its meter
    /// says just "stopped", never nothing.
    @Test func aStoppedAgentWithNoDataReadsStopped() {
        let script = Script()
        script.on(.replayed([
            .turnStarted("t1", origin: .user, at: Date()), spawn("scout"), .turnFinished("t1", .interrupted, duration: nil),
        ]))
        _ = script.sections
        let scout = script.store.agent("scout")
        #expect(scout?.status == .stopped)
        #expect(scout?.duration == nil)
        #expect(scout.map { meter($0) } == "stopped")
        #expect(scout.map { meter($0, background: true) } == "background · stopped")
    }

    // MARK: Keys and selection

    /// ↑ ↓ meet the running rows, the Done row and its agents while it's open, then the Stopped
    /// row; an agent selected inside a closed group stays selected, the group's row highlighted.
    @Test func theKeysMeetTheRowsInOrder() {
        let script = stoppedTurn()
        script.on(.agentResumed(id: "reader"))
        _ = script.sections
        let trees = script.store.agentTree()
        let closed = AgentMapRows(trees, folded: [], open: [])
        #expect(closed.stops == [.agent("reader"), .fold(.done), .fold(.stopped)])
        let open = AgentMapRows(trees, folded: [], open: [.done, .stopped])
        #expect(open.stops == [.agent("reader"), .fold(.done), .agent("writer"), .fold(.stopped), .agent("scout")])
        // Selected, then its group closed: the group's row has the highlight, the agent stays.
        #expect(closed.selection("scout")?.id == "scout")
        #expect(closed.highlight(selected: "scout", cursor: nil) == .fold(.stopped))
        #expect(open.highlight(selected: "scout", cursor: nil) == .agent("scout"))
        // A group's row reached by keys holds the highlight.
        #expect(open.highlight(selected: "reader", cursor: .done) == .fold(.done))
        // Nothing picked: the first row shown.
        #expect(closed.selection(nil)?.id == "reader")
        #expect(closed.fold(of: "writer") == .done)

        // Nothing shown at all: the newest agent, its group's row highlighted.
        let ended = AgentMapRows(stoppedTurn().store.agentTree(), folded: [], open: [])
        #expect(ended.stops == [.fold(.done), .fold(.stopped)])
        #expect(ended.selection(nil)?.id == "writer")
        #expect(ended.highlight(selected: "writer", cursor: nil) == .fold(.done))
    }

    // MARK: Claude

    private func line(_ json: String) -> ClaudeEvent {
        ClaudeEvent(message: (try? JSONValue.parse(Data(json.utf8))) ?? .null)
    }

    /// Claude runs an agent again with SendMessage: "Resuming agent …", then the agent's task
    /// starts again under its own id from the SendMessage call, and reports under that call.
    @Test func claudeSendMessageResumesTheAgent() {
        let translator = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: nil)
        let lines = [
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"description":"Scout","prompt":"Look"}}]}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"toolu_A","description":"Scout","task_type":"local_agent"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_A","status":"killed"}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"toolu_S","name":"SendMessage","input":{"to":"a1","message":"Go on"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_S","content":"Resuming agent a1"}]},"tool_use_result":{"success":true,"message":"Resuming agent a1","resumedAgentId":"a1"}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"toolu_S","description":"Scout","task_type":"local_agent"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_S","status":"completed"}"#,
        ]
        var events: [ChatEvent] = []
        for json in lines {
            translator.translate(line(json))
            events += translator.take().events
        }
        let agents = events.compactMap { event -> String? in
            switch event {
            case .agentSpawned(let info): "spawned \(info.id)"
            case .agentFinished(let id, let status, _): "finished \(id) \(status)"
            case .agentResumed(let id): "resumed \(id)"
            default: nil
            }
        }
        // The Resuming answer and the task's start both say it; the transcript takes it once.
        #expect(agents == [
            "spawned toolu_A", "finished toolu_A stopped", "resumed toolu_A", "resumed toolu_A", "finished toolu_A completed",
        ])
    }

    /// The same read back from a transcript: the run's report names the SendMessage call.
    @Test func claudeReadBackFinishesTheResumedRun() {
        let translator = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: nil)
        let messages = [
            #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"content":"Use a helper"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:01.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"description":"Scout","prompt":"Look","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"Launched"}]},"toolUseResult":{"status":"async_launched","agentId":"a1"}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:01:00.000Z","message":{"content":"Go on with it"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:01:01.000Z","message":{"id":"m2","content":[{"type":"tool_use","id":"toolu_S","name":"SendMessage","input":{"to":"a1","message":"Go on"}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:01:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_S","content":"ok"}]},"toolUseResult":{"success":true,"message":"Agent \"a1\" had no active task; resumed from transcript in the background with your message."}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:02:00.000Z","turnOrigin":"task_notification","message":{"content":"<task-notification><task-id>a1</task-id><tool-use-id>toolu_S</tool-use-id><status>completed</status><result>Done</result></task-notification>"}}"#,
        ].compactMap { try? JSONValue.parse(Data($0.utf8)) }
        let events = translator.replay(messages)
        let store = TranscriptStore()
        store.apply(.replayed(events))
        #expect(store.agent("toolu_A")?.status == .finished)
        #expect(store.agent("toolu_A")?.result == "Done")
        #expect(store.agentTree().stopped.isEmpty)
        #expect(store.agentTree().done.map(\.id) == ["toolu_A"])
    }

    // MARK: Codex

    /// Codex runs a child again with followup_task: the child thread starts another turn.
    @Test func codexFollowUpResumesTheChild() {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        func item(_ kind: String, _ id: String) -> CodexEvent {
            .itemCompleted(CodexItem(.object([
                "id": .string(id), "type": .string("subAgentActivity"), "kind": .string(kind),
                "agentThreadId": .string("child"), "agentPath": .string("/root/scout"),
            ])))
        }
        let turn = CodexEvent(notification: "turn/started", params: .object(["turn": .object(["id": .string("c1")])]))
        var events: [ChatEvent] = []
        func on(_ event: CodexEvent, agent: AgentID = .main) {
            translator.translate(event, agent: agent)
            events += translator.take().events
        }
        on(item("started", "call_1"))
        on(turn, agent: .sub("child"))
        on(item("interrupted", "call_2"))
        on(CodexEvent(notification: "turn/started", params: .object(["turn": .object(["id": .string("c2")])])), agent: .sub("child"))
        on(item("completed", "subagent-completed-c2"))
        let agents = events.compactMap { event -> String? in
            switch event {
            case .agentSpawned(let info): "spawned \(info.id)"
            case .agentFinished(let id, let status, _): "finished \(id) \(status)"
            case .agentResumed(let id): "resumed \(id)"
            default: nil
            }
        }
        #expect(agents == ["spawned child", "finished child stopped", "resumed child", "finished child completed"])
    }

    /// Read back, a rollout has no child turns: a later run's end is a report of its own.
    @Test func codexReadBackTakesALaterRunsEnd() {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        var events: [ChatEvent] = []
        for (kind, id) in [("started", "call_1"), ("interrupted", "call_2"), ("interacted", "call_3"), ("completed", "subagent-completed-c2")] {
            let item = CodexItem(.object([
                "id": .string(id), "type": .string("subAgentActivity"), "kind": .string(kind),
                "agentThreadId": .string("child"), "agentPath": .string("/root/scout"),
            ]))
            translator.translate(.itemStarted(item))
            translator.translate(.itemCompleted(item))
            events += translator.take().events
        }
        let finished = events.compactMap { if case .agentFinished(_, let status, _) = $0 { status } else { nil } }
        #expect(finished == [.stopped, .completed])
    }
}

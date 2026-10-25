import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Background shells, long foreground commands, monitors and scheduled jobs: each CLI's events
/// as `ChatEvent`s (shapes from the 2026-10-25 probes), and the store the map and panes read.
@MainActor
@Suite("Active commands")
struct ActiveCommandsTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-tests-commands")

    // MARK: - Store

    @Test func theMarkCountsLiveRowsOnTheirNearestOwnerOnly() {
        let store = CommandsStore()
        store.apply(.agentSpawned(Self.agent("A", parent: .main)))
        store.apply(.agentSpawned(Self.agent("B", parent: .sub("A"))))
        store.apply(.commandStarted(Self.shell("c1", owner: .main)))
        store.apply(.commandStarted(Self.shell("c2", owner: .sub("B"))))
        store.apply(.commandStarted(Self.shell("c3", owner: .sub("B"))))
        store.apply(.commandEnded(id: "c3", .completed, at: .now))
        #expect(store.summary.live(.main) == 1)
        #expect(store.summary.live(.sub("B")) == 1)
        #expect(store.summary.live(.sub("A")) == 0)
        #expect(store.summary.total == 2)
        #expect(store.summary.outlived == 0)
    }

    @Test func aCommandOutlivesItsAgentUntilTheAgentRunsAgain() {
        let store = CommandsStore()
        store.apply(.commandStarted(Self.shell("c1", owner: .sub("A"))))
        store.apply(.agentFinished(id: "A", .completed, result: nil))
        #expect(store.summary.outlived == 1)
        #expect(store.outlived.map(\.id) == ["c1"])
        store.apply(.agentResumed(id: "A"))
        #expect(store.summary.outlived == 0)
        store.apply(.agentFinished(id: "A", .stopped, result: nil))
        store.apply(.commandEnded(id: "c1", .stopped(by: .user), at: .now))
        #expect(store.summary == CommandsStore.Summary())
    }

    /// A failed agent stays in sight under the chat, but it has ended: what it left running
    /// counts on its own row and on the foot line alike.
    @Test func aFailedAgentsCommandCountsAsOutlived() {
        let store = CommandsStore()
        store.apply(.commandStarted(Self.shell("c1", owner: .sub("A"))))
        store.apply(.agentFinished(id: "A", .failed, result: nil))
        #expect(store.summary.outlived == 1)
        #expect(store.summary.live(.sub("A")) == 1)
    }

    @Test func livePaneRowsComeNewestFirstThenFinishedByMostRecentEnd() {
        let store = CommandsStore()
        let start = Date(timeIntervalSince1970: 1_000)
        for (i, id) in ["a", "b", "c", "d"].enumerated() {
            store.apply(.commandStarted(Self.shell(id, owner: .main, at: start.addingTimeInterval(Double(i)))))
        }
        store.apply(.commandEnded(id: "a", .completed, at: start.addingTimeInterval(20)))
        store.apply(.commandEnded(id: "b", .failed(exit: 1), at: start.addingTimeInterval(10)))
        let rows = store.rows(of: .main)
        #expect(rows.live.map(\.id) == ["d", "c"])
        #expect(rows.finished.map(\.id) == ["a", "b"])
        #expect(rows.finished.first?.duration == 20)
    }

    @Test func aLaterEndOnlySaysMore() {
        let store = CommandsStore()
        store.apply(.commandStarted(Self.shell("c", owner: .main)))
        store.apply(.commandEnded(id: "c", .failed(exit: nil), at: .now))
        store.apply(.commandEnded(id: "c", .failed(exit: 2), at: .now))
        #expect(store.command("c")?.state == .failed(exit: 2))
        store.apply(.commandEnded(id: "c", .ended, at: .now))
        #expect(store.command("c")?.state == .failed(exit: 2))
    }

    @Test func streamedOutputIsBounded() {
        let buffer = OutputBuffer(limit: 100)
        for i in 0..<500 { buffer.append("line \(i)\n") }
        #expect(buffer.lines(2) == ["line 498", "line 499"])
        #expect(buffer.lines(1000).count < 40)
    }

    // MARK: - Claude

    @Test func aClaudeBackgroundShellStartsAndIsStoppedByKore() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("call-1", "Bash", #"{"command":"npm run dev","description":"Run the dev server","run_in_background":true}"#),
                #"{"type":"system","subtype":"task_started","task_id":"b1","tool_use_id":"call-1","description":"Run the dev server","is_backgrounded":true,"task_type":"local_bash"}"#,
                Self.claudeResult("call-1", "Command running in background with ID: b1. Output is being written to: /tmp/claude-0/k/s1/tasks/b1.output. You will be notified.", #"{"backgroundTaskId":"b1"}"#),
            ])
        let started = try #require(events.lazy.compactMap(Self.started).first)
        #expect(started.kind == .shell)
        #expect(started.title == "Run the dev server")
        #expect(started.command == "npm run dev")
        #expect(started.owner == .main)
        #expect(started.toolId == "call-1")
        #expect(events.contains { if case .commandChanged("b1", .outputFile("/tmp/claude-0/k/s1/tasks/b1.output")) = $0 { true } else { false } })
        t.stopRequested("b1")
        let stopped = try Self.claude(
            t,
            [
                #"{"type":"system","subtype":"task_updated","task_id":"b1","patch":{"status":"killed","end_time":1792874572528}}"#,
                #"{"type":"system","subtype":"task_notification","task_id":"b1","tool_use_id":"call-1","status":"stopped","output_file":"/tmp/claude-0/k/s1/tasks/b1.output","summary":"Run the dev server"}"#,
            ])
        #expect(Self.ends(stopped) == [.stopped(by: .user)])
    }

    @Test func aClaudeSubAgentsShellIsTheAgentsNotItsParents() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("agent-call", "Agent", #"{"description":"Check the build","prompt":"Go","subagent_type":"general-purpose"}"#),
                #"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"agent-call","description":"Check the build","task_type":"local_agent"}"#,
                Self.claudeCall("call-2", "Bash", #"{"command":"sleep 301","run_in_background":true}"#, parent: "agent-call"),
                #"{"type":"system","subtype":"task_started","task_id":"b2","tool_use_id":"call-2","description":"Sleep","is_backgrounded":true,"owned_by_subagent":true,"parent_task_id":"a1","task_type":"local_bash"}"#,
            ])
        #expect(events.compactMap(Self.started).map(\.owner) == [.sub("agent-call")])
    }

    @Test func aLongForegroundCommandMovesToTheBackgroundAsTheSameRow() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("call-3", "Bash", #"{"command":"python stress.py","description":"Run the stress suite"}"#),
                #"{"type":"system","subtype":"task_started","task_id":"b3","tool_use_id":"call-3","description":"Run the stress suite","is_backgrounded":false,"task_type":"local_bash"}"#,
            ])
        #expect(events.compactMap(Self.started).map(\.kind) == [.foreground])
        #expect(t.commands.toolId(of: "b3") == "call-3")
        let moved = try Self.claude(
            t,
            [
                #"{"type":"system","subtype":"task_updated","task_id":"b3","patch":{"is_backgrounded":true}}"#,
                Self.claudeResult("call-3", "Command was manually backgrounded by user with ID: b3.", #"{"backgroundTaskId":"b3","backgroundedByUser":true}"#),
                #"{"type":"system","subtype":"task_notification","task_id":"b3","tool_use_id":"call-3","status":"failed","output_file":"/tmp/o","summary":"Background command \"Run the stress suite\" failed with exit code 1"}"#,
            ])
        #expect(moved.filter { if case .commandChanged(_, .backgrounded) = $0 { true } else { false } }.count == 1)
        #expect(Self.ends(moved) == [.failed(exit: 1)])
    }

    /// Its own timeout sends a command to the background (it isn't killed): a shell from its start.
    @Test func aClaudeBashTimeoutIsABackgroundShell() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("call-4", "Bash", #"{"command":"ping -c 43 127.0.0.1","timeout":3000}"#),
                #"{"type":"system","subtype":"task_started","task_id":"b4","tool_use_id":"call-4","description":"Ping","is_backgrounded":true,"task_type":"local_bash"}"#,
                Self.claudeResult("call-4", "Command did not complete within its 3s timeout and was moved to the background (ID: b4).", #"{"backgroundTaskId":"b4","timedOutAfterMs":3000}"#),
            ])
        #expect(events.compactMap(Self.started).map(\.kind) == [.shell])
        #expect(Self.ends(events).isEmpty)
    }

    @Test func theAgentsOwnTaskStopIsAStopByTheAgent() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("call-5", "Bash", #"{"command":"sleep 344","run_in_background":true}"#),
                #"{"type":"system","subtype":"task_started","task_id":"b5","tool_use_id":"call-5","description":"Sleep","is_backgrounded":true,"task_type":"local_bash"}"#,
                Self.claudeCall("call-6", "TaskStop", #"{"task_id":"b5"}"#),
                #"{"type":"system","subtype":"task_updated","task_id":"b5","patch":{"status":"killed"}}"#,
            ])
        #expect(Self.ends(events) == [.stopped(by: .agent)])
    }

    @Test func anInterruptEndsTheForegroundCommandItWaitedOn() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        _ = try Self.claude(
            t,
            [
                Self.claudeCall("call-7", "Bash", #"{"command":"make all"}"#),
                #"{"type":"system","subtype":"task_started","task_id":"b7","tool_use_id":"call-7","description":"Build","is_backgrounded":false,"task_type":"local_bash"}"#,
            ])
        t.interruptRequested()
        let events = try Self.claude(t, [#"{"type":"system","subtype":"task_updated","task_id":"b7","patch":{"status":"killed"}}"#])
        #expect(Self.ends(events) == [.interrupted])
    }

    @Test func workflowsAndAgentsAreNotCommands() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t, [#"{"type":"system","subtype":"task_started","task_id":"w1","description":"Run the flow","task_type":"local_workflow"}"#])
        #expect(events.compactMap(Self.started).isEmpty)
    }

    @Test func aTaskMissingFromTheLiveSetEndedUnheard() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                #"{"type":"system","subtype":"task_started","task_id":"b8","description":"Watch","is_backgrounded":true,"task_type":"local_bash"}"#,
                #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b8","task_type":"local_bash","description":"Watch"}]}"#,
                #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#,
            ])
        #expect(Self.ends(events) == [.completed])
    }

    @Test func aMonitorIsKnownByItsCall() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("call-9", "Monitor", #"{"command":"tail -F err.log","description":"clock","timeout_ms":1800000}"#),
                #"{"type":"system","subtype":"task_started","task_id":"m1","tool_use_id":"call-9","description":"clock","task_type":"local_bash"}"#,
            ])
        #expect(events.compactMap(Self.started).map(\.kind) == [.monitor])
    }

    @Test func aCronJobIsTheChatsArmedRowUntilItsCLIEnds() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let created = try Self.claude(
            t,
            [
                Self.claudeCall("call-10", "CronCreate", #"{"cron":"*/30 * * * *","prompt":"Re-check the census\nand report","recurring":true}"#, parent: "agent-x"),
                Self.claudeResult("call-10", "Scheduled recurring job j1 (Every 30 minutes).", #"{"id":"j1","humanSchedule":"Every 30 minutes","recurring":true,"durable":false}"#, parent: "agent-x"),
            ])
        let job = try #require(created.lazy.compactMap(Self.started).first)
        #expect(job.kind == .scheduled)
        #expect(job.owner == .main)
        #expect(job.title == "Re-check the census")
        #expect(job.schedule?.human == "Every 30 minutes")
        #expect(job.schedule?.next != nil)
        #expect(!job.canStop)
        t.cronFired(try JSONValue.parse(Data(#"{"type":"user","turnOrigin":"scheduled","isMeta":true,"message":{"role":"user","content":"Re-check the census\nand report"}}"#.utf8)))
        let fired = t.take().events
        #expect(fired.contains { if case .commandChanged("j1", .fired) = $0 { true } else { false } })
        t.translate(.exited(status: 0))
        #expect(Self.ends(t.take().events) == [.ended])
    }

    @Test func theAgentsCronDeleteDeletesTheJob() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try Self.claude(
            t,
            [
                Self.claudeCall("call-11", "CronCreate", #"{"cron":"0 9 * * *","prompt":"Morning report","recurring":false}"#),
                Self.claudeResult("call-11", "Scheduled one-shot task j2.", #"{"id":"j2","humanSchedule":"At 9:00 AM","recurring":false}"#),
                Self.claudeCall("call-12", "CronDelete", #"{"id":"j2"}"#),
                Self.claudeResult("call-12", "Cancelled job j2.", "null"),
            ])
        #expect(Self.ends(events) == [.deleted(by: .agent)])
    }

    /// Read back after Kore restarted: only what the history records, every row finished; one
    /// with no recorded end ended with its CLI.
    @Test func aClaudeReplayShowsNothingLive() async throws {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-21T10:00:00.000Z","message":{"role":"user","content":"Start them."}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-21T10:00:01.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call-1","name":"Bash","input":{"command":"sleep 5","description":"Short wait","run_in_background":true}},{"type":"tool_use","id":"call-2","name":"Bash","input":{"command":"npm run dev","description":"Dev server","run_in_background":true}}]}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-10-21T10:00:02.000Z","toolUseResult":{"backgroundTaskId":"b1"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-1","content":"Command running in background with ID: b1."}]}}"#,
            #"{"type":"user","uuid":"r2","timestamp":"2026-10-21T10:00:02.000Z","toolUseResult":{"backgroundTaskId":"b2"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-2","content":"Command running in background with ID: b2."}]}}"#,
            #"{"type":"user","uuid":"n1","timestamp":"2026-10-21T10:00:07.000Z","turnOrigin":"task_notification","message":{"role":"user","content":"<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>call-1</tool-use-id>\n<status>completed</status>\n<summary>Background command \"Short wait\" completed (exit code 0)</summary>\n</task-notification>"}}"#,
        ]
        let messages = try lines.map { try JSONValue.parse(Data($0.utf8)) }
        let replayed = await ClaudeTranslator.replayed(messages, folder: Self.folder, sessionId: "s1")
        let store = CommandsStore()
        store.apply(.replayed(replayed.events))
        #expect(store.summary.total == 0)
        #expect(store.command("b1")?.state == .completed)
        #expect(store.command("b1")?.duration == 6)
        #expect(store.command("b2")?.state == .ended)
    }

    // MARK: - Codex

    @Test func aCodexCommandStillRunningAtItsTurnsEndBecomesARow() {
        let t = CodexTranslator(folder: Self.folder)
        Self.codex(t, "turn/started", #"{"turn":{"id":"t1"}}"#)
        Self.codex(t, "item/started", Self.codexItem("i-in", "inProgress", process: "11"))
        Self.codex(t, "item/completed", Self.codexItem("i-in", "completed", process: "11", exit: 0))
        Self.codex(t, "item/started", Self.codexItem("i-bg", "inProgress", process: "12"))
        Self.codex(t, "turn/completed", #"{"turn":{"id":"t1","status":"completed"}}"#)
        Self.codex(t, "item/commandExecution/outputDelta", #"{"itemId":"i-bg","delta":"Forwarding\n"}"#)
        let events = t.take().events
        let rows = events.compactMap(Self.started)
        #expect(rows.map(\.id) == ["i-bg"])
        #expect(rows.first?.output == .stream)
        #expect(rows.first?.process?.id == "12")
        #expect(events.contains { if case .commandOutput("i-bg", "Forwarding\n") = $0 { true } else { false } })
        // Its later output is the command's, not the tool row's.
        #expect(!events.contains { if case .toolOutput("i-bg", _, _) = $0 { true } else { false } })
        t.stopRequested("i-bg")
        Self.codex(t, "item/completed", Self.codexItem("i-bg", "failed", process: "12", exit: -1))
        #expect(Self.ends(t.take().events) == [.stopped(by: .user)])
    }

    @Test func aChildThreadsTerminalIsTheChilds() {
        let t = CodexTranslator(folder: Self.folder)
        t.translate(.subThread(threadId: "child", method: "turn/started", params: Self.json(#"{"threadId":"child","turn":{"id":"ct"}}"#)))
        t.translate(.subThread(threadId: "child", method: "item/started", params: Self.json(Self.codexItem("ci", "inProgress", process: "21"))))
        t.translate(.subThread(threadId: "child", method: "turn/completed", params: Self.json(#"{"threadId":"child","turn":{"id":"ct","status":"completed"}}"#)))
        #expect(t.take().events.compactMap(Self.started).map(\.owner) == [.sub("child")])
    }

    @Test func aCodexRowMissingFromTwoListsEndedUnheard() {
        let t = CodexTranslator(folder: Self.folder)
        Self.codex(t, "turn/started", #"{"turn":{"id":"t1"}}"#)
        Self.codex(t, "item/started", Self.codexItem("i1", "inProgress", process: "31"))
        Self.codex(t, "turn/completed", #"{"turn":{"id":"t1","status":"completed"}}"#)
        _ = t.take()
        t.terminalsListed([Self.json(#"{"itemId":"i1","processId":"31","command":"x","cwd":"/tmp","osPid":4242,"cpuPercent":1.5,"rssKb":2048}"#)], owner: .main)
        let listed = t.take().events
        #expect(listed.contains { if case .commandChanged("i1", .process(let p)) = $0 { p.osPid == 4242 && p.memoryKB == 2048 } else { false } })
        t.terminalsListed([], owner: .main)
        #expect(Self.ends(t.take().events).isEmpty)
        t.terminalsListed([], owner: .main)
        #expect(Self.ends(t.take().events) == [.completed])
    }

    @Test func theAppServerEndingEndsItsTerminals() {
        let t = CodexTranslator(folder: Self.folder)
        Self.codex(t, "turn/started", #"{"turn":{"id":"t1"}}"#)
        Self.codex(t, "item/started", Self.codexItem("i1", "inProgress", process: "41"))
        Self.codex(t, "turn/completed", #"{"turn":{"id":"t1","status":"completed"}}"#)
        t.translate(.exited(status: 0))
        #expect(Self.ends(t.take().events) == [.ended])
    }

    /// A thread read back: an item that ran longer than its turn outlived it, a finished row.
    @Test func aCodexReplayShowsOutlivedItemsFinished() {
        let t = CodexTranslator(folder: Self.folder)
        let turn = Self.json(
            #"{"id":"t1","status":"completed","startedAt":1792874894,"durationMs":2000,"items":[{"type":"userMessage","id":"u","content":[{"type":"text","text":"Start it"}]},"#
                + Self.codexItem("short", "completed", process: "1", exit: 0, duration: 500) + ","
                + Self.codexItem("long", "completed", process: "2", exit: 0, duration: 6933) + ","
                + Self.codexItem("killed", "failed", process: "3", exit: -1, duration: 5964) + "]}")
        let store = CommandsStore()
        store.apply(.replayed(t.replay([turn])))
        #expect(store.summary.total == 0)
        #expect(store.command("short") == nil)
        #expect(store.command("long")?.state == .completed)
        #expect(abs((store.command("long")?.duration ?? 0) - 6.933) < 0.001)
        #expect(store.command("killed")?.state == .stopped(by: .unknown))
    }

    // MARK: - Helpers

    static func agent(_ id: String, parent: AgentID) -> AgentInfo {
        AgentInfo(id: id, parent: parent, toolId: id, name: id, type: nil, model: nil, prompt: nil, background: false)
    }

    static func shell(_ id: String, owner: AgentID, at: Date = .now) -> ActiveCommand {
        ActiveCommand(id: id, kind: .shell, title: id, startedAt: at, owner: owner)
    }

    static func json(_ text: String) -> JSONValue { (try? JSONValue.parse(Data(text.utf8))) ?? .null }

    static func claude(_ t: ClaudeTranslator, _ lines: [String]) throws -> [ChatEvent] {
        for line in lines { t.translate(ClaudeEvent(message: try JSONValue.parse(Data(line.utf8)))) }
        return t.take().events
    }

    static func claudeCall(_ id: String, _ name: String, _ input: String, parent: String? = nil) -> String {
        let parent = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"assistant","parent_tool_use_id":"# + parent
            + #","message":{"id":"m-"# + id + #"","role":"assistant","content":[{"type":"tool_use","id":""# + id + #"","name":""# + name
            + #"","input":"# + input + "}]}}"
    }

    static func claudeResult(_ id: String, _ text: String, _ result: String, parent: String? = nil) -> String {
        let parent = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"user","parent_tool_use_id":"# + parent + #","tool_use_result":"# + result
            + #","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":""# + id + #"","content":""# + text + #""}]}}"#
    }

    static func codex(_ t: CodexTranslator, _ method: String, _ params: String) {
        t.translate(CodexEvent(notification: method, params: json(params)))
    }

    static func codexItem(_ id: String, _ status: String, process: String, exit: Int? = nil, duration: Int? = nil) -> String {
        let item =
            #"{"type":"commandExecution","id":""# + id + #"","command":"/bin/zsh -lc 'ping -c 30 127.0.0.1'","cwd":"/tmp","status":""#
            + status + #"","processId":""# + process + #"","exitCode":"# + (exit.map(String.init) ?? "null") + #","durationMs":"#
            + (duration.map(String.init) ?? "null") + "}"
        return duration == nil ? #"{"item":"# + item + "}" : item
    }

    static func started(_ event: ChatEvent) -> ActiveCommand? {
        if case .commandStarted(let command) = event { command } else { nil }
    }

    static func ends(_ events: [ChatEvent]) -> [ActiveCommand.State] {
        events.compactMap { if case .commandEnded(_, let state, _) = $0 { state } else { nil } }
    }
}

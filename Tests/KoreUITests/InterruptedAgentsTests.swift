import Foundation
import Testing

@testable import KoreCore
@testable import KoreUI

/// A stop while agents run (`Fixtures/transcripts/stopped-agents`, trimmed from a real session
/// with all text scrubbed): a background agent spawned in an earlier turn, and a foreground one
/// whose Agent call the stop rejected. Both end stopped, live and read back, each with its cause
/// in the agents log.
@MainActor
@Suite("Interrupted agents")
struct InterruptedAgentsTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/transcripts/stopped-agents")

    private let parent: [JSONValue]
    private let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("kore-agents-\(UUID().uuidString).log")
    private let log: KoreLog

    init() throws {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent("parent.jsonl"), encoding: .utf8)
        parent = try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
        log = KoreLog(url: logFile)
    }

    private func translator() -> ClaudeTranslator {
        let translator = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: "s1")
        translator.log = AgentLog(log)
        return translator
    }

    private func json(_ text: String) -> JSONValue { (try? JSONValue.parse(Data(text.utf8))) ?? .null }

    /// stdout's start of the foreground agent's task.
    private var taskStarted: JSONValue {
        json(#"{"type":"system","subtype":"task_started","task_id":"afg","tool_use_id":"toolu_fg","description":"Demo","task_type":"local_agent","is_backgrounded":false}"#)
    }

    private var stoppedResult: JSONValue {
        json(#"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":54000,"terminal_reason":"aborted_tools"}"#)
    }

    private var completedResult: JSONValue {
        json(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":10000}"#)
    }

    /// Plays lines as stdout gives them: the background agent's turn, then the foreground one's,
    /// stopped. `rejected`: the stop's result for the Agent call comes (it may not).
    private func live(_ translator: ClaudeTranslator, rejected: Bool) -> [ChatEvent] {
        var events: [ChatEvent] = []
        func feed(_ lines: [JSONValue]) {
            for line in lines { translator.translate(ClaudeEvent(message: line)) }
            events += translator.take().events
        }
        translator.openTurn(.user)
        feed(Array(parent[1...3]) + [completedResult])
        translator.openTurn(.user)
        feed([parent[5], taskStarted] + (rejected ? [parent[6]] : []) + [parent[7], stoppedResult])
        return events
    }

    private func ends(_ events: [ChatEvent]) -> [String] {
        events.compactMap { if case .agentFinished(let id, let status, _) = $0 { "\(id) \(status)" } else { nil } }
    }

    private func logLines() throws -> [String] {
        log.sync()
        return try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    // MARK: The foreground agent

    /// (a) The Agent call's result is the CLI's rejection, as an error: its agent is stopped, not
    /// done, and leaves the tree for the Stopped group.
    @Test func aRejectedAgentCallStopsItsAgent() throws {
        let translator = translator()
        let events = live(translator, rejected: true)
        #expect(ends(events) == ["toolu_fg stopped"])
        #expect(!translator.isFinished("toolu_bg"))

        let script = Script()
        script.send("Go")
        events.forEach(script.store.apply)
        _ = script.sections
        #expect(script.store.agent("toolu_fg")?.status == .stopped)
        #expect(script.store.agentTree().stopped.map(\.id) == ["toolu_fg"])
        #expect(script.store.agentTree().background.map(\.id) == ["toolu_bg"])

        let lines = try logLines().filter { $0.contains("agent=toolu_fg") && $0.contains("\tstatus ") }
        #expect(lines.count == 1)
        #expect(lines.first?.contains(#"to=stopped source="tool_result error""#) == true)
    }

    /// No result for the call at all: the stopped turn ends its foreground agent, and leaves the
    /// background one to its files.
    @Test func aStopEndsTheForegroundAgentWithoutItsResult() throws {
        let translator = translator()
        let events = live(translator, rejected: false)
        #expect(ends(events) == ["toolu_fg stopped"])
        #expect(!translator.isFinished("toolu_bg"))
        let lines = try logLines()
        #expect(lines.contains { $0.contains("agent=toolu_fg") && $0.contains(#"source="turn interrupt""#) })
        #expect(lines.contains { $0.contains("\tspawned ") && $0.contains("agent=toolu_bg") && $0.contains("mode=background") })
    }

    /// Read back, the rejected call's agent is stopped too; the background one is left for its
    /// files to settle.
    @Test func aRejectedAgentCallReadsBackStopped() throws {
        let translator = translator()
        let events = translator.replay(parent)
        #expect(ends(events) == ["toolu_fg stopped"])
        #expect(translator.unfinishedAgents().map(\.id) == ["toolu_bg"])
        // A replay logs nothing of its own.
        log.sync()
        #expect(((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").isEmpty)
    }

    // MARK: The agents' own files

    /// (b) A followed background agent this CLI runs: running while its files say nothing of a
    /// stop; stopped once its meta file flips to `stoppedByUser` and its last line is the marker.
    @Test func aFollowedAgentsFilesSayItWasStopped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = try String(contentsOf: Self.fixtures.appendingPathComponent("agent-abg.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let transcript = folder.appendingPathComponent("agent-abg.jsonl")
        let meta = folder.appendingPathComponent("agent-abg.meta.json")
        let since = Date().addingTimeInterval(-1)

        try (lines.dropLast().joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try #"{"agentType":"general-purpose","requestShape":"background","toolUseId":"toolu_bg"}"#.write(
            to: meta, atomically: true, encoding: .utf8)
        var state = ClaudeHistory.Subagent.read(transcript)
        #expect(state.outcome() == .running)
        #expect(ClaudeBackend.stopSource(state, wrote: true, since: since) == nil)

        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try String(contentsOf: Self.fixtures.appendingPathComponent("agent-abg.meta.json"), encoding: .utf8)
            .write(to: meta, atomically: true, encoding: .utf8)
        state = ClaudeHistory.Subagent.read(transcript)
        #expect(state.stoppedByUser && state.interrupted)
        #expect(state.outcome() == .stopped)
        #expect(ClaudeBackend.stopSource(state, wrote: true, since: since) == .fileStoppedByUser)
        // Run again, its old marks don't end it until it has written since.
        #expect(ClaudeBackend.stopSource(state, wrote: false, since: since) == nil)
    }

    /// (c) Both markers end an agent: the plain one (the background agent's) and the one for a
    /// tool use (the foreground agent's, with no meta file to say so).
    @Test func bothStopMarkersEndAnAgent() {
        let background = ClaudeHistory.Subagent.read(Self.fixtures.appendingPathComponent("agent-abg.jsonl"))
        let foreground = ClaudeHistory.Subagent.read(Self.fixtures.appendingPathComponent("agent-afg.jsonl"))
        #expect(background.interrupted && foreground.interrupted)
        #expect(!foreground.stoppedByUser)
        #expect(foreground.outcome() == .stopped)
        #expect(ClaudeBackend.stopSource(foreground, wrote: true, since: nil) == .fileStopMarker)
        #expect(ClaudeBackend.source(of: foreground) == .fileStopMarker)
        #expect(ClaudeBackend.source(of: background) == .fileStoppedByUser)
        #expect(ClaudeHistory.stopMarkers == ["[Request interrupted by user]", "[Request interrupted by user for tool use]"])
    }

    // MARK: Codex

    /// A stopped Codex turn ends the child thread it ran, logged with its cause.
    @Test func aStoppedCodexTurnStopsItsChild() throws {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        translator.log = AgentLog(log)
        let item = CodexItem(.object([
            "id": .string("call_1"), "type": .string("subAgentActivity"), "kind": .string("started"),
            "agentThreadId": .string("child"), "agentPath": .string("/root/scout"),
        ]))
        translator.translate(.turnStarted(turnId: "t1"))
        translator.translate(.itemStarted(item))
        translator.translate(.itemCompleted(item))
        translator.translate(.turnCompleted(CodexTurnResult(json(#"{"turn":{"id":"t1","status":"interrupted"}}"#))))
        #expect(ends(translator.take().events) == ["child stopped"])
        let lines = try logLines()
        #expect(lines.contains { $0.contains("\tspawned cli=codex") && $0.contains("agent=child") })
        #expect(lines.contains { $0.contains("agent=child") && $0.contains(#"to=stopped source="turn interrupt""#) })
    }

    // MARK: The log

    /// One status change, one line: a timestamp, a tab, the event, its fields; past the limit the
    /// file moves to `.1`.
    @Test func aStatusChangeWritesOneLineWithItsSource() throws {
        AgentLog(log).status("claude", chat: "s1", agent: "toolu_x", to: "stopped", source: .fileStopMarker, via: "turn interrupt")
        let lines = try logLines()
        #expect(lines.count == 1)
        let parts = lines[0].split(separator: "\t", maxSplits: 1).map(String.init)
        #expect(parts.count == 2)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(stamp.date(from: parts[0]) != nil)
        #expect(
            parts.last == #"status cli=claude chat=s1 agent=toolu_x from=running to=stopped source="file stop marker" via="turn interrupt""#)

        let small = KoreLog(url: logFile, limit: 200)
        for i in 0..<6 { small.write("resumed", ["agent": "a\(i)"]) }
        small.sync()
        small.write("resumed", ["agent": "after"])
        small.sync()
        let older = logFile.appendingPathExtension("1")
        defer { try? FileManager.default.removeItem(at: older) }
        #expect(FileManager.default.fileExists(atPath: older.path))
        #expect(try String(contentsOf: logFile, encoding: .utf8).contains("agent=after"))
    }
}

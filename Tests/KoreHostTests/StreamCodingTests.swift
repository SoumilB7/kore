import Foundation
import KoreCore
import Testing

@testable import LinkProtocol
@testable import src

/// The stream's wire forms against golden JSON (`Tests/Fixtures/stream/v1`): every `ChatEvent`
/// and `ChatCommand` case, encoded as the fixture says and read back the same. A renamed Swift
/// case or label that changes a byte fails here. `KORE_WRITE_FIXTURES=1` writes them again.
@Suite("stream coding")
struct StreamCodingTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stream/v1")
    static let at = Date(timeIntervalSince1970: 1_800_000_000)

    static var events: [ChatEvent] {
        let tool = ToolCall(id: "tool1", name: "Bash", detail: "ls", input: "ls -la", description: "List", path: nil, readOnly: true)
        let change = FileChange(path: "a.txt", kind: .update, hunks: [])
        let command = ActiveCommand(id: "cmd1", kind: .shell, title: "watch", command: "npm run watch", startedAt: at, owner: .sub("ag1"))
        let approval = Approval(
            id: "ap1", title: "Run ls", detail: "in work", body: "ls", canAlwaysAllow: false,
            questions: [.init(id: "q1", text: "Which?", header: "Pick", options: [.init(label: "A", description: "first")])])
        let controls = ChatControls(
            models: [ModelOption(id: "small", name: "Small", resolved: "small-1", efforts: ["low"], supportsAutoMode: true)], model: "small",
            effort: "low", commands: [SlashCommand(name: "review", description: "Review", hint: "", kind: .skill)])
        return [
            .sessionIdentified("s1"), .titleChanged("Totals"), .controlsLoaded(controls),
            .modeChanged(ModeChange(mode: "plan", previous: "default", source: .agent(.enteredPlanMode, .main), at: at)),
            .planModeChanged(PlanModeChange(on: true, source: .user, at: at)),
            .fastModeChanged(FastModeReport(on: true, paused: false, offered: true)),
            .remoteControl(RemoteControl(state: .failed("no"), place: "x")), .remoteControlUnavailable("why"),
            .turnStarted("t1", origin: .user, at: at), .turnOrigin("t1", .schedule),
            .turnFinished("t1", .limited("limit", resetsAt: at), duration: .seconds(3)), .turnFinished(nil, .interrupted, duration: nil),
            .refused("t1", Refusal(category: "cyber", model: "m-4-5")), .turnChanges("t1", [change]),
            .queuedMessage(id: "m2", .nextTurn("t2")), .messageQueued(id: "m2", text: "later", attachments: []),
            .userMessage(text: "hello", attachments: [SentAttachment(name: "a.txt", kind: .text, url: URL(fileURLWithPath: "/tmp/a.txt"), image: nil)], id: "m1"),
            .peerMessage(from: "other", text: "hi", turn: "t1", id: "p1"),
            .text("b1", .answer, "Hi", agent: .main), .text("b2", .thinking, "hmm", agent: .sub("ag1")), .finalAnswer("b1", agent: .main),
            .toolStarted(tool, agent: .main), .toolOutput(id: "tool1", "out", agent: .main),
            .toolFinished(id: "tool1", output: nil, isError: false, agent: .sub("ag1")), .toolStopped(id: "tool1", agent: .main),
            .fileChanged(toolId: "tool1", [change], agent: .main), .notice("note", isError: true),
            .agentSpawned(AgentInfo(id: "ag1", parent: .main, toolId: "tool2", name: "Search", type: "Explore", model: nil, prompt: "find", background: true)),
            .agentProgress(id: "ag1", AgentProgress(tokens: 10, tools: 2, duration: .seconds(5), lastTool: "Read")),
            .agentFinished(id: "ag1", .completed, result: "done"), .agentResumed(id: "ag1"), .agentBackgrounded(id: "ag1"),
            .commandStarted(command), .commandChanged(id: "cmd1", .fired(at: at, next: nil)), .commandOutput(id: "cmd1", "line"),
            .commandEnded(id: "cmd1", .stopped(by: .user), at: at),
            .approvalRequested(approval), .approvalWithdrawn("ap1"), .planReady, .exited(status: 15),
            .compacted(at: at, from: 1000, auto: false), .compactionStarted(auto: true), .compactionSummary("sum"), .compactionFailed("no"),
            .compactionStopped, .connection(.retrying(attempt: 1, of: 3)), .connection(.away("mybox offline")),
            .contextUsage(ContextUsage(used: 10, window: 100, autoCompacts: true, at: at)), .earlierHistory(true),
            .requestUsage(RequestUsage(id: "msg1", at: at, model: "small", agent: "ag1", input: 10, output: 5, cacheRead: 100, cacheWrite5m: 20, cacheWrite1h: 0)),
            .replayed([.userMessage(text: "old", attachments: [], id: "m0")]), .historyReplaced([]),
        ]
    }

    static let commands: [ChatCommand] = [
        .send(text: "hi", files: [CallFile(blob: "b1", name: "a.png", kind: .image)], queued: nil, id: "m1"), .interrupt,
        .respond(approval: "ap1", decision: .answers(["q1": ["A"]])), .respond(approval: "ap2", decision: .approvePlan(autoAcceptEdits: true)),
        .setMode("plan"), .setPlanMode(true), .setModel("small"), .setEffort("high"), .setFastMode(false), .rename("Totals"),
        .stopAgent("ag1"), .stopCommand("cmd1"), .backgroundCommand("cmd1"), .commandOutput("cmd1"), .watchCommands(true),
        .agentHistory("ag1"), .fork(message: "m1", text: "hi"), .forkAtEnd, .rollback(message: nil, text: "hi"), .earlier(turns: 5),
        .earlierMessages, .unloadPoint(message: "m1", text: "hi"), .unloaded(to: "e1"), .compact(instructions: "keep"), .usage,
        .useReset(credit: "c1", attempt: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), .setRemoteControl(true),
        .relaunch(reason: "stalled"), .listModels, .close, .keepRow(text: "/compact keep it", id: "m9"),
    ]

    func lines<T: Encodable>(_ values: [T]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return values.map { String(decoding: (try? encoder.encode($0)) ?? Data(), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    func check<T: Codable>(_ values: [T], _ name: String) throws {
        let made = lines(values)
        let file = Self.folder.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["KORE_WRITE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try made.write(to: file, atomically: true, encoding: .utf8)
        }
        let golden = try String(contentsOf: file, encoding: .utf8)
        #expect(made == golden)
        // Read back, and written again: the same bytes.
        let read = try golden.split(separator: "\n").map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
        #expect(lines(read) == golden)
    }

    @Test func everyEventKeepsItsWireForm() throws { try check(Self.events, "events.jsonl") }
    @Test func everyCommandKeepsItsWireForm() throws { try check(Self.commands, "commands.jsonl") }

    @Test func unknownTagsDontFail() throws {
        let call = try JSONDecoder().decode(ChatCall.self, from: Data(#"{"t":"chat.call","id":"1","chatId":"c","command":{"type":"teleport","to":"x"}}"#.utf8))
        guard case .unknown("teleport") = call.command else { Issue.record("not unknown: \(call.command)"); return }
        let item = try JSONDecoder().decode(StreamItem.self, from: Data(#"{"s":3,"e":{"type":"hologram"}}"#.utf8))
        #expect(item.s == 3 && item.e == nil)
        var assembler = StreamAssembler()
        #expect(assembler.take(item) == nil)
        // A history with one event this side can't read keeps the rest.
        let history = try JSONDecoder().decode(ChatEvent.self, from: Data(#"{"type":"replayed","events":[{"type":"hologram"},{"type":"titleChanged","title":"x"}]}"#.utf8))
        guard case .replayed(let inner) = history else { Issue.record("not a history"); return }
        #expect(inner.count == 1)
    }
}

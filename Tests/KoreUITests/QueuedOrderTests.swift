import Foundation
@testable import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// Two messages sent while a turn runs, A then B, taken by the CLI at the same boundary: they
/// show in the order the CLI took them (what the model read), live and read back, for Claude
/// and Codex. Kore sends one at a time, so that's the send order.
@MainActor
@Suite("Queued messages keep their order")
struct QueuedOrderTests {
    private func users(_ store: TranscriptStore) -> [String] {
        store.entries.filter { $0.kind == .user }.map(\.text)
    }

    private func running(_ last: (Script) -> Void) -> Script {
        let s = Script()
        s.send("Run it")
        s.start("t1")
        last(s)
        s.on(.messageQueued(id: "a", text: "A", attachments: []), .messageQueued(id: "b", text: "B", attachments: []))
        return s
    }

    /// The anchor last (the boundary the command's end left), or with rows streamed after it.
    @Test(arguments: [false, true])
    func twoTakenAtOneBoundaryStayInOrder(rowsAfter: Bool) {
        let s = running { s in
            s.tool("cmd")
            s.done("cmd")
            if rowsAfter { s.say("next", "Next.") }
        }
        s.on(.queuedMessage(id: "a", .inTurn(after: "cmd")), .queuedMessage(id: "b", .inTurn(after: "cmd")))
        #expect(users(s.store) == ["Run it", "A", "B"])
        let texts = s.store.entries.map(\.text)
        if rowsAfter { #expect(texts.firstIndex(of: "B")! < texts.firstIndex(of: "Next.")!) }
        #expect(s.lines.filter { $0.hasPrefix("§") } == ["§ Run it", "§ A", "§ B"])
    }

    /// Taken with nothing in the turn yet, and one at a later boundary after one at an earlier.
    @Test func noAnchorAndLaterBoundaries() {
        let s = running { _ in }
        s.on(.queuedMessage(id: "a", .inTurn(after: nil)))
        s.tool("cmd")
        s.on(.queuedMessage(id: "b", .inTurn(after: "cmd")))
        #expect(users(s.store) == ["Run it", "A", "B"])
        let kinds = s.store.entries.map { $0.kind == .user ? $0.text : "\($0.kind)" }
        #expect(kinds.firstIndex(of: "A")! < kinds.firstIndex(of: "tool")! && kinds.firstIndex(of: "tool")! < kinds.firstIndex(of: "B")!)
    }

    /// Were the CLI to take B first, B shows first: the rows follow what the model read.
    @Test func theCLIsOrderWins() {
        let s = running { s in
            s.tool("cmd")
            s.done("cmd")
        }
        s.on(.queuedMessage(id: "b", .inTurn(after: "cmd")), .queuedMessage(id: "a", .inTurn(after: "cmd")))
        #expect(users(s.store) == ["Run it", "B", "A"])
    }

    /// After the turn: A starts the next turn, B joins it (Claude runs both as one).
    @Test func afterTheTurnTheFirstStartsItAndTheSecondFollows() {
        let s = running { s in
            s.tool("cmd")
            s.done("cmd")
        }
        s.finish("t1")
        s.on(.queuedMessage(id: "a", .nextTurn("t2")), .turnStarted("t2", origin: .user, at: .now))
        s.on(.queuedMessage(id: "b", .inTurn(after: nil)))
        #expect(users(s.store) == ["Run it", "A", "B"])
    }

    // MARK: Claude

    private static func call(_ id: String) -> String {
        #"{"type":"assistant","parent_tool_use_id":null,"message":{"id":"m-"# + id
            + #"","role":"assistant","content":[{"type":"tool_use","id":""# + id + #"","name":"Bash","input":{"command":"sleep 5"}}]}}"#
    }

    private static func result(_ id: String) -> String {
        #"{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":""# + id
            + #"","content":"ok"}]}}"#
    }

    private static func lifecycle(_ id: String, _ state: String) -> String {
        #"{"type":"command_lifecycle","command_uuid":""# + id + #"","state":""# + state + #"","uuid":"x-"# + id + #"-"# + state + #""}"#
    }

    /// Claude's stream: both queued, both started at the command's end, in its queue's order.
    @Test func claudeLiveTwoAtOneToolBoundary() throws {
        let t = ClaudeTranslator(folder: Drive.folder, sessionId: "s")
        let s = Script()
        s.send("Run it")
        t.openTurn(.user)
        let feed = { (lines: [String]) in
            for line in lines { t.translate(ClaudeEvent(message: try JSONValue.parse(Data(line.utf8)))) }
            t.take().events.forEach(s.store.apply)
        }
        try feed([Self.call("cmd")])
        for (id, text) in [("a", "A"), ("b", "B")] {
            s.on(.messageQueued(id: id, text: text, attachments: []))
            t.pendingQueued.insert(id)
        }
        try feed([Self.lifecycle("a", "queued"), Self.lifecycle("b", "queued"), Self.result("cmd"),
                  Self.lifecycle("a", "started"), Self.lifecycle("b", "started")])
        #expect(users(s.store) == ["Run it", "A", "B"])
        #expect(s.store.entries.filter { $0.kind == .user }.map(\.inTurn) == [false, true, true])
    }

    /// Claude's session file: two queued_command attachments read back in the file's order.
    @Test func claudeReplayTwoQueuedCommands() async throws {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-21T10:00:00Z","message":{"role":"user","content":"Run it"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-21T10:00:01Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 5"}}]}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-10-21T10:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"attachment","uuid":"q1","timestamp":"2026-10-21T10:00:06Z","attachment":{"type":"queued_command","prompt":"A"}}"#,
            #"{"type":"attachment","uuid":"q2","timestamp":"2026-10-21T10:00:06Z","attachment":{"type":"queued_command","prompt":"B"}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-21T10:00:07Z","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Done"}]}}"#,
        ]
        let messages = try lines.map { try JSONValue.parse(Data($0.utf8)) }
        let replayed = await ClaudeTranslator.replayed(messages, folder: Drive.folder, sessionId: "s")
        let store = TranscriptStore()
        store.apply(.replayed(replayed.events))
        #expect(users(store) == ["Run it", "A", "B"])
    }

    // MARK: Codex

    /// Codex: both steered, their user items arriving in the order it took them.
    @Test func codexLiveTwoSteers() {
        let t = CodexTranslator(folder: Drive.folder)
        let s = Script(.codex)
        s.send("Run it")
        t.translate(.turnStarted(turnId: "t1"))
        let command = CodexItem(["type": "commandExecution", "id": "cmd", "command": "sleep 5"])
        t.translate(.itemStarted(command))
        t.translate(.itemCompleted(command))
        t.take().events.forEach(s.store.apply)
        for (id, text) in [("a", "A"), ("b", "B")] {
            s.on(.messageQueued(id: id, text: text, attachments: []))
            t.queuedRequest(id)
            t.queuedAccepted(id, turn: "t1")
        }
        for id in ["a", "b"] {
            t.translate(.itemCompleted(CodexItem(["type": "userMessage", "id": .string("srv-\(id)"), "clientId": .string(id), "content": []])))
        }
        t.take().events.forEach(s.store.apply)
        #expect(users(s.store) == ["Run it", "A", "B"])
    }

    /// Codex's turns read back: two steered user items after the same command.
    @Test func codexReplayTwoSteers() {
        let t = CodexTranslator(folder: Drive.folder)
        let text = { (s: String) -> JSONValue in [["type": "text", "text": .string(s)]] }
        let turn: JSONValue = [
            "id": "t1", "status": "completed",
            "items": [
                ["type": "userMessage", "id": "u1", "content": text("Run it")],
                ["type": "commandExecution", "id": "cmd", "command": "sleep 5", "status": "completed"],
                ["type": "userMessage", "id": "u2", "content": text("A")],
                ["type": "userMessage", "id": "u3", "content": text("B")],
                ["type": "agentMessage", "id": "ans", "text": "Done"],
            ],
        ]
        let store = TranscriptStore()
        store.apply(.replayed(t.replay([turn])))
        #expect(users(store) == ["Run it", "A", "B"])
    }
}

import Foundation
import Testing

@testable import KoreCore

/// Importing a chat's history: each format's sniff and read, the budget, both writers and the
/// record, on tiny histories written in the test (the CLIs' own row shapes).
@Suite("Chat import", .serialized)
struct HandoffTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        HandoffRecords.root.value = scratch.appendingPathComponent("records")
    }

    private func file(_ name: String, _ lines: [String]) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: Fixtures

    private func claudeRow(_ uuid: String, _ parent: String?, _ type: String, _ content: Any, extra: [String: Any] = [:]) -> String {
        var row: [String: Any] = [
            "type": type, "uuid": uuid, "parentUuid": parent as Any, "sessionId": "s-1", "cwd": scratch.path,
            "timestamp": "2026-10-20T09:00:0\(min(uuid.count, 9)).000Z",
            "message": type == "user"
                ? ["role": "user", "content": content]
                : ["id": "m-\(uuid)", "role": "assistant", "model": "fixture-model", "content": content],
        ]
        row.merge(extra) { _, new in new }
        return json(row)
    }

    private var claude: [String] {
        [
            claudeRow("u1", nil, "user", "Check the build."),
            claudeRow("a1", "u1", "assistant", [["type": "thinking", "thinking": "", "signature": "x"], ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "cat BUILD"]]]),
            claudeRow("r1", "a1", "user", [["type": "tool_result", "tool_use_id": "t1", "content": "Build 7781"]]),
            claudeRow("a2", "r1", "assistant", [["type": "tool_use", "id": "t2", "name": "Edit", "input": ["file_path": scratch.path + "/VERSION", "old_string": "1.4.0", "new_string": "1.4.1"]]]),
            claudeRow(
                "r2", "a2", "user", [["type": "tool_result", "tool_use_id": "t2", "content": "ok"]],
                extra: ["toolUseResult": ["filePath": scratch.path + "/VERSION", "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-1.4.0", "+1.4.1"]]]]]),
            claudeRow("a3", "r2", "assistant", [["type": "text", "text": "Build 7781, bumped to 1.4.1."]]),
            claudeRow("c1", "a3", "user", "<command-name>/model</command-name>"),
            claudeRow("c2", "c1", "assistant", [["type": "text", "text": "Set model"]]).replacingOccurrences(of: "fixture-model", with: "<synthetic>"),
            claudeRow("u2", "c2", "user", "Now run the tests."),
            claudeRow("a4", "u2", "assistant", [["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "swift test"]]]),
            claudeRow("x1", "a4", "user", "[Request interrupted by user]"),
            json(["type": "custom-title", "customTitle": "Build check", "sessionId": "s-1"]),
        ]
    }

    private func rollout(_ items: [[String: Any]]) -> [String] {
        [json(["timestamp": "2026-10-20T09:00:00.000Z", "type": "session_meta", "payload": ["id": "thread-1", "cwd": scratch.path]])]
            + items.enumerated().map { index, item in
                // As Codex writes them: time and type first, then the payload.
                let time = String(format: "2026-10-20T09:%02d:%02d.000Z", (index + 1) / 60, (index + 1) % 60)
                let payload = json(["p": item["payload"] ?? [:]]).dropFirst(5).dropLast()
                return #"{"timestamp":"\#(time)","type":"\#(item["type"] as? String ?? "")","payload":\#(payload)}"#
            }
    }

    private func response(_ payload: [String: Any]) -> [String: Any] { ["type": "response_item", "payload": payload] }
    private func message(_ role: String, _ text: String) -> [String: Any] {
        response(["type": "message", "role": role, "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]]])
    }

    private var codex: [String] {
        rollout([
            ["type": "turn_context", "payload": ["turn_id": "turn-1", "model": "fixture-model", "approval_policy": "never", "sandbox_policy": ["type": "danger-full-access"]]],
            message("developer", "Codex's own instructions"),
            message("user", "<environment_context>\n</environment_context>"),
            message("user", "Check the build."),
            response(["type": "reasoning", "summary": [], "encrypted_content": "gAAAA"]),
            response(["type": "custom_tool_call", "name": "exec", "call_id": "c1", "input": "text(await tools.exec_command({cmd:\"cat BUILD\"}));"]),
            response(["type": "custom_tool_call_output", "call_id": "c1", "output": "Script completed\nOutput:\nBuild 7781"]),
            response(["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2", "input": "*** Begin Patch\n*** Update File: VERSION\n@@\n-1.4.0\n+1.4.1\n*** End Patch\n"]),
            response(["type": "custom_tool_call_output", "call_id": "c2", "output": "Success. Updated the following files:\nM VERSION\n"]),
            message("assistant", "Build 7781, bumped to 1.4.1."),
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn-1"]],
            ["type": "turn_context", "payload": ["turn_id": "turn-2", "model": "fixture-model"]],
            message("user", "Now run the tests."),
            response(["type": "function_call", "name": "exec_command", "call_id": "c3", "arguments": "{\"cmd\":\"swift test\"}"]),
            response(["type": "function_call_output", "call_id": "c3", "output": "Process exited with code 1\nOutput:\n1 failure"]),
            ["type": "event_msg", "payload": ["type": "turn_aborted", "turn_id": "turn-2"]],
        ])
    }

    // MARK: Recognising files

    @Test func eachFormatKnowsOnlyItsOwnFiles() throws {
        let transcript = try file("t.jsonl", claude)
        let thread = try file("r.jsonl", codex)
        #expect(HandoffFormats.identify(transcript)?.format == "claude")
        #expect(HandoffFormats.identify(transcript)?.title == "Build check")
        #expect(HandoffFormats.identify(thread)?.format == "codex")
        #expect(HandoffFormats.identify(thread)?.sessionId == "thread-1")
        // JSON lines that aren't a chat, and a file that isn't JSON at all.
        #expect(HandoffFormats.identify(try file("n.jsonl", [#"{"type":"user","text":"hi"}"#, #"{"a":1}"#])) == nil)
        #expect(HandoffFormats.identify(try file("x.jsonl", ["hello", "world"])) == nil)
        #expect(HandoffFormats.read(try file("n2.jsonl", [#"{"note":1}"#])) == nil)
    }

    @Test func aHistoryWithNoTurnsOrDamageImportsNothing() throws {
        #expect(HandoffFormats.read(try file("empty.jsonl", rollout([]))) == nil)
        var damaged = codex
        damaged.insert(#"{"timestamp":"2026-10-20T09:00:30.000Z","type":"response_item","payload":{"type":"mess"#, at: 5)
        #expect(HandoffFormats.read(try file("damaged.jsonl", damaged)) == nil)
    }

    // MARK: Reading

    @Test func aClaudeTranscriptReadsAsTurnsAndSteps() throws {
        let segment = try #require(HandoffFormats.read(try file("t2.jsonl", claude)))
        #expect(segment.turns.map(\.prompt) == ["Check the build.", "Now run the tests."])
        let first = segment.turns[0]
        #expect(first.steps.map(\.kind) == [.command, .edit])
        #expect(first.steps[0].output == "Build 7781")
        #expect(first.steps[1].detail == "file: VERSION\n@@ -1,1 +1,1 @@\n-1.4.0\n+1.4.1")
        // The command's synthetic reply doesn't replace the turn's own.
        #expect(first.reply == "Build 7781, bumped to 1.4.1.")
        #expect(segment.turns[1].end == .interrupted)
        #expect(segment.turns[1].steps[0].status == .interrupted)
        #expect(segment.model == "fixture-model")
    }

    @Test func aCompactedClaudeTranscriptCarriesItsSummary() throws {
        let lines = [
            claudeRow("o1", nil, "user", "An old prompt."),
            json(["type": "system", "subtype": "compact_boundary", "uuid": "b1", "parentUuid": NSNull(), "logicalParentUuid": "o1", "sessionId": "s-1"]),
            claudeRow("s1", "b1", "user", "What happened so far.", extra: ["isCompactSummary": true]),
            claudeRow("n1", "s1", "user", "A new prompt."),
            claudeRow("n2", "n1", "assistant", [["type": "text", "text": "Done."]]),
        ]
        let segment = try #require(HandoffFormats.read(try file("c.jsonl", lines)))
        #expect(segment.summary == "What happened so far.")
        #expect(segment.turns.map(\.prompt) == ["A new prompt."])
    }

    @Test func aCodexRolloutReadsFromItsOwnItems() throws {
        let segment = try #require(HandoffFormats.read(try file("r2.jsonl", codex)))
        #expect(segment.turns.map(\.prompt) == ["Check the build.", "Now run the tests."])
        let first = segment.turns[0]
        #expect(first.id == "turn-1")
        #expect(first.steps.map(\.kind) == [.command, .edit])
        #expect(first.steps[0].title == "cat BUILD")
        #expect(first.steps[1].added == 1 && first.steps[1].removed == 1)
        #expect(first.reply == "Build 7781, bumped to 1.4.1.")
        let second = segment.turns[1]
        #expect(second.end == .interrupted)
        #expect(second.steps[0].exitCode == 1 && second.steps[0].status == .error)
        #expect(segment.mode == "fullAccess")
    }

    // MARK: Budget

    private func turn(_ n: Int, prompt: Int = 400, output: Int = 0) -> HandoffTurn {
        var turn = HandoffTurn(id: "t\(n)", prompt: "p\(n) " + String(repeating: "a", count: prompt))
        if output > 0 {
            turn.steps = [HandoffStep(kind: .command, tool: "Bash", title: "make", detail: "command: make", output: String(repeating: "o", count: output))]
        }
        turn.reply = "r\(n)"
        return turn
    }

    @Test func newestTurnsGoInFullThenShorterThenNotAtAll() {
        var segment = HandoffSegment(source: "claude", product: "Claude Code", sessionId: "s")
        segment.turns = (1...40).map { turn($0, output: 2000) }
        // A 10k window: a 4k budget.
        let plan = HandoffBudget.plan(segment, window: 10_000)
        let levels = plan.entries.map(\.level)
        #expect(plan.entries.last?.turn.id == "t40")
        #expect(levels.last == .full)
        #expect(levels.contains(.condensed) && levels.contains(.bare))
        // Levels only step down going back.
        #expect(levels == levels.sorted { ["bare": 0, "condensed": 1, "full": 2][$0.rawValue]! < ["bare": 0, "condensed": 1, "full": 2][$1.rawValue]! })
        #expect(plan.notCarried == 40 - plan.carried && plan.notCarried > 0)
        #expect(plan.tokens <= plan.budget)
    }

    @Test func theSourcesOwnSummaryIsAlwaysCarried() {
        var segment = HandoffSegment(source: "claude", product: "Claude Code", sessionId: "s", summary: String(repeating: "s", count: 50_000))
        segment.turns = [turn(1)]
        let plan = HandoffBudget.plan(segment, window: 10_000)
        #expect(plan.summary != nil)
        #expect(plan.carried == 1)
    }

    @Test func longOutputsKeepTheirStartAndEnd() {
        let lines = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        let cut = HandoffRender.cut(lines)
        #expect(cut.hasPrefix("line 1\n"))
        #expect(cut.hasSuffix("line 2000"))
        #expect(cut.contains("lines cut …]"))
        #expect(cut.count < 3500)
    }

    // MARK: Writers

    private var plan: HandoffPlan {
        get throws { try #require(HandoffImport.plan(try file("p.jsonl", claude), for: CodexHandoffWriter(), model: nil)?.plan) }
    }

    @Test func codexGetsPlainMessagesOnly() throws {
        let items = CodexHandoffWriter.items(try plan)
        #expect(items.first?["role"]?.string == "developer")
        #expect(items.allSatisfy { $0["type"]?.string == "message" })
        let texts = items.compactMap { $0["content"]?[0]?["text"]?.string }
        #expect(texts.contains("Check the build."))
        #expect(texts.contains { $0.hasPrefix("[external_agent_tool_call: Bash]\ncommand: cat BUILD") && $0.contains("Build 7781") })
        #expect(texts.contains("Build 7781, bumped to 1.4.1."))
        #expect(items.filter { $0["role"]?.string == "assistant" }.allSatisfy { $0["content"]?[0]?["type"]?.string == "output_text" })
    }

    @Test func claudeGetsANewChainedTranscript() throws {
        let (lines, rows) = ClaudeHandoffWriter.lines(try plan, sessionId: "new-1", cwd: scratch.path, version: "1.0.0", title: "Build check", plan: false)
        let conversation = lines.filter { $0["uuid"] != nil }
        #expect(conversation.map { $0["uuid"]?.string ?? "" } == rows)
        #expect(conversation.first?["isMeta"]?.bool == true)
        #expect(conversation.first?["parentUuid"] == .null)
        for (row, parent) in zip(conversation.dropFirst(), conversation) { #expect(row["parentUuid"]?.string == parent["uuid"]?.string) }
        let replies = conversation.filter { $0["type"]?.string == "assistant" }
        #expect(replies.count == 2 && replies.allSatisfy { $0["message"]?["model"]?.string == "<synthetic>" })
        #expect(lines.contains { $0["type"]?.string == "custom-title" && $0["customTitle"]?.string == "Build check" })
        #expect(lines.last?["type"]?.string == "last-prompt" && lines.last?["leafUuid"]?.string == rows.last)
        // Every text block has words in it (the API refuses empty ones).
        let blocks = replies.flatMap { $0["message"]?["content"]?.array ?? [] }
        #expect(blocks.allSatisfy { !($0["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func anExistingFileIsNeverWritten() throws {
        let target = scratch.appendingPathComponent("existing.jsonl")
        try Data("kept".utf8).write(to: target)
        #expect(throws: HandoffError.self) { try ClaudeHandoffWriter.create(target, Data("new".utf8)) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "kept")
    }

    // MARK: Records

    @Test func theRecordAndItsTurnsComeBackBySession() throws {
        let plan = try plan
        let record = HandoffRecord(
            source: .init(cli: "claude", session: "s-1"), sourceFile: scratch, sourceProduct: "Claude Code", cutoff: plan.cutoff,
            sourceTitle: "Build check", sourceModel: nil, target: .init(cli: "codex", session: "thread-new"), targetModel: nil,
            folder: scratch, carried: .init(plan), written: ["w1"])
        try HandoffRecords.save(record, history: plan.entries.map(\.turn))
        #expect(HandoffRecords.record(target: "thread-new")?.written == ["w1"])
        #expect(HandoffRecords.history(target: "thread-new")?.map(\.prompt) == ["Check the build.", "Now run the tests."])
        #expect(HandoffRecords.record(target: "another") == nil)
        #expect(throws: HandoffError.self) { try HandoffRecords.save(record, history: []) }
    }

    @Test func rowsKoreWroteArentReadBackAsTheChatsOwn() throws {
        let plan = try plan
        let (lines, rows) = ClaudeHandoffWriter.lines(plan, sessionId: "made-1", cwd: scratch.path, version: "1.0.0", title: "t", plan: false)
        let record = HandoffRecord(
            source: .init(cli: "codex", session: "thread-1"), sourceFile: scratch, sourceProduct: "Codex", cutoff: nil,
            sourceTitle: "t", sourceModel: nil, target: .init(cli: "claude", session: "made-1"), targetModel: nil, folder: scratch,
            carried: .init(plan), written: rows)
        try HandoffRecords.save(record, history: [])
        let own = claudeRow("z1", rows.last, "user", "My own prompt.").replacingOccurrences(of: "\"s-1\"", with: "\"made-1\"")
        let made = try file("made.jsonl", lines.map(\.compact) + [own])
        let segment = try #require(HandoffFormats.read(made))
        #expect(segment.turns.map(\.prompt) == ["My own prompt."])
    }

    @Test func aThreadKoreMadeSkipsTheItemsItWasGiven() throws {
        // As Codex writes it: its start-up context, Kore's injected history, then the first turn.
        let lines = rollout([
            message("user", "<environment_context>\n</environment_context>"),
            ["type": "turn_context", "payload": ["turn_id": "auto-compact-1"]],
            message("developer", "The earlier part of this conversation ran in Claude Code."),
            message("user", "Check the build."),
            message("assistant", "Build 7781."),
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-9"]],
            ["type": "turn_context", "payload": ["turn_id": "turn-9"]],
            message("user", "What did we find?"),
            message("assistant", "Build 7781."),
        ]).map { $0.replacingOccurrences(of: "thread-1", with: "thread-made") }
        let plan = try plan
        let record = HandoffRecord(
            source: .init(cli: "claude", session: "s-1"), sourceFile: scratch, sourceProduct: "Claude Code", cutoff: nil,
            sourceTitle: "t", sourceModel: nil, target: .init(cli: "codex", session: "thread-made"), targetModel: nil,
            folder: scratch, carried: .init(plan))
        try HandoffRecords.save(record, history: [])
        let segment = try #require(HandoffFormats.read(try file("made-thread.jsonl", lines)))
        #expect(segment.turns.map(\.prompt) == ["What did we find?"])
    }

    @Test func aLongRolloutIsReadFromItsEndOnlyAsFarAsTheBudget() throws {
        var items: [[String: Any]] = []
        for n in 1...30 {
            items.append(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-\(n)"]])
            items.append(["type": "turn_context", "payload": ["turn_id": "turn-\(n)", "model": "fixture-model"]])
            items.append(message("user", "Prompt \(n) " + String(repeating: "x", count: 4000)))
            items.append(message("assistant", "Reply \(n)"))
        }
        let rollout = try file("long.jsonl", rollout(items))
        let whole = try #require(HandoffFormats.read(rollout))
        #expect(whole.turns.count == 30 && whole.earlier == 0)
        let read = try #require(HandoffFormats.read(rollout, window: 20_000))
        #expect(read.turns.count < 30)
        #expect(read.turns.last?.reply == "Reply 30")
        // The turns not read are counted, and the plan says so.
        #expect(read.turns.count + (read.earlier ?? -1) == 30)
        let plan = HandoffBudget.plan(read, window: 20_000)
        #expect(plan.notCarriedKnown && plan.carried + plan.notCarried == 30)
    }

    @Test func everyTextOfATurnIsCarriedInOrder() throws {
        let bash = { (id: String, command: String) -> [String: Any] in ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]] }
        let lines = [
            claudeRow("p1", nil, "user", "Is it ready?"),
            claudeRow("a1", "p1", "assistant", [["type": "text", "text": "All 20 hits are product wording."], bash("t1", "git status")]),
            claudeRow("r1", "a1", "user", [["type": "tool_result", "tool_use_id": "t1", "content": "clean"]]),
            claudeRow("a2", "r1", "assistant", [["type": "text", "text": "The landing check passed."]]),
            claudeRow(
                "n1", "a2", "user", "<task-notification><summary>done</summary></task-notification>",
                extra: ["isMeta": true, "turnOrigin": "task_notification"]),
            claudeRow("a3", "n1", "assistant", [["type": "text", "text": "The installed app is current."], bash("t2", "make install")]),
            claudeRow("r2", "a3", "user", [["type": "tool_result", "tool_use_id": "t2", "content": "installed"]]),
            claudeRow("a4", "r2", "assistant", [["type": "text", "text": "Installing now."]]),
        ]
        let segment = try #require(HandoffFormats.read(try file("texts.jsonl", lines)))
        #expect(segment.turns.count == 1)
        let turn = segment.turns[0]
        #expect(turn.steps.map(\.kind) == [.text, .command, .text, .text, .command])
        #expect(turn.steps.filter { $0.kind == .text }.map(\.output) == [
            "All 20 hits are product wording.", "The landing check passed.", "The installed app is current.",
        ])
        #expect(turn.reply == "Installing now.")
        // Codex gets one assistant message per text and per call, in order; shorter levels keep the last words.
        let blocks = HandoffRender.turn(turn, .full).assistant
        #expect(blocks.count == 6 && blocks[0] == "All 20 hits are product wording." && blocks[5] == "Installing now.")
        #expect(blocks[1].hasPrefix("[external_agent_tool_call: Bash]"))
        #expect(HandoffRender.turn(turn, .bare).assistant == ["Installing now."])
        #expect(!HandoffRender.turn(turn, .condensed).assistant.contains("The landing check passed."))

        let rolloutTexts = rollout([
            ["type": "turn_context", "payload": ["turn_id": "turn-1"]],
            message("user", "Is it ready?"),
            message("assistant", "First."),
            response(["type": "function_call", "name": "exec_command", "call_id": "c1", "arguments": "{\"cmd\":\"ls\"}"]),
            response(["type": "function_call_output", "call_id": "c1", "output": "Process exited with code 0"]),
            message("assistant", "Second."),
            message("assistant", "Last."),
        ])
        let codexTurn = try #require(HandoffFormats.read(try file("codex-texts.jsonl", rolloutTexts))?.turns.first)
        #expect(codexTurn.steps.map(\.kind) == [.text, .command, .text])
        #expect(codexTurn.reply == "Last.")
    }

    @Test func theSourceIsNamedAsHistoryNamesIt() throws {
        // An AI title from early on, then a rename: the rename is the name.
        let lines = [json(["type": "ai-title", "aiTitle": "An old summary", "sessionId": "s-1"])] + claude.dropLast()
            + [json(["type": "custom-title", "customTitle": "Kore (fork)", "sessionId": "s-1"])]
        let segment = try #require(HandoffFormats.read(try file("named.jsonl", lines)))
        #expect(segment.shownTitle == "Kore (fork)")
        let index = try file("session_index.jsonl", [
            json(["id": "thread-1", "thread_name": "First name"]), json(["id": "thread-2", "thread_name": "Another"]),
            json(["id": "thread-1", "thread_name": "Renamed"]),
        ])
        #expect(CodexRolloutFormat.threadName("thread-1", index: index) == "Renamed")
        #expect(CodexRolloutFormat.threadName("thread-9", index: index) == nil)
    }

    // MARK: Carrying what the target can take

    private func reply(_ uuid: String, _ parent: String, _ text: String) -> String {
        claudeRow(uuid, parent, "assistant", [["type": "text", "text": text]])
    }

    @Test func onlyTheHarnessTagsAreLeftOutAndACommandIsItsTurn() throws {
        let segment = try #require(HandoffFormats.read(try file("tags.jsonl", [
            claudeRow("u1", nil, "user", "<b>bold</b> is the idea"), reply("a1", "u1", "ok"),
            claudeRow("u2", "a1", "user", "<system-reminder>noise</system-reminder>"),
            claudeRow("u3", "u2", "user", "<command-name>/review</command-name><command-args>the fix</command-args>"),
            reply("a3", "u3", "reviewed"),
        ])))
        #expect(segment.turns.map(\.prompt) == ["<b>bold</b> is the idea", "/review the fix"])
    }

    @Test func oneHugeMessageIsCut() throws {
        var turn = HandoffTurn(id: "t", prompt: String(repeating: "word ", count: 60_000))
        turn.reply = "ok"
        let rendered = HandoffRender.turn(turn, .full)
        #expect(rendered.user.utf8.count < HandoffRender.messageChars + 200)
    }

    @Test func aTextDocumentComesInFullTurnsOnly() throws {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Read this"],
            ["type": "document", "title": "spec.md", "source": ["type": "text", "media_type": "text/plain", "data": "The spec says 42."]],
        ]
        let segment = try #require(HandoffFormats.read(try file("doc.jsonl", [claudeRow("u1", nil, "user", content), reply("a1", "u1", "ok")])))
        let turn = try #require(segment.turns.first)
        #expect(HandoffRender.turn(turn, .full).user.contains("The spec says 42."))
        #expect(!HandoffRender.turn(turn, .bare).user.contains("The spec says 42."))
        #expect(HandoffRender.turn(turn, .bare).user.contains("[document: spec.md]"))
    }

    @Test func aBackgroundAgentsResultIsItsStepsOutput() throws {
        let segment = try #require(HandoffFormats.read(try file("agent.jsonl", [
            claudeRow("u1", nil, "user", "Look into it"),
            claudeRow("a1", "u1", "assistant", [["type": "tool_use", "id": "t1", "name": "Agent", "input": ["description": "dig", "prompt": "dig", "run_in_background": true]]]),
            claudeRow("r1", "a1", "user", [["type": "tool_result", "tool_use_id": "t1", "content": "Async agent launched"]]),
            reply("a2", "r1", "Started it."),
            claudeRow("n1", "a2", "user", "<task-notification><task-id>x</task-id><tool-use-id>t1</tool-use-id><status>completed</status><result>Found the bug in parse()</result></task-notification>", extra: ["turnOrigin": "task_notification"]),
        ])))
        #expect(segment.turns.first?.steps.first?.output == "Found the bug in parse()")
    }

    @Test func whatACompactionKeptWordForWordIsCarriedAfterItsSummary() throws {
        let segment = try #require(HandoffFormats.read(try file("kept.jsonl", [
            claudeRow("u0", nil, "user", "Old work"), reply("a0", "u0", "done"),
            claudeRow("p1", "a0", "user", "Keep me"),
            json([
                "type": "system", "subtype": "compact_boundary", "uuid": "b1", "parentUuid": NSNull(), "sessionId": "s-1",
                "timestamp": "2026-10-20T09:00:05.000Z",
                "compactMetadata": ["preservedMessages": ["anchorUuid": "s1", "uuids": ["p1"], "allUuids": ["p1"]]],
            ]),
            claudeRow("s1", "b1", "user", "Summary text", extra: ["isCompactSummary": true]),
            claudeRow("u5", "s1", "user", "Next"), reply("a5", "u5", "ok"),
        ])))
        #expect(segment.summary == "Summary text")
        #expect(segment.turns.map(\.prompt) == ["Keep me", "Next"])
    }

    @Test func aChatFromAnotherFolderIsNamed() throws {
        var segment = HandoffSegment(source: "claude", product: "Claude Code", sessionId: "s")
        var turn = HandoffTurn(id: "t", prompt: "hi")
        turn.reply = "ok"
        segment.turns = [turn]
        segment.cwd = "/tmp/elsewhere-project"
        let plan = HandoffBudget.plan(segment, window: 200_000)
        #expect(HandoffRender.note(plan, folder: scratch).contains("/tmp/elsewhere-project"))
        #expect(HandoffRender.note(plan).contains("in this folder"))
    }
}

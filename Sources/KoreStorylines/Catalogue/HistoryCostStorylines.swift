import AppKit
import KoreCore
import KoreUI

/// Opening a long history, in-process: resuming a chat of many turns, then opening its heavy
/// sub-agent (hundreds of tool calls with long outputs) in its own tab, and scrolling each to its
/// top. Nothing is asserted; the times and the rows built go to `history.notes` in the run's
/// folder, so a change and the main it starts from are measured by the same code.
final class HistoryCost: Storyline {
    override class var tags: Set<Tag> { [.agents] }

    static let session = "history-cost"
    static let agent = "big"
    static let turns = 300
    static let agentTools = 400

    /// A tool's output: long enough to stand for a real one.
    static func output(_ i: Int) -> String {
        (0..<60).map { "line \($0) of output \(i): the command printed something worth a row of its own" }.joined(separator: "\n")
    }

    /// The resumed session: turns of a message, a few commands and an answer; the last one
    /// spawned the agent.
    static var history: [ChatEvent] {
        var events: [ChatEvent] = []
        for t in 0..<turns {
            let turn = "turn-\(t)"
            events.append(.userMessage(text: "Message \(t): look into the next part", attachments: [], id: "message-\(t)"))
            events.append(.turnStarted(turn, origin: .user, at: Date()))
            for c in 0..<6 {
                let id = "main-\(t)-\(c)"
                events.append(.toolStarted(ToolCall(id: id, name: "Bash", detail: "ls part-\(t)-\(c)", input: "ls part-\(t)-\(c)")))
                events.append(.toolFinished(id: id, output: output(c), isError: false))
            }
            if t == turns - 1 {
                events.append(.agentSpawned(AgentInfo(
                    id: agent, parent: .main, toolId: nil, name: "Read everything", type: nil, model: nil,
                    prompt: "Read every file and report.", background: false)))
                events.append(.agentFinished(id: agent, .completed, result: "Read them all."))
            }
            events.append(.text("answer-\(t)", .answer, DevNavProbe.sample(t)))
            events.append(.turnFinished(turn, .completed, duration: nil))
        }
        return events
    }

    /// The agent's own history: its commands, with a line of text every twenty.
    static var agentHistory: [ChatEvent] {
        var events: [ChatEvent] = []
        for i in 0..<agentTools {
            let id = "\(agent)-\(i)"
            events.append(.toolStarted(ToolCall(id: id, name: "Bash", detail: "cat file-\(i)", input: "cat file-\(i)"), agent: .sub(agent)))
            events.append(.toolFinished(id: id, output: output(i), isError: false, agent: .sub(agent)))
            if i % 20 == 19 { events.append(.text("\(agent)-text-\(i)", .answer, "Read \(i + 1) files so far.", agent: .sub(agent))) }
        }
        return events
    }

    override func steps() -> [any Step] {
        [OpenFolder(), UseScript(CLIScript(agents: [Self.agent: Self.agentHistory])), MeasureHistory()]
    }
}

struct MeasureHistory: Step {
    var label: String { "Measure resuming a long chat and opening its heavy agent" }
    var timeout: Duration? { .seconds(240) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        ScriptedWorld.shared.sessions[HistoryCost.session] = HistoryCost.history
        var lines: [String] = []
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func rows(_ prefix: String) -> Int { StoryRegistry.ids.count { $0.hasPrefix(prefix) } }

        // A resumed tab the CLI's list doesn't have is closed once the list is read: read it first.
        try await story.until("the folder's chats listed") { DevNavProbe.chatsListed(workspace) }

        // Resume: the chat's rows on screen, settled.
        let resumed = await DevNavProbe.open(workspace, ready: { rows("transcript.answer[") > 0 }) {
            workspace.open(SessionSummary(id: HistoryCost.session, agent: .claude, title: "Long", updated: .now))
        }
        try await story.idle()
        let chat = try story.activeChat()
        lines.append("resume: \(resumed.map { "\(f($0.ms)) ms, worst frame \(f($0.worst)) ms" } ?? "never settled"); "
            + "\(DevNavProbe.modelRows(chat).entries) entries, \(DevNavProbe.modelRows(chat).rows) row models, \(rows("transcript.")) transcript rows built")
        lines.append("resume page in: " + (await pageIn(workspace, rows: "transcript.")))
        let up = await DevNavProbe.scrollToTop(workspace)
        try await story.idle()
        lines.append("resume scroll up: \(Int(up.px)) px, frames \(up.frames), over 33 ms \(up.over33), worst \(f(up.worst)) ms; "
            + "\(DevNavProbe.modelRows(chat).rows) row models, \(rows("transcript.")) transcript rows built")

        // The agent's tab: its rows on screen, settled.
        let agentRows = "transcript.tool[\(HistoryCost.agent)-"
        let opened = await DevNavProbe.open(workspace, ready: { rows(agentRows) > 0 }) {
            DevNavProbe.openAgent(HistoryCost.agent, of: chat, in: workspace)
        }
        try await story.idle()
        lines.append("agent tab: \(opened.map { "\(f($0.ms)) ms, worst frame \(f($0.worst)) ms" } ?? "never settled"); "
            + "\(rows(agentRows)) of \(HistoryCost.agentTools) tool rows built")
        lines.append("agent page in: " + (await pageIn(workspace, rows: agentRows)))
        let agentUp = await DevNavProbe.scrollToTop(workspace)
        try await story.idle()
        lines.append("agent scroll up: \(Int(agentUp.px)) px, frames \(agentUp.frames), over 33 ms \(agentUp.over33), worst \(f(agentUp.worst)) ms; "
            + "\(rows(agentRows)) tool rows built")

        let text = lines.map { "\(story.name) \($0)" }.joined(separator: "\n") + "\n"
        try text.write(to: story.outputs.appendingPathComponent("history.notes"), atomically: true, encoding: .utf8)
    }

    /// Scrolls to 1.3 screens below the top, then up half a screen, which pages earlier turns in
    /// above (in an agent's tab, builds the rows above): a row on screen should move down by
    /// exactly what was scrolled, whatever went in above it (the lazy stack's height is partly
    /// estimated, so the row is what's measured). "off by" is what it missed by.
    @MainActor private func pageIn(_ workspace: Workspace, rows prefix: String) async -> String {
        guard let place = DevNavProbe.scrollPlace(workspace) else { return "no scroll view" }
        _ = await DevNavProbe.scrollUp(workspace, by: max(0, place.offset - 1.3 * place.visible))
        try? await Task.sleep(for: .milliseconds(300))
        guard let before = DevNavProbe.scrollPlace(workspace), let row = DevNavProbe.rowOnScreen(workspace, prefix: prefix) else {
            return "no row on screen"
        }
        let scrolled = await DevNavProbe.scrollUp(workspace, by: before.visible / 2)
        try? await Task.sleep(for: .milliseconds(300))
        guard let after = DevNavProbe.scrollPlace(workspace) else { return "no scroll view" }
        guard let y = DevNavProbe.rowY(row.id) else { return "the row went away" }
        return String(format: "content %.0f -> %.0f pt; scrolled %.0f, off by %.0f pt", before.height, after.height, scrolled, row.y - scrolled - y)
    }
}

/// Opening a very long Claude chat through the real backend: its transcript (KORE_LONG_CHAT, a
/// path; else a synthetic one of some 60 MB) is put in the run's Claude store and resumed, with
/// a CLI that never starts, so only reading the history counts. The time to its rows on screen,
/// settled, goes to `history.notes`.
final class LongChatOpen: Storyline {
    override class var tags: Set<Tag> { [.resume, .claude] }

    static let session = "6f1c1d1e-0000-4000-8000-00000000c0de"

    override func steps() -> [any Step] { [OpenFolder(), MeasureLongOpen()] }

    /// Turns of a prompt, a command with a long output and an answer, with lines no page reads
    /// (request bodies) between them, and a compaction `tail` turns before the end.
    static func synthetic(turns: Int, tail: Int) -> Data {
        var out = Data()
        var parent: String?
        func line(_ object: [String: Any]) {
            out += (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            out.append(0x0A)
        }
        let output = String(repeating: "a line of the command's output, long enough to weigh\n", count: 400)
        let body = String(repeating: "x", count: 60_000)
        for t in 0..<turns {
            let time = "2026-10-20T10:\(String(format: "%02d", t / 60 % 60)):\(String(format: "%02d", t % 60)).000Z"
            func entry(_ uuid: String, _ object: [String: Any]) {
                var object = object
                object["uuid"] = uuid
                object["parentUuid"] = parent ?? NSNull()
                object["timestamp"] = time
                object["sessionId"] = session
                object["isSidechain"] = false
                line(object)
                parent = uuid
            }
            if t == turns - tail {
                var boundary: [String: Any] = ["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"]
                boundary["logicalParentUuid"] = parent
                boundary["compactMetadata"] = ["trigger": "auto", "preTokens": 150_000]
                parent = nil
                entry("b-\(t)", boundary)
                entry("s-\(t)", ["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": "Summary of the work so far."]])
            }
            entry("u-\(t)", ["type": "user", "permissionMode": "default", "message": ["role": "user", "content": "Turn \(t): look at the next part"]])
            line(["type": "api-request", "sessionId": session, "params": ["body": body]])
            entry("a-\(t)", ["type": "assistant", "message": ["id": "m-\(t)", "role": "assistant", "content": [["type": "tool_use", "id": "t-\(t)", "name": "Bash", "input": ["command": "ls part-\(t)"]]]]])
            entry("r-\(t)", ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t-\(t)", "content": output]]]])
            entry("c-\(t)", ["type": "assistant", "message": ["id": "n-\(t)", "role": "assistant", "content": [["type": "text", "text": "Part \(t) is fine."]]]])
        }
        return out
    }
}

struct MeasureLongOpen: Step {
    var label: String { "Measure opening a very long Claude chat" }
    var timeout: Duration? { .seconds(240) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        guard let store = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] else { throw StoryFailure.other("no Claude store") }
        let project = URL(fileURLWithPath: store).appendingPathComponent("projects")
            .appendingPathComponent(CassettePaths.encoded(ClaudeTraces.realPath(story.folder.path)))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("\(LongChatOpen.session).jsonl")
        try? FileManager.default.removeItem(at: file)
        let source: String
        if let path = ProcessInfo.processInfo.environment["KORE_LONG_CHAT"] {
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: path))
            source = URL(fileURLWithPath: path).lastPathComponent
        } else {
            try LongChatOpen.synthetic(turns: 1000, tail: 40).write(to: file)
            source = "synthetic"
        }
        let bytes = ClaudeHistory.size(of: URL(fileURLWithPath: ClaudeTraces.realPath(file.path)))
        // The real backend, with a CLI that exits at once: the history is all that's read.
        let seams = StorylineSeams.backend
        let standIns = CLIExecutable.standIns.value
        StorylineSeams.backend = nil
        CLIExecutable.standIns.value = ["claude": .init(executable: URL(fileURLWithPath: "/usr/bin/false"))]
        defer {
            StorylineSeams.backend = seams
            CLIExecutable.standIns.value = standIns
        }
        try await story.until("the folder's chats listed") { DevNavProbe.chatsListed(workspace) }
        func rows() -> Int { StoryRegistry.ids.count { $0.hasPrefix("transcript.") } }
        let began = CACurrentMediaTime()
        var firstRows: Double?
        let opened = await DevNavProbe.open(workspace, ready: {
            let n = rows()
            if n > 0, firstRows == nil { firstRows = (CACurrentMediaTime() - began) * 1000 }
            return n > 0
        }) {
            workspace.open(SessionSummary(id: LongChatOpen.session, agent: .claude, title: "Long", updated: .now))
        }
        try await story.idle()
        let chat = try story.activeChat()
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let line = "\(story.name) open \(source) (\(bytes / 1_000_000) MB): first rows \(firstRows.map(f) ?? "never") ms, settled "
            + "\(opened.map { "\(f($0.ms)) ms, worst frame \(f($0.worst)) ms" } ?? "never"); "
            + "\(DevNavProbe.modelRows(chat).entries) entries, \(rows()) rows built\n"
        let url = story.outputs.appendingPathComponent("history.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

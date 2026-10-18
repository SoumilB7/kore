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

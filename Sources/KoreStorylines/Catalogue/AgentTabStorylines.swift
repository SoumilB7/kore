import AppKit
import KoreUI

/// An agent with a long brief and many commands, opened in its own tab: the timeline takes the
/// tab's whole height, the brief is its first row and scrolls away with the rest, and a long
/// brief shows its first lines with "Show full prompt" under it, as a long message does.
final class AgentTabLongPrompt: ChatStoryline {
    static let agent = "brief"
    static let prompt = (1...40).map { "Line \($0) of the brief: what to check, where to look and what to leave alone." }
        .joined(separator: "\n")

    override class var tags: Set<Tag> { [.chat, .agents, .gate] }
    override class var script: CLIScript {
        let commands: [Beat] = (1...40).flatMap { n -> [Beat] in
            let id = "brief-read-\(n)"
            return [
                .event(.toolStarted(ToolCall(id: id, name: "Read", detail: "notes-\(n).md", readOnly: true), agent: .sub(agent))),
                .event(.toolFinished(id: id, output: "notes \(n)", isError: false, agent: .sub(agent))),
            ]
        }
        return CLIScript(turns: [[
            .startTurn,
            .event(.agentSpawned(AgentInfo(
                id: agent, parent: .main, toolId: nil, name: "Read the notes", type: nil, model: nil, prompt: prompt, background: false))),
        ] + commands + [
            .event(.agentFinished(id: agent, .completed, result: "Read")),
            .stream(.answer, "The helper read the notes."),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Read the notes with a helper"), TurnFinished(1), WaitIdle(),
            Do("open the agent's tab") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
                DevNavProbe.openAgent(Self.agent, of: try story.activeChat(), in: workspace)
            },
            ExpectElement(.id(StoryID.AgentTab.crumb), .visible),
            // At the end, the brief has scrolled away with the rest: nothing holds the top.
            ExpectElement(.id(StoryID.AgentTab.end), .visible),
            ExpectElement(.id(StoryID.AgentTab.prompt), .absent),
            Scroll(.id(StoryID.AgentTab.end), to: .top),
            ExpectElement(.id(StoryID.AgentTab.prompt), .visible),
            ExpectElement(.id(StoryID.AgentTab.promptToggle), .visible),
            Expect("the brief folded to a few lines") { _ in
                guard let frame = StoryElement(StoryID.AgentTab.prompt)?.frame else { return false }
                return frame.height < 240  // eight lines, the toggle and the box's inset
            },
            Press(.id(StoryID.AgentTab.promptToggle)),
            Expect("the whole brief shown") { _ in
                guard let frame = StoryElement(StoryID.AgentTab.prompt)?.frame else { return false }
                return frame.height > 480  // forty lines
            },
        ]
    }
}

import Foundation
import KoreUI

/// The root turn finishes while a helper and then a shell continue. Its tab stays marked
/// while a new empty tab shows Kore's muted mark; an armed schedule alone never spins.
final class TabBackgroundWork: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents, .gate] }

    override class var script: CLIScript {
        let shell = ActiveCommand(id: "shell", kind: .shell, title: "Background shell", startedAt: .now, owner: .main)
        let later = ActiveCommand(id: "later", kind: .scheduled, title: "Scheduled check", startedAt: .now, owner: .main)
        return CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("scout", "Background scout", background: true), .finishTurn(.completed),
            .wait(.release), .event(.agentFinished(id: "scout", .completed, result: "Done")),
            .event(.commandStarted(shell)), .wait(.release), .event(.commandEnded(id: "shell", .completed, at: .now)),
            .event(.commandStarted(later)),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Start background work"), TurnFinished(1),
            ExpectElement(.tab(1).action(.working)),
            Press(.id(StoryID.Titlebar.newtab)),
            Expect("the empty tab's Kore mark") { story in
                guard let tab = story.app.workspace?.activeTab else { return false }
                return StoryElement(StoryID(.tabs, "empty", key: tab.id.uuidString)) != nil
            },
            ExpectElement(.tab(1).action(.working)),
            ExpectElement(.tab(2).action(.working), .absent), Snapshot("empty-tab-and-running-chat"),
            Do("Finish the helper and leave its shell running") { _ in ScriptedWorld.shared.backends.last?.release() },
            Expect("the background shell to start in the hidden chat") { story in
                story.events.contains { if case .commandStarted(let command) = $0.event { command.id == "shell" } else { false } }
            },
            ExpectElement(.tab(1).action(.working)),
            Do("Finish the shell, leaving only an armed schedule") { _ in ScriptedWorld.shared.backends.last?.release() },
            Expect("the armed schedule to arrive in the hidden chat") { story in
                story.events.contains { if case .commandStarted(let command) = $0.event { command.id == "later" } else { false } }
            },
            ExpectElement(.tab(1).action(.working), .absent),
            Press(.tab(1)),
            ExpectElement(.tab(1).action(.working), .absent),
        ]
    }
}

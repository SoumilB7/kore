import Foundation
import KoreUI
import src

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
            // Only the shell runs now: ">_" in the spinner's place.
            ExpectElement(.tab(1).action(.background)),
            ExpectElement(.tab(1).action(.working), .absent),
            Do("Finish the shell, leaving only an armed schedule") { _ in ScriptedWorld.shared.backends.last?.release() },
            Expect("the armed schedule to arrive in the hidden chat") { story in
                story.events.contains { if case .commandStarted(let command) = $0.event { command.id == "later" } else { false } }
            },
            ExpectElement(.tab(1).action(.working), .absent),
            ExpectElement(.tab(1).action(.background), .absent),
            Press(.tab(1)),
            ExpectElement(.tab(1).action(.working), .absent),
        ]
    }
}

/// bg-command-cue.html C: a build outlives its turn. The tab's spinner becomes ">_" while only
/// the build runs, takes the amber point while an approval waits beside it, and the logo comes
/// back once the build ends. One scripted run per CLI (`--provider claude|codex`).
final class TabBackgroundPromptStates: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    static let card = Approval(id: "ls1", title: "Run ls -la", detail: "List the folder", body: "ls -la", canAlwaysAllow: false, questions: [])

    override class var script: CLIScript {
        let build = ActiveCommand(id: "build", kind: .shell, title: "npm run build", startedAt: .now, owner: .main)
        return CLIScript(turns: [
            [.startTurn, .event(.commandStarted(build)), .wait(.release), .finishTurn(.completed)],
            [.startTurn, .approval(card, allow: Beat.answer("Listed."), deny: []), .finishTurn(.completed),
             .wait(.release), .event(.commandEnded(id: "build", .completed, at: .now))],
        ])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Start the build in the background"),
            ExpectElement(.tab(1).action(.working)),
            ExpectElement(.tab(1).action(.background), .absent),
            Snapshot("1-working"),
            Do("End the turn, leaving the build running") { _ in ScriptedWorld.shared.backends.last?.release() },
            TurnFinished(1),
            ExpectElement(.tab(1).action(.background)),
            ExpectElement(.tab(1).action(.working), .absent),
            ExpectElement(.tab(1).action(.needsYou), .absent),
            Snapshot("2-background-only"),
            Send("List the folder"),
            ExpectElement(.id(StoryID.Approval.card("ls1").part(.allow))),
            ExpectElement(.tab(1).action(.background)),
            ExpectElement(.tab(1).action(.needsYou)),
            Snapshot("3-background-needs-you"),
            Press(.id(StoryID.Approval.card("ls1").part(.allow))),
            TurnFinished(2),
            ExpectElement(.tab(1).action(.needsYou), .absent),
            ExpectElement(.tab(1).action(.background)),
            Do("End the build") { _ in ScriptedWorld.shared.backends.last?.release() },
            Expect("the build to end") { story in
                story.events.contains { if case .commandEnded(let id, _, _) = $0.event { id == "build" } else { false } }
            },
            ExpectElement(.tab(1).action(.background), .absent),
            ExpectElement(.tab(1).action(.working), .absent),
            Snapshot("4-done"),
        ]
    }
}

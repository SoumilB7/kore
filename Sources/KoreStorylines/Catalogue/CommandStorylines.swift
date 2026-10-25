import AppKit
import KoreCore
import KoreUI

/// A command the chat leaves running in the background: the Agents button counts it (">_ 1",
/// with no agents to show), the map opens on the chat's own BACKGROUND, and its Stop asks first
/// (Cancel leaves it running); Stop goes to the CLI, and the row ends stopped.
final class BackgroundCommandStopped: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    static let id = "dev"

    /// Claude names it; Codex has only the command.
    static func script(title: String) -> CLIScript {
        let command = ActiveCommand(
            id: id, kind: .shell, title: title, command: "npm run dev -- --port 5173", folder: "/tmp", startedAt: Date(), owner: .main,
            toolId: "call-dev", output: .stream)
        return CLIScript(turns: [
            [.startTurn, .event(.commandStarted(command)), .stream(.answer, "The dev server runs."), .finishTurn(.completed)]
        ])
    }

    override class var script: CLIScript { script(title: "Run the dev server") }

    override func steps() -> [any Step] {
        let row = StoryID.AgentMap.command(Self.id)
        return [UseScript(Self.script(title: "npm run dev -- --port 5173"), for: "codex")] + super.steps() + [
            Send("Start the dev server"), TurnFinished(1), WaitIdle(),
            Expect("one live command", found: Self.found) { try $0.activeChat().storyLiveCommands == 1 },
            ExpectElement(.id(StoryID.Titlebar.commands), .visible),
            Press(.id(StoryID.Titlebar.commands)),
            Expect("the agent map open") { try $0.activeChat().isAgentMapOpen },
            ExpectElement(.id(row), .visible),
            Press(.id(row)),
            Snapshot("background-opened"),
            Press(.id(row.part(.stop))),
            ExpectElement(.id(row.part(.allow)), .visible),
            Snapshot("stop-confirm"),
            Press(.id(row.part(.cancel))),
            ExpectElement(.id(row.part(.allow)), .absent),
            Expect("still running after Cancel") { try $0.activeChat().storyLiveCommands == 1 },
            Press(.id(row.part(.stop))),
            Press(.id(row.part(.allow))),
            Expect("the stop sent to the CLI") { try $0.scriptedBackend().log.contains(.stopCommand(Self.id)) },
            Expect("the row stopped, nothing live", found: Self.found) { story in
                let chat = try story.activeChat()
                return chat.storyLiveCommands == 0 && chat.storyBackground.first?.contains(" · stopped · main") == true
            },
            ExpectElement(.id(row.part(.stop)), .absent),
        ]
    }

    static func found(_ story: StoryContext) -> String? { (try? story.activeChat().storyBackground)?.joined(separator: " | ") }
}

/// A command that outlives the agent that started it: the agent ends, the command doesn't, and
/// the one line at the tree's foot says so; it opens the Still running pane with that row.
final class CommandOutlivesItsAgent: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }

    static func script(title: String) -> CLIScript {
        let command = ActiveCommand(
            id: "watch", kind: .shell, title: title, command: "tail -F logs/staging.err", folder: "/tmp", startedAt: Date(),
            owner: .sub("watcher"), toolId: "call-watch")
        return CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("watcher", "Watch the staging logs"), .event(.commandStarted(command)),
                .event(.agentFinished(id: "watcher", .completed, result: "Watching")), .stream(.answer, "The watch goes on."),
                .finishTurn(.completed),
            ]
        ])
    }

    override class var script: CLIScript { script(title: "Watch staging errors") }

    override func steps() -> [any Step] {
        [UseScript(Self.script(title: "tail -F logs/staging.err"), for: "codex")] + super.steps() + [
            Send("Watch the logs"), TurnFinished(1), WaitIdle(),
            Expect("one command outlived its agent", found: BackgroundCommandStopped.found) { try $0.activeChat().storyOutlivedCommands == 1 },
            Press(.id(StoryID.Titlebar.commands)),
            ExpectElement(.id(StoryID.AgentMap.outlived), .visible),
            Press(.id(StoryID.AgentMap.outlived)),
            ExpectElement(.id(StoryID.AgentMap.command("watch")), .visible),
            ExpectElement(.id(StoryID.AgentMap.command("watch").part(.stop)), .visible),
            Snapshot("still-running"),
        ]
    }
}

/// A chat read back after Kore restarted: its history's commands, rebuilt by each CLI's own
/// translator, are all finished (one with no recorded end reads "ended"), so nothing is live:
/// no Agents button, no mark, no foot line.
final class ReplayedCommandsEnded: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    static let folder = URL(fileURLWithPath: "/tmp")

    override class var script: CLIScript { CLIScript(start: [.controls(), .event(.replayed(claudeHistory()))]) }

    static var codexScript: CLIScript { CLIScript(start: [.controls(), .event(.replayed(codexHistory()))]) }

    /// Two background commands: one finished as its notification says, one with no end recorded.
    static func claudeHistory() -> [ChatEvent] {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-21T10:00:00.000Z","message":{"role":"user","content":"Start them."}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-21T10:00:01.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call-1","name":"Bash","input":{"command":"sleep 5","description":"Short wait","run_in_background":true}},{"type":"tool_use","id":"call-2","name":"Bash","input":{"command":"npm run dev","description":"Dev server","run_in_background":true}}]}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-10-21T10:00:02.000Z","toolUseResult":{"backgroundTaskId":"b1"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-1","content":"Command running in background with ID: b1."}]}}"#,
            #"{"type":"user","uuid":"r2","timestamp":"2026-10-21T10:00:02.000Z","toolUseResult":{"backgroundTaskId":"b2"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-2","content":"Command running in background with ID: b2."}]}}"#,
            #"{"type":"user","uuid":"n1","timestamp":"2026-10-21T10:00:07.000Z","turnOrigin":"task_notification","message":{"role":"user","content":"<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>call-1</tool-use-id>\n<status>completed</status>\n<summary>Background command \"Short wait\" completed (exit code 0)</summary>\n</task-notification>"}}"#,
        ]
        let messages = lines.compactMap { try? JSONValue.parse(Data($0.utf8)) }
        return ClaudeTranslator(folder: folder, sessionId: "replayed").replay(messages)
    }

    /// A turn whose command ran on after it, as a thread records it once ended.
    static func codexHistory() -> [ChatEvent] {
        let turn =
            #"{"id":"t1","status":"completed","startedAt":1792874894,"durationMs":2000,"items":[{"type":"userMessage","id":"u","content":[{"type":"text","text":"Start it"}]},{"type":"commandExecution","id":"long","command":"/bin/zsh -lc 'sleep 7; echo finished'","cwd":"/tmp","status":"completed","processId":"2","exitCode":0,"durationMs":6933}]}"#
        let turns = [(try? JSONValue.parse(Data(turn.utf8))) ?? .null]
        return CodexTranslator(folder: folder).replay(turns)
    }

    override func steps() -> [any Step] {
        [UseScript(Self.codexScript, for: "codex")] + super.steps() + [
            WaitIdle(),
            Expect("the history's commands, all finished", found: BackgroundCommandStopped.found) { story in
                let chat = try story.activeChat()
                return !chat.storyBackground.isEmpty && chat.storyBackground.allSatisfy { !$0.contains(" · running · ") }
            },
            Expect("nothing live") { try $0.activeChat().storyLiveCommands == 0 },
            ExpectElement(.id(StoryID.Titlebar.commands), .absent),
        ]
    }
}

/// The account changes while a command the chat left runs (a dev server): the CLI isn't started
/// again under it, so it keeps running; once it ends, the CLI starts again as the new account.
final class AccountChangeWaitsForCommands: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }

    override class var script: CLIScript {
        let command = ActiveCommand(
            id: "dev", kind: .shell, title: "Run the dev server", command: "npm run dev", folder: "/tmp", startedAt: Date(), owner: .main)
        return CLIScript(turns: [
            [
                .startTurn, .event(.commandStarted(command)), .stream(.answer, "The dev server runs."), .finishTurn(.completed),
                .wait(.release), .event(.commandEnded(id: "dev", .completed, at: Date())),
            ]
        ])
    }

    override func steps() -> [any Step] {
        let relaunches = { (story: StoryContext) in try story.scriptedBackend().log.filter { $0 == .relaunch }.count }
        return super.steps() + [
            Send("Start the dev server"), TurnFinished(1), WaitIdle(),
            Expect("one live command") { try $0.activeChat().storyLiveCommands == 1 },
            Expect("the account changes elsewhere") { story in
                try story.activeChat().storyAccountChanged()
                return true
            },
            WaitIdle(),
            Expect("no start again while it runs", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 0 },
            Expect("still running") { try $0.activeChat().storyLiveCommands == 1 },
            Release(),
            Expect("the CLI started again once it ended", found: { try? "\(relaunches($0)) relaunches" }) { story in
                try story.activeChat().storyLiveCommands == 0 && relaunches(story) == 1
            },
        ]
    }
}

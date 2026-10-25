import AppKit
import KoreCore
import KoreUI

/// A real PTY survives chat-tab changes and panel hiding, follows native sizing and ends when
/// its window closes. The explorer stays outside the split, full height.
final class WindowTerminal: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals() },
            Key(.ctrl("`")),
            ExpectElement(.id(StoryID.Terminal.panel), .visible),
            Expect("a shell focused in the window's folder") { $0.app.workspace?.storyTerminal.focused == true },
            TypeText("pwd -P > terminal-cwd; printf 'directory:ok\\n'"), Key(.returnKey),
            Expect("the shell starts in this folder") { story in
                guard let cwd = try? String(contentsOf: story.folder.appendingPathComponent("terminal-cwd"), encoding: .utf8) else { return false }
                return URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
                    == story.folder.resolvingSymlinksInPath().path
            },
            Key(.ctrl("`")), ExpectElement(.id(StoryID.Terminal.panel), .absent),
            TypeText("draft after terminal"),
            Expect("hiding returns typing to the chat") { try $0.activeChat().draft == "draft after terminal" },
            Command(.newTab), Key(.ctrl("`")),
            Expect("the same shell after switching tabs") { $0.app.workspace?.storyTerminal.count == 1 },
            Expect("the output survives hiding") { $0.app.workspace?.storyTerminal.text.contains("directory:") == true },
            Key(KeyChord(.character("`"), [.control, .shift])),
            Expect("two shells in the same panel") { $0.app.workspace?.storyTerminal.count == 2 },
            Command(.toggleExplorer),
            TerminalResize(),
            Press(.id(StoryID.Terminal.maximize)),
            Expect("terminal maximized") { $0.app.workspace?.storyTerminalMaximized == true },
            Snapshot("terminal-explorer-maximized"),
            Press(.id(StoryID.Terminal.maximize)),
            Expect("terminal restored") { $0.app.workspace?.storyTerminalMaximized == false },
            Snapshot("terminal-explorer"),
            Do("Resize the window with the explorer docked") { $0.window?.setContentSize(CGSize(width: 760, height: 540)) },
            WaitIdle(),
            Expect("the terminal stays beside the explorer and inside the window") { story in
                guard let panel = StoryElement(StoryID.Terminal.panel)?.frame,
                      let explorer = StoryElement(StoryID.Explorer.newfile)?.frame,
                      let width = story.window?.contentView?.bounds.width else { return false }
                return panel.minX >= explorer.maxX && panel.maxX <= width + 1 && panel.maxY < explorer.minY
            },
            Snapshot("terminal-compact-window"),
            Press(.id(StoryID.Terminal.close)),
            Expect("closing one terminal keeps the other shell") { $0.app.workspace?.storyTerminal.count == 1 },
            TerminalWindowCloses(),
        ]
    }
}

/// Opening an agent's command from Agents watches it without typing into the CLI; Stop goes
/// through its owning chat. A finished command opens safely prepared in a fresh shell.
final class AgentCommandTerminal: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents, .gate] }
    static let liveID = "terminal-live"
    static let endedID = "terminal-ended"
    override class var script: CLIScript {
        let live = ActiveCommand(id: liveID, kind: .shell, title: "Watch a command", command: "sleep 30", startedAt: .now,
                                 owner: .main, output: .stream)
        let ended = ActiveCommand(id: endedID, kind: .shell, title: "Create a file", command: "/usr/bin/touch terminal-should-not-run",
                                  startedAt: .now, owner: .main, output: .stream)
        return CLIScript(turns: [[.startTurn, AgentMapStories.spawn("helper", "Check the command"),
                                 .event(.agentFinished(id: "helper", .completed, result: "Checked")), .event(.commandStarted(live)), .event(.commandOutput(id: liveID, "Ready to watch\n")),
                                 .event(.commandStarted(ended)), .event(.commandEnded(id: endedID, .completed, at: .now)),
                                 .stream(.answer, "The command is running."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals() },
            Send("Run the commands"), TurnFinished(1),
            Press(.id(StoryID.Titlebar.commands)),
            Press(.id(StoryID.AgentMap.command(Self.liveID).part(.open))),
            ExpectElement(.id(StoryID.Terminal.panel), .visible),
            Do("Make the offscreen test terminal readable") { $0.app.workspace?.storyTerminalVisible() },
            Expect("a read-only command output") { $0.app.workspace?.storyTerminal.shell == false },
            Expect("the map closes and shows the live output") {
                try !$0.activeChat().isAgentMapOpen && $0.app.workspace?.storyTerminal.text.contains("Ready to watch") == true
            },
            Expect("the read-only terminal owns keyboard focus") { $0.app.workspace?.storyTerminal.focused == true },
            TypeText("do not send"),
            Expect("typing never reaches the output") { $0.app.workspace?.storyTerminal.text.contains("do not send") == false },
            Press(.id(StoryID.Terminal.stop)),
            Expect("stop goes to the owning CLI") { try $0.scriptedBackend().log.contains(.stopCommand(Self.liveID)) },
            Press(.id(StoryID.Titlebar.agents)),
            Press(.id(StoryID.AgentMap.chat)),
            Press(.id(StoryID.AgentMap.doneCommands)),
            Press(.id(StoryID.AgentMap.command(Self.endedID).part(.open))),
            Expect("a fresh shell with the command prepared") {
                $0.app.workspace?.storyTerminal.shell == true && $0.app.workspace?.storyTerminal.count == 2
                    && $0.app.workspace?.storyTerminal.text.contains("terminal-should-not-run") == true
            },
            Expect("opening an ended command never executes it") {
                !FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("terminal-should-not-run").path)
            },
            Expect("the prepared shell owns keyboard focus") { $0.app.workspace?.storyTerminal.focused == true },
            ExpectElement(.id(StoryID.AgentMap.close), .absent),
            Do("Paint the offscreen native terminal") { $0.app.workspace?.storyPaintTerminal() },
            Snapshot("ended-command-prepared"),
            Key(.returnKey),
            Expect("the prepared command runs only on Return", found: { "focused=\($0.app.workspace?.storyTerminal.focused ?? false) screen=" + ($0.app.workspace?.storyTerminal.text ?? "") }) {
                FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("terminal-should-not-run").path)
            },
        ]
    }
}

private struct TerminalWindowCloses: Step {
    var label: String { "Closing the window ends even hidden shells" }
    func run(_ story: StoryContext) async throws {
        let children = story.app.workspace?.storyTerminalChildren ?? []
        guard !children.isEmpty else { throw StoryFailure.other("no PTY children to close") }
        story.window?.performClose(nil)
        try await story.until("the window's shells end") { children.allSatisfy { !$0.alive } }
    }
}

private struct TerminalResize: Step {
    var label: String { "Drag the terminal sash upward" }
    func run(_ story: StoryContext) async throws {
        let sash = try await story.element(.id(StoryID.Terminal.sash))
        guard let frame = sash.frame, let window = story.window else { throw StoryFailure.other("no terminal sash") }
        let height = story.app.workspace?.storyTerminalHeight ?? 0
        let start = CGPoint(x: frame.midX, y: frame.midY)
        await story.input.drag(from: start, to: CGPoint(x: start.x, y: start.y + 80), in: window)
        do {
            try await story.until("the terminal grows as its sash moves") { (story.app.workspace?.storyTerminalHeight ?? 0) > height + 40 }
        } catch {
            throw StoryFailure.expectation("terminal sash: height \(height) → \(story.app.workspace?.storyTerminalHeight ?? 0), frame=\(frame), key=\(window.isKeyWindow)")
        }
    }
}

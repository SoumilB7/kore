import AppKit
import KoreUI

/// Real pointer paths open themed menus; keyboard selection, control-click, native text and
/// status pickers all use the same surface. No filesystem action leaves this run's folder.
final class ThemedOptions: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .files, .gate] }
    override func steps() -> [any Step] {
        [WriteFiles([("menu.txt", "hello from the editor\n"), ("other.txt", "another file\n")])] + super.steps() + [
            Command(.toggleExplorer), WaitForElement(.treeRow("menu.txt")),
            RightClick(.treeRow("menu.txt")), WaitForElement(.id(StoryID.Options.panel)),
            Snapshot("explorer-options"),
            LeadingContextClick(StoryID.Explorer.row("other.txt")), WaitForElement(.id(StoryID.Options.panel)),
            Press(.id(StoryID.Options.item(8))),
            Expect("the second row owns the replacement menu") { _ in NSPasteboard.general.string(forType: .string) == "other.txt" },
            RightClick(.treeRow("menu.txt")), WaitForElement(.id(StoryID.Options.panel)),
            Key(.down), Key(.down), Key(.down), Key(.returnKey),
            Expect("keyboard chose Open") { $0.app.workspace?.storyActiveFile == "menu.txt" },
            Expect("the menu Return did not edit the file") { $0.app.workspace?.storyEditor?.text == "hello from the editor\n" },
            ExpectElement(.id(StoryID.Options.panel), .absent),
            Click(.treeRow("menu.txt"), modifiers: .control), WaitForElement(.id(StoryID.Options.panel)),
            Key(.escape), ExpectElement(.id(StoryID.Options.panel), .absent),
            // The editor's own native menu is presented using Kore's surface too.
            RightClick(.editor), WaitForElement(.id(StoryID.Options.panel)),
            Snapshot("editor-text-options"), Key(.escape),
            Press(.id(StoryID.Editor.Status.indent)), WaitForElement(.id(StoryID.Options.panel)),
            Key(.down), Key(.returnKey), ExpectElement(.id(StoryID.Options.panel), .absent),
            Expect("the picker Return did not edit the file") { $0.app.workspace?.storyEditor?.text == "hello from the editor\n" },
            RightClick(.treeRow("menu.txt")), WaitForElement(.id(StoryID.Options.panel)),
            Click(.editor), ExpectElement(.id(StoryID.Options.panel), .absent),
            Expect("Terminal is a top-level menu with both commands") { _ in
                let top = NSApp.mainMenu?.items.first { $0.title == "Terminal" }
                return top?.submenu?.items.contains { $0.title == "New Terminal" } == true
                    && top?.submenu?.items.contains { $0.title == "Show / Hide Terminal" } == true
            },
        ]
    }
}

/// A closed command's two-line header is selectable before its output box is expanded.
final class SelectCommandHeader: ChatStoryline {
    static let command = "printf 'hello from the command'"
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: command, output: "hello from the command"),
                          .stream(.answer, "Done."), .finishTurn(.completed)], CLIScript.reply("Next.")])
    }
    override func steps() -> [any Step] {
        super.steps() + [
            Send("Run it"), TurnFinished(1), Send("Next"), TurnFinished(2), Press(.fold(turn: 1)),
            DragSelect(from: Spot(row: .tool("Bash"), path: [-1], offset: 5),
                       to: Spot(row: .tool("Bash"), path: [-1], offset: 5 + Self.command.utf16.count)),
            CopySelection(Self.command), Snapshot("selected-command"),
            Expect("the header selected without opening the output box") { story in
                let transcript = try story.activeChat().storyTranscript
                let paths = transcript.selectableTexts(try Spot.tool("Bash").entry(story))
                return paths.contains([-1]) && !paths.contains([0])
            },
            ClickText(Spot(row: .tool("Bash"), path: [-1], offset: 7), count: 2),
            CopySelection("printf"),
            Do("Clear the copy receipt") { _ in StoryTranscript.clearCopied() },
            ControlClickCommand(), WaitForElement(.id(StoryID.Options.panel)),
            Key(.down), Key(.returnKey),
            Expect("control-click Copy keeps the selected command word") { _ in StoryTranscript.copied == "printf" },
        ]
    }
}

private struct ControlClickCommand: Step {
    var label: String { "Control-click the selected command" }
    func run(_ story: StoryContext) async throws {
        let (window, point) = try await Spot(row: .tool("Bash"), path: [-1], offset: 7).point(story)
        await story.input.click(at: point, in: window, modifiers: .control)
    }
}

/// The first menu covers the next row's centre; use its exposed leading edge.
private struct LeadingContextClick: Step {
    let id: StoryID
    init(_ id: StoryID) { self.id = id }
    var label: String { "Control-click the next row outside the open menu" }
    func run(_ story: StoryContext) async throws {
        guard let element = StoryElement(id), let window = element.window, let frame = element.frame else {
            throw StoryFailure.expectation("the next explorer row")
        }
        await story.input.click(at: CGPoint(x: frame.minX + 8, y: frame.midY), in: window, modifiers: .control)
    }
}

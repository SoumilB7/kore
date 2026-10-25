import KoreUI

/// A menu command of the storyline's window, run as the menu runs it (`Workspace.perform`):
/// "New tab", "Go to file". The menu reaches only the focused window, and a storyline's window
/// isn't focused, so this covers what the command does, not its shortcut's wiring; storylines
/// tagged `realinput` press the real shortcuts.
package struct Command: Step {
    let command: WorkspaceCommand
    package var label: String {
        switch command {
        case .newTab: "New tab"
        case .newBoard: "New board"
        case .closeTab: "Close the tab"
        case .reopenClosedTab: "Reopen the closed tab"
        case .nextTab: "Show the next tab"
        case .previousTab: "Show the previous tab"
        case .moveTabRight: "Move the tab right"
        case .moveTabLeft: "Move the tab left"
        case .save: "Save the file"
        case .saveAll: "Save all files"
        case .goToFile: "Go to file"
        case .goToLine: "Go to line"
        case .toggleExplorer: "Show or hide the explorer"
        case .search: "Search the folder"
        case .reloadTab: "Reload the tab"
        case .reload: "Reload the window"
        case .stop: "Stop the chat"
        }
    }
    package init(_ command: WorkspaceCommand) { self.command = command }

    package func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
        guard workspace.can(command) else { throw StoryFailure.expectation("“\(label)” to be available (its menu item is disabled)") }
        workspace.perform(command)
        try await story.idle()
    }
}

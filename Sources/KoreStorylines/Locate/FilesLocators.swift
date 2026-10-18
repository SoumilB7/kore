import KoreUI

// Locators for the explorer and the editor (phase 12, §3). Paths are relative to the folder;
// lines are counted from 1, as the editor shows them (the ids hold 0-based lines).

extension Locator {
    /// The explorer's row for a file or folder. Its folders open down to it when it isn't
    /// built, as Reveal in Explorer does (which also selects it).
    package static func treeRow(_ path: String) -> Locator {
        Locator(
            "the tree row “\(path)”",
            key: { app in
                guard let workspace = app.workspace else { return .failure(LocatorMiss("no workspace")) }
                guard workspace.explorerOpen else { return .failure(LocatorMiss("the tree row “\(path)”: the explorer is closed")) }
                guard workspace.storyHasFile(path) else { return .failure(LocatorMiss("the tree row “\(path)”: no such file in the folder")) }
                return .success(StoryID.Explorer.row(path))
            },
            reveal: { app in app.workspace?.storyRevealInTree(path) })
    }

    /// The active file's text view.
    package static var editor: Locator {
        Locator("the editor") { app in
            guard let path = app.workspace?.storyActiveFile else { return .failure(LocatorMiss("the editor: the active tab isn't a file")) }
            return .success(StoryID.Editor.text(path))
        }
    }

    /// The gutter's fold chevron on a line of the active file (registered whether it's drawn
    /// or not: it only shows while the pointer is over the gutter).
    package static func gutterChevron(line: Int) -> Locator {
        editorLine("the fold chevron on line \(line)", line) { workspace, index in
            if workspace.storyCanFold(line: index) { return .success(StoryID.Editor.gutterFold(index)) }
            return .failure(LocatorMiss("line \(line) doesn't fold", pending: !workspace.storyFoldsReady))
        }
    }

    /// The " ⋯ " chip after a folded line of the active file.
    package static func foldChip(line: Int) -> Locator {
        editorLine("the fold chip on line \(line)", line) { workspace, index in
            if workspace.storyIsFolded(line: index) { return .success(StoryID.Editor.foldChip(index)) }
            return .failure(LocatorMiss("line \(line) isn't folded"))
        }
    }

    private static func editorLine(
        _ description: String, _ line: Int, _ key: @escaping @MainActor (Workspace, Int) -> Result<StoryID, LocatorMiss>
    ) -> Locator {
        Locator(
            description,
            key: { app in
                guard let workspace = app.workspace, workspace.storyActiveFile != nil else {
                    return .failure(LocatorMiss("\(description): the active tab isn't a file"))
                }
                guard let count = workspace.storyLineCount else {
                    return .failure(LocatorMiss("\(description): the file isn't loaded as text", pending: true))
                }
                guard (1...max(count, 1)).contains(line) else { return .failure(LocatorMiss("\(description): the file has \(count) lines")) }
                return key(workspace, line - 1)
            },
            reveal: { app in app.workspace?.storyScrollEditor(toLine: line - 1) })
    }
}

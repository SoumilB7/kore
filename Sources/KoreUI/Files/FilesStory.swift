import AppKit
import KoreCore

/// The folder window's files as a storyline reads them (phase 12, §3): which files exist, the
/// active file and its folds, and how to bring a tree row or an editor line into view from the
/// model side. Only the storyline host uses it.
extension Workspace {
    /// The active file tab's path, relative to the folder.
    package var storyActiveFile: String? { activeFile.map { relativePath($0.path) } }

    package func storyHasFile(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relativePath).path)
    }

    /// Opens the tree's folders down to the item and selects it, as Reveal in Explorer does.
    package func storyRevealInTree(_ relativePath: String) {
        let store = filesStore()
        let path = realPath(folder.appendingPathComponent(relativePath).path)
        Task { await store.reveal(path) }
    }

    /// The active file's line count; nil when it isn't a text file shown in the editor.
    package var storyLineCount: Int? {
        guard let file = activeFile, file.isText, file.loaded else { return nil }
        return file.editor.lines.count
    }

    /// Whether a line (0-based) of the active file starts a region that folds, or a fold.
    package func storyCanFold(line: Int) -> Bool {
        guard let editor = activeFile?.editor else { return false }
        return editor.regions.end(of: line) != nil || editor.fold(startingOn: line) != nil
    }

    /// The active file's fold regions are worked out (they're found off the main thread).
    package var storyFoldsReady: Bool { activeFile?.editor.regionsPending == nil }

    package func storyIsFolded(line: Int) -> Bool { activeFile?.editor.fold(startingOn: line) != nil }

    /// Scrolls the active file's editor so a line (0-based) is on screen, leaving the caret.
    package func storyScrollEditor(toLine line: Int) {
        guard let editor = activeFile?.editor, line < editor.lines.count else { return }
        let text = editor.textView
        text.scrollRangeToVisible(NSRange(location: editor.lines.start(of: line), length: 0))
    }
}

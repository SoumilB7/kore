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

    // MARK: Checks

    /// The active file's editor as a storyline checks it; nil when the active tab isn't a text
    /// file that has loaded.
    package var storyEditor: StoryEditor? {
        guard let file = activeFile, file.isText, file.loaded else { return nil }
        let editor = file.editor
        let lines = editor.lines
        var hidden: [Int] = []
        for fold in editor.folds {
            let first = lines.line(at: fold.location)
            let last = lines.line(at: NSMaxRange(fold))
            if last > first { hidden += (first + 1...last).filter { editor.hiddenFold(line: $0) != nil }.map { $0 + 1 } }
        }
        let find = editor.find
        return StoryEditor(
            path: relativePath(file.path), text: file.storage.string, isDirty: file.isDirty, caretLine: file.caret.line,
            hiddenLines: hidden, foldCount: editor.folds.count,
            find: find.isOpen
                ? StoryEditor.Find(
                    query: find.query, showsReplace: find.showReplace, label: find.countLabel,
                    matchLines: find.matches.map { lines.line(at: $0.location) + 1 })
                : nil)
    }

    /// The window's file tabs, left to right.
    package var storyFileTabs: [StoryFileTab] {
        tabs.compactMap { tab in
            tab.file.map { StoryFileTab(path: relativePath($0.path), preview: tab.isPreview, active: tab.id == activeID) }
        }
    }

    /// The renderer showing the active file ("html", "markdown"…); nil for the editor.
    package var storyActiveRenderer: String? {
        guard let rendering = activeFile?.rendering, rendering.showsRenderer else { return nil }
        return rendering.renderer?.id
    }

    /// Quick open's file list is showing (⌘P).
    package var storyQuickOpenShown: Bool { quickOpen == .files }

    /// The sidebar shows Search.
    package var storySearchShown: Bool { explorerOpen && sidebar == .search }

    /// Search's results so far, and whether the search is still going; nil before Search shows.
    package var storySearch: StorySearch? {
        guard let search else { return nil }
        let hits = search.results.flatMap { file in file.hits.map { StorySearch.Hit(path: search.relative(file.path), line: $0.line) } }
        let finished = search.searched == search.text && search.outcome != .running
        return StorySearch(query: search.text, finished: finished, hits: hits)
    }

    /// Brings a search result's row into the list (its file's group opened), as moving the
    /// selection onto it does.
    package func storyRevealSearchHit(_ relativePath: String, line: Int) {
        guard let search else { return }
        let path = search.root + "/" + relativePath
        search.collapsed.remove(path)
        search.selection = .hit(path, line: line)
    }
}

/// The active file's editor, in plain terms. Lines are 1-based, as the editor shows them.
package struct StoryEditor: Sendable, Equatable {
    package let path: String
    package let text: String
    package let isDirty: Bool
    package let caretLine: Int
    /// Lines under a fold.
    package let hiddenLines: [Int]
    package let foldCount: Int
    /// The find bar, when it's open.
    package let find: Find?

    package struct Find: Sendable, Equatable {
        package let query: String
        package let showsReplace: Bool
        /// "1 of 3", "No results".
        package let label: String
        /// Each match's line, in order: where the scroller's ticks go.
        package let matchLines: [Int]
    }
}

package struct StoryFileTab: Sendable, Equatable {
    package let path: String
    /// The italic tab the next single-click open replaces.
    package let preview: Bool
    package let active: Bool

    package init(path: String, preview: Bool, active: Bool) {
        self.path = path
        self.preview = preview
        self.active = active
    }
}

package struct StorySearch: Sendable, Equatable {
    package struct Hit: Sendable, Hashable, CustomStringConvertible {
        package let path: String
        /// 1-based.
        package let line: Int

        package init(path: String, line: Int) {
            self.path = path
            self.line = line
        }

        package var description: String { "\(path):\(line)" }
    }

    package let query: String
    /// The results are the query's, all in.
    package let finished: Bool
    package let hits: [Hit]
}

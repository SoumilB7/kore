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

    /// Shows the tab at `index` (0-based), as its click does. In a storyline's window (never key)
    /// a click on another tab doesn't reach it while a file tab shows.
    package func storySelect(tabAt index: Int) {
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    /// The name of the tab at `index` (0-based) in the strip: `tabs.file[…]` for a file's.
    package func storyTabID(at index: Int) -> StoryID? {
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        return tab.file.map { StoryID.Tabs.file(relativePath($0.path)) } ?? StoryID.Tabs.tab(tab.id)
    }

    /// The tree's selected row, relative to the folder.
    package var storyTreeSelection: String? { files.flatMap { store in store.selection.map(store.relative) } }

    /// The folder the tree underlines (a chain's chosen folder), relative to the folder.
    package var storyTreeMark: String? { files.flatMap { store in store.markedFolder.map(store.relative) } }

    /// The file's size in bytes; nil when there's no such file.
    package func storyFileSize(_ relativePath: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(relativePath).path))?[.size] as? Int
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
            caretShown: Self.storyCaretShown(editor),
            hiddenLines: hidden, foldCount: editor.folds.count, changedLines: editor.changes.marks.keys.sorted().map { $0 + 1 },
            find: find.isOpen
                ? StoryEditor.Find(
                    query: find.query, showsReplace: find.showReplace, label: find.countLabel,
                    matchLines: find.matches.map { lines.line(at: $0.location) + 1 })
                : nil)
    }

    /// The editor has the keyboard and its caret's spot is on screen, clear of the gutter
    /// (a storyline's window is never key, so AppKit never draws the caret itself).
    private static func storyCaretShown(_ editor: CodeEditorController) -> Bool {
        let text = editor.textView
        guard text.window?.firstResponder === text, text.selectedRange().length == 0,
            let layout = text.layoutManager, let container = text.textContainer, let gutter = editor.scrollView.verticalRulerView
        else { return false }
        let caret = text.selectedRange().location
        let length = text.textStorage?.length ?? 0
        var box: NSRect
        if caret >= length, layout.extraLineFragmentRect.height > 0 {
            box = layout.extraLineFragmentRect
            box.origin.x += container.lineFragmentPadding
        } else if length > 0 {
            // The glyph after the caret, or at the end the one before it.
            let after = caret < length
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: after ? caret : length - 1, length: 1), actualCharacterRange: nil)
            box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            if !after { box.origin.x = box.maxX }
        } else {
            return false
        }
        box.size.width = 1
        let spot = editor.scrollView.convert(box.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y), from: text)
        let clip = editor.scrollView.contentView.frame
        return box.height > 0 && spot.minX >= gutter.frame.maxX && spot.maxX <= clip.maxX && spot.minY >= clip.minY && spot.maxY <= clip.maxY
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

    /// The active Markdown preview's selection: whether it has the keyboard, and what's selected.
    package var storyPreviewSelection: (focused: Bool, markdown: String)? {
        guard let state = activeFile?.rendering.memory.current as? MarkdownState else { return nil }
        let responder = state.selection.responder
        return (responder.map { $0.window?.firstResponder === $0 } ?? false, state.selection.markdown())
    }

    /// Where the glyph at `offset` of a text in the active Markdown preview starts (its run, then
    /// the text's path), in its window; nil until it's laid out.
    package func storyPreviewPoint(run: Int, path: [Int], offset: Int) -> (NSWindow, CGPoint)? {
        guard let state = activeFile?.rendering.memory.current as? MarkdownState, run < state.runs.ids.count else { return nil }
        let (selection, entry) = (state.selection, state.runs.ids[run])
        guard let slot = selection.slots[entry]?[path], let layout = selection.layout(entry, path), let p = layout.point(at: offset),
            let view = selection.responder, let window = view.window
        else { return nil }
        return (window, view.convert(CGPoint(x: slot.frame.minX + p.x + 1, y: slot.frame.minY + p.y), to: nil))
    }

    /// A script's number answer from the active HTML tab's page; nil while no web view shows it.
    package func storyPageNumber(_ script: String) async -> Double? {
        guard let page = activeFile?.rendering.memory.current as? WebPageState else { return nil }
        return await page.storyNumber(script)
    }

    /// A script's answer from the active tab's diagram (a Mermaid file, or a Markdown file's
    /// first ```mermaid block); nil while it isn't shown.
    package func storyDiagram(_ script: String) async -> Any? {
        await storyDiagramPage?.storyAnswer(script)
    }

    /// The active tab's diagrams as WebKit drew them, and their frames in the window.
    package func storyDiagramSnapshots() async -> [(image: NSImage, frame: CGRect)] {
        let current = activeFile?.rendering.memory.current
        let pages = (current as? DiagramPage).map { [$0] } ?? (current as? MarkdownState)?.diagrams.values.map { $0 } ?? []
        var shots: [(image: NSImage, frame: CGRect)] = []
        for page in pages { if let shot = await page.storySnapshot() { shots.append(shot) } }
        return shots
    }

    private var storyDiagramPage: DiagramPage? {
        let current = activeFile?.rendering.memory.current
        return current as? DiagramPage ?? (current as? MarkdownState)?.diagrams.min { $0.key < $1.key }?.value
    }

    /// The HTML page of the file tab at this path (the active tab's when nil) is in the window.
    package func storyPageShown(_ path: String? = nil) -> Bool {
        let file = path.map { path in tabs.lazy.compactMap(\.file).first { relativePath($0.path) == path } } ?? activeFile
        return (file?.rendering.memory.current as? WebPageState)?.onScreen == true
    }

    /// Where the active renderer's column of rows is (Markdown, a notebook): the row at the top
    /// and how far down it; nil at the top or with no such renderer.
    package var storyRowPlace: (row: Int, into: CGFloat)? {
        (activeFile?.rendering.memory.current as? PlacedRenderer)?.place.current
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
    /// The caret is where it's seen: the editor has the keyboard, and the caret's spot is on
    /// screen, not under the gutter.
    package let caretShown: Bool
    /// Lines under a fold.
    package let hiddenLines: [Int]
    package let foldCount: Int
    /// Lines with a change bar against git `HEAD`.
    package let changedLines: [Int]
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

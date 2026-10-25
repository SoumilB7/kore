import AppKit
import KoreUI

/// A long HTML page, a long Markdown file and a long code file, each in a tab of its own and
/// scrolled to its middle: going to the chat's tab and back finds each where it was left, the
/// page with its script state too (its web view was kept, not loaded again). Changed on disk,
/// the page loads again at the same place, as it does once more pages than are kept have shown.
final class FileTabState: ChatStoryline {
    override class var tags: Set<Tag> { [.files] }

    static let page = "site/long.html"
    static let notes = "notes.md"
    static let code = "Sources/Long.swift"

    static var files: [(path: String, text: String)] {
        let paragraphs = (1...300).map { "<p id=\"p\($0)\">Paragraph \($0) of the long page, with enough words to wrap a line or two.</p>" }
        let sections = (1...80).map { n in
            "## Section \(n)\n\n" + (1...4).map { "Section \(n), paragraph \($0): a few sentences of Markdown, so each section is a screen or so of text, and a little more." }.joined(separator: "\n\n")
        }
        return [
            (page, "<!doctype html><title>Long</title><body>" + paragraphs.joined(separator: "\n") + "</body>"),
            (notes, "# Notes\n\n" + sections.joined(separator: "\n\n") + "\n"),
            (code, (1...800).map { "let value\($0) = \($0)  // line \($0)" }.joined(separator: "\n") + "\n"),
        ]
    }

    override func steps() -> [any Step] {
        [WriteFiles(Self.files + Self.others)] + super.steps()
            + Self.open(Self.page) + [
                Expect("the page in the web renderer", found: { $0.app.workspace?.storyActiveRenderer ?? "no renderer" }) {
                    $0.app.workspace?.storyActiveRenderer == "html"
                },
                PageScroll.middle,
            ]
            + Self.away(2, gone: Expect("the page out of the window") { $0.app.workspace?.storyPageShown(Self.page) == false })
            + [PageScroll.same]
            + Self.open(Self.notes) + [
                Expect("the notes in the Markdown renderer") { $0.app.workspace?.storyActiveRenderer == "markdown" },
                Scroll(.id(StoryID.Editor.rows), to: .by(2400)),
                RowPlaceKept.left,
            ]
            + Self.away(3, gone: Expect("the notes out of the window") { _ in StoryElement(StoryID.Editor.rows) == nil })
            + [RowPlaceKept.same]
            + Self.open(Self.code) + [
                Expect.editor("the code in the editor") { $0.path == Self.code },
                Scroll(.editor, to: .by(4000)),
                EditorScrollKept.left,
            ]
            + Self.away(4, gone: Expect("the code out of the window") { _ in StoryElement(StoryID.Editor.text(Self.code))?.window == nil })
            + [EditorScrollKept.same]
            // The page once more, after the other tabs: still the page it was.
            + [SelectTab(2), PageScroll.same]
            // Changed on disk: loaded again, at the same place.
            + [WriteFiles([(Self.page, Self.files[0].text + "\n<!-- changed -->")]), PageScroll.reloaded]
            // Past the pages kept alive: the one unseen longest is let go, and comes back loaded
            // again at the same place.
            + [PageScroll.middle]
            + Self.others.flatMap { Self.open($0.path) + [Expect("its page in the window") { $0.app.workspace?.storyPageShown() == true }] }
            + [SelectTab(2), PageScroll.reloaded]
    }

    /// More pages than are kept alive.
    static var others: [(path: String, text: String)] {
        (1...KeptPages.limit).map { ("site/other\($0).html", "<!doctype html><p>Another page, \($0).</p>") }
    }

    /// Opens the file in a kept tab (Go to File), the active one.
    static func open(_ path: String) -> [any Step] {
        [
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText(path),
            ExpectElement(.quickOpenRow(path)),
            Key(.returnKey),
            Expect("\(path) the active tab") { $0.app.workspace?.storyActiveFile == path },
        ]
    }

    /// To the chat's tab, once the file's view has gone, and back to the file's, the nth.
    static func away(_ n: Int, gone: Expect) -> [any Step] { [SelectTab(1), gone, SelectTab(n)] }
}

/// Shows the nth tab and waits for it (see `Workspace.storySelect`).
private struct SelectTab: Step {
    let n: Int
    var label: String { "Show tab \(n)" }
    init(_ n: Int) { self.n = n }

    func run(_ story: StoryContext) async throws {
        story.app.workspace?.storySelect(tabAt: n - 1)
        try await story.until("tab \(n) to be the active one") {
            story.app.workspace.map { $0.tabs.indices.contains(n - 1) && $0.activeTab === $0.tabs[n - 1] } ?? false
        }
    }
}

/// What a tab's view showed when it was left, to find again.
@MainActor
private final class LeftPlaces {
    var pageY: Double?
    var row: (row: Int, into: CGFloat)?
    var editorY: CGFloat?
}

/// The HTML page scrolled to its middle and marked, found there again with its mark, or found
/// there loaded again (its mark gone).
private struct PageScroll: Step {
    enum Kind { case middle, same, reloaded }
    let kind: Kind
    var label: String {
        switch kind {
        case .middle: "Scroll the page to its middle"
        case .same: "Find the page where it was, its script state kept"
        case .reloaded: "Find the page loaded again, where it was"
        }
    }

    static let middle = PageScroll(kind: .middle)
    static let same = PageScroll(kind: .same)
    static let reloaded = PageScroll(kind: .reloaded)

    func run(_ story: StoryContext) async throws {
        let left = story.stash(LeftPlaces.self) { LeftPlaces() }
        if kind == .middle {
            let room = try await Self.answer(story, "the page loaded", "document.readyState == 'complete' ? document.body.scrollHeight - window.innerHeight : 0") { $0 > 0 }
            guard room > 1000 else { throw StoryFailure.expectation("a long page (\(Int(room)) pt to scroll)") }
            let script = "window.scrollTo(0, \(Int(room / 2))); window.koreMark = 7; window.scrollY"
            left.pageY = try await Self.answer(story, "the page scrolled to its middle", script) { $0 > 500 }
            return
        }
        guard let y = left.pageY else { throw StoryFailure.other("the page was never scrolled") }
        // -1: the mark is gone, the page was loaded again; -2: it's still there.
        let script = kind == .same ? "window.koreMark === 7 ? window.scrollY : -1" : "window.koreMark === 7 ? -2 : window.scrollY"
        let what = kind == .same ? "with its mark" : "loaded again"
        do {
            _ = try await Self.answer(story, "the page at \(Int(y)) \(what)", script) { $0 == y }
        } catch StoryFailure.timedOut {
            let now = await story.app.workspace?.storyPageNumber(script)
            let found = now.map { $0 == -1 ? "the page was loaded again" : $0 == -2 ? "the page wasn't loaded again" : "at \(Int($0))" } ?? "no page"
            throw StoryFailure.expectation("the page at \(Int(y)) \(what) (\(found))")
        }
    }

    /// Waits for the page's answer to a script to pass `check`, asking again once each answer is in.
    @MainActor static func answer(_ story: StoryContext, _ label: String, _ script: String, _ check: @escaping (Double) -> Bool) async throws -> Double {
        let box = Answer()
        return try await story.wait(label) {
            if let value = box.value, check(value) { return value }
            if !box.asking, let workspace = story.app.workspace {
                box.asking = true
                Task { @MainActor in
                    box.value = await workspace.storyPageNumber(script)
                    box.asking = false
                }
            }
            return nil
        }
    }

    @MainActor private final class Answer {
        var value: Double?
        var asking = false
    }
}

/// The Markdown column's place (its top row and how far down it), noted or found again.
private struct RowPlaceKept: Step {
    let leave: Bool
    var label: String { leave ? "Note the Markdown's place" : "Find the Markdown where it was" }

    static let left = RowPlaceKept(leave: true)
    static let same = RowPlaceKept(leave: false)

    func run(_ story: StoryContext) async throws {
        let left = story.stash(LeftPlaces.self) { LeftPlaces() }
        if leave {
            let place = try await story.wait("the Markdown scrolled past its top") { story.app.workspace?.storyRowPlace }
            guard place.row > 2 else { throw StoryFailure.expectation("the Markdown scrolled to its middle (row \(place.row))") }
            left.row = place
            return
        }
        guard let want = left.row else { throw StoryFailure.other("the Markdown's place was never noted") }
        do {
            try await story.until("the Markdown back at row \(want.row), \(Int(want.into)) pt into it") {
                guard let now = story.app.workspace?.storyRowPlace else { return false }
                return now.row == want.row && abs(now.into - want.into) < 1
            }
        } catch StoryFailure.timedOut {
            let now = story.app.workspace?.storyRowPlace
            throw StoryFailure.expectation(
                "the Markdown at row \(want.row), \(want.into) pt into it (at \(now.map { "row \($0.row), \($0.into) pt" } ?? "the top"))")
        }
    }
}

/// The code editor's scroll, noted or found again.
private struct EditorScrollKept: Step {
    let leave: Bool
    var label: String { leave ? "Note the editor's scroll" : "Find the editor where it was" }

    static let left = EditorScrollKept(leave: true)
    static let same = EditorScrollKept(leave: false)

    func run(_ story: StoryContext) async throws {
        let left = story.stash(LeftPlaces.self) { LeftPlaces() }
        let element = try await story.element(.editor)
        let offset = { @MainActor () -> CGFloat? in
            var view = element.registeredView
            while let current = view {
                if let scroll = current as? NSScrollView { return scroll.contentView.bounds.origin.y }
                view = current.superview
            }
            return nil
        }
        if leave {
            left.editorY = try await story.wait("the editor scrolled to its middle") { offset().flatMap { $0 > 1000 ? $0 : nil } }
            return
        }
        guard let want = left.editorY else { throw StoryFailure.other("the editor's scroll was never noted") }
        do {
            // Its scroll view goes with the tab: back in the window, and where it was.
            try await story.until("the editor at \(Int(want))") {
                element.window != nil && offset().map { abs($0 - want) < 0.5 } ?? false
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("the editor at \(Int(want)) (at \(offset().map { "\(Int($0))" } ?? "no editor"))")
        }
    }
}

/// A Markdown file's preview selects as the transcript does: opened from Quick Open it has the
/// keyboard, ⌘A takes the whole file and ⌘C copies it as its markdown; a double-click takes a
/// word, Escape lets it go.
final class MarkdownPreviewSelects: ChatStoryline {
    override class var tags: Set<Tag> { [.files, .gate] }

    static let path = "guide.md"
    static let text = """
        # Guide

        Read the **config** first, then check `port` values.

        - one item
        - two items

        ```sh
        make run
        ```
        """

    override func steps() -> [any Step] {
        [WriteFiles([(Self.path, Self.text + "\n")])] + super.steps() + FileTabState.open(Self.path) + [
            Expect("the guide in the Markdown renderer") { $0.app.workspace?.storyActiveRenderer == "markdown" },
            Expect("the preview to have the keyboard") { $0.app.workspace?.storyPreviewSelection?.focused == true },
            Key(KeyChord(.character("a"), .command)),
            CopySelection(Self.text),
            Key(.escape),
            CopySelectionNothing(),
            ClickPreview(path: [1], offset: 10, count: 2),
            CopySelection("**config**"),
        ]
    }
}

/// Clicks at a glyph of the active Markdown preview's first run.
private struct ClickPreview: Step {
    let path: [Int]
    let offset: Int
    var count = 1
    var label: String { "\(count)× click the preview at \(path)@\(offset)" }

    func run(_ story: StoryContext) async throws {
        let (window, p) = try await story.wait("the preview's text") {
            story.app.workspace?.storyPreviewPoint(run: 0, path: path, offset: offset)
        }
        await story.input.click(at: p, in: window, count: count, modifiers: [])
    }
}

/// ⌘C with nothing selected copies nothing.
private struct CopySelectionNothing: Step {
    var label: String { "⌘C copies nothing" }

    func run(_ story: StoryContext) async throws {
        StoryTranscript.clearCopied()
        try await Key(KeyChord(.character("c"), .command)).run(story)
        try await Task.sleep(for: .milliseconds(200))
        if let copied = StoryTranscript.copied { throw StoryFailure.expectation("nothing copied — it copied:\n\(copied)") }
    }
}

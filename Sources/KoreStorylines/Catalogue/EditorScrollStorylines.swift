import AppKit
import Foundation
import KoreUI

// The editor's scroll is the owner's (owner, 0.3.10: "I cannot scroll to the right and keep it
// there, it reverts to this just before I stop"): a flick sideways stays where it ends, and a
// wait, a reload from disk, a save or a resize never moves it; a flick back to the left edge
// stays there too.

/// What the editor was scrolled to.
@MainActor
private final class KeptScroll {
    var x: CGFloat = 0
}

/// A Markdown file of long lines (no wrap), its caret at the top left; flicked right, then put
/// through what used to move it.
final class EditorKeepsSideways: FilesStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    static let path = "wide.md"
    static let line = String(repeating: "Read every modified clause, then the new one beside it. ", count: 6)
    override class var files: [(path: String, text: String)] {
        [(path, (1...80).map { "\($0). " + line }.joined(separator: "\n") + "\n")]
    }

    private final class Saved { var autoSave = false }

    private static func x(_ story: StoryContext) -> CGFloat? { story.app.workspace?.storyEditorScroll?.x }

    /// Still where the flick left it (half a point either way: a pixel's rounding).
    private static func kept(_ what: String) -> Expect {
        Expect("the editor still \(what)", found: { story in x(story).map { "x \($0), was \(story.stash(KeptScroll.self) { KeptScroll() }.x)" } }) { story in
            guard let x = x(story) else { return false }
            return abs(x - story.stash(KeptScroll.self) { KeptScroll() }.x) <= 0.5
        }
    }

    override func steps() -> [any Step] {
        [Do("Auto Save off, so only this run's saves write") { story in
            story.stash(Saved.self) { Saved() }.autoSave = FileAutoSave.shared.isEnabled
            FileAutoSave.shared.isEnabled = false
        }] + super.steps() + [
            Command(.toggleExplorer),
            Press(.treeRow(Self.path)),
            Do("As its text, line numbers and all") { story in story.app.workspace?.storyShowRaw() },
            Click(.editor),
            WaitForFocus(.editor),
            Key(KeyChord(.up, .command)),
            // No wrap, as the owner has it (⌥Z): long lines run off the right edge.
            Key(KeyChord(.character("z"), .option)),
            Expect("wrap off") { story in story.app.workspace?.storyEditorWraps == false },
            Expect("the editor at its left edge") { story in Self.x(story).map { abs($0) <= 0.5 } ?? false },
            ScrollSideways(.editor, dx: 200),
            Expect("the scroll moved it right, about 200 pt", found: { story in Self.x(story).map { "x \($0)" } }) { story in
                Self.x(story).map { $0 > 150 && $0 < 260 } ?? false
            },
            Do("Note where it stopped") { story in story.stash(KeptScroll.self) { KeptScroll() }.x = Self.x(story) ?? 0 },
            WaitIdle(),
            Self.kept("there once the scroll is over"),
            // The trackpad gesture ending as a pinch would, nothing magnified.
            Do("A stray pinch over the editor as the scroll ends") { story in
                guard story.app.workspace?.storyStrayPinchOverEditor() == true else { throw StoryFailure.other("the pinch didn't reach the editor") }
            },
            WaitIdle(),
            Self.kept("there after a stray pinch"),
            Command(.newTab),
            WaitIdle(),
            Do("The file's tab in front again") { story in story.app.workspace?.storySelect(tabAt: 0) },
            Expect("the file in front") { $0.app.workspace?.storyActiveFile == Self.path },
            WaitIdle(),
            Self.kept("there after the tab came back"),
            Snapshot("editor-sideways-kept"),
            // A chat writes the file: it's read again.
            WriteFiles([(Self.path, Self.files[0].text + "81. " + Self.line + "\n")]),
            Expect("the change read in") { story in story.app.workspace?.storyEditor?.text.contains("81. ") == true },
            WaitIdle(),
            Self.kept("there after the file changed on disk"),
            Do("Saved, as autosave saves") { story in story.app.workspace?.storySaveActive() },
            WaitIdle(),
            Self.kept("there after a save"),
            Do("The window narrower") { story in
                guard let window = story.window else { return }
                window.setContentSize(CGSize(width: window.frame.width - 120, height: window.contentLayoutRect.height))
            },
            WaitIdle(),
            Self.kept("there after a resize"),
            Do("The window back") { story in story.window?.setContentSize(story.windowSize) },
            WaitIdle(),
            Self.kept("there after the resize back"),
            ScrollSideways(.editor, dx: -2_000),
            Expect("scrolled back to the left edge", found: { story in Self.x(story).map { "x \($0)" } }) { story in Self.x(story).map { abs($0) <= 0.5 } ?? false },
            WaitIdle(),
            Expect("and it stays there", found: { story in Self.x(story).map { "x \($0)" } }) { story in Self.x(story).map { abs($0) <= 0.5 } ?? false },
            Do("Auto Save as it was") { story in FileAutoSave.shared.isEnabled = story.stash(Saved.self) { Saved() }.autoSave },
        ]
    }
}

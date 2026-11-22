import AppKit
import Foundation
import KoreUI
import src

// The editor's controls no other storyline uses as a person does: the find bar's Aa, ab and .*
// toggles, ⇧↩ and ⇧⌘1; the notice's Save, Close, Retry, Compare and Keep Mine; a file state's
// button; the path row's segments and their menu; the "this turn" mark; and Quick Open's ↓ ↑
// and a click on its row.

/// Auto Save as the storyline sets it, put back when it ends.
@MainActor private final class DriveAutoSave: StoryFinishing {
    private let original = FileAutoSave.shared.isEnabled
    func finish() { FileAutoSave.shared.isEnabled = original }
}

/// Files a storyline made unreadable or read-only, readable and writable again when it ends.
@MainActor private final class DrivePermissions: StoryFinishing {
    var urls: [URL] = []
    func finish() {
        for url in urls { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    }
}

/// Sets a file's permissions; the storyline's end makes it 0644 again.
@MainActor private func drivePermissions(_ story: StoryContext, _ path: String, _ mode: Int) throws {
    let url = story.folder.appendingPathComponent(path)
    story.stash(DrivePermissions.self) { DrivePermissions() }.urls.append(url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// What a storyline noted to compare with later.
@MainActor private final class DriveNoted {
    var path: String?
}

/// The find bar's Aa, ab and .* each change what matches, and back.
final class DriveFilesFindToggles: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("find.txt", "Hello world\nhello there\nhelloworld\n")] }

    override func steps() -> [any Step] {
        typealias Find = StoryID.Editor.Find
        return super.steps() + [
            Key(.cmd("f")),
            WaitForFocus(.id(Find.field)),
            TypeText("hello"),
            Expect.editor("“hello” on all three lines") { $0.find?.matchLines == [1, 2, 3] },
            Press(.id(Find.matchCase)),
            Expect.editor("Aa: only the lowercase two") { $0.find?.matchLines == [2, 3] },
            Press(.id(Find.matchCase)),
            Expect.editor("Aa off: all three again") { $0.find?.matchLines == [1, 2, 3] },
            Press(.id(Find.wholeWord)),
            Expect.editor("ab: whole words only, not “helloworld”") { $0.find?.matchLines == [1, 2] },
            Press(.id(Find.wholeWord)),
            Expect.editor("ab off: all three again") { $0.find?.matchLines == [1, 2, 3] },
            Click(.id(Find.field)),
            WaitForFocus(.id(Find.field)),
            Key(.cmd("a")),
            TypeText("h.llo"),
            Expect.editor("“h.llo” as plain text matches nothing") { $0.find?.query == "h.llo" && $0.find?.matchLines.isEmpty == true },
            Press(.id(Find.regex)),
            Expect.editor(".*: “h.llo” as a pattern finds all three") { $0.find?.matchLines == [1, 2, 3] },
        ]
    }
}

/// ⇧↩ in the find field goes to the previous match; ⇧⌘1 replaces the current one.
final class DriveFilesFindKeys: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("fish.txt", "one fish\ntwo fish\nred fish\n")] }

    override func steps() -> [any Step] {
        typealias Find = StoryID.Editor.Find
        return super.steps() + [
            Key(.cmd("f")),
            WaitForFocus(.id(Find.field)),
            TypeText("fish"),
            Expect.editor("“1 of 3”") { $0.find?.label == "1 of 3" },
            Key(KeyChord(.returnKey, .shift)),
            Expect.editor("⇧↩ went back round to the last match") { $0.find?.label == "3 of 3" },
            Press(.id(Find.toggleReplace)),
            Expect.editor("the replace row") { $0.find?.showsReplace == true },
            Click(.id(Find.replaceField)),
            WaitForFocus(.id(Find.replaceField)),
            TypeText("cat"),
            Key(KeyChord(.character("1"), [.command, .shift])),
            Expect.editor("⇧⌘1 replaced the current match, on line 3") {
                $0.text == "one fish\ntwo fish\nred cat\n" && $0.find?.matchLines == [1, 2] && $0.isDirty
            },
        ]
    }
}

/// A file deleted on disk while it's open: the notice's Save writes it back; deleted again, its
/// Close closes the tab.
final class DriveFilesNoticeDeleted: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let path = "gone.txt"
    override class var files: [(path: String, text: String)] { [(path, "keep me\n")] }

    override func steps() -> [any Step] {
        let delete = Do("Delete gone.txt on disk") { story in
            try FileManager.default.removeItem(at: story.folder.appendingPathComponent(Self.path))
        }
        return super.steps() + [
            delete,
            ExpectElement(.id(StoryID.Editor.Notice.save), .visible),
            Press(.id(StoryID.Editor.Notice.save)),
            Expect.disk(Self.path, "keep me\n"),
            ExpectElement(.id(StoryID.Editor.Notice.save), .absent),
            delete,
            ExpectElement(.id(StoryID.Editor.Notice.close), .visible),
            Press(.id(StoryID.Editor.Notice.close)),
            Expect.fileTabs("the file's tab closed") { $0.isEmpty },
        ]
    }
}

/// Auto Save can't write a read-only file: its notice's Retry saves once the file is writable.
final class DriveFilesNoticeRetry: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let path = "locked.txt"
    override class var files: [(path: String, text: String)] { [(path, "start\n")] }

    override func steps() -> [any Step] {
        [Do("Turn Auto Save on") { story in
            _ = story.stash(DriveAutoSave.self) { DriveAutoSave() }
            FileAutoSave.shared.isEnabled = true
        }] + super.steps() + [
            Do("Make locked.txt read-only") { try drivePermissions($0, Self.path, 0o444) },
            TypeText("x"),
            ExpectElement(.id(StoryID.Editor.Notice.retry), .visible),
            Expect.disk(Self.path, "start\n"),
            Do("Make it writable again") { try drivePermissions($0, Self.path, 0o644) },
            Press(.id(StoryID.Editor.Notice.retry)),
            Expect.disk(Self.path, "xstart\n"),
            ExpectElement(.id(StoryID.Editor.Notice.retry), .absent),
            Expect.editor("saved") { !$0.isDirty },
        ]
    }
}

/// A file changed on disk under unsaved edits: Compare shows the two, Keep Mine keeps the edits
/// and the next save writes them over the disk's.
final class DriveFilesNoticeCompareKeep: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let path = "both.txt"
    override class var files: [(path: String, text: String)] { [(path, "original\n")] }

    override func steps() -> [any Step] {
        [Do("Turn Auto Save off") { story in
            _ = story.stash(DriveAutoSave.self) { DriveAutoSave() }
            FileAutoSave.shared.isEnabled = false
        }] + super.steps() + [
            TypeText("mine "),
            Expect.editor("an unsaved edit") { $0.isDirty && $0.text == "mine original\n" },
            WriteFiles([(Self.path, "theirs\n")]),
            ExpectElement(.id(StoryID.Editor.Notice.compare), .visible),
            Press(.id(StoryID.Editor.Notice.compare)),
            ExpectElement(.id(StoryID.Changes.file(Self.path))),
            Press(.id(StoryID.Changes.done)),
            ExpectElement(.id(StoryID.Changes.done), .absent),
            Press(.id(StoryID.Editor.Notice.keep)),
            ExpectElement(.id(StoryID.Editor.Notice.keep), .absent),
            Expect.editor("the edits kept, still unsaved") { $0.text == "mine original\n" && $0.isDirty },
            Expect.disk(Self.path, "theirs\n"),
            Click(.editor),
            WaitForFocus(.editor),
            Key(.cmd("s")),
            Expect.disk(Self.path, "mine original\n"),
        ]
    }
}

/// A file Kore can't read shows its state; Try Again reads it once it's readable.
final class DriveFilesStateTryAgain: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let path = "sealed.txt"
    override class var files: [(path: String, text: String)] { [(path, "readable now\n")] }

    override func steps() -> [any Step] {
        let again = StoryID.Editor.state("Try Again")
        return super.steps() + [
            Do("Make sealed.txt unreadable") { try drivePermissions($0, Self.path, 0o000) },
            Command(.toggleExplorer),
            Press(.treeRow(Self.path)),
            ExpectElement(.id(again), .visible),
            Do("Make it readable again") { try drivePermissions($0, Self.path, 0o644) },
            Press(.id(again)),
            Expect.editor("its text") { $0.path == Self.path && $0.text == "readable now\n" },
            ExpectElement(.id(again), .absent),
        ]
    }
}

/// A path row segment opens its folder's menu; a file in it opens in the preview tab.
final class DriveFilesCrumbMenu: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("src/a.swift", "let a = 1\n"), ("src/b.swift", "let b = 2\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Press(.id(StoryID.Editor.crumb("src"))),
            ExpectElement(.id(StoryID.Editor.crumbRow("b.swift")), .visible),
            Press(.id(StoryID.Editor.crumbRow("b.swift"))),
            Expect.fileTabs("b.swift in the preview tab") { $0 == [StoryFileTab(path: "src/b.swift", preview: true, active: true)] },
            ExpectElement(.id(StoryID.Editor.crumbRow("b.swift")), .absent),
        ]
    }
}

/// A file the last turn wrote: its path row's "this turn" mark opens the turn's changes to it.
final class DriveFilesTurnMark: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let path = "notes.md"
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .fileEdit(path: path, content: "# Notes\n\nWritten in the turn.\n"), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [Send("Write the notes"), TurnFinished(1), WaitIdle()] + FileTabState.open(Self.path) + [
            ExpectElement(.id(StoryID.Editor.turnMark), .visible),
            Press(.id(StoryID.Editor.turnMark)),
            ExpectElement(.id(StoryID.Changes.file(Self.path))),
            Press(.id(StoryID.Changes.done)),
            ExpectElement(.id(StoryID.Changes.done), .absent),
        ]
    }
}

/// Quick Open's ↓ moves its selection to the next file and ↑ back, for Return to open.
final class DriveFilesQuickOpenKeys: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("notes-one.txt", "1\n"), ("notes-two.txt", "2\n"), ("other.md", "x\n")] }

    override func steps() -> [any Step] {
        let first = DriveNoted()
        let type: [any Step] = [
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText("notes"),
            ExpectElement(.quickOpenRow("notes-one.txt")),
            ExpectElement(.quickOpenRow("notes-two.txt")),
        ]
        let notes: @MainActor @Sendable (StoryContext) -> String? = { story in
            story.app.workspace?.storyActiveFile.flatMap { $0.hasPrefix("notes-") ? $0 : nil }
        }
        return super.steps() + type + [
            Key(.returnKey),
            Expect("Return opened one of the two") { notes($0) != nil },
            Do("Note which") { first.path = notes($0) },
        ] + type + [
            Key(.down),
            Key(.returnKey),
            Expect("↓ then Return opened the other one", found: { $0.app.workspace?.storyActiveFile }) { story in
                notes(story) != nil && notes(story) != first.path
            },
        ] + type + [
            Key(.down),
            Key(.up),
            Key(.returnKey),
            Expect("↓ ↑ then Return opened the first again", found: { $0.app.workspace?.storyActiveFile }) { story in
                notes(story) == first.path
            },
        ]
    }
}

/// A click on a Quick Open row opens its file.
final class DriveFilesQuickOpenRow: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("alpha.txt", "a\n"), ("beta.txt", "b\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText("beta"),
            Press(.quickOpenRow("beta.txt")),
            Expect("quick open closed") { $0.app.workspace?.storyQuickOpenShown == false },
            Expect("beta.txt the active tab") { $0.app.workspace?.storyActiveFile == "beta.txt" },
        ]
    }
}

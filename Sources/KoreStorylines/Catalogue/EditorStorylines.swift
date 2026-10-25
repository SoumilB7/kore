import AppKit
import KoreUI

/// A folder of a few files, written into the run's scratch folder and opened. Its subclasses
/// name the files and what happens next.
class FilesStoryline: Storyline {
    override class var isFamily: Bool { self == FilesStoryline.self }
    /// The folder's files, relative to it.
    class var files: [(path: String, text: String)] { [] }

    override func steps() -> [any Step] { [WriteFiles(Self.files), OpenFolder()] }
}

/// A file opened from the explorer with a click (a preview tab), and a click in its text that
/// puts the caret at its start. Its subclasses name the file.
class EditorStoryline: FilesStoryline {
    override class var isFamily: Bool { self == EditorStoryline.self }
    /// The file it opens: one of `files`.
    class var file: String { files.first?.path ?? "" }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            Press(.treeRow(Self.file)),
            Expect.fileTabs("\(Self.file) in a preview tab") { $0 == [StoryFileTab(path: Self.file, preview: true, active: true)] },
            Click(.editor),
            WaitForFocus(.editor),
            Key(KeyChord(.up, .command)),
            Expect.editor("the caret on line 1") { $0.path == Self.file && $0.caretLine == 1 },
        ]
    }
}

/// A committed file edited and saved shows its change bar; a commit from outside (the
/// terminal) clears it without reopening the file. Its subclasses name the repository's folder.
class GitMarksStoryline: EditorStoryline {
    override class var isFamily: Bool { self == GitMarksStoryline.self }
    override class var tags: Set<Tag> { [.editor] }
    /// The repository's folder in the storyline's folder ("" for the folder itself).
    class var repo: String { "" }
    override class var files: [(path: String, text: String)] {
        [((repo as NSString).appendingPathComponent("notes.txt"), "one\ntwo\nthree\n")]
    }

    override func steps() -> [any Step] {
        super.steps() + [
            RunGit(in: Self.repo, "init", "-q"),
            RunGit(in: Self.repo, "add", "notes.txt"),
            RunGit(in: Self.repo, "commit", "-qm", "first"),
            Expect.editor("no change bars") { $0.changedLines.isEmpty },
            TypeText("1 "),
            Key(.cmd("s")),
            Expect.editor("line 1's change bar, saved") { $0.changedLines == [1] && !$0.isDirty },
            RunGit(in: Self.repo, "commit", "-qam", "second"),
            Expect.editor("the bar gone once committed") { $0.changedLines.isEmpty },
        ]
    }
}

/// The folder's own repository.
final class GitMarksClearOnCommit: GitMarksStoryline {}

/// A repository in a dot folder of the folder's repository (as `.agents` is): its commits
/// move its own `HEAD`, not the folder's.
final class GitMarksClearInNestedRepo: GitMarksStoryline {
    override class var repo: String { ".agents" }
    override class var files: [(path: String, text: String)] { super.files + [("README.md", "outer\n")] }

    override func steps() -> [any Step] {
        // After the files are written, before the folder opens.
        var steps = super.steps()
        let outer: [any Step] = [RunGit("init", "-q"), RunGit("add", "README.md"), RunGit("commit", "-qm", "outer")]
        steps.insert(contentsOf: outer, at: 1)
        return steps
    }
}

/// Find, replace one and then the rest, save, fold, and undo: the editor's find bar and its
/// keys, the gutter, and the file on disk.
final class EditorFindReplace: EditorStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    static let original = """
        struct Greeting {
            let name: String

            func greet() -> String {
                let first = "Hello"
                let second = "Hello"
                return first + ", " + second + " " + name
            }
        }

        // Hello again
        """
    static let replacedOne = original.replacingOccurrences(of: "first = \"Hello\"", with: "first = \"Hi\"")
    static let replacedAll = original.replacingOccurrences(of: "Hello", with: "Hi")
    override class var files: [(path: String, text: String)] { [("Sources/Greeting.swift", original)] }

    override func steps() -> [any Step] {
        typealias Find = StoryID.Editor.Find
        return super.steps() + [
            Key(.cmd("f")),
            WaitForFocus(.id(Find.field)),
            TypeText("Hello"),
            Expect.editor("“1 of 3”, on lines 5, 6 and 11") { $0.find?.label == "1 of 3" && $0.find?.matchLines == [5, 6, 11] },
            ExpectElement(.id(Find.ticks)),

            Press(.id(Find.toggleReplace)),
            Expect.editor("the replace row") { $0.find?.showsReplace == true },
            Click(.id(Find.replaceField)),
            WaitForFocus(.id(Find.replaceField)),
            TypeText("Hi"),
            Press(.id(Find.replace)),
            Expect.editor("line 5 replaced, “1 of 2” left") {
                $0.text == Self.replacedOne && $0.find?.label == "1 of 2" && $0.find?.matchLines == [6, 11]
            },
            // Replace All's own shortcut: a view's key equivalent, not the editor's.
            Key(KeyChord(.returnKey, [.command, .option])),
            Expect.editor("every “Hello” replaced, unsaved") {
                $0.text == Self.replacedAll && $0.find?.label == "No results" && $0.isDirty
            },
            Expect.fileTabs("the edited file's tab kept") { $0 == [StoryFileTab(path: Self.file, preview: false, active: true)] },

            Press(.id(Find.close)),
            ExpectElement(.id(Find.ticks), .absent),
            WaitForFocus(.editor),
            Key(.cmd("s")),
            Expect.editor("the file saved") { !$0.isDirty },
            Expect.disk(Self.file, Self.replacedAll),

            Press(.gutterChevron(line: 4)),
            Expect.editor("greet()'s body folded away") { $0.hiddenLines == [5, 6, 7] },
            ExpectElement(.foldChip(line: 4)),
            Press(.foldChip(line: 4)),
            Expect.editor("the body back") { $0.hiddenLines.isEmpty && $0.foldCount == 0 },

            Key(.cmd("z")),
            Expect.editor("Replace All undone in one step") { $0.text == Self.replacedOne && $0.isDirty },
            Key(.cmdShift("z")),
            Expect.editor("and redone, matching the disk again") { $0.text == Self.replacedAll && !$0.isDirty },
        ]
    }
}

/// Go to File with a fuzzy query opens a kept tab with the caret in it; Search finds a line, and
/// its result opens the file there in a preview tab.
final class QuickOpenAndSearch: FilesStoryline {
    override class var tags: Set<Tag> { [.files, .gate] }
    override class var files: [(path: String, text: String)] {
        [
            ("Sources/Greet.swift", "func greet() {\n    // TODO: say hello\n    print(\"Hello\")\n}\n"),
            ("Sources/Farewell.swift", "func farewell() {\n    print(\"Bye\")\n}\n"),
            ("Tests/GreetTests.swift", "import Testing\n\n// TODO: test greet\n@Test func greets() {}\n"),
            ("README.md", "# Greeter\n\nNothing to do here.\n"),
        ]
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText("srcgrt"),
            ExpectElement(.quickOpenRow("Sources/Greet.swift")),
            ExpectElement(.quickOpenRow("Tests/GreetTests.swift"), .absent),
            Key(.returnKey),
            Expect("quick open closed") { $0.app.workspace?.storyQuickOpenShown == false },
            Expect.fileTabs("Greet.swift in a kept tab") { $0 == [StoryFileTab(path: "Sources/Greet.swift", preview: false, active: true)] },
            // The caret goes to the file, as its editor comes up: typing lands in it.
            WaitForFocus(.editor),
            TypeText("@"),
            Expect.editor("“@” typed into Greet.swift") { $0.path == "Sources/Greet.swift" && $0.text.hasPrefix("@func greet()") },

            Command(.search),
            WaitForFocus(.id(StoryID.Search.field)),
            TypeText("TODO"),
            Expect.search("a TODO in each Greet file, nowhere else") { search in
                search.query == "TODO"
                    && Set(search.hits) == [StorySearch.Hit(path: "Sources/Greet.swift", line: 2), StorySearch.Hit(path: "Tests/GreetTests.swift", line: 3)]
                    && search.hits.count == 2
            },
            Press(.searchResult("Tests/GreetTests.swift", line: 3)),
            Expect.fileTabs("GreetTests.swift in a preview tab beside it") { tabs in
                tabs == [
                    StoryFileTab(path: "Sources/Greet.swift", preview: false, active: false),
                    StoryFileTab(path: "Tests/GreetTests.swift", preview: true, active: true),
                ]
            },
            Expect.editor("the caret on the TODO's line") { $0.path == "Tests/GreetTests.swift" && $0.caretLine == 3 },
        ]
    }
}

/// A double click on a file in the explorer keeps its tab and puts the caret in it, though both
/// clicks come before the file's editor is built.
final class ExplorerDoubleClick: FilesStoryline {
    override class var tags: Set<Tag> { [.files] }
    override class var files: [(path: String, text: String)] { [("Notes.txt", "first line\nsecond line\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            Click(.treeRow("Notes.txt"), count: 2),
            Expect.fileTabs("Notes.txt in a kept tab") { $0 == [StoryFileTab(path: "Notes.txt", preview: false, active: true)] },
            WaitForFocus(.editor),
            TypeText("@"),
            Expect.editor("“@” typed into Notes.txt") { $0.path == "Notes.txt" && $0.text == "@first line\nsecond line\n" },
        ]
    }
}

/// A chain's row ("a / b") picks the folder a new item goes in, as VS Code's compact folders do:
/// a click on "a" selects it and underlines it, and New File lands in "a", not in "b". A right
/// click on another chain's upper name targets it too.
final class ExplorerChainSegment: FilesStoryline {
    override class var tags: Set<Tag> { [.files] }
    override class var files: [(path: String, text: String)] { [("a/b/inner.txt", ""), ("x/y/inner.txt", "")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            RevealInTree("a/b/inner.txt"),
            RevealInTree("x/y/inner.txt"),
            Click(.id(StoryID.Explorer.segment("a"))),
            Expect("“a” selected and underlined", found: { "\($0.app.workspace?.storyTreeMark ?? "nothing") underlined" }) {
                $0.app.workspace?.storyTreeSelection == "a" && $0.app.workspace?.storyTreeMark == "a"
            },
            ExpectElement(.id(StoryID.Explorer.row("a/b"))),
            Press(.id(StoryID.Explorer.newfile)),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            Expect("“a” underlined over the name field") { $0.app.workspace?.storyTreeMark == "a" },
            TypeText("new.txt"),
            Key(.returnKey),
            Expect("new.txt made in “a”") { $0.app.workspace?.storyHasFile("a/new.txt") == true },
            Expect("and not in “b”") { $0.app.workspace?.storyHasFile("a/b/new.txt") == false },

            RightClick(.id(StoryID.Explorer.segment("x"))), WaitForElement(.id(StoryID.Options.panel)),
            // New Folder…
            Press(.id(StoryID.Options.item(1))),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            TypeText("made"),
            Key(.returnKey),
            Expect("the folder made in “x”") { $0.app.workspace?.storyHasFile("x/made") == true },
        ]
    }
}

/// A ten-folder chain picks any of its names, the last too, as VS Code's compact folders do: a
/// click underlines the name it hits, ← and → step the underline along the chain, and New File
/// lands in the underlined folder. Compress on a name zips that folder beside it.
final class ExplorerChainDeep: FilesStoryline {
    override class var tags: Set<Tag> { [.files] }
    static let chain = (1...10).map { "d\($0)" }
    /// The chain's folder `depth` names down: "d1/d2/…".
    static func folder(_ depth: Int) -> String { chain.prefix(depth).joined(separator: "/") }
    override class var files: [(path: String, text: String)] { [(folder(10) + "/f.txt", "")] }

    private static func marked(_ depth: Int, _ what: String) -> Expect {
        Expect(what, found: { "\($0.app.workspace?.storyTreeSelection ?? "nothing") selected, \($0.app.workspace?.storyTreeMark ?? "nothing") underlined" }) {
            $0.app.workspace?.storyTreeSelection == folder(depth) && $0.app.workspace?.storyTreeMark == folder(depth)
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            RevealInTree(Self.folder(10) + "/f.txt"),
            ExpectElement(.id(StoryID.Explorer.row(Self.folder(10)))),
            Click(.id(StoryID.Explorer.segment(Self.folder(10)))),
            Self.marked(10, "“d10”, the last name, selected and underlined"),
            Click(.id(StoryID.Explorer.segment(Self.folder(5)))),
            Self.marked(5, "“d5” selected and underlined"),
            Key(.left),
            Self.marked(4, "← steps up to “d4”"),
            Key(.right),
            Self.marked(5, "→ steps back down to “d5”"),
            Press(.id(StoryID.Explorer.newfile)),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            Self.marked(5, "“d5” underlined over the name field"),
            TypeText("new.txt"),
            Key(.returnKey),
            Expect("new.txt made in “d5”") { $0.app.workspace?.storyHasFile(Self.folder(5) + "/new.txt") == true },
            Expect("and not in “d10”") { $0.app.workspace?.storyHasFile(Self.folder(10) + "/new.txt") == false },

            // Compress on a chain's name zips that folder beside it, as Finder does.
            RightClick(.id(StoryID.Explorer.segment(Self.folder(3)))), WaitForElement(.id(StoryID.Options.panel)),
            Press(.id(StoryID.Options.item(4))),
            Expect("d3.zip made beside “d3”, not empty", found: { "\($0.app.workspace?.storyFileSize(Self.folder(2) + "/d3.zip") ?? 0) bytes" }) {
                ($0.app.workspace?.storyFileSize(Self.folder(2) + "/d3.zip") ?? 0) > 0
            },
            Expect("and selected") { $0.app.workspace?.storyTreeSelection == Self.folder(2) + "/d3.zip" },
        ]
    }
}

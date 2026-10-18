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

/// Go to File with a fuzzy query opens a kept tab; Search finds a line, and its result opens
/// the file there in a preview tab.
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

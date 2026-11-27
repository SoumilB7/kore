import AppKit
import Foundation
import KoreUI
import src

// The explorer's and Search's controls no other storyline uses as a person does: the title
// bar's Explorer button, the empty folder's New File, a click below the rows, Search's Aa ab .*
// (their keys and their buttons), the files to include and exclude, Clear filters, and the
// transfer bar's Retry and ✕.

/// Picks the open option popup's item titled `title`.
private struct DrivePick: Step {
    let title: String
    var label: String { "Pick “\(title)”" }
    init(_ title: String) { self.title = title }

    func run(_ story: StoryContext) async throws {
        try await WaitForElement(.id(StoryID.Options.panel)).run(story)
        guard let index = StoryMenus.open.firstIndex(of: title) else {
            throw StoryFailure.expectation("“\(title)” in the menu (it has \(StoryMenus.open.filter { !$0.isEmpty }))")
        }
        try await Press(.id(StoryID.Options.item(index))).run(story)
    }
}

/// Search's hits as lines of one file, sorted.
@MainActor private func driveLines(_ search: StorySearch) -> [Int] { search.hits.map(\.line).sorted() }

/// The title bar's Explorer button opens the explorer and closes it.
final class DriveFilesExplorerButton: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("a.txt", "a\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Expect("the explorer closed") { $0.app.workspace?.explorerOpen == false },
            Press(.id(StoryID.Titlebar.explorer)),
            Expect("the button opened it") { $0.app.workspace?.explorerOpen == true },
            WaitForElement(.treeRow("a.txt")),
            Press(.id(StoryID.Titlebar.explorer)),
            Expect("and closed it") { $0.app.workspace?.explorerOpen == false },
        ]
    }
}

/// An empty folder's explorer says so, with New File: it starts a name, and Return makes the file.
final class DriveFilesExplorerEmptyNewFile: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            Press(.id(StoryID.Explorer.state)),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            TypeText("first.txt"),
            Key(.returnKey),
            Expect("first.txt made") { $0.app.workspace?.storyHasFile("first.txt") == true },
        ]
    }
}

/// The window's folder and the one picked for it, as Locate… moves it.
@MainActor private final class DriveLocated {
    weak var workspace: Workspace?
    var found: URL?
}

/// The window's folder deleted: the explorer says so, with Locate…; the folder picked there
/// (the storyline host answers the picker) becomes the window's folder, its files in the tree.
final class DriveFilesExplorerLocate: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("a.txt", "a\n")] }

    override func steps() -> [any Step] {
        let held = DriveLocated()
        let same: @MainActor @Sendable (URL?, URL?) -> Bool = { a, b in
            a != nil && a?.resolvingSymlinksInPath().path == b?.resolvingSymlinksInPath().path
        }
        return super.steps() + [
            Command(.toggleExplorer),
            WaitForElement(.treeRow("a.txt")),
            Do("A folder to pick beside it, with b.txt; the window's folder deleted") { story in
                held.workspace = story.app.workspace
                let found = story.folder.deletingLastPathComponent().appendingPathComponent(story.folder.lastPathComponent + "-found")
                try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
                try "b\n".write(to: found.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
                held.found = found
                StoryHost.pickedFolder = found
                try FileManager.default.removeItem(at: story.folder)
            },
            // The tree reads its folder again and finds it gone.
            Press(.id(StoryID.Explorer.refresh)),
            // Lost first: until then the same button is the unreadable folder's Try Again.
            Expect("the window knows its folder is lost") { _ in held.workspace?.folderLost == true },
            ExpectElement(.id(StoryID.Explorer.state), .visible),
            Press(.id(StoryID.Explorer.state)),
            Expect("Locate… asked for a folder once", found: { _ in "\(StoryHost.picks)" }) { _ in StoryHost.picks == ["Locate"] },
            Expect("the picked folder is the window's now", found: { _ in held.workspace?.folder.path }) { _ in
                same(held.workspace?.folder, held.found) && held.workspace?.folderLost == false
            },
            Expect("its tree lists b.txt", found: { _ in "\(held.workspace?.storyTreeRows ?? [])" }) { _ in
                held.workspace?.storyTreeRows.contains("b.txt") == true
            },
            // The window no longer answers to the storyline's folder: closed here, not by the runner.
            Do("Close the moved window") { _ in held.workspace?.window?.close() },
        ]
    }
}

/// A click in the empty part below the tree's rows clears the selection.
final class DriveFilesExplorerClickBelow: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("docs/a.txt", "a\n"), ("z.txt", "z\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            WaitForElement(.treeRow("z.txt")),
            // A folder's click: a file's would open it.
            Click(.treeRow("docs")),
            Expect("docs chosen", found: { $0.app.workspace?.storyTreeSelection ?? "none" }) {
                $0.app.workspace?.storyTreeSelection == "docs"
            },
            Click(.id(StoryID.Explorer.below)),
            Expect("nothing chosen", found: { $0.app.workspace?.storyTreeSelection ?? "none" }) {
                $0.app.workspace?.storyTreeSelection == nil
            },
        ]
    }
}

/// Search's ⌥⌘C, ⌥⌘W and ⌥⌘R turn match case, whole word and regex on and off.
final class DriveFilesSearchKeys: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("words.txt", "Hello world\nhello there\nhelloworld\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.search),
            WaitForFocus(.id(StoryID.Search.field)),
            TypeText("hello"),
            Expect.search("“hello” on all three lines") { $0.query == "hello" && driveLines($0) == [1, 2, 3] },
            Key(.cmdOption("c")),
            Expect.search("⌥⌘C: only the lowercase two") { driveLines($0) == [2, 3] },
            Key(.cmdOption("c")),
            Expect.search("⌥⌘C again: all three") { driveLines($0) == [1, 2, 3] },
            Key(.cmdOption("w")),
            Expect.search("⌥⌘W: whole words only") { driveLines($0) == [1, 2] },
            Key(.cmdOption("w")),
            Expect.search("⌥⌘W again: all three") { driveLines($0) == [1, 2, 3] },
            Key(.cmd("a")),
            TypeText("h.llo"),
            Expect.search("“h.llo” as plain text finds nothing") { $0.query == "h.llo" && $0.hits.isEmpty },
            Key(.cmdOption("r")),
            Expect.search("⌥⌘R: “h.llo” as a pattern finds all three") { driveLines($0) == [1, 2, 3] },
        ]
    }
}

/// Search's Aa and ab buttons, clicked.
final class DriveFilesSearchToggles: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("words.txt", "Hello world\nhello there\nhelloworld\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.search),
            WaitForFocus(.id(StoryID.Search.field)),
            TypeText("hello"),
            Expect.search("“hello” on all three lines") { $0.query == "hello" && driveLines($0) == [1, 2, 3] },
            Press(.id(StoryID.Search.matchCase)),
            Expect.search("Aa: only the lowercase two") { driveLines($0) == [2, 3] },
            Press(.id(StoryID.Search.wholeWord)),
            Expect.search("Aa and ab: “hello” alone, line 2") { driveLines($0) == [2] },
            Press(.id(StoryID.Search.matchCase)),
            Press(.id(StoryID.Search.wholeWord)),
            Expect.search("both off: all three") { driveLines($0) == [1, 2, 3] },
        ]
    }
}

/// Files to include narrow the results, files to exclude take them away, and Clear filters
/// under no results brings them all back.
final class DriveFilesSearchFilters: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("a.txt", "hello a\n"), ("b.md", "hello b\n")] }

    override func steps() -> [any Step] {
        let include = StoryID.Search.include.part(.field)
        let exclude = StoryID.Search.exclude.part(.field)
        return super.steps() + [
            Command(.search),
            WaitForFocus(.id(StoryID.Search.field)),
            TypeText("hello"),
            Expect.search("a hit in each file") { Set($0.hits.map(\.path)) == ["a.txt", "b.md"] },
            Press(.id(StoryID.Search.filters)),
            Click(.id(include)),
            WaitForFocus(.id(include)),
            TypeText("*.md"),
            Expect.search("only b.md's") { $0.hits.map(\.path) == ["b.md"] },
            Expect("“*.md” to include", found: { $0.app.workspace?.storySearchInclude }) { $0.app.workspace?.storySearchInclude == "*.md" },
            Click(.id(exclude)),
            WaitForFocus(.id(exclude)),
            TypeText("*.md"),
            Expect.search("none left") { $0.query == "hello" && $0.hits.isEmpty },
            Press(.id(StoryID.Search.clearFilters)),
            Expect("the filters cleared", found: { $0.app.workspace?.storySearchInclude }) { $0.app.workspace?.storySearchInclude == "" },
            Expect.search("both files' hits back") { Set($0.hits.map(\.path)) == ["a.txt", "b.md"] },
        ]
    }
}

/// A copy that fails stays on the explorer's transfer bar with Retry; Retry, once the file can
/// be read, copies it.
final class DriveFilesTransferRetry: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("notes.txt", "n\n")] }

    override func steps() -> [any Step] {
        let retried = DriveChatNote(false)
        return super.steps() + [
            Command(.toggleExplorer),
            WaitForElement(.treeRow("notes.txt")),
            Do("A copy into the folder stopped") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the window") }
                let id = workspace.storyFailedTransfer("Copying big.bin") { retried.value = true }
                story.atFinish { [weak workspace] in workspace?.storyForgetTransfer(id) }
            },
            ExpectElement(.id(StoryID.Explorer.transfer("Retry")), .visible),
            Press(.id(StoryID.Explorer.transfer("Retry"))),
            Expect("Retry ran the copy again") { _ in retried.value },
        ]
    }
}

/// A chat paste that fails stays on the explorer's transfer bar; its ✕ takes it away. The chat
/// is one History lists whose session isn't on this Mac, copied and pasted in its own folder.
final class DriveFilesTransferDismiss: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }
    static let missing = UUID().uuidString.lowercased()

    override func steps() -> [any Step] {
        let row = Locator.id(StoryID.History.row(Self.missing))
        return super.steps() + [
            Send("hello"), TurnFinished(1),
            Do("History lists a chat whose session isn't on this Mac") { story in
                let chat = try story.activeChat()
                ScriptedWorld.shared.list(Self.missing, provider: chat.provider.id, folder: chat.folder, title: "Elsewhere")
            },
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(row),
            RightClick(row),
            DrivePick("Copy"),
            RightClick(row),
            DrivePick("Paste Chat"),
            ExplorerShown(),
            ExpectElement(.id(StoryID.Explorer.transferDismiss), .visible, timeout: .seconds(15)),
            DriveChatSettle(),
            Press(.id(StoryID.Explorer.transferDismiss)),
            ExpectElement(.id(StoryID.Explorer.transferDismiss), .absent),
            // The chat clipboard is app-wide: a cut pasted where it is takes it, so later
            // storylines' menus have no Paste Chat.
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(row),
            RightClick(row),
            DrivePick("Cut"),
            RightClick(row),
            DrivePick("Paste Chat"),
        ]
    }
}

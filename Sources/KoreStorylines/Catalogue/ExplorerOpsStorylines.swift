import AppKit
import KoreUI

// The explorer as VS Code's: several rows chosen with ⌘ and ⇧, and what acts on them (trash,
// move, cut / copy / paste, duplicate), undo, Open in Terminal, Find in Folder, type to jump,
// the active file revealed, and a drop from outside copying in.

/// Answers Kore's confirmations ("trash", "move") with yes, and counts them.
@MainActor final class Confirms {
    var asked: [String] = []
    func install() { StorylineSeams.confirm = { [unowned self] what in asked.append(what); return true } }
    func remove() { StorylineSeams.confirm = nil }
}

/// Picks a title from the tree's menu on a row: a right-click, then that item.
struct TreeMenuItem: Step {
    let row: String
    let title: String
    /// What's right-clicked: the row, or a chain's name (`StoryID.Explorer.segment`).
    let target: Locator?
    /// The menu is already open (a right-click done by an earlier step).
    let opened: Bool
    var label: String { "“\(title)” on “\(row)”" }
    init(_ row: String, _ title: String, on target: Locator? = nil, opened: Bool = false) {
        self.row = row
        self.title = title
        self.target = target
        self.opened = opened
    }

    func run(_ story: StoryContext) async throws {
        if !opened {
            try await RightClick(target ?? .treeRow(row)).run(story)
            try await WaitForElement(.id(StoryID.Options.panel)).run(story)
        }
        guard let index = story.app.workspace?.storyTreeMenuIndex(row, title) else {
            throw StoryFailure.other("no “\(title)” in the menu on “\(row)”")
        }
        // The menu is taller than its 260pt panel: its later items scroll into view first.
        let item = Locator.id(StoryID.Options.item(index))
        if index > 6 { try await Scroll(item, to: .by(CGFloat(index - 4) * 26)).run(story) }
        try await Press(item).run(story)
    }
}

@MainActor private func chosen(_ story: StoryContext) -> [String] { story.app.workspace?.storyTreeChosen ?? [] }

/// ⌘-click adds a row, ⇧-click takes a range from the anchor, ⇧↓ / ⇧↑ grow and shrink it,
/// Esc goes back to one. ⌘⌫ trashes the three chosen with one question, ⌘Z brings them all
/// back, and two chosen rows dragged on a folder move together with one question.
final class ExplorerMultiSelect: FilesStoryline {
    override class var tags: Set<Tag> { [.files, .gate] }
    override class var files: [(path: String, text: String)] {
        ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "dest/keep.txt"].map { ($0, $0 + "\n") }
    }
    private let confirms = Confirms()

    override func steps() -> [any Step] {
        super.steps() + [
            Do("answer confirmations") { [confirms] _ in confirms.install() },
            Command(.toggleExplorer),
            WaitForElement(.treeRow("e.txt")),
            Click(.treeRow("a.txt")),
            Click(.treeRow("c.txt"), modifiers: .command),
            Expect("⌘-click chose a and c", found: { chosen($0).joined(separator: ", ") }) { chosen($0) == ["a.txt", "c.txt"] },
            Click(.treeRow("b.txt")),
            Click(.treeRow("d.txt"), modifiers: .shift),
            Expect("⇧-click chose b to d", found: { chosen($0).joined(separator: ", ") }) { chosen($0) == ["b.txt", "c.txt", "d.txt"] },
            Key(KeyChord(.down, .shift)),
            Expect("⇧↓ grew it to e", found: { chosen($0).joined(separator: ", ") }) { chosen($0) == ["b.txt", "c.txt", "d.txt", "e.txt"] },
            Key(KeyChord(.up, .shift)),
            Expect("⇧↑ shrank it back", found: { chosen($0).joined(separator: ", ") }) { chosen($0) == ["b.txt", "c.txt", "d.txt"] },
            Snapshot("explorer-three-chosen"),
            Key(KeyChord(.backspace, .command)),
            Expect("one question, three trashed", found: { [confirms] _ in confirms.asked.joined(separator: ", ") }) { [confirms] story in
                confirms.asked == ["trash"] && ["b.txt", "c.txt", "d.txt"].allSatisfy { story.app.workspace?.storyHasFile($0) == false }
            },
            Do("⌘Z") { $0.app.workspace?.storyUndo() },
            Expect("⌘Z brought all three back") { story in ["b.txt", "c.txt", "d.txt"].allSatisfy { story.app.workspace?.storyHasFile($0) == true } },
            // The rows are back on screen before they're clicked (a missing row is revealed, which selects it).
            WaitForElement(.treeRow("b.txt")),
            Click(.treeRow("a.txt")),
            Click(.treeRow("b.txt"), modifiers: .command),
            Expect("a and b chosen", found: { chosen($0).joined(separator: ", ") }) { chosen($0) == ["a.txt", "b.txt"] },
            Do("drag them on dest") { $0.app.workspace?.storyTreeDragChosen(into: "dest") },
            Expect("both moved with one question", found: { [confirms] _ in confirms.asked.joined(separator: ", ") }) { [confirms] story in
                guard let w = story.app.workspace else { return false }
                return confirms.asked == ["trash", "move"] && w.storyHasFile("dest/a.txt") && w.storyHasFile("dest/b.txt")
                    && !w.storyHasFile("a.txt") && !w.storyHasFile("b.txt")
            },
            Key(.escape),
            Expect("Esc leaves one row chosen") { chosen($0).count <= 1 },
            Do("stop answering") { [confirms] _ in confirms.remove() },
        ]
    }
}

/// Copy and Paste make "a copy.txt"; Cut and Paste move into a folder; Duplicate makes "b copy";
/// a rename is undone and redone; Open in Terminal starts a shell in the folder; Find in Folder
/// scopes Search to it; typing jumps to a name; opening the explorer reveals the active file;
/// a drop from outside copies the file in.
final class ExplorerFileOps: FilesStoryline {
    override class var tags: Set<Tag> { [.files, .gate] }
    override class var files: [(path: String, text: String)] {
        [("a.txt", "a\n"), ("b.txt", "b\n"), ("zeta.txt", "z\n"), ("dest/keep.txt", "k\n"), ("deep/inner/x.txt", "x\n")]
    }
    private let confirms = Confirms()
    private static let outside = FileManager.default.temporaryDirectory.appendingPathComponent("kore-outside-\(UUID().uuidString).txt")

    override func steps() -> [any Step] {
        super.steps() + [
            Do("answer confirmations, and a file outside the folder") { [confirms] _ in
                confirms.install()
                try "outside\n".write(to: Self.outside, atomically: true, encoding: .utf8)
            },
            Command(.toggleExplorer),
            WaitForElement(.treeRow("zeta.txt")),
            // Copy, then Paste beside it: "a copy.txt".
            TreeMenuItem("a.txt", "Copy"),
            TreeMenuItem("a.txt", "Paste"),
            Expect("pasted as “a copy.txt”") { $0.app.workspace?.storyHasFile("a copy.txt") == true },
            // Cut, then Paste on dest: moved.
            TreeMenuItem("a copy.txt", "Cut"),
            TreeMenuItem("dest", "Paste"),
            Expect("cut and pasted into dest") { s in
                s.app.workspace?.storyHasFile("dest/a copy.txt") == true && s.app.workspace?.storyHasFile("a copy.txt") == false
            },
            Do("⌘Z") { $0.app.workspace?.storyUndo() },
            Expect("⌘Z put it back") { s in
                s.app.workspace?.storyHasFile("a copy.txt") == true && s.app.workspace?.storyHasFile("dest/a copy.txt") == false
            },
            // Duplicate.
            TreeMenuItem("b.txt", "Duplicate"),
            Expect("duplicated as “b copy.txt”") { $0.app.workspace?.storyHasFile("b copy.txt") == true },
            // Rename, undone and redone.
            TreeMenuItem("b copy.txt", "Rename…"),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            Key(.cmd("a")),
            TypeText("renamed.txt"),
            Key(.returnKey),
            Expect("renamed") { $0.app.workspace?.storyHasFile("renamed.txt") == true },
            Do("⌘Z") { $0.app.workspace?.storyUndo() },
            Expect("⌘Z undid the rename") { s in
                s.app.workspace?.storyHasFile("b copy.txt") == true && s.app.workspace?.storyHasFile("renamed.txt") == false
            },
            Do("⇧⌘Z") { $0.app.workspace?.storyRedo() },
            Expect("⇧⌘Z did it again") { $0.app.workspace?.storyHasFile("renamed.txt") == true },
            // Open in Terminal: a shell in dest.
            TreeMenuItem("dest", "Open in Terminal"),
            Expect("a shell started in dest", found: { $0.app.workspace?.storyTerminalFolder ?? "none" }) { s in
                s.app.workspace?.storyTerminalFolder?.hasSuffix("/dest") == true
            },
            // Find in Folder: Search scoped to deep.
            TreeMenuItem("deep", "Find in Folder…"),
            Expect("Search's include is ./deep/**", found: { $0.app.workspace?.storySearchInclude ?? "none" }) {
                $0.app.workspace?.storySearchInclude == "./deep/**"
            },
            // Type to jump (back on the tree first: Search took the sidebar).
            Command(.toggleExplorer),
            WaitForElement(.treeRow("a.txt")),
            Click(.treeRow("a.txt")),
            TypeText("ze"),
            Expect("typing “ze” chose zeta.txt", found: { $0.app.workspace?.storyTreeSelection ?? "none" }) {
                $0.app.workspace?.storyTreeSelection == "zeta.txt"
            },
            // Reveal: the active file shows in the tree when it opens.
            Click(.treeRow("deep/inner/x.txt"), count: 2),
            Expect.fileTabs("x.txt open") { tabs in tabs.contains { $0.path == "deep/inner/x.txt" && $0.active } },
            // Another row chosen (a folder: a file's click would open it instead).
            Click(.treeRow("dest")),
            Command(.toggleExplorer),
            Command(.toggleExplorer),
            Expect("the active file revealed", found: { $0.app.workspace?.storyTreeSelection ?? "none" }) {
                $0.app.workspace?.storyTreeSelection == "deep/inner/x.txt"
            },
            // A drop from outside copies in.
            Do("drop a file from outside on dest") { $0.app.workspace?.storyTreeDropFromOutside([Self.outside.path], into: "dest") },
            Expect("copied in, the original kept") { s in
                s.app.workspace?.storyHasFile("dest/" + Self.outside.lastPathComponent) == true
                    && FileManager.default.fileExists(atPath: Self.outside.path)
            },
            Do("clean up") { [confirms] _ in
                confirms.remove()
                try? FileManager.default.removeItem(at: Self.outside)
            },
        ]
    }
}

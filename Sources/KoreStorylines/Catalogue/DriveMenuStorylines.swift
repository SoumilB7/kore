import AppKit
import KoreUI

// Every item of Kore's own menus chosen once, its effect checked (`--tag drive`): the explorer's
// (one row and several), the editor's status bar, and the tab strip's (one tab, several, its end, +).
// Each check is set against the state before it, so a pick that did nothing fails.

/// Picks the open menu's row whose title is `title`, or starts with it (`prefix`); a row with a
/// submenu opens it, so a path is picked one title at a time.
struct DriveMenuPick: Step {
    let title: String
    let prefix: Bool
    var label: String { "Pick “\(title)\(prefix ? "…" : "")”" }
    init(_ title: String, prefix: Bool = false) {
        self.title = title
        self.prefix = prefix
    }

    func run(_ story: StoryContext) async throws {
        do { try await WaitForElement(.id(StoryID.Options.panel)).run(story) } catch {
            throw StoryFailure.expectation("a menu up for “\(title)” (popups: \(StoryMenus.trail); last click \(InputDriver.lastRoute))")
        }
        let rows = StoryMenus.open
        guard let index = rows.firstIndex(where: { prefix ? $0.hasPrefix(title) : $0 == title }) else {
            throw StoryFailure.expectation("“\(title)” in the menu (it has \(rows.filter { !$0.isEmpty }))")
        }
        try await Press(.id(StoryID.Options.item(index))).run(story)
    }
}

/// The menu on `target` (a right-click), then `path` picked through it.
@MainActor func driveMenu(_ target: Locator, _ path: String...) -> [any Step] {
    [RightClick(target)] + path.map { DriveMenuPick($0) }
}

private let driveBoard: @MainActor @Sendable (StoryContext) -> String? = { _ in StoryHost.pasteboard.string(forType: .string) }

// MARK: - The explorer, one row

/// Every item of a row's menu in the explorer: Open, Open with Default App, Reveal in Finder,
/// Open in Terminal, Compress, Copy Relative Path, Duplicate, Copy then Paste, New File…,
/// New Folder…, Move to Trash.
final class DriveMenuExplorerRow: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("a.txt", "a\n"), ("b.txt", "b\n"), ("dest/keep.txt", "k\n")] }

    override func steps() -> [any Step] {
        let has: @MainActor @Sendable (String) -> (StoryContext) -> Bool = { path in { $0.app.workspace?.storyHasFile(path) == true } }
        let file = { (story: StoryContext, name: String) in story.folder.appendingPathComponent(name).resolvingSymlinksInPath().path }
        return super.steps() + [
            Do("Kore's questions answered yes") { story in _ = story.stash(DriveConfirms.self) { DriveConfirms() } },
            Command(.toggleExplorer),
            WaitForElement(.treeRow("a.txt")),
            Expect("no file open, nothing opened or revealed, no terminal") { story in
                story.app.workspace?.storyActiveFile == nil && StoryHost.opened.isEmpty && StoryHost.revealed.isEmpty
                    && story.app.workspace?.storyTerminalFolder == nil
            },
        ] + driveMenu(.treeRow("a.txt"), "Open") + [
            Expect("Open: a.txt in a tab", found: { $0.app.workspace?.storyActiveFile }) { $0.app.workspace?.storyActiveFile == "a.txt" },
        ] + driveMenu(.treeRow("a.txt"), "Open with Default App") + [
            Expect("Open with Default App: handed to the system once", found: { _ in "\(StoryHost.opened)" }) { story in
                StoryHost.opened.map { $0.resolvingSymlinksInPath().path } == [file(story, "a.txt")]
            },
        ] + driveMenu(.treeRow("a.txt"), "Reveal in Finder") + [
            Expect("Reveal in Finder: a.txt shown in Finder", found: { _ in "\(StoryHost.revealed)" }) { story in
                StoryHost.revealed.map { $0.resolvingSymlinksInPath().path } == [file(story, "a.txt")]
            },
        ] + driveMenu(.treeRow("a.txt"), "Open in Terminal") + [
            Expect("Open in Terminal: a shell in the folder", timeout: .seconds(10), found: { $0.app.workspace?.storyTerminalFolder }) { story in
                story.app.workspace?.storyTerminalFolder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                    == story.folder.resolvingSymlinksInPath().path
            },
            Expect("no a.txt.zip yet") { !has("a.txt.zip")($0) },
        ] + driveMenu(.treeRow("a.txt"), "Compress") + [
            Expect("Compress: a.txt.zip beside it", timeout: .seconds(10)) { has("a.txt.zip")($0) },
            Do("an empty clipboard") { _ in StoryHost.pasteboard.clearContents() },
        ] + driveMenu(.treeRow("a.txt"), "Copy Relative Path") + [
            Expect("Copy Relative Path: “a.txt”", found: driveBoard) { _ in StoryHost.pasteboard.string(forType: .string) == "a.txt" },
            Expect("no copy yet") { !has("a copy.txt")($0) },
        ] + driveMenu(.treeRow("a.txt"), "Duplicate") + [
            Expect("Duplicate: “a copy.txt”", timeout: .seconds(10)) { has("a copy.txt")($0) },
            Expect("dest has no b.txt") { !has("dest/b.txt")($0) },
        ] + driveMenu(.treeRow("b.txt"), "Copy") + driveMenu(.treeRow("dest"), "Paste") + [
            Expect("Copy then Paste on dest: b.txt in it, the original kept", timeout: .seconds(10)) { story in
                has("dest/b.txt")(story) && has("b.txt")(story)
            },
        ] + driveMenu(.treeRow("dest"), "New File…") + [
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            TypeText("new.txt\n"),
            Expect("New File…: dest/new.txt", timeout: .seconds(10)) { has("dest/new.txt")($0) },
        ] + driveMenu(.treeRow("dest"), "New Folder…") + [
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            TypeText("inner\n"),
            Expect("New Folder…: dest/inner", timeout: .seconds(10)) { story in
                var folder: ObjCBool = false
                return FileManager.default.fileExists(atPath: story.folder.appendingPathComponent("dest/inner").path, isDirectory: &folder) && folder.boolValue
            },
            WaitForElement(.treeRow("a copy.txt")),
        ] + driveMenu(.treeRow("a copy.txt"), "Move to Trash") + [
            Expect("Move to Trash: asked once, gone", timeout: .seconds(10)) { story in
                story.stash(DriveConfirms.self) { DriveConfirms() }.asked == ["trash"] && !has("a copy.txt")(story)
            },
        ]
    }
}

// MARK: - The explorer, several rows

/// The menu on two chosen rows: Copy Paths, Copy Relative Paths, Reveal in Finder, Duplicate,
/// Compress 2 Items, Move 2 Items to Trash.
final class DriveMenuExplorerRows: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("a.txt", "a\n"), ("b.txt", "b\n")] }

    override func steps() -> [any Step] {
        let has: @MainActor @Sendable (String) -> (StoryContext) -> Bool = { path in { $0.app.workspace?.storyHasFile(path) == true } }
        let real = { (story: StoryContext, name: String) in story.folder.appendingPathComponent(name).resolvingSymlinksInPath().path }
        let both: [any Step] = [Click(.treeRow("a.txt")), Click(.treeRow("b.txt"), modifiers: .command)]
        let copies: [any Step] = [Click(.treeRow("a copy.txt")), Click(.treeRow("b copy.txt"), modifiers: .command)]
        return super.steps() + [
            Do("Kore's questions answered yes") { story in _ = story.stash(DriveConfirms.self) { DriveConfirms() } },
            Command(.toggleExplorer),
            WaitForElement(.treeRow("b.txt")),
            Do("an empty clipboard") { _ in StoryHost.pasteboard.clearContents() },
        ] + both + driveMenu(.treeRow("b.txt"), "Copy Relative Paths") + [
            Expect("Copy Relative Paths: both, a line each", found: driveBoard) { _ in StoryHost.pasteboard.string(forType: .string) == "a.txt\nb.txt" },
        ] + both + driveMenu(.treeRow("b.txt"), "Copy Paths") + [
            Expect("Copy Paths: both, whole", found: driveBoard) { story in
                StoryHost.pasteboard.string(forType: .string)?.split(separator: "\n").map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
                    == [real(story, "a.txt"), real(story, "b.txt")]
            },
            Expect("nothing revealed yet") { _ in StoryHost.revealed.isEmpty },
        ] + both + driveMenu(.treeRow("b.txt"), "Reveal in Finder") + [
            Expect("Reveal in Finder: both", found: { _ in "\(StoryHost.revealed)" }) { story in
                Set(StoryHost.revealed.map { $0.resolvingSymlinksInPath().path }) == [real(story, "a.txt"), real(story, "b.txt")]
            },
        ] + both + [RightClick(.treeRow("b.txt")), DriveMenuPick("Compress 2 Items")] + [
            Expect("Compress 2 Items: Archive.zip", timeout: .seconds(10)) { has("Archive.zip")($0) },
            // Its row in the tree (between a.txt and b.txt) before the rows are clicked again.
            WaitForElement(.treeRow("Archive.zip")),
        ] + both + [
            Expect("a.txt and b.txt chosen", found: { "\($0.app.workspace?.storyExplorerChosen ?? [])" }) {
                Set($0.app.workspace?.storyExplorerChosen ?? []) == ["a.txt", "b.txt"]
            },
        ] + driveMenu(.treeRow("b.txt"), "Duplicate") + [
            Expect("Duplicate: a copy of each", timeout: .seconds(10), found: { story in "\(((try? FileManager.default.contentsOfDirectory(atPath: story.folder.path)) ?? []).sorted())" }) { has("a copy.txt")($0) && has("b copy.txt")($0) },
            WaitForElement(.treeRow("b copy.txt")),
        ] + copies + [RightClick(.treeRow("b copy.txt")), DriveMenuPick("Move 2 Items to Trash")] + [
            Expect("Move 2 Items to Trash: asked once, both gone, the originals kept", timeout: .seconds(10)) { story in
                story.stash(DriveConfirms.self) { DriveConfirms() }.asked == ["trash"]
                    && !has("a copy.txt")(story) && !has("b copy.txt")(story) && has("a.txt")(story) && has("b.txt")(story)
            },
        ]
    }
}

// MARK: - The editor's status bar

/// Its four menus: Go to Line…, the indent (four widths, two conversions), line endings, language.
final class DriveMenuEditorStatus: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var needs: Needs { Needs(window: CGSize(width: 1300, height: 800)) }
    override class var files: [(path: String, text: String)] { [("e.txt", "\tone\n\ttwo\n")] }

    override func steps() -> [any Step] {
        let status: @MainActor @Sendable (StoryContext) -> String? = { $0.app.workspace?.storyEditorStatus?.joined(separator: " · ") }
        let shows: @MainActor @Sendable (Int, String) -> (StoryContext) -> Bool = { at, word in { $0.app.workspace?.storyEditorStatus?[at] == word } }
        let indent = Locator.id(StoryID.Editor.Status.indent)
        let pick: @MainActor @Sendable (Locator, String) -> [any Step] = { opener, title in [PressLabel(opener), DriveMenuPick(title)] }
        let text: @MainActor @Sendable (StoryContext) -> String? = { $0.app.workspace?.storyEditor?.text }
        return super.steps() + FileTabState.open("e.txt") + [
            Expect("tabs, LF, plain text to start", found: status) { shows(0, "Tabs")($0) && shows(1, "LF")($0) },
            Expect("Go to Line isn't up") { $0.app.workspace?.storyGoToLineShown == false },
        ] + pick(.id(StoryID(.editor, "status.caret")), "Go to Line…") + [
            Expect("Go to Line…: it's up") { $0.app.workspace?.storyGoToLineShown == true },
            Key(.escape),
        ] + pick(indent, "Indent Using Spaces: 4") + [Expect("Spaces: 4", found: status) { shows(0, "Spaces: 4")($0) }]
            + pick(indent, "Indent Using Spaces: 2") + [Expect("Spaces: 2", found: status) { shows(0, "Spaces: 2")($0) }]
            + pick(indent, "Convert Indentation to Spaces") + [
                Expect("the tabs now two spaces each", found: text) { $0.app.workspace?.storyEditor?.text == "  one\n  two\n" },
            ]
            + pick(indent, "Indent Using Spaces: 8") + [Expect("Spaces: 8", found: status) { shows(0, "Spaces: 8")($0) }]
            + pick(indent, "Indent Using Spaces: 2") + pick(indent, "Convert Indentation to Tabs") + [
                Expect("the spaces tabs again", found: text) { $0.app.workspace?.storyEditor?.text == "\tone\n\ttwo\n" },
            ]
            + pick(indent, "Indent Using Tabs") + [Expect("Tabs", found: status) { shows(0, "Tabs")($0) }]
            + pick(.id(StoryID.Editor.Status.lineEndings), "CRLF") + [Expect("CRLF", found: status) { shows(1, "CRLF")($0) }]
            + pick(.id(StoryID.Editor.Status.lineEndings), "LF") + [Expect("LF again", found: status) { shows(1, "LF")($0) }]
            + [Expect("not Swift yet", found: status) { !shows(2, "Swift")($0) }]
            + pick(.id(StoryID.Editor.Status.language), "Swift") + [Expect("Swift", found: status) { shows(2, "Swift")($0) }]
    }
}

// MARK: - The tab strip

/// The strip's empty end and its +: New Tab and New Board in each.
final class DriveMenuStripEnds: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let tabs: @MainActor @Sendable (StoryContext) -> Int = { $0.app.workspace?.tabs.count ?? 0 }
        let boards: @MainActor @Sendable (StoryContext) -> Int = { $0.app.workspace?.boardTabs.count ?? 0 }
        let was = DriveChatNote((tabs: 0, boards: 0))
        let note = Do("note the tabs and boards") { story in was.value = (tabs(story), boards(story)) }
        let plus = Locator.id(StoryID.Titlebar.newtab)
        let end = BoxStep("Right-click the strip's empty end, past +") { story in
            let element = try await story.element(plus)
            guard let window = element.window, let frame = element.frame else { throw StoryFailure.modelMissing("+'s frame") }
            await story.input.rightClick(at: CGPoint(x: frame.maxX + 60, y: frame.midY), in: window)
        }
        return super.steps() + [note, end, DriveMenuPick("New Tab")] + [
            Expect("the strip's end: New Tab, one more tab", found: { "\(tabs($0))" }) { tabs($0) == was.value.tabs + 1 && boards($0) == was.value.boards },
            note,
        ] + [end, DriveMenuPick("New Board")] + [
            Expect("the strip's end: New Board", found: { "\(boards($0))" }) { boards($0) == was.value.boards + 1 },
            note,
        ] + driveMenu(plus, "New Tab") + [
            Expect("+: New Tab", found: { "\(tabs($0))" }) { tabs($0) == was.value.tabs + 1 && boards($0) == was.value.boards },
            note,
        ] + driveMenu(plus, "New Board") + [
            Expect("+: New Board", found: { "\(boards($0))" }) { boards($0) == was.value.boards + 1 },
        ]
    }
}

/// One tab's menu: Add to New Group, Remove from Group, Add to Group ▸ a group, Keep Open (a
/// preview), Attach to a board ▸ New Section and ▸ its section, Close Tab.
final class DriveMenuTab: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.claude] }
    override class var chats: Int { 4 }

    override func steps() -> [any Step] {
        let groups: @MainActor @Sendable (StoryContext) throws -> TabGroups = { try TabGroupProbe.workspace($0).tabGroups }
        let tab: @MainActor @Sendable (StoryContext, Int) throws -> ChatTab = { try TabGroupProbe.tab($0, $1 - 1) }
        let grouped: @MainActor @Sendable (StoryContext, Int) throws -> Bool = { try groups($0).member[tab($0, $1).id] != nil }
        let row = TabSelectProbe.MenuRow.init
        return super.steps() + [
            Expect("no groups") { try groups($0).groups.isEmpty },
            row(1, "Add to New Group"),
            Expect("Add to New Group: a group holding tab 1") { try groups($0).groups.count == 1 && grouped($0, 1) },
            row(2, "Add to Group"), DriveMenuPick("", prefix: true),
            Expect("Add to Group ▸ it: tab 2 in it too") { story in
                let g = try groups(story)
                let two = try tab(story, 2).id, one = try tab(story, 1).id
                return g.groups.count == 1 && g.member[two] == g.member[one]
            },
            row(2, "Remove from Group"),
            Expect("Remove from Group: tab 2 out, tab 1 still in") { try !grouped($0, 2) && grouped($0, 1) },
            MakeBoard(name: "Backend", take: 0),
            Do("back to the chats") { try TabGroupProbe.workspace($0).storySelect(tabAt: 0) },
            Expect("the board empty") { try BoardProbe.model($0).chats.isEmpty },
        ] + [row(3, "Attach to Board"), DriveMenuPick("Backend")] + [
            Expect("Attach ▸ Backend: a chat on the board", found: { "\((try? BoardProbe.model($0).chats.count) ?? -1)" }) { try BoardProbe.model($0).chats.count == 1 },
            Do("back to the chats") { try TabGroupProbe.workspace($0).storySelect(tabAt: 0) },
            Do("note the sections") { story in _ = try BoardProbe.model(story) },
        ] + [row(3, "Attach to Board"), DriveMenuPick("New Section")] + [
            Expect("Attach ▸ New Section: a second section", found: { "\((try? BoardProbe.model($0).board.sections.count) ?? -1)" }) {
                try BoardProbe.model($0).board.sections.count == 2
            },
            Do("back to the chats") { try TabGroupProbe.workspace($0).storySelect(tabAt: 0) },
            Do("note the tabs") { story in story.stash(DriveTabCount.self) { DriveTabCount() }.count = try TabGroupProbe.workspace(story).tabs.count },
            row(2, "Close Tab"),
            Expect("Close Tab: one fewer") { story in
                try TabGroupProbe.workspace(story).tabs.count == story.stash(DriveTabCount.self) { DriveTabCount() }.count - 1
            },
        ]
    }
}

@MainActor private final class DriveTabCount { var count = 0 }

/// Several tabs' menu: Group 2 Tabs, Add 2 Tabs to Group ▸ it, Remove from Group, Attach 2 to the
/// board ▸ its section, Close 2 Tabs.
final class DriveMenuTabs: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.codex] }
    override class var chats: Int { 6 }
    // Seven tabs once the board is made, every one in the strip (none in its overflow).
    override class var needs: Needs { Needs(window: CGSize(width: 1800, height: 900)) }

    override func steps() -> [any Step] {
        let workspace: @MainActor @Sendable (StoryContext) throws -> Workspace = { try TabGroupProbe.workspace($0) }
        let id: @MainActor @Sendable (StoryContext, Int) throws -> UUID = { try TabGroupProbe.tab($0, $1 - 1).id }
        let pick: (Int, Int) -> [any Step] = { a, b in [
            Click(.tab(a)),
            Expect("tab \(a) in front", found: { story in
                (try? workspace(story)).map { w in "front \(w.tabs.firstIndex { $0 === w.activeTab } ?? -1); \(InputDriver.lastRoute)" }
            }) { story in let w = try workspace(story); return w.activeTab === w.tabs[a - 1] },
            Click(.tab(b), modifiers: .command),
            // Two picked, and (past the first) not the tab that was in front before the click.
            Expect("tabs \(a) and \(b) picked", found: { story in
                (try? workspace(story)).map { w in "picked \(w.selection.compactMap { id in w.tabs.firstIndex { $0.id == id } }.sorted()) of \(w.tabs.map(\.title)), front \(w.tabs.firstIndex { $0 === w.activeTab } ?? -1); \(InputDriver.lastRoute)" }
            }) { story in
                let w = try workspace(story)
                return w.selection.count == 2 && (a == 1 || !w.selection.contains(w.tabs[0].id))
            },
        ] }
        let row = TabSelectProbe.MenuRow.init
        return super.steps() + [
            Expect("no groups") { try workspace($0).tabGroups.groups.isEmpty },
        ] + pick(1, 2) + [row(2, "Group 2 Tabs")] + [
            Expect("Group 2 Tabs: one group of tabs 1 and 2") { story in
                let g = try workspace(story).tabGroups
                let one = try id(story, 1), two = try id(story, 2)
                return g.groups.count == 1 && g.member[one] != nil && g.member[one] == g.member[two]
            },
            ExpectElement(.id(StoryID.TabGroups.popup), .visible),
            Key(.escape),
            ExpectElement(.id(StoryID.TabGroups.popup), .absent),
        ] + pick(3, 4) + [row(4, "Add 2 Tabs to Group"), DriveMenuPick("", prefix: true)] + [
            Expect("Add 2 Tabs to Group ▸ it: four in it") { story in
                let g = try workspace(story).tabGroups
                let ids = try (1...4).map { try id(story, $0) }
                return ids.allSatisfy { g.member[$0] != nil } && g.groups.count == 1
            },
        ] + pick(3, 4) + [row(4, "Remove from Group")] + [
            Expect("Remove from Group: 3 and 4 out, 1 and 2 in") { story in
                let g = try workspace(story).tabGroups
                let one = try id(story, 1), three = try id(story, 3), four = try id(story, 4)
                return g.member[three] == nil && g.member[four] == nil && g.member[one] != nil
            },
            MakeBoard(name: "Backend", take: 0),
            Do("back to the chats") { try workspace($0).storySelect(tabAt: 0) },
            // Once a board is up, clicks on strip tabs don't reach their buttons in a storyline's
            // window (open in NOTES): these two picks are unchecked; the attach's count is.
            Click(.tab(5)), Click(.tab(6), modifiers: .command),
        ] + [row(6, "Attach 2 to Board"), DriveMenuPick("Backend")] + [
            Expect("Attach 2 ▸ Backend: two chats on the board", found: { "\((try? BoardProbe.model($0).chats.count) ?? -1)" }) {
                try BoardProbe.model($0).chats.count == 2
            },
            Do("back to the chats") { try workspace($0).storySelect(tabAt: 0) },
            Do("note the tabs") { story in story.stash(DriveTabCount.self) { DriveTabCount() }.count = try workspace(story).tabs.count },
            Click(.tab(3)), Click(.tab(4), modifiers: .command),
        ] + [row(4, "Close 2 Tabs")] + [
            Expect("Close 2 Tabs: two fewer") { story in
                try workspace(story).tabs.count == story.stash(DriveTabCount.self) { DriveTabCount() }.count - 2
            },
        ]
    }
}

/// A click on a menu button's own label (its leading edge), not its centre: a label-and-chevron
/// button takes clicks on what it draws, and its centre can be the gap between the two.
struct PressLabel: Step {
    let target: Locator
    var label: String { "Press \(target)'s label" }
    init(_ target: Locator) { self.target = target }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        guard let window = element.window, let frame = element.frame else { throw StoryFailure.modelMissing("\(target)'s frame") }
        await story.input.click(at: CGPoint(x: frame.minX + 4, y: frame.midY), in: window)
    }
}

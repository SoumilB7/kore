import AppKit
import HostClient
import KoreUI

// Kore's menus not driven elsewhere, each item chosen once and its effect checked against the
// state before (`--tag drive`): the board's (a section's ⋯ and ＋, a tile's ⋯, a slot's ＋), a
// paste's name clash, a carry's Cancel, a preview tab's Keep Open, Search's Reveal, a sent file's
// chip, History's row, the Stay awake cup, the narrow agent map and changes view, a summary, a
// box explorer's several rows, a box's Welcome row, a box chat's Sync this chat, and the dim
// Arsenal row of a Codex chat outside Full access.
//
// Not driven, each for its reason:
// - Send back to <box> (tab): only after a whole move; ChatMoveUITests checks the item and its sheet.
// - Check again (a box's Welcome row): it runs a real ssh detect on the box (BoxSetup isn't a seam
//   and the storyline's box is a fake name); BoxList's tests own act(.checkAgain).
// - Delete N files (Sync's options): shows only while a running sync holds a bulk delete (no sync
//   runs under storylines); HostSync's tests own it.
// - History's locked line: a dim label (box rows only), not a control.
// - Try again (a device row's ⋯): offered only when a joinable row carries an upgrade's note; a
//   stopped upgrade (BoxTailnetMacOtherWay's) shows its line, but the row's ⋯ still says Join
//   KoreNet, which runs the same join (DevicesJoinKoreNet drives it).
// - A paste's “… is already in …” row, and the Codex Arsenal row outside Full access: dim labels,
//   checked as rows (DriveMenuPasteClash, DriveMenuArsenalDim clicks the dim row: nothing happens).

/// Picks the open menu's row titled as `title` says at the time (a chat's title, a strip chat's).
struct DriveMenuPickNamed: Step {
    let what: String
    let title: @MainActor (StoryContext) throws -> String
    var label: String { "Pick \(what)" }

    func run(_ story: StoryContext) async throws { try await DriveMenuPick(try title(story)).run(story) }
}

/// A locator whose id the app gives at the time; pending until it can.
@MainActor func driveLocate(_ what: String, _ id: @escaping @MainActor (AppProbe) -> StoryID?) -> Locator {
    Locator(what, key: { app in id(app).map { .success($0) } ?? .failure(LocatorMiss("no \(what) yet", pending: true)) })
}

@MainActor final class DriveBoardNote {
    var tile: UUID?
    var chats = 0
    var strip = 0
}

// MARK: - The board

/// A section's ⋯ (Colour ▸ Blue 200 and None, Split Right, Split Down, Merge Into ▸, Remove
/// Section), its ＋ (a strip chat, New Claude Chat), a tile's ⋯ (Split Right and Down, Chip, Zoom,
/// Move To ▸, Move to Its Own Tab, Remove from the board) and a slot's ＋ (New Claude Chat, a strip
/// chat).
final class DriveMenuBoard: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.claude] }
    override class var chats: Int { 6 }

    override func steps() -> [any Step] {
        let model: @MainActor @Sendable (StoryContext) throws -> BoardModel = { try BoardProbe.model($0) }
        let sections: @MainActor @Sendable (StoryContext) throws -> [BoardSection] = { try model($0).board.sections }
        let named: @MainActor @Sendable (StoryContext, String) throws -> BoardSection = { story, name in
            guard let section = try sections(story).first(where: { $0.name == name }) else { throw StoryFailure.modelMissing("the section “\(name)”") }
            return section
        }
        let note = DriveBoardNote()
        let tile: @MainActor @Sendable (StoryContext) throws -> UUID = { story in
            guard let id = note.tile else { throw StoryFailure.modelMissing("the noted tile") }
            return id
        }
        let section: (String, String) -> [any Step] = { name, item in
            [BoardPress("“\(name)”'s ⋯") { StoryID.Board.sectionMenu(try named($0, name).id) }, DriveMenuPick(item)]
        }
        let add: (String) -> [any Step] = { name in [BoardPress("“\(name)”'s ＋") { StoryID.Board.sectionAdd(try named($0, name).id) }] }
        let pickTile: (String, @escaping @MainActor @Sendable (StoryContext) throws -> UUID) -> any Step = { what, which in
            Do("note \(what)") { story in
                note.tile = try which(story)
                note.chats = try model(story).chats.count
                note.strip = BoardProbe.chatTabs(story).count
            }
        }
        let menu: (String) -> [any Step] = { item in
            [
                Do("focus the noted tile") { story in try model(story).focus(try tile(story)) },
                BoardPress("the noted tile's ⋯") { StoryID.Board.tileMenu(try tile($0)) }, DriveMenuPick(item, prefix: item.hasSuffix(" ")),
            ]
        }
        let name: (String) -> [any Step] = { new in
            [
                WaitForFocus(driveLocate("the new section's name") { app in
                    (app.workspace?.tabs.first { $0.board != nil }?.board?.renaming).map { StoryID.Board.sectionName($0) }
                }),
                TypeText(new), Key(.returnKey),
            ]
        }
        let slot: @MainActor @Sendable (StoryContext) throws -> UUID = { story in
            let m = try model(story)
            guard let id = m.board.tiles.map(\.id).first(where: { m.chats[$0] == nil }) else { throw StoryFailure.modelMissing("a slot") }
            return id
        }
        let stripTitle: @MainActor @Sendable (StoryContext) throws -> String = { story in
            guard let first = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("a chat in the strip") }
            return first.title
        }
        let strip: @MainActor @Sendable (StoryContext) -> Int = { BoardProbe.chatTabs($0).count }
        let count: @MainActor @Sendable (StoryContext) -> String? = { story in
            (try? model(story)).map { "\($0.board.sections.map { "\($0.name) \($0.tiles.count)" }) chats \($0.chats.count), strip \(strip(story))" }
        }
        var steps = super.steps() + [MakeBoard(name: "Backend", take: 2)]
        steps += [Expect("one section, two chats, no colour", found: count) { story in
            try sections(story).count == 1 && model(story).chats.count == 2 && sections(story)[0].swatch == nil
        }]
        steps += section("Backend", "Colour") + [DriveMenuPick("Blue 200")]
        steps += [Expect("Colour ▸ Blue 200") { try named($0, "Backend").swatch == .b200 }]
        steps += section("Backend", "Colour") + [DriveMenuPick("None")]
        steps += [Expect("Colour ▸ None") { try named($0, "Backend").swatch == nil }]
        steps += section("Backend", "Split Right") + name("Reviews")
        steps += [Expect("Split Right: a section “Reviews”", found: count) { try sections($0).map(\.name) == ["Backend", "Reviews"] }]
        steps += section("Reviews", "Split Down") + name("Notes")
        steps += [Expect("Split Down: a third, “Notes”", found: count) { try Set(sections($0).map(\.name)) == ["Backend", "Reviews", "Notes"] }]
        steps += [pickTile("Backend's first tile") { try named($0, "Backend").tiles[0].id }] + menu("Move To") + [DriveMenuPick("Reviews")]
        steps += [Expect("Move To ▸ Reviews: the tile there", found: count) { story in
            try named(story, "Reviews").tiles.map(\.id) == [tile(story)] && named(story, "Backend").tiles.count == 1
        }]
        steps += section("Reviews", "Merge Into") + [DriveMenuPick("Backend")]
        steps += [Expect("Merge Into ▸ Backend: Reviews gone, its tile in Backend", found: count) { story in
            try sections(story).map(\.name).sorted() == ["Backend", "Notes"] && named(story, "Backend").tiles.contains { $0.id == (try tile(story)) }
        }]
        steps += section("Notes", "Remove Section")
        steps += [Expect("Remove Section: only Backend", found: count) { try sections($0).map(\.name) == ["Backend"] }]
        steps += [Do("note the chats") { note.chats = try model($0).chats.count }]
        steps += add("Backend") + [DriveMenuPickNamed(what: "the first strip chat", title: stripTitle)]
        steps += [Expect("＋ ▸ a strip chat: on the board", found: count) { try model($0).chats.count == note.chats + 1 }]
        steps += [Do("note the chats") { note.chats = try model($0).chats.count }]
        steps += add("Backend") + [DriveMenuPick("New Claude Chat")]
        steps += [Expect("＋ ▸ New Claude Chat: a new chat on it", timeout: .seconds(10), found: count) { try model($0).chats.count == note.chats + 1 }]
        steps += [pickTile("the first tile") { try model($0).board.tiles[0].id }] + menu("Split Right")
        steps += [Expect("Split Right: a slot beside it", found: count) { story in
            let m = try model(story)
            return m.board.tiles.count == m.chats.count + 1
        }]
        steps += [BoardPress("the slot's ＋") { StoryID.Board.slotAdd(try slot($0)) }, DriveMenuPick("New Claude Chat")]
        steps += [Expect("the slot's ＋ ▸ New Claude Chat: filled", timeout: .seconds(10), found: count) { story in
            let m = try model(story)
            return m.chats.count == note.chats + 1 && m.board.tiles.count == m.chats.count
        }]
        steps += [pickTile("the first tile") { try model($0).board.tiles[0].id }] + menu("Split Down")
        steps += [Expect("Split Down: a slot under it", found: count) { story in
            let m = try model(story)
            return m.board.tiles.count == m.chats.count + 1
        }]
        steps += [
            BoardPress("the slot's ＋") { StoryID.Board.slotAdd(try slot($0)) },
            DriveMenuPickNamed(what: "the strip's last chat", title: stripTitle),
        ]
        steps += [Expect("the slot's ＋ ▸ a strip chat: filled, one fewer in the strip", found: count) { story in
            let m = try model(story)
            return m.chats.count == note.chats + 1 && m.board.tiles.count == m.chats.count && strip(story) == note.strip - 1
        }]
        steps += [
            pickTile("the last tile") { try model($0).board.tiles.last!.id },
            Expect("not a chip yet") { BoardProbe.density(try tile($0)) != .chip },
        ] + menu("Chip")
        steps += [Expect("Chip: drawn as one", found: { story in (try? tile(story)).flatMap(BoardProbe.density).map { "\($0)" } }) {
            BoardProbe.density(try tile($0)) == .chip
        }]
        steps += [pickTile("the first tile") { try model($0).board.tiles[0].id }, Expect("nothing zoomed") { try model($0).zoomed == nil }] + menu("Zoom")
        steps += [Expect("Zoom: that tile") { try model($0).zoomed == tile($0) }, Do("unzoom") { try model($0).zoomed = nil }]
        steps += [pickTile("the first tile") { try model($0).board.tiles[0].id }] + menu("Move to Its Own Tab")
        steps += [Expect("Move to Its Own Tab: off the board, a tab again", found: count) { story in
            try model(story).chats.count == note.chats - 1 && strip(story) == note.strip + 1
        }]
        steps += [Do("back to the board") { story in
            guard let workspace = story.app.workspace, let at = workspace.tabs.firstIndex(where: { $0.board != nil }) else { throw StoryFailure.modelMissing("the board's tab") }
            workspace.storySelect(tabAt: at)
        }]
        steps += [pickTile("the first tile") { try model($0).board.tiles[0].id }] + menu("Remove from ")
        steps += [Expect("Remove from the board: off it, a tab again", found: count) { story in
            try model(story).chats.count == note.chats - 1 && strip(story) == note.strip + 1
        }]
        return steps
    }
}

// MARK: - Files

/// A box file pasted onto a name already there (with no seam answering): Kore's popup names the
/// clash (a dim line), Keep Both carries it as “a 2.txt”, and Replace carries it over the old one.
/// (A paste from this Mac to this Mac keeps both without asking.)
final class DriveMenuPasteClash: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let folder = "/home/me/clash"
        let spec = DriveBoxSpec(alias: "drive-clash", folder: folder, files: [folder + "/a.txt": "new\n", folder + "/dest/a.txt": "old\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let a = Locator.id(StoryID.Explorer.row("a.txt")), dest = Locator.id(StoryID.Explorer.row("dest"))
        let plans: @MainActor @Sendable (StoryContext) -> String? = { _ in "\(FilePaste.storyPlans)" }
        let paste: [any Step] = driveMenu(a, "Copy") + [RightClick(dest), DriveMenuPick("Paste"), WaitForElement(.id(StoryID.Options.panel))]
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            WaitForElement(dest),
            Expect("nothing carried yet") { _ in FilePaste.storyPlans.isEmpty },
        ] + paste + [
            Expect("the clash named, dim, then Keep Both and Replace", found: { _ in "\(StoryID.Options.rows)" }) { _ in
                let rows = StoryID.Options.rows.filter { !$0.title.isEmpty }
                return rows.map(\.title) == ["“a.txt” is already in “dest”", "Keep Both", "Replace"] && rows.first?.enabled == false
            },
            DriveMenuPick("Keep Both"),
            Expect("Keep Both: carried as a new name", found: plans) { _ in FilePaste.storyPlans == [["a 2.txt"]] },
        ] + [RightClick(dest), DriveMenuPick("Paste"), WaitForElement(.id(StoryID.Options.panel))] + [
            DriveMenuPick("Replace"),
            Expect("Replace: carried over the old one", found: plans) { _ in FilePaste.storyPlans.last == ["replace a.txt"] },
        ]
    }
}

/// A carry that can pause: its Cancel asks Pause or remove the partial copy; Pause pauses it,
/// and Cancel and remove cancels it.
final class DriveMenuTransfer: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("notes.txt", "n\n")] }

    override func steps() -> [any Step] {
        let paused = DriveChatNote(0), cancelled = DriveChatNote(0)
        let cancel = Locator.id(StoryID.Explorer.transfer("Cancel"))
        return super.steps() + [
            Command(.toggleExplorer),
            WaitForElement(.treeRow("notes.txt")),
            Do("A copy into the folder going, one that pauses") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the window") }
                let id = workspace.storyRunningTransfer("Copying big.bin", pause: { paused.value += 1 }, cancel: { cancelled.value += 1 })
                story.atFinish { [weak workspace] in workspace?.storyForgetTransfer(id) }
            },
            Press(cancel),
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("Pause, then Cancel and remove", found: { _ in "\(StoryMenus.open)" }) { _ in
                StoryMenus.open.filter { !$0.isEmpty } == ["Pause", "Cancel and remove the partial copy"]
            },
            DriveMenuPick("Pause"),
            Expect("Pause: paused, not cancelled") { _ in paused.value == 1 && cancelled.value == 0 },
            Press(cancel),
            DriveMenuPick("Cancel and remove the partial copy"),
            Expect("Cancel and remove: cancelled") { _ in cancelled.value == 1 && paused.value == 1 },
        ]
    }
}

/// A file clicked once opens as a preview tab: its menu's Keep Open keeps it, the first
/// file's and then a second's beside it.
final class DriveMenuKeepOpen: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("a.txt", "a\n"), ("b.txt", "b\n")] }

    override func steps() -> [any Step] {
        let tabOf: @MainActor @Sendable (String) -> Locator = { Locator.id(StoryID.Tabs.file($0)) }
        let preview: @MainActor @Sendable (StoryContext, String) -> Bool? = { story, name in
            story.app.workspace?.tabs.first { $0.title == name }?.storyPreview
        }
        return super.steps() + [
            Command(.toggleExplorer),
            WaitForElement(.treeRow("a.txt")),
            Click(.treeRow("a.txt")),
            Expect("a.txt a preview") { preview($0, "a.txt") == true },
            RightClick(tabOf("a.txt")), DriveMenuPick("Keep Open"),
            Expect("Keep Open: kept") { preview($0, "a.txt") == false },
            Click(.treeRow("b.txt")),
            Expect("b.txt a preview beside it") { preview($0, "b.txt") == true && preview($0, "a.txt") == false },
            RightClick(tabOf("b.txt")), DriveMenuPick("Keep Open"),
            Expect("b.txt's Keep Open: kept") { preview($0, "b.txt") == false },
        ]
    }
}

/// Search's file row: Reveal in Finder shows the file.
final class DriveMenuSearchReveal: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("words.txt", "hello\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.search),
            WaitForFocus(.id(StoryID.Search.field)),
            TypeText("hello"),
            WaitForElement(.id(StoryID.Search.file("words.txt"))),
            Expect("nothing revealed") { _ in StoryHost.revealed.isEmpty },
            RightClick(.id(StoryID.Search.file("words.txt"))), DriveMenuPick("Reveal in Finder"),
            Expect("Reveal in Finder: the file", found: { _ in "\(StoryHost.revealed)" }) { story in
                StoryHost.revealed.map { driveRealFolder($0).path } == [driveRealFolder(story.folder.appendingPathComponent("words.txt")).path]
            },
        ]
    }
}

// MARK: - The chat

/// A sent file's chip: Copy File (the file itself on the pasteboard), Open with Default App,
/// Reveal in Finder; a sent picture's Save As… saves where the panel says.
final class DriveMenuAttachment: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Read it."), CLIScript.reply("Seen.")]) }
    static let file = "notes.txt"
    static let picture = "shot.png"

    override func steps() -> [any Step] {
        let chip = Locator.id(StoryID.Transcript.attachment(Self.file))
        let path: @MainActor @Sendable (StoryContext, String) -> String = { driveRealFolder($0.folder.appendingPathComponent($1)).path }
        return super.steps() + [
            Do("Attach a file") { story in
                let file = story.folder.appendingPathComponent(Self.file)
                try "notes\n".write(to: file, atomically: true, encoding: .utf8)
                try story.activeChat().storyAttach([file])
            },
            Send("Read this"), TurnFinished(1),
            Do("an empty pasteboard, nothing opened") { _ in
                StoryHost.pasteboard.clearContents()
                TranscriptSelection.opened = []
            },
            RightClick(chip), DriveMenuPick("Copy File"),
            Expect("Copy File: the file itself", found: { _ in "\(StoryHost.pasteboard.readObjects(forClasses: [NSURL.self]) ?? [])" }) { story in
                (StoryHost.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.map { driveRealFolder($0).path } == [path(story, Self.file)]
            },
            RightClick(chip), DriveMenuPick("Open with Default App"),
            Expect("Open with Default App: handed over once", found: { _ in "\(TranscriptSelection.opened)" }) { story in
                TranscriptSelection.opened.map { driveRealFolder($0).path } == [path(story, Self.file)]
            },
            Expect("nothing revealed") { _ in StoryHost.revealed.isEmpty },
            RightClick(chip), DriveMenuPick("Reveal in Finder"),
            Expect("Reveal in Finder: the file", found: { _ in "\(StoryHost.revealed)" }) { story in
                StoryHost.revealed.map { driveRealFolder($0).path } == [path(story, Self.file)]
            },
            Do("Attach a picture; the save panel will give saved.png") { story in
                let image = story.folder.appendingPathComponent(Self.picture)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                try rep?.representation(using: .png, properties: [:])?.write(to: image)
                try story.activeChat().storyAttach([image])
                StoryHost.pickedSave = story.outputs.appendingPathComponent("saved.png")
            },
            Send("And this"), TurnFinished(2),
            Expect("not saved yet") { !FileManager.default.fileExists(atPath: $0.outputs.appendingPathComponent("saved.png").path) },
            RightClick(.id(StoryID.Transcript.attachment(Self.picture))), DriveMenuPick("Save As…"),
            Expect("Save As…: the panel asked once, the picture saved there", timeout: .seconds(5)) { story in
                StoryHost.picks == ["Save"]
                    && FileManager.default.contentsEqual(
                        atPath: story.outputs.appendingPathComponent("saved.png").path, andPath: story.folder.appendingPathComponent(Self.picture).path)
            },
        ]
    }
}

/// A compaction's summary: its right-click's Copy Summary copies it.
final class DriveMenuSummary: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let summary = "The conversation so far, in brief."
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("First answer")], compact: CLIScript.compaction(summary: summary))
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Say something"), TurnFinished(1),
            StartCompact(),
            Expect("compacted, a summary row") { try !$0.activeChat().isCompacting && $0.activeChat().storySummaryEntry != nil },
            Do("an empty pasteboard") { _ in StoryHost.pasteboard.clearContents() },
            RightClick(driveLocate("the summary row") { app in
                (app.workspace?.activeTab.chat?.storySummaryEntry).map { StoryID.Transcript.summary($0) }
            }),
            DriveMenuPick("Copy Summary"),
            Expect("Copy Summary: the summary's text", found: { _ in StoryHost.pasteboard.string(forType: .string) }) { _ in
                StoryHost.pasteboard.string(forType: .string)?.contains(Self.summary) == true
            },
        ]
    }
}

/// A narrow agent map's menu in place of the tree: the chat's row shows its pane, a running
/// agent's row selects it, and Done ▸ an ended one selects that.
final class DriveMenuAgents: ChatStoryline {
    override class var tags: Set<Tag> { [.drive, .agents] }
    override class var variants: [Variant] { [.claude] }
    override class var needs: Needs { Needs(window: CGSize(width: 520, height: 760)) }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("done", "Read the notes"),
            AgentMapStories.spawn("watch", "Watch the build", background: true),
            .event(.agentFinished(id: "done", .completed, result: "Read")),
            .stream(.answer, "One runs on."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let menu = Locator.id(StoryID.AgentMap.menu)
        let state: @MainActor @Sendable (StoryContext) -> String? = { story in
            (try? story.activeChat()).map { "selected \($0.storyAgentMapSelected ?? "-"), pane \($0.storyAgentMapPane ?? "-")" }
        }
        return super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            WaitForElement(menu),
            Expect("the chat's pane not shown") { try $0.activeChat().storyAgentMapPane == nil },
            Press(menu), Press(.id(StoryID.Options.item(0))),
            Expect("the chat's row: its pane", found: state) { try $0.activeChat().storyAgentMapPane == "chat" },
            Press(menu), DriveMenuPick("Watch the build", prefix: true),
            Expect("a running agent's row: it selected", found: state) { try $0.activeChat().storyAgentMapSelected == "watch" },
            Press(menu), DriveMenuPick("Done 1", prefix: true), DriveMenuPick("Read the notes", prefix: true),
            Expect("Done ▸ its agent: selected", found: state) { try $0.activeChat().storyAgentMapSelected == "done" },
        ]
    }
}

/// A narrow changes view's file menu in place of the list: a pick shows that file.
final class DriveMenuChanges: DriveChangesView {
    override class var variants: [Variant] { [.codex] }
    override class var needs: Needs { Needs(window: CGSize(width: 520, height: 760)) }

    override func steps() -> [any Step] {
        let a = Locator.id(StoryID.Changes.file("a.txt").part(.selected)), b = Locator.id(StoryID.Changes.file("b.txt").part(.selected))
        return opening + [
            WaitForElement(a),
            ExpectElement(b, .absent),
            PressLabel(.id(StoryID.Changes.menu)), DriveMenuPick("b.txt"),
            WaitForElement(b),
            ExpectElement(a, .absent),
        ]
    }
}

/// History's row menu: Rename… renames in place, Archive takes it off the list, and in the
/// archived view Unarchive brings it back. History stays open through each (a click on its row's
/// popup is the panel's own, not one outside it).
final class DriveMenuHistory: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    static let session = "d71e-0003"

    override func steps() -> [any Step] {
        let row = StoryID.History.row(Self.session)
        let archived: @MainActor @Sendable (StoryContext) -> Bool = { $0.app.workspace?.storyArchivedHistory.contains(Self.session) == true }
        return super.steps() + [
            PutHistoryChat(session: Self.session, title: "Archive by menu"),
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(row), timeout: .seconds(15)),
            Expect("not archived") { !archived($0) },
            RightClick(.id(row)), DriveMenuPick("Rename…"),
            WaitForFocus(.id(StoryID.History.rename(Self.session).part(.field))),
            TypeText("Renamed by menu"), Key(.returnKey),
            Expect("Rename…: renamed in place, History still open", found: { story in story.app.workspace?.storyHistory.first { $0.id == Self.session }?.title }) { story in
                story.app.workspace?.storyHistory.first { $0.id == Self.session }?.title == "Renamed by menu"
            },
            RightClick(.id(row)), DriveMenuPick("Archive"),
            Expect("Archive: archived") { archived($0) },
            ExpectElement(.id(row), .absent),
            Press(.id(StoryID.History.archived)),
            Expect("the archived view lists it", timeout: .seconds(5), found: { story in
                "popups \(StoryMenus.trail), last click \(InputDriver.lastRoute), registered \(StoryRegistry.ids.filter { $0.hasPrefix("history.") }.sorted()), archived \(story.app.workspace?.storyArchivedHistory ?? [])"
            }) { _ in StoryElement(row) != nil },
            RightClick(.id(row)), DriveMenuPick("Unarchive"),
            Expect("Unarchive: back") { !archived($0) },
        ]
    }
}

/// The Stay awake cup's right-click: Always turns it on so, Turn Off turns it off (dim while off).
final class DriveMenuStayAwake: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let cup = Locator.id(StoryID.Titlebar.awake)
        return super.steps() + [
            Do("Stay awake recorded, never held for real") { story in
                StoryAwake.reset()
                story.atFinish { StoryAwake.reset() }
            },
            Expect("off") { _ in !StoryAwake.isOn },
            RightClick(cup),
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("Turn Off dim while off", found: { _ in "\(StoryID.Options.rows)" }) { _ in
                StoryID.Options.rows.first { $0.title == "Turn Off" }?.enabled == false
            },
            DriveMenuPick("Always"),
            Expect("Always: on, always", found: { _ in StoryAwake.mode }) { _ in StoryAwake.isOn && StoryAwake.mode == "always" },
            RightClick(cup), DriveMenuPick("Turn Off"),
            Expect("Turn Off: off") { _ in !StoryAwake.isOn },
        ]
    }
}

/// A Codex chat outside Full access: its tab's Arsenal row is dim and says why, and a press on it
/// does nothing.
final class DriveMenuArsenalDim: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let row = "Arsenal · Codex needs Full access"
        return super.steps() + [
            RightClick(.tab(1)),
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("the row dim, saying why", found: { _ in "\(StoryID.Options.rows)" }) { _ in
                StoryID.Options.rows.contains { $0.title == row && !$0.enabled }
            },
            // A pointer's click on the dim row, as a person's would land (a press would skip it).
            BoxStep("Click the dim row") { story in
                guard let index = StoryID.Options.rows.firstIndex(where: { $0.title == row }) else { throw StoryFailure.expectation("a “\(row)” row") }
                try await story.input.click(try await story.element(.id(StoryID.Options.item(index))))
            },
            Expect("the menu still up") { _ in StoryMenus.open.contains(row) },
            Expect("the press did nothing") { try $0.activeChat().arsenal == nil },
            Key(.escape),
            Expect("Esc: the menu gone") { _ in StoryMenus.open.isEmpty },
        ]
    }
}

// MARK: - Boxes

/// Two rows chosen in a box's explorer: Copy Paths (the box's paths), Copy Relative Paths, and
/// Move 2 Items to Trash (asked once, both gone on the box).
final class DriveMenuBoxRows: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let folder = "/home/me/pair"
        let spec = DriveBoxSpec(alias: "drive-rows", folder: folder, files: [folder + "/a.txt": "a\n", folder + "/b.txt": "b\n", folder + "/c.txt": "c\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let rows: @MainActor @Sendable (StoryContext) -> [String] = { (try? box($0).workspace())?.storyBoxTreeRows ?? [] }
        let a = Locator.id(StoryID.Explorer.row("a.txt")), b = Locator.id(StoryID.Explorer.row("b.txt"))
        let both: [any Step] = [Click(a), Click(b, modifiers: .command)]
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("Kore's questions answered yes; an empty pasteboard") { story in
                _ = story.stash(DriveConfirms.self) { DriveConfirms() }
                StoryHost.pasteboard.clearContents()
            },
            WaitForElement(.id(StoryID.Explorer.row("c.txt"))),
        ] + both + [RightClick(b), DriveMenuPick("Copy Paths")] + [
            Expect("Copy Paths: the box's paths", found: { _ in StoryHost.pasteboard.string(forType: .string) }) { _ in
                StoryHost.pasteboard.string(forType: .string) == "\(folder)/a.txt\n\(folder)/b.txt"
            },
        ] + both + [RightClick(b), DriveMenuPick("Copy Relative Paths")] + [
            Expect("Copy Relative Paths", found: { _ in StoryHost.pasteboard.string(forType: .string) }) { _ in
                StoryHost.pasteboard.string(forType: .string) == "a.txt\nb.txt"
            },
        ] + both + [RightClick(b), DriveMenuPick("Move 2 Items to Trash")] + [
            Expect("Move 2 Items to Trash: asked once, both gone, c.txt kept", timeout: .seconds(10), found: { "\(rows($0))" }) { story in
                story.stash(DriveConfirms.self) { DriveConfirms() }.asked == ["trash"]
                    && !rows(story).contains("a.txt") && !rows(story).contains("b.txt") && rows(story).contains("c.txt")
            },
        ]
    }
}

/// A box on the Welcome: its row's Remove ▸ forget takes it off Kore's list.
final class DriveMenuBoxRemove: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-remove.invalid", folder: "/home/me/app", dirs: ["/home/me/app"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        return super.steps() + [
            DevicesSetUp(),
            DriveBoxOnWelcome(box: box, agents: false),
            DriveChatSettle(),
            Expect("on Kore's list") { _ in BoxList.shared.box(spec.alias) != nil },
            BoxStep("Right-click the box's tab") { try await $0.input.pointerRightClick(try await $0.element(.id(StoryID.Boxes.place(spec.alias)))) },
            DriveMenuPick("Remove"), DriveMenuPick("", prefix: true),
            Expect("Remove ▸ forget: off the list") { _ in BoxList.shared.box(spec.alias) == nil },
        ]
    }
}

/// A box chat in a synced folder: its tab's Sync this chat turns its sync on, and off again.
final class DriveMenuSyncThisChat: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-sync-chat", folder: "/home/me/trip", chats: [DriveBoxChat(id: "s1", title: "Plan the trip")])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let syncs: @MainActor @Sendable (StoryContext) -> Bool? = { _ in
            SyncPairList.shared.pair(alias: spec.alias, box: spec.folder).map { SyncPairList.shared.syncs($0, chatId: "s1") }
        }
        let open: [any Step] = [
            DriveTap("Right-click the chat's tab", .rightClick) { story in StoryID.Tabs.tab(try box(story).tab("Plan the trip").id) },
            DriveMenuPick("Sync this chat"),
        ]
        return [
            BoxStep("Open the box folder's window with its chat, linked") { try await box($0).open($0) },
            Do("The box folder synced with this storyline's folder (no sync runs)") { story in
                _ = story.stash(DrivePairReset.self) { DrivePairReset(alias: spec.alias, folder: spec.folder) }
                SyncPairList.shared.pair(mac: driveRealFolder(story.folder), alias: spec.alias, box: spec.folder)
            },
            Expect("paired, the chat's sync as it starts", found: { "\(String(describing: syncs($0)))" }) { syncs($0) != nil },
            Do("note it") { story in story.stash(DriveSyncNote.self) { DriveSyncNote() }.was = syncs(story) ?? false },
        ] + open + [
            Expect("Sync this chat: turned", found: { "\(String(describing: syncs($0)))" }) { story in
                syncs(story) == !story.stash(DriveSyncNote.self) { DriveSyncNote() }.was
            },
        ] + open + [
            Expect("again: back", found: { "\(String(describing: syncs($0)))" }) { story in
                syncs(story) == story.stash(DriveSyncNote.self) { DriveSyncNote() }.was
            },
        ]
    }
}

@MainActor private final class DriveSyncNote { var was = false }


// MARK: - Viewer and transcript files

/// The chat's viewer: an SVG's right-click menu reveals it; for a picture in a narrow window the
/// pen's colours fold into one swatch whose menu picks a colour.
final class DriveMenuViewer: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var needs: Needs { Needs(window: CGSize(width: 360, height: 700)) }
    static let name = "shot.png"

    override func steps() -> [any Step] {
        let canvas = Locator.id(StoryID.Viewer.canvas)
        let picked: (String) -> Locator = { .id(StoryID.Viewer.swatch($0).part(.selected)) }
        return super.steps() + [
            // An SVG's viewer has the menu (a raster picture's canvas has none: its pen draws there).
            WriteFiles([(DriveWindowViewerSVG.name, DriveWindowViewerSVG.text)]),
            Do("an SVG, attached") { story in try story.activeChat().storyAttach([story.folder.appendingPathComponent(DriveWindowViewerSVG.name)]) },
            Expect("its chip shows it") { try $0.activeChat().storyChipShowsPicture(DriveWindowViewerSVG.name) },
            Press(.id(StoryID.Composer.attachment(DriveWindowViewerSVG.name))),
            WaitForElement(.id(StoryID.Viewer.svg)),
            Expect("nothing revealed yet") { _ in StoryHost.revealed.isEmpty },
            RightClick(.id(StoryID.Viewer.svg)), DriveMenuPick("Reveal in Finder"),
            Expect("Reveal in Finder: the SVG", found: { _ in "\(StoryHost.revealed.map(\.lastPathComponent))" }) { _ in
                StoryHost.revealed.map(\.lastPathComponent) == [DriveWindowViewerSVG.name]
            },
            Press(.id(StoryID.Viewer.close)),
            ExpectElement(.id(StoryID.Viewer.svg), .absent),
            Do("a picture, attached") { story in
                let file = story.folder.appendingPathComponent(Self.name)
                try DriveWindowViewerImage.picture(width: 800, height: 600).write(to: file)
                try story.activeChat().storyAttach([file])
            },
            Expect("its chip shows it") { try $0.activeChat().storyChipShowsPicture(Self.name) },
            Press(.id(StoryID.Composer.attachment(Self.name))),
            WaitForElement(canvas),
            Press(.id(StoryID.Viewer.pen)),
            WaitForElement(.id(StoryID.Viewer.penColour)),
            ExpectElement(picked("red")),
            PressLabel(.id(StoryID.Viewer.penColour)), DriveMenuPick("Blue"),
            WaitForElement(picked("blue")),
            ExpectElement(picked("red"), .absent),
        ]
    }
}

/// A tool's file row and a file link in an answer: each one's right-click menu (MediaMenu)
/// reveals the file or copies its path.
final class DriveMenuTranscriptFiles: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let file = "notes.md"
    static let shown = "See the notes."

    override func steps() -> [any Step] {
        let name = Locator.id(StoryID.Transcript.fileName(Self.file))
        return [
            WriteFiles([(Self.file, "# Notes\n")]),
            UseFolderScript { folder in
                let url = folder.appendingPathComponent(Self.file).absoluteString
                return CLIScript(turns: [
                    [.startTurn, .fileEdit(path: Self.file, content: "# Notes\n\nWritten.\n"), .finishTurn(.completed)],
                    CLIScript.reply("See [the notes](\(url))."),
                ])
            },
            OpenFolder(),
            StartChat(),
            Send("Write the notes"), TurnFinished(1), WaitIdle(),
            WaitForElement(name),
            Expect("nothing revealed yet") { _ in StoryHost.revealed.isEmpty },
            RightClick(name), DriveMenuPick("Reveal in Finder"),
            Expect("the row's Reveal in Finder: the file", found: { _ in "\(StoryHost.revealed.map(\.lastPathComponent))" }) { _ in
                StoryHost.revealed.map(\.lastPathComponent) == [Self.file]
            },
            Send("Where are they?"), TurnFinished(2), WaitIdle(),
            Expect("its path not on the board yet") { _ in StoryHost.pasteboard.string(forType: .string)?.hasSuffix("/" + Self.file) != true },
            RightClickSpot(.answer(2, [0], at: Self.shown, "notes")), DriveMenuPick("Copy Path"),
            Expect("the link's Copy Path: the file's path", found: { _ in StoryHost.pasteboard.string(forType: .string) }) { _ in
                StoryHost.pasteboard.string(forType: .string)?.hasSuffix("/" + Self.file) == true
            },
        ]
    }
}

/// A right-click on a word in the transcript.
struct RightClickSpot: Step {
    let spot: Spot
    init(_ spot: Spot) { self.spot = spot }
    var label: String { "Right-click \(spot)" }

    func run(_ story: StoryContext) async throws {
        let (window, p) = try await spot.point(story)
        await story.input.rightClick(at: p, in: window)
    }
}

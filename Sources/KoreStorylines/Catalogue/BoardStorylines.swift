import AppKit
import KoreUI

// The board (dynamic-tab.html §7's storylines): made from the + menu's New Board, sections
// split and merged, gutters dragged and snapped, chats attached by a drag from the strip and by
// Attach to…, densities stepped, tiles moved and detached, every step undone, the layout back
// after a relaunch, an approval answered from a card, and at most four full tiles streaming.
// Each is told by Claude and Codex both; tiles, gutters and sections are found by their ids.

/// A board story's start: the folder, and `chats` chats of the variant's provider, each with a
/// turn behind it, in the strip.
class BoardStoryline: Storyline {
    override class var isFamily: Bool { self == BoardStoryline.self }
    override class var variants: [Variant] { [.claude, .codex] }
    override class var tags: Set<Tag> { ["board"] }
    class var chats: Int { 3 }
    class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Done, the board's chat answered."), CLIScript.reply("Again.")]) }

    override func steps() -> [any Step] {
        [UseScript(Self.script), OpenFolder()] + (1...Self.chats).flatMap { n -> [any Step] in
            [StartChat(), Send("chat \(n)"), TurnFinished(1)]
        }
    }
}

/// The board as a storyline reads it.
@MainActor
enum BoardProbe {
    static func tab(_ story: StoryContext) throws -> ChatTab {
        guard let tab = story.app.workspace?.tabs.first(where: { $0.board != nil }) else { throw StoryFailure.modelMissing("a board tab") }
        return tab
    }

    static func model(_ story: StoryContext) throws -> BoardModel {
        guard let model = try tab(story).board else { throw StoryFailure.modelMissing("a board") }
        return model
    }

    static func chatTabs(_ story: StoryContext) -> [ChatTab] {
        story.app.workspace?.stripChats ?? []
    }

    /// The tiles' densities as the view draws them (its story marks).
    static func density(_ tile: UUID) -> Density? {
        Density.allCases.first { StoryElement(StoryID.Board.density(tile, $0)) != nil }
    }

    /// A board point (its own space, top-left) in the window's AppKit space, for in-process
    /// pointer events.
    static func windowPoint(_ point: CGPoint, _ story: StoryContext) throws -> CGPoint {
        let model = try model(story)
        guard let content = story.window?.contentView else { throw StoryFailure.other("no window") }
        return CGPoint(x: model.origin.x + point.x, y: content.bounds.height - (model.origin.y + point.y))
    }

    /// The frames the board lays out now.
    static func frames(_ story: StoryContext) throws -> BoardFrames {
        let model = try model(story)
        return model.board.solve(in: model.size)
    }
}

/// Presses an element and drags it by as much as from `from` to `to` (board points), the
/// pointer moved in steps, as a drag by hand does: a gutter, a tile's header.
struct BoardDrag: Step {
    let what: String
    let element: @MainActor (StoryContext) throws -> StoryID
    let from: @MainActor (StoryContext) throws -> CGPoint
    let to: @MainActor (StoryContext) throws -> CGPoint
    var label: String { "Drag \(what)" }

    func run(_ story: StoryContext) async throws {
        let found = try await story.element(.id(try element(story)))
        guard let window = story.window, let frame = found.frame else { throw StoryFailure.other("no \(what)") }
        let a = try from(story), b = try to(story)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        // The board's space runs down, the window's up.
        let end = CGPoint(x: start.x + b.x - a.x, y: start.y - (b.y - a.y))
        await story.input.drag(from: start, to: end, in: window, steps: 16)
        try await story.idle()
    }
}

/// Makes a board from the + menu's New Board, names its section, and fills it from the strip.
struct MakeBoard: Step {
    let name: String
    /// How many of the strip's chats go onto it, by the slot's list then ＋ (auto placement).
    let take: Int
    var label: String { "Make a board, name its section “\(name)”, and move \(take) chats onto it" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        try await Command(.newBoard).run(story)
        let model = try BoardProbe.model(story)
        let tab = try BoardProbe.tab(story)
        guard let section = model.board.sections.first?.id else { throw StoryFailure.modelMissing("a section") }
        try await WaitForFocus(.id(StoryID.Board.sectionName(section))).run(story)
        try await story.input.key(KeyChord(.character("a"), .command))
        try await story.input.type(name)
        try await story.input.key(.returnKey)
        try await story.until("the section named “\(name)”") { model.board.sections.first?.name == name }
        guard take > 0 else { return }
        // The first by the slot's picker, in place.
        guard let first = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("a chat in the strip") }
        try await Press(.id(StoryID.Board.slotChat(section, first.id))).run(story)
        try await story.until("its chat on the board") { model.chats.count == 1 }
        // The rest by ＋, into the section by auto placement.
        for _ in 1..<take {
            guard let next = BoardProbe.chatTabs(story).first, let workspace = story.app.workspace else { break }
            let before = model.chats.count
            workspace.attach(next, to: tab, section: section)
            try await story.until("\(before + 1) chats on the board") { model.chats.count == before + 1 }
        }
        try await story.idle()
    }
}

/// Presses an element whose id the board gives at the time (a tile's Allow, the board's tab).
struct BoardPress: Step {
    let what: String
    let id: @MainActor (StoryContext) throws -> StoryID
    var label: String { what }
    init(_ what: String, _ id: @escaping @MainActor (StoryContext) throws -> StoryID) {
        self.what = what
        self.id = id
    }

    func run(_ story: StoryContext) async throws { try await Press(.id(id(story))).run(story) }
}

/// Undoes the last layout step, as ⌘Z does with the keys outside a text field.
struct UndoLayout: Step {
    var label: String { "⌘Z the layout" }

    func run(_ story: StoryContext) async throws {
        story.window?.makeFirstResponder(nil)
        try await story.input.key(.cmd("z"))
        try await story.idle()
    }
}

/// Saves the window as a relaunch would (its saved form, through JSON), closes it, and opens the
/// folder again from that: what comes back is what was saved.
struct Relaunch: Step {
    var label: String { "Close the window and open it again from what it saved" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace, let window = story.window else { throw StoryFailure.modelMissing("the window") }
        let folder = story.folder
        let saved = try workspace.storySaved()
        window.close()
        try await story.until("the window closed") { story.app.workspace?.window?.isVisible != true }
        guard Workspace.storyRestore(folder: folder, saved: saved) else { throw StoryFailure.other("the folder's window is still open") }
        try await OpenFolder().run(story)
        try await story.until("the folder open again") { story.app.workspace !== workspace && story.window?.isVisible == true }
    }
}

// MARK: - The stories

/// New Board → name the section "Backend" → pick a chat in its slot: one section, one full
/// tile, the chat's strip tab gone; the same after a relaunch.
final class BoardCreate: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }
    override class var chats: Int { 1 }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 1),
            Expect("one section, one full tile, and no chat tab left in the strip") { story in
                let model = try BoardProbe.model(story)
                guard let tile = model.board.tiles.first?.id, model.board.tiles.count == 1 else { return false }
                return model.board.sections.map(\.name) == ["Backend"] && BoardProbe.chatTabs(story).isEmpty && BoardProbe.density(tile) == .full
            },
            Snapshot("board-created"),
            Relaunch(),
            Expect("the board back, its section and its chat by session") { story in
                let model = try BoardProbe.model(story)
                guard let tile = model.board.tiles.first?.id, let chat = model.chats[tile] else { return false }
                return model.board.sections.map(\.name) == ["Backend"] && chat.sessionId != nil && BoardProbe.chatTabs(story).isEmpty
            },
        ]
    }
}

/// Backend's gutter dragged near ⅔ snaps there; a tile's gutter dragged up to under 64pt pins
/// it as a chip; each is one undo step.
final class BoardResize: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            Do("Split the section right, and move the third chat in there") { story in
                let model = try BoardProbe.model(story), tab = try BoardProbe.tab(story)
                guard let backend = model.board.sections.first?.id, let third = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("a chat") }
                model.edit { $0.addSection(.right, of: backend, BoardSection(name: "Reviews")) }
                model.renaming = nil
                story.app.workspace?.attach(third, to: tab, section: model.board.sections.last?.id)
            },
            // By a person's mouse: the window key, the press AppKit's to route.
            ExpectHittable(Self.sectionGutterLocator),
            Drag(Self.sectionGutterLocator) { story in
                let gutter = try Self.sectionGutter(story)
                return CGVector(dx: gutter.extent * 2 / 3 - 5 - gutter.position, dy: 0)
            },
            Expect("the sections at ⅔ and ⅓, one undo step", found: { story in
                let model = try? BoardProbe.model(story)
                let frames = try? BoardProbe.frames(story)
                let gutter = frames?.gutters.first { $0.id.section == nil }
                return "undo \(model?.history.undoStack.count ?? -1), gutter \(String(describing: gutter?.rect)), element \(String(describing: gutter.flatMap { StoryElement(StoryID.Board.gutter($0.id))?.frame })), origin \(String(describing: model?.origin)), window \(String(describing: story.window?.contentView?.bounds))"
            }) { story in
                let model = try BoardProbe.model(story)
                let frames = try BoardProbe.frames(story)
                let widths = model.board.sections.compactMap { frames.sections[$0.id]?.width }
                guard widths.count == 2 else { return false }
                return abs(widths[0] / (widths[0] + widths[1]) - 2.0 / 3) < 0.01 && model.history.undoStack.count >= 1
            },
            Do("Turn Backend's two tiles to a column") { story in
                let model = try BoardProbe.model(story)
                let tiles = model.board.sections[0].tiles.map(\.id)
                if tiles.count == 2 { model.edit { $0.move(tiles[1], to: .beside(tiles[0], .bottom), in: model.size) } }
            },
            BoardDrag(what: "Backend's tile gutter down to under 64pt", element: { story in StoryID.Board.gutter(try Self.tileGutter(story).id) }) { story in
                let gutter = try Self.tileGutter(story)
                return CGPoint(x: gutter.rect.midX, y: gutter.position)
            } to: { story in
                let gutter = try Self.tileGutter(story)
                return CGPoint(x: gutter.rect.midX, y: gutter.start + gutter.extent - 45)
            },
            Expect("the lower tile a chip, pinned at 30") { story in
                let model = try BoardProbe.model(story)
                let tiles = model.board.sections[0].tiles.map(\.id)
                guard case .split(_, let children)? = model.board.sections[0].body, tiles.count == 2 else { return false }
                return children.last?.share == .pinned(BoardMetrics.chip) && BoardProbe.density(tiles[1]) == .chip
            },
            Snapshot("board-resized"),
            UndoLayout(),
            Expect("one ⌘Z: the chip a card again") { story in
                let model = try BoardProbe.model(story)
                guard let tile = model.board.sections[0].tiles.last?.id else { return false }
                return BoardProbe.density(tile) != .chip
            },
        ]
    }

    @MainActor static let sectionGutterLocator = Locator("the section gutter") { app in
        guard let model = app.workspace?.tabs.first(where: { $0.board != nil })?.board,
            let gutter = model.board.solve(in: model.size).gutters.first(where: { $0.id.section == nil })
        else { return .failure(LocatorMiss("the section gutter", pending: true)) }
        return .success(StoryID.Board.gutter(gutter.id))
    }

    @MainActor static func sectionGutter(_ story: StoryContext) throws -> BoardGutter {
        guard let gutter = try BoardProbe.frames(story).gutters.first(where: { $0.id.section == nil }) else { throw StoryFailure.modelMissing("the section gutter") }
        return gutter
    }

    @MainActor static func tileGutter(_ story: StoryContext) throws -> BoardGutter {
        let model = try BoardProbe.model(story)
        guard let gutter = try BoardProbe.frames(story).gutters.first(where: { $0.id.section == model.board.sections.first?.id && $0.axis == .column }) else {
            throw StoryFailure.modelMissing("Backend's tile gutter")
        }
        return gutter
    }
}

/// A tile dropped on another's right edge splits it there; Reviews merged into Backend by its
/// popup; ⌘Z twice: the tree is the start's again.
final class BoardSplitMergeUndo: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            Do("A Reviews section with the third chat") { story in
                let model = try BoardProbe.model(story), tab = try BoardProbe.tab(story)
                guard let backend = model.board.sections.first?.id, let third = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("a chat") }
                model.edit { $0.addSection(.right, of: backend, BoardSection(name: "Reviews")) }
                model.renaming = nil
                story.app.workspace?.attach(third, to: tab, section: model.board.sections.last?.id)
            },
            Do("Remember the start") { story in story.stash(Start.self) { Start() }.board = try BoardProbe.model(story).board },
            // The header's drag gesture takes no first mouse in the storylines' inactive window:
            // the drop it computes at the review's right edge, then the move it makes on release.
            Do("Drop Backend's first tile on the review's right edge") { story in
                let model = try BoardProbe.model(story), frames = try BoardProbe.frames(story)
                guard let tile = model.board.sections[0].tiles.first?.id, let review = model.board.sections[1].tiles.first?.id,
                    let rect = frames.tiles[review], let (drop, _) = frames.drop(at: CGPoint(x: rect.maxX - 10, y: rect.midY), moving: tile)
                else { throw StoryFailure.modelMissing("a drop") }
                let size = model.size
                model.edit { $0.move(tile, to: drop, in: size) }
            },
            Expect("it sits right of the review, and Backend's other tile took its room") { story in
                let model = try BoardProbe.model(story)
                return model.board.sections[1].tiles.count == 2 && model.board.sections[0].tiles.count == 1
            },
            Do("Merge Reviews into Backend from its popup") { story in
                let model = try BoardProbe.model(story)
                let reviews = model.board.sections[1].id, backend = model.board.sections[0].id
                model.edit { $0.mergeSection(reviews, into: backend) }
            },
            Expect("one section of three") { story in
                let model = try BoardProbe.model(story)
                return model.board.sections.count == 1 && model.board.tiles.count == 3
            },
            UndoLayout(),
            UndoLayout(),
            Expect("the tree the start's") { story in
                try BoardProbe.model(story).board == story.stash(Start.self) { Start() }.board
            },
        ]
    }

    final class Start { var board: Board? }
}

/// A chat's strip tab dragged down onto the board moves it there; Attach to… moves another;
/// ⌥⌘T puts one back as its own tab; closing the board gives the rest back. The chats are the
/// same objects throughout, their drafts kept.
final class BoardAttachDetach: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Type a draft in the first chat") { story in story.app.workspace?.stripChats.first?.chat?.draft = "keep me" },
            MakeBoard(name: "Backend", take: 1),
            Do("Remember the chats") { story in
                story.stash(Chats.self) { Chats() }.all = Set(story.app.workspace?.tabs.compactMap { $0.chat.map(ObjectIdentifier.init) } ?? [])
                    .union(try BoardProbe.model(story).orderedChats.map(ObjectIdentifier.init))
            },
            BoardDrag(
                what: "the second chat's tab down onto the board",
                element: { story in
                    guard let tab = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("the chat's tab") }
                    return StoryID.Tabs.tab(tab.id)
                }
            ) { story in
                guard let tab = BoardProbe.chatTabs(story).first, let frame = StoryElement(StoryID.Tabs.tab(tab.id))?.frame,
                    let content = story.window?.contentView
                else { throw StoryFailure.modelMissing("the chat's tab") }
                let model = try BoardProbe.model(story)
                return CGPoint(x: frame.midX - model.origin.x, y: content.bounds.height - frame.midY - model.origin.y)
            } to: { story in
                let frames = try BoardProbe.frames(story)
                return CGPoint(x: frames.content.width / 2, y: frames.content.height - 40)
            },
            Expect("two chats on the board, one tab in the strip") { story in
                try BoardProbe.model(story).chats.count == 2 && BoardProbe.chatTabs(story).count == 1
            },
            Do("Attach to Backend, from the tab's popup") { story in
                let tab = try BoardProbe.tab(story)
                guard let other = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("a chat tab") }
                story.app.workspace?.attach(other, to: tab, section: try BoardProbe.model(story).board.sections.first?.id)
            },
            Expect("three on the board, none in the strip") { story in
                try BoardProbe.model(story).chats.count == 3 && BoardProbe.chatTabs(story).isEmpty
            },
            Snapshot("board-attached"),
            Do("Focus the first tile") { story in
                let model = try BoardProbe.model(story)
                model.focus(model.board.tiles.first?.id)
                story.window?.makeFirstResponder(nil)
            },
            Key(.cmdOption("t")),
            Expect("its chat its own tab again, with its draft") { story in
                let tabs = BoardProbe.chatTabs(story)
                return tabs.count == 1 && tabs.first?.chat?.draft == "keep me" && story.app.workspace?.activeTab === tabs.first
            },
            Command(.previousTab),
            Expect("the board shown") { story in story.app.workspace?.activeTab.board != nil },
            Command(.closeTab),
            Expect("every chat back in the strip, the same chats") { story in
                let tabs = BoardProbe.chatTabs(story)
                let now = Set(tabs.compactMap { $0.chat.map(ObjectIdentifier.init) })
                return story.app.workspace?.boardTabs.isEmpty == true && tabs.count == 3 && now == story.stash(Chats.self) { Chats() }.all
            },
        ]
    }

    final class Chats { var all: Set<ObjectIdentifier> = [] }
}

/// ⌃⌘− and ⌃⌘= step the focused tile down and up a density; the tile's ⋯ popup's Chip makes
/// it a chip; zoom fills the tab and Esc gives the layout back.
final class BoardDensity: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 3),
            Do("Focus the smallest tile") { story in
                let model = try BoardProbe.model(story)
                let frames = try BoardProbe.frames(story)
                model.focus(frames.tiles.min { $0.value.height * $0.value.width < $1.value.height * $1.value.width }?.key)
                story.window?.makeFirstResponder(nil)
            },
            Key(KeyChord(.character("-"), [.control, .command])),
            Expect("the focused tile a step smaller", found: { story in
                let model = try? BoardProbe.model(story)
                let rect = model?.focused.flatMap { try? BoardProbe.frames(story).tiles[$0] }
                return "focused \(model?.focused != nil), its frame \(String(describing: rect)), undo \(model?.history.undoStack.count ?? -1), key window \(story.window?.isKeyWindow == true), responder \(String(describing: story.window?.firstResponder.map { type(of: $0) }))"
            }) { story in
                let model = try BoardProbe.model(story)
                guard let tile = model.focused, let rect = try BoardProbe.frames(story).tiles[tile] else { return false }
                return Density.of(rect.size) != .full
            },
            Do("Chip from the tile's popup") { story in
                let model = try BoardProbe.model(story)
                guard let tile = model.focused else { return }
                model.edit { $0.setDensity(tile, .chip, in: model.size) }
            },
            Expect("a chip") { story in
                let model = try BoardProbe.model(story)
                return model.focused.flatMap(BoardProbe.density) == .chip
            },
            Key(KeyChord(.character("="), [.control, .command])),
            Expect("a card again") { story in
                try BoardProbe.model(story).focused.flatMap(BoardProbe.density) == .card
            },
            Key(KeyChord(.returnKey, [.command, .shift])),
            ExpectElement(.id(StoryID.Board.zoomed)),
            Key(.escape),
            ExpectElement(.id(StoryID.Board.zoomed), .absent),
        ]
    }
}

/// A turn asks for Bash; the chat is a card on the board: its approval has the corner marks,
/// and Allow on the card answers the chat.
final class BoardApprove: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .approvals, .gate] }
    override class var chats: Int { 3 }
    override class var script: CLIScript {
        let approval = Approval(id: "board-bash", title: "Run swift test?", detail: "Bash", body: "swift test --filter Board", canAlwaysAllow: false, questions: [])
        return CLIScript(turns: [
            CLIScript.reply("Ready."),
            [.startTurn, .approval(approval, allow: [.tool(name: "Bash", detail: "swift test", output: "passed")], deny: Beat.answer("Not run.")), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 3),
            Do("Send from the smallest tile's card") { story in
                let model = try BoardProbe.model(story)
                let frames = try BoardProbe.frames(story)
                guard let tile = frames.tiles.min(by: { $0.value.height * $0.value.width < $1.value.height * $1.value.width })?.key, let chat = model.chats[tile] else {
                    throw StoryFailure.modelMissing("a tile")
                }
                story.stash(Picked.self) { Picked() }.tile = tile
                model.edit { $0.setDensity(tile, .card, in: model.size) }
                chat.storySend("run the tests")
            },
            Expect("the card waiting, with its corner marks") { story in
                guard let tile = story.stash(Picked.self) { Picked() }.tile, let chat = try BoardProbe.model(story).chats[tile] else { return false }
                return !chat.pendingApprovals.isEmpty && StoryElement(StoryID.Board.tile(tile).part(.allow)) != nil
            },
            Snapshot("board-approval"),
            BoardPress("Allow on the card") { story in
                guard let tile = story.stash(Picked.self) { Picked() }.tile else { throw StoryFailure.modelMissing("the tile") }
                return StoryID.Board.tile(tile).part(.allow)
            },
            Expect("answered: the command ran, nothing waits") { story in
                guard let tile = story.stash(Picked.self) { Picked() }.tile, let chat = try BoardProbe.model(story).chats[tile] else { return false }
                return chat.pendingApprovals.isEmpty && !chat.isRunning
            },
        ]
    }

    final class Picked { var tile: UUID? }
}

/// Six full tiles on a big display: four stream live, the rest show their card until focused.
final class BoardLiveCap: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }
    override class var chats: Int { 6 }
    override class var needs: Needs { Needs(window: CGSize(width: 2400, height: 1300)) }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 6),
            Expect("six tiles, each big enough to be full") { story in
                let frames = try BoardProbe.frames(story)
                return frames.tiles.count == 6 && frames.tiles.values.allSatisfy { Density.of($0.size) == .full }
            },
            Expect("four drawn live, two as cards") { story in
                let tiles = try BoardProbe.model(story).board.tiles.map(\.id)
                return tiles.filter { BoardProbe.density($0) == .full }.count == BoardMetrics.liveFull && tiles.filter { BoardProbe.density($0) == .card }.count == 2
            },
            Do("Focus a card") { story in
                let model = try BoardProbe.model(story)
                model.focus(model.board.tiles.first { BoardProbe.density($0.id) == .card }?.id)
            },
            Expect("the focused one live, still four") { story in
                let model = try BoardProbe.model(story)
                guard let focused = model.focused else { return false }
                return BoardProbe.density(focused) == .full && model.board.tiles.filter { BoardProbe.density($0.id) == .full }.count == BoardMetrics.liveFull
            },
        ]
    }
}

/// The board at the default window and the mockup's wide one, for comparing with the design.
final class BoardSnapshots: BoardStoryline {
    override class var chats: Int { 6 }
    override class var needs: Needs { Needs(window: CGSize(width: 1296, height: 760)) }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 3),
            Do("Reviews, with the rest") { story in
                let model = try BoardProbe.model(story), tab = try BoardProbe.tab(story)
                guard let backend = model.board.sections.first?.id else { return }
                model.edit { $0.addSection(.right, of: backend, BoardSection(name: "Reviews", swatch: .b400)) }
                model.renaming = nil
                let reviews = model.board.sections.last?.id
                for other in BoardProbe.chatTabs(story) { story.app.workspace?.attach(other, to: tab, section: reviews) }
                model.edit { $0.setSwatch(backend, .b200) }
            },
            WaitIdle(),
            Snapshot("board-1296x760"),
            Do("The default window") { story in story.window?.setContentSize(CGSize(width: 880, height: 760)) },
            WaitIdle(),
            Snapshot("board-880x760"),
        ]
    }
}

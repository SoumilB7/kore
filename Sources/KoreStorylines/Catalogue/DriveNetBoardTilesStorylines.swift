import AppKit
import KoreUI
import src
import SwiftUI

// The board's controls that no other storyline uses as a person does: a click on a tile, a
// chip's handle (double-click, drag), a header's double-click, a section's name double-clicked,
// a gutter's double-click, a section header dragged onto another, a card's Deny, its one-line
// composer and its Stop, and an empty section's New Claude / New Codex.

/// A card that isn't focused: a click on it focuses it.
final class DriveNetBoardTileClick: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        var steps: [any Step] = super.steps() + [MakeBoard(name: "Backend", take: 3)]
        steps += DriveNetBoardTiles.cardSmallest(focusOther: true)
        steps += [
            DriveNetBoardPointer("Click the card", count: 1) { story in StoryID.Board.tile(try DriveNetBoardTiles.picked(story)) },
            Expect("the click focused it") { story in try BoardProbe.model(story).focused == DriveNetBoardTiles.picked(story) },
        ]
        return steps
    }
}

/// A chip: a double-click on its handle makes it a card; dragged by its handle onto another
/// tile's right edge, it lands there.
final class DriveNetBoardChip: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let chip: @MainActor @Sendable (StoryContext) throws -> StoryID = { story in StoryID.Board.chipHandle(try DriveNetBoardTiles.picked(story)) }
        var steps: [any Step] = super.steps() + [MakeBoard(name: "Backend", take: 3)]
        steps += DriveNetBoardTiles.chipSmallest()
        steps += [
            DriveNetBoardPointer("Double-click the chip's handle", count: 2, chip),
            Expect("a card now", found: { story in (try? DriveNetBoardTiles.picked(story)).flatMap { BoardProbe.density($0) }.map { "\($0)" } }) { story in
                BoardProbe.density(try DriveNetBoardTiles.picked(story)) == .card
            },
        ]
        steps += DriveNetBoardTiles.chipSmallest()
        steps += [
            BoardDrag(what: "the chip by its handle onto the largest tile's right edge", element: chip) { story in
                guard let frame = StoryElement(try chip(story))?.frame, let content = story.window?.contentView else { throw StoryFailure.modelMissing("the chip's handle") }
                let model = try BoardProbe.model(story)
                return CGPoint(x: frame.midX - model.origin.x, y: content.bounds.height - frame.midY - model.origin.y)
            } to: { story in
                guard let other = DriveNetBoardTiles.kept(story).other, let rect = try BoardProbe.frames(story).tiles[other] else { throw StoryFailure.modelMissing("the largest tile") }
                return CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.midY)
            },
            Expect("the chip's chat right of the largest tile", found: { story in
                let frames = try? BoardProbe.frames(story)
                let kept = DriveNetBoardTiles.kept(story)
                return "chip \(String(describing: kept.tile.flatMap { frames?.tiles[$0] })), largest \(String(describing: kept.other.flatMap { frames?.tiles[$0] }))"
            }) { story in
                let frames = try BoardProbe.frames(story), kept = DriveNetBoardTiles.kept(story)
                guard let tile = kept.tile, let other = kept.other, let moved = frames.tiles[tile], let target = frames.tiles[other] else { return false }
                return moved.minX >= target.maxX - 0.5
            },
        ]
        return steps
    }
}

/// A full tile's header double-clicked makes it a card; again, full.
final class DriveNetBoardHeaderToggle: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.claude] }
    override class var chats: Int { 3 }

    override func steps() -> [any Step] {
        let header: @MainActor @Sendable (StoryContext) throws -> StoryID = { story in StoryID.Board.tileHeader(try DriveNetBoardTiles.picked(story)) }
        return super.steps() + [
            MakeBoard(name: "Backend", take: 3),
            Do("Take the smallest tile") { story in _ = try DriveNetBoardTiles.pick(story) },
            DriveNetBoardTiles.density("full to start", .full),
            DriveNetBoardPointer("Double-click its header", count: 2, header),
            DriveNetBoardTiles.density("a card", .card),
            DriveNetBoardPointer("Double-click its header again", count: 2, header),
            DriveNetBoardTiles.density("full again", .full),
        ]
    }
}

/// A section's name double-clicked turns into its field, with the keys; a new name and Return
/// rename it.
final class DriveNetBoardSectionRename: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.codex] }
    override class var chats: Int { 1 }

    override func steps() -> [any Step] {
        let section: @MainActor @Sendable (StoryContext) throws -> UUID = { story in
            guard let id = try BoardProbe.model(story).board.sections.first?.id else { throw StoryFailure.modelMissing("a section") }
            return id
        }
        return super.steps() + [
            MakeBoard(name: "Backend", take: 1),
            Expect("not renaming") { story in try BoardProbe.model(story).renaming == nil },
            DriveNetBoardPointer("Double-click the section's name", count: 2) { story in StoryID.Board.sectionTitle(try section(story)) },
            Expect("its name field up") { story in try BoardProbe.model(story).renaming == section(story) },
            DriveNetBoardWaitForFocus { story in StoryID.Board.sectionName(try section(story)) },
            Key(.cmd("a")),
            TypeText("Frontend\n"),
            Expect("renamed Frontend", found: { story in try? BoardProbe.model(story).board.sections.map(\.name).joined(separator: ", ") }) { story in
                let model = try BoardProbe.model(story)
                return model.board.sections.map(\.name) == ["Frontend"] && model.renaming == nil
            },
        ]
    }
}

/// Two sections at seven tenths and three: a double-click on the line between them makes them
/// even.
final class DriveNetBoardGutterEqualise: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            DriveNetBoardTiles.reviews(withChat: true),
            Do("Backend at seven tenths") { story in
                let model = try BoardProbe.model(story)
                let gutter = try BoardResize.sectionGutter(story)
                let pair = gutter.lengths[0] + gutter.lengths[1]
                model.edit { $0.resize(gutter.id, lengths: [pair * 0.7, pair * 0.3]) }
            },
            DriveNetBoardTiles.share("Backend at seven tenths", 0.7),
            DoubleClick(BoardResize.sectionGutterLocator),
            DriveNetBoardTiles.share("the two even", 0.5),
        ]
    }
}

/// Reviews' header dragged onto Backend merges it there: one section of three.
final class DriveNetBoardSectionMerge: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            DriveNetBoardTiles.reviews(withChat: true),
            BoardDrag(what: "Reviews' header onto Backend", element: { story in
                StoryID.Board.sectionHeader(try BoardProbe.model(story).board.sections[1].id)
            }) { story in
                let model = try BoardProbe.model(story)
                guard let rect = try BoardProbe.frames(story).sections[model.board.sections[1].id] else { throw StoryFailure.modelMissing("Reviews") }
                return CGPoint(x: rect.midX, y: rect.minY)
            } to: { story in
                let model = try BoardProbe.model(story)
                guard let rect = try BoardProbe.frames(story).sections[model.board.sections[0].id] else { throw StoryFailure.modelMissing("Backend") }
                return CGPoint(x: rect.midX, y: rect.midY)
            },
            Expect("one section of three", found: { story in (try? BoardProbe.model(story)).map { "sections \($0.board.sections.map(\.name)), tiles \($0.board.tiles.count)" } }) { story in
                let model = try BoardProbe.model(story)
                return model.board.sections.map(\.name) == ["Backend"] && model.board.tiles.count == 3
            },
        ]
    }
}

/// A turn asks for Bash; Deny on the card answers it: nothing runs, the chat says so.
final class DriveNetBoardCardDeny: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive, .approvals] }
    override class var script: CLIScript {
        let approval = Approval(id: "board-deny", title: "Run swift test?", detail: "Bash", body: "swift test --filter Board", canAlwaysAllow: false, questions: [])
        return CLIScript(turns: [
            CLIScript.reply("Ready."),
            [.startTurn, .approval(approval, allow: [.tool(name: "Bash", detail: "swift test", output: "passed")], deny: Beat.answer("Not run.")), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        var steps: [any Step] = super.steps() + [MakeBoard(name: "Backend", take: 3)]
        steps += DriveNetBoardTiles.cardSmallest(send: "run the tests")
        steps += [
            Expect("the card waiting") { story in
                let tile = try DriveNetBoardTiles.picked(story)
                return try DriveNetBoardTiles.chat(story).pendingApprovals.isEmpty == false && StoryElement(StoryID.Board.tile(tile).part(.deny)) != nil
            },
            BoardPress("Deny on the card") { story in StoryID.Board.tile(try DriveNetBoardTiles.picked(story)).part(.deny) },
            Expect("denied: nothing waits, the command never ran", found: { story in
                (try? DriveNetBoardTiles.chat(story)).map { chat in chat.storyTranscript.entries.map { "\($0.kind): \($0.text)" }.joined(separator: " | ") }
            }) { story in
                let chat = try DriveNetBoardTiles.chat(story)
                let entries = chat.storyTranscript.entries
                return chat.pendingApprovals.isEmpty && !chat.isRunning
                    && entries.contains { $0.kind == .answer && $0.text == "Not run." } && !entries.contains { $0.kind == .tool }
            },
        ]
        return steps
    }
}

/// A card's one-line composer: a click puts the caret there, the message and Return send it,
/// and the answer comes.
final class DriveNetBoardCardComposer: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }

    override func steps() -> [any Step] {
        let field: @MainActor @Sendable (StoryContext) throws -> StoryID = { story in StoryID.Board.tile(try DriveNetBoardTiles.picked(story)).part(.field) }
        var steps: [any Step] = super.steps() + [MakeBoard(name: "Backend", take: 3)]
        steps += DriveNetBoardTiles.cardSmallest()
        steps += [
            DriveNetBoardClick("Click the card's message field", field),
            DriveNetBoardWaitForFocus(field),
            TypeText("ship it\n"),
            Expect("sent from the card, and answered", found: { story in
                (try? DriveNetBoardTiles.chat(story)).map { chat in "draft “\(chat.draft)”, running \(chat.isRunning), " + chat.storyTranscript.entries.map { "\($0.kind): \($0.text)" }.joined(separator: " | ") }
            }) { story in
                let chat = try DriveNetBoardTiles.chat(story)
                let entries = chat.storyTranscript.entries
                return chat.draft.isEmpty && !chat.isRunning && entries.last { $0.kind == .user }?.text == "ship it"
                    && entries.last { $0.kind == .answer }?.text == "Again."
            },
        ]
        return steps
    }
}

/// A card's Stop while its turn runs a long command: the turn ends, interrupted.
final class DriveNetBoardCardStop: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("Ready."), [.startTurn, .wait(.interrupt), .finishTurn(.interrupted)]])
    }

    override func steps() -> [any Step] {
        var steps: [any Step] = super.steps() + [MakeBoard(name: "Backend", take: 3)]
        steps += DriveNetBoardTiles.cardSmallest(send: "run the long job")
        steps += [
            Expect("its turn running, Stop on the card") { story in
                let tile = try DriveNetBoardTiles.picked(story)
                let chat = try DriveNetBoardTiles.chat(story)
                // Sent isn't begun: the second turn's start has come.
                let begun = story.events.filter { event in
                    if event.chat == chat.id, case .turnStarted = event.event { true } else { false }
                }.count >= 2
                return begun && chat.isRunning && StoryElement(StoryID.Board.tile(tile).part(.stop)) != nil
            },
            BoardPress("Stop on the card") { story in StoryID.Board.tile(try DriveNetBoardTiles.picked(story)).part(.stop) },
            Expect("the turn over, interrupted") { story in
                let chat = try DriveNetBoardTiles.chat(story)
                let interrupted = story.events.contains { event in
                    guard event.chat == chat.id, case .turnFinished(_, .interrupted, _) = event.event else { return false }
                    return true
                }
                return !chat.isRunning && interrupted
            },
            Expect("no Stop left on the card") { story in StoryElement(StoryID.Board.tile(try DriveNetBoardTiles.picked(story)).part(.stop)) == nil },
        ]
        return steps
    }
}

/// An empty section's New Claude / New Codex starts that chat there.
final class DriveNetBoardSlotProvider: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .drive] }
    override class var chats: Int { 2 }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            DriveNetBoardTiles.reviews(withChat: false),
            DriveNetBoardClick("Press the empty section's New chat of the variant's provider") { story in
                let model = try BoardProbe.model(story)
                return StoryID.Board.slotProvider(model.board.sections[1].id, story.variant?.provider ?? "claude")
            },
            Expect("a new chat of that provider in Reviews", found: { story in
                (try? BoardProbe.model(story)).map { model in "sections \(model.board.sections.map { "\($0.name): \($0.tiles.count)" }), chats \(model.chats.count)" }
            }) { story in
                let model = try BoardProbe.model(story)
                guard model.board.sections.count == 2, let tile = model.board.sections[1].tiles.first?.id, model.board.sections[1].tiles.count == 1,
                    let chat = model.chats[tile]
                else { return false }
                return chat.provider.id == (story.variant?.provider ?? "claude") && model.chats.count == 3
            },
        ]
    }
}

// MARK: - Helpers

@MainActor
enum DriveNetBoardTiles {
    final class Kept {
        var tile: UUID?
        var other: UUID?
    }

    static func kept(_ story: StoryContext) -> Kept { story.stash(Kept.self) { Kept() } }

    static func picked(_ story: StoryContext) throws -> UUID {
        guard let tile = kept(story).tile else { throw StoryFailure.modelMissing("the tile this storyline picked") }
        return tile
    }

    static func chat(_ story: StoryContext) throws -> Chat {
        guard let chat = try BoardProbe.model(story).chats[picked(story)] else { throw StoryFailure.modelMissing("the picked tile's chat") }
        return chat
    }

    /// The smallest tile and the largest, by area (the smallest kept).
    static func pick(_ story: StoryContext) throws -> (small: UUID, large: UUID) {
        let tiles = try BoardProbe.frames(story).tiles.sorted { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
        guard let small = tiles.first?.key, let large = tiles.last?.key, small != large else { throw StoryFailure.modelMissing("two tiles") }
        let kept = kept(story)
        kept.tile = small
        kept.other = large
        return (small, large)
    }

    /// The smallest tile made a card (as its ⋯ would); optionally another focused, or a message
    /// sent from its chat.
    static func cardSmallest(focusOther: Bool = false, send: String? = nil) -> [any Step] {
        [
            Do("Make the smallest tile a card") { story in
                let model = try BoardProbe.model(story)
                let (small, large) = try pick(story)
                model.edit { $0.setDensity(small, .card, in: model.size) }
                if focusOther { model.focus(large) }
                if let send, let chat = model.chats[small] { chat.storySend(send) }
            },
            density("a card", .card),
        ]
    }

    /// The smallest tile, or the one picked before, made a chip.
    static func chipSmallest() -> [any Step] {
        [
            Do("Make the smallest tile a chip") { story in
                let model = try BoardProbe.model(story)
                let small = try kept(story).tile ?? pick(story).small
                model.edit { $0.setDensity(small, .chip, in: model.size) }
            },
            density("a chip", .chip),
        ]
    }

    static func density(_ what: String, _ density: Density) -> Expect {
        Expect(what, found: { story in (try? picked(story)).flatMap { BoardProbe.density($0) }.map { "\($0)" } }) { story in
            BoardProbe.density(try picked(story)) == density
        }
    }

    /// A Reviews section right of Backend, with the strip's last chat or empty.
    static func reviews(withChat: Bool) -> Do {
        Do("A Reviews section" + (withChat ? " with the third chat" : ", empty")) { story in
            let model = try BoardProbe.model(story), tab = try BoardProbe.tab(story)
            guard let backend = model.board.sections.first?.id else { throw StoryFailure.modelMissing("Backend") }
            model.edit { $0.addSection(.right, of: backend, BoardSection(name: "Reviews")) }
            model.renaming = nil
            guard withChat else { return }
            guard let third = BoardProbe.chatTabs(story).first else { throw StoryFailure.modelMissing("a chat in the strip") }
            story.app.workspace?.attach(third, to: tab, section: model.board.sections.last?.id)
        }
    }

    /// Backend's share of the two sections' width.
    static func share(_ what: String, _ share: CGFloat) -> Expect {
        Expect(what, found: { story in
            guard let model = try? BoardProbe.model(story), let frames = try? BoardProbe.frames(story) else { return nil }
            return "widths \(model.board.sections.compactMap { frames.sections[$0.id]?.width })"
        }) { story in
            let model = try BoardProbe.model(story), frames = try BoardProbe.frames(story)
            let widths = model.board.sections.compactMap { frames.sections[$0.id]?.width }
            guard widths.count == 2 else { return false }
            return abs(widths[0] / (widths[0] + widths[1]) - share) < 0.02
        }
    }
}

/// Clicks an element whose id the board gives at the time, as a person's mouse does: the point
/// checked to be the element's.
struct DriveNetBoardPointer: Step {
    let what: String
    let count: Int
    let id: @MainActor @Sendable (StoryContext) throws -> StoryID
    var label: String { what }
    init(_ what: String, count: Int, _ id: @escaping @MainActor @Sendable (StoryContext) throws -> StoryID) {
        self.what = what
        self.count = count
        self.id = id
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let element = try await story.element(.id(try id(story)))
        if count > 1 { try await story.input.click(element, count: count) } else { try await story.input.pointerClick(element) }
    }
}

/// A click at an element whose id the board gives at the time (a field's caret, a button).
struct DriveNetBoardClick: Step {
    let what: String
    let id: @MainActor @Sendable (StoryContext) throws -> StoryID
    var label: String { what }
    init(_ what: String, _ id: @escaping @MainActor @Sendable (StoryContext) throws -> StoryID) {
        self.what = what
        self.id = id
    }

    @MainActor func run(_ story: StoryContext) async throws { try await Click(.id(try id(story))).run(story) }
}

/// Waits for the keys in an element whose id the board gives at the time.
struct DriveNetBoardWaitForFocus: Step {
    let id: @MainActor @Sendable (StoryContext) throws -> StoryID
    var label: String { "Wait for the keys there" }
    init(_ id: @escaping @MainActor @Sendable (StoryContext) throws -> StoryID) { self.id = id }

    @MainActor func run(_ story: StoryContext) async throws { try await WaitForFocus(.id(try id(story))).run(story) }
}

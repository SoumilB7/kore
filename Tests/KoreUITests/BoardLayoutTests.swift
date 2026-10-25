import CoreGraphics
import Foundation
import Testing

@testable import KoreUI

/// The board's pure layout (dynamic-tab.html §2, §3, §7): the solver covers the tab exactly at
/// any size, keeps minimums and stacks what can't fit; gutters push to minimums, snap and pin
/// chips; every edit keeps every tile; undo walks back to the start; and it all round-trips
/// through Codable.
struct BoardLayoutTests {
    static let wide = CGSize(width: 1296, height: 720)
    static let narrow = CGSize(width: 880, height: 720)

    /// Two sections side by side: Backend (a full tile over two), Reviews (three in a row).
    static func ops() -> (Board, [UUID]) {
        let t = (0..<6).map { _ in UUID() }
        let backend = BoardSection(
            name: "Backend",
            body: .split(.column, [.init(.fraction(0.6), .leaf(BoardTile(id: t[0]))), .init(.fraction(0.4), .split(.row, [.init(.fraction(0.5), .leaf(BoardTile(id: t[1]))), .init(.fraction(0.5), .leaf(BoardTile(id: t[2])))]))]))
        let reviews = BoardSection(
            name: "Reviews",
            body: .split(.row, [.init(.fraction(1.0 / 3), .leaf(BoardTile(id: t[3]))), .init(.fraction(1.0 / 3), .leaf(BoardTile(id: t[4]))), .init(.fraction(1.0 / 3), .leaf(BoardTile(id: t[5])))]))
        let board = Board(name: "Ops", root: .split(.row, [.init(.fraction(0.44), .leaf(backend)), .init(.fraction(0.56), .leaf(reviews))]))
        return (board, t)
    }

    /// No two tiles overlap, and each is inside its section's body.
    static func strict(_ board: Board, _ frames: BoardFrames) -> Bool {
        let rects = Array(frames.tiles.values)
        for i in rects.indices {
            for j in rects.indices where j > i && rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j].insetBy(dx: 0.5, dy: 0.5)) { return false }
        }
        for section in board.sections {
            guard let body = frames.bodies[section.id] else { return false }
            for tile in section.tiles {
                guard let rect = frames.tiles[tile.id], body.insetBy(dx: -0.5, dy: -0.5).contains(rect) else { return false }
            }
        }
        return true
    }

    // MARK: Solver

    @Test func sectionsCoverTheTabExactly() {
        let (board, _) = Self.ops()
        let frames = board.solve(in: Self.wide)
        let sections = board.sections.compactMap { frames.sections[$0.id] }
        let area = sections.map { $0.width * $0.height }.reduce(0, +)
        // Two sections and one 1pt line.
        #expect(abs(area + Size.Board.sectionGap * Self.wide.height - Self.wide.width * Self.wide.height) < 1)
        #expect(Self.strict(board, frames))
        #expect(frames.content == Self.wide)
    }

    @Test func densityFollowsSizeAndTheSameTreeFitsAnySize() {
        let (board, t) = Self.ops()
        let wide = board.solve(in: Self.wide)
        let narrow = board.solve(in: Self.narrow)
        #expect(Density.of(wide.tiles[t[0]]!.size) == .full)
        // Backend at 44% of 880 is under 420 wide: the same tile is a card.
        #expect(Density.of(narrow.tiles[t[0]]!.size) == .card)
        #expect(Density.of(CGSize(width: 300, height: 30)) == .chip)
        #expect(Density.of(CGSize(width: 300, height: 63)) == .chip)
        #expect(Density.of(CGSize(width: 419, height: 600)) == .card)
        #expect(Density.of(CGSize(width: 420, height: 300)) == .full)
        // Fractions, not points: the shares hold at both sizes.
        let ratio = { (f: BoardFrames) in f.sections[board.sections[0].id]!.width / f.content.width }
        #expect(abs(ratio(wide) - ratio(narrow)) < 0.01)
    }

    @Test func aRowTooNarrowForItsMinimumsStacks() {
        let (board, t) = Self.ops()
        // Reviews' three tiles need 3 × 140 + 2 × 8; at 420 wide its row can't keep them.
        let frames = board.solve(in: CGSize(width: 420, height: 640))
        #expect(frames.stacked > 0)
        #expect(Self.strict(board, frames))
        for id in t { #expect(frames.tiles[id]!.width >= Size.Board.tileMin.width) }
        // Stacked, it scrolls up and down, never sideways.
        #expect(frames.content.width == 420)
    }

    @Test func minimumsHoldInATinyTab() {
        let (board, t) = Self.ops()
        let frames = board.solve(in: CGSize(width: 200, height: 100))
        #expect(Self.strict(board, frames))
        for id in t {
            #expect(frames.tiles[id]!.height >= Size.Board.tileMin.height - 0.01)
        }
        #expect(frames.content.height > 100)
    }

    @Test func aPinnedChipKeepsItsHeightAtAnySize() {
        var (board, t) = Self.ops()
        let gutter = board.solve(in: Self.wide).gutters.first { $0.id.section == board.sections[0].id && $0.axis == .column }!
        board.resize(gutter.id, lengths: [gutter.lengths[0] + gutter.lengths[1] - 30, 30])
        for size in [Self.wide, Self.narrow, CGSize(width: 2560, height: 1400)] {
            #expect(board.solve(in: size).tiles[t[1]]!.height == Size.Board.chip)
        }
    }

    // MARK: Gutters

    @Test func aGutterStopsAtItsNeighboursMinimum() {
        let (board, _) = Self.ops()
        let gutter = board.solve(in: Self.wide).gutters.first { $0.id.section == nil }!
        let (lengths, _) = GutterDrag.lengths(gutter, delta: 5000, free: true)
        #expect(lengths[1] == gutter.mins[1])
        #expect(abs(lengths.reduce(0, +) - gutter.lengths.reduce(0, +)) < 0.001)
    }

    @Test func aGutterSnapsToTwoThirdsUnlessCommandIsHeld() {
        let (board, _) = Self.ops()
        let gutter = board.solve(in: Self.wide).gutters.first { $0.id.section == nil }!
        let twoThirds = gutter.extent * 2 / 3 - gutter.gap / 2
        let near = twoThirds - gutter.lengths[0] + 5
        let (snapped, snap) = GutterDrag.lengths(gutter, delta: near)
        #expect(abs(snapped[0] - twoThirds) < 0.001)
        #expect(snap == .share("⅔"))
        let (free, none) = GutterDrag.lengths(gutter, delta: near, free: true)
        #expect(abs(free[0] - (twoThirds + 5)) < 0.001)
        #expect(none == nil)
    }

    @Test func underSixtyFourATileSnapsToAChipAndPins() {
        var (board, t) = Self.ops()
        let frames = board.solve(in: Self.wide)
        let gutter = frames.gutters.first { $0.id.section == board.sections[0].id && $0.axis == .column }!
        let (lengths, snap) = GutterDrag.lengths(gutter, delta: gutter.lengths[1] - 50)
        #expect(lengths[1] == Size.Board.chip)
        #expect(snap == .density(.chip))
        board.resize(gutter.id, lengths: lengths)
        guard case .split(_, let children)? = board.sections[0].body else { Issue.record("no split"); return }
        #expect(children[1].share == .pinned(Size.Board.chip))
        #expect(Density.of(board.solve(in: Self.wide).tiles[t[1]]!.size) == .chip)
    }

    // MARK: Edits

    @Test func autoPlacementSplitsTheLargestTileAlongItsLongerSide() {
        var (board, t) = Self.ops()
        let new = UUID()
        board.attach(new, to: board.sections[0].id, in: Self.wide)
        let frames = board.solve(in: Self.wide)
        // t[0] was the largest, wider than tall: it's now beside the new one.
        #expect(abs(frames.tiles[new]!.minY - frames.tiles[t[0]]!.minY) < 0.5)
        #expect(frames.tiles[new]!.minX > frames.tiles[t[0]]!.minX)
        #expect(board.tiles.count == 7)
        #expect(Self.strict(board, frames))

        var empty = Board()
        empty.attach(new, to: empty.sections[0].id, in: Self.wide)
        #expect(empty.sections[0].body == .leaf(BoardTile(id: new)))
    }

    @Test func removingATileGivesItsRoomToItsNeighbour() {
        var (board, t) = Self.ops()
        board.remove(t[2])
        let frames = board.solve(in: Self.wide)
        #expect(board.tiles.count == 5)
        // t[1] took the whole row.
        #expect(abs(frames.tiles[t[1]]!.width - frames.tiles[t[0]]!.width) < 0.5)
        board.remove(t[1])
        board.remove(t[0])
        #expect(board.sections[0].body == nil)
        #expect(board.sections.count == 2)
    }

    @Test func moveSplitsSwapsAndMakesSections() {
        var (board, t) = Self.ops()
        // Onto the right edge of a review: a split there, and the origin collapses.
        board.move(t[1], to: .beside(t[3], .right), in: Self.wide)
        var frames = board.solve(in: Self.wide)
        #expect(board.section(of: t[1])?.name == "Reviews")
        #expect(abs(frames.tiles[t[1]]!.minY - frames.tiles[t[3]]!.minY) < 0.5)
        #expect(frames.tiles[t[1]]!.minX > frames.tiles[t[3]]!.minX)
        // Swap: each in the other's place.
        let before = frames.tiles
        board.move(t[0], to: .swap(t[5]), in: Self.wide)
        frames = board.solve(in: Self.wide)
        #expect(frames.tiles[t[0]] == before[t[5]])
        #expect(frames.tiles[t[5]] == before[t[0]])
        // The tab's edge: a new section holding it.
        board.move(t[4], to: .newSection(.right), in: Self.wide)
        #expect(board.sections.count == 3)
        #expect(board.sections.last?.tiles.map(\.id) == [t[4]])
        #expect(board.tiles.count == 6)
        #expect(Self.strict(board, board.solve(in: Self.wide)))
    }

    @Test func mergeAndRemoveKeepEveryChat() {
        var (board, _) = Self.ops()
        let ids = Set(board.tiles.map(\.id))
        let backend = board.sections[0].id
        board.mergeSection(board.sections[1].id, into: backend)
        #expect(board.sections.count == 1)
        #expect(board.sections[0].name == "Backend")
        #expect(Set(board.tiles.map(\.id)) == ids)
        // The merged tiles are a new row at the bottom.
        let frames = board.solve(in: Self.wide)
        #expect(Self.strict(board, frames))

        var (other, _) = Self.ops()
        let all = Set(other.tiles.map(\.id))
        other.removeSection(other.sections[0].id)
        #expect(other.sections.map(\.name) == ["Reviews"])
        #expect(Set(other.tiles.map(\.id)) == all)
    }

    @Test func sectionsSplitRenameAndSwatch() {
        var board = Board()
        let first = board.sections[0].id
        board.addSection(.right, of: first, BoardSection(name: "Section 2"))
        board.addSection(.bottom, of: first, BoardSection(name: "Section 3"))
        #expect(board.sections.map(\.name) == ["Section 1", "Section 3", "Section 2"])
        board.rename(first, to: "Backend")
        board.rename(first, to: "   ")
        board.setSwatch(first, .b400)
        #expect(board.sections[0].name == "Backend")
        #expect(board.sections[0].swatch == .b400)
    }

    @Test func densityByResizing() {
        var (board, t) = Self.ops()
        let chipped = board.setDensity(t[1], .chip, in: Self.wide)
        #expect(chipped)
        #expect(Density.of(board.solve(in: Self.wide).tiles[t[1]]!.size) == .chip)
        let carded = board.setDensity(t[1], .card, in: Self.wide)
        #expect(carded)
        #expect(Density.of(board.solve(in: Self.wide).tiles[t[1]]!.size) == .card)
        // A lone tile has no split to take room from.
        var single = Board()
        let only = UUID()
        single.attach(only, to: single.sections[0].id, in: Self.wide)
        let lone = single.setDensity(only, .chip, in: Self.wide)
        #expect(!lone)
    }

    @Test func focusMovesToTheNearestTileThatWay() {
        let (board, t) = Self.ops()
        let frames = board.solve(in: Self.wide)
        #expect(board.neighbour(of: t[1], toward: .top, in: frames) == t[0])
        #expect(board.neighbour(of: t[0], toward: .right, in: frames) == t[3])
        #expect(board.neighbour(of: t[0], toward: .left, in: frames) == nil)
    }

    // MARK: Undo and persistence

    @Test func eachEditIsOneUndoStepBackToTheStart() {
        let (start, t) = Self.ops()
        var history = BoardHistory(start)
        let size = Self.wide
        history.apply { $0.move(t[1], to: .beside(t[3], .right), in: size) }
        history.apply { $0.mergeSection($0.sections[1].id, into: $0.sections[0].id) }
        // A change that changes nothing isn't a step.
        let none = history.apply { $0.rename($0.sections[0].id, to: "") }
        #expect(!none)
        #expect(history.undoStack.count == 2)
        history.undo()
        history.undo()
        #expect(history.board == start)
        #expect(!history.canUndo)
        history.redo()
        #expect(history.board.section(of: t[1])?.name == "Reviews")
        history.apply { $0.rename($0.sections[0].id, to: "Ops") }
        #expect(!history.canRedo)
    }

    @Test func undoKeepsAHundredSteps() {
        var history = BoardHistory(Board())
        for n in 0..<150 { history.apply { $0.rename($0.sections[0].id, to: "n\(n)") } }
        #expect(history.undoStack.count == Size.Board.undoDepth)
    }

    @Test func aBoardAndItsStepsRoundTrip() throws {
        let (board, t) = Self.ops()
        var history = BoardHistory(board)
        history.apply { $0.setSwatch($0.sections[0].id, .b200) }
        history.apply { $0.setDensity(t[2], .chip, in: Self.wide) }
        let saved = SavedBoard(history: history, chats: [t[0].uuidString: Workspace.Saved.Tab(provider: "claude", session: "s1", title: "auth refresh")])
        let tab = Workspace.Saved.Tab(board: saved)
        let data = try JSONEncoder().encode(Workspace.Saved(tabs: [tab], active: 0))
        let back = try JSONDecoder().decode(Workspace.Saved.self, from: data)
        #expect(back.tabs[0].board == saved)
        #expect(back.tabs[0].board?.history.undoStack.count == 2)
        // Older saves, with no board, still read.
        let old = try JSONDecoder().decode(Workspace.Saved.self, from: Data(#"{"tabs":[{"provider":"claude"}],"active":0}"#.utf8))
        #expect(old.tabs[0].board == nil)
    }
}

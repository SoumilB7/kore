import CoreGraphics
import Foundation
import Testing

@testable import KoreUI

/// A grip pulled apart (board-resize-2.html, option A): the room becomes an empty leaf in the
/// split tree with the other edge kept; under a tile's least it closes again; a slot closed
/// gives its room back in proportion; a tile dropped in fills it; each is one undo step.
struct BoardSlotTests {
    static let size = CGSize(width: 1296, height: 720)

    /// One section of two tiles in a row, or a column.
    static func pair(_ axis: SplitAxis = .row) -> (Board, UUID, UUID) {
        let a = UUID(), b = UUID()
        let body = Split<BoardTile>.split(axis, [.init(.fraction(0.5), .leaf(BoardTile(id: a))), .init(.fraction(0.5), .leaf(BoardTile(id: b)))])
        return (Board(name: "Ops", root: .leaf(BoardSection(name: "Backend", body: body))), a, b)
    }

    static func near(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 0.5 }
    static func near(_ a: CGRect, _ b: CGRect) -> Bool { near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height) }

    static func open(_ board: inout Board, delta: CGFloat, slot: UUID) -> RoomPull {
        let gutter = board.solve(in: size).gutters.first { $0.id.section != nil }!
        let pull = RoomPull(gutter, delta: delta)
        if pull.opens { board.openSlot(gutter.id, lengths: pull.lengths, slot: slot) }
        return pull
    }

    @Test func underATilesLeastTheEdgesCloseAgain() {
        var (board, _, _) = Self.pair()
        let before = board
        let pull = Self.open(&board, delta: 120, slot: UUID())
        #expect(!pull.opens)
        #expect(board == before)
    }

    @Test func pullingRightKeepsTheLeftEdgeAndLeavesASlot() {
        var (board, a, b) = Self.pair()
        let start = board.solve(in: Self.size)
        let slot = UUID()
        let pull = Self.open(&board, delta: 300, slot: slot)
        let frames = board.solve(in: Self.size)
        #expect(pull.opens && pull.room == 300 - Size.Board.gap)
        #expect(board.tiles.map(\.id) == [a, slot, b])
        #expect(Self.near(frames.tiles[a]!, start.tiles[a]!))
        #expect(Self.near(frames.tiles[slot]!, pull.rect))
        #expect(Self.near(frames.tiles[b]!.maxX, start.tiles[b]!.maxX) && Self.near(frames.tiles[b]!.width, start.tiles[b]!.width - 300))
        #expect(Self.near(pull.moved(start.tiles[b]!), frames.tiles[b]!))
        #expect(BoardLayoutTests.strict(board, frames))
    }

    @Test func pullingLeftKeepsTheRightEdge() {
        var (board, a, b) = Self.pair()
        let start = board.solve(in: Self.size)
        let slot = UUID()
        let pull = Self.open(&board, delta: -200, slot: slot)
        let frames = board.solve(in: Self.size)
        #expect(board.tiles.map(\.id) == [a, slot, b])
        #expect(Self.near(frames.tiles[b]!, start.tiles[b]!))
        #expect(Self.near(frames.tiles[slot]!, pull.rect))
        #expect(Self.near(frames.tiles[a]!.width, start.tiles[a]!.width - 200))
    }

    @Test func aPullStopsAtTheGivingSidesLeast() {
        var (board, _, b) = Self.pair()
        _ = Self.open(&board, delta: 5000, slot: UUID())
        #expect(Self.near(board.solve(in: Self.size).tiles[b]!.width, Size.Board.tileMin.width))
    }

    @Test func aStackedDividerOpensRoomAChipTall() {
        var (board, a, b) = Self.pair(.column)
        let slot = UUID()
        let pull = Self.open(&board, delta: 40, slot: slot)
        #expect(pull.opens && pull.least == Size.Board.tileMin.height)
        #expect(board.tiles.map(\.id) == [a, slot, b])
        #expect(Density.of(board.solve(in: Self.size).tiles[slot]!.size) == .chip)
    }

    @Test func closingASlotGivesItsRoomBackInProportion() {
        var (board, a, b) = Self.pair()
        let slot = UUID()
        _ = Self.open(&board, delta: 400, slot: slot)
        let open = board.solve(in: Self.size)
        let ratio = open.tiles[a]!.width / open.tiles[b]!.width
        board.closeSlot(slot)
        let closed = board.solve(in: Self.size)
        #expect(board.tiles.map(\.id) == [a, b])
        #expect(abs(closed.tiles[a]!.width / closed.tiles[b]!.width - ratio) < 0.01)
        #expect(BoardLayoutTests.strict(board, closed))
    }

    @Test func closingTheLastTileEmptiesTheSection() {
        let slot = UUID()
        var board = Board(name: "Ops", root: .leaf(BoardSection(name: "Backend", body: .leaf(BoardTile(id: slot)))))
        board.closeSlot(slot)
        #expect(board.sections.first?.body == nil)
    }

    @Test func aTileDroppedInFillsTheSlotAndItsPlaceCloses() {
        var (board, a, b) = Self.pair()
        let slot = UUID()
        _ = Self.open(&board, delta: 300, slot: slot)
        board.fill(slot, with: a)
        #expect(board.tiles.map(\.id) == [a, b])
        #expect(board.section(of: slot) == nil)
    }

    @Test func doubleClickEvensADividerAndTheGripIsItsMiddle() {
        var (board, a, b) = Self.pair()
        let gutter = board.solve(in: Self.size).gutters.first { $0.id.section != nil }!
        board.resize(gutter.id, lengths: [gutter.lengths[0] + 200, gutter.lengths[1] - 200])
        let moved = board.solve(in: Self.size).gutters.first { $0.id.section != nil }!
        board.resize(moved.id, lengths: GutterDrag.even(moved))
        let frames = board.solve(in: Self.size)
        #expect(Self.near(frames.tiles[a]!.width, frames.tiles[b]!.width))
        #expect(gutter.grip.width == Size.Board.gap + 2 * Size.Board.grab && gutter.grip.midY == gutter.rect.midY && gutter.grip.height == Size.Board.grip.height)
    }

    @Test func eachIsOneUndoStep() {
        let (start, a, _) = Self.pair()
        var history = BoardHistory(start)
        let slot = UUID()
        history.apply { _ = Self.open(&$0, delta: 300, slot: slot) }
        let opened = history.board
        history.apply { $0.closeSlot(slot) }
        #expect(history.board.section(of: slot) == nil)
        history.undo()
        #expect(history.board == opened)
        history.apply { $0.fill(slot, with: a) }
        history.undo()
        history.undo()
        #expect(history.board == start)
    }
}

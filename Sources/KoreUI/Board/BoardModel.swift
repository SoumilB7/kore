import Foundation
import Observation

/// The board's sizes storylines check against.
package enum BoardMetrics {
    package static let chip = Size.Board.chip
    package static let tileHeader = Size.Board.tileHeader
    package static let liveFull = Size.Board.liveFull
}

/// A board as it's saved with the window's tabs: its layout with its undo steps, and each
/// tile's chat as a tab would save it (by session id; no pixel sizes).
struct SavedBoard: Codable, Equatable {
    var history: BoardHistory
    /// By tile id.
    var chats: [String: Workspace.Saved.Tab]
}

/// A board tab's state: its layout and steps, the chat in each tile, which tile has focus or is
/// zoomed, and which chats finished while no one was looking. A chat lives in one place: a
/// board's tile or the strip, never both.
@MainActor @Observable
package final class BoardModel {
    package private(set) var history: BoardHistory
    /// By tile id; a tile with none is a slot.
    package private(set) var chats: [UUID: Chat] = [:]
    package var focused: UUID?
    /// The tile filling the tab (⌘⇧↩); the layout under it doesn't change. Not saved.
    package var zoomed: UUID?
    /// Chats whose turn ended while their tile wasn't focused: the accent dot.
    private(set) var unseen: Set<UUID> = []
    /// The tab's size, as the view last laid it out: edits that place by size use it.
    @ObservationIgnored package var size = CGSize(width: Layout.Window.defaultWidth, height: Layout.Window.defaultHeight)
    /// The frames as the view lays them out now, and where the view is in the window (global):
    /// a strip tab dropped on the board lands by them.
    @ObservationIgnored var frames: (() -> BoardFrames)?
    @ObservationIgnored package var origin = CGPoint.zero
    /// A strip tab dragged over the board: where it would land, and the zone that lights.
    var incoming: (drop: BoardDrop, zone: CGRect)?
    /// Where something dropped at a window point (SwiftUI's global space) would land.
    func drop(atGlobal point: CGPoint) -> (drop: BoardDrop, zone: CGRect)? {
        frames?().drop(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), moving: nil).map { (drop: $0.0, zone: $0.1) }
    }

    /// A section whose name is being typed, after Split or a new board.
    package var renaming: UUID?
    @ObservationIgnored var onChange: (() -> Void)?

    package var board: Board { history.board }
    package var name: String { board.name }

    init(_ history: BoardHistory, chats: [UUID: Chat] = [:]) {
        self.history = history
        self.chats = chats
    }

    package convenience init() {
        var board = Board()
        board.root = .leaf(BoardSection(name: "Section 1"))
        self.init(BoardHistory(board))
        renaming = board.sections.first?.id
    }

    /// One layout step. The chats of tiles it took out are given back.
    @discardableResult
    package func edit(_ change: (inout Board) -> Void) -> [Chat] {
        let changed = history.apply(change)
        guard changed else { return [] }
        return settle()
    }

    package func undo() -> [Chat] {
        history.undo()
        return settle()
    }

    package func redo() -> [Chat] {
        history.redo()
        return settle()
    }

    /// Tiles gone from the layout give their chats back (to the strip); focus and zoom leave
    /// tiles that went.
    private func settle() -> [Chat] {
        let ids = Set(board.tiles.map(\.id))
        let gone = chats.filter { !ids.contains($0.key) }
        for id in gone.keys { chats[id] = nil }
        if let focused, !ids.contains(focused) { self.focused = nil }
        if let zoomed, !ids.contains(zoomed) { self.zoomed = nil }
        onChange?()
        return Array(gone.values)
    }

    /// The board's tab closed: its chats are let go of (to the strip), not ended.
    func close() {
        chats.removeAll()
        onChange = nil
    }

    /// Puts a chat in a tile (a new one, or a slot).
    func place(_ chat: Chat, in tile: UUID) {
        chats[tile] = chat
        onChange?()
    }

    /// The tile of a chat, if it's on this board.
    package func tile(of chat: Chat) -> UUID? { chats.first { $0.value === chat }?.key }

    /// Every chat on the board, in the layout's order.
    package var orderedChats: [Chat] { board.tiles.compactMap { chats[$0.id] } }

    func turnEnded(_ chat: Chat) {
        guard let tile = tile(of: chat), tile != focused else { return }
        unseen.insert(chat.id)
    }

    func seen(_ chat: Chat) {
        if unseen.contains(chat.id) { unseen.remove(chat.id) }
    }

    func isUnseen(_ chat: Chat) -> Bool { unseen.contains(chat.id) }

    package func focus(_ tile: UUID?) {
        focused = tile
        if let tile, let chat = chats[tile] { seen(chat) }
    }

    /// The full tiles that stream live: the focused one, then the rest in the layout's order,
    /// `Size.Board.liveFull` at most. The others show their summary until focused or hovered.
    func live(_ full: [UUID], hovered: UUID?) -> Set<UUID> {
        var order = full
        for first in [hovered, focused].compactMap({ $0 }) where order.contains(first) {
            order.removeAll { $0 == first }
            order.insert(first, at: 0)
        }
        return Set(order.prefix(Size.Board.liveFull))
    }

    // MARK: State, rolled up

    /// The most urgent state among the board's chats, for its strip mark.
    var urgent: BoardTileState {
        orderedChats.map { BoardTileState.of($0, unseen: isUnseen($0)) }.min() ?? .idle
    }

    /// What `SavedBoard` keeps of it.
    func saved(_ tab: (Chat) -> Workspace.Saved.Tab) -> SavedBoard {
        SavedBoard(history: history, chats: Dictionary(uniqueKeysWithValues: chats.map { ($0.key.uuidString, tab($0.value)) }))
    }
}

/// A tile's one cue, most urgent first: waiting for the owner (accent corner marks), failed
/// (a red mark), stuck (⚠), working (the CLI-coloured spinner), done and not yet seen (an
/// accent dot), idle (the CLI's logo).
enum BoardTileState: Int, Comparable {
    case waiting, failed, stuck, working, unseen, idle

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    @MainActor static func of(_ chat: Chat, unseen: Bool) -> BoardTileState {
        if !chat.approvals.pending.isEmpty { return .waiting }
        let running = TabWork.running(chat)
        if running, chat.isBusy || chat.isWaitingForNetwork, chat.connection.stuck { return .stuck }
        if running { return .working }
        if chat.transcript.lastTurnFailed != nil { return .failed }
        return unseen ? .unseen : .idle
    }

    /// Spoken and stamped on the tile for storylines.
    var word: String {
        switch self {
        case .waiting: "waiting for approval"
        case .failed: "failed"
        case .stuck: "stuck"
        case .working: "working"
        case .unseen: "done"
        case .idle: "idle"
        }
    }
}

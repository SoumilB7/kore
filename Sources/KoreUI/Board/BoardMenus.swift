import AppKit
import Foundation

extension StoryID {
    /// The board: tiles, sections and gutters by their layout ids.
    package enum Board {
        package static func board(_ tab: UUID) -> StoryID { StoryID(.board, "board", key: tab.uuidString) }
        /// A tile; `.part(.allow)` / `.part(.deny)` its card's approval, `.part(.field)` its
        /// one-line composer, `.part(.stop)` its Stop.
        package static func tile(_ id: UUID) -> StoryID { StoryID(.board, "tile", key: id.uuidString) }
        package static func tileHeader(_ id: UUID) -> StoryID { StoryID(.board, "tile.header", key: id.uuidString) }
        package static func tileMenu(_ id: UUID) -> StoryID { StoryID(.board, "tile.menu", key: id.uuidString) }
        /// The density a tile draws at, and its state's cue, as marks keyed by the tile.
        package static func density(_ id: UUID, _ density: Density) -> StoryID { StoryID(.board, "tile.\(density.rawValue)", key: id.uuidString) }
        static func state(_ id: UUID, _ state: BoardTileState) -> StoryID { StoryID(.board, "tile.state.\(state)", key: id.uuidString) }
        package static func section(_ id: UUID) -> StoryID { StoryID(.board, "section", key: id.uuidString) }
        package static func sectionHeader(_ id: UUID) -> StoryID { StoryID(.board, "section.header", key: id.uuidString) }
        package static func sectionName(_ id: UUID) -> StoryID { StoryID(.board, "section.name", key: id.uuidString) }
        package static func sectionAdd(_ id: UUID) -> StoryID { StoryID(.board, "section.add", key: id.uuidString) }
        package static func sectionMenu(_ id: UUID) -> StoryID { StoryID(.board, "section.menu", key: id.uuidString) }
        /// A slot's (or an empty section's) New Claude / New Codex, and a strip chat in its list.
        package static func slotProvider(_ id: UUID, _ provider: String) -> StoryID { StoryID(.board, "slot.provider", key: "\(id.uuidString):\(provider)") }
        package static func slotChat(_ id: UUID, _ tab: UUID) -> StoryID { StoryID(.board, "slot.chat", key: "\(id.uuidString):\(tab.uuidString)") }
        /// A gutter by its split's place: "-" between sections, else the section's id; then the
        /// split's path and the child it follows.
        package static func gutter(_ id: GutterID) -> StoryID {
            StoryID(.board, "gutter", key: "\(id.section?.uuidString ?? "-"):\(id.path.map(String.init).joined(separator: ".")):\(id.index)")
        }
        package static func snap(_ label: String) -> StoryID { StoryID(.board, "snap", key: label) }
        /// A tile divider's grip: pulled, it opens room for a slot.
        package static func grip(_ id: GutterID) -> StoryID {
            StoryID(.board, "grip", key: "\(id.section?.uuidString ?? "-"):\(id.path.map(String.init).joined(separator: ".")):\(id.index)")
        }
        /// A slot tile's ＋ (the picker) and × (closes it).
        package static func slotAdd(_ id: UUID) -> StoryID { StoryID(.board, "slot.add", key: id.uuidString) }
        package static func slotClose(_ id: UUID) -> StoryID { StoryID(.board, "slot.close", key: id.uuidString) }
        /// The room a pulled grip shows; keyed "open" once letting go makes a slot.
        package static func room(_ opens: Bool) -> StoryID { StoryID(.board, "room", key: opens ? "open" : "closed") }
        package static let dropZone = StoryID(.board, "drop")
        /// The tile a drop lands on, outlined where it would be after.
        package static let dropTarget = StoryID(.board, "drop.target")
        /// The strip's ghost of a tile's chat a drop would send there.
        package static let ghostTab = StoryID(.board, "ghost.tab")
        package static let zoomed = StoryID(.board, "zoomed")
    }
}

/// The board's Kore popups: a section's ⋯ and ＋, and a tile's ⋯.
@MainActor
package enum BoardMenus {
    /// Storylines: the open popup's entries.
    package static var storyTitles: [String] { OptionsMenu.shared.items.map(\.title) }

    static func section(_ id: UUID, model: BoardModel, workspace: Workspace, tab: ChatTab) -> [OptionItem] {
        let others = model.board.sections.filter { $0.id != id }
        let current = model.board.section(id)?.swatch
        let swatches = [OptionItem("None", checked: current == nil) { model.edit { $0.setSwatch(id, nil) } }]
            + Swatch.allCases.map { swatch in
                OptionItem(swatch == .neutral ? "Neutral" : "Blue \(swatch.rawValue.dropFirst())", checked: current == swatch, tint: Theme.Board.swatch(swatch)) {
                    model.edit { $0.setSwatch(id, swatch) }
                }
            }
        return [
            OptionItem("Rename…") { model.renaming = id },
            OptionItem("Colour", children: swatches),
            .rule,
            OptionItem("Split Right") { split(id, .right, model: model) },
            OptionItem("Split Down") { split(id, .bottom, model: model) },
            OptionItem("Merge Into", enabled: !others.isEmpty, children: others.map { other in
                OptionItem(other.name) { model.edit { $0.mergeSection(id, into: other.id) } }
            }),
            .rule,
            OptionItem("Remove Section", destructive: true) { workspace.removeSection(id, from: tab) },
        ]
    }

    /// A new, empty section beside one, with its name field up.
    static func split(_ id: UUID, _ edge: DropEdge, model: BoardModel) {
        let section = BoardSection(name: "Section \(model.board.sections.count + 1)")
        model.edit { $0.addSection(edge, of: id, section) }
        model.renaming = section.id
    }

    /// A slot beside a tile, focused for its choice (⌘\ and ⌘⇧\, the tile's Split Right / Down).
    static func splitTile(_ tile: UUID, _ edge: DropEdge, model: BoardModel) {
        let slot = UUID()
        model.edit { $0.split(tile, edge, new: slot) }
        model.focus(slot)
    }

    /// ＋: a new chat, or one of this window's strip chats, into the section.
    static func attach(_ section: UUID, workspace: Workspace, tab: ChatTab) -> [OptionItem] {
        let chats = workspace.stripChats.map { other in
            OptionItem(other.title) { workspace.attach(other, to: tab, section: section, slot: nil) }
        }
        return chats + [.rule] + Provider.allCases.map { provider in
            OptionItem("New \(provider.name) Chat") { workspace.startChat(provider, on: tab, section: section, slot: nil) }
        }
    }

    /// A slot's ＋ (or Return on it): a new chat first, then this window's strip chats.
    static func slot(_ tile: UUID, workspace: Workspace, tab: ChatTab) -> [OptionItem] {
        let new = Provider.allCases.map { provider in
            OptionItem("New \(provider.name) Chat") { workspace.startChat(provider, on: tab, section: nil, slot: tile) }
        }
        let chats = workspace.stripChats.map { other in OptionItem(other.title) { workspace.attach(other, to: tab, slot: tile) } }
        return chats.isEmpty ? new : new + [.rule] + chats
    }

    static func tile(_ tile: UUID, workspace: Workspace, tab: ChatTab, model: BoardModel) -> [OptionItem] {
        let size = model.size
        let current = model.board.solve(in: size).tiles[tile].map { Density.of($0.size) }
        let here = model.board.section(of: tile)?.id
        let sections = model.board.sections.filter { $0.id != here }
        // Split first, with their keys (⌘\ and ⌘⇧\ do the same on the focused tile).
        let splits = [
            OptionItem("Split Right", glyph: "rectangle.split.2x1", key: "⌘\\") { splitTile(tile, .right, model: model) },
            OptionItem("Split Down", glyph: "rectangle.split.1x2", key: "⌘⇧\\") { splitTile(tile, .bottom, model: model) },
            .rule,
        ]
        return splits + Density.allCases.map { density in
            OptionItem(density.rawValue.capitalized, checked: current == density) { model.edit { $0.setDensity(tile, density, in: size) } }
        } + [
            .rule,
            OptionItem("Zoom", key: "⌘⇧↩") { model.zoomed = tile },
            OptionItem("Move To", enabled: !sections.isEmpty, children: sections.map { section in
                OptionItem(section.name) { model.edit { $0.move(tile, to: .into(section.id), in: size) } }
            }),
            OptionItem("Move to Its Own Tab", key: "⌥⌘T") { workspace.detach(tile, from: tab) },
            .rule,
            OptionItem("Remove from \(model.name)", destructive: true) { workspace.detach(tile, from: tab, select: false) },
        ]
    }
}

/// The board's keys, while it's the window's tab (dynamic-tab.html §5): focus and move tiles by
/// direction, move a boundary, step density, split, zoom, detach, and layout undo when the keys
/// aren't in a text field.
@MainActor
enum BoardKeys {
    static func handle(_ event: NSEvent, workspace: Workspace, tab: ChatTab, model: BoardModel) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typing = event.window?.firstResponder is NSTextView
        let arrows: [UInt16: DropEdge] = [123: .left, 124: .right, 125: .bottom, 126: .top]
        let size = model.size
        if event.keyCode == 53, flags.isEmpty, model.zoomed != nil {
            model.zoomed = nil
            return true
        }
        if let edge = arrows[event.keyCode] {
            let frames = model.board.solve(in: size)
            let focused = model.focused ?? model.board.tiles.first?.id
            guard let focused else { return false }
            switch flags {
            case [.option, .command]:
                if let next = model.board.neighbour(of: focused, toward: edge, in: frames) { model.focus(next) } else { model.focus(focused) }
                return true
            case [.option, .command, .shift]:
                if let next = model.board.neighbour(of: focused, toward: edge, in: frames) { model.edit { $0.swap(focused, next) } }
                return true
            case [.control, .command], [.control, .command, .shift]:
                moveBoundary(of: focused, edge, sections: flags.contains(.shift), model: model, frames: frames)
                return true
            default:
                return false
            }
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        let focused = model.focused
        switch (flags, event.keyCode, key) {
        case ([.control, .command], _, "=") where focused != nil, ([.control, .command], 24, _) where focused != nil:
            step(focused!, up: true, model: model)
        case ([.control, .command], _, "-") where focused != nil, ([.control, .command], 27, _) where focused != nil:
            step(focused!, up: false, model: model)
        case (.command, 42, _) where focused != nil, ([.command, .shift], 42, _) where focused != nil:
            BoardMenus.splitTile(focused!, flags.contains(.shift) ? .bottom : .right, model: model)
        case ([], 51, _) where !typing && focused.map(model.isSlot) == true:
            model.edit { $0.closeSlot(focused!) }
        case ([], 36, _) where !typing && focused.map(model.isSlot) == true:
            let items = BoardMenus.slot(focused!, workspace: workspace, tab: tab)
            if let window = workspace.window, let rect = model.board.solve(in: size).tiles[focused!], let content = window.contentView {
                let point = CGPoint(x: model.origin.x + rect.midX, y: content.bounds.height - model.origin.y - rect.midY)
                OptionsMenu.shared.show(items, at: point, in: window, source: "board-slot")
            }
        case ([.command, .shift], 36, _) where focused != nil:
            model.zoomed = model.zoomed == nil ? focused : nil
        case ([.option, .command], _, "t") where focused != nil:
            workspace.detach(focused!, from: tab)
        case (.command, _, "z") where !typing:
            workspace.returnToStrip(model.undo(), after: tab)
        case ([.command, .shift], _, "z") where !typing:
            workspace.returnToStrip(model.redo(), after: tab)
        default:
            return false
        }
        return true
    }

    /// ⌃⌘= and ⌃⌘−: chip ↔ card ↔ full, by resizing.
    private static func step(_ tile: UUID, up: Bool, model: BoardModel) {
        let size = model.size
        guard let rect = model.board.solve(in: size).tiles[tile] else { return }
        let order = Density.allCases
        let index = order.firstIndex(of: Density.of(rect.size)) ?? 1
        let next = order[min(max(index + (up ? 1 : -1), 0), order.count - 1)]
        guard next != Density.of(rect.size) else { return }
        model.edit { $0.setDensity(tile, next, in: size) }
    }

    /// ⌃⌘ arrows: the focused tile's boundary on that side to the next snap point, else
    /// `keyStep`; with ⇧, its section's.
    private static func moveBoundary(of tile: UUID, _ edge: DropEdge, sections: Bool, model: BoardModel, frames: BoardFrames) {
        guard let section = model.board.section(of: tile) else { return }
        let rect = (sections ? frames.sections[section.id] : frames.tiles[tile]) ?? .zero
        let candidates = frames.gutters.filter { gutter in
            guard gutter.id.section == (sections ? nil : section.id), gutter.axis == edge.axis else { return false }
            let spans = edge.axis == .row ? gutter.rect.minY <= rect.midY && gutter.rect.maxY >= rect.midY : gutter.rect.minX <= rect.midX && gutter.rect.maxX >= rect.midX
            switch edge {
            case .left: return spans && abs(gutter.rect.maxX - rect.minX) < Size.Board.gap + 1
            case .right: return spans && abs(gutter.rect.minX - rect.maxX) < Size.Board.gap + 1
            case .top: return spans && abs(gutter.rect.maxY - rect.minY) < Size.Board.gap + 1
            case .bottom: return spans && abs(gutter.rect.minY - rect.maxY) < Size.Board.gap + 1
            }
        }
        guard let gutter = candidates.first else { return }
        // Arrow right or down moves the boundary that way.
        let sign: CGFloat = edge == .right || edge == .bottom ? 1 : -1
        let lines = frames.gutters.filter { $0.axis == gutter.axis && $0.id != gutter.id }.map(\.position)
        let (lengths, _) = GutterDrag.lengths(gutter, delta: sign * Size.Board.keyStep, lines: lines)
        model.edit { $0.resize(gutter.id, lengths: lengths) }
    }
}

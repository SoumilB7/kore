import AppKit
import SwiftUI

/// A board tab: its sections and tiles at the frames `Board.solve` gives for the tab's size, in
/// one ZStack of explicit frames (a resize is one layout pass), with the gutters on top. Gutters
/// are always live, a tile moves by its header, and drop zones show only while something drags.
struct BoardView: View {
    static let space = "board"
    let workspace: Workspace
    let tab: ChatTab
    let model: BoardModel
    /// A gutter being dragged: the lengths it gives its split, and the tiles' frames from before
    /// (full tiles keep theirs until the release, then lay out once).
    @StateObject private var gutterDrag = Local<GutterDragState?>(nil)
    /// A grip being pulled apart: the room it opens, and the tiles' frames from before.
    @StateObject private var roomPull = Local<RoomPullState?>(nil)
    @StateObject private var tileDrag = Local<TileDragState?>(nil)
    @StateObject private var hovered = Local<UUID?>(nil)
    @StateObject private var keys = Held<Any?>(nil)

    var body: some View {
        // The tab's size from its proposal, never from the layout it gets (that would only grow).
        GeometryReader { proxy in
            content(in: proxy.size)
                .onChange(of: proxy.size, initial: true) { _, new in model.size = new }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { model.origin = $0 }
        .onAppear {
            let model = model
            model.frames = { [weak model] in model.map { $0.board.solve(in: $0.size) } ?? BoardFrames() }
            installKeys()
        }
        .onDisappear(perform: removeKeys)
        .storyID(StoryID.Board.board(tab.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.name)
    }

    private func content(in size: CGSize) -> some View {
        let board = shownBoard
        let frames = board.solve(in: size)
        let full = board.tiles.map(\.id).filter { frames.tiles[$0].map { Density.of($0.size) == .full } ?? false }
        let live = model.live(full, hovered: hovered.value)
        return ZStack(alignment: .topLeading) {
            Theme.Board.ground
            if let zoomed = model.zoomed, model.chats[zoomed] != nil {
                zoom(zoomed, size: size)
            } else if frames.content.height > size.height + 0.5 {
                ScrollView(.vertical) { layer(board, frames, live: live) }
            } else {
                layer(board, frames, live: live)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    /// The layout as it is, or as the gutter being dragged makes it.
    private var shownBoard: Board {
        guard let drag = gutterDrag.value else { return model.board }
        var board = model.board
        board.resize(drag.gutter.id, lengths: drag.lengths)
        return board
    }

    /// The tile a drag would land on: dimmed under the preview.
    private var dropTarget: UUID? { tileDrag.value?.preview?.target ?? model.incoming?.preview.target }

    private func layer(_ board: Board, _ frames: BoardFrames, live: Set<UUID>) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(board.sections) { section in
                if let rect = frames.sections[section.id] {
                    SectionView(workspace: workspace, tab: tab, model: model, section: section, drag: drag(section))
                        .place(rect)
                }
            }
            ForEach(board.tiles) { tile in
                if let laid = frames.tiles[tile.id] {
                    let rect = roomPull.value?.pull.moved(laid) ?? laid
                    let frozen = (gutterDrag.value?.frozen ?? roomPull.value?.frozen)?[tile.id]
                    TileView(
                        workspace: workspace, tab: tab, model: model, tile: tile.id, size: rect.size,
                        frozen: frozen.map { Density.of($0.size) == .full && Density.of(rect.size) == .full ? $0.size : nil } ?? nil,
                        live: live.contains(tile.id), drag: tileGesture(tile.id, frames: frames)
                    )
                    .opacity(tileDrag.value?.tile == tile.id ? Theme.Board.dragged : dropTarget == tile.id ? Theme.Board.structureDim : 1)
                    .onHover { inside in
                        if inside { hovered.value = tile.id } else if hovered.value == tile.id { hovered.value = nil }
                    }
                    .place(rect)
                }
            }
            ForEach(frames.gutters, id: \.id) { gutter in
                BoardGutterView(
                    gutter: gutter, hot: gutterDrag.value?.gutter.id == gutter.id || roomPull.value?.pull.gutter.id == gutter.id,
                    gesture: gutterGesture(gutter, frames: frames)
                ) {
                    model.edit { $0.resize(gutter.id, lengths: GutterDrag.even(gutter)) }
                }
            }
            if let drag = gutterDrag.value {
                SnapTicks(gutter: drag.gutter, lengths: drag.lengths, snap: drag.snap)
            }
            if let pull = roomPull.value?.pull {
                RoomView(pull: pull)
            }
            if let drag = tileDrag.value, let preview = drag.preview {
                DropPreviewView(preview: preview, incoming: model.chats[drag.tile], target: preview.target.flatMap { model.chats[$0] })
            } else if let incoming = model.incoming {
                DropPreviewView(preview: incoming.preview, incoming: incoming.chat, target: incoming.preview.target.flatMap { model.chats[$0] })
            }
        }
        .frame(width: frames.content.width, height: frames.content.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func zoom(_ tile: UUID, size: CGSize) -> some View {
        TileView(workspace: workspace, tab: tab, model: model, tile: tile, size: size, frozen: nil, live: true, drag: nil)
            .padding(Size.Board.gap)
            .storyMark(StoryID.Board.zoomed)
    }

    // MARK: Gutters

    /// A divider's drag: from its grip (a tile divider's middle) it pulls room apart, and a slot
    /// opens once there's a tile's least; from anywhere else on it, it resizes.
    private func gutterGesture(_ gutter: BoardGutter, frames: BoardFrames) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if roomPull.value != nil || (gutterDrag.value == nil && gutter.id.section != nil && gutter.grip.contains(value.startLocation)) {
                    let start = roomPull.value?.pull.gutter ?? gutter
                    let delta = start.axis == .row ? value.translation.width : value.translation.height
                    roomPull.value = RoomPullState(pull: RoomPull(start, delta: delta), frozen: roomPull.value?.frozen ?? frames.tiles)
                    return
                }
                let start = gutterDrag.value?.gutter ?? gutter
                let delta = start.axis == .row ? value.translation.width : value.translation.height
                let lines = frames.gutters.filter { $0.axis == start.axis && $0.id != start.id }.map(\.position)
                let free = NSEvent.modifierFlags.contains(.command)
                let (lengths, snap) = GutterDrag.lengths(start, delta: delta, lines: lines, free: free)
                gutterDrag.value = GutterDragState(gutter: start, lengths: lengths, snap: snap, frozen: gutterDrag.value?.frozen ?? frames.tiles)
            }
            .onEnded { _ in
                if let pull = roomPull.value?.pull {
                    roomPull.value = nil
                    guard pull.opens else { return }
                    let slot = UUID()
                    model.edit { $0.openSlot(pull.gutter.id, lengths: pull.lengths, slot: slot) }
                    model.focus(slot)
                    UILog.event("board-room", ["axis": pull.gutter.axis.rawValue])
                    return
                }
                guard let drag = gutterDrag.value else { return }
                gutterDrag.value = nil
                model.edit { $0.resize(drag.gutter.id, lengths: drag.lengths) }
                UILog.event("board-resize", ["snap": drag.snap.map { "\($0)" }])
            }
    }

    // MARK: Moving tiles

    /// A tile's header drags it: onto another tile's edge (a split), its middle (a swap), a
    /// section (into it), the tab's edge (a new section) or the strip (its own tab again).
    private func tileGesture(_ tile: UUID, frames: BoardFrames) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: Size.tabDragStart, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let point = value.location
                    if point.y < 0 {
                        tileDrag.value = TileDragState(tile: tile, drop: nil, strip: true, preview: nil)
                    } else if let (drop, zone) = frames.drop(at: point, moving: tile) {
                        // The would-be board is solved once per zone, not per pointer move.
                        guard tileDrag.value?.drop != drop || tileDrag.value?.strip == true else { return }
                        let preview = model.board.preview(drop, zone: zone, moving: tile, isSlot: model.isSlot, in: model.size)
                        tileDrag.value = TileDragState(tile: tile, drop: drop, strip: false, preview: preview)
                    } else {
                        tileDrag.value = TileDragState(tile: tile, drop: nil, strip: false, preview: nil)
                    }
                }
                .onEnded { _ in
                    guard let drag = tileDrag.value else { return }
                    tileDrag.value = nil
                    if drag.strip {
                        workspace.detach(tile, from: tab)
                    } else if let drop = drag.drop {
                        model.move(tile, to: drop)
                    }
                })
    }

    private func drag(_ section: BoardSection) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: Size.tabDragStart, coordinateSpace: .named(Self.space))
                .onEnded { value in
                    // A section's header dropped on another section merges it there.
                    let frames = model.board.solve(in: model.size)
                    guard let target = frames.sections.first(where: { $0.key != section.id && $0.value.contains(value.location) })?.key else { return }
                    model.edit { $0.mergeSection(section.id, into: target) }
                })
    }

    // MARK: Keys

    private func installKeys() {
        guard keys.value == nil else { return }
        let workspace = workspace, tab = tab, model = model
        keys.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = workspace.window, event.window === window, workspace.activeTab === tab, !workspace.hasOverlay,
                OptionsMenu.shared.items.isEmpty
            else { return event }
            return BoardKeys.handle(event, workspace: workspace, tab: tab, model: model) ? nil : event
        }
    }

    private func removeKeys() {
        if let monitor = keys.value { NSEvent.removeMonitor(monitor) }
        keys.value = nil
    }
}

extension View {
    /// At a rectangle of the board's space, by layout (not an offset), so its frame and hit area
    /// are where it's drawn. Last: what's before it is the rectangle's.
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

struct GutterDragState: Equatable {
    let gutter: BoardGutter
    var lengths: [CGFloat]
    var snap: GutterDrag.Snap?
    let frozen: [UUID: CGRect]
}

struct RoomPullState: Equatable {
    let pull: RoomPull
    let frozen: [UUID: CGRect]
}

struct TileDragState: Equatable {
    let tile: UUID
    var drop: BoardDrop?
    /// Over the strip: it goes back to its own tab.
    var strip: Bool
    var preview: DropPreview?
}

// MARK: - Drops

extension BoardFrames {
    /// Where something dropped at `point` lands, and the zone that lights: the tab's outer edge
    /// makes a new section there; a tile's outer ring splits it on its nearest side and its
    /// middle swaps; elsewhere in a section, into it. Nil over the tile being moved.
    package func drop(at point: CGPoint, moving: UUID?) -> (BoardDrop, CGRect)? {
        let edge = Size.Board.tabEdge
        if point.x < edge { return (.newSection(.left), CGRect(x: 0, y: 0, width: edge, height: content.height)) }
        if point.x > content.width - edge { return (.newSection(.right), CGRect(x: content.width - edge, y: 0, width: edge, height: content.height)) }
        if point.y > content.height - edge { return (.newSection(.bottom), CGRect(x: 0, y: content.height - edge, width: content.width, height: edge)) }
        if let (id, rect) = tiles.first(where: { $0.value.contains(point) }) {
            guard id != moving else { return nil }
            switch Self.side(of: point, in: rect) {
            case .left?: return (.beside(id, .left), CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height))
            case .right?: return (.beside(id, .right), CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
            case .top?: return (.beside(id, .top), CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2))
            case .bottom?: return (.beside(id, .bottom), CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
            case nil: return (.swap(id), rect)
            }
        }
        if let (id, rect) = sections.first(where: { $0.value.contains(point) }) { return (.into(id), rect) }
        return nil
    }

    /// A tile's side a point is nearest, or nil in its middle: the middle half each way (top and
    /// bottom bands never under `dropBand`), and the ring around it cut by its diagonals, so top
    /// and bottom are as easy to hit as left and right. A chip splits only sideways.
    package static func side(of point: CGPoint, in rect: CGRect) -> DropEdge? {
        let across = rect.width * Size.Board.dropEdge
        let down = max(rect.height * Size.Board.dropEdge, min(Size.Board.dropBand, rect.height / 2))
        let left = point.x - rect.minX, right = rect.maxX - point.x
        if Density.of(rect.size) == .chip { return left < across ? .left : right < across ? .right : nil }
        let top = point.y - rect.minY, bottom = rect.maxY - point.y
        if left >= across, right >= across, top >= down, bottom >= down { return nil }
        let sides: [(DropEdge, CGFloat)] = [(.left, left / across), (.right, right / across), (.top, top / down), (.bottom, bottom / down)]
        return sides.min { $0.1 < $1.1 }?.0
    }
}

extension Board {
    /// What a drop would make, without making it: one solve of the board as it would be. The
    /// incoming chat's place, and the target tile's place after (nil when it leaves: a strip tab
    /// on a tile's middle sends that tile's chat to the strip).
    package func preview(_ drop: BoardDrop, zone: CGRect, moving: UUID?, isSlot: (UUID) -> Bool, in size: CGSize) -> DropPreview {
        let now = solve(in: size)
        switch drop {
        case .swap(let target):
            let place = now.tiles[target] ?? zone
            if isSlot(target) { return DropPreview(drop: drop, incoming: place) }
            if let moving { return DropPreview(drop: drop, incoming: place, target: target, targetPlace: now.tiles[moving]) }
            return DropPreview(drop: drop, incoming: place, target: target, displaced: target)
        case .beside, .into, .newSection:
            var after = self
            let id = moving ?? UUID()
            if let moving { after.move(moving, to: drop, in: size) } else { after.put(id, section: nil, drop: drop, in: size) }
            let frames = after.solve(in: size)
            var target: UUID?
            if case .beside(let other, _) = drop { target = other }
            return DropPreview(drop: drop, incoming: frames.tiles[id] ?? zone, target: target, targetPlace: target.flatMap { frames.tiles[$0] })
        }
    }
}

/// A drop's ghost of the result, drawn over the board while something drags (option A of
/// board-tiling-add.html): nothing under it moves.
package struct DropPreview: Equatable, Sendable {
    package var drop: BoardDrop
    /// Where the dragged chat would be: filled and named.
    package var incoming: CGRect
    /// The tile it lands on (dimmed), and that tile's place after: outlined and named.
    package var target: UUID?
    package var targetPlace: CGRect?
    /// A tile whose chat would go to the strip: its ghost tab shows there.
    package var displaced: UUID?
}

/// The ghost of the result: the incoming chat's place filled with its mark and name, the
/// target's place after outlined with its name, the target's content dimmed.
private struct DropPreviewView: View {
    let preview: DropPreview
    let incoming: Chat?
    let target: Chat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let place = preview.targetPlace, let target {
                RoundedRectangle(cornerRadius: Radius.panel)
                    .strokeBorder(Theme.Board.dropLine, style: StrokeStyle(lineWidth: Stroke.emphasis, dash: Size.Board.slotDash))
                    .overlay { name(target, color: Theme.secondary) }
                    .storyMark(StoryID.Board.dropTarget)
                    .place(place)
            }
            RoundedRectangle(cornerRadius: Radius.panel)
                .fill(Theme.Board.dropFill)
                .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.Board.dropLine, lineWidth: Stroke.emphasis) }
                .overlay { if let incoming { name(incoming, color: Theme.text) } }
                .storyMark(StoryID.Board.dropZone)
                .place(preview.incoming)
        }
        .allowsHitTesting(false)
    }

    private func name(_ chat: Chat, color: Color) -> some View {
        HStack(spacing: Space.sm) {
            ProviderLogo(provider: chat.provider, size: Size.logoTab)
            Text(chat.title).font(TextStyle.bodyMedium).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, Space.md)
    }
}

// MARK: - Gutters

/// A boundary: the gap between tiles with 4pt into each tile's edge (16pt), or a section line
/// with 4pt either side. Under the pointer: the resize cursor, its hairline lit, and on a tile
/// divider a grip at its middle that opens room (its own cursor). Nothing grows or moves.
/// Double-click makes its two sides equal.
private struct BoardGutterView<G: Gesture>: View {
    let gutter: BoardGutter
    let hot: Bool
    let gesture: G
    let equalise: () -> Void
    @StateObject private var over = Local<Part?>(nil)

    enum Part { case line, grip }

    var body: some View {
        let grab = gutter.id.section == nil ? Size.Board.sectionGrab : Size.Board.grab
        let rect = gutter.axis == .row ? gutter.rect.insetBy(dx: -grab, dy: 0) : gutter.rect.insetBy(dx: 0, dy: -grab)
        let row = gutter.axis == .row
        let grip = Size.Board.grip
        let gripped = gutter.id.section != nil
        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle()
                .fill(hot || over.value != nil ? Theme.Board.gutterHot : .clear)
                .frame(width: row ? Stroke.hairline : nil, height: row ? nil : Stroke.hairline)
            if gripped {
                // Drawn only: the gutter's one drag tells the grip from the line by where it starts.
                RoundedRectangle(cornerRadius: grip.width / 2)
                    .fill(over.value == .grip || hot ? Theme.Board.gripHot : over.value == .line ? Theme.Board.grip : .clear)
                    .frame(width: row ? grip.width : grip.height, height: row ? grip.height : grip.width)
                    .frame(width: gutter.grip.width, height: gutter.grip.height)
                    .allowsHitTesting(false)
                    .storyMark(StoryID.Board.grip(gutter.id))
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let part: Part = gripped && gutter.grip.contains(CGPoint(x: rect.minX + point.x, y: rect.minY + point.y)) ? .grip : .line
                guard part != over.value else { return }
                if over.value != nil { NSCursor.pop() }
                (part == .grip ? BoardCursor.room(gutter.axis) : row ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                over.value = part
            case .ended:
                if over.value != nil { NSCursor.pop() }
                over.value = nil
            }
        }
        .gesture(gesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded(equalise))
        .allowsWindowActivationEvents(true)
        .accessibilityElement()
        .accessibilityLabel(row ? "Width" : "Height")
        .accessibilityValue("\(Int((gutter.lengths[gutter.id.index] / max(gutter.extent, 1) * 100).rounded())) percent")
        .storyID(StoryID.Board.gutter(gutter.id))
        .place(rect)
    }
}

/// The grip's cursor: arrows apart from a line, white with a dark edge as the system's are.
@MainActor
enum BoardCursor {
    static let row = make("arrow.left.and.line.vertical.and.arrow.right", fallback: .resizeLeftRight)
    static let column = make("arrow.up.and.line.horizontal.and.arrow.down", fallback: .resizeUpDown)

    static func room(_ axis: SplitAxis) -> NSCursor { axis == .row ? row : column }

    private static func make(_ name: String, fallback: NSCursor) -> NSCursor {
        func symbol(_ color: NSColor) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold).applying(.init(paletteColors: [color])))
        }
        guard let white = symbol(.white), let black = symbol(.black) else { return fallback }
        let edge: CGFloat = 1
        let size = NSSize(width: white.size.width + edge * 2, height: white.size.height + edge * 2)
        let image = NSImage(size: size, flipped: false) { _ in
            for dx in [-edge, 0, edge] {
                for dy in [-edge, 0, edge] where dx != 0 || dy != 0 {
                    black.draw(at: NSPoint(x: edge + dx, y: edge + dy), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            white.draw(at: NSPoint(x: edge, y: edge), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }
}

/// The room a pulled grip opens: a dashed outline, accent once letting go makes it a slot, and
/// the drag label reading Room.
private struct RoomView: View {
    let pull: RoomPull

    var body: some View {
        let rect = pull.rect
        ZStack {
            if rect.width > 0, rect.height > 0 {
                RoundedRectangle(cornerRadius: Radius.panel)
                    .strokeBorder(pull.opens ? Theme.Board.roomLine : Theme.Board.slotLine, style: StrokeStyle(lineWidth: Stroke.hairline, dash: Size.Board.slotDash))
                    .place(rect)
            }
            DragLabel(text: "Room", at: CGPoint(x: rect.midX, y: rect.midY))
        }
        .allowsHitTesting(false)
        .storyMark(StoryID.Board.room(pull.opens))
    }
}

/// While a gutter drags: the snap point it pulled to, as a small label by it.
private struct SnapTicks: View {
    let gutter: BoardGutter
    let lengths: [CGFloat]
    let snap: GutterDrag.Snap?

    var body: some View {
        let i = gutter.id.index
        let at = gutter.start + lengths[...i].reduce(0, +) + gutter.gap * CGFloat(i) + gutter.gap / 2
        if let label = label {
            DragLabel(text: label, at: gutter.axis == .row ? CGPoint(x: at, y: gutter.rect.maxY - Space.xxxl) : CGPoint(x: gutter.rect.maxX - Space.xxxl * 2, y: at))
                .storyMark(StoryID.Board.snap(label))
        }
    }

    /// On a tile divider, what the chat it shrinks turns into (Full, Card, Chip), with the share
    /// it pulled to; between sections, the snap alone.
    private var label: String? {
        let share: String? = if case .share(let name) = snap { name } else { nil }
        guard gutter.id.section != nil else {
            if case .density(let density) = snap { return density.rawValue.capitalized }
            return share
        }
        let i = gutter.id.index
        let side = lengths[i] < gutter.lengths[i] ? i : i + 1
        let cross = gutter.axis == .row ? gutter.rect.height : gutter.rect.width
        let size = gutter.axis == .row ? CGSize(width: lengths[side], height: cross) : CGSize(width: cross, height: lengths[side])
        let density = Density.of(size).rawValue.capitalized
        return share.map { "\(density) · \($0)" } ?? density
    }
}

/// A drag's small accent label on the board's ground.
private struct DragLabel: View {
    let text: String
    let at: CGPoint

    var body: some View {
        Text(text)
            .font(Chrome.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.xs)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .fixedSize()
            .position(at)
            .allowsHitTesting(false)
    }
}



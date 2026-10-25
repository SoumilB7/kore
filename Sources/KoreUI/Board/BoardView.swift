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

    private func layer(_ board: Board, _ frames: BoardFrames, live: Set<UUID>) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(board.sections) { section in
                if let rect = frames.sections[section.id] {
                    SectionView(workspace: workspace, tab: tab, model: model, section: section, drag: drag(section))
                        .place(rect)
                }
            }
            ForEach(board.tiles) { tile in
                if let rect = frames.tiles[tile.id] {
                    let frozen = gutterDrag.value?.frozen[tile.id]
                    TileView(
                        workspace: workspace, tab: tab, model: model, tile: tile.id, size: rect.size,
                        frozen: frozen.map { Density.of($0.size) == .full && Density.of(rect.size) == .full ? $0.size : nil } ?? nil,
                        live: live.contains(tile.id), drag: tileGesture(tile.id, frames: frames)
                    )
                    .opacity(tileDrag.value?.tile == tile.id ? Theme.Board.dragged : 1)
                    .onHover { inside in
                        if inside { hovered.value = tile.id } else if hovered.value == tile.id { hovered.value = nil }
                    }
                    .place(rect)
                }
            }
            ForEach(frames.gutters, id: \.id) { gutter in
                BoardGutterView(gutter: gutter, hot: gutterDrag.value?.gutter.id == gutter.id, gesture: gutterGesture(gutter, frames: frames))
            }
            if let drag = gutterDrag.value {
                SnapTicks(gutter: drag.gutter, lengths: drag.lengths, snap: drag.snap)
            }
            if let zone = tileDrag.value?.zone ?? model.incoming?.zone {
                DropZone(rect: zone)
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

    private func gutterGesture(_ gutter: BoardGutter, frames: BoardFrames) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = gutterDrag.value?.gutter ?? gutter
                let delta = start.axis == .row ? value.translation.width : value.translation.height
                let lines = frames.gutters.filter { $0.axis == start.axis && $0.id != start.id }.map(\.position)
                let free = NSEvent.modifierFlags.contains(.command)
                let (lengths, snap) = GutterDrag.lengths(start, delta: delta, lines: lines, free: free)
                gutterDrag.value = GutterDragState(gutter: start, lengths: lengths, snap: snap, frozen: gutterDrag.value?.frozen ?? frames.tiles)
            }
            .onEnded { _ in
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
                        tileDrag.value = TileDragState(tile: tile, drop: nil, strip: true, zone: nil)
                    } else if let (drop, zone) = frames.drop(at: point, moving: tile) {
                        tileDrag.value = TileDragState(tile: tile, drop: drop, strip: false, zone: zone)
                    } else {
                        tileDrag.value = TileDragState(tile: tile, drop: nil, strip: false, zone: nil)
                    }
                }
                .onEnded { _ in
                    guard let drag = tileDrag.value else { return }
                    tileDrag.value = nil
                    if drag.strip {
                        workspace.detach(tile, from: tab)
                    } else if let drop = drag.drop {
                        let size = model.size
                        model.edit { $0.move(tile, to: drop, in: size) }
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

struct TileDragState: Equatable {
    let tile: UUID
    var drop: BoardDrop?
    /// Over the strip: it goes back to its own tab.
    var strip: Bool
    var zone: CGRect?
}

// MARK: - Drops

extension BoardFrames {
    /// Where something dropped at `point` lands, and the zone that lights: the tab's outer edge
    /// makes a new section there; a tile's outer quarter splits it on that side and its middle
    /// swaps; elsewhere in a section, into it. Nil over the tile being moved.
    package func drop(at point: CGPoint, moving: UUID?) -> (BoardDrop, CGRect)? {
        let edge = Size.Board.tabEdge
        if point.x < edge { return (.newSection(.left), CGRect(x: 0, y: 0, width: edge, height: content.height)) }
        if point.x > content.width - edge { return (.newSection(.right), CGRect(x: content.width - edge, y: 0, width: edge, height: content.height)) }
        if point.y > content.height - edge { return (.newSection(.bottom), CGRect(x: 0, y: content.height - edge, width: content.width, height: edge)) }
        if let (id, rect) = tiles.first(where: { $0.value.contains(point) }) {
            guard id != moving else { return nil }
            let x = (point.x - rect.minX) / max(rect.width, 1)
            let y = (point.y - rect.minY) / max(rect.height, 1)
            let quarter = Size.Board.dropEdge
            if x < quarter { return (.beside(id, .left), CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)) }
            if x > 1 - quarter { return (.beside(id, .right), CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)) }
            if y < quarter { return (.beside(id, .top), CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)) }
            if y > 1 - quarter { return (.beside(id, .bottom), CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)) }
            return (.swap(id), rect)
        }
        if let (id, rect) = sections.first(where: { $0.value.contains(point) }) { return (.into(id), rect) }
        return nil
    }
}

/// A drop zone: the accent at 14% with its line, as the composer's file drop zone.
private struct DropZone: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.panel)
            .fill(Theme.Board.dropFill)
            .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.Board.dropLine, lineWidth: Stroke.emphasis) }
            .allowsHitTesting(false)
            .storyMark(StoryID.Board.dropZone)
            .place(rect)
    }
}

// MARK: - Gutters

/// A boundary: the gap between tiles, or a section line with 4pt of grab either side. The
/// pointer over it shows the resize cursor and lights it; nothing grows.
private struct BoardGutterView<G: Gesture>: View {
    let gutter: BoardGutter
    let hot: Bool
    let gesture: G
    @StateObject private var hovered = Local(false)

    var body: some View {
        let grab = gutter.id.section == nil ? Size.Board.sectionGrab : 0
        let rect = gutter.axis == .row ? gutter.rect.insetBy(dx: -grab, dy: 0) : gutter.rect.insetBy(dx: 0, dy: -grab)
        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle()
                .fill(hot || hovered.value ? Theme.Board.gutterHot : .clear)
                .frame(width: gutter.axis == .row ? Stroke.hairline : nil, height: gutter.axis == .column ? Stroke.hairline : nil)
        }
        .onHover { inside in
            hovered.value = inside
            let cursor: NSCursor = gutter.axis == .row ? .resizeLeftRight : .resizeUpDown
            if inside { cursor.push() } else { NSCursor.pop() }
        }
        .gesture(gesture)
        .allowsWindowActivationEvents(true)
        .accessibilityElement()
        .accessibilityLabel(gutter.axis == .row ? "Width" : "Height")
        .accessibilityValue("\(Int((gutter.lengths[gutter.id.index] / max(gutter.extent, 1) * 100).rounded())) percent")
        .storyID(StoryID.Board.gutter(gutter.id))
        .place(rect)
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
            Text(label)
                .font(Chrome.caption)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Space.xs)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
                .fixedSize()
                .position(gutter.axis == .row ? CGPoint(x: at, y: gutter.rect.maxY - Space.xxxl) : CGPoint(x: gutter.rect.maxX - Space.xxxl * 2, y: at))
                .allowsHitTesting(false)
                .storyMark(StoryID.Board.snap(label))
        }
    }

    private var label: String? {
        switch snap {
        case .share(let name): name
        case .density(let density): density.rawValue.capitalized
        case .line, nil: nil
        }
    }
}



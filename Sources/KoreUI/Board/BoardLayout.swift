import CoreGraphics
import Foundation

// The board's layout (dynamic-tab.html, direction A: strict tiling): pure values, Codable, no
// views. Sections tile the tab and each section's chats tile its body, both as split trees whose
// sizes are shares of their parent, so the same tree fits any window. Every edit is a pure
// function of the board, so undo is a stack of boards.

/// Which way a split lays its children: side by side, or one under the next.
package enum SplitAxis: String, Codable, Sendable {
    case row, column

    var other: SplitAxis { self == .row ? .column : .row }
}

/// A child's part of its split: a fraction of what the pinned children leave, or a fixed length
/// (a chip's 30, which it keeps at any window size).
package enum Share: Codable, Equatable, Sendable {
    case fraction(CGFloat)
    case pinned(CGFloat)

    var fraction: CGFloat? {
        if case .fraction(let f) = self { return f }
        return nil
    }

    var isPinned: Bool { fraction == nil }
}

/// A split tree: a leaf, or two or more children along an axis, each with its share.
package indirect enum Split<Leaf: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case leaf(Leaf)
    case split(SplitAxis, [Child])

    package struct Child: Codable, Equatable, Sendable {
        package var share: Share
        package var node: Split

        package init(_ share: Share, _ node: Split) {
            self.share = share
            self.node = node
        }
    }
}

/// One chat's place in a section. Which chat is the board model's to say: a tile with none is a
/// slot, showing the attach picker.
package struct BoardTile: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID

    package init(id: UUID = UUID()) { self.id = id }
}

/// A section's colour: the shades of Kore's one blue, or a neutral grey.
package enum Swatch: String, Codable, CaseIterable, Sendable {
    case b200, b300, b400, b600, neutral
}

/// A named region of the board; its body is its tiles' split tree, nil while it has none.
package struct BoardSection: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package var name: String
    package var swatch: Swatch?
    package var body: Split<BoardTile>?

    package init(id: UUID = UUID(), name: String, swatch: Swatch? = nil, body: Split<BoardTile>? = nil) {
        self.id = id
        self.name = name
        self.swatch = swatch
        self.body = body
    }

    package var tiles: [BoardTile] { body?.leaves ?? [] }
}

/// A board: its name and its sections' tree.
package struct Board: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package var name: String
    package var root: Split<BoardSection>

    package init(id: UUID = UUID(), name: String = "Board", root: Split<BoardSection>? = nil) {
        self.id = id
        self.name = name
        self.root = root ?? .leaf(BoardSection(name: "Section 1"))
    }
}

/// How much of a chat a tile shows, from its size alone.
package enum Density: String, Sendable, CaseIterable {
    case chip, card, full

    /// Under `chipBelow` tall a chip; at least `full` wide and tall the full chat; else a card.
    package static func of(_ size: CGSize) -> Density {
        if size.height < Size.Board.chipBelow { return .chip }
        if size.width >= Size.Board.full.width, size.height >= Size.Board.full.height { return .full }
        return .card
    }
}

/// A side of a tile or section, where a drop puts the new one.
package enum DropEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    var axis: SplitAxis { self == .left || self == .right ? .row : .column }
    /// The new one goes after the old one along the axis.
    var after: Bool { self == .right || self == .bottom }
}

/// Where a moved tile lands.
package enum BoardDrop: Equatable, Sendable {
    /// Beside a tile, splitting it.
    case beside(UUID, DropEdge)
    /// In a tile's place, which takes the moved one's.
    case swap(UUID)
    /// Into a section, placed as a new chat is.
    case into(UUID)
    /// A new section at the tab's edge, holding it.
    case newSection(DropEdge)
}

// MARK: - Trees

extension Split {
    package var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .split(_, let children): children.flatMap(\.node.leaves)
        }
    }

    func node(at path: [Int]) -> Split? {
        guard let first = path.first else { return self }
        guard case .split(_, let children) = self, children.indices.contains(first) else { return nil }
        return children[first].node.node(at: Array(path.dropFirst()))
    }

    /// The path to the first leaf that matches.
    func path(where match: (Leaf) -> Bool) -> [Int]? {
        switch self {
        case .leaf(let leaf): return match(leaf) ? [] : nil
        case .split(_, let children):
            for (index, child) in children.enumerated() {
                if let rest = child.node.path(where: match) { return [index] + rest }
            }
            return nil
        }
    }

    func mapLeaves(_ transform: (Leaf) -> Leaf) -> Split {
        switch self {
        case .leaf(let leaf): .leaf(transform(leaf))
        case .split(let axis, let children): .split(axis, children.map { Child($0.share, $0.node.mapLeaves(transform)) })
        }
    }

    func replacing(at path: [Int], with node: Split) -> Split {
        guard let first = path.first else { return node }
        guard case .split(let axis, var children) = self, children.indices.contains(first) else { return self }
        children[first].node = children[first].node.replacing(at: Array(path.dropFirst()), with: node)
        return .split(axis, children)
    }

    /// No split inside runs top to bottom: the node can be a chip's height (a row of chips).
    var isFlat: Bool {
        switch self {
        case .leaf: true
        case .split(let axis, let children): axis == .row && children.allSatisfy(\.node.isFlat)
        }
    }

    /// The node at `path` taken out. Its share goes to the neighbour before it (after, for the
    /// first), and a split left with one child is that child. Nil when the root itself goes.
    func removing(at path: [Int]) -> Split? {
        guard let first = path.first else { return nil }
        guard case .split(let axis, var children) = self, children.indices.contains(first) else { return self }
        if path.count > 1 {
            if let rest = children[first].node.removing(at: Array(path.dropFirst())) {
                children[first].node = rest
                return Split.split(axis, children).normalized()
            }
            return removing(at: [first])
        }
        let removed = children.remove(at: first)
        let neighbour = max(first - 1, 0)
        if let f = removed.share.fraction, let g = children[neighbour].share.fraction {
            children[neighbour].share = .fraction(g + f)
        }
        if children.count == 1 { return children[0].node }
        return Split.split(axis, children).normalized()
    }

    /// `new` beside the node at `path` along `axis`, before or after it. In a split of that axis
    /// already, it's a sibling taking half the old one's share; else the old one becomes a split
    /// of the two, halves each.
    func inserting(_ new: Split, beside path: [Int], axis: SplitAxis, after: Bool) -> Split {
        if let index = path.last, case .split(let parentAxis, var children)? = node(at: Array(path.dropLast())), parentAxis == axis {
            let share: Share
            if let f = children[index].share.fraction {
                children[index].share = .fraction(f / 2)
                share = .fraction(f / 2)
            } else {
                let fractions = children.compactMap(\.share.fraction)
                share = .fraction(fractions.isEmpty ? 1 : fractions.reduce(0, +) / CGFloat(fractions.count))
            }
            children.insert(Child(share, new), at: after ? index + 1 : index)
            return replacing(at: Array(path.dropLast()), with: Split.split(axis, children).normalized())
        }
        guard let old = node(at: path) else { return self }
        let pair = after ? [Child(.fraction(0.5), old), Child(.fraction(0.5), new)] : [Child(.fraction(0.5), new), Child(.fraction(0.5), old)]
        var result = replacing(at: path, with: .split(axis, pair))
        // A pinned chip split down isn't a chip any more.
        if axis == .column, let index = path.last, case .split(let parentAxis, var children)? = result.node(at: Array(path.dropLast())),
            children[index].share.isPinned
        {
            children[index].share = .fraction(Self.averageFraction(children))
            result = result.replacing(at: Array(path.dropLast()), with: .split(parentAxis, children))
        }
        return result.normalized()
    }

    private static func averageFraction(_ children: [Child]) -> CGFloat {
        let fractions = children.compactMap(\.share.fraction)
        return fractions.isEmpty ? 1 : fractions.reduce(0, +) / CGFloat(fractions.count)
    }

    /// Splits within a split of the same axis join it, fractions sum to 1, a pin stays only on a
    /// flat child of a column, and a split of one child is that child.
    func normalized() -> Split {
        guard case .split(let axis, let children) = self else { return self }
        var flat: [Child] = []
        for child in children {
            let node = child.node.normalized()
            if case .split(let inner, let grandchildren) = node, inner == axis, let f = child.share.fraction {
                let sum = grandchildren.compactMap(\.share.fraction).reduce(0, +)
                for grandchild in grandchildren {
                    let share = grandchild.share.fraction.map { Share.fraction(sum > 0 ? f * $0 / sum : f) } ?? grandchild.share
                    flat.append(Child(share, grandchild.node))
                }
            } else {
                flat.append(Child(child.share, node))
            }
        }
        if flat.count == 1 { return flat[0].node }
        let average = Self.averageFraction(flat)
        for index in flat.indices where flat[index].share.isPinned && (axis != .column || !flat[index].node.isFlat) {
            flat[index].share = .fraction(average)
        }
        let sum = flat.compactMap(\.share.fraction).reduce(0, +)
        if sum > 0 {
            for index in flat.indices {
                if let f = flat[index].share.fraction { flat[index].share = .fraction(f / sum) }
            }
        }
        return .split(axis, flat)
    }
}

// MARK: - Solving

/// Where a gutter is: between sections (`section` nil) or a section's tiles, the split's path
/// from its tree's root, and the child it follows.
package struct GutterID: Hashable, Codable, Sendable {
    package var section: UUID?
    package var path: [Int]
    package var index: Int
}

/// A gutter as solved: its split's axis, its gap's rectangle, and the split's children along
/// the axis (where they start, how long each is, and the least each can be).
package struct BoardGutter: Equatable, Sendable {
    package let id: GutterID
    package let axis: SplitAxis
    package let rect: CGRect
    package let start: CGFloat
    package let lengths: [CGFloat]
    package let mins: [CGFloat]
    /// Each child can be pinned to a chip's height.
    package let pinnable: [Bool]
    package let gap: CGFloat

    /// Its middle along the axis.
    package var position: CGFloat { axis == .row ? rect.midX : rect.midY }
    package var extent: CGFloat { lengths.reduce(0, +) + gap * CGFloat(lengths.count - 1) }
}

/// Every rectangle of a board in a tab of some size. `content` is taller than the tab only
/// when a split had to stack.
package struct BoardFrames: Equatable, Sendable {
    package var content: CGSize = .zero
    package var sections: [UUID: CGRect] = [:]
    package var bodies: [UUID: CGRect] = [:]
    package var tiles: [UUID: CGRect] = [:]
    package var gutters: [BoardGutter] = []
    /// Splits that stacked to fit (their stored axis was a row).
    package var stacked = 0

    package func gutter(_ id: GutterID) -> BoardGutter? { gutters.first { $0.id == id } }
}

/// A split tree's minimums and layout, given its leaves' minimums.
private struct Solver<Leaf: Codable & Equatable & Sendable> {
    let gap: CGFloat
    let leafWidth: (Leaf) -> CGFloat
    let leafHeight: (Leaf, CGFloat) -> CGFloat
    let place: (Leaf, CGRect) -> Void
    let gutter: (_ path: [Int], _ index: Int, _ axis: SplitAxis, _ rect: CGRect, _ start: CGFloat, _ lengths: [CGFloat], _ mins: [CGFloat], _ pinnable: [Bool]) -> Void
    let stacked: () -> Void

    /// A row can always stack, so its least width is its widest child's.
    func minWidth(_ node: Split<Leaf>) -> CGFloat {
        switch node {
        case .leaf(let leaf): leafWidth(leaf)
        case .split(_, let children): children.map { minWidth($0.node) }.max() ?? 0
        }
    }

    func stacks(_ children: [Split<Leaf>.Child], width: CGFloat) -> Bool {
        children.map { minWidth($0.node) }.reduce(0, +) + gaps(children.count) > width + 0.5
    }

    func minHeight(_ node: Split<Leaf>, width: CGFloat) -> CGFloat {
        switch node {
        case .leaf(let leaf):
            return leafHeight(leaf, width)
        case .split(let axis, let children):
            if axis == .row, !stacks(children, width: width) {
                let widths = Self.allocate(children.map(\.share), total: width - gaps(children.count), mins: children.map { minWidth($0.node) })
                return zip(children, widths).map { minHeight($0.node, width: $1) }.max() ?? 0
            }
            return children.map { child in
                let least = minHeight(child.node, width: width)
                if case .pinned(let p) = child.share, axis == .column { return max(p, least) }
                return least
            }.reduce(0, +) + gaps(children.count)
        }
    }

    private func gaps(_ count: Int) -> CGFloat { gap * CGFloat(max(count - 1, 0)) }

    /// Lengths for shares in `total`: pinned ones their length, fractions what's left in
    /// proportion, none under its minimum (taken from the others in proportion). With no
    /// fraction, the last child takes the slack. The sum is over `total` only when the minimums
    /// are.
    static func allocate(_ shares: [Share], total: CGFloat, mins: [CGFloat]) -> [CGFloat] {
        var sizes = mins
        var fixed = Array(repeating: false, count: shares.count)
        for (index, share) in shares.enumerated() {
            if case .pinned(let p) = share {
                sizes[index] = max(p, mins[index])
                fixed[index] = true
            }
        }
        guard !fixed.allSatisfy({ $0 }) else {
            if let last = sizes.indices.last { sizes[last] += max(0, total - sizes.reduce(0, +)) }
            return sizes
        }
        while true {
            let free = total - zip(sizes, fixed).filter(\.1).map(\.0).reduce(0, +)
            let open = shares.indices.filter { !fixed[$0] }
            if open.isEmpty { break }
            let weight = open.map { max(shares[$0].fraction ?? 0, 0.0001) }.reduce(0, +)
            var changed = false
            for index in open {
                let size = free * max(shares[index].fraction ?? 0, 0.0001) / weight
                if size < mins[index] - 0.001 {
                    sizes[index] = mins[index]
                    fixed[index] = true
                    changed = true
                } else {
                    sizes[index] = size
                }
            }
            if !changed { break }
        }
        return sizes
    }

    /// Lays the node out in `rect`, and gives the height it took: more than `rect`'s only when its
    /// minimums are.
    @discardableResult
    func layout(_ node: Split<Leaf>, in rect: CGRect, path: [Int] = []) -> CGFloat {
        switch node {
        case .leaf(let leaf):
            let height = max(rect.height, leafHeight(leaf, rect.width))
            place(leaf, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height))
            return height
        case .split(let axis, let children):
            let pinnable = children.map { axis == .column && $0.node.isFlat }
            if axis == .row, !stacks(children, width: rect.width) {
                let mins = children.map { minWidth($0.node) }
                let widths = Self.allocate(children.map(\.share), total: rect.width - gaps(children.count), mins: mins)
                let height = max(rect.height, zip(children, widths).map { minHeight($0.node, width: $1) }.max() ?? 0)
                var x = rect.minX
                for (index, child) in children.enumerated() {
                    layout(child.node, in: CGRect(x: x, y: rect.minY, width: widths[index], height: height), path: path + [index])
                    x += widths[index]
                    if index < children.count - 1 {
                        gutter(path, index, .row, CGRect(x: x, y: rect.minY, width: gap, height: height), rect.minX, widths, mins, pinnable)
                        x += gap
                    }
                }
                return height
            }
            let isStacked = axis == .row
            if isStacked { stacked() }
            let mins = children.map { child -> CGFloat in
                let least = minHeight(child.node, width: rect.width)
                if !isStacked, case .pinned(let p) = child.share { return max(p, least) }
                return least
            }
            // A stacked row's pins were heights of nothing: its children share by fraction.
            let shares = isStacked ? children.map { Share.fraction($0.share.fraction ?? 1) } : children.map(\.share)
            let heights = Self.allocate(shares, total: rect.height - gaps(children.count), mins: mins)
            var y = rect.minY
            for (index, child) in children.enumerated() {
                y += layout(child.node, in: CGRect(x: rect.minX, y: y, width: rect.width, height: heights[index]), path: path + [index])
                if index < children.count - 1 {
                    if !isStacked {
                        gutter(path, index, .column, CGRect(x: rect.minX, y: y, width: rect.width, height: gap), rect.minY, heights, mins, pinnable)
                    }
                    y += gap
                }
            }
            return max(rect.height, y - rect.minY)
        }
    }
}

extension Board {
    package var sections: [BoardSection] { root.leaves }
    package var tiles: [BoardTile] { sections.flatMap(\.tiles) }

    package func section(_ id: UUID) -> BoardSection? { sections.first { $0.id == id } }
    package func section(of tile: UUID) -> BoardSection? { sections.first { $0.tiles.contains { $0.id == tile } } }

    private static let tileMetrics = (width: Size.Board.tileMin.width, height: Size.Board.tileMin.height)

    /// The frames of every section, body, tile and gutter in a tab `size` big: minimums kept,
    /// splits that can't fit stacked (the tab then scrolls), 8pt between tiles and 1pt between
    /// sections. Arithmetic over the tree.
    package func solve(in size: CGSize) -> BoardFrames {
        final class Recorder { var frames = BoardFrames() }
        let recorder = Recorder()
        let gap = Size.Board.gap
        func tileSolver(_ section: UUID) -> Solver<BoardTile> {
            Solver<BoardTile>(
                gap: gap, leafWidth: { _ in Self.tileMetrics.width }, leafHeight: { _, _ in Self.tileMetrics.height },
                place: { tile, rect in recorder.frames.tiles[tile.id] = rect },
                gutter: { path, index, axis, rect, start, lengths, mins, pinnable in
                    recorder.frames.gutters.append(
                        BoardGutter(id: GutterID(section: section, path: path, index: index), axis: axis, rect: rect, start: start, lengths: lengths, mins: mins, pinnable: pinnable, gap: gap))
                },
                stacked: { recorder.frames.stacked += 1 })
        }
        func bodyWidth(_ width: CGFloat) -> CGFloat { width - 2 * gap }
        let sectionSolver = Solver<BoardSection>(
            gap: Size.Board.sectionGap,
            leafWidth: { section in
                max(Size.Board.sectionMinWidth, (section.body.map { tileSolver(section.id).minWidth($0) } ?? Self.tileMetrics.width) + 2 * gap)
            },
            leafHeight: { section, width in
                let body = section.body.map { tileSolver(section.id).minHeight($0, width: bodyWidth(width)) } ?? Self.tileMetrics.height
                return Size.Board.header + body + gap
            },
            place: { section, rect in
                recorder.frames.sections[section.id] = rect
                let body = CGRect(x: rect.minX + gap, y: rect.minY + Size.Board.header, width: bodyWidth(rect.width), height: rect.height - Size.Board.header - gap)
                recorder.frames.bodies[section.id] = body
                if let tree = section.body { tileSolver(section.id).layout(tree, in: body) }
            },
            gutter: { path, index, axis, rect, start, lengths, mins, _ in
                recorder.frames.gutters.append(
                    BoardGutter(
                        id: GutterID(section: nil, path: path, index: index), axis: axis, rect: rect, start: start, lengths: lengths, mins: mins,
                        pinnable: lengths.map { _ in false }, gap: Size.Board.sectionGap))
            },
            stacked: { recorder.frames.stacked += 1 })
        let height = sectionSolver.layout(root, in: CGRect(origin: .zero, size: size))
        recorder.frames.content = CGSize(width: size.width, height: max(size.height, height))
        return recorder.frames
    }
}

// MARK: - Gutters

/// A gutter's drag: the lengths its split's children take with it moved.
package enum GutterDrag {
    /// What a snapped gutter lines up with, for its label.
    package enum Snap: Equatable, Sendable {
        case share(String)
        case density(Density)
        case line
    }

    /// The split's lengths with the gutter moved `delta` along its axis: its neighbours pushed to
    /// their minimums and no further; unless `free` (⌘ held), pulled within `snapPull` to a
    /// density step of either side, to ½, ⅓ or ⅔ of the split, or to `lines` (other gutters'
    /// middles on the same axis); and a pinnable side under `chipBelow` snapped to a chip.
    package static func lengths(_ gutter: BoardGutter, delta: CGFloat, lines: [CGFloat] = [], free: Bool = false) -> (lengths: [CGFloat], snap: Snap?) {
        let i = gutter.id.index
        var lengths = gutter.lengths
        let pair = lengths[i] + lengths[i + 1]
        let low = gutter.mins[i]
        let high = pair - gutter.mins[i + 1]
        guard high >= low else { return (lengths, nil) }
        let before = gutter.start + lengths[..<i].reduce(0, +) + gutter.gap * CGFloat(i)
        var a = min(max(lengths[i] + delta, low), high)
        var snap: Snap?
        if !free {
            // Candidates as the length of the side before the gutter.
            var candidates: [(CGFloat, Snap)] = []
            for (name, share) in [("½", 0.5), ("⅓", 1.0 / 3), ("⅔", 2.0 / 3)] {
                candidates.append((gutter.start + gutter.extent * share - gutter.gap / 2 - before, .share(name)))
            }
            if gutter.axis == .column {
                for (step, density) in [(Size.Board.card, Density.card), (Size.Board.full.height, Density.full)] {
                    candidates.append((step, .density(density)))
                    candidates.append((pair - step, .density(density)))
                }
            } else {
                candidates.append((Size.Board.full.width, .density(.full)))
                candidates.append((pair - Size.Board.full.width, .density(.full)))
            }
            for line in lines where abs(line - gutter.position) > 0.5 {
                candidates.append((line - gutter.gap / 2 - before, .line))
            }
            if let best = candidates.filter({ $0.0 >= low && $0.0 <= high }).min(by: { abs($0.0 - a) < abs($1.0 - a) }),
                abs(best.0 - a) <= Size.Board.snapPull
            {
                a = best.0
                snap = best.1
            }
        }
        // The chip detent: under its threshold, a pinnable side is a chip.
        if gutter.axis == .column {
            if gutter.pinnable[i], a < Size.Board.chipBelow, Size.Board.chip >= low {
                a = Size.Board.chip
                snap = .density(.chip)
            } else if gutter.pinnable[i + 1], pair - a < Size.Board.chipBelow, pair - Size.Board.chip <= high {
                a = pair - Size.Board.chip
                snap = .density(.chip)
            }
        }
        lengths[i] = a
        lengths[i + 1] = pair - a
        return (lengths, snap)
    }
}

// MARK: - Edits

extension Board {
    private mutating func updateSection(_ id: UUID, _ change: (inout BoardSection) -> Void) {
        root = root.mapLeaves { section in
            guard section.id == id else { return section }
            var section = section
            change(&section)
            return section
        }
    }

    private mutating func updateBody(of section: UUID, _ change: (Split<BoardTile>?) -> Split<BoardTile>?) {
        updateSection(section) { $0.body = change($0.body)?.normalized() }
    }

    /// A chat put in a section with no drop point: it splits the section's largest tile that
    /// isn't a chip, along its longer side (bspwm's way); the first one takes the whole body.
    package mutating func attach(_ tile: UUID, to section: UUID, in size: CGSize) {
        guard let target = self.section(section) else { return }
        guard let body = target.body else {
            updateBody(of: section) { _ in .leaf(BoardTile(id: tile)) }
            return
        }
        let frames = solve(in: size)
        let candidates = target.tiles.compactMap { t in frames.tiles[t.id].map { (t.id, $0) } }
        let open = candidates.filter { Density.of($0.1.size) != .chip }
        guard let (largest, rect) = (open.isEmpty ? candidates : open).max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }),
            let path = body.path(where: { $0.id == largest })
        else { return }
        let axis: SplitAxis = rect.width >= rect.height ? .row : .column
        updateBody(of: section) { $0?.inserting(.leaf(BoardTile(id: tile)), beside: path, axis: axis, after: true) }
    }

    /// A new tile where it was put: at a drop point, else into the section (the first, with
    /// none said) by auto placement. Dropped on a tile's middle, a new one goes beside it.
    package mutating func put(_ tile: UUID, section: UUID?, drop: BoardDrop?, in size: CGSize) {
        switch drop {
        case .beside(let other, let edge)?: split(other, edge, new: tile)
        case .swap(let other)?: split(other, .right, new: tile)
        case .into(let target)?: attach(tile, to: target, in: size)
        case .newSection(let edge)?: addSection(at: edge, BoardSection(name: "Section \(sections.count + 1)", body: .leaf(BoardTile(id: tile))))
        case nil:
            guard let target = section ?? sections.first?.id else { return }
            attach(tile, to: target, in: size)
        }
    }

    /// A new tile (a slot, or a chat dropped there) beside `tile`, on `edge`.
    package mutating func split(_ tile: UUID, _ edge: DropEdge, new: UUID) {
        guard let section = section(of: tile), let path = section.body?.path(where: { $0.id == tile }) else { return }
        updateBody(of: section.id) { $0?.inserting(.leaf(BoardTile(id: new)), beside: path, axis: edge.axis, after: edge.after) }
    }

    /// A tile out; its neighbour takes its room.
    package mutating func remove(_ tile: UUID) {
        guard let section = section(of: tile), let path = section.body?.path(where: { $0.id == tile }) else { return }
        updateBody(of: section.id) { $0?.removing(at: path) }
    }

    /// Two tiles trade places.
    package mutating func swap(_ a: UUID, _ b: UUID) {
        guard a != b, section(of: a) != nil, section(of: b) != nil else { return }
        root = root.mapLeaves { section in
            var section = section
            section.body = section.body?.mapLeaves { $0.id == a ? BoardTile(id: b) : $0.id == b ? BoardTile(id: a) : $0 }
            return section
        }
    }

    /// A tile moved: out of its place (its neighbour takes the room), and in where it's dropped.
    package mutating func move(_ tile: UUID, to drop: BoardDrop, in size: CGSize) {
        guard section(of: tile) != nil else { return }
        switch drop {
        case .swap(let other):
            swap(tile, other)
        case .beside(let other, let edge):
            guard other != tile, section(of: other) != nil else { return }
            remove(tile)
            split(other, edge, new: tile)
        case .into(let target):
            guard self.section(target) != nil else { return }
            remove(tile)
            attach(tile, to: target, in: size)
        case .newSection(let edge):
            remove(tile)
            addSection(at: edge, BoardSection(name: "Section \(sections.count + 1)", body: .leaf(BoardTile(id: tile))))
        }
    }

    /// A tile's boundaries moved: the gutter's split takes these lengths. A tile (or a row of
    /// them) left under `chipBelow` tall in a column is pinned as a chip; one pinned before and
    /// grown past it shares by fraction again.
    package mutating func resize(_ gutter: GutterID, lengths: [CGFloat]) {
        func reshare(_ node: Split<BoardTile>) -> Split<BoardTile>? {
            guard case .split(let axis, var children) = node.node(at: gutter.path), children.count == lengths.count else { return nil }
            var pinned = Array(repeating: false, count: children.count)
            for index in children.indices where axis == .column && children[index].node.isFlat && lengths[index] < Size.Board.chipBelow {
                pinned[index] = true
            }
            let free = zip(lengths, pinned).filter { !$0.1 }.map(\.0).reduce(0, +)
            for index in children.indices {
                children[index].share = pinned[index] ? .pinned(Size.Board.chip) : .fraction(free > 0 ? lengths[index] / free : 1)
            }
            return node.replacing(at: gutter.path, with: .split(axis, children))
        }
        if let section = gutter.section {
            updateBody(of: section) { body in body.flatMap(reshare) ?? body }
        } else if case .split(let axis, var children)? = root.node(at: gutter.path), children.count == lengths.count {
            let total = lengths.reduce(0, +)
            for index in children.indices { children[index].share = .fraction(total > 0 ? lengths[index] / total : 1) }
            root = root.replacing(at: gutter.path, with: .split(axis, children)).normalized()
        }
    }

    /// A tile made a chip, card or full chat by resizing it along its split: a chip pins the
    /// nearest flat node in a column; a card or full chat takes the length it needs from the
    /// siblings with the most to give. False when its place can't (a lone tile, a stacked split).
    @discardableResult
    package mutating func setDensity(_ tile: UUID, _ density: Density, in size: CGSize) -> Bool {
        guard let section = section(of: tile), let body = section.body, var path = body.path(where: { $0.id == tile }) else { return false }
        let frames = solve(in: size)
        if density == .chip {
            // The nearest flat node that's a column's child.
            while let index = path.last {
                let parent = Array(path.dropLast())
                if case .split(.column, _)? = body.node(at: parent), body.node(at: path)?.isFlat == true,
                    let gutter = frames.gutters.first(where: { $0.id.section == section.id && $0.id.path == parent })
                {
                    var lengths = gutter.lengths
                    let freed = lengths[index] - Size.Board.chip
                    lengths[index] = Size.Board.chip
                    let receiver = lengths.indices.filter { $0 != index }.max { lengths[$0] < lengths[$1] }
                    if let receiver { lengths[receiver] += freed }
                    resize(gutter.id, lengths: lengths)
                    return true
                }
                path = parent
                _ = index
            }
            return false
        }
        // Card or full: along the parent split, to the length the density needs; a pinned chip
        // (or row of them) grows along its column first.
        var level = path
        while let index = level.last {
            if case .split(.column, let children)? = body.node(at: Array(level.dropLast())), children[index].share.isPinned {
                path = level
                break
            }
            level.removeLast()
        }
        guard let index = path.last,
            let gutter = frames.gutters.first(where: { $0.id.section == section.id && $0.id.path == Array(path.dropLast()) })
        else { return false }
        let target: CGFloat
        switch (density, gutter.axis) {
        case (.full, .row): target = Size.Board.full.width
        case (.full, .column): target = Size.Board.full.height
        case (_, .column): target = Size.Board.card
        case (.card, .row): target = min(gutter.lengths[index], Size.Board.full.width - 1)
        default: target = gutter.lengths[index]
        }
        var lengths = gutter.lengths
        var need = target - lengths[index]
        if density == .card, gutter.axis == .column, lengths[index] >= Size.Board.full.height {
            // Down from full: just under it.
            need = Size.Board.full.height - 1 - lengths[index]
        }
        if need > 0 {
            for other in lengths.indices.filter({ $0 != index }).sorted(by: { lengths[$0] - gutter.mins[$0] > lengths[$1] - gutter.mins[$1] }) {
                let give = min(need, max(0, lengths[other] - gutter.mins[other]))
                lengths[other] -= give
                lengths[index] += give
                need -= give
                if need <= 0 { break }
            }
        } else if need < 0, let receiver = lengths.indices.filter({ $0 != index }).max(by: { lengths[$0] < lengths[$1] }) {
            lengths[receiver] -= need
            lengths[index] += need
        }
        resize(gutter.id, lengths: lengths)
        return true
    }

    // MARK: Sections

    /// A new section at the tab's edge, a share as big as each of the sections along that edge.
    package mutating func addSection(at edge: DropEdge, _ section: BoardSection) {
        var count = 1
        if case .split(let axis, let children) = root, axis == edge.axis { count = children.count }
        let share = 1 / CGFloat(count + 1)
        let old = Split<BoardSection>.Child(.fraction(1 - share), root)
        let new = Split<BoardSection>.Child(.fraction(share), .leaf(section))
        root = Split.split(edge.axis, edge.after ? [old, new] : [new, old]).normalized()
    }

    /// A new section beside another, halving it (the section popup's Split right and down).
    package mutating func addSection(_ edge: DropEdge, of other: UUID, _ section: BoardSection) {
        guard let path = root.path(where: { $0.id == other }) else { return }
        root = root.inserting(.leaf(section), beside: path, axis: edge.axis, after: edge.after)
    }

    /// `source`'s tiles become a row under `target`'s (pins kept); `source`'s room goes to its
    /// neighbour. The target keeps its name.
    package mutating func mergeSection(_ source: UUID, into target: UUID) {
        guard source != target, let from = section(source), let to = section(target), let path = root.path(where: { $0.id == source }) else { return }
        if let moved = from.body {
            let merged: Split<BoardTile>
            if let body = to.body {
                let share = CGFloat(from.tiles.count) / CGFloat(from.tiles.count + to.tiles.count)
                merged = Split.split(.column, [.init(.fraction(1 - share), body), .init(.fraction(share), moved)]).normalized()
            } else {
                merged = moved
            }
            updateSection(target) { $0.body = merged }
        }
        if let rest = root.removing(at: path) { root = rest }
    }

    /// A section out: its tiles merge into its neighbour, so no chat goes with it. The last
    /// section only empties.
    package mutating func removeSection(_ id: UUID) {
        guard let path = root.path(where: { $0.id == id }) else { return }
        guard let index = path.last, case .split(_, let children)? = root.node(at: Array(path.dropLast())) else {
            updateSection(id) { $0.body = nil }
            return
        }
        let neighbour = index > 0 ? index - 1 : index + 1
        let leaves = children[neighbour].node.leaves
        guard let target = index > 0 ? leaves.last : leaves.first else { return }
        mergeSection(id, into: target.id)
    }

    package mutating func rename(_ section: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updateSection(section) { $0.name = name }
    }

    package mutating func setSwatch(_ section: UUID, _ swatch: Swatch?) {
        updateSection(section) { $0.swatch = swatch }
    }

    /// The tile in a direction from another, by nearest centre (⌥⌘ arrows), across sections.
    package func neighbour(of tile: UUID, toward edge: DropEdge, in frames: BoardFrames) -> UUID? {
        guard let from = frames.tiles[tile] else { return nil }
        let candidates = frames.tiles.filter { id, rect in
            guard id != tile else { return false }
            switch edge {
            case .left: return rect.midX < from.minX
            case .right: return rect.midX > from.maxX
            case .top: return rect.midY < from.minY
            case .bottom: return rect.midY > from.maxY
            }
        }
        return candidates.min { a, b in
            hypot(a.value.midX - from.midX, a.value.midY - from.midY) < hypot(b.value.midX - from.midX, b.value.midY - from.midY)
        }?.key
    }
}

// MARK: - Undo

/// A board with its layout steps: each edit pushes the board it replaced, ⌘Z goes back one,
/// ⌘⇧Z forward again. Up to `Size.Board.undoDepth` steps, saved with the board.
package struct BoardHistory: Codable, Equatable, Sendable {
    package private(set) var board: Board
    package private(set) var undoStack: [Board] = []
    package private(set) var redoStack: [Board] = []

    package init(_ board: Board) { self.board = board }

    /// One step: nothing when the edit changed nothing.
    @discardableResult
    package mutating func apply(_ edit: (inout Board) -> Void) -> Bool {
        var next = board
        edit(&next)
        guard next != board else { return false }
        undoStack.append(board)
        if undoStack.count > Size.Board.undoDepth { undoStack.removeFirst(undoStack.count - Size.Board.undoDepth) }
        redoStack.removeAll()
        board = next
        return true
    }

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }

    package mutating func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(board)
        board = last
    }

    package mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(board)
        board = next
    }
}

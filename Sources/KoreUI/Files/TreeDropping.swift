import AppKit
import HostClient
import KoreCore
import SwiftUI

// A drag over an explorer's tree, from Finder, another Kore window or the tree itself: which
// folder it points at (a folder row: that folder; a file row: its folder; the space under the
// rows: the root), what a drop there does (copy or move, or nothing), the badge saying so at
// the pointer, a collapsed folder held under it opening after a moment (closed again when the
// drag leaves without dropping in it), and the tree scrolling at its edges.

/// What a drop does.
enum DropAct: Equatable {
    case copy, move
    /// Not here: a folder into itself, a place that can't be written, a box that's offline, or
    /// a move into the folder it's in.
    case refused
}

/// What a drag carries, as far as the drag's pasteboard says while it's over a tree.
@MainActor
struct DragSources: Equatable {
    var places: [FilePlace]
    /// From a Kore tree (this window's or another's), not Finder.
    var fromKore: Bool

    /// The drag now: a box tree's rows (`BoxDrag`), else the files on the drag pasteboard, from
    /// a Kore tree when they're its rows (`TreeDrag`).
    static func now() -> DragSources {
        let urls = Self.dragURLs()
        if urls.isEmpty, BoxDrag.active, let alias = BoxDrag.alias {
            return DragSources(places: BoxDrag.paths.map { .box(alias: alias, path: $0) }, fromKore: true)
        }
        let paths = urls.map { realPath($0.path) }
        let fromKore = !paths.isEmpty && !TreeDrag.paths.isEmpty && paths.allSatisfy(TreeDrag.paths.contains)
        let all = fromKore && paths.count == 1 ? TreeDrag.paths : paths
        return DragSources(places: all.map { .mac($0) }, fromKore: fromKore)
    }

    private static var cached: (count: Int, urls: [URL])?

    private static func dragURLs() -> [URL] {
        let board = NSPasteboard(name: .drag)
        if let cached, cached.count == board.changeCount { return cached.urls }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        cached = (board.changeCount, urls)
        return urls
    }
}

@MainActor
enum DropRules {
    /// The folder a drop on a row goes into: the row if it's a folder, else the row's folder;
    /// nil (the space under the rows): the root.
    static func target(row: String?, isFolder: Bool, root: String) -> String {
        guard let row else { return root }
        return isFolder ? row : (row as NSString).deletingLastPathComponent
    }

    /// Same device: moves (⌥ copies) when the rows come from a Kore tree; Finder's files copy and
    /// so does anything across devices (⌘ moves, the copy checked before the source goes).
    static func act(_ sources: DragSources, into folder: FilePlace, flags: NSEvent.ModifierFlags, reachable: Bool = true, writable: Bool = true)
        -> DropAct
    {
        guard reachable, writable else { return .refused }
        if sources.places.contains(where: { folder.within($0) }) { return .refused }
        let sameDevice = !sources.places.isEmpty && sources.places.allSatisfy { $0.sameDevice(folder) }
        let move = sources.fromKore && sameDevice ? !flags.contains(.option) : flags.contains(.command)
        // A move into the folder it's in does nothing.
        if move, sameDevice, sources.places.allSatisfy({ $0.parent == folder }) { return .refused }
        return move ? .move : .copy
    }

    /// "Copy to src/", "Move to mybox: src/", "Can't drop here". `shown`: the folder as the tree
    /// names it.
    static func badge(_ act: DropAct, sources: DragSources, into folder: FilePlace, shown: String) -> String {
        guard act != .refused else { return "Can't drop here" }
        let across = sources.places.contains { !$0.sameDevice(folder) }
        return (act == .move ? "Move to " : "Copy to ") + (across ? folder.device + ": " : "") + shown + "/"
    }
}

/// One tree's drag state: its target, its badge, and the folders it sprang open.
@MainActor @Observable
final class TreeDropping {
    struct Badge: Equatable {
        /// The row under the pointer; nil: the space under the rows.
        var row: String?
        /// The pointer in that row (or space).
        var point: CGPoint
        var text: String
        var refused: Bool
    }

    /// The folder a drop goes into now; nil when nothing's over the tree or it's refused.
    private(set) var target: String?
    private(set) var badge: Badge?
    /// How long a collapsed folder is held under the pointer before it opens.
    @ObservationIgnored var springDelay: Duration = .milliseconds(600)
    /// How long the pointer may be off every row before the drag counts as gone.
    @ObservationIgnored var leaveDelay: Duration = .milliseconds(250)
    /// Folders this drag opened, in order.
    @ObservationIgnored private(set) var sprung: [String] = []
    @ObservationIgnored private var holding: String?
    @ObservationIgnored private var spring: Task<Void, Never>?
    @ObservationIgnored private var leaving: Task<Void, Never>?
    @ObservationIgnored private var nudged = Date.distantPast
    /// The tree: whether a folder is open, opening and closing one, and scrolling a row's
    /// neighbours into view (the edges scroll under a drag).
    @ObservationIgnored var isOpen: (String) -> Bool = { _ in true }
    @ObservationIgnored var expand: (String) -> Void = { _ in }
    @ObservationIgnored var collapse: (String) -> Void = { _ in }
    @ObservationIgnored var nudge: ((String) -> Void)?

    /// The pointer over `row` (nil: the space under the rows), which points at `folder`.
    func over(row: String?, isFolder: Bool, folder: String, point: CGPoint, act: DropAct, text: String) {
        leaving?.cancel()
        leaving = nil
        let next = Badge(row: row, point: point, text: text, refused: act == .refused)
        if badge != next { badge = next }
        let aimed = act == .refused ? nil : folder
        if target != aimed { target = aimed }
        // A collapsed folder held under the pointer opens.
        let closed = row != nil && isFolder && act != .refused && !isOpen(folder) ? folder : nil
        if closed != holding {
            holding = closed
            spring?.cancel()
            spring = closed.map { folder in
                Task { [weak self] in
                    guard let delay = self?.springDelay else { return }
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self, self.holding == folder, !self.isOpen(folder) else { return }
                    self.expand(folder)
                    self.sprung.append(folder)
                }
            }
        }
        if let row, let nudge, Date().timeIntervalSince(nudged) > 0.12 {
            nudged = Date()
            nudge(row)
        }
    }

    /// The pointer left `row`: unless it comes over another soon, the drag has gone, and the
    /// folders it opened close.
    func out(row: String?) {
        guard badge?.row == row else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            guard let delay = self?.leaveDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.ended(droppedInto: nil)
        }
    }

    /// Dropped (into `droppedInto`) or gone: the folders it opened close, but those the drop
    /// went into or below.
    func ended(droppedInto folder: String?) {
        leaving?.cancel()
        spring?.cancel()
        holding = nil
        for opened in Self.toClose(sprung, droppedInto: folder).reversed() { collapse(opened) }
        sprung = []
        if target != nil { target = nil }
        if badge != nil { badge = nil }
    }

    /// The folders a drag opened that close as it ends: all but the drop's folder and those
    /// above it.
    static func toClose(_ sprung: [String], droppedInto folder: String?) -> [String] {
        guard let folder else { return sprung }
        return sprung.filter { folder != $0 && !folder.hasPrefix($0 + "/") }
    }
}

/// The badge at the pointer: what a drop there does, in a quiet capsule.
struct DropBadge: View {
    let badge: TreeDropping.Badge

    var body: some View {
        Text(badge.text)
            .font(Chrome.caption)
            .foregroundStyle(badge.refused ? Theme.tertiary : Theme.text)
            .lineLimit(1)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Tree.guide, lineWidth: Stroke.hairline))
            .fixedSize()
            .offset(x: badge.point.x + 14, y: badge.point.y + 12)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// A thin bar under a row whose copy is on its way.
struct CarryBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.accent.opacity(0.6))
                .frame(width: max(geometry.size.width * fraction, 4), height: 2)
                .animation(Motion.fade, value: fraction)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

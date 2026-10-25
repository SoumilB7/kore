import AppKit
import SwiftUI

/// A place in a chat's transcript, in the model's terms: which entry, which of its texts (a path
/// through its blocks: the top-level block's index, then a list item, an inner block, or a table
/// row and column; a tool's IN is [0] and OUT [1]), and a UTF-16 offset into that text as shown.
/// It outlives the views: a row that scrolls away and is built again finds the same place.
struct TextPoint: Equatable, CustomStringConvertible {
    var entry: UUID
    var path: [Int]
    var offset: Int

    var description: String { "\(entry.uuidString.prefix(8))\(path)@\(offset)" }
}

/// What a selection runs over: rows by entry, in order (a chat's transcript, a Markdown file's
/// runs), and how a range of them copies.
@MainActor protocol SelectionSource: AnyObject {
    /// The entry's place; nil once it has gone.
    func index(of entry: UUID) -> Int?
    /// The first and last rows shown (⌘A).
    var selectionBounds: (first: UUID, last: UUID)? { get }
    /// The range as markdown, from the model.
    func selectionMarkdown(from start: TextPoint, to end: TextPoint) -> String
}

/// One selectable text of a built row: where it is (the timeline's content space), what it
/// shows and how it's set.
struct SelectionSlot {
    var frame: CGRect
    var text: AttributedString
    var style: SelectionStyle
}

/// The chat transcript's one text selection (research/transcript-selection.md): from any text to
/// any other, across blocks, rows and turns, as a browser selects a page. Rows report where their
/// texts are as they're laid out (a frame each, nothing else); a press, a drag or the highlight
/// lays out again, with TextKit 2, only the texts it touches. Copy builds markdown from the
/// model (`SelectionCopy`).
@MainActor
package final class TranscriptSelection: ObservableObject {
    /// The coordinate space rows report in: the timeline's content, so scrolling moves nothing.
    nonisolated static let space = "transcript-selection"

    weak var store: (any SelectionSource)?
    /// The view behind the rows that follows the pointer (its coordinates are the content space).
    weak var responder: NSView?
    @Published private(set) var anchor: TextPoint?
    @Published private(set) var focus: TextPoint?
    /// The transcript has focus in the key window: the highlight is the active colour.
    @Published var active = false

    /// Built rows' frames, their texts, and what floats over them (a pinned message), in the
    /// content space.
    private(set) var rows: [UUID: CGRect] = [:]
    private(set) var slots: [UUID: [[Int]: SelectionSlot]] = [:]
    private var blockers: [String: CGRect] = [:]

    /// Texts laid out again, least recently used first.
    private var layouts: [LayoutKey: SlotLayout] = [:]
    private var layoutOrder: [LayoutKey] = []

    /// A double- or triple-click selects by words or paragraphs, and a drag after it extends by
    /// the same: the unit first taken.
    enum Unit { case character, word, paragraph }
    private var unit = Unit.character
    private var anchorRange: (start: TextPoint, end: TextPoint)?

    /// Counts for storylines and the nav probe.
    package private(set) var hitTests = 0
    package private(set) var laidOut = 0

    init(store: (any SelectionSource)?) { self.store = store }

    // MARK: Rows report

    func rowMoved(_ entry: UUID, _ frame: CGRect) { rows[entry] = frame }

    func textMoved(_ entry: UUID, _ path: [Int], _ slot: SelectionSlot) { slots[entry, default: [:]][path] = slot }

    /// A row came on screen, or went off it. A lazy stack keeps a row's view a while after it
    /// leaves, and shows it again without laying it out (so it doesn't report again): what it
    /// reported is kept, and only rows on screen are hit-tested. Off-screen rows' reports go
    /// once there are many.
    func rowAppeared(_ entry: UUID) {
        offscreen.removeAll { $0 == entry }
        shown[entry, default: 0] += 1
    }

    func rowLeft(_ entry: UUID) {
        let left = (shown[entry] ?? 1) - 1
        shown[entry] = left > 0 ? left : nil
        guard left <= 0 else { return }
        offscreen.append(entry)
        while offscreen.count > Layout.Selection.offscreenRows {
            let gone = offscreen.removeFirst()
            rows[gone] = nil
            slots[gone] = nil
        }
    }

    /// Rows on screen (how many views of each: a row built again appears before its old view goes).
    private var shown: [UUID: Int] = [:]
    /// Rows that left the screen, oldest first.
    private var offscreen: [UUID] = []

    func blocker(_ id: String, _ frame: CGRect?) { blockers[id] = frame }

    func isBlocked(_ p: CGPoint) -> Bool { blockers.values.contains { $0.contains(p) } }

    // MARK: The selection

    /// Start and end in transcript order; nil when nothing is selected, or an end's entry has gone.
    var range: (start: TextPoint, end: TextPoint)? {
        guard let anchor, let focus, anchor != focus, index(anchor.entry) != nil, index(focus.entry) != nil else { return nil }
        return less(focus, anchor) ? (focus, anchor) : (anchor, focus)
    }

    var hasSelection: Bool { range != nil }

    func clear() {
        if anchor != nil { anchor = nil }
        if focus != nil { focus = nil }
        unit = .character
        anchorRange = nil
        layouts = [:]
        layoutOrder = []
    }

    /// A press on text: a caret (one click), a word (two) or a paragraph (three); with ⇧, the
    /// selection is extended to it instead.
    func press(at p: CGPoint, clicks: Int, extend: Bool) {
        guard let point = hit(p) else { return }
        if extend, anchor != nil {
            focus = point
            return
        }
        switch clicks {
        case 2: take(point, .word)
        case 3...: take(point, .paragraph)
        default:
            unit = .character
            anchorRange = nil
            anchor = point
            focus = point
        }
    }

    /// A drag that started away from text: it selects from the text nearest where it started.
    func begin(at p: CGPoint) {
        unit = .character
        anchorRange = nil
        anchor = hit(p)
        focus = anchor
    }

    /// The pointer moved on with the button down.
    func extend(to p: CGPoint) {
        guard let point = hit(p) else { return }
        guard unit != .character, let around = units(around: point), let anchorRange else {
            if point != focus { focus = point }
            return
        }
        if less(point, anchorRange.start) {
            anchor = anchorRange.end
            focus = around.start
        } else {
            anchor = anchorRange.start
            focus = less(around.end, anchorRange.end) ? anchorRange.end : around.end
        }
    }

    /// Every row the timeline shows, first to last (⌘A).
    func selectAll() {
        guard let (first, last) = store?.selectionBounds else { return }
        unit = .character
        anchorRange = nil
        anchor = TextPoint(entry: first, path: [], offset: 0)
        focus = TextPoint(entry: last, path: [Int.max], offset: Int.max)
    }

    private func take(_ point: TextPoint, _ unit: Unit) {
        self.unit = unit
        guard let around = units(around: point) else { return }
        anchorRange = around
        anchor = around.start
        focus = around.end
    }

    /// The word or paragraph around a point, in its text.
    private func units(around point: TextPoint) -> (start: TextPoint, end: TextPoint)? {
        guard let layout = layout(point.entry, point.path) else { return nil }
        let r = unit == .paragraph ? layout.paragraph(at: point.offset) : layout.word(at: point.offset)
        var start = point, end = point
        start.offset = r.lowerBound
        end.offset = r.upperBound
        return (start, end)
    }

    // MARK: Order

    /// The entry's place in the chat; nil once it has gone.
    func index(_ entry: UUID) -> Int? { store?.index(of: entry) }

    func less(_ a: TextPoint, _ b: TextPoint) -> Bool {
        let (ia, ib) = (index(a.entry) ?? .max, index(b.entry) ?? .max)
        if ia != ib { return ia < ib }
        if a.path != b.path { return a.path.lexicographicallyPrecedes(b.path) }
        return a.offset < b.offset
    }

    /// How much of one text is selected: a range of offsets, with `Int.max` for "to its end";
    /// nil for none of it.
    func selected(_ entry: UUID, _ path: [Int]) -> Range<Int>? {
        guard let (start, end) = range, let here = index(entry) else { return nil }
        let (s, e) = (index(start.entry) ?? .max, index(end.entry) ?? .max)
        guard s <= here, here <= e else { return nil }
        let afterStart = here > s || !path.lexicographicallyPrecedes(start.path)
        let beforeEnd = here < e || !end.path.lexicographicallyPrecedes(path)
        guard afterStart, beforeEnd else { return nil }
        let lo = here == s && path == start.path ? start.offset : 0
        let hi = here == e && path == end.path ? end.offset : .max
        return lo < hi ? lo..<hi : nil
    }

    /// Whether any of an entry is selected.
    func touches(_ entry: UUID) -> Bool {
        guard let (start, end) = range, let here = index(entry), let s = index(start.entry), let e = index(end.entry) else { return false }
        return s <= here && here <= e
    }

    // MARK: Hit-testing

    /// The text under a point of the content space, or the nearest one: off text (a gap, the
    /// margin, past a line's end) a press takes the nearest place, as a browser does.
    func hit(_ p: CGPoint) -> TextPoint? {
        hitTests += 1
        var best: (entry: UUID, path: [Int], frame: CGRect, score: CGFloat)?
        for (entry, texts) in slots where shown[entry] != nil {
            for (path, slot) in texts {
                let r = slot.frame
                let dy = p.y < r.minY ? r.minY - p.y : p.y > r.maxY ? p.y - r.maxY : 0
                let dx = p.x < r.minX ? r.minX - p.x : p.x > r.maxX ? p.x - r.maxX : 0
                let score = dy * 10_000 + dx
                if best == nil || score < best!.score || (score == best!.score && less(TextPoint(entry: entry, path: path, offset: 0), TextPoint(entry: best!.entry, path: best!.path, offset: 0))) {
                    best = (entry, path, r, score)
                }
            }
        }
        guard let (entry, path, frame, _) = best, let layout = layout(entry, path) else { return nil }
        return TextPoint(entry: entry, path: path, offset: layout.offset(at: CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)))
    }

    /// The text whose frame holds the point (a press there is the text's, not the row's).
    func text(at p: CGPoint) -> (entry: UUID, path: [Int])? {
        for (entry, texts) in slots where shown[entry] != nil {
            for (path, slot) in texts where slot.frame.contains(p) { return (entry, path) }
        }
        return nil
    }

    /// A link under the point, for a click that didn't drag.
    func link(at p: CGPoint) -> URL? {
        guard let (entry, path) = text(at: p), let slot = slots[entry]?[path], let layout = layout(entry, path) else { return nil }
        let local = CGPoint(x: p.x - slot.frame.minX, y: p.y - slot.frame.minY)
        let offset = layout.offset(at: local)
        // The glyph under the point: just before the nearest place when that's past it.
        return layout.link(at: offset) ?? layout.link(at: offset - 1)
    }

    /// A built text laid out again at its width (kept until it changes, a bounded number of them).
    func layout(_ entry: UUID, _ path: [Int]) -> SlotLayout? {
        guard let slot = slots[entry]?[path] else { return nil }
        let key = LayoutKey(
            entry: entry, path: path, width: Int((slot.frame.width * 2).rounded()), height: Int((slot.frame.height * 2).rounded()),
            text: slot.text, zoom: Zoom.shared.scale)
        if let done = layouts[key] {
            if layoutOrder.last != key, let i = layoutOrder.lastIndex(of: key) {
                layoutOrder.remove(at: i)
                layoutOrder.append(key)
            }
            return done
        }
        let made = SlotLayout(slot.style.attributed(slot.text, zoom: Zoom.shared.scale), size: slot.frame.size)
        laidOut += 1
        layouts[key] = made
        layoutOrder.append(key)
        if layoutOrder.count > Layout.Selection.layoutCache { layouts[layoutOrder.removeFirst()] = nil }
        return made
    }

    struct LayoutKey: Hashable {
        let entry: UUID
        let path: [Int]
        let width: Int
        let height: Int
        let text: AttributedString
        let zoom: CGFloat
    }

    // MARK: Highlight

    /// What a built row fills for the selection, in its own coordinates. A text selected whole
    /// fills its frame and isn't laid out again, so a long selection costs nothing per row; only
    /// the texts holding an end are.
    func rects(_ entry: UUID) -> [CGRect] {
        guard touches(entry), let row = rows[entry], let texts = slots[entry] else { return [] }
        var out: [CGRect] = []
        for (path, slot) in texts {
            guard let sel = selected(entry, path) else { continue }
            let dx = slot.frame.minX - row.minX, dy = slot.frame.minY - row.minY
            if sel.lowerBound == 0, sel.upperBound == .max {
                out.append(CGRect(origin: CGPoint(x: dx, y: dy), size: slot.frame.size))
            } else if let layout = layout(entry, path) {
                out += layout.rects(sel).map { $0.offsetBy(dx: dx, dy: dy) }
            }
        }
        return out
    }

    // MARK: Links and copy

    /// Where the chat's window opens a link (`Workspace.openLink`: a file in a Kore tab); nil
    /// for a transcript outside one, whose links go to the system.
    var openLink: ((URL) -> Void)?

    /// Opens a link clicked in a text. Under storylines the system never gets one: it's noted.
    func open(_ url: URL) {
        if let openLink {
            openLink(url)
        } else if StoryHost.installed {
            Self.opened.append(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Links a storyline's clicks opened, or would have opened in the system.
    package static var opened: [URL] = []
    /// Those of them Kore opened itself (a file in a tab, a folder in the explorer).
    package static var openedInKore: [URL] = []

    /// Where copies go: the general pasteboard, or under storylines a named one, so a run never
    /// touches the owner's clipboard.
    package static var pasteboard: NSPasteboard {
        StoryHost.installed ? NSPasteboard(name: .init("kore-storylines")) : .general
    }

    func markdown() -> String {
        guard let store, let range else { return "" }
        return store.selectionMarkdown(from: range.start, to: range.end)
    }

    /// The selection as markdown on the pasteboard; false with nothing selected.
    @discardableResult
    func copy() -> Bool {
        let text = markdown()
        guard !text.isEmpty else { return false }
        let board = Self.pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
        return true
    }
}

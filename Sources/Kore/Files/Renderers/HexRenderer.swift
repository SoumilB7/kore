import AppKit
import SwiftUI

/// A read-only hex view (VS Code's Hex Editor, read-only): offset, 16 bytes in hex and their
/// ASCII, for binary and unknown files. Rows are drawn only where visible, and the file is
/// read 64 KB at a time off the main thread, so a file of any size opens at once.
struct HexView: View {
    let file: FileInfo
    let context: RendererContext

    var body: some View {
        HexCanvas(url: file.url, reloadToken: context.reloadToken, zoom: context.zoom) { context.setFacts($0.items) }
            .background(Theme.background)
    }
}

/// What the status row shows: the caret's offset, the selection, the file's size.
struct HexStatus: Equatable {
    var caret = 0
    var selected = 0
    var size: Int64 = 0

    var items: [String] {
        var offset = String(format: "Offset 0x%08llX", Int64(caret))
        if selected > 1 { offset += " (\(selected) bytes selected)" }
        return [offset, ByteCountFormatter.string(fromByteCount: size, countStyle: .file)]
    }
}

private struct HexCanvas: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    let zoom: CGFloat
    let report: (HexStatus) -> Void

    /// The scroll view scrolls an empty spacer as tall as the rows; the drawing view sits over
    /// it at the window's size and follows the scroll, so only one screen is ever backed.
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = HexScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // The window's content runs under the title bar; this view starts below it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.clipsToBounds = true
        let view = HexDocumentView(url: url, report: report)
        scroll.documentView = view.spacer
        view.attach(to: scroll)
        context.coordinator.view = view
        context.coordinator.token = reloadToken
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = context.coordinator.view else { return }
        view.setZoom(zoom)
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            view.reload()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.view?.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token = 0
        var view: HexDocumentView?
    }
}

// MARK: - Reading

/// The file in 64 KB pages, read on a background queue; the last few are kept.
@MainActor
private final class HexPages {
    nonisolated static let pageSize = 64 * 1024
    private static let kept = 16

    let url: URL
    private(set) var size: Int64 = 0
    private var pages: [Int: Data] = [:]
    private var order: [Int] = []
    private var pending: Set<Int> = []
    private var generation = 0
    private let queue = DispatchQueue(label: "kore.hex", qos: .userInitiated)
    var onLoad: () -> Void = {}

    init(url: URL) {
        self.url = url
        measure()
    }

    func measure() {
        size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func reset() {
        generation += 1
        pages = [:]
        order = []
        pending = []
        measure()
    }

    /// The byte at `offset`, or nil while its page is loading (it's requested).
    func byte(at offset: Int64) -> UInt8? {
        let page = Int(offset / Int64(Self.pageSize))
        guard let data = pages[page] else {
            request(page)
            return nil
        }
        let index = Int(offset - Int64(page) * Int64(Self.pageSize))
        return index < data.count ? data[data.startIndex + index] : nil
    }

    private func request(_ page: Int) {
        guard !pending.contains(page) else { return }
        pending.insert(page)
        let url = url
        let generation = generation
        queue.async {
            let data = Self.read(url, page: page)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.store(data, page: page, generation: generation) }
            }
        }
    }

    private func store(_ data: Data?, page: Int, generation: Int) {
        guard generation == self.generation else { return }
        pending.remove(page)
        guard let data else { return }
        pages[page] = data
        order.append(page)
        if order.count > Self.kept { pages[order.removeFirst()] = nil }
        onLoad()
    }

    nonisolated private static func read(_ url: URL, page: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(page) * UInt64(pageSize))
        return try? handle.read(upToCount: pageSize) ?? Data()
    }

    /// Bytes for copying, read directly (a copy is capped, so this stays quick).
    func bytes(_ range: Range<Int64>) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(range.lowerBound))
        return (try? handle.read(upToCount: Int(range.count))) ?? Data()
    }
}

// MARK: - Drawing

/// Draws only the visible rows. Past a few million points the scroll position maps onto the
/// rows proportionally, so any size scrolls (AppKit's coordinates lose precision far out).
/// Lays the drawing view over the clip view (an NSScrollView sizes only its own parts).
private final class HexScrollView: NSScrollView {
    weak var viewport: HexDocumentView?

    override func tile() {
        super.tile()
        viewport?.fit(contentView.frame)
    }
}

/// Gives the scroll view its range; draws nothing, so it has no backing store.
private final class HexSpacer: NSView {
    override var isFlipped: Bool { true }
}

private final class HexDocumentView: NSView {
    let spacer = HexSpacer()
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private let pages: HexPages
    private let report: (HexStatus) -> Void
    private var zoom: CGFloat = 0
    private var font = TextStyle.hexFont
    private var advance: CGFloat = 7
    private var rowHeight: CGFloat = Size.Editor.line
    /// Selection as byte offsets: from the anchor to the caret, inclusive.
    private var anchor: Int64 = 0
    private var caret: Int64 = 0
    /// Which column the last click was in: ⌘C copies that form.
    private var inASCII = false
    /// The byte under the pointer: it and its twin in the other column get a light fill.
    private var hovered: Int64?
    /// The header's rule, over the scroll view.
    private let rule = NSView()
    /// RenderTiming has had the first frame.
    private var timed = false
    private var tracking: NSTrackingArea?
    private static let heightCap: CGFloat = 4_000_000
    private static let copyCap: Int64 = 16 * 1024 * 1024

    init(url: URL, report: @escaping (HexStatus) -> Void) {
        pages = HexPages(url: url)
        self.report = report
        super.init(frame: .zero)
        pages.onLoad = { [weak self] in self?.needsDisplay = true }
        setZoom(Zoom.shared.scale)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func attach(to scroll: HexScrollView) {
        scrollView = scroll
        scroll.viewport = self
        scroll.addSubview(self, positioned: .below, relativeTo: scroll.verticalScroller)
        clipsToBounds = true
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.border.nsColor.cgColor
        scroll.addSubview(rule, positioned: .below, relativeTo: scroll.verticalScroller)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } }
        resize()
        // The facts row, once SwiftUI has finished this update.
        DispatchQueue.main.async { [weak self] in self?.publish() }
    }

    /// Shows the part of the spacer the clip view shows: bounds origin = scroll offset, so
    /// everything below works in the spacer's coordinates.
    private func follow() {
        guard let clip = scrollView?.contentView else { return }
        if bounds.origin != clip.bounds.origin { setBoundsOrigin(clip.bounds.origin) }
        needsDisplay = true
    }

    /// The clip view's frame, from the scroll view's layout.
    func fit(_ rect: NSRect) {
        if frame != rect { frame = rect }
        placeRule()
        resize()
        follow()
    }

    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let next = hit(convert(event.locationInWindow, from: nil))?.0
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setZoom(_ value: CGFloat) {
        guard value != zoom else { return }
        zoom = value
        font = TextStyle.hexFont
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        rowHeight = (Size.Editor.line * value).rounded()
        placeRule()
        resize()
    }

    func reload() {
        pages.reset()
        caret = min(caret, max(pages.size - 1, 0))
        anchor = min(anchor, caret)
        resize()
        needsDisplay = true
        publish()
    }

    func close() {
        pages.onLoad = {}
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: Geometry

    private var rows: Int64 { max((pages.size + Int64(Size.Hex.bytesPerRow) - 1) / Int64(Size.Hex.bytesPerRow), 1) }

    /// Character columns: offset, gap, 16 × "XX " with an extra space after 8, gap, ASCII.
    private var hexColumn: Int { Size.Hex.offsetDigits + Size.Hex.columnGap }
    private var asciiColumn: Int { hexColumn + Size.Hex.bytesPerRow * 3 + 1 + Size.Hex.columnGap - 1 }
    private var columns: Int { asciiColumn + Size.Hex.bytesPerRow }

    private func x(ofColumn column: Int) -> CGFloat { Size.Hex.leading + CGFloat(column) * advance }

    private func hexColumn(of byte: Int) -> Int { hexColumn + byte * 3 + (byte >= Size.Hex.group ? 1 : 0) }

    private func resize() {
        let content = CGFloat(rows) * rowHeight + rowHeight  // the header row
        let width = x(ofColumn: columns) + Size.Hex.leading
        let height = min(content, Self.heightCap)
        let visible = scrollView?.contentSize ?? .zero
        let size = NSSize(width: max(width, visible.width), height: max(height, visible.height))
        if spacer.frame.size != size { spacer.setFrameSize(size) }
    }

    /// The (fractional) row at the top of the visible rows area.
    private var topRow: CGFloat {
        let visibleRows = max((visibleRect.height - rowHeight) / rowHeight, 1)
        let scrollable = max(spacer.frame.height - visibleRect.height, 1)
        let maxTop = max(CGFloat(rows) - visibleRows, 0)
        let fraction = min(max(visibleRect.minY / scrollable, 0), 1)
        return spacer.frame.height - visibleRect.height <= 0 ? 0 : fraction * maxTop
    }

    private func y(ofRow row: Int64) -> CGFloat {
        visibleRect.minY + rowHeight + (CGFloat(row) - topRow) * rowHeight
    }

    private func row(at y: CGFloat) -> Int64 {
        let row = Int64(floor(topRow + (y - visibleRect.minY - rowHeight) / rowHeight))
        return min(max(row, 0), rows - 1)
    }

    // MARK: Drawing

    /// Text and small fills only, on no ground of its own (the tab's shows through): a view
    /// that fills its whole area keeps a full bitmap of it, one that draws text keeps a fraction.
    override func draw(_ dirtyRect: NSRect) {
        let first = row(at: visibleRect.minY + rowHeight)
        let last = row(at: visibleRect.maxY)
        let selection = min(anchor, caret)...max(anchor, caret)
        if first <= last {
            // Rows scroll under the sticky header without showing through it.
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: visibleRect.minX, y: visibleRect.minY + rowHeight, width: visibleRect.width, height: visibleRect.height - rowHeight).clip()
            for row in first...last { draw(row: row, selection: selection) }
            NSGraphicsContext.restoreGraphicsState()
        }
        drawHeader()
        if !timed {
            timed = true
            RenderTiming.ready(HexRenderer.id)
        }
    }

    private func attributes(_ color: Color) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color.nsColor]
    }

    private func drawHeader() {
        let top = visibleRect.minY
        let header = attributes(Theme.Hex.header)
        for byte in 0..<Size.Hex.bytesPerRow {
            (String(format: "%02X", byte) as NSString).draw(at: NSPoint(x: x(ofColumn: hexColumn(of: byte)), y: top + baseline), withAttributes: header)
        }
        ("ASCII" as NSString).draw(at: NSPoint(x: x(ofColumn: asciiColumn), y: top + baseline), withAttributes: header)
    }

    /// The header's bottom rule: its own layer, so the drawing doesn't span the width.
    private func placeRule() {
        // The scroll view isn't flipped: the header's bottom is `rowHeight` below its top.
        rule.frame = NSRect(x: frame.minX, y: frame.maxY - rowHeight, width: frame.width, height: Stroke.hairline)
    }

    /// Text is drawn from the line's top plus this, so it sits centred in the row.
    private var baseline: CGFloat { (rowHeight - (font.ascender - font.descender)) / 2 }

    private func draw(row: Int64, selection: ClosedRange<Int64>) {
        let top = y(ofRow: row)
        let start = row * Int64(Size.Hex.bytesPerRow)
        (String(format: "%08llX", start) as NSString).draw(
            at: NSPoint(x: x(ofColumn: 0), y: top + baseline), withAttributes: attributes(Theme.Hex.offset))
        for byte in 0..<Size.Hex.bytesPerRow {
            let offset = start + Int64(byte)
            guard offset < pages.size else { break }
            let hexX = x(ofColumn: hexColumn(of: byte))
            let asciiX = x(ofColumn: asciiColumn + byte)
            if offset == hovered {
                Theme.Hex.hover.nsColor.setFill()
                NSRect(x: hexX, y: top, width: advance * 2, height: rowHeight).fill()
                NSRect(x: asciiX, y: top, width: advance, height: rowHeight).fill()
            }
            if selection.contains(offset) {
                Theme.Hex.selection.nsColor.setFill()
                // The fill runs into the space after a byte when the next one is selected too.
                let joins = selection.contains(offset + 1) && byte != Size.Hex.bytesPerRow - 1
                NSRect(x: hexX, y: top, width: advance * (joins ? (byte == Size.Hex.group - 1 ? 4 : 3) : 2), height: rowHeight).fill()
                NSRect(x: asciiX, y: top, width: advance, height: rowHeight).fill()
            }
            guard let value = pages.byte(at: offset) else { continue }
            (String(format: "%02X", value) as NSString).draw(
                at: NSPoint(x: hexX, y: top + baseline), withAttributes: attributes(value == 0 ? Theme.Hex.zero : Theme.Hex.byte))
            let printable = value >= 0x20 && value < 0x7F
            ((printable ? String(UnicodeScalar(value)) : ".") as NSString).draw(
                at: NSPoint(x: asciiX, y: top + baseline), withAttributes: attributes(printable ? Theme.Hex.ascii : Theme.Hex.zero))
        }
    }

    // MARK: Selection

    /// The byte under a point, and whether it's in the ASCII column; nil off the bytes.
    private func hit(_ point: NSPoint) -> (Int64, Bool)? {
        guard pages.size > 0, point.y > visibleRect.minY + rowHeight else { return nil }
        let row = row(at: point.y)
        let column = Int(floor((point.x - Size.Hex.leading) / advance))
        let byte: Int
        let ascii: Bool
        if column >= asciiColumn {
            byte = min(column - asciiColumn, Size.Hex.bytesPerRow - 1)
            ascii = true
        } else if column >= hexColumn {
            let within = column - hexColumn
            byte = min(within >= Size.Hex.group * 3 ? (within - 1) / 3 : within / 3, Size.Hex.bytesPerRow - 1)
            ascii = false
        } else {
            byte = 0
            ascii = inASCII
        }
        return (min(row * Int64(Size.Hex.bytesPerRow) + Int64(byte), pages.size - 1), ascii)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (offset, ascii) = hit(convert(event.locationInWindow, from: nil)) else { return }
        inASCII = ascii
        caret = offset
        if !event.modifierFlags.contains(.shift) { anchor = offset }
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let clip = scrollView?.contentView, clip.autoscroll(with: event) { scrollView?.reflectScrolledClipView(clip) }
        guard let (offset, _) = hit(point) else { return }
        caret = offset
        changed()
    }

    override func keyDown(with event: NSEvent) {
        guard pages.size > 0 else { return super.keyDown(with: event) }
        let row = Int64(Size.Hex.bytesPerRow)
        let page = Int64(max((visibleRect.height - rowHeight) / rowHeight - 1, 1)) * row
        let command = event.modifierFlags.contains(.command)
        let move: Int64?
        switch event.keyCode {
        case 123: move = command ? -(caret % row) : -1
        case 124: move = command ? row - 1 - caret % row : 1
        case 125: move = command ? pages.size : row
        case 126: move = command ? -pages.size : -row
        case 121: move = page
        case 116: move = -page
        case 115: move = -pages.size
        case 119: move = pages.size
        default: move = nil
        }
        guard let move else { return super.keyDown(with: event) }
        caret = min(max(caret + move, 0), pages.size - 1)
        if !event.modifierFlags.contains(.shift) { anchor = caret }
        changed()
        reveal(caret)
    }

    override func selectAll(_ sender: Any?) {
        anchor = 0
        caret = max(pages.size - 1, 0)
        changed()
    }

    @objc func copy(_ sender: Any?) {
        guard pages.size > 0 else { return }
        let low = min(anchor, caret)
        let high = min(max(anchor, caret) + 1, low + Self.copyCap)
        let data = pages.bytes(low..<high)
        let text =
            inASCII
            ? String(data.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            : data.map { String(format: "%02X", $0) }.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Scrolls just enough to show the byte's row.
    private func reveal(_ offset: Int64) {
        let target = offset / Int64(Size.Hex.bytesPerRow)
        let visibleRows = Int64(max((visibleRect.height - rowHeight) / rowHeight, 1))
        let top = Int64(topRow.rounded(.up))
        guard target < top || target >= top + visibleRows - 1 else { return }
        let newTop = target < top ? target : target - visibleRows + 2
        let maxTop = max(CGFloat(rows) - CGFloat(visibleRows), 1)
        let scrollable = max(spacer.frame.height - visibleRect.height, 0)
        let y = min(max(CGFloat(newTop) / maxTop * scrollable, 0), scrollable)
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: visibleRect.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func changed() {
        needsDisplay = true
        publish()
    }

    private func publish() {
        report(HexStatus(caret: Int(caret), selected: Int(abs(caret - anchor) + 1), size: pages.size))
    }
}

extension Color {
    @MainActor var nsColor: NSColor { NSColor(self) }
}

/// The last renderer: whatever doesn't decode as text and nothing else claimed.
enum HexRenderer: FileRenderer {
    static let id = "hex"
    static let hasRaw = false

    static func matches(_ file: FileInfo) -> Bool { !file.isText }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(HexView(file: file, context: context))
    }
}

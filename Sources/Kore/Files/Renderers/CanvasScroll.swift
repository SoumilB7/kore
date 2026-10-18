import AppKit

/// A scroll view over an empty document of `documentSize`, with a canvas on top that draws only
/// what's visible. The canvas is the size of the visible area whatever the document's size, so
/// a 100,000-row grid costs one screenful of drawing, and sticky parts (a header, a gutter)
/// are just drawn at the visible edge.
final class CanvasScrollView: NSScrollView {
    let canvas: CanvasView
    private let spacer = FlippedSpacer()

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        documentView = spacer
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        contentView.drawsBackground = false
        // Unclipped views get an overdraw layer the size of the scroll area (macOS 14+).
        clipsToBounds = true
        canvas.clipsToBounds = true
        canvas.scroller = self
        // Above the content, under the scrollers.
        addSubview(canvas, positioned: .above, relativeTo: contentView)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    var documentSize: NSSize {
        get { spacer.frame.size }
        set { if spacer.frame.size != newValue { spacer.frame.size = newValue } }
    }

    /// The visible part of the document.
    var visible: NSRect { contentView.bounds }

    func scroll(to point: NSPoint) {
        let maxX = max(0, documentSize.width - contentView.bounds.width)
        let maxY = max(0, documentSize.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: min(max(point.x, 0), maxX), y: min(max(point.y, 0), maxY)))
        reflectScrolledClipView(contentView)
    }

    /// Scrolls just enough to show `rect` (document coordinates), less what `inset` covers
    /// (sticky parts at the top and left).
    func reveal(_ rect: NSRect, inset: NSSize) {
        var origin = visible.origin
        let size = visible.size
        if rect.minX - inset.width < origin.x { origin.x = rect.minX - inset.width }
        if rect.maxX > origin.x + size.width { origin.x = rect.maxX - size.width }
        if rect.minY - inset.height < origin.y { origin.y = rect.minY - inset.height }
        if rect.maxY > origin.y + size.height { origin.y = rect.maxY - size.height }
        if origin != visible.origin { scroll(to: origin) }
    }

    override func tile() {
        super.tile()
        if canvas.frame != contentView.frame { canvas.frame = contentView.frame }
    }

    @objc private func scrolled() { canvas.needsDisplay = true }
}

/// What a `CanvasScrollView` draws. Points in `draw` are view points; add `offset` for the
/// document point under them.
class CanvasView: NSView {
    weak var scroller: CanvasScrollView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var offset: NSPoint { scroller?.visible.origin ?? .zero }

    /// Scrolling goes to the scroll view (the canvas sits outside its clip view).
    override func scrollWheel(with event: NSEvent) { scroller?.scrollWheel(with: event) }

    func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }
}

private final class FlippedSpacer: NSView {
    override var isFlipped: Bool { true }
}

import AppKit

/// A scroll view whose document is a `CanvasView` the size of the whole content, drawn only
/// where it's dirty. AppKit tiles a large document view and scrolls it without redrawing, as it
/// does the editor's text view, so a 100,000-row grid costs no more than a short one.
/// Sticky parts (a grid's header and row numbers) are the canvas's to place over it.
final class CanvasScrollView: NSScrollView {
    let canvas: CanvasView

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        documentView = canvas
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
    }

    required init?(coder: NSCoder) { fatalError() }

    /// At least the visible size, so the canvas paints the whole ground.
    var documentSize = NSSize.zero {
        didSet { fit() }
    }

    override func tile() {
        super.tile()
        fit()
        canvas.documentResized(canvas.frame.size)
    }

    private func fit() {
        let size = NSSize(
            width: max(documentSize.width, contentView.bounds.width),
            height: max(documentSize.height, contentView.bounds.height))
        if canvas.frame.size != size {
            canvas.frame.size = size
            canvas.documentResized(size)
        }
    }

    /// The visible part of the document.
    var visible: NSRect { contentView.bounds }

    func scroll(to point: NSPoint) {
        let maxX = max(0, canvas.frame.width - contentView.bounds.width)
        let maxY = max(0, canvas.frame.height - contentView.bounds.height)
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
}

/// A `CanvasScrollView`'s document: points are document points. It draws no ground of its own
/// (the tab's is behind it): a view that fills its whole area keeps a full bitmap of it, while
/// one that draws only text and lines keeps a fraction (18.7 MB against 2.1 MB for a 1000×700
/// tab).
class CanvasView: NSView {
    weak var scroller: CanvasScrollView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The document or the visible area changed size (sticky parts follow).
    func documentResized(_ size: NSSize) {}

    func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    var visible: NSRect { scroller?.visible ?? visibleRect }
}

import AppKit
import SwiftUI

/// A long message opened a little (look.md §15): its box grows to `openedLines` at most and the
/// text scrolls inside it, in a text view of its own, so ⌘A takes just this message and ⌘C copies
/// it. Only an opened message has one; every other message is a plain `Text`. Escape, a click
/// outside its box, or its toggle closes it.
struct OpenedMessageText: NSViewRepresentable {
    let text: String
    var color = Theme.text
    /// Takes the keys as it opens: the open that a click asked for (`opening`), not a row built
    /// again while it's open.
    let key: String
    /// Its box, global: a press inside it isn't a press elsewhere.
    let box: Held<CGRect>
    let close: () -> Void

    /// The message a click just opened, until its text view takes the keys.
    @MainActor static var opening: String?

    func makeNSView(context: Context) -> OpenedMessageView {
        let view = OpenedMessageView()
        view.key = key
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: OpenedMessageView, context: Context) {
        view.box = box
        view.close = close
        view.show(text, color: NSColor(color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OpenedMessageView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 1 else { return nil }
        return CGSize(width: width, height: nsView.fittingHeight(width: width))
    }

    static func dismantleNSView(_ view: OpenedMessageView, coordinator: ()) { view.closeDown() }
}

/// The opened message's scroll view and text: read-only, selectable, scrolling past `openedLines`.
final class OpenedMessageView: NSScrollView {
    /// TextKit 1, as the composer's: exact line heights, and only the lines asked for laid out.
    let textView = OpenedTextView(usingTextLayoutManager: false)
    var box = Held(CGRect.zero)
    var close: () -> Void = {}
    /// Its message's `OpenedMessageText.key`.
    var key = ""
    /// What had the keys before it took them, to have them back when it closes.
    private weak var before: NSResponder?
    private var monitor: Any?
    private var zoom: CGFloat = 0
    /// Closing, or gone: a second ask (the press outside, then the keys leaving) does nothing.
    private var closing = false

    init() {
        super.init(frame: .zero)
        let text = textView
        text.close = { [weak self] in self?.closeSoon() }
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.usesFontPanel = false
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.selectedTextAttributes = [.backgroundColor: NSColor(Theme.Selection.active)]
        text.unregisterDraggedTypes()
        documentView = text
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        // Inside the transcript, not under the title bar: no inset of the window's.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        contentView.automaticallyAdjustsContentInsets = false
        drawsBackground = false
        contentView.drawsBackground = false
        // Its clip's moves aren't the transcript's: SwiftUI's lazy stack took them for its own
        // scroll, and a jump to the end after one built no rows there (a blank transcript).
        contentView.postsBoundsChangedNotifications = false
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { nil }

    func show(_ string: String, color: NSColor) {
        let scale = Zoom.shared.scale
        guard string != textView.string || scale != zoom || textView.textColor != color else { return }
        zoom = scale
        textView.textStorage?.setAttributedString(SelectionStyle.body.attributed(AttributedString(string), zoom: scale))
        textView.textColor = color
        invalidateIntrinsicContentSize()
    }

    /// The text's height at `width`, up to `openedLines`; only that much is laid out for it.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let line = MessageText.lineHeight
        let cap = (line * CGFloat(Layout.Timeline.openedLines)).rounded(.up)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return cap }
        if abs(container.size.width - width) > 0.5 { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: width, height: cap + line), in: container)
        return min(cap, layout.usedRect(for: container).height.rounded(.up))
    }

    /// A turn of the wheel moves the text while it can, then the transcript. Inside the
    /// transcript's own scroll view AppKit leaves a turn here unread; the text is at most
    /// `openedLines` tall, so moving it by hand costs nothing.
    override func scrollWheel(with event: NSEvent) {
        guard let document = documentView, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return super.scrollWheel(with: event) }
        let clip = contentView
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * MessageText.lineHeight
        let (low, high) = (document.frame.minY, max(document.frame.minY, document.frame.maxY - clip.bounds.height))
        let y = min(max(clip.bounds.minY - step, low), high)
        guard abs(y - clip.bounds.minY) > 0.1 else { return super.scrollWheel(with: event) }
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        reflectScrolledClipView(clip)
        flashScrollers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The one the click opened takes the keys, once it's in the window (SwiftUI can make a
        // view to measure that never gets there).
        if OpenedMessageText.opening == key {
            OpenedMessageText.opening = nil
            before = window.firstResponder
            window.makeFirstResponder(textView)
        }
        guard monitor == nil else { return }
        // A press anywhere outside its box closes it, once the press has gone where it was going.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let content = window.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !self.box.value.contains(point) { self.closeSoon() }
            return event
        }
    }

    /// Closes it once what set it off (a press, a key) has gone where it was going.
    func closeSoon() {
        guard !closing else { return }
        closing = true
        DispatchQueue.main.async { [close] in close() }
    }

    /// Gone from the transcript: the monitor goes, and the keys go back where they were.
    func closeDown() {
        closing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let window, window.firstResponder === textView else { return }
        // After SwiftUI's update that took it away, not inside it.
        let before = before
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            if let before, (before as? NSView)?.window === window { window.makeFirstResponder(before) } else { window.makeFirstResponder(nil) }
        }
    }
}

/// The opened message's text: Escape closes it, as do the keys going elsewhere (a press on the
/// transcript's text or the composer, which a press monitor can't see past the transcript's
/// own). ⌘C copies to the transcript's pasteboard (a named one under storylines).
final class OpenedTextView: NSTextView {
    var close: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { close() }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        close()
        return true
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let board = TranscriptSelection.pasteboard
        board.clearContents()
        board.setString((string as NSString).substring(with: range), forType: .string)
    }

    // The transcript's own text menu, not AppKit's.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

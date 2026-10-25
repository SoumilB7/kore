import AppKit
import SwiftUI

/// The composer's text: an AppKit text view in a scroll view of its own. It grows with its
/// text to `Layout.composerLines` lines, then scrolls (wheel, trackpad, an overlay scroller), and
/// a click anywhere in it puts the caret there. SwiftUI's vertical text field can't: its field
/// editor sits in a clip view with no scroll view, so the hidden lines could only be reached
/// with the arrow keys.
///
/// It holds no draft of its own: `text` is the chat's draft, and every edit goes straight back
/// through `changed`. The keys the composer gives a meaning (Return, Tab, Esc, ↑ ↓, Backspace at
/// the start) come to `command` as the text view's own commands, after an input method has had
/// its say, so marked text keeps them.
struct ComposerText: NSViewRepresentable {
    /// The chat whose draft this is: another one's starts the undo over.
    let chat: UUID
    let text: String
    let font: NSFont
    /// A caret Kore placed in `placed.text`: put in the view once, when it shows that text.
    let placed: Placed?
    let editor: ComposerEditor
    let changed: (String) -> Void
    /// A command the text view is about to perform (`insertNewline:`, `moveUp:` …): true when
    /// the composer took it.
    let command: (ComposerTextView, Selector) -> Bool

    struct Placed: Equatable {
        let chat: UUID
        let range: NSRange
        let text: String
        /// Each placing is new, even at the same place.
        let serial: Int
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView(font: font)
        scroll.textView.delegate = context.coordinator
        context.coordinator.view = scroll.textView
        editor.view = scroll.textView
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.changed = changed
        coordinator.command = command
        editor.view = scroll.textView
        editor.undo = coordinator.undo
        let view = scroll.textView
        if view.font != font { scroll.setFont(font) }
        let enabled = context.environment.isEnabled
        if view.isEditable != enabled {
            view.isEditable = enabled
            view.isSelectable = enabled
        }
        if coordinator.chat != chat {
            coordinator.chat = chat
            coordinator.undo.removeAllActions()
        }
        // Set from outside (a send, a fork, a pick, another chat): the view takes it, and its
        // undo, made for the text it had, starts over. Never over an input method's marked text.
        if text != view.shown, !view.hasMarkedText() {
            view.string = text
            view.shown = text
            coordinator.undo.removeAllActions()
            view.breakUndoCoalescing()
        }
        if let placed, placed.serial != coordinator.serial, placed.chat == chat, placed.text == text, view.shown == text {
            coordinator.serial = placed.serial
            let length = (text as NSString).length
            let location = min(max(placed.range.location, 0), length)
            let range = NSRange(location: location, length: min(max(placed.range.length, 0), length - location))
            view.setSelectedRange(range)
            // After this layout pass, when the box has its new height; the caret then, as the
            // text may have changed by then and a range outside it raises.
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.scrollRangeToVisible(view.selectedRange())
            }
        }
    }

    /// Its text's height up to the cap, at the width offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: nsView.fittingHeight(width: width))
    }

    static func dismantleNSView(_ nsView: ComposerScrollView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
    }

    /// Where the first line's baseline is, from the view's top: the command chip lines up on it.
    @MainActor static func baseline(_ font: NSFont) -> CGFloat {
        ComposerScrollView.measure.defaultBaselineOffset(for: font)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: ComposerTextView?
        var changed: (String) -> Void = { _ in }
        var command: (ComposerTextView, Selector) -> Bool = { _, _ in false }
        var chat: UUID?
        var serial = -1
        /// The composer's own, not the window's (the explorer's file moves use that one).
        let undo = UndoManager()

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            let text = view.copiedText()
            view.shown = text
            changed(text)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let textView = textView as? ComposerTextView else { return false }
            return command(textView, selector)
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}

/// The text view, keeping the key it's handling: what a command came from (Return with ⇧ or ⌥
/// held is a new line, not a send).
final class ComposerTextView: NSTextView {
    private(set) var key: NSEvent?
    /// What it holds, as last set or typed, as a Swift string of its own: the draft shares it, so
    /// comparing the two costs nothing, where `string` is the text storage's, bridged, and each
    /// read of it walks the whole text.
    var shown = ""

    /// The text, copied out whole as UTF-16 in one call: a long draft's copy costs well under a
    /// millisecond, where a Swift string's own conversion of `string` costs many.
    func copiedText() -> String {
        guard let storage = textStorage else { return string }
        let text = storage.string as NSString
        let length = text.length
        guard length > 0 else { return "" }
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: length) { buffer in
            guard let base = buffer.baseAddress else { return storage.string }
            text.getCharacters(base, range: NSRange(location: 0, length: length))
            return String(decoding: buffer, as: UTF16.self)
        }
    }

    override func keyDown(with event: NSEvent) {
        key = event
        defer { key = nil }
        super.keyDown(with: event)
    }
}

/// The composer's text view and its undo, for the composer's own reads (the caret, the
/// keys' state) outside SwiftUI's updates. Never shown, so setting it draws nothing.
@MainActor
final class ComposerEditor: ObservableObject {
    weak var view: ComposerTextView?
    weak var undo: UndoManager?

    /// A click beside the text, on the box's padding: the caret goes where the nearest line is
    /// nearest the click (below the last line, its end; left of a line, its start), as a click
    /// in the text would put it.
    func placeCaret(at windowPoint: NSPoint) {
        guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
        // In the box, the text view took the click itself (its press put the caret): placing it
        // again on the release would move it.
        if let box = view.enclosingScrollView, box.bounds.contains(box.convert(windowPoint, from: nil)) { return }
        let local = view.convert(windowPoint, from: nil)
        // Laid out only as far as drawn (non-contiguous): what is in sight, at least, for its rect.
        layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
        let used = layout.usedRect(for: container)
        let point = NSPoint(
            x: min(max(local.x, used.minX), used.maxX),
            y: min(max(local.y, used.minY + 1), max(used.maxY - 1, used.minY + 1)))
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let length = (view.string as NSString).length
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: min(index + (fraction > 0.5 ? 1 : 0), length), length: 0))
    }
}

/// The text view's scroll view. A wheel or trackpad scroll over it moves its text; the
/// transcript is beside it, not around it, so never moves with it. (`scrollWheel` isn't
/// overridden: that would cost the scroll view AppKit's responsive scrolling.)
final class ComposerScrollView: NSScrollView {
    let textView: ComposerTextView
    private(set) var lineHeight: CGFloat

    /// Measures fonts' line heights and baselines; holds no text.
    static let measure = NSLayoutManager()

    init(font: NSFont) {
        // TextKit 1: its line heights are exact (TextKit 2 estimates the text it hasn't laid
        // out), and with non-contiguous layout it lays out only what's asked for, so the height
        // of a long draft costs the box's ten lines, not the whole text.
        let text = ComposerTextView(usingTextLayoutManager: false)
        textView = text
        lineHeight = Self.measure.defaultLineHeight(for: font)
        super.init(frame: .zero)
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.usesFontPanel = false
        text.drawsBackground = false
        text.textColor = NSColor(Theme.text)
        text.insertionPointColor = NSColor(Theme.accent)
        text.font = font
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        // Files dropped on the box attach (the box's drop); the text takes none itself.
        text.unregisterDraggedTypes()
        text.clipsToBounds = true
        clipsToBounds = true
        documentView = text
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        // A box that fits its text doesn't bounce under a scroll.
        verticalScrollElasticity = .none
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { nil }

    func setFont(_ font: NSFont) {
        textView.font = font
        lineHeight = Self.measure.defaultLineHeight(for: font)
    }

    /// The text's height at `width`, between one line and the cap. Only the lines up to the cap
    /// are laid out for it.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let cap = (lineHeight * Layout.composerLines).rounded(.up)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return lineHeight }
        let measured = width.isFinite && width > 1 ? width : container.size.width
        guard measured.isFinite, measured > 1 else { return lineHeight }
        if abs(container.size.width - measured) > 0.5 {
            container.size = NSSize(width: measured, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: measured, height: cap + lineHeight), in: container)
        let used = layout.usedRect(for: container).height
        return min(max(used, lineHeight), cap).rounded(.up)
    }

    /// A click in the box but off the text view (under its last line, before the text view has
    /// grown to the box, on the clip view or AppKit's views in it) is the text view's: it puts the caret at the nearest point of the text,
    /// where the clip view would take it and do nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The clip view, or AppKit's own views in it (its overhang view), never the scrollers.
        return hit.isDescendant(of: contentView) && !hit.isDescendant(of: textView) ? textView : hit
    }

    /// The box grew or shrank with its text: the caret stays in sight (after a paste, the end
    /// of what was pasted).
    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        // The text fills the box, so a click below its last line still lands in it.
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        if abs(old.height - newSize.height) > 0.5, window?.firstResponder === textView {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        // A new width wraps the text into more lines or fewer: the box's height is asked again
        // for it, or it keeps the last width's (lines under the box, or empty ones in it).
        if abs(old.width - newSize.width) > 0.5, abs(fittingHeight(width: newSize.width) - newSize.height) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }
}

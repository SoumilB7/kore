import AppKit
import SwiftUI

// How the transcript's rows take part in its one selection (TranscriptSelection): the timeline
// hands down the selection, each selectable row its entry, and each of its texts reports its
// frame. A press, drag, ⌘C or ⌘A goes to the responder view at the corner of the rows.

private struct TranscriptSelectionKey: EnvironmentKey {
    static let defaultValue: TranscriptSelection? = nil
}

private struct SelectionEntryKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The selection of the transcript a view is in; nil outside one.
    var transcriptSelection: TranscriptSelection? {
        get { self[TranscriptSelectionKey.self] }
        set { self[TranscriptSelectionKey.self] = newValue }
    }

    /// The entry of the transcript row a view is in, when its texts are selectable.
    var selectionEntry: UUID? {
        get { self[SelectionEntryKey.self] }
        set { self[SelectionEntryKey.self] = newValue }
    }
}

extension View {
    /// A transcript row whose texts take part in the selection: they report under `entry`, and
    /// the row draws its part of the selection over itself.
    func selectionRow(_ entry: UUID) -> some View { modifier(SelectionRow(entry: entry)) }

    /// A text of a selectable row, at `path` among the row's texts, showing `text` set in
    /// `style`. Outside a selectable row (a file preview, a pinned message, a closed tool box)
    /// it's selectable on its own once the pointer reaches it, as before.
    func selectableText(_ path: [Int], _ text: AttributedString, _ style: SelectionStyle, enabled: Bool = true) -> some View {
        modifier(SelectableText(path: path, text: text, style: style, enabled: enabled))
    }

    func selectableText(_ path: [Int], _ text: String, _ style: SelectionStyle, enabled: Bool = true) -> some View {
        modifier(SelectableText(path: path, text: AttributedString(text), style: style, enabled: enabled))
    }
}

private struct SelectionRow: ViewModifier {
    let entry: UUID
    @Environment(\.transcriptSelection) private var selection

    func body(content: Content) -> some View {
        if let selection {
            content
                .environment(\.selectionEntry, entry)
                .overlay { SelectionHighlight(entry: entry, selection: selection) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptSelection.space)) } action: {
                    selection.rowMoved(entry, $0)
                }
                .onAppear { selection.rowAppeared(entry) }
                .onDisappear { selection.rowLeft(entry) }
        } else {
            content
        }
    }
}

private struct SelectableText: ViewModifier {
    let path: [Int]
    let text: AttributedString
    let style: SelectionStyle
    let enabled: Bool
    @Environment(\.transcriptSelection) private var selection
    @Environment(\.selectionEntry) private var entry

    func body(content: Content) -> some View {
        if enabled, let selection, let entry {
            let (path, text, style) = (path, text, style)
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptSelection.space)) } action: {
                selection.textMoved(entry, path, SelectionSlot(frame: $0, text: text, style: style))
            }
        } else {
            content.selectableOnHover()
        }
    }
}

/// A row's part of the selection, in the system's selection colour. Kore's text is light on a
/// dark ground, so the fill is lightened in, not laid over: the ground and fills under it take
/// the selection's colour, and the lighter text stays as it was.
private struct SelectionHighlight: View {
    let entry: UUID
    @ObservedObject var selection: TranscriptSelection

    var body: some View {
        let rects = selection.rects(entry)
        if rects.isEmpty {
            Color.clear.allowsHitTesting(false)
        } else {
            let color = selection.active ? Theme.Selection.active : Theme.Selection.inactive
            Canvas { context, _ in
                for rect in rects { context.fill(Path(rect), with: .color(color)) }
            }
            .blendMode(.lighten)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The transcript's place in the responder chain and its pointer handling: a point at the top
/// corner of its content, so its coordinates are the rows' content space.
struct SelectionResponder: NSViewRepresentable {
    let selection: TranscriptSelection
    /// The chat's tab is hidden under the active one: it takes no presses.
    let hidden: Bool
    /// Where its links open (the chat's window).
    var openLink: ((URL) -> Void)?
    /// The chat's folder, for its links' relative paths.
    var folder: URL?
    /// A preview can take a pending keyboard request once its responder actually mounts.
    var onReady: ((SelectionResponderView) -> Void)?

    func makeNSView(context: Context) -> SelectionResponderView {
        let view = SelectionResponderView()
        view.selection = selection
        view.hiddenTab = hidden
        view.onReady = onReady
        selection.openLink = openLink
        selection.folder = folder
        return view
    }

    func updateNSView(_ view: SelectionResponderView, context: Context) {
        view.selection = selection
        view.hiddenTab = hidden
        view.onReady = onReady
        selection.openLink = openLink
        selection.folder = folder
        view.notifyReady()
    }
}

/// Watches the window's presses (an event monitor, as a text view tracks its own): a press on
/// text selects there (a caret, a word, a paragraph, or extends with ⇧) and a drag carries the
/// selection on, scrolling at the edges. A press elsewhere in the transcript goes to the rows
/// (buttons, folds, links) and becomes a selection only once it drags. Presses on what floats
/// over the transcript (the composer, a pinned message) are left alone.
final class SelectionResponderView: NSView, NSMenuItemValidation {
    weak var selection: TranscriptSelection? {
        didSet { selection?.responder = self }
    }
    var hiddenTab = false
    var onReady: ((SelectionResponderView) -> Void)?

    func notifyReady() {
        guard window != nil, !hiddenTab else { return }
        onReady?(self)
    }

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?

    /// The press being followed: where it went down, whether it was on text (consumed) or let
    /// through to the rows, and whether it has dragged.
    private struct Press {
        let start: CGPoint
        let onText: Bool
        let clicks: Int
        var dragging: Bool
        var event: NSEvent
    }

    private var press: Press?
    private var autoscroll: Timer?
    private var iBeam = false
    /// When the last press this view took (consumed) went down.
    private var takenAt: TimeInterval = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let tracking { tracked?.removeTrackingArea(tracking) }
        tracking = nil
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActive() }
                })
        }
        updateActive()
        DispatchQueue.main.async { [weak self] in self?.track() }
        notifyReady()
    }

    /// The I-beam over text comes from a tracking area on the transcript's clip view (this view
    /// is a point at the content's corner: a view as tall as the content cost scrolling).
    private func track() {
        if let tracking { tracked?.removeTrackingArea(tracking) }
        tracking = nil
        guard let clip = enclosingScrollView?.contentView else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        clip.addTrackingArea(area)
        tracking = area
        tracked = clip
    }

    private weak var tracked: NSView?

    override func becomeFirstResponder() -> Bool {
        defer { updateActive() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.updateActive() } }
        return true
    }

    private func updateActive() {
        let active = window?.firstResponder === self && window?.isKeyWindow == true
        if selection?.active != active { selection?.active = active }
    }

    // MARK: Pointer

    /// The content-space point of an event in this window.
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// Whether a press at this event is the transcript's: inside its scroll view, on nothing
    /// floating over it.
    private func isTranscript(_ event: NSEvent) -> Bool {
        guard !hiddenTab, event.window === window, let window, let content = window.contentView, let scroll = enclosingScrollView,
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
            hit.isDescendant(of: scroll)
        else { return false }
        return selection?.isBlocked(point(event)) != true
    }

    /// AppKit text views inside the transcript (a diff's own selection) keep their presses.
    private func isOwnText(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView,
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return false }
        return hit is NSText || String(describing: type(of: hit)).contains("Selection")
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let selection else { return event }
        // A press handled here can come again from the event queue, re-sent as it was (seen
        // with a double click on a window that isn't key): it's the same press, already taken.
        if [.leftMouseDown, .leftMouseUp].contains(event.type), event.timestamp <= takenAt { return nil }
        switch event.type {
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) { return showCopyMenu(event) ? nil : event }
            stopAutoscroll()
            press = nil
            guard isTranscript(event) else { return event }
            let p = point(event)
            if selection.text(at: p) != nil {
                window?.makeFirstResponder(self)
                selection.press(at: p, clicks: event.clickCount, extend: event.modifierFlags.contains(.shift))
                press = Press(start: p, onText: true, clicks: event.clickCount, dragging: false, event: event)
                takenAt = event.timestamp
                return nil
            }
            if isOwnText(event) { return event }
            press = Press(start: p, onText: false, clicks: event.clickCount, dragging: false, event: event)
            return event
        case .leftMouseDragged:
            guard var current = press, event.window === window else { return event }
            let p = point(event)
            if !current.dragging {
                guard hypot(p.x - current.start.x, p.y - current.start.y) > Layout.Selection.dragStart else {
                    return current.onText ? nil : event
                }
                current.dragging = true
                if !current.onText {
                    window?.makeFirstResponder(self)
                    selection.begin(at: current.start)
                }
            }
            current.event = event
            press = current
            selection.extend(to: p)
            followEdge(event)
            return nil
        case .leftMouseUp:
            guard let done = press, event.window === window else { return event }
            press = nil
            stopAutoscroll()
            if done.onText {
                // Taken, like its press: the same release sent again (a window that isn't key)
                // would open the link a second time.
                takenAt = event.timestamp
                // A click on a link that didn't drag opens it.
                if !done.dragging, done.clicks == 1, !event.modifierFlags.contains(.shift), let url = selection.link(at: point(event)) {
                    selection.open(url)
                }
                return nil
            }
            if done.dragging {
                // The rows had the press: they get a release far outside, so no tap or button fires.
                return Self.releaseOutside(event)
            }
            // A click on the transcript away from text clears the selection, as in a browser.
            selection.clear()
            return event
        case .rightMouseDown:
            return showCopyMenu(event) ? nil : event
        default:
            return event
        }
    }

    private func showCopyMenu(_ event: NSEvent) -> Bool {
        guard let selection, isTranscript(event), let window else { return false }
        guard selection.hasSelection, let (entry, path) = selection.text(at: point(event)), selection.selected(entry, path) != nil else {
            return showFileMenu(event)
        }
        OptionsMenu.shared.show([OptionItem("Copy") { [weak self] in self?.copy(nil) }],
                                at: event.locationInWindow, in: window, source: "selection")
        return true
    }

    /// A right-click on a link to a file that's there: its menu (`MediaMenu`).
    private func showFileMenu(_ event: NSEvent) -> Bool {
        guard let selection, isTranscript(event), let window, let url = selection.link(at: point(event)),
              let items = selection.fileMenu(url) else { return false }
        OptionsMenu.shared.show(items, at: event.locationInWindow, in: window, source: "file-link")
        return true
    }

    private static func releaseOutside(_ event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: -100_000, y: -100_000), modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.clickCount, pressure: 0) ?? event
    }

    /// Past the transcript's visible edge (under the title bar counts as past it): scroll that
    /// way, faster the further out, now and on a timer while the pointer stays there.
    private func followEdge(_ event: NSEvent) {
        guard edgeDistance(event) != 0 else { return stopAutoscroll() }
        scrollTowardsPointer(event)
        guard autoscroll == nil else { return }
        autoscroll = Timer.scheduledTimer(withTimeInterval: Layout.Selection.autoscrollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let press = self.press, self.edgeDistance(press.event) != 0 else { return self?.stopAutoscroll() ?? () }
                self.scrollTowardsPointer(press.event)
            }
        }
    }

    /// How far past the visible top (negative) or bottom (positive) the pointer is, in points.
    private func edgeDistance(_ event: NSEvent) -> CGFloat {
        guard let scroll = enclosingScrollView else { return 0 }
        let frame = scroll.convert(scroll.bounds, to: nil)
        let (top, bottom) = (frame.maxY - scroll.contentInsets.top, frame.minY + scroll.contentInsets.bottom)
        let y = event.locationInWindow.y
        return y > top ? -(y - top) : y < bottom ? bottom - y : 0
    }

    private func scrollTowardsPointer(_ event: NSEvent) {
        guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let distance = edgeDistance(event)
        let step = min(max(abs(distance), Layout.Selection.autoscrollMin), Layout.Selection.autoscrollMax) * (distance < 0 ? -1 : 1)
        let clip = scroll.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        let minY = -scroll.contentInsets.top
        let y = min(max(clip.bounds.origin.y + (document.isFlipped ? step : -step), minY), maxY)
        guard abs(y - clip.bounds.origin.y) > 0.1 else { return }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        selection?.extend(to: point(event))
    }

    private func stopAutoscroll() {
        autoscroll?.invalidate()
        autoscroll = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard !hiddenTab, let selection else { return }
        let over = selection.text(at: point(event)) != nil && !selection.isBlocked(point(event)) && isTranscript(event)
        if over {
            NSCursor.iBeam.set()
        } else if iBeam {
            NSCursor.arrow.set()
        }
        iBeam = over
    }

    override func mouseExited(with event: NSEvent) {
        if iBeam { NSCursor.arrow.set() }
        iBeam = false
    }

    // MARK: Commands

    @objc func copy(_ sender: Any?) { selection?.copy() }

    override func selectAll(_ sender: Any?) {
        selection?.selectAll()
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: "Selected the conversation", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    override func cancelOperation(_ sender: Any?) { selection?.clear() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selection?.clear() } else { super.keyDown(with: event) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selection?.hasSelection == true
        case #selector(selectAll(_:)): true
        default: false
        }
    }
}

import AppKit
import SwiftUI

/// The scroll view a timeline's content is in, found from inside it (`ScrollShift.Finder` in its
/// background), so a page going in above moves the view down by exactly what it added, at once.
/// Through `ScrollPosition` the move lands an update later, and whatever the reader scrolled in
/// between is lost.
@MainActor
final class ScrollShift: ObservableObject {
    private static let known = NSMapTable<NSScrollView, ScrollShift>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    fileprivate weak var scrollView: NSScrollView?
    /// Called when its window comes back into view or to the front.
    var onReturn: (() -> Void)?
    /// A single absolute position replaces any retained edge/row scroll target at pinch begin.
    /// Given the native clip origin the pinch began at.
    var onZoomBegin: ((CGPoint) -> Void)?
    var onZoomEnd: ((Bool) -> Void)?
    var onZoomInput: (() -> Void)?
    /// Whether the page is magnified now.
    var onMagnified: ((Bool) -> Void)?
    /// A file preview's column takes a pinch as the transcript does. The transcript is found by
    /// its selection responder instead, which knows when its tab is hidden.
    var pinches = false

    func attach(_ scroll: NSScrollView) {
        if let old = scrollView, Self.known.object(forKey: old) === self { Self.known.removeObject(forKey: old) }
        release()
        scrollView = scroll
        Self.known.setObject(self, forKey: scroll)
        Self.watchInput()
        liveObservers.forEach(NotificationCenter.default.removeObserver)
        // A live scroll is the reader's: the trackpad, the wheel's momentum, the scroller dragged.
        liveObservers = [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: scroll, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readerInput()
                    self?.claim()
                }
            }
        }
        seenY = scroll.contentView.bounds.minY
        scroll.contentView.postsBoundsChangedNotifications = true
        liveObservers.append(
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipMoved() }
            })
        if ScrollLog.on { watchClip(scroll) }
    }

    // MARK: SwiftUI's target, aimed at once more

    /// SwiftUI keeps a `scrollTo`'s target past its landing, and aims at it once more as it takes
    /// up the first move after it: the reader's, undone (a wheel's notch, a page, a whole drag of
    /// the scroll bar lost). From a scroll of Kore's (`aim`) till the reader's first moves are
    /// taken up, their move is put back on the place aimed at, in the same pass.
    private var aimed = false
    /// The reader's moves since: from where, to where, and when the first was made.
    private var reader: (from: CGFloat, to: CGFloat, at: Date)?
    /// The clip's last move, till the reader's input claims it (AppKit says so after the move).
    private var change: (from: CGFloat, to: CGFloat)?
    /// The reader's input said before its move (a wheel without phases, a key): it claims the
    /// next move until then.
    private var due = Date.distantPast
    /// Where SwiftUI has the view (its geometry) against the reader's move, before AppKit's clip
    /// is taken there.
    private var aiming: CGFloat?
    private var seenY: CGFloat?
    private var ours = false
    /// Whether the reader's move by this much stays: not one within a followed end's slack.
    var readerKeeps: ((CGFloat) -> Bool)?
    /// The reader moved the view by this much.
    var onReaderMoved: ((CGFloat) -> Void)?
    private static let takenUp: TimeInterval = 0.5

    /// A scroll of Kore's goes through SwiftUI now.
    func aim() {
        aimed = true
        (reader, change, aiming) = (nil, nil, nil)
    }

    private func claim() {
        guard let change else { return }
        self.change = nil
        claim(change)
    }

    private func claim(_ move: (from: CGFloat, to: CGFloat)) {
        onReaderMoved?(move.to - move.from)
        guard aimed else { return }
        if let reader, abs(reader.to - move.from) < 1.5 {
            self.reader?.to = move.to
        } else {
            reader = (move.from, move.to, Date())
        }
    }

    private func clipMoved() {
        guard let clip = scrollView?.contentView else { return }
        let y = clip.bounds.minY
        let was = seenY ?? y
        seenY = y
        guard abs(y - was) > 0.5, !ours, !holding, !zoomAdjusting else { return }
        if Date() < due {
            due = .distantPast
            return claim((was, y))
        }
        guard aimed, let reader else {
            change = (was, y)
            return
        }
        guard Date() < reader.at + Self.takenUp else {
            aimed = false
            return
        }
        let by = reader.to - reader.from
        guard abs(y - reader.from) < 1.5 || aiming.map({ abs(y - $0) < 1.5 }) ?? false, abs(by) > 1, readerKeeps?(by) ?? false else {
            change = (was, y)
            return
        }
        aimed = false
        ScrollLog.write("reader-kept", "by=\(ScrollLog.d(by)) from=\(ScrollLog.n(y))")
        _ = self(by)
    }

    /// SwiftUI's geometry has the view at `offset`: against the reader's move and not where
    /// AppKit's clip is, it's aiming at the target again.
    func laidOut(at offset: CGFloat) {
        guard aimed, let reader, let clip = scrollView?.contentView.bounds.minY, abs(offset - clip) > 1.5 else { return }
        let by = reader.to - reader.from
        guard (offset - reader.to) * by < 0, abs(offset - reader.to) >= abs(by) / 2 else { return }
        aiming = offset
    }

    // MARK: The scroll log (`ScrollLog`)

    private var clipSeen: (y: CGFloat, doc: CGFloat)?

    /// Every move of the clip and every new document height, whoever made it.
    private func watchClip(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        ScrollLog.write("attach", "doc=\(ScrollLog.n(scroll.documentView?.frame.height ?? 0)) y=\(ScrollLog.n(clip.bounds.minY))")
        clipSeen = nil
        let names: [(NSView?, Notification.Name)] = [(clip, NSView.boundsDidChangeNotification), (scroll.documentView, NSView.frameDidChangeNotification)]
        for (view, name) in names {
            guard let view else { continue }
            liveObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.logClip() }
                })
        }
    }

    private func logClip() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let y = scroll.contentView.bounds.minY
        let doc = document.frame.height
        let was = clipSeen
        clipSeen = (y, doc)
        guard abs(y - (was?.y ?? .nan)) > 0.5 || abs(doc - (was?.doc ?? .nan)) > 0.5 else { return }
        ScrollLog.write(
            "clip",
            "y=\(ScrollLog.n(y)) dy=\(ScrollLog.d(y - (was?.y ?? y))) doc=\(ScrollLog.n(doc)) ddoc=\(ScrollLog.d(doc - (was?.doc ?? doc))) in=\(readerInputs)"
                + (holding ? " by=hold" : ""))
    }

    // MARK: The reader's own input

    /// The reader's own moves of this view, counted: a live scroll (the trackpad, the scroller
    /// dragged), a wheel turn over it, a click on its scroller, a key that scrolls it while it
    /// has the keyboard. Only those leave the end by moving it (`TranscriptTimeline`): layout, the
    /// lazy stack measuring rows and SwiftUI settling a scroll of ours move the view too, in
    /// passes of their own. Kore's own moves away from it (a jump, a reveal) drop the end as
    /// they're made.
    private(set) var readerInputs = 0
    func readerInput() { readerInputs &+= 1 }
    private var liveObservers: [NSObjectProtocol] = []

    isolated deinit { liveObservers.forEach(NotificationCenter.default.removeObserver) }

    /// A move of `scroll` made for the reader (the navigation bench's, standing in for the scroll bar).
    static func readerMoved(_ scroll: NSScrollView) { known.object(forKey: scroll)?.inputDue() }

    /// The reader's input, its move still to come.
    private func inputDue() {
        readerInput()
        due = Date() + 0.1
    }

    private static var inputMonitor: Any?
    /// Home, Page Up, End, Page Down, ↓, ↑, space: keys a scroll view takes to move.
    private static let movingKeys: Set<UInt16> = [115, 116, 119, 121, 125, 126, 49]

    /// One monitor for the app, as events come in (nothing per frame).
    private static func watchInput() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated { route(event) }
            return event
        }
    }

    /// A wheel with no phases counts each turn; a gesture once, as it begins (its live scroll
    /// counts the rest).
    static func countsWheel(_ phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        phase.isEmpty && momentum.isEmpty || phase.contains(.began)
    }

    /// A wheel turn counts for the scroll view under the pointer, and a click for the one whose
    /// scroller it's on; a scrolling key for the one holding the keyboard, unless a text has it.
    static func route(_ event: NSEvent) {
        guard let window = event.window else { return }
        let view: NSView?
        let hit = { window.contentView.flatMap { $0.hitTest($0.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) } }
        switch event.type {
        case .scrollWheel:
            guard countsWheel(event.phase, momentum: event.momentumPhase) else { return }
            view = hit()
        case .leftMouseDown:
            guard let scroller = hit() as? NSScroller else { return }
            view = scroller.superview
        case .keyDown where movingKeys.contains(event.keyCode):
            view = window.firstResponder as? NSView
            if view is NSText { return }
        default:
            return
        }
        var scroll = view as? NSScrollView ?? view?.enclosingScrollView
        while let current = scroll {
            if let shift = known.object(forKey: current) { return shift.inputDue() }
            scroll = current.enclosingScrollView
        }
    }

    @discardableResult
    static func beginZoom(in scroll: NSScrollView) -> Bool {
        guard let freeze = known.object(forKey: scroll)?.onZoomBegin else { return false }
        freeze(scroll.contentView.bounds.origin)
        return true
    }

    static func endZoom(in scroll: NSScrollView, resumeFollowing: Bool) {
        known.object(forKey: scroll)?.onZoomEnd?(resumeFollowing)
    }

    static func magnified(_ scroll: NSScrollView) {
        known.object(forKey: scroll)?.onMagnified?(scroll.magnification > 1.001)
    }

    static func pinches(_ scroll: NSScrollView) -> Bool { known.object(forKey: scroll)?.pinches == true }

    static func interruptZoomRecovery(in scroll: NSScrollView) {
        known.object(forKey: scroll)?.onZoomInput?()
    }

    /// AppKit's own geometry: the content's frame and the visible part of it.
    var frames: (content: CGRect, visible: CGRect)? {
        guard let scroll = scrollView, let document = scroll.documentView else { return nil }
        return (document.frame, scroll.contentView.bounds)
    }

    /// The scroll view it found, for a storyline to read.
    var current: NSScrollView? { scrollView }

    /// Its window can be seen: not minimised or covered.
    var windowVisible: Bool { scrollView?.window?.occlusionState.contains(.visible) ?? false }

    var zoomAdjusting: Bool { scrollView.map(PinchZoom.isAdjusting) ?? false }

    /// How many layers draw in the visible part of the content: none is a blank view, whatever
    /// its geometry says. Under a hidden or see-through layer (a tab's fade left at nothing)
    /// none of them shows.
    var drawn: Int? { scrollView.flatMap(Self.drawn) }

    static func drawn(in scroll: NSScrollView) -> Int? {
        guard let document = scroll.documentView, let root = document.layer else { return nil }
        if scroll.isHiddenOrHasHiddenAncestor || faded(scroll.layer) { return 0 }
        let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
        var count = 0
        func walk(_ layer: CALayer, depth: Int) {
            for sub in layer.sublayers ?? [] where !sub.isHidden && sub.opacity > 0 {
                let frame = sub.convert(sub.bounds, to: root)
                guard frame.intersects(visible) else { continue }
                if sub.contents != nil { count += 1 }
                if depth < 6 { walk(sub, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return count
    }

    /// A layer or one above it hidden or see-through.
    static func faded(_ layer: CALayer?) -> Bool {
        var layer = layer
        while let current = layer {
            if current.isHidden || current.opacity < 0.01 { return true }
            layer = current.superlayer
        }
        return false
    }

    /// Moves the view `dy` points towards the content's end; false while no scroll view is known.
    func callAsFunction(_ dy: CGFloat) -> Bool {
        guard let scroll = scrollView, let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y += document.isFlipped ? dy : -dy
        ScrollLog.write("shift", "dy=\(ScrollLog.d(dy))")
        ours = true
        defer { ours = false }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// Where the view is held while the transcript's width changes (`hold`).
    enum Place: Equatable {
        /// The content's end, as AppKit sizes it.
        case end
        /// The top of the view this far down the content (as SwiftUI's geometry counts it: minus
        /// the top inset at the top).
        case offset(CGFloat)
    }

    /// The place held, and until when.
    private(set) var held: (place: Place, until: Date)?
    /// The reader took over a held view (the scroll bar, a gesture): it's let go.
    var onLetGo: (() -> Void)?
    private var holders: [NSObjectProtocol] = []
    /// The notifications the views posted before the hold, given back after it.
    private var posted: (clip: NSClipView, bounds: Bool, frame: Bool, document: NSView, documentFrame: Bool)?
    private var holding = false

    /// Holds the view at `place` until `until`, in the same pass as anything moves it: the content
    /// laid out again, the visible part resized, or SwiftUI keeping its own offset. A
    /// `ScrollPosition` lands an update later, after a frame drawn where layout left it (as the
    /// pinch holds its viewport, `PinchZoom`).
    func hold(_ place: Place, until: Date) {
        held = (place, until)
        if holders.isEmpty, let scroll = scrollView, let document = scroll.documentView {
            let clip = scroll.contentView
            posted = (clip, clip.postsBoundsChangedNotifications, clip.postsFrameChangedNotifications, document, document.postsFrameChangedNotifications)
            clip.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            holders = [(document, NSView.frameDidChangeNotification), (clip, NSView.frameDidChangeNotification), (clip, NSView.boundsDidChangeNotification)].map { view, name in
                center.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.keep() }
                }
            }
            holders.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.release()
                    self?.onLetGo?()
                }
            })
        }
        keep()
    }

    func release() {
        held = nil
        holders.forEach(NotificationCenter.default.removeObserver)
        holders = []
        if let posted {
            posted.clip.postsBoundsChangedNotifications = posted.bounds
            posted.clip.postsFrameChangedNotifications = posted.frame
            posted.document.postsFrameChangedNotifications = posted.documentFrame
        }
        posted = nil
    }

    /// Puts the view back at the place held; false when there's none (or it's let go past its
    /// time) or no scroll view to hold.
    @discardableResult
    func keep() -> Bool {
        guard let held else { return false }
        guard Date() < held.until else {
            release()
            return false
        }
        guard let scroll = scrollView, let document = scroll.documentView, document.isFlipped else { return false }
        guard !holding else { return true }
        let clip = scroll.contentView
        var place = clip.bounds
        switch held.place {
        case .end: place.origin.y = document.frame.height
        case .offset(let y): place.origin.y = y
        }
        let origin = clip.constrainBoundsRect(place).origin
        if abs(origin.y - clip.bounds.minY) > 0.5 {
            ScrollLog.write("hold-keep", "place=\(held.place) from=\(ScrollLog.n(clip.bounds.minY)) to=\(ScrollLog.n(origin.y))")
            holding = true
            defer { holding = false }
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
        return true
    }

    /// The view's bottom on `end` (where the rows end, which AppKit's document can run past), in
    /// one go and in the same pass, up or down only: a magnified page keeps its side. False when
    /// it didn't move.
    @discardableResult
    func pinEnd(at end: CGFloat) -> Bool {
        guard let scroll = scrollView, let document = scroll.documentView, document.isFlipped else { return false }
        let clip = scroll.contentView
        var place = clip.bounds
        place.origin.y = end - place.height
        let origin = clip.constrainBoundsRect(place).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return false }
        ScrollLog.write("pin-end-native", "end=\(ScrollLog.n(end)) from=\(ScrollLog.n(clip.bounds.minY)) to=\(ScrollLog.n(origin.y))")
        ours = true
        defer { ours = false }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// The view's bottom more than `slack` past `end`, where the content's rows end (taller than
    /// the view): on a document AppKit still sizes as it was, or a clip run on past it, nothing
    /// draws there.
    func past(end: CGFloat, slack: CGFloat) -> Bool {
        guard let frames, scrollView?.documentView?.isFlipped == true, end > frames.visible.height else { return false }
        return frames.visible.maxY > end + slack
    }

    /// The page is magnified (a pinch).
    var isMagnified: Bool { (scrollView?.magnification ?? 1) > 1.001 }

    /// Sits in the content and tells its `ScrollShift` the scroll view it's in.
    struct Finder: NSViewRepresentable {
        let shift: ScrollShift
        init(_ shift: ScrollShift) { self.shift = shift }

        func makeNSView(context: Context) -> NSView { Probe(shift) }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class Probe: NSView {
            weak var shift: ScrollShift?
            init(_ shift: ScrollShift) {
                self.shift = shift
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { nil }

            private var observers: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                // Leaving its window (a rebuilt scroll view's old content, after the new one
                // attached), it no longer says which scroll view is current.
                if window != nil, let scroll = enclosingScrollView { shift?.attach(scroll) }
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                guard let window else { return }
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
                    observers.append(
                        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated {
                                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                                self.shift?.onReturn?()
                            }
                        })
                }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

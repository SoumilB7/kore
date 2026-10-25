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
    /// A file preview's column takes a pinch as the transcript does. The transcript is found by
    /// its selection responder instead, which knows when its tab is hidden.
    var pinches = false

    func attach(_ scroll: NSScrollView) {
        if let old = scrollView, Self.known.object(forKey: old) === self { Self.known.removeObject(forKey: old) }
        scrollView = scroll
        Self.known.setObject(self, forKey: scroll)
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

    static func pinches(_ scroll: NSScrollView) -> Bool { known.object(forKey: scroll)?.pinches == true }

    static func interruptZoomRecovery(in scroll: NSScrollView) {
        known.object(forKey: scroll)?.onZoomInput?()
    }

    /// AppKit's own geometry: the content's frame and the visible part of it.
    var frames: (content: CGRect, visible: CGRect)? {
        guard let scroll = scrollView, let document = scroll.documentView else { return nil }
        return (document.frame, scroll.contentView.bounds)
    }

    /// Its window can be seen: not minimised or covered.
    var windowVisible: Bool { scrollView?.window?.occlusionState.contains(.visible) ?? false }

    var zoomAdjusting: Bool { scrollView.map(PinchZoom.isAdjusting) ?? false }

    /// How many layers draw in the visible part of the content: none is a blank view, whatever
    /// its geometry says.
    var drawn: Int? {
        guard let scroll = scrollView, let document = scroll.documentView, let root = document.layer else { return nil }
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

    /// Moves the view `dy` points towards the content's end; false while no scroll view is known.
    func callAsFunction(_ dy: CGFloat) -> Bool {
        guard let scroll = scrollView, let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y += document.isFlipped ? dy : -dy
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

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
                if let scroll = enclosingScrollView { shift?.attach(scroll) }
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

import AppKit
import SwiftUI

/// The scroll view a timeline's content is in, found from inside it (`ScrollShift.Finder` in its
/// background), so a page going in above moves the view down by exactly what it added, at once.
/// Through `ScrollPosition` the move lands an update later, and whatever the reader scrolled in
/// between is lost.
@MainActor
final class ScrollShift: ObservableObject {
    fileprivate weak var scrollView: NSScrollView?

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

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let scroll = enclosingScrollView { shift?.scrollView = scroll }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

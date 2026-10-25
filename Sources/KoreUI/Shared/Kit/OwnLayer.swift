import AppKit
import SwiftUI

/// A view drawn in a hosting view of its own, apart from the window's: what changes in it frame
/// by frame (a timeline, an animation) renders it alone, not the whole window around it, and
/// `animation` runs on its layer in Core Animation, at no cost to the app per frame. It doesn't
/// take this one's environment: style what's inside fully (font, colour). Clicks go through it
/// to the view it sits in.
struct OwnLayer<Content: View>: NSViewRepresentable {
    let content: Content
    var animation: CAAnimation?

    func makeCoordinator() -> NSHostingController<Content> { NSHostingController(rootView: content) }

    func makeNSView(context: Context) -> Host { Host(context.coordinator.view, animation) }

    func updateNSView(_ view: Host, context: Context) { context.coordinator.rootView = content }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        context.coordinator.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
    }

    final class Host: NSView {
        private let content: NSView
        private let animation: CAAnimation?

        init(_ content: NSView, _ animation: CAAnimation?) {
            self.content = content
            self.animation = animation
            super.init(frame: .zero)
            content.wantsLayer = true
            addSubview(content)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            content.frame = bounds
        }

        /// Made before it had a window, its layer starts the animation here.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let animation, let layer = content.layer, layer.animation(forKey: "own") == nil else { return }
            layer.add(animation, forKey: "own")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

import AppKit
import SwiftUI

/// A separate hosting boundary whose layer can animate without a repeating SwiftUI animation.
/// This can reduce app work; it does not guarantee that surrounding layout stops. It doesn't
/// inherit the enclosing SwiftUI environment: style the content fully (font, colour). Clicks
/// go through to the enclosing view; the hosted content remains available to accessibility.
struct OwnLayer<Content: View>: NSViewRepresentable {
    let content: Content
    var animation: LayerAnimation?

    func makeCoordinator() -> NSHostingController<Content> { NSHostingController(rootView: content) }

    func makeNSView(context: Context) -> Host { Host(context.coordinator.view, animation) }

    func updateNSView(_ view: Host, context: Context) {
        context.coordinator.rootView = content
        view.setAnimation(animation, key: "own")
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: Host, coordinator: NSHostingController<Content>) {
        view.stopAnimation()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        context.coordinator.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
    }

    final class Host: LayerAnimationView {
        private let content: NSView
        override var animatedLayer: CALayer? { content.layer }

        init(_ content: NSView, _ animation: LayerAnimation?) {
            self.content = content
            super.init(frame: .zero)
            content.wantsLayer = true
            addSubview(content)
            setAnimation(animation, key: "own")
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            content.frame = bounds
        }
    }
}

/// The scalar repeating animations used by the live marks. Value comparison prevents unrelated
/// content updates from restarting an unchanged animation, while allowing its inputs to change.
struct LayerAnimation: Equatable {
    let keyPath: String
    let from: Double
    let to: Double
    let duration: TimeInterval
    var autoreverses = false
    var easing: CAMediaTimingFunctionName = .linear

    func makeAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: easing)
        return animation
    }
}

/// Event-driven playback for a decorative layer. A detached, hidden or occluded mark retains
/// its phase with a paused layer clock. No app timer or per-frame callback is needed.
class LayerAnimationView: NSView {
    var animatedLayer: CALayer? { layer }
    private var animation: LayerAnimation?
    private var animationKey: String?
    private(set) var playbackPaused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func setAnimation(_ animation: LayerAnimation?, key: String) {
        guard let layer = animatedLayer else { return }
        if self.animation != animation || animationKey != key {
            if let animationKey { layer.removeAnimation(forKey: animationKey) }
            self.animation = animation
            animationKey = key
        }
        updatePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                  name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updatePlayback()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePlayback()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePlayback()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePlayback()
    }

    @objc private func visibilityChanged(_ notification: Notification) { updatePlayback() }

    private func updatePlayback() {
        if let animation, let animationKey, let layer = animatedLayer, layer.animation(forKey: animationKey) == nil {
            layer.add(animation.makeAnimation(), forKey: animationKey)
        }
        setPlaybackPaused(window == nil || isHiddenOrHasHiddenAncestor || window?.occlusionState.contains(.visible) != true)
    }

    /// The layer's local time is frozen and then rebased, so a hidden spell isn't a jump.
    func setPlaybackPaused(_ paused: Bool, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard paused != playbackPaused, let layer = animatedLayer else { return }
        if paused {
            let localTime = layer.convertTime(time, from: nil)
            layer.speed = 0
            layer.timeOffset = localTime
        } else {
            let localTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(time, from: nil) - localTime
        }
        playbackPaused = paused
    }

    func stopAnimation() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let animationKey { animatedLayer?.removeAnimation(forKey: animationKey) }
        animation = nil
        animationKey = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

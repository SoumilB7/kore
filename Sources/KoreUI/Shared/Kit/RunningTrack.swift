import AppKit
import SwiftUI

/// The Agents button's running marks. Core Animation moves one dash around the capsule;
/// steady motion needs no SwiftUI frame callback. Count changes briefly animate the layout.
struct RunningTrack: View {
    let indexes: [Int]
    var background = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hiddenTab) private var hidden

    var body: some View {
        Track(width: Self.width(indexes.count), indexes: Array(indexes.prefix(3)),
              background: background, still: reduceMotion || hidden)
            .animation(reduceMotion || hidden ? nil : Motion.fade, value: indexes.count)
            .accessibilityHidden(true)
    }

    static func width(_ count: Int) -> CGFloat {
        Size.agentTrack + CGFloat(min(max(count, 1), 3) - 1) * Size.agentTrackStep + Stroke.emphasis
    }

    /// Only a count change interpolates this width. The native dash runs independently once
    /// layout settles; no timeline drives this wrapper.
    private struct Track: View, Animatable {
        var width: CGFloat
        let indexes: [Int]
        let background: Bool
        let still: Bool

        nonisolated var animatableData: CGFloat {
            get { width }
            set { width = newValue }
        }

        var body: some View {
            Native(indexes: indexes, background: background, still: still)
                .frame(width: width, height: Size.agentTrack + Stroke.emphasis)
        }
    }

    private struct Native: NSViewRepresentable {
        let indexes: [Int]
        let background: Bool
        let still: Bool

        func makeNSView(context: Context) -> RunningTrackHost { RunningTrackHost() }
        func updateNSView(_ view: RunningTrackHost, context: Context) {
            view.configure(indexes: indexes, background: background, still: still)
        }
        static func dismantleNSView(_ view: RunningTrackHost, coordinator: ()) { view.detach() }
    }
}

/// Geometry shared by native drawing and the tests. Coordinates follow SwiftUI's top-left
/// origin, including the clockwise path's start at the top of its left semicircle.
struct RunningTrackGeometry {
    let size: CGSize
    static let dashLength = 0.28 * .pi * Size.agentTrack

    var perimeter: CGFloat {
        guard size.height > Stroke.emphasis, size.width >= size.height else { return 0 }
        let height = max(size.height - Stroke.emphasis, 0)
        return 2 * max(size.width - size.height, 0) + .pi * height
    }

    var path: CGPath {
        let inset = Stroke.emphasis / 2
        let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard perimeter > 0 else { return CGMutablePath() }
        let radius = box.height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX + radius, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - radius, y: box.minY))
        path.addArc(center: CGPoint(x: box.maxX - radius, y: box.midY), radius: radius,
                    startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        path.addLine(to: CGPoint(x: box.minX + radius, y: box.maxY))
        path.addArc(center: CGPoint(x: box.minX + radius, y: box.midY), radius: radius,
                    startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    @MainActor func mark(_ index: Int, slot: Int) -> CGPath {
        let side = AgentAvatar.Place.stack.shape
        let x = Stroke.emphasis / 2 + Size.agentTrack / 2 + CGFloat(slot) * Size.agentTrackStep
        let rect = CGRect(x: x - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
        let count = AgentShape.allCases.count
        let shape = AgentShape(rawValue: (index % count + count) % count)!
        let path = CGMutablePath()
        for part in AgentShapeView.paths(shape, in: rect) { path.addPath(part.cgPath) }
        return path
    }
}

/// A monotonic clock anchor, not a ticking task. A geometry change keeps the fraction round
/// the track; a pause keeps that same fraction, while each new lap retains its point speed.
struct RunningTrackPhase {
    static let speed = .pi * Size.agentTrack / Motion.ringLap
    private(set) var fraction = 0.0
    private(set) var perimeter: CGFloat = 0
    private(set) var began: CFTimeInterval?

    func value(at time: CFTimeInterval) -> Double {
        guard let began, perimeter > 0 else { return fraction }
        return (fraction + max(time - began, 0) * Double(Self.speed / perimeter)).truncatingRemainder(dividingBy: 1)
    }

    mutating func update(perimeter: CGFloat, running: Bool, at time: CFTimeInterval) {
        fraction = value(at: time)
        self.perimeter = perimeter
        began = running && perimeter > 0 ? time : nil
    }
}

@MainActor
final class RunningTrackHost: NSView {
    static let motionKey = "running-track.phase"
    private let drawing = CALayer()
    let track = CAShapeLayer()
    let dash = CAShapeLayer()
    let marks = (0..<3).map { _ in CAShapeLayer() }
    private(set) var phase = RunningTrackPhase()
    private(set) var windowVisible = false
    private(set) var indexes: [Int] = []
    private var leaving: [Int] = []
    private var background = false
    private var still = false
    private var laidOut = CGSize.zero
    private var observer: RunningTrackObservation?
    private let now: () -> CFTimeInterval

    init(now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.now = now
        super.init(frame: .zero)
        wantsLayer = true
        track.fillColor = nil
        track.strokeColor = NSColor(Theme.border).cgColor
        track.lineWidth = Stroke.emphasis
        dash.fillColor = nil
        dash.strokeColor = NSColor(Theme.agentArc).cgColor
        dash.lineWidth = Stroke.emphasis
        dash.lineCap = .round
        drawing.addSublayer(track)
        drawing.addSublayer(dash)
        for mark in marks {
            mark.fillColor = NSColor(Theme.agentMark).cgColor
            mark.opacity = 0
            drawing.addSublayer(mark)
        }
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(indexes: [Int], background: Bool, still: Bool) {
        let indexes = Array(indexes.prefix(3))
        guard self.indexes != indexes || self.background != background || self.still != still else { return }
        if self.indexes != indexes { leaving = self.indexes }
        self.indexes = indexes
        self.background = background
        self.still = still
        refresh()
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOut else { return }
        refresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer = nil
        guard let window else { return detach() }
        layer?.addSublayer(drawing)
        updateScale()
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setWindowVisible(self.window?.occlusionState.contains(.visible) ?? false)
            }
        }
        observer = RunningTrackObservation(token)
        windowVisible = window.occlusionState.contains(.visible)
        refresh()
    }

    /// Also a seam for deterministic notification/lifecycle tests without ordering a window in.
    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        refresh()
    }

    func detach() {
        observer = nil
        windowVisible = false
        phase.update(perimeter: phase.perimeter, running: false, at: now())
        stopAnimations()
        drawing.removeFromSuperlayer()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [drawing, track, dash] + marks { layer.contentsScale = scale }
        CATransaction.commit()
    }

    private func refresh() {
        let geometry = RunningTrackGeometry(size: bounds.size)
        let running = !still && windowVisible && window != nil && !isHiddenOrHasHiddenAncestor
            && !indexes.isEmpty && geometry.perimeter > 0
        let time = now()
        phase.update(perimeter: geometry.perimeter, running: running, at: time)
        laidOut = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawing.frame = bounds
        for layer in [track, dash] + marks { layer.frame = CGRect(origin: .zero, size: bounds.size) }
        track.path = geometry.path
        dash.path = geometry.path
        track.lineDashPattern = background ? Stroke.backgroundDash.map { NSNumber(value: Double($0)) } : nil
        let length = min(RunningTrackGeometry.dashLength, geometry.perimeter)
        dash.lineDashPattern = geometry.perimeter > 0
            ? [NSNumber(value: Double(length)), NSNumber(value: Double(max(geometry.perimeter - length, 0)))] : nil
        dash.lineDashPhase = CGFloat(1 - phase.fraction) * geometry.perimeter
        for (slot, mark) in marks.enumerated() {
            let shown = indexes.isEmpty || geometry.perimeter == 0 ? nil : (slot < indexes.count ? indexes[slot] : (slot < leaving.count ? leaving[slot] : nil))
            if let shown {
                mark.path = geometry.mark(shown, slot: slot)
                // The old slot remains while the capsule closes; a new slot appears over the
                // last step of its expansion, as in the previous Canvas implementation.
                mark.opacity = Float(min(max((bounds.width - RunningTrack.width(slot + 1)) / Size.agentTrackStep + 1, 0), 1))
            } else {
                mark.opacity = 0
            }
        }
        // Restart only on input, geometry or visibility changes; there is no frame callback.
        dash.removeAnimation(forKey: Self.motionKey)
        if running {
            let motion = CABasicAnimation(keyPath: "lineDashPhase")
            motion.fromValue = dash.lineDashPhase
            motion.toValue = dash.lineDashPhase - geometry.perimeter
            motion.duration = Double(geometry.perimeter / RunningTrackPhase.speed)
            motion.repeatCount = .infinity
            motion.beginTime = dash.convertTime(time, from: nil)
            motion.timingFunction = CAMediaTimingFunction(name: .linear)
            dash.add(motion, forKey: Self.motionKey)
        }
        CATransaction.commit()
    }

    private func stopAnimations() {
        track.removeAllAnimations()
        dash.removeAllAnimations()
        for mark in marks { mark.removeAllAnimations() }
    }
}

/// NotificationCenter owns the callback, not the view. Removal also happens if the view is
/// released without first detaching; the token wrapper itself can be released on any thread.
private final class RunningTrackObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

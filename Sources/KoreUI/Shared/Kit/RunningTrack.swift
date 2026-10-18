import AppKit
import SwiftUI

/// The Agents button's running agents (look.md §10): their shapes, still, in one capsule track
/// with one dash going round it. One agent is a ring around its shape, as a running avatar's;
/// more stretch the ring sideways, so their shapes stand clear instead of crossing arcs. The
/// whole mark is one Canvas on one timeline, which holds still under Reduce Motion, under
/// another tab and while its window is hidden.
struct RunningTrack: View {
    /// The running agents' spawn orders, at most three.
    let indexes: [Int]
    /// They all run in the background: the track is dashed.
    var background = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hiddenTab) private var hidden
    @StateObject private var visible = Local(true)
    /// The shapes as they were before a change, so a leaving one fades as the track closes.
    @StateObject private var trail = Held<(was: [Int], now: [Int])>(([], []))
    @StateObject private var dash = Held(Dash())

    var body: some View {
        if trail.value.now != indexes { trail.value = (trail.value.now, indexes) }
        return Track(
            width: Self.width(indexes.count), indexes: indexes, leaving: trail.value.was,
            still: reduceMotion || hidden || !visible.value, dash: dash, background: background
        )
        .animation(Motion.fade, value: indexes.count)
        .background(Occlusion { visible.value = $0 })
        .accessibilityHidden(true)
    }

    /// The track's box for `count` shapes, its stroke included.
    static func width(_ count: Int) -> CGFloat {
        Size.agentTrack + CGFloat(max(count, 1) - 1) * Size.agentTrackStep + Stroke.emphasis
    }

    /// Where the dash is, as a share of the way round; it moves at the running ring's speed
    /// whatever the track's length, and carries on from where it was as the track changes.
    final class Dash {
        var at = 0.0
        var last: Date?

        func advance(to date: Date, perimeter: CGFloat, still: Bool) -> Double {
            defer { last = still ? nil : date }
            guard !still, let last, perimeter > 0 else { return at }
            // A long gap (a pause, a hidden spell) restarts from where it stopped.
            let step = min(date.timeIntervalSince(last), 0.1)
            at = (at + step * Double(Self.speed / perimeter)).truncatingRemainder(dividingBy: 1)
            return at
        }

        /// A lone running avatar's ring: once round in `Motion.ringLap`.
        static let speed = .pi * Size.agentTrack / Motion.ringLap
    }

    /// The drawing, with the width animatable so the track stretches and closes smoothly.
    private struct Track: View, Animatable {
        var width: CGFloat
        let indexes: [Int]
        let leaving: [Int]
        let still: Bool
        let dash: Held<Dash>
        let background: Bool

        nonisolated var animatableData: CGFloat {
            get { width }
            set { width = newValue }
        }

        var body: some View {
            TimelineView(.animation(minimumInterval: nil, paused: still)) { context in
                Canvas { graphics, size in
                    draw(&graphics, size, at: dash.value.advance(to: context.date, perimeter: Self.perimeter(size), still: still))
                }
            }
            .frame(width: width, height: Size.agentTrack + Stroke.emphasis)
        }

        /// The capsule's path, clockwise from the top of its left end.
        private static func path(_ size: CGSize) -> Path {
            let inset = Stroke.emphasis / 2
            let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let r = box.height / 2
            var path = Path()
            path.move(to: CGPoint(x: box.minX + r, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
            path.addRelativeArc(center: CGPoint(x: box.maxX - r, y: box.midY), radius: r, startAngle: .degrees(-90), delta: .degrees(180))
            path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
            path.addRelativeArc(center: CGPoint(x: box.minX + r, y: box.midY), radius: r, startAngle: .degrees(90), delta: .degrees(180))
            path.closeSubpath()
            return path
        }

        private static func perimeter(_ size: CGSize) -> CGFloat {
            let h = size.height - Stroke.emphasis
            return 2 * max(size.width - size.height, 0) + .pi * h
        }

        private func draw(_ graphics: inout GraphicsContext, _ size: CGSize, at: Double) {
            let path = Self.path(size)
            let perimeter = Self.perimeter(size)
            graphics.stroke(
                path, with: .color(Theme.border),
                style: StrokeStyle(lineWidth: Stroke.emphasis, dash: background ? Stroke.backgroundDash : []))
            // A running avatar's arc: 0.28 of a lone ring, the same length on any track.
            let length = 0.28 * .pi * Size.agentTrack
            let start = CGFloat(at) * perimeter
            graphics.stroke(
                path, with: .color(Theme.agentArc),
                style: StrokeStyle(lineWidth: Stroke.emphasis, lineCap: .round, dash: [length, max(perimeter - length, 0)], dashPhase: perimeter - start))
            let shown = max(indexes.count, leaving.count)
            for slot in 0..<min(shown, 3) {
                guard let index = slot < indexes.count ? indexes[slot] : leaving[safe: slot] else { continue }
                // A slot fades in over the last step of the track reaching it.
                let opacity = min(max((width - RunningTrack.width(slot + 1)) / Size.agentTrackStep + 1, 0), 1)
                guard opacity > 0 else { continue }
                let side = AgentAvatar.Place.stack.shape
                let x = Stroke.emphasis / 2 + Size.agentTrack / 2 + CGFloat(slot) * Size.agentTrackStep
                let rect = CGRect(x: x - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
                let shape = AgentShape(rawValue: index % AgentShape.allCases.count)!
                var layer = graphics
                layer.opacity = opacity
                for part in AgentShapeView.paths(shape, in: rect) { layer.fill(part, with: .color(Theme.agentMark)) }
            }
        }
    }
}

/// Says whether its window can be seen: false while it's minimised or covered.
private struct Occlusion: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(onChange: onChange) }
    func updateNSView(_ nsView: Watcher, context: Context) {}

    final class Watcher: NSView {
        let onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            // Not inside the update that moved it here.
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.changed() } }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }

        private func changed() {
            onChange(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

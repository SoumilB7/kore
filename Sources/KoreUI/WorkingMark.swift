import AppKit
import QuartzCore
import SwiftUI

/// A chat tab's provider mark while its chat is busy (working-marks.html, v3): light travels
/// from the mark's centre out to its edge, dim to bright and back, again and again, a ring each
/// `Motion.workingWave` (slower while it compacts). One radial gradient layer under the mark as
/// its mask, its colours animated by Core Animation: the render server draws it, and SwiftUI
/// does nothing per frame. Under Reduce Motion it holds one still frame of the wave.
struct WorkingMark: NSViewRepresentable {
    let provider: Provider
    var size: CGFloat = Size.logoTab
    var slow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> WorkingMarkView {
        WorkingMarkView(logo: provider.logo, ramp: WorkingMarkColors.ramp(provider).map(NSColor.init))
    }

    func updateNSView(_ view: WorkingMarkView, context: Context) {
        view.run(period: slow ? Motion.workingWaveCompacting : Motion.workingWave, still: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkingMarkView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class WorkingMarkView: NSView {
    private let gradient = CAGradientLayer()
    private let mask = CALayer()
    private let ramp: [NSColor]
    private var running: (period: TimeInterval, still: Bool)?
    /// Marks with the wave running now, for storylines.
    static var storyRunning = 0

    /// Stops from the centre (0) to the edge (1); the wave's frames per ring.
    private static let stops = 13
    private static let frames = 16
    /// The rings' spacing, as a share of the radius: a little over one ring shows at a time.
    private static let spacing: CGFloat = 0.64

    init(logo: NSImage, ramp: [NSColor]) {
        self.ramp = ramp
        super.init(frame: .zero)
        wantsLayer = true
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.locations = (0..<Self.stops).map { NSNumber(value: Double($0) / Double(Self.stops - 1)) }
        gradient.colors = Self.colors(phase: 0, ramp: ramp)
        mask.contents = logo
        mask.contentsGravity = .resizeAspect
        gradient.mask = mask
        layer?.addSublayer(gradient)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        mask.frame = gradient.bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mask.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// The wave at `period` a ring, or one still frame; a change of either starts it again.
    func run(period: TimeInterval, still: Bool) {
        guard running.map({ $0.period != period || $0.still != still }) ?? true else { return }
        running = (period, still)
        gradient.removeAnimation(forKey: "wave")
        gradient.colors = Self.colors(phase: 0.4, ramp: ramp)
        guard !still else { return }
        let wave = CAKeyframeAnimation(keyPath: "colors")
        wave.values = (0...Self.frames).map { Self.colors(phase: CGFloat($0) / CGFloat(Self.frames), ramp: ramp) }
        wave.duration = period
        wave.repeatCount = .infinity
        wave.calculationMode = .linear
        gradient.add(wave, forKey: "wave")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.storyRunning += window == nil ? -1 : 1
    }

    /// The colours at each stop, `phase` (0 to 1) of the way through a ring's travel outward:
    /// each stop's place in the repeating dim-bright-dim profile, moved out by the phase.
    private static func colors(phase: CGFloat, ramp: [NSColor]) -> [CGColor] {
        (0..<stops).map { i in
            let r = CGFloat(i) / CGFloat(stops - 1)
            var u = (r / spacing - phase).truncatingRemainder(dividingBy: 1)
            if u < 0 { u += 1 }
            // 0 at the ring's trough, 1 at its crest.
            let level = 0.5 - 0.5 * cos(2 * .pi * u)
            return blend(ramp, level).cgColor
        }
    }

    private static func blend(_ ramp: [NSColor], _ level: CGFloat) -> NSColor {
        let (a, b, t) = level < 0.5 ? (ramp[0], ramp[1], level * 2) : (ramp[1], ramp[2], (level - 0.5) * 2)
        return a.usingColorSpace(.sRGB)?.blended(withFraction: t, of: b.usingColorSpace(.sRGB) ?? b) ?? a
    }
}

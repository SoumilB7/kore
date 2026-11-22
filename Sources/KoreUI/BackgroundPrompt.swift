import AppKit
import SwiftUI
import src

/// A chat's mark while only its background commands run and the model is idle (bg-command-cue.html,
/// option C): ">_" in its CLI's colour (the working spinner's: Claude's orange, Codex's white), its
/// cursor blinking, in the logo's place. With an approval waiting, the amber point sits on its
/// corner, ringed in the ground so it reads apart from the orange. The blink is one Core Animation opacity
/// animation on the cursor's layer, run by the render server and only while the mark is in a
/// window; under Reduce Motion the cursor holds still.
struct BackgroundPrompt: View {
    let provider: Provider
    var needsYou = false
    var size: CGFloat = Size.spinner
    /// The chat's Arsenal tier: on, ">_" takes Arsenal's colour, as the logo does.
    var arsenal: ArsenalTier? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var tint: Color { WorkingSpinner.tint(provider, arsenal: arsenal) }

    var body: some View {
        PromptMarkView.Representable(reduceMotion: reduceMotion, tint: NSColor(tint))
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if needsYou {
                    Circle().fill(Theme.warning)
                        .frame(width: Size.backgroundPromptPoint, height: Size.backgroundPromptPoint)
                        .background(Circle().fill(Theme.background).padding(-Size.backgroundPromptRing))
                        .offset(x: Size.backgroundPromptPoint / 2, y: -Size.backgroundPromptPoint / 3)
                }
            }
            .tip(needsYou ? "Background commands running · needs you" : "Background commands running")
            .accessibilityLabel(Text(needsYou ? "Background commands running, needs you" : "Background commands running"))
    }
}

/// ">" and "_" as two stroked paths on a 14 box; the "_" layer blinks.
final class PromptMarkView: NSView {
    private let chevron = CAShapeLayer()
    private let cursor = CAShapeLayer()
    var still = false { didSet { if still != oldValue { updateBlink() } } }
    var tint = NSColor(Theme.secondary) {
        didSet {
            guard tint != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for shape in [chevron, cursor] { shape.strokeColor = tint.cgColor }
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [chevron, cursor] {
            shape.fillColor = nil
            shape.strokeColor = NSColor(Theme.secondary).cgColor
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let s = min(bounds.width, bounds.height) / 14
        let ox = (bounds.width - 14 * s) / 2, oy = (bounds.height - 14 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let c = CGMutablePath()
        c.move(to: p(1.8, 3.6)); c.addLine(to: p(6.0, 7.0)); c.addLine(to: p(1.8, 10.4))
        let u = CGMutablePath()
        u.move(to: p(7.4, 10.9)); u.addLine(to: p(12.4, 10.9))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [chevron, cursor] { shape.frame = bounds; shape.lineWidth = 1.5 * s }
        chevron.path = c
        cursor.path = u
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBlink()
    }

    /// Runs only in a window and not still: a tab that isn't drawn spends nothing.
    private func updateBlink() {
        cursor.removeAnimation(forKey: "blink")
        guard window != nil, !still else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        // Discrete: shown for the first 55%, hidden for the rest (one more key time than values).
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.55, 1]
        blink.calculationMode = .discrete
        blink.duration = Motion.promptBlink
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        cursor.add(blink, forKey: "blink")
    }

    struct Representable: NSViewRepresentable {
        let reduceMotion: Bool
        let tint: NSColor
        func makeNSView(context: Context) -> PromptMarkView { PromptMarkView() }
        func updateNSView(_ view: PromptMarkView, context: Context) {
            view.still = reduceMotion
            view.tint = tint
        }
    }
}

/// For storylines: the colour of each ">_" mark on screen, as "#RRGGBB".
@MainActor
package enum StoryBackgroundPrompt {
    package static func tints() -> [String] {
        func marks(_ view: NSView) -> [PromptMarkView] {
            (view as? PromptMarkView).map { [$0] } ?? view.subviews.flatMap(marks)
        }
        return NSApp.windows.compactMap(\.contentView).flatMap(marks).compactMap { mark in
            guard let c = mark.tint.usingColorSpace(.sRGB) else { return nil }
            return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
    }
}

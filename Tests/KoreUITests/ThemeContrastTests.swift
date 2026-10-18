import AppKit
import SwiftUI
import Testing

@testable import KoreUI

/// The text tokens keep WCAG contrast on the grounds they're drawn on, and the three steps of
/// text stay apart.
@Suite("Theme contrast")
struct ThemeContrastTests {
    /// sRGB components, laid over `ground` by their opacity.
    private static func rgb(_ color: Color, over ground: Color? = nil) -> [Double] {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let top = [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
        guard let ground, c.alphaComponent < 1 else { return top }
        let under = rgb(ground)
        let a = Double(c.alphaComponent)
        return zip(top, under).map { $0 * a + $1 * (1 - a) }
    }

    private static func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func ratio(_ text: Color, on ground: Color) -> Double {
        let a = luminance(rgb(text, over: ground)), b = luminance(rgb(ground))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func tertiaryIsReadableOnTheWindow() {
        #expect(Self.ratio(Theme.tertiary, on: Theme.background) >= 4.5)
        #expect(Self.ratio(Theme.tertiary, on: Theme.surface) >= 4.3)
        #expect(Self.ratio(Theme.tertiary, on: Theme.surfaceHover) >= 3.9)
        #expect(Self.ratio(Theme.tertiary, on: Theme.surfaceRaised) >= 3.4)
    }

    @Test func theThreeStepsStayApart() {
        let steps = [Theme.text, Theme.secondary, Theme.tertiary].map { Self.ratio($0, on: Theme.background) }
        #expect(steps[0] > steps[1] + 4 && steps[1] > steps[2] + 1)
    }

    @Test func toolLabelsReadOnTheirBox() {
        #expect(Self.ratio(Theme.toolLabel, on: Theme.surface) >= 4.5)
    }
}

import SwiftUI
import Testing

@testable import KoreUI

/// The one hover and selection vocabulary: on either ground, the hovered row, the selected row
/// and the ground itself are three different colours, the hover between the other two.
@Suite("Row fills")
@MainActor
struct RowFillTests {
    /// A fill drawn over the ground, as the screen shows it: its relative luminance.
    private func luminance(_ fill: Color, over ground: Color) -> Double {
        let environment = EnvironmentValues()
        let top = fill.resolve(in: environment)
        let bottom = ground.resolve(in: environment)
        let a = Double(top.opacity)
        func mix(_ t: Float, _ b: Float) -> Double { Double(t) * a + Double(b) * (1 - a) }
        return 0.2126 * mix(top.linearRed, bottom.linearRed) + 0.7152 * mix(top.linearGreen, bottom.linearGreen)
            + 0.0722 * mix(top.linearBlue, bottom.linearBlue)
    }

    @Test(arguments: [(Theme.Ground.window, Theme.background), (.surface, Theme.surface)])
    func hoverAndSelectionStandOffTheirGround(ground: Theme.Ground, color: Color) {
        let bare = luminance(color, over: color)
        let hover = luminance(Theme.Row.hover(ground), over: color)
        let selected = luminance(Theme.Row.selected(ground), over: color)
        #expect(bare < hover)
        #expect(hover < selected)
    }

    /// The floating explorer's fault: its rows sit on `surface`, the docked one's selection.
    @Test func aFloatingTreesSelectionIsntItsPanel() {
        #expect(luminance(Theme.Row.selected(.surface), over: Theme.surface) > luminance(Theme.surface, over: Theme.surface))
        #expect(luminance(Theme.Row.hover(.surface), over: Theme.surface) > luminance(Theme.surface, over: Theme.surface))
    }
}

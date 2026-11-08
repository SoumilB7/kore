import AppKit
import SwiftTerm
import Testing
@testable import KoreUI

/// ⌘= / ⌘- / ⌘0 take the whole window: one level, its steps and limits, and the lengths that
/// follow it (fonts, rows, the title row, the terminal's font) scale by it alike.
@MainActor @Suite("Window zoom scale")
struct ZoomScaleTests {
    @Test func stepsLimitsAndResetArePersisted() {
        var writes: [CGFloat] = []
        let zoom = Zoom(saved: 1, persist: { writes.append($0) })
        zoom.zoomIn(); zoom.zoomIn()
        #expect(abs(zoom.scale - 1.2) < 0.0001)
        for _ in 0..<20 { zoom.zoomIn() }
        #expect(zoom.scale == Zoom.range.upperBound)
        for _ in 0..<30 { zoom.zoomOut() }
        #expect(zoom.scale == Zoom.range.lowerBound)
        zoom.reset()
        #expect(zoom.scale == 1)
        #expect(writes.last == 1 && writes.count == 2 + 6 + 11 + 1)
        // A saved level out of range comes back inside it; none saved is 100%.
        #expect(Zoom(saved: 9, persist: { _ in }).scale == Zoom.range.upperBound)
        #expect(Zoom(saved: 0, persist: { _ in }).scale == 1)
    }

    @Test func lengthsScaleLinearlyByTheLevel() {
        for scale in [0.7, 0.8, 1, 1.2, 1.5, 1.8] as [CGFloat] {
            #expect(abs(Zoom.pt(22, scale: scale) - 22 * scale) < 0.0001)
            let size = Zoom.pt(CGSize(width: 44, height: 28), scale: scale)
            #expect(abs(size.width - 44 * scale) < 0.0001 && abs(size.height - 28 * scale) < 0.0001)
            // Rows and the text they hold grow together: the ratio row / font stays put.
            #expect(abs(Zoom.pt(22, scale: scale) / Zoom.pt(13, scale: scale) - 22 / 13) < 0.0001)
        }
        #expect(Zoom.pt(30, scale: 1) == 30)
    }

    @Test func titleRowGrowsWithItsTabsAndNeverShrinksBelowTheBar() {
        #expect(Zoom.titleRow(bar: 40, scale: 1) == 40)
        #expect(abs(Zoom.titleRow(bar: 40, scale: 1.2) - 46) < 0.0001)
        #expect(abs(Zoom.titleRow(bar: 40, scale: 1.8) - 64) < 0.0001)
        #expect(Zoom.titleRow(bar: 40, scale: 0.8) == 40)
        #expect(Zoom.titleRow(bar: 28, scale: 0.7) == 28)
        // The tabs fit the row at every level, with the 100% margin or more.
        for scale in stride(from: Zoom.range.lowerBound, through: Zoom.range.upperBound, by: Zoom.step) {
            #expect(Zoom.titleRow(bar: 40, scale: scale) - Zoom.pt(Zoom.tabBase, scale: scale) >= 10 - 0.0001)
        }
    }

    @Test func terminalFontFollowsTheLevelOnceAndOnlyOnChange() {
        #expect(TerminalShell.font(1).pointSize == 12)
        #expect(abs(TerminalShell.font(1.2).pointSize - 14.4) < 0.01)
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200), font: TerminalShell.font(1))
        TerminalShell.follow(view, scale: 1.5)
        #expect(abs(view.font.pointSize - 18) < 0.01)
        let font = view.font
        TerminalShell.follow(view, scale: 1.5)
        #expect(view.font === font)
        TerminalShell.follow(view, scale: 1)
        #expect(view.font.pointSize == 12)
    }
}

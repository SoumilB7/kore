import AppKit
import Testing
@testable import KoreUI

/// The transcript's end: pinned up or down only on a magnified page, and left alone when the
/// composer grows or shrinks under it; a view past the rows' end found and brought back
/// natively, and what a turn's fold does to the view.
@MainActor @Suite("Transcript end", .serialized)
struct TranscriptEndTests {
    init() { _ = NSApplication.shared }

    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    /// A 500×400 scroll view over a 2000 pt flipped document, as SwiftUI's is, at its bottom.
    private func page(magnified: CGFloat = 1) -> (NSWindow, NSScrollView, ScrollShift) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = Flipped(frame: CGRect(x: 0, y: 0, width: 500, height: 2000))
        scroll.allowsMagnification = true
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.magnification = magnified
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: magnified > 1 ? 100 : 0, y: 2000 - clip.bounds.height))
        let shift = ScrollShift()
        shift.attach(scroll)
        return (window, scroll, shift)
    }

    @Test func aViewPastTheRowsEndIsFoundOnlyWhenTheRowsFillIt() {
        let (window, scroll, shift) = page()
        defer { window.contentView = nil }
        #expect(scroll.contentView.bounds.maxY == 2000)
        // The rows end 500 pt above the view's bottom: blank under them.
        #expect(shift.past(end: 1500, slack: 50))
        // Within the slack of it: at the end.
        #expect(!shift.past(end: 1960, slack: 50))
        // Rows shorter than the view sit in it, whatever is under them.
        #expect(!shift.past(end: 300, slack: 50))
    }

    @Test func pinningTheEndMovesUpOrDownOnlyAndKeepsAMagnifiedSide() throws {
        let (window, scroll, shift) = page(magnified: 1.5)
        defer { window.contentView = nil }
        let clip = scroll.contentView
        #expect(shift.isMagnified)
        let side = clip.bounds.minX
        #expect(abs(side - 100) < 0.01)
        #expect(shift.pinEnd(at: 1500))
        #expect(abs(clip.bounds.maxY - 1500) < 0.01 && clip.bounds.minX == side && scroll.magnification == 1.5)
        // There already: no move.
        #expect(!shift.pinEnd(at: 1500))
        // Never past the document, however far the end is asked.
        #expect(shift.pinEnd(at: 5000))
        #expect(abs(clip.bounds.maxY - 2000) < 0.01 && clip.bounds.minX == side)
    }

    @Test func aPageAtItsNaturalSizeIsNotMagnified() {
        let (window, _, shift) = page()
        defer { window.contentView = nil }
        #expect(!shift.isMagnified)
        #expect(!ScrollShift().isMagnified)
    }

    @Test func holdingTheEndOfAMagnifiedPageKeepsItsSide() {
        let (window, scroll, shift) = page(magnified: 1.5)
        defer { window.contentView = nil }
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 100, y: 1000))
        shift.hold(.end, until: Date() + 1)
        defer { shift.release() }
        #expect(abs(clip.bounds.maxY - 2000) < 0.01 && clip.bounds.minX == 100 && scroll.magnification == 1.5)
    }

    @Test func aMagnifiedPagesNewVisibleHeightDoesntPinTheEnd() {
        // Unzoomed, the composer growing under a followed end keeps it there.
        #expect(TranscriptTimeline.pinsEnd(grew: false, insetSettling: false, visibleMoved: true, magnified: false))
        // Zoomed, nothing moves: the view only gets shorter or taller at the bottom.
        #expect(!TranscriptTimeline.pinsEnd(grew: false, insetSettling: false, visibleMoved: true, magnified: true))
        // New content still pins it, zoomed or not; an inset's move does too.
        #expect(TranscriptTimeline.pinsEnd(grew: true, insetSettling: false, visibleMoved: true, magnified: true))
        #expect(TranscriptTimeline.pinsEnd(grew: false, insetSettling: true, visibleMoved: false, magnified: true))
        #expect(!TranscriptTimeline.pinsEnd(grew: false, insetSettling: false, visibleMoved: false, magnified: false))
    }

    @Test func aFoldFollowedLooksAtTheEndAndAboveKeepsTheAnswerOnScreen() {
        // Following: the end is looked at, whatever answers are on screen.
        #expect(FoldMove(following: true, answerTops: ["a": 100], visible: 600) == .checkEnd)
        // Above the end: the answer starting lowest above the view's bottom stays where it is,
        // one whose top went above the view included; one under the bottom isn't the reader's.
        #expect(FoldMove(following: false, answerTops: ["a": -300, "b": 120, "c": 640], visible: 600) == .keep(id: "b", top: 120))
        #expect(FoldMove(following: false, answerTops: ["a": -300], visible: 600) == .keep(id: "a", top: -300))
        // No answer there: up by the height the fold took.
        #expect(FoldMove(following: false, answerTops: ["c": 640], visible: 600) == .byHeight)
        #expect(FoldMove(following: false, answerTops: [:], visible: 600) == .byHeight)
    }
}

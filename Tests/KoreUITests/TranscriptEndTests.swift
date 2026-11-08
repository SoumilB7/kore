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

    private final class Focusable: NSView {
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    /// The reader's own moves of the view are counted: its live scrolls, and a scrolling key
    /// while it has the keyboard. Another view's live scroll, a key typed into a text, or any key
    /// that doesn't scroll, isn't.
    @Test func onlyTheReadersOwnMovesAreCounted() throws {
        let (window, scroll, shift) = page()
        defer { window.contentView = nil }
        let other = NSScrollView(frame: .zero)
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didLiveScrollNotification, object: other)
        #expect(shift.readerInputs == 2)
        let focus = Focusable(frame: CGRect(x: 0, y: 0, width: 500, height: 2000))
        scroll.documentView = focus
        #expect(window.makeFirstResponder(focus))
        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code))
        }
        ScrollShift.route(try key(121))  // Page Down
        ScrollShift.route(try key(0))  // "a"
        #expect(shift.readerInputs == 3)
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        focus.addSubview(text)
        #expect(window.makeFirstResponder(text))
        ScrollShift.route(try key(121))
        #expect(shift.readerInputs == 3)
    }

    /// A wheel counts each turn with no phases, and a gesture once, as it begins; a click on the
    /// view's scroller counts, and a move made for the reader (the navigation bench's) does; a
    /// click anywhere else doesn't.
    @Test func wheelsScrollerClicksAndBenchMovesAreCounted() throws {
        #expect(ScrollShift.countsWheel([], momentum: []))
        #expect(ScrollShift.countsWheel(.began, momentum: []))
        #expect(!ScrollShift.countsWheel(.changed, momentum: []))
        #expect(!ScrollShift.countsWheel([], momentum: .changed))
        let (window, scroll, shift) = page()
        defer { window.contentView = nil }
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        window.contentView?.layoutSubtreeIfNeeded()
        func click(_ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let scroller = try #require(scroll.verticalScroller)
        ScrollShift.route(try click(scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)))
        #expect(shift.readerInputs == 1)
        ScrollShift.route(try click(NSPoint(x: 50, y: 200)))
        #expect(shift.readerInputs == 1)
        ScrollShift.readerMoved(scroll)
        #expect(shift.readerInputs == 2)
    }

    /// Following is left only once the reader moved the view since the end was taken up.
    @Test func theEndIsLeftOnlyByTheReader() {
        #expect(!TranscriptTimeline.readerLeft(inputs: 4, taken: 4))
        #expect(TranscriptTimeline.readerLeft(inputs: 5, taken: 4))
    }

    /// A followed view moved up leaves the end only by the reader's move, well clear of the end,
    /// in a chat taller than a screen: the lazy stack or SwiftUI settling a pin never leaves it,
    /// and the reader's move does in a pass that measured rows too (whatever the height).
    @Test func onlyTheReadersMoveUpLeavesTheEnd() {
        // 10 000 pt of content, 600 shown, at the end (9400): up 1000.
        #expect(TranscriptTimeline.leavesEnd(readerLeft: true, height: 10_000, visible: 600, offset: 8400, was: 9400))
        #expect(!TranscriptTimeline.leavesEnd(readerLeft: false, height: 10_000, visible: 600, offset: 8400, was: 9400))
        // The pass grew the content as the reader moved: still theirs.
        #expect(TranscriptTimeline.leavesEnd(readerLeft: true, height: 12_000, visible: 600, offset: 8400, was: 9400))
        // Within the slack of the end, down, or a chat shorter than a screen: not left.
        #expect(!TranscriptTimeline.leavesEnd(readerLeft: true, height: 10_000, visible: 600, offset: 9300, was: 9400))
        #expect(!TranscriptTimeline.leavesEnd(readerLeft: true, height: 10_000, visible: 600, offset: 9400, was: 8400))
        #expect(!TranscriptTimeline.leavesEnd(readerLeft: true, height: 620, visible: 600, offset: -200, was: 20))
    }

    /// The reader's inputs so far are behind the end when it's taken up, and while the view stays
    /// at it with nothing moved up (a wheel turned down there); not while it moves up, nor when
    /// it isn't followed.
    @Test func inputsAtTheEndAreBehindIt() {
        #expect(TranscriptTimeline.takesEnd(following: true, was: false, atEnd: false, movedUp: true))
        #expect(TranscriptTimeline.takesEnd(following: true, was: true, atEnd: true, movedUp: false))
        #expect(!TranscriptTimeline.takesEnd(following: true, was: true, atEnd: true, movedUp: true))
        #expect(!TranscriptTimeline.takesEnd(following: true, was: true, atEnd: false, movedUp: false))
        #expect(!TranscriptTimeline.takesEnd(following: false, was: true, atEnd: true, movedUp: false))
    }

    /// A tab shown again is built anew at its end only when rows came while it was hidden, it was
    /// following, and it isn't magnified.
    @Test func aTabShownWithNewRowsAtItsEndIsBuiltAnew() {
        #expect(TranscriptTimeline.renewsOnShow(showing: true, grew: true, following: true, magnified: false))
        #expect(!TranscriptTimeline.renewsOnShow(showing: true, grew: false, following: true, magnified: false))
        #expect(!TranscriptTimeline.renewsOnShow(showing: true, grew: true, following: false, magnified: false))
        #expect(!TranscriptTimeline.renewsOnShow(showing: true, grew: true, following: true, magnified: true))
        #expect(!TranscriptTimeline.renewsOnShow(showing: false, grew: true, following: true, magnified: false))
    }

    /// A view not followed takes up the end when it moves down to it; a view built again for a
    /// tab coming back doesn't while it settles, though it lays out from the bottom first.
    @Test func aRestoredViewSettlingAtTheBottomDoesntTakeUpTheEnd() {
        // 2500 pt of content, 623 shown: down from 400 to the end (1877), then 1839.
        #expect(TranscriptTimeline.movesToEnd(settling: false, height: 2500, visible: 623, offset: 1877, was: 400))
        #expect(TranscriptTimeline.movesToEnd(settling: false, height: 2500, visible: 623, offset: 1839, was: 400))
        #expect(!TranscriptTimeline.movesToEnd(settling: true, height: 2500, visible: 623, offset: 1839, was: 400))
        // Short of the slack, or not a move down: not taken up.
        #expect(!TranscriptTimeline.movesToEnd(settling: false, height: 2500, visible: 623, offset: 1800, was: 400))
        #expect(!TranscriptTimeline.movesToEnd(settling: false, height: 2500, visible: 623, offset: 1877, was: 1877))
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

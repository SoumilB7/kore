import AppKit
import PDFKit
import Testing
import WebKit
@testable import KoreUI

@MainActor @Suite("Optical page pinch zoom", .serialized)
struct PinchZoomTests {
    init() { _ = NSApplication.shared }

    private func editor() -> (NSWindow, NSScrollView, EditorTextView, CGPoint) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let text = EditorTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 2000))
        text.string = (0..<100).map { "Line \($0), some text to preserve under the cursor." }.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scroll.documentView = text
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        return (window, scroll, text, CGPoint(x: 200, y: 200))
    }

    @Test func samplesAndEndMagnifyOnlyTheNativePageWithoutReflowOrFontWrites() {
        let (window, scroll, text, point) = editor()
        var writes: [CGFloat] = []
        let zoom = Zoom(saved: 1, persist: { writes.append($0) })
        let pinch = PinchZoom(zoom: zoom)
        // Neither the shared keyboard model nor the actual text may change.
        let frame = text.frame, bounds = text.bounds, font = text.font
        let selection = NSRange(location: 10, length: 7)
        text.setSelectedRange(selection)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0, phase: .began, at: point))
        for _ in 0..<120 { #expect(pinch.receive(0.001, phase: .changed, at: point)) }
        #expect(abs(scroll.magnification - 1.12) < 0.00001)
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(text.frame == frame && text.bounds == bounds && text.font == font)
        #expect(text.selectedRange() == selection)
        #expect(zoom.scale == 1 && writes.isEmpty && zoom.commits == 0)
        #expect(pinch.counts.previews == 120 && pinch.counts.commits == 1)
        #expect(!PinchZoom.isAdjusting(scroll))
        #expect(abs(scroll.contentView.bounds.width - 500 / 1.12) < 0.01)
    }

    @Test func nativeConversionsKeepTheSameCharacterUnderTheCursorAndPanAfterEnd() throws {
        let (window, scroll, text, point) = editor()
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in Issue.record("Font reflow") }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        let beforePoint = text.convert(point, from: nil)
        let before = text.characterIndexForInsertion(at: beforePoint)
        #expect(pinch.receive(0.5, phase: .began, at: point))
        let during = text.characterIndexForInsertion(at: text.convert(point, from: nil))
        #expect(during == before)
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(text.characterIndexForInsertion(at: text.convert(point, from: nil)) == before)
        let placed = try #require(pinch.placement)
        #expect(abs(placed.unavoidableDrift.dx) < 0.01 && abs(placed.unavoidableDrift.dy) < 0.01)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: CGPoint(x: origin.x + 25, y: origin.y + 75))
        #expect(scroll.contentView.bounds.minX > origin.x && scroll.contentView.bounds.minY > origin.y)
        let after = text.convert(beforePoint, to: nil)
        #expect(abs(after.x - (point.x - 37.5)) < 0.01)
        #expect(abs(abs(after.y - point.y) - 112.5) < 0.01)
        #expect(!scroll.hasHorizontalScroller)
    }

    @Test func cancellationRestoresPreviousLocalFactorOriginAndSelectionThenDetachRestoresConfiguration() {
        let (window, scroll, text, point) = editor()
        let oldMinimum = scroll.minMagnification, oldMaximum = scroll.maxMagnification
        let oldElasticity = scroll.horizontalScrollElasticity
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in Issue.record("Font write") }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.3, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        let scale = scroll.magnification, origin = scroll.contentView.bounds.origin
        let selection = NSRange(location: 20, length: 8)
        text.setSelectedRange(selection)
        #expect(pinch.receive(0.2, phase: .began, at: point))
        #expect(scroll.magnification > scale)
        #expect(pinch.receive(0, phase: .cancelled, at: point))
        #expect(scroll.magnification == scale && hypot(scroll.contentView.bounds.minX - origin.x, scroll.contentView.bounds.minY - origin.y) < 0.00001)
        #expect(text.selectedRange() == selection && pinch.counts.cancellations == 1)
        pinch.detach()
        #expect(scroll.magnification == 1 && !scroll.allowsMagnification)
        #expect(scroll.minMagnification == oldMinimum && scroll.maxMagnification == oldMaximum)
        #expect(scroll.horizontalScrollElasticity == oldElasticity)
    }

    @Test func localFactorsAreIsolatedByTabAndWindowAndPrunedOnClose() {
        let (window, scroll, _, point) = editor()
        let (otherWindow, otherScroll, _, otherPoint) = editor()
        let pinch = PinchZoom(), other = PinchZoom()
        let first = UUID(), second = UUID()
        pinch.attach(window); other.attach(otherWindow)
        pinch.setActiveTab(first, openTabs: [first, second])
        defer { pinch.detach(); other.detach(); window.contentView = nil; otherWindow.contentView = nil }
        #expect(pinch.receive(0.4, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        let firstOrigin = scroll.contentView.bounds.origin
        #expect(otherScroll.magnification == 1)
        #expect(other.receive(0.1, phase: .began, at: otherPoint))
        #expect(other.receive(0, phase: .ended, at: otherPoint))
        pinch.setActiveTab(second, openTabs: [first, second])
        #expect(scroll.magnification == 1)
        #expect(pinch.receive(0.2, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.setActiveTab(first, openTabs: [first, second]); pinch.completeLayout()
        #expect(abs(scroll.magnification - 1.4) < 0.00001)
        #expect(hypot(scroll.contentView.bounds.minX - firstOrigin.x, scroll.contentView.bounds.minY - firstOrigin.y) < 0.00001)
        #expect(abs(otherScroll.magnification - 1.1) < 0.00001)
        pinch.setActiveTab(second, openTabs: [second]); pinch.completeLayout()
        #expect(abs(scroll.magnification - 1.2) < 0.00001)
        pinch.setActiveTab(first, openTabs: [first, second]); pinch.completeLayout()
        #expect(scroll.magnification == 1)
    }

    @Test func invalidSamplesAndLimitsNeverWriteGlobalZoomOrDefaults() {
        let (window, scroll, _, point) = editor()
        let zoom = Zoom(saved: 1, persist: { _ in Issue.record("Font defaults changed") })
        let pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(!pinch.receive(0.2, phase: [], at: point))
        #expect(pinch.receive(.infinity, phase: .began, at: point))
        #expect(pinch.receive(.nan, phase: .changed, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(scroll.magnification == 1 && pinch.counts.commits == 0)
        #expect(pinch.receive(100, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(scroll.magnification == 3)
        #expect(pinch.receive(-100, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        // Pinching out stops at the page's own size: never below what ⌘+ / ⌘− set.
        #expect(scroll.magnification == 1 && zoom.scale == 1 && zoom.commits == 0)
    }

    @Test func resizeFocusAndKeyboardChangesCancelOnlyTheGesture() {
        let (window, scroll, text, point) = editor()
        var writes = 0
        let zoom = Zoom(saved: 1, persist: { _ in writes += 1 })
        let pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.2, phase: .began, at: point))
        window.setContentSize(CGSize(width: 520, height: 420))
        #expect(!PinchZoom.isAdjusting(scroll) && scroll.magnification == 1)
        #expect(window.makeFirstResponder(text))
        #expect(pinch.receive(0.2, phase: .began, at: point))
        #expect(window.makeFirstResponder(nil))
        #expect(pinch.receive(0.1, phase: .changed, at: point))
        #expect(!PinchZoom.isAdjusting(scroll) && scroll.magnification == 1)
        #expect(pinch.receive(0.2, phase: .began, at: point))
        zoom.zoomIn()
        #expect(pinch.receive(0.1, phase: .changed, at: point))
        #expect(!PinchZoom.isAdjusting(scroll) && scroll.magnification == 1 && writes == 1)
    }

    @Test(arguments: [true, false])
    func unsolicitedNativeScrollsAreHeldOnlyDuringTheGesture(posted: Bool) {
        let (window, scroll, _, point) = editor()
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = posted
        let shift = ScrollShift()
        shift.attach(scroll)
        var freezes = 0
        shift.onZoomBegin = { _ in freezes += 1 }
        let pinch = PinchZoom()
        pinch.attach(window)
        defer { pinch.detach(); shift.onZoomBegin = nil; window.contentView = nil }
        #expect(pinch.receive(0, phase: .began, at: point))
        #expect(pinch.receive(0.1, phase: .changed, at: point))
        let held = clip.bounds.origin
        for delta in [20.0, 40.0, -20.0] {
            clip.scroll(to: CGPoint(x: held.x, y: held.y + delta))
            #expect(hypot(clip.bounds.minX - held.x, clip.bounds.minY - held.y) < 0.00001)
        }
        for _ in 0..<120 { #expect(pinch.receive(0, phase: .changed, at: point)) }
        #expect(freezes == 1 && pinch.counts.previews == 1 && pinch.counts.corrections == 3)
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(clip.postsBoundsChangedNotifications == posted)
        clip.scroll(to: CGPoint(x: held.x, y: held.y + 40))
        #expect(clip.bounds.minY > held.y && pinch.counts.corrections == 3)
    }

    @Test func nativeViewersAndComposerTextKeepTheirOwnGestures() {
        let (window, scroll, _, point) = editor()
        let pinch = PinchZoom()
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        scroll.allowsMagnification = true
        #expect(!pinch.receive(0.2, phase: .began, at: point))
        scroll.allowsMagnification = false
        scroll.documentView = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 2000))
        #expect(!pinch.receive(0.2, phase: .began, at: point))
        #expect(scroll.magnification == 1)
    }
    @Test func closingTheWindowImmediatelyRestoresItsNativeSurface() {
        let (window, scroll, _, point) = editor()
        let controller = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        controller.attach(window)
        #expect(controller.receive(0.3, phase: .began, at: point))
        #expect(controller.receive(0, phase: .ended, at: point))
        #expect(scroll.magnification > 1)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(scroll.magnification == 1)
        #expect(!scroll.allowsMagnification)
        #expect(PinchZoom.storyCounts(in: window) == nil)
    }

    @Test func endWaitsForNativeLayoutBeforeResumingAndSwitchNeverResumesTheHiddenPage() {
        let (window, scroll, _, point) = editor()
        let controller = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in Issue.record("Font write") }))
        let shift = ScrollShift()
        shift.attach(scroll)
        var ends: [Bool] = []
        var adjustingAtEnd: [Bool] = []
        shift.onZoomBegin = { _ in }
        shift.onZoomEnd = { resume in
            ends.append(resume)
            adjustingAtEnd.append(PinchZoom.isAdjusting(scroll))
        }
        controller.attach(window)
        defer { controller.detach(); shift.onZoomBegin = nil; shift.onZoomEnd = nil; window.contentView = nil }
        let first = UUID(), second = UUID()
        controller.setActiveTab(first, openTabs: [first, second])
        #expect(controller.receive(0.2, phase: .began, at: point))
        #expect(controller.receive(0, phase: .cancelled, at: point))
        #expect(ends.isEmpty && PinchZoom.isAdjusting(scroll))
        controller.completeLayout()
        #expect(ends == [true] && adjustingAtEnd == [false])
        #expect(scroll.magnification == 1)
        #expect(controller.receive(0.2, phase: .began, at: point))
        #expect(controller.receive(0, phase: .ended, at: point))
        #expect(PinchZoom.isAdjusting(scroll) && ends == [true])
        controller.completeLayout()
        #expect(ends == [true, true] && scroll.magnification > 1)
        #expect(controller.receive(0.1, phase: .began, at: point))
        PinchZoom.selectTab(in: window, id: second, openTabs: [first, second])
        #expect(ends == [true, true, false])
        #expect(!PinchZoom.isAdjusting(scroll) && scroll.magnification == 1)
    }


    /// Back at its natural size, a page keeps no place of its own: its tab comes back where its
    /// transcript put it (the end moved on while it was out of sight), and nothing scrolls sideways.
    @Test func aPageBackAtItsSizeKeepsNoPlaceAndNoSidewaysScroll() {
        let (window, scroll, _, point) = editor()
        let elasticity = scroll.horizontalScrollElasticity
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        let first = UUID(), second = UUID()
        pinch.setActiveTab(first, openTabs: [first, second])
        #expect(pinch.receive(0.5, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(scroll.magnification > 1 && scroll.horizontalScrollElasticity == .allowed)
        #expect(pinch.receive(-1, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(scroll.magnification == 1 && scroll.horizontalScrollElasticity == elasticity && abs(scroll.contentView.bounds.minX) < 0.001)
        pinch.setActiveTab(second, openTabs: [first, second])
        // The tab's own view moves on meanwhile (a reply came, followed to its end).
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1200))
        pinch.setActiveTab(first, openTabs: [first, second])
        pinch.completeLayout()
        #expect(scroll.magnification == 1 && abs(scroll.contentView.bounds.minY - 1200) < 0.001)
    }

    /// A page wider than its view keeps the sideways place its own scroll gave it when a pinch
    /// ends with nothing magnified (owner, 0.3.10: "I cannot scroll to the right and keep it
    /// there"), and text starting left of 0 under a gutter keeps its left edge.
    @Test(arguments: [(inset: CGFloat(0), x: CGFloat(200)), (inset: 50, x: 200), (inset: 50, x: -50)])
    func aWidePagesOwnSidewaysScrollStays(inset: CGFloat, x: CGFloat) {
        let (window, scroll, text, point) = editor()
        // Unwrapped, as the editor is with wrap off: as wide as its longest line.
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.string = (0..<100).map { "Line \($0), " + String(repeating: "a long line run off the right edge, ", count: 6) }.joined(separator: "\n")
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        text.sizeToFit()
        if inset > 0 {
            // The editor's line-number gutter: a ruler the text runs under.
            let ruler = NSRulerView(scrollView: scroll, orientation: .verticalRuler)
            ruler.ruleThickness = inset
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            window.contentView?.layoutSubtreeIfNeeded()
        }
        scroll.contentView.scroll(to: CGPoint(x: x, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.contentView.bounds.minX - x) < 0.001, "insets \(scroll.contentView.contentInsets.left), x \(scroll.contentView.bounds.minX)")
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(scroll.magnification == 1 && abs(scroll.contentView.bounds.minX - x) < 0.001, "x \(scroll.contentView.bounds.minX), page \(text.frame.width)")
        // Pinched in and back out: the page's own scroll still holds it, within its bounds.
        #expect(pinch.receive(0.5, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(pinch.receive(-1, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        let clip = scroll.contentView
        #expect(scroll.magnification == 1 && clip.constrainBoundsRect(clip.bounds).minX == clip.bounds.minX, "x \(clip.bounds.minX)")
    }

    /// A page as wide as its view (wrapped text) comes back to its text's left edge after a pinch:
    /// under the editor's gutter that's left of 0, so no text sits under the gutter.
    @Test func aWrappedPageUnderAGutterComesBackToItsTextsLeftEdge() {
        let (window, scroll, _, point) = editor()
        let ruler = NSRulerView(scrollView: scroll, orientation: .verticalRuler)
        ruler.ruleThickness = 50
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        window.contentView?.layoutSubtreeIfNeeded()
        let left = -scroll.contentView.contentInsets.left
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.5, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(pinch.receive(-1, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(left == -50 && scroll.magnification == 1 && abs(scroll.contentView.bounds.minX - left) < 0.001, "x \(scroll.contentView.bounds.minX)")
    }

    /// Left magnified, a page comes back so, where it was; at the natural size meanwhile it's drawn
    /// from its left edge. Other content in its place starts at the natural size.
    @Test func aPageLeftMagnifiedComesBackOnlyToItsOwnContent() {
        let (window, scroll, _, point) = editor()
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        let first = UUID(), second = UUID()
        pinch.setActiveTab(first, openTabs: [first, second])
        #expect(pinch.receive(0.5, phase: .began, at: CGPoint(x: 450, y: 200)))
        #expect(pinch.receive(0, phase: .ended, at: CGPoint(x: 450, y: 200)))
        pinch.completeLayout()
        let scale = scroll.magnification, origin = scroll.contentView.bounds.origin
        #expect(scale > 1 && origin.x > 1)
        pinch.setActiveTab(second, openTabs: [first, second])
        #expect(scroll.magnification == 1 && abs(scroll.contentView.bounds.minX) < 0.001)
        pinch.setActiveTab(first, openTabs: [first, second])
        pinch.completeLayout()
        #expect(abs(scroll.magnification - scale) < 0.00001)
        #expect(hypot(scroll.contentView.bounds.minX - origin.x, scroll.contentView.bounds.minY - origin.y) < 0.00001)
        pinch.setActiveTab(second, openTabs: [first, second])
        scroll.documentView = EditorTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 2000))
        pinch.setActiveTab(first, openTabs: [first, second])
        pinch.completeLayout()
        #expect(scroll.magnification == 1 && abs(scroll.contentView.bounds.minX) < 0.001)
        _ = point
    }
}

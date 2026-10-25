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
        #expect(scroll.magnification == 0.5 && zoom.scale == 1 && zoom.commits == 0)
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

}

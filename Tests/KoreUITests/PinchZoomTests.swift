import AppKit
import PDFKit
import QuartzCore
import Testing
import WebKit
@testable import KoreUI

@MainActor @Suite("Composited pinch zoom", .serialized)
struct PinchZoomTests {
    init() { _ = NSApplication.shared }

    private func editor() -> (NSWindow, NSScrollView, EditorTextView, CGPoint) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let text = EditorTextView(frame: CGRect(x: 0, y: 0, width: 480, height: 2000))
        text.string = (0..<100).map { "Line \($0), some text to preserve under the cursor." }.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scroll.documentView = text
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, scroll, text, CGPoint(x: 200, y: 200))
    }

    @Test func gestureSamplesOnlyCompositeUntilOneSemanticCommit() {
        let (window, scroll, text, point) = editor()
        var writes: [CGFloat] = []
        let zoom = Zoom(saved: 1, persist: { writes.append($0) })
        let pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        let selection = NSRange(location: 10, length: 7)
        text.setSelectedRange(selection)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0, phase: .began, at: point))
        #expect(PinchZoom.isAdjusting(scroll))
        for _ in 0..<120 { #expect(pinch.receive(0.001, phase: .changed, at: point)) }
        #expect(zoom.scale == 1 && writes.isEmpty && zoom.commits == 0)
        #expect(pinch.counts.previews == 120)
        #expect(text.selectedRange() == selection)
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(abs(zoom.scale - 1.12) < 0.00001)
        #expect(writes.count == 1 && pinch.counts.commits == 1 && zoom.commits == 1)
        pinch.completeLayout()
        #expect(!PinchZoom.isAdjusting(scroll))
        #expect(text.selectedRange() == selection)
    }

    @Test func cancellationRestoresTheOriginalLayerAndDoesNotPersist() throws {
        let (window, scroll, _, point) = editor()
        scroll.contentView.wantsLayer = true
        let layer = try #require(scroll.contentView.layer)
        layer.sublayerTransform = CATransform3DMakeTranslation(3, 4, 0)
        let original = layer.sublayerTransform
        var writes = 0
        let zoom = Zoom(saved: 1, persist: { _ in writes += 1 }), pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.25, phase: .began, at: point))
        #expect(!CATransform3DEqualToTransform(layer.sublayerTransform, original))
        #expect(pinch.receive(0, phase: .cancelled, at: point))
        #expect(CATransform3DEqualToTransform(layer.sublayerTransform, original))
        #expect(zoom.scale == 1 && writes == 0 && !PinchZoom.isAdjusting(scroll))
        #expect(pinch.counts.cancellations == 1)
    }

    @Test(arguments: [CGPoint(x: 0.5, y: 0.5), CGPoint.zero, CGPoint(x: 1, y: 0.3)])
    func compositePreviewKeepsItsCursorPivotFixed(anchor: CGPoint) throws {
        let (window, scroll, _, point) = editor()
        scroll.contentView.wantsLayer = true
        let layer = try #require(scroll.contentView.layer)
        layer.anchorPoint = anchor
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        let local = scroll.contentView.convert(point, from: nil)
        let marker = CALayer()
        marker.anchorPoint = .zero
        marker.position = CGPoint(x: local.x - scroll.contentView.bounds.minX + layer.bounds.minX,
                                  y: local.y - scroll.contentView.bounds.minY + layer.bounds.minY)
        layer.addSublayer(marker)
        let before = marker.convert(CGPoint.zero, to: layer)
        #expect(pinch.receive(0.3, phase: .began, at: point))
        let after = marker.convert(CGPoint.zero, to: layer)
        #expect(abs(after.x - before.x) < 0.001 && abs(after.y - before.y) < 0.001)
        marker.removeFromSuperlayer()
    }

    @Test func limitsInvalidSamplesNoOpGesturesAndSavedValuesAreSafe() {
        let (window, scroll, _, point) = editor()
        var writes = 0
        let zoom = Zoom(saved: .nan, persist: { _ in writes += 1 }), pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(zoom.scale == 1)
        #expect(pinch.receive(.infinity, phase: .began, at: point))
        #expect(pinch.receive(.nan, phase: .changed, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        #expect(writes == 0 && !PinchZoom.isAdjusting(scroll))
        #expect(pinch.receive(100, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(zoom.scale == 1.8 && writes == 1)
        #expect(pinch.receive(-100, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(zoom.scale == 0.7 && writes == 2)
        #expect(!zoom.commitPinch(.infinity) && !zoom.commitPinch(.nan))
        #expect(writes == 2)
    }

    @Test func resizeDetachAndExternalKeyboardZoomEndThePreviewSafely() {
        let (window, scroll, _, point) = editor()
        var writes = 0
        let zoom = Zoom(saved: 1, persist: { _ in writes += 1 }), pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.2, phase: .began, at: point))
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        #expect(!PinchZoom.isAdjusting(scroll) && writes == 0)
        #expect(pinch.receive(0.2, phase: .began, at: point))
        window.setContentSize(CGSize(width: 520, height: 420))
        #expect(!PinchZoom.isAdjusting(scroll) && writes == 0)
        #expect(pinch.receive(0.2, phase: .began, at: point))
        zoom.zoomIn()
        #expect(pinch.receive(0.1, phase: .changed, at: point))
        #expect(!PinchZoom.isAdjusting(scroll) && zoom.scale == 1.1 && writes == 1)
        #expect(pinch.receive(0.2, phase: .began, at: point))
        pinch.detach()
        #expect(!PinchZoom.isAdjusting(scroll) && writes == 1)
    }

    @Test func changingFirstResponderInsideTheWindowCancelsBeforeAnyCommit() {
        let (window, scroll, text, point) = editor()
        var writes = 0
        let zoom = Zoom(saved: 1, persist: { _ in writes += 1 }), pinch = PinchZoom(zoom: zoom)
        let other = NSTextView(frame: CGRect(x: 300, y: 0, width: 100, height: 40))
        text.addSubview(other)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(window.makeFirstResponder(text))
        #expect(pinch.receive(0.2, phase: .began, at: point))
        #expect(window.makeFirstResponder(other))
        #expect(pinch.receive(0.1, phase: .changed, at: point))
        #expect(!PinchZoom.isAdjusting(scroll) && zoom.scale == 1 && writes == 0)
        #expect(pinch.counts.cancellations == 1)
    }

    @Test func beginningAPinchReplacesTheScrollTargetOnlyOnce() {
        let (window, scroll, _, point) = editor()
        let shift = ScrollShift()
        shift.attach(scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        var frozen: [CGFloat] = []
        shift.onZoomBegin = { frozen.append($0) }
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); shift.onZoomBegin = nil; window.contentView = nil }
        let offset = scroll.contentView.bounds.minY
        #expect(pinch.receive(0, phase: .began, at: point))
        #expect(frozen == [offset])
        for _ in 0..<120 { #expect(pinch.receive(0.0001, phase: .changed, at: point)) }
        #expect(frozen == [offset])
        #expect(pinch.receive(0, phase: .cancelled, at: point))
        #expect(frozen == [offset])
    }

    @Test(arguments: [true, false])
    func nativeScrollAttemptsAreHeldUntilCancellationThenRelease(posted: Bool) {
        let (window, scroll, _, point) = editor()
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = posted
        clip.scroll(to: CGPoint(x: 0, y: 300))
        let held = clip.bounds.origin
        var writes = 0
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in writes += 1 }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.1, phase: .began, at: point))
        #expect(clip.postsBoundsChangedNotifications)
        for delta in [20.0, 40.0, -20.0] {
            clip.scroll(to: CGPoint(x: held.x, y: held.y + delta))
            #expect(clip.bounds.origin == held)
        }
        #expect(pinch.counts.corrections == 3 && writes == 0)
        #expect(pinch.receive(0, phase: .cancelled, at: point))
        #expect(clip.postsBoundsChangedNotifications == posted)
        clip.scroll(to: CGPoint(x: held.x, y: held.y + 40))
        #expect(clip.bounds.minY > held.y && pinch.counts.corrections == 3)
    }

    @Test func endingReleasesNativeBoundsHoldBeforeRestoringTheTextAnchor() {
        let (window, scroll, _, point) = editor()
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.scroll(to: CGPoint(x: 0, y: 300))
        let held = clip.bounds.origin
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(pinch.receive(0.1, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        clip.scroll(to: CGPoint(x: held.x, y: held.y + 40))
        #expect(clip.bounds.minY > held.y && pinch.counts.corrections == 0)
        pinch.completeLayout()
        #expect(clip.postsBoundsChangedNotifications && pinch.counts.commits == 1)
        let landed = clip.bounds.minY
        clip.scroll(to: CGPoint(x: held.x, y: landed + 30))
        #expect(clip.bounds.minY > landed && pinch.counts.corrections == 0)
    }

    @Test func nativeMagnifyingScrollViewsAndUnphasedInputAreNotCaptured() {
        let (window, scroll, _, point) = editor()
        let zoom = Zoom(saved: 1, persist: { _ in Issue.record("Native gestures must not change app zoom") })
        let pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        #expect(!pinch.receive(0.2, phase: [], at: point))
        scroll.allowsMagnification = true
        #expect(!pinch.receive(0.2, phase: .began, at: point))
        #expect(zoom.scale == 1 && pinch.counts.previews == 0)
    }

    @Test func endCommitKeepsTheEditorCharacterNearItsCursor() throws {
        let (window, scroll, text, point) = editor()
        // Match an unwrapped source editor with a real horizontal scroll range. A wrapped
        // document narrower than its viewport cannot pan sideways to hold the same glyph.
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = CGSize(width: 1e7, height: 1e7)
        text.frame.size.width = 4000
        text.string = (0..<100).map { "Line \($0) " + String(repeating: "some text to preserve under the cursor. ", count: 8) }.joined(separator: "\n")
        let zoom = Zoom(saved: 1, persist: { scale in text.font = .monospacedSystemFont(ofSize: 13 * scale, weight: .regular) })
        let pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        let before = text.characterIndexForInsertion(at: text.convert(point, from: nil))
        #expect(pinch.receive(0.1, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        let after = text.characterIndexForInsertion(at: text.convert(point, from: nil))
        #expect(abs(after - before) <= 1)
        let placed = try #require(pinch.placement)
        #expect(!placed.horizontalClamped && !placed.verticalClamped)
    }

    @Test func wrappedEditorKeepsItsLineAndUsesTheNearestFeasibleHorizontalPosition() throws {
        let (window, scroll, text, point) = editor()
        let zoom = Zoom(saved: 1, persist: { scale in text.font = .monospacedSystemFont(ofSize: 13 * scale, weight: .regular) })
        let pinch = PinchZoom(zoom: zoom)
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        let before = text.characterIndexForInsertion(at: text.convert(point, from: nil))
        let line = (text.string as NSString).lineRange(for: NSRange(location: before, length: 0))
        #expect(pinch.receive(0.1, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        let after = text.characterIndexForInsertion(at: text.convert(point, from: nil))
        #expect((text.string as NSString).lineRange(for: NSRange(location: after, length: 0)) == line)
        let placed = try #require(pinch.placement)
        #expect(placed.horizontalClamped && !placed.verticalClamped)
        #expect(placed.desiredOrigin.x > placed.actualOrigin.x)
        #expect(placed.unavoidableDrift.dx > 0 && abs(placed.unavoidableDrift.dy) < 0.5)
        #expect(scroll.contentView.bounds == scroll.contentView.constrainBoundsRect(scroll.contentView.bounds))
    }
}

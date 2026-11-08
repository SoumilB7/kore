import AppKit
import SwiftUI
import Testing
@testable import KoreUI

/// SwiftUI's scroll view hit-tests its page as if unmagnified; a magnified page's pointer events
/// are re-aimed for it (`PinchZoom`), and only while it's magnified.
@MainActor @Suite("Pointer on a magnified page", .serialized)
struct PinchZoomPointerTests {
    init() { _ = NSApplication.shared }

    /// A SwiftUI scroll view's page that takes a pinch, as a preview's column does.
    private func swiftUIPage() throws -> (NSWindow, NSScrollView, ScrollShift) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ScrollView {
            VStack(spacing: 0) { ForEach(0..<40, id: \.self) { n in Color.gray.frame(width: 500, height: 40).overlay { Text("Row \(n)") } } }
        })
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.scrollView(in: host))
        let shift = ScrollShift()
        shift.pinches = true
        shift.attach(scroll)
        return (window, scroll, shift)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 1)!
    }

    @Test func theDrawnPointGoesTowardsTheViewsCornerByTheMagnification() {
        let corner = CGPoint(x: 0, y: 760)
        let aimed = PinchZoom.aimed(CGPoint(x: 917, y: 265), corner: corner, scale: 1.5)
        #expect(abs(aimed.x - 611.333) < 0.001 && abs(aimed.y - 430) < 0.001)
        #expect(PinchZoom.aimed(CGPoint(x: 917, y: 265), corner: corner, scale: 1) == CGPoint(x: 917, y: 265))
        #expect(PinchZoom.aimed(corner, corner: corner, scale: 3) == corner)
    }

    @Test func aMagnifiedSwiftUIPageReaimsItsPressesAndMovesOnlyWhileMagnified() throws {
        let (window, scroll, shift) = try swiftUIPage()
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); shift.pinches = false; window.contentView = nil }
        let center = CGPoint(x: 250, y: 200)
        #expect(!pinch.aiming)
        #expect(pinch.receive(0, phase: .began, at: center))
        #expect(pinch.receive(1, phase: .changed, at: center))
        #expect(pinch.receive(0, phase: .ended, at: center))
        pinch.completeLayout()
        #expect(abs(scroll.magnification - 2) < 0.001 && pinch.aiming)

        let clip = scroll.contentView
        let corner = clip.convert(clip.bounds.origin, to: nil)
        let point = CGPoint(x: 300, y: 120)
        let expected = PinchZoom.aimed(point, corner: corner, scale: 2)
        // A move is re-aimed over the page; off it (outside the window) it's left as it is.
        let far = CGPoint(x: -50, y: -50)
        let move = pinch.aim(event(.mouseMoved, point, in: window))
        #expect(move.locationInWindow == expected && move.drawnLocation == point)
        #expect(pinch.aim(event(.mouseMoved, far, in: window)).locationInWindow == far)
        let down = pinch.aim(event(.leftMouseDown, point, in: window))
        #expect(down.locationInWindow == expected && down.drawnLocation == point)
        // Its release goes with it, wherever it is.
        let up = pinch.aim(event(.leftMouseUp, far, in: window))
        #expect(up.locationInWindow == PinchZoom.aimed(far, corner: corner, scale: 2) && up.drawnLocation == far)
        // A ⌃-click is a context click, its release too: Kore's menus find their row through AppKit.
        #expect(pinch.aim(event(.leftMouseDown, point, in: window, modifiers: .control)).locationInWindow == point)
        #expect(pinch.aim(event(.leftMouseUp, point, in: window, modifiers: .control)).locationInWindow == point)
        // An event that isn't re-aimed reads where it is.
        #expect(event(.leftMouseDown, point, in: window).drawnLocation == point)

        // Back at its natural size: no monitor, events as they come.
        #expect(pinch.receive(0, phase: .began, at: center))
        #expect(pinch.receive(-1, phase: .changed, at: center))
        #expect(pinch.receive(0, phase: .ended, at: center))
        pinch.completeLayout()
        #expect(scroll.magnification == 1 && !pinch.aiming)
    }

    @Test func anAppKitPageHitTestsMagnifiedItselfAndIsNeverReaimed() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = EditorTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 2000))
        window.contentView = scroll
        let pinch = PinchZoom(zoom: Zoom(saved: 1, persist: { _ in }))
        pinch.attach(window)
        defer { pinch.detach(); window.contentView = nil }
        let point = CGPoint(x: 200, y: 200)
        #expect(pinch.receive(0.5, phase: .began, at: point))
        #expect(pinch.receive(0, phase: .ended, at: point))
        pinch.completeLayout()
        #expect(scroll.magnification > 1.4 && !pinch.aiming)
        #expect(pinch.aim(event(.leftMouseDown, point, in: window)).locationInWindow == point)
    }
}

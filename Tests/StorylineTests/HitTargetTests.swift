import AppKit
import KoreStorylines
import SwiftUI
import Testing

@testable import KoreUI

/// A control drawn smaller than `Size.hitTarget` takes clicks across that much, and no further,
/// and sits where it did. Clicks go in as events, as a pointer's would, to a window off screen.
@Suite("hit targets", .serialized)
@MainActor
struct HitTargetTests {
    private final class Hits {
        var count = 0
    }

    /// Clicks taken by `control` (made with the counter to bump), centred in a window of its own
    /// off screen, of one click `dx`, `dy` from the centre. The click goes straight to the app,
    /// press then release, with nothing posted to its queue: a posted event ends the test runner's
    /// main run loop when it lands outside the short run meant to take it, which other suites'
    /// clicks, running at the same time, can cause.
    private func clicks(dx: CGFloat, dy: CGFloat = 0, _ control: (Hits) -> some View) async throws -> Int {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Ordered in, off every screen: controls track the mouse only in a window that's shown.
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let hits = Hits()
        let host = NSHostingView(rootView: control(hits).frame(width: 300, height: 200))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let point = host.convert(CGPoint(x: 150 + dx, y: 100 + dy), to: nil)
        await InputDriver(window: { window }, real: nil).click(at: point, in: window)
        return hits.count
    }

    private static let glyph = Size.closeGlyph
    private static let reach = HitTarget.reach(width: glyph, height: glyph)

    private func square(_ hits: Hits, reaching: Bool) -> some View {
        Button { hits.count += 1 } label: {
            Color.gray.frame(width: Self.glyph, height: Self.glyph).hitTarget(reaching ? Self.reach : EdgeInsets())
        }
        .buttonStyle(.plain)
        .hitTargetRoom(reaching ? Self.reach : EdgeInsets())
    }

    @Test func aSmallControlTakesClicksJustPastItsEdge() async throws {
        let edge = Self.glyph / 2
        #expect(try await clicks(dx: edge - 2) { square($0, reaching: false) } == 1)
        #expect(try await clicks(dx: edge + 2) { square($0, reaching: false) } == 0)
        #expect(try await clicks(dx: edge + 2) { square($0, reaching: true) } == 1)
        #expect(try await clicks(dx: -edge - 2) { square($0, reaching: true) } == 1)
    }

    @Test func noFurtherThanTheTarget() async throws {
        #expect(try await clicks(dx: Size.hitTarget / 2 + 1.5) { square($0, reaching: true) } == 0)
    }

    @Test func itSitsWhereItDid() {
        let hits = Hits()
        #expect(NSHostingView(rootView: square(hits, reaching: true).fixedSize()).fittingSize == CGSize(width: Self.glyph, height: Self.glyph))
        let small = NSHostingView(rootView: Button("Use reset") {}.smallButton().fixedSize()).fittingSize
        #expect(small.height == Size.smallButton)
    }

    @Test func aMiniIconButtonAndASmallButtonReach() async throws {
        let mini = Size.MessageActions.button / 2
        #expect(try await clicks(dx: mini + 0.5) { hits in IconButton(symbol: "doc.on.doc", kind: .mini, help: "Copy") { hits.count += 1 } } == 1)
        #expect(try await clicks(dx: mini + 2) { hits in IconButton(symbol: "doc.on.doc", kind: .mini, help: "Copy") { hits.count += 1 } } == 0)
        let small = Size.smallButton / 2
        #expect(try await clicks(dx: 0, dy: small + 1.5) { hits in Button("Use reset") { hits.count += 1 }.smallButton() } == 1)
        #expect(try await clicks(dx: 0, dy: -small - 1.5) { hits in Button("Use reset") { hits.count += 1 }.smallButton() } == 1)
    }
}

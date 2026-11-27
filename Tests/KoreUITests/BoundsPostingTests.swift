import AppKit
import SwiftUI
import Testing
@testable import KoreUI

/// A clip's `postsBoundsChangedNotifications` is one flag several parts of Kore turn on and put
/// back. `ScrollShift` reads the reader's moves by it; the others (a pinch, a hold, the copy
/// button's `VisibleRightEdge`) put back only what they found, and they find it on.
@MainActor @Suite("Bounds posting shared by the clip's watchers", .serialized)
struct BoundsPostingTests {
    init() { _ = NSApplication.shared }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = scrollView(in: sub) { return scroll }
        }
        return nil
    }

    @Test func swiftUIsClipPostsItsMovesAlready() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack {
                ForEach(0..<200, id: \.self) { Text("Row \($0)").frame(height: 30) }
            }
        })
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.scrollView(in: host))
        // SwiftUI's clip posts already: the copy button's probe finds it on and leaves it on.
        // Off here, the probe would turn it off again as the hover ends, under `ScrollShift`.
        #expect(scroll.contentView.postsBoundsChangedNotifications)
    }
}

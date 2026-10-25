import AppKit
import KoreUI

/// An element a locator found: a live registration in the StoryID registry. Its frame is worked
/// out each time it's asked for, so it's right for the window's size, zoom and scroll at that moment.
@MainActor
package struct StoryElement {
    package let id: StoryID
    let entry: StoryRegistry.Entry

    package init?(_ id: StoryID) {
        guard let entry = StoryRegistry.entry(id.raw) else { return nil }
        self.id = id
        self.entry = entry
    }

    /// The element of that name in `window`, rather than the latest window's.
    package init?(_ id: StoryID, in window: NSWindow) {
        guard let entry = StoryRegistry.entry(id.raw, in: window) else { return nil }
        self.id = id
        self.entry = entry
    }

    package var window: NSWindow? { entry.window }
    /// In the window's base coordinates; nil once the element has left its window.
    package var frame: CGRect? { entry.frame }
    package var hasPress: Bool { entry.press != nil }
    package var press: (@MainActor () -> Void)? { entry.press }

    /// The view that registered it, wherever the element is scrolled to.
    package var registeredView: NSView? { entry.registeredView }

    /// The AppKit view under the element's centre: the control itself, not the registrar.
    package var view: NSView? {
        guard let window, let frame, let content = window.contentView else { return nil }
        return content.hitTest(CGPoint(x: frame.midX, y: frame.midY))
    }
}

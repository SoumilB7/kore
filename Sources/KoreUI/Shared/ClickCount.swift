import AppKit

extension NSApplication {
    /// How many clicks the event being handled is part of, or 1 when it isn't a mouse click (a
    /// button pressed from the keyboard, an accessibility action). `NSEvent.clickCount` raises
    /// for any other event type, so actions that tell a double click apart read this instead.
    var mouseClickCount: Int {
        guard let event = currentEvent else { return 1 }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.clickCount
        default:
            return 1
        }
    }
}

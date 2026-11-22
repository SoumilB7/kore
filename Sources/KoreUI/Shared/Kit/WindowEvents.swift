import AppKit

/// Local event monitors for what a window's keys and presses do. While Kore's question is up over
/// a window (`KoreAsk`), that window's keys are the question's: no monitor made here sees them,
/// whatever order AppKit runs monitors in (it keeps none). Every monitor outside Shared/Kit is
/// made here (scripts/lint-theme.sh).
@MainActor
enum WindowEvents {
    static func monitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.type == .keyDown, let window = event.window, KoreAsk.shared.holds(window) { return event }
            return handler(event)
        }
    }
}

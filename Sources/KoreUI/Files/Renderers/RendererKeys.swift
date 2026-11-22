import AppKit
import SwiftUI

/// Window keys for a renderer while it's on screen: ⌘= ⌘- ⌘0 zoom the file instead of the
/// app's text, ⌘F finds in it, and so on. The handler gets the event's characters (lowercased)
/// and modifiers, and returns true when it used the key. Keys typed into another text field
/// (the explorer's rename, the chat composer) are left alone, except Esc and Return.
struct RendererKeys: ViewModifier {
    let handle: (_ key: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> Bool
    @StateObject private var monitor = Held<Any?>(nil)
    @StateObject private var anchor = Held<NSView?>(nil)

    func body(content: Content) -> some View {
        content
            .background(AnchorView { anchor.value = $0; arm() })
            .onAppear {
                guard monitor.value == nil else { return }
                defer { arm() }
                monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let window = anchor.value?.window, event.window === window else { return event }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    let typing = window.firstResponder is NSText && !flags.contains(.command)
                    if typing && event.keyCode != 53 { return event }
                    return handle((event.charactersIgnoringModifiers ?? "").lowercased(), flags, event.keyCode) ? nil : event
                }
            }
            .onDisappear {
                if let value = monitor.value { NSEvent.removeMonitor(value) }
                monitor.value = nil
                if let view = anchor.value { Self.armed.remove(view) }
            }
    }

    /// Storylines: the renderers taking keys now, by their anchor (its window known, the monitor on).
    @MainActor private static let armed = NSHashTable<NSView>.weakObjects()
    @MainActor private func arm() {
        guard StoryHost.installed, monitor.value != nil, let view = anchor.value else { return }
        Self.armed.add(view)
    }
    /// Storylines: a renderer in `window` takes its keys.
    @MainActor static func storyTakesKeys(in window: NSWindow?) -> Bool {
        Self.armed.allObjects.contains { $0.window != nil && $0.window === window }
    }
}

extension View {
    func rendererKeys(_ handle: @escaping (_ key: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> Bool) -> some View {
        modifier(RendererKeys(handle: handle))
    }
}

/// Reports the NSView it's backed by, for its window.
private struct AnchorView: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Storylines: a file renderer in `window` takes its keys now (⌘C, ⌘=, ⌘F).
@MainActor package enum StoryRendererKeys {
    package static func taken(in window: NSWindow?) -> Bool { RendererKeys.storyTakesKeys(in: window) }
}

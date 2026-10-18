import AppKit
import SwiftUI

/// A popup from the / menu (Usage, Account), in the menu's place over the chat: a card at most
/// `usagePopupMax` wide at the composer's leading edge, opaque, no shadow. `room`: the most it
/// may be tall, scrolling past it; nil, its content's height.
///
/// Esc steps back (`stepBack`) and, with nothing to step back from, closes it and goes no
/// further; Return closes it and never sends nor confirms; any other key closes it and goes on
/// to the field; a click outside it closes it and goes on. So the composer keeps focus
/// throughout (the context card's monitor pattern). What reaches the draft without a key here
/// (a paste the composer takes first, a menu's Paste, dictation) closes it too, as the draft
/// changes; it shows only once open, so the change that opened it never counts. While a field
/// or form in it is open (`editing`), every key is the field's and never closes it, Return
/// included; Esc still steps back, and a click outside still closes it. Otherwise ⇥ and ⇧⇥ ring
/// its buttons in turn (`tabStop`), and Return or Space presses the ringed one; `keys` takes the
/// keys a list in it moves by (↑ ↓) before any of that.
struct ComposerPopup<Content: View>: View {
    let chat: Chat
    let id: StoryID
    var room: CGFloat?
    /// Still open: a popup fading out takes no more keys or clicks.
    let isOpen: @MainActor () -> Bool
    let stepBack: @MainActor () -> Bool
    let close: @MainActor () -> Void
    var editing: @MainActor () -> Bool = { false }
    /// A key the content takes first (a list's ↑ ↓ and Return): true when taken.
    var keys: @MainActor (NSEvent) -> Bool = { _ in false }
    @ViewBuilder let content: () -> Content
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)
    @StateObject private var stops = Held(TabStops())

    var body: some View {
        sized
            .tabStops(stops.value)
            .panel(.panel)
            .frame(maxWidth: Size.usagePopupMax)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
            .background(WindowReader { window.value = $0 })
            .storyID(id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: chat.draft) { close() }
            .onChange(of: chat.attachments.count) { close() }
            .onAppear {
                monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
            }
            .onDisappear {
                if let m = monitor.value { NSEvent.removeMonitor(m) }
                monitor.value = nil
            }
    }

    @ViewBuilder private var sized: some View {
        if let room {
            ScrollView {
                padded
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: room)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            padded
        }
    }

    private var padded: some View {
        content()
            .padding(Inset.well)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window, isOpen() else { return event }
        // Esc steps back one at a time, then closes.
        if event.type == .keyDown, event.keyCode == 53, stepBack() { return nil }
        if event.type == .keyDown, event.keyCode != 53, keys(event) { return nil }
        // A field has the keys: Tab, Return and the rest are its own.
        if event.type == .keyDown, event.keyCode != 53, editing() { return event }
        if event.type == .keyDown {
            if stops.value.handle(event) { return nil }
            close()
            // Esc, Return, keypad Enter.
            return [53, 36, 76].contains(event.keyCode) ? nil : event
        }
        guard let content = window.contentView else { return event }
        stops.value.clear()
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point) { close() }
        return event
    }
}

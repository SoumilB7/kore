import AppKit
import SwiftUI
import KoreUI

/// Where a scroll goes.
package enum ScrollTarget: Sendable, CustomStringConvertible {
    case top, bottom
    /// Points; positive moves down the content (towards its end).
    case by(CGFloat)

    package var description: String {
        switch self {
        case .top: "top"
        case .bottom: "bottom"
        case .by(let d): "\(Int(d)) pt"
        }
    }
}

/// How a storyline acts on Kore (phase 12, §4). Everything here stays inside the process: events
/// are built in Kore and handed to AppKit, nothing goes through the window server, and nothing
/// needs the app active or its window key, so the owner keeps their focus. Real input (the only
/// way to hover) is a separate mode, given only with `--real-input`.
@MainActor
package final class InputDriver {
    private let storyWindow: () -> NSWindow?
    package let real: RealInput?

    package init(window: @escaping () -> NSWindow?, real: RealInput?) {
        self.storyWindow = window
        self.real = real
    }

    // MARK: Pointer

    /// The element's registered action, with no pointer; without one, a click at its centre.
    package func press(_ element: StoryElement) async throws {
        guard let press = element.press else { return try await click(element) }
        press()
        await pass()
    }

    package func click(_ element: StoryElement, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async throws {
        let (window, point) = try await aim(element)
        for n in 1...max(count, 1) {
            click(.leftMouseDown, .leftMouseUp, at: point, in: window, clickCount: n, modifiers: modifiers)
        }
        await pass()
    }

    package func rightClick(_ element: StoryElement) async throws {
        let (window, point) = try await aim(element)
        click(.rightMouseDown, .rightMouseUp, at: point, in: window)
        await pass()
    }

    /// A press and release at a point. The release is queued first, so a view that tracks the
    /// mouse in its press (a text view selecting) finds it, and is sent after when nothing took it.
    /// A window that isn't key keeps a first click for itself unless the view under it accepts
    /// the first mouse; a storyline's window is never key, so an AppKit view's click (the
    /// editor's text) goes to the view itself, which first becomes the window's first responder
    /// when it takes one, as the key window makes the view a click lands on.
    private func click(
        _ downType: NSEvent.EventType, _ upType: NSEvent.EventType, at point: CGPoint, in window: NSWindow,
        clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let down = mouseEvent(downType, at: point, in: window, clickCount: clickCount, modifiers: modifiers),
            let up = mouseEvent(upType, at: point, in: window, clickCount: clickCount, modifiers: modifiers)
        else { return }
        Self.enqueue(up)
        let mask: NSEvent.EventTypeMask = upType == .rightMouseUp ? .rightMouseUp : .leftMouseUp
        if let view = window.contentView?.hitTest(point), !window.isKeyWindow, !Self.isSwiftUI(view), !view.acceptsFirstMouse(for: down) {
            // Both halves to the view: the window, having kept no press, would drop the release.
            if view.acceptsFirstResponder, window.firstResponder !== view { window.makeFirstResponder(view) }
            if downType == .rightMouseDown { view.rightMouseDown(with: down) } else { view.mouseDown(with: down) }
            if let queued = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
                if upType == .rightMouseUp { view.rightMouseUp(with: queued) } else { view.mouseUp(with: queued) }
            }
        } else {
            // Through the app, so local event monitors (outside-click handling) see it too.
            NSApp.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
        }
    }

    /// Puts an event at the back of the app's queue. Posting one stops the main run loop's
    /// current run when the app isn't in its event loop (`NSApp.run`): AppKit's way to hand the
    /// event to a loop that isn't reading events. Kore's host is always in it. A host that isn't,
    /// such as a test runner on a plain run loop, would have its main loop end and the process
    /// exit mid-run, so there the event is posted inside a short nested run that takes the stop.
    private static func enqueue(_ event: NSEvent) {
        if NSApp.isRunning {
            NSApp.postEvent(event, atStart: false)
            return
        }
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) { NSApp.postEvent(event, atStart: false) }
        _ = CFRunLoopRunInMode(.defaultMode, 1, false)
    }

    /// A press, a pointer moved in steps (a run-loop pass between each, so gestures see motion),
    /// and a release over `target`. It drives SwiftUI drag gestures and AppKit tracking; a system
    /// drag session (`.onDrag`) needs the window server, so drops go through the target's action.
    package func drag(_ element: StoryElement, to target: StoryElement, steps: Int = 8) async throws {
        let (window, start) = try await aim(element)
        let (_, end) = try await aim(target)
        mouse(.leftMouseDown, at: start, in: window)
        for i in 1...max(steps, 1) {
            let t = CGFloat(i) / CGFloat(max(steps, 1))
            await pass()
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), in: window)
        }
        await pass()
        mouse(.leftMouseUp, at: end, in: window)
        await pass()
    }

    /// Scrolls the list the element sits in, wherever in it the element is, by moving its scroll
    /// view: where a scroll gesture ends up, without the gesture. (Wheel and trackpad events built
    /// in the process don't reach SwiftUI's scroll views; the spike behind this showed none
    /// moving one.) The list reacts as to any scroll: lazy rows build, paging loads.
    package func scroll(_ element: StoryElement, to target: ScrollTarget) async throws {
        guard let scrollView = Self.scrollView(holding: element.registeredView), let document = scrollView.documentView else {
            throw StoryFailure.other("\(element.id) isn't in a scroll view")
        }
        let clip = scrollView.contentView
        // The clip's range: from above the content by the top inset (under the title bar) to
        // the content's end plus the bottom inset. A flipped document's top is the low end.
        func range() -> (low: CGFloat, high: CGFloat) {
            let insets = scrollView.contentInsets
            let low = -(document.isFlipped ? insets.top : insets.bottom)
            let high = document.bounds.height - clip.bounds.height + (document.isFlipped ? insets.bottom : insets.top)
            return (low, max(high, low))
        }
        func place() -> CGFloat {
            let (low, high) = range()
            switch target {
            case .top: return document.isFlipped ? low : high
            case .bottom: return document.isFlipped ? high : low
            case .by(let delta): return min(max(clip.bounds.origin.y + (document.isFlipped ? delta : -delta), low), high)
            }
        }
        try await liveScroll(scrollView, to: place())
        // A lazy list grows as rows build at the new place: an end is reached when it stays put.
        if case .by = target { return }
        for _ in 0..<20 {
            let y = place()
            if abs(y - clip.bounds.origin.y) < 0.5 { return }
            try await liveScroll(scrollView, to: y)
        }
    }

    /// Centres the element in its scroll view's visible part.
    private func bringIntoView(_ element: StoryElement, in scrollView: NSScrollView) async throws {
        guard let document = scrollView.documentView, let frame = element.frame else { return }
        let clip = scrollView.contentView
        let inDocument = document.convert(frame, from: nil)
        let insets = scrollView.contentInsets
        let visible = clip.bounds.height - insets.top - insets.bottom
        let low = -(document.isFlipped ? insets.top : insets.bottom)
        let high = max(document.bounds.height - clip.bounds.height + (document.isFlipped ? insets.bottom : insets.top), low)
        let y = document.isFlipped
            ? inDocument.midY - insets.top - visible / 2
            : inDocument.midY - insets.bottom - visible / 2
        try await liveScroll(scrollView, to: min(max(y, low), high))
    }

    /// Whether a frame (window coordinates) is inside the visible part of the element's scroll
    /// view, or of its window when it isn't in one.
    private static func inView(_ frame: CGRect, of element: StoryElement) -> Bool {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let scrollView = scrollView(holding: element.registeredView) else {
            return element.window?.contentView?.frame.contains(point) ?? false
        }
        let insets = scrollView.contentInsets
        var visible = scrollView.convert(scrollView.bounds, to: nil)
        visible.origin.y += insets.bottom
        visible.size.height -= insets.top + insets.bottom
        return visible.contains(point)
    }

    /// Moves the clip framed as a live scroll, as a gesture is, so the scroll view's owner takes
    /// the new place as the reader's own rather than putting its old one back.
    private func liveScroll(_ scrollView: NSScrollView, to y: CGFloat) async throws {
        let clip = scrollView.contentView
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        await pass()
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        await pass()
    }

    // MARK: Keys

    /// One key, sent to the first place that takes it, in a real keypress's order (the input
    /// spike, 2026-10-21). The app's local event monitors see it first, as AppKit runs them
    /// before anything else (the editor's own keys, ⌘F ⌘S ⌘Z, are one). A key equivalent (⌘ or
    /// ⌃) they pass on then goes to the window's view tree, which SwiftUI's `.keyboardShortcut`
    /// needs, then to the menu item it matches, and last to the focused view as typed. Any
    /// other key goes through the app as typed.
    package func key(_ chord: KeyChord) async throws {
        let window = try keyWindow()
        guard let down = chord.event(.keyDown, in: window), let up = chord.event(.keyUp, in: window) else {
            throw StoryFailure.other("can't build the key \(chord)")
        }
        // The end of the event after each key, as between a person's keystrokes: what one key
        // set off (a selection, a binding's update) lands before the next.
        guard chord.isEquivalent else {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            return await pass()
        }
        if KeyGate.passesMonitors(down) {
            if !window.performKeyEquivalent(with: down), !menu(down, in: window) {
                // The monitors have seen it: straight to the window, not through the app again.
                window.sendEvent(down)
            }
        }
        NSApp.sendEvent(up)
        await pass()
    }

    /// Text typed into whatever has focus, a key per character. A line break is Return and a
    /// tab is Tab, as on a keyboard.
    package func type(_ text: String) async throws {
        for c in text {
            switch c {
            case "\n", "\r\n", "\r": try await key(.returnKey)
            case "\t": try await key(.tab)
            case " ": try await key(KeyChord(.space))
            default: try await key(KeyChord(.character(c)))
            }
        }
    }

    /// Modifiers pressed and released on their own (⌘ held for a hover's alternate state, say),
    /// as flags-changed events: the safe form of a modifier key (see `KeyChord`).
    package func flags(_ modifiers: NSEvent.ModifierFlags) throws {
        let window = try keyWindow()
        for flags in [modifiers, []] {
            if let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: Self.modifierCode(modifiers))
            {
                NSApp.sendEvent(event)
            }
        }
    }

    // MARK: Real input

    /// No synthetic event fires SwiftUI's `.onHover`, so hovering needs the real pointer.
    package func hover(_ element: StoryElement) async throws {
        guard let real else { throw StoryFailure.needsRealInput("hover \(element.id)") }
        let (window, point) = try await aim(element)
        try await real.move(to: point, in: window)
    }

    /// A click with the real pointer: for what only a real click shows.
    package func realClick(_ element: StoryElement, count: Int = 1) async throws {
        guard let real else { throw StoryFailure.needsRealInput("a real click on \(element.id)") }
        let (window, point) = try await aim(element)
        try await real.click(at: point, in: window, count: count)
    }

    /// A real key press, through the window server: a menu command's shortcut as the user
    /// presses it (focused-value commands answer only real focus). Needs `--real-keys`.
    package func realKey(_ chord: KeyChord) async throws {
        guard let real else { throw StoryFailure.needsRealInput("the real key \(chord)") }
        try await real.key(chord, in: try keyWindow())
    }

    /// Ends real input for the storyline: the cursor goes back, and so does the front.
    package func finish() { real?.finish() }

    // MARK: Building events

    private func keyWindow() throws -> NSWindow {
        guard let window = storyWindow() else { throw StoryFailure.other("the storyline has no window") }
        return window
    }

    /// A view of SwiftUI's own (its hosting views): SwiftUI takes a first click in a window
    /// that isn't key, and handles it only when the window delivers it.
    private static func isSwiftUI(_ view: NSView) -> Bool {
        Bundle(for: Swift.type(of: view)) == swiftUI
    }

    private static let swiftUI = Bundle(for: NSHostingView<EmptyView>.self)

    /// The element's window and centre, scrolled into view first when its list has it out of
    /// sight (as a person scrolls to what they click), and checked to be inside the window.
    private func aim(_ element: StoryElement) async throws -> (NSWindow, CGPoint) {
        guard let window = element.window, var frame = element.frame else {
            throw StoryFailure.elementNotFound(element.id.raw, nearby: StoryRegistry.nearest(to: element.id.raw))
        }
        if !Self.inView(frame, of: element), let scrollView = Self.scrollView(holding: element.registeredView) {
            try await bringIntoView(element, in: scrollView)
            frame = element.frame ?? frame
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let content = window.contentView, content.frame.contains(point), Self.inView(frame, of: element), !frame.isEmpty else {
            throw StoryFailure.other("\(element.id) is outside its window (\(Self.describe(frame)) in \(Self.describe(window.contentView?.frame ?? .zero)))")
        }
        return (window, point)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        if let event = mouseEvent(type, at: point, in: window) { NSApp.sendEvent(event) }
    }

    /// The menu item a key equivalent matches. Items with a target are performed by the menu; an
    /// item that goes up the responder chain (Copy, Paste, Select All) is sent to the storyline
    /// window's first responder, since AppKit would send it to the key window's.
    private func menu(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let main = NSApp.mainMenu else { return false }
        if let item = Self.item(in: main, matching: event), item.target == nil, let action = item.action {
            if NSApp.sendAction(action, to: window.firstResponder, from: item) { return true }
        }
        return main.performKeyEquivalent(with: event)
    }

    private static func item(in menu: NSMenu, matching event: NSEvent) -> NSMenuItem? {
        let typed = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for item in menu.items {
            if let sub = item.submenu, let found = Self.item(in: sub, matching: event) { return found }
            guard item.isEnabled, !item.keyEquivalent.isEmpty else { continue }
            var mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            // An uppercase equivalent implies ⇧.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            if item.keyEquivalent.lowercased() == typed, mask == flags { return item }
        }
        return nil
    }

    private static func scrollView(holding view: NSView?) -> NSScrollView? {
        var view = view
        while let v = view {
            if let scroll = v as? NSScrollView { return scroll }
            view = v.superview
        }
        return nil
    }

    private static func modifierCode(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        if flags.contains(.command) { return 55 }
        if flags.contains(.shift) { return 56 }
        if flags.contains(.option) { return 58 }
        if flags.contains(.control) { return 59 }
        return 63
    }

    private static func describe(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }

    /// The end of an event, as between a person's events: one turn of the app's event loop, so
    /// what the last event set off runs before the next, and AppKit closes the event as it does
    /// after each one it dispatches (an undo group per event: two presses are two undo steps).
    /// The driver hands its events to AppKit directly, so a marker event goes through the loop
    /// instead (or, should a loop of someone else's hold it, the end comes after a second). A
    /// host that isn't in the event loop (a test runner) gets a main-queue turn.
    private func pass() async {
        guard NSApp.isRunning else {
            return await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
        Self.marks += 1
        let mark = Self.marks
        guard let marker = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: Self.markerSubtype, data1: mark, data2: 0)
        else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let monitor = Box()
            let end = {
                guard let value = monitor.value else { return }
                NSEvent.removeMonitor(value)
                monitor.value = nil
                done.resume()
            }
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
                guard event.subtype.rawValue == Self.markerSubtype, event.data1 == mark else { return event }
                end()
                return nil
            }
            NSApp.postEvent(marker, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { end() }
        }
    }

    private static var marks = 0
    /// The driver's own application-defined events.
    private static let markerSubtype: Int16 = 0x4B53

    private final class Box { var value: Any? }
}

/// Finished with its storyline, pass or fail: the cursor and the front app go back.
extension InputDriver: StoryFinishing {}

extension StoryContext {
    /// This storyline's input driver, made on first use (real input only with `--real-input`).
    package var input: InputDriver {
        stash(InputDriver.self) {
            InputDriver(window: { [unowned self] in window }, real: flags.realInput ? RealInput(keys: flags.realKeys) : nil)
        }
    }
}

/// Runs a key down through the app's local event monitors alone. They're called inside
/// `NSApp.sendEvent`, in no fixed order, before AppKit routes the key on, and there's no API for
/// running them apart. So the key goes through the app with the routing after them stopped:
/// AppKit offers a key equivalent to the main menu (set aside meanwhile for one that only takes
/// note) or hands the key to its window (whose `sendEvent`, swapped in by the storyline driver
/// only, holds it at the door). A key that gets that far wasn't taken by any monitor, and the
/// driver then offers it to the window's views first, as AppKit does for the key window.
@MainActor
enum KeyGate {
    // Read from AppKit's callbacks, which run on the main thread inside `passesMonitors`.
    nonisolated(unsafe) private static var held: NSEvent?
    nonisolated(unsafe) private static var passed = false

    static func passesMonitors(_ event: NSEvent) -> Bool {
        install()
        held = event
        passed = false
        let menu = NSApp.mainMenu
        NSApp.mainMenu = Door(title: "")
        NSApp.sendEvent(event)
        NSApp.mainMenu = menu
        held = nil
        return passed
    }

    /// Whether `event` is the held key, which stops wherever it got to.
    nonisolated fileprivate static func stops(_ event: NSEvent) -> Bool {
        guard let held, event.type == .keyDown, event.timestamp == held.timestamp, event.keyCode == held.keyCode else { return false }
        passed = true
        return true
    }

    /// The main menu while a key is held: it takes the key, and only notes that it came.
    private final class Door: NSMenu {
        override func performKeyEquivalent(with event: NSEvent) -> Bool { KeyGate.stops(event) }
    }

    private static var installed = false

    private static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.sendEvent(_:))),
            let gated = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.storyGatedSendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, gated)
    }
}

extension NSWindow {
    /// `sendEvent` once `KeyGate` swaps it in: the held key stops here; everything else goes to
    /// the original (now under this selector).
    @objc fileprivate func storyGatedSendEvent(_ event: NSEvent) {
        if KeyGate.stops(event) { return }
        storyGatedSendEvent(event)
    }
}

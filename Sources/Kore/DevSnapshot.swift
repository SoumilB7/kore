import AppKit
import KoreCore

/// Debug hook for checking the UI without clicking through it:
///   KORE_OPEN=<folder>       open that folder's window at launch
///   KORE_START=claude|codex  start a chat of that provider in its first tab
///   KORE_RESUME=<agent>:<id> open that past session instead
///   KORE_SEND=<text>         send that message in the started chat
///   KORE_MODE=<mode id>      switch the started chat to that mode
///   KORE_MODEL=<model>       launch the started or resumed chat on that model (haiku / gpt-6-luna keep tests cheap)
///   KORE_ATTACH=<path>[:...] attach those files to the started chat's composer
///   KORE_PASTE=1             press ⌘V (a real key event) in the composer
///   KORE_THEN_SEND=<text>    after that, send this text with whatever got attached
///   KORE_FULLSCREEN=1        enter full screen before the snapshot
///   KORE_DRAG=<x>,<y>,<dx>,<dy> real drag from that point (after any clicks); logs the window's move to stderr
///   KORE_KEYS=<code>[;cmd+<code>...] key presses (virtual key codes) after the clicks and drag, 0.5s apart,
///                            delivered inside Kore; KORE_REAL_KEYS=1 posts them through the window server
///                            instead (they then go to whatever app is frontmost)
///   KORE_CLICK=<x>,<y>[;...] click those points (from the window's top-left), 1s apart, before the snapshot
///   KORE_REAL_CLICK=1        post that click through the window server (moves the real cursor),
///                            to catch title-bar regions that swallow clicks
///   KORE_HISTORY=1           open the history panel at launch
///   KORE_VIEW_IMAGE=1        open the first composer attachment in the image viewer
///   KORE_SIZE=<w>,<h>        resize the folder window's content first (tile-size checks)
///   KORE_HANGS=1             log main-thread stalls over 60ms and each click/key, with times, to stderr
///   KORE_SNAPSHOT=<png path> once a folder window is up, save an image of it and quit
enum DevSnapshot {
    static let openFolder = ProcessInfo.processInfo.environment["KORE_OPEN"].map { URL(fileURLWithPath: $0) }
    static let startProvider = ProcessInfo.processInfo.environment["KORE_START"].flatMap(Provider.init(rawValue:))
    static let resume: SessionSummary? = ProcessInfo.processInfo.environment["KORE_RESUME"].flatMap { value in
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let agent = SessionSummary.Agent(rawValue: parts[0]) else { return nil }
        return SessionSummary(id: parts[1], agent: agent, title: "Resumed", updated: .now)
    }
    static let send = ProcessInfo.processInfo.environment["KORE_SEND"]
    static let mode = ProcessInfo.processInfo.environment["KORE_MODE"]
    static let thenSend = ProcessInfo.processInfo.environment["KORE_THEN_SEND"]
    static let model = ProcessInfo.processInfo.environment["KORE_MODEL"]
    /// KORE_HISTORY=1: open the history panel at launch. KORE_VIEW_IMAGE=1: open the first
    /// composer attachment in the image viewer. (Deterministic snapshots without real clicks.)
    static let openHistory = ProcessInfo.processInfo.environment["KORE_HISTORY"] == "1"
    static let viewImage = ProcessInfo.processInfo.environment["KORE_VIEW_IMAGE"] == "1"
    static let attach = ProcessInfo.processInfo.environment["KORE_ATTACH"].map {
        $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }
    /// Runs that start or resume a chat keep one tab instead of loading the folder's chats.
    static var singleTab: Bool { startProvider != nil || resume != nil }
    private static let output = ProcessInfo.processInfo.environment["KORE_SNAPSHOT"]
    private static let clicks: [NSPoint] = (ProcessInfo.processInfo.environment["KORE_CLICK"] ?? "")
        .split(separator: ";").compactMap { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
        }

    /// KORE_HANGS=1: logs every main-thread stall over 50ms (with what was happening) to stderr.
    @MainActor static func watchHangs() {
        guard ProcessInfo.processInfo.environment["KORE_HANGS"] == "1" else { return }
        let start = Date()
        final class Tick: @unchecked Sendable { var last = Date() }
        let tick = Tick()
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = Date()
            let gap = now.timeIntervalSince(tick.last)
            if gap > 0.06 {
                FileHandle.standardError.write(Data(String(format: "HANG %.0fms at %.2fs\n", gap * 1000, now.timeIntervalSince(start)).utf8))
            }
            tick.last = now
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            var focus = event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            if let editor = event.window?.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField {
                focus += " field[\(field.placeholderString ?? "")]=\(editor.string) editable=\(editor.isEditable)/\(field.isEditable) enabled=\(field.isEnabled)"
            }
            FileHandle.standardError.write(Data(String(format: "EVENT %@ at %.2fs focus=%@\n", event.type == .keyDown ? "key" : "click", Date().timeIntervalSince(start), focus).utf8))
            if event.type == .keyDown, let window = event.window {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let after = (window.firstResponder as? NSTextView)?.string ?? "-"
                    FileHandle.standardError.write(Data("  after key: \(after) key=\(NSApp.keyWindow === window) active=\(NSApp.isActive)\n".utf8))
                }
            }
            return event
        }
    }

    @MainActor static func captureIfRequested() {
        guard let output else { return }
        if let size = ProcessInfo.processInfo.environment["KORE_SIZE"]?.split(separator: ",").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?
                    .setContentSize(NSSize(width: size[0], height: size[1]))
            }
        }
        if ProcessInfo.processInfo.environment["KORE_FULLSCREEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?.toggleFullScreen(nil)
            }
        }
        if let drag = ProcessInfo.processInfo.environment["KORE_DRAG"]?.split(separator: ",").compactMap({ Double($0) }),
            drag.count == 4
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + (clicks.isEmpty ? 2 : 2.5 + Double(clicks.count))) {
                post(drag: NSPoint(x: drag[0], y: drag[1]), by: CGVector(dx: drag[2], dy: drag[3]))
            }
        }
        let keys = (ProcessInfo.processInfo.environment["KORE_KEYS"] ?? "").split(separator: ";")
        for (index, key) in keys.enumerated() {
            let command = key.hasPrefix("cmd+")
            guard let code = CGKeyCode(key.dropFirst(command ? 4 : 0)) else { continue }
            let start = 2.5 + Double(clicks.count) + (ProcessInfo.processInfo.environment["KORE_DRAG"] == nil ? 0 : 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(index) * 0.5) {
                if ProcessInfo.processInfo.environment["KORE_REAL_KEYS"] == "1" {
                    // Through the window server: goes to whichever app is frontmost.
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                        if command { event?.flags = .maskCommand }
                        event?.post(tap: .cghidEventTap)
                    }
                } else {
                    send(key: code, command: command)
                }
            }
        }
        if ProcessInfo.processInfo.environment["KORE_PASTE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    for down in [true, false] {
                        let key = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)  // "v"
                        key?.flags = .maskCommand
                        key?.post(tap: .cghidEventTap)
                    }
                }
            }
        }
        let real = ProcessInfo.processInfo.environment["KORE_REAL_CLICK"] == "1"
        for (index, point) in clicks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(index)) {
                real ? post(click: point) : send(click: point)
            }
        }
        let delay = Double(ProcessInfo.processInfo.environment["KORE_WAIT"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The folder window first, then any others (popovers) as <output>-1.png, -2, ...
            let windows = NSApp.windows.filter(\.isVisible).sorted { a, _ in a.styleMask.contains(.fullSizeContentView) }
            for (index, window) in windows.enumerated() {
                guard let frame = window.contentView?.superview,
                    let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
                else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                let path = index == 0 ? output : output.replacingOccurrences(of: ".png", with: "-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                // Where it sits in KORE_CLICK coordinates (from the folder window's top-left).
                let origin = windows[0].frame
                FileHandle.standardError.write(Data(
                    "WINDOW \(index): x \(window.frame.minX - origin.minX) y \(origin.maxY - window.frame.maxY) size \(window.frame.size)\n".utf8))
            }
            exit(0)
        }
    }

    /// A mouse click posted to the window server, exactly like the user's; restores the cursor.
    @MainActor private static func post(click point: NSPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }),
            let screenHeight = NSScreen.screens.first?.frame.height
        else { return }
        // Only when needed: re-keying the window would close an open popover.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let target = CGPoint(x: window.frame.minX + point.x, y: screenHeight - (window.frame.maxY - point.y))
            let original = CGEvent(source: nil)?.location
            // Move there first, as a hand does, then press and release.
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let original { CGWarpMouseCursorPosition(original) }
                }
            }
        }
    }

    /// A real press-drag-release; reports how far the window moved.
    @MainActor private static func post(drag point: NSPoint, by delta: CGVector) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }),
            let screenHeight = NSScreen.screens.first?.frame.height
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let before = window.frame.origin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let start = CGPoint(x: window.frame.minX + point.x, y: screenHeight - (window.frame.maxY - point.y))
            // Spread over time so the app handles each event as a user's drag would.
            func post(_ type: CGEventType, _ p: CGPoint, after delay: Double) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                }
            }
            post(.leftMouseDown, start, after: 0)
            for step in 1...10 {
                let p = CGPoint(x: start.x + delta.dx * Double(step) / 10, y: start.y + delta.dy * Double(step) / 10)
                post(.leftMouseDragged, p, after: 0.1 + Double(step) * 0.03)
            }
            post(.leftMouseUp, CGPoint(x: start.x + delta.dx, y: start.y + delta.dy), after: 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let after = window.frame.origin
                FileHandle.standardError.write(Data("DRAG moved window by (\(after.x - before.x), \(after.y - before.y))\n".utf8))
            }
        }
    }

    /// A key press delivered inside Kore (NSApp.sendEvent, so event monitors see it), aimed at
    /// the folder window. It can't reach another app, even if the user brings one to the front.
    @MainActor private static func send(key code: CGKeyCode, command: Bool) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }) else { return }
        if !window.isKeyWindow { window.makeKey() }
        let probe = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true).flatMap(NSEvent.init(cgEvent:))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: probe?.characters ?? "",
                charactersIgnoringModifiers: probe?.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: code)
            {
                NSApp.sendEvent(event)
            }
        }
    }

    /// A mouse down/up delivered inside Kore (skips the window server).
    @MainActor private static func send(click point: NSPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }) else { return }
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                // Through NSApp, so local event monitors (outside-click handling) see it too.
                NSApp.sendEvent(event)
            }
        }
    }
}

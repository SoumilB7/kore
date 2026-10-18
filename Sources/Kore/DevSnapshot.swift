import AppKit
import KoreCore

/// Debug hook for checking the UI without clicking through it:
///   KORE_OPEN=<folder>       open that folder's window at launch
///   KORE_START=claude|codex  start a chat of that provider in its first tab
///   KORE_RESUME=<agent>:<id> open that past session instead
///   KORE_SEND=<text>         send that message in the started chat
///   KORE_MODE=<mode id>      switch the started chat to that mode
///   KORE_PASTE=1             press ⌘V (a real key event) in the composer
///   KORE_THEN_SEND=<text>    after that, send this text with whatever got attached
///   KORE_FULLSCREEN=1        enter full screen before the snapshot
///   KORE_DRAG=<x>,<y>,<dx>,<dy> real drag from that point; logs the window's move to stderr
///   KORE_CLICK=<x>,<y>[;...] click those points (from the window's top-left), 1s apart, before the snapshot
///   KORE_REAL_CLICK=1        post that click through the window server (moves the real cursor),
///                            to catch title-bar regions that swallow clicks
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
    private static let output = ProcessInfo.processInfo.environment["KORE_SNAPSHOT"]
    private static let clicks: [NSPoint] = (ProcessInfo.processInfo.environment["KORE_CLICK"] ?? "")
        .split(separator: ";").compactMap { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
        }

    @MainActor static func captureIfRequested() {
        guard let output else { return }
        if ProcessInfo.processInfo.environment["KORE_FULLSCREEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?.toggleFullScreen(nil)
            }
        }
        if let drag = ProcessInfo.processInfo.environment["KORE_DRAG"]?.split(separator: ",").compactMap({ Double($0) }),
            drag.count == 4
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                post(drag: NSPoint(x: drag[0], y: drag[1]), by: CGVector(dx: drag[2], dy: drag[3]))
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
            }
            exit(0)
        }
    }

    /// A mouse click posted to the window server, exactly like the user's; restores the cursor.
    @MainActor private static func post(click point: NSPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }),
            let screenHeight = NSScreen.screens.first?.frame.height
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

    /// A mouse down/up through NSWindow.sendEvent (in-process, skips the window server).
    @MainActor private static func send(click point: NSPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }) else { return }
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                window.sendEvent(event)
            }
        }
    }
}

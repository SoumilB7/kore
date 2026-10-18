import AppKit

/// Real input (phase 12, §4): events posted through the window server, so the real cursor moves
/// and real keys are pressed. It's the only way to hover, since no synthetic event fires
/// SwiftUI's `.onHover`, and the only way to press a menu command's real shortcut.
///
/// Given only with `--real-input`, after the owner OKs the run in chat; keys need `--real-keys`
/// as well (posted keystrokes once reached the owner's other apps). Before its first event, the
/// storyline's window shows a "Real input" banner that counts down 3 seconds, so whoever is at
/// the machine sees it coming. Posted events go to the frontmost app, so it then brings Kore
/// forward. When the storyline ends it puts the cursor back and gives the front back to the app
/// that had it.
///
/// A dry run (`--real-input-dry`) does all of that but post: the events it would have posted
/// are kept in `posted`, and the cursor, which never moved, isn't put back.
@MainActor
package final class RealInput {
    package let keys: Bool
    package let dry: Bool
    /// Seconds the banner counts down before the first event.
    private let countdown: Int
    private var started = false
    private var cursor: CGPoint?
    private var previous: NSRunningApplication?
    private(set) var banner: NSWindow?
    /// A dry run's events, in the order they would have been posted.
    private(set) var posted: [CGEvent] = []

    package init(keys: Bool, dry: Bool = false, countdown: Int = 3) {
        self.keys = keys
        self.dry = dry
        self.countdown = countdown
    }

    /// Moves the real pointer onto a point in the window, and leaves it there (a hover lasts
    /// until the next real event or the end of the storyline).
    func move(to point: CGPoint, in window: NSWindow) async throws {
        try await start(window)
        post(.mouseMoved, at: global(point, in: window))
        try await settle()
    }

    func click(at point: CGPoint, in window: NSWindow, count: Int) async throws {
        try await start(window)
        let at = global(point, in: window)
        post(.mouseMoved, at: at)
        for n in 1...max(count, 1) {
            post(.leftMouseDown, at: at, clickCount: n)
            post(.leftMouseUp, at: at, clickCount: n)
        }
        try await settle()
    }

    func key(_ chord: KeyChord, in window: NSWindow) async throws {
        guard keys else { throw StoryFailure.needsRealInput("posting the key \(chord) (it also needs --real-keys)") }
        try await start(window)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: down)
            event?.flags = chord.cgFlags
            send(event)
        }
        try await settle()
    }

    /// Puts the cursor back, takes the banner down and gives the front back. Safe to call when
    /// nothing was posted.
    package func finish() {
        guard started else { return }
        started = false
        if let cursor, !dry { CGWarpMouseCursorPosition(cursor) }
        banner?.orderOut(nil)
        banner = nil
        if let previous, previous != NSRunningApplication.current { previous.activate() }
    }

    // MARK: Before the first event

    private func start(_ window: NSWindow) async throws {
        if started { return }
        started = true
        cursor = CGEvent(source: nil)?.location
        previous = NSWorkspace.shared.frontmostApplication
        let banner = Self.banner(over: window)
        self.banner = banner
        for left in stride(from: countdown, to: 0, by: -1) {
            Self.say("Real input in \(left)…", on: banner)
            try await Task.sleep(for: .seconds(1))
        }
        Self.say("Real input", on: banner)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await settle()
    }

    private static func banner(over window: NSWindow) -> NSWindow {
        let size = CGSize(width: 220, height: 34)
        let frame = window.frame
        let banner = NSPanel(
            contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 52, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        banner.isOpaque = false
        banner.backgroundColor = .clear
        banner.level = .floating
        banner.ignoresMouseEvents = true
        let pill = NSView(frame: CGRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.systemRed.cgColor
        pill.layer?.cornerRadius = size.height / 2
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        banner.contentView = pill
        window.addChildWindow(banner, ordered: .above)
        return banner
    }

    private static func say(_ text: String, on banner: NSWindow) {
        (banner.contentView?.subviews.first as? NSTextField)?.stringValue = text
    }

    // MARK: Posting

    /// A point in the window, in the window server's global coordinates (top-left origin on the
    /// main display), worked out the moment before the event.
    private func global(_ point: CGPoint, in window: NSWindow) -> CGPoint {
        let screen = window.convertPoint(toScreen: point)
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: screen.x, y: primary - screen.y)
    }

    private func post(_ type: CGEventType, at point: CGPoint, clickCount: Int = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        send(event)
    }

    private func send(_ event: CGEvent?) {
        guard let event else { return }
        if dry { posted.append(event) } else { event.post(tap: .cghidEventTap) }
    }

    /// A short wait for the window server to deliver what was posted (a real event arrives
    /// asynchronously, unlike the in-process ones).
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }
}

extension KeyChord {
    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}

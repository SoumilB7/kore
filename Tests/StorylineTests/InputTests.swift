import AppKit
import Testing

@testable import KoreStorylines
@testable import KoreUI

@Suite("keys as storylines name them")
@MainActor
struct KeyChordTests {
    private let window: NSWindow = {
        _ = NSApplication.shared
        return NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    }()

    @Test func aLetterKeepsItsCharactersAndTheUSKeyCode() throws {
        let event = try #require(KeyChord.cmd("t").event(.keyDown, in: window))
        #expect(event.characters == "t")
        #expect(event.charactersIgnoringModifiers == "t")
        #expect(event.keyCode == 17)
        #expect(event.modifierFlags.contains(.command))
        #expect(KeyChord.cmd("t").isEquivalent)
        #expect(!KeyChord.key("t").isEquivalent)
    }

    @Test func uppercaseAndShiftedPunctuationHoldShift() throws {
        let upper = try #require(KeyChord.key("T").event(.keyDown, in: window))
        #expect(upper.modifierFlags.contains(.shift))
        #expect(upper.keyCode == 17)
        let bang = try #require(KeyChord.key("!").event(.keyDown, in: window))
        #expect(bang.modifierFlags.contains(.shift))
        #expect(bang.keyCode == 18)
    }

    @Test func controlMakesALettersControlCharacter() throws {
        let event = try #require(KeyChord.ctrl("a").event(.keyDown, in: window))
        #expect(event.characters == "\u{1}")
        #expect(event.charactersIgnoringModifiers == "a")
    }

    @Test func arrowsCarryTheFlagsTheKeyboardAdds() throws {
        let event = try #require(KeyChord.up.event(.keyDown, in: window))
        #expect(event.keyCode == 126)
        #expect(event.modifierFlags.contains(.function))
        #expect(event.modifierFlags.contains(.numericPad))
    }

    @Test func describesChordsAsMenusDo() {
        #expect(KeyChord.cmdShift("e").description == "⇧⌘E")
        #expect(KeyChord(.character("z"), [.command, .option, .control]).description == "⌃⌥⌘Z")
        #expect(KeyChord.returnKey.description == "↩")
    }
}

@Suite("finding elements and acting on them", .serialized)
@MainActor
struct LocatorTests {
    private let window: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Ordered in, off every screen: controls track the mouse only in a window that's shown.
        window.orderFront(nil)
        return window
    }()
    private let app = AppProbe(folder: nil)

    private func register(_ id: StoryID, frame: CGRect = CGRect(x: 10, y: 10, width: 40, height: 20), press: (@MainActor () -> Void)? = nil)
        -> StoryRegistry.Token
    {
        let view = NSView(frame: frame)
        window.contentView?.addSubview(view)
        return StoryRegistry.register(id.raw, in: view, press: press)
    }

    @Test func aNameIsFoundOnceItRegisters() {
        let locator = Locator.id(StoryID.Composer.send)
        guard case .revealing(let id) = locator.resolve(app) else { Issue.record("expected revealing"); return }
        #expect(id == StoryID.Composer.send)
        let token = register(StoryID.Composer.send)
        defer { StoryRegistry.unregister(token) }
        guard case .found(let element) = locator.resolve(app) else { Issue.record("expected found"); return }
        #expect(element.frame == CGRect(x: 10, y: 10, width: 40, height: 20))
    }

    @Test func aPartIsLookedUpAndRevealedLikeItsElement() {
        var revealed = 0
        let row = Locator("row", key: { _ in .success(StoryID.Transcript.earlier) }, reveal: { _ in revealed += 1 })
        guard case .revealing(let id) = row.action(.open).resolve(app) else { Issue.record("expected revealing"); return }
        #expect(id.raw == "transcript.earlier.open")
        #expect(revealed == 1)
        #expect(row.action(.open).description == "row › open")
    }

    @Test func theModelSaysWhetherToWait() {
        let gone = Locator("gone", key: { _ in .failure(LocatorMiss("no such turn")) })
        let later = Locator("later", key: { _ in .failure(LocatorMiss("still loading", pending: true)) })
        guard case .missing(let what) = gone.resolve(app) else { Issue.record("expected missing"); return }
        #expect(what == "no such turn")
        guard case .waiting = later.resolve(app) else { Issue.record("expected waiting"); return }
    }

    @Test func aPressRunsTheRegisteredActionWithoutAPointer() async throws {
        var pressed = 0
        let token = register(StoryID.Explorer.refresh, press: { pressed += 1 })
        defer { StoryRegistry.unregister(token) }
        let driver = InputDriver(window: { [window] in window }, real: nil)
        try await driver.press(try #require(StoryElement(StoryID.Explorer.refresh)))
        #expect(pressed == 1)
    }

    @Test func aPressWithoutAnActionClicksTheControl() async throws {
        final class Target: NSObject {
            var hits = 0
            @objc func hit(_ sender: Any?) { hits += 1 }
        }
        let target = Target()
        let button = NSButton(title: "Send", target: target, action: #selector(Target.hit(_:)))
        button.frame = CGRect(x: 100, y: 50, width: 80, height: 30)
        window.contentView?.addSubview(button)
        let token = StoryRegistry.register(StoryID.Composer.send.raw, in: button)
        defer { StoryRegistry.unregister(token) }
        let driver = InputDriver(window: { [window] in window }, real: nil)
        try await driver.press(try #require(StoryElement(StoryID.Composer.send)))
        #expect(target.hits == 1)
    }

    @Test func hoverNeedsRealInput() async throws {
        let token = register(StoryID.Titlebar.history)
        defer { StoryRegistry.unregister(token) }
        let driver = InputDriver(window: { [window] in window }, real: nil)
        await #expect(throws: StoryFailure.self) { try await driver.hover(try #require(StoryElement(StoryID.Titlebar.history))) }
    }

    @Test func anElementOutsideItsWindowIsNotClicked() async throws {
        let token = register(StoryID.Titlebar.agents, frame: CGRect(x: 500, y: 500, width: 20, height: 20))
        defer { StoryRegistry.unregister(token) }
        let driver = InputDriver(window: { [window] in window }, real: nil)
        await #expect(throws: StoryFailure.self) { try await driver.click(try #require(StoryElement(StoryID.Titlebar.agents))) }
    }
}

@Suite("keys in a real keypress's order", .serialized)
@MainActor
struct KeyOrderTests {
    private let window: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }()

    /// A view with a key equivalent of its own, as SwiftUI's `.keyboardShortcut` is.
    private final class Shortcut: NSView {
        var hits = 0
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.charactersIgnoringModifiers == "k" else { return false }
            hits += 1
            return true
        }
    }

    private func run(_ chord: KeyChord, monitorTakes: Bool) async throws -> (monitor: Int, view: Int) {
        let view = Shortcut(frame: CGRect(x: 10, y: 10, width: 40, height: 20))
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        var seen = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers == "k" else { return event }
            seen += 1
            return monitorTakes ? nil : event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        try await InputDriver(window: { [window] in window }, real: nil).key(chord)
        return (seen, view.hits)
    }

    @Test func theAppsMonitorsTakeAKeyBeforeTheWindowsViews() async throws {
        let (monitor, view) = try await run(.cmd("k"), monitorTakes: true)
        #expect(monitor == 1)
        #expect(view == 0)
    }

    @Test func aKeyTheMonitorsPassOnReachesTheViews() async throws {
        let (monitor, view) = try await run(.cmd("k"), monitorTakes: false)
        #expect(monitor == 1)
        #expect(view == 1)
    }
}

@Suite("real input, dry", .serialized)
@MainActor
struct DryRealInputTests {
    private let window: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }()

    private func label(_ banner: NSWindow?) -> String? {
        (banner?.contentView?.subviews.first as? NSTextField)?.stringValue
    }

    @Test func theBannerCountsDownOverTheWindowAndNothingIsPosted() async throws {
        let real = RealInput(keys: false, dry: true, countdown: 1)
        let move = Task { try await real.move(to: CGPoint(x: 150, y: 100), in: window) }
        // The countdown leaves the main actor free: this runs during it.
        try await Task.sleep(for: .milliseconds(200))
        let banner = try #require(real.banner)
        #expect(label(banner) == "Real input in 1…")
        #expect(banner.parent === window)
        #expect(banner.isVisible)
        #expect(!banner.canBecomeKey)
        #expect(banner.ignoresMouseEvents)
        try await move.value
        #expect(label(banner) == "Real input")

        let screen = window.convertPoint(toScreen: CGPoint(x: 150, y: 100))
        let primary = NSScreen.screens.first?.frame.height ?? 0
        #expect(real.posted.map(\.type) == [.mouseMoved])
        #expect(real.posted.first?.location == CGPoint(x: screen.x, y: primary - screen.y))

        // The countdown is once a storyline.
        try await real.click(at: CGPoint(x: 10, y: 10), in: window, count: 2)
        #expect(real.posted.map(\.type) == [.mouseMoved, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(real.posted.last?.getIntegerValueField(.mouseEventClickState) == 2)
        await #expect(throws: StoryFailure.self) { try await real.key(.cmd("k"), in: window) }

        real.finish()
        #expect(real.banner == nil)
        #expect(!banner.isVisible)
        #expect(window.childWindows?.contains(banner) != true)
    }

    @Test func theRunnerReadsTheDryFlag() {
        let dry = StorylineHost.Options(["kore-storylines", "--real-input-dry", "--real-keys"]).flags
        #expect(dry.realInput && dry.realInputDry && dry.realKeys)
        let real = StorylineHost.Options(["kore-storylines", "--real-input"]).flags
        #expect(real.realInput && !real.realInputDry)
    }
}

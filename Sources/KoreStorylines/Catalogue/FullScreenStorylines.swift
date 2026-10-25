import AppKit
import KoreUI

/// Full screen: the tab row stays in view while the menu bar and the title bar slide down over
/// the top of the window (the pointer at the top of the screen), moving down with them and
/// clear of them, and back to the top when they go. Out of full screen the window's chrome is
/// as it was: the transparent title bar's traffic lights in the tab row.
final class FullScreenTabs: Storyline {
    override class var tags: Set<Tag> { ["window"] }

    override func steps() -> [any Step] {
        [
            OpenFolder(),
            Self.windowed("before full screen"),
            Do("Enter full screen") { story in
                _ = story.stash(LeaveFullScreen.self) { LeaveFullScreen(story.window) }
                story.window?.toggleFullScreen(nil)
            },
            Expect("full screen", timeout: .seconds(10), found: { story in
                guard let window = story.window else { return "no window" }
                return "full screen \(window.styleMask.contains(.fullScreen)), moved \(String(describing: LeaveFullScreen.settled(story))), "
                    + "the title bar in \(TitleBarReach.container(window)?.window === window ? "the window" : "its own window")"
            }) { story in
                guard let window = story.window, window.styleMask.contains(.fullScreen), LeaveFullScreen.settled(story) == true
                else { return false }
                // The title bar has moved to its own window, over the top of the screen.
                return TitleBarReach.container(window)?.window !== window && TitleBarReach.of(window) == 0
            },
            Self.tabsClear("with the title bar hidden", shown: false),
            Press(.id(StoryID.Titlebar.newtab)),
            Expect("two tabs, the second active") { $0.app.workspace.map { $0.tabs.count == 2 && $0.activeTab === $0.tabs[1] } ?? false },

            // The pointer at the top of the screen: the title bar slides down over the window,
            // its container moved frame by frame in the window macOS keeps it in. (A storyline's
            // app isn't the active one, so the menu bar won't bring it: it's moved as macOS does.)
            SlideTitleBar(shown: true),
            Self.tabsClear("with the title bar shown", shown: true),
            Snapshot("full-screen-revealed"),
            // The moved row takes the click.
            Click(.tab(1)),
            Expect("the first tab active") { $0.app.workspace.map { $0.activeTab === $0.tabs[0] } ?? false },

            SlideTitleBar(shown: false),
            Expect("the title bar gone again") { story in story.window.map { TitleBarReach.of($0) == 0 } ?? false },
            Self.tabsClear("with the title bar hidden again", shown: false),

            Do("Leave full screen") { story in story.window?.toggleFullScreen(nil) },
            Expect("out of full screen", timeout: .seconds(10)) { story in
                guard let window = story.window else { return false }
                return !window.styleMask.contains(.fullScreen) && LeaveFullScreen.settled(story) == false
                    && TitleBarReach.container(window)?.window === window
            },
            Self.windowed("after full screen"),
        ]
    }

    /// The tab row in full view, just under wherever the title bar ends (`shown`: over the top
    /// of the window): nothing of it covered.
    static func tabsClear(_ when: String, shown: Bool) -> Expect {
        Expect("the tabs in full view \(when)", timeout: .seconds(3), found: { story in
            guard let window = story.window, let strip = stripTop(window) else { return "no tab strip" }
            return "the strip's top \(strip)pt down, the title bar reaching \(TitleBarReach.of(window))pt"
        }) { story in
            guard let window = story.window, let top = stripTop(window) else { return false }
            let reach = TitleBarReach.of(window)
            return (shown ? reach > 20 : reach == 0) && top >= reach && top - reach < 20
        }
    }

    /// Out of full screen: the compact title bar's row holds the tabs, the traffic lights in it.
    static func windowed(_ when: String) -> Expect {
        Expect("the transparent title bar with the tabs in its row \(when)", timeout: .seconds(3), found: { story in
            guard let window = story.window else { return nil }
            return "toolbar \(window.toolbar == nil ? "none" : "set"), strip top \(stripTop(window) ?? -1), "
                + "close button mid \(closeMid(window) ?? -1), strip mid \(stripMid(window) ?? -1)"
        }) { story in
            guard let window = story.window, window.toolbar != nil, window.styleMask.contains(.fullSizeContentView),
                let top = stripTop(window), let close = closeMid(window), let mid = stripMid(window)
            else { return false }
            return top < 20 && abs(close - mid) < 2
        }
    }

    /// How far below the window's top the tab strip starts.
    static func stripTop(_ window: NSWindow) -> CGFloat? {
        guard let frame = StoryElement(StoryID.Tabs.strip, in: window)?.frame, frame.height > 0 else { return nil }
        return window.frame.height - frame.maxY
    }

    static func stripMid(_ window: NSWindow) -> CGFloat? {
        guard let frame = StoryElement(StoryID.Tabs.strip, in: window)?.frame else { return nil }
        return window.frame.height - frame.midY
    }

    /// The close button's middle, below the window's top.
    static func closeMid(_ window: NSWindow) -> CGFloat? {
        guard let button = window.standardWindowButton(.closeButton), button.window === window else { return nil }
        return window.frame.height - button.convert(button.bounds, to: nil).midY
    }
}

/// Moves the full-screen title bar in or out of sight over 10 frames, as macOS slides it when
/// the pointer reaches the top of the screen: its container from below its window's bottom
/// edge to that edge.
struct SlideTitleBar: Step {
    let shown: Bool
    var label: String { shown ? "Slide the title bar down" : "Slide the title bar back up" }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let container = TitleBarReach.container(window), container.window !== window else {
            throw StoryFailure.other("no full-screen title bar")
        }
        let (from, to) = shown ? (-container.frame.height, CGFloat(0)) : (container.frame.minY, -container.frame.height)
        for step in 1...10 {
            container.setFrameOrigin(NSPoint(x: container.frame.minX, y: (from + (to - from) * CGFloat(step) / 10).rounded()))
            try await Task.sleep(for: .milliseconds(16))
        }
        try await story.idle()
    }
}

/// Leaves full screen however the storyline ended.
@MainActor
private final class LeaveFullScreen: StoryFinishing {
    weak var window: NSWindow?
    /// True once in full screen, false once out again; nil while it moves.
    var settled: Bool?
    private var observers: [NSObjectProtocol] = []

    init(_ window: NSWindow?) {
        self.window = window
        for (name, state) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settled = state }
                })
        }
    }

    /// Whether the storyline's window has finished moving into full screen (true) or out (false).
    static func settled(_ story: StoryContext) -> Bool? { story.stash(LeaveFullScreen.self) { LeaveFullScreen(story.window) }.settled }

    func finish() {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}


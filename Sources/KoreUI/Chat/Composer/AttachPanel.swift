import AppKit

/// The + button's file picker. Each new open panel connects to the system's panel service
/// before it returns, holding the main thread: about 0.1 s, and over a second the first time in
/// a launch. So one panel is kept and reused, connected ahead of the first click when Kore goes
/// to the background or the pointer rests on +, and it opens with `begin`, which returns at
/// once and leaves the main thread running while it's up (`runModal` held every chat's work).
@MainActor
enum AttachPanel {
    private static var kept: NSOpenPanel?
    private static var observer: NSObjectProtocol?

    /// Connects the panel the first time Kore goes to the background, where the wait is unseen.
    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                warm()
            }
        }
    }

    /// Makes the kept panel (it shows nothing and takes no focus) unless it's there already.
    static func warm() {
        guard kept == nil else { return }
        let start = ContinuousClock.now
        kept = NSOpenPanel()
        UILog.event("attach-panel-warm", ["ms": ms(since: start)])
    }

    /// Files and folders, several at once, starting in `folder`; `done` gets the chosen ones
    /// (none on Cancel). With the panel already up, it comes forward instead.
    static func choose(in folder: URL, done: @escaping @MainActor ([URL]) -> Void) {
        if let kept, kept.isVisible {
            kept.makeKeyAndOrderFront(nil)
            return
        }
        let start = ContinuousClock.now
        let wasKept = kept != nil
        let panel = kept ?? NSOpenPanel()
        kept = panel
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = folder
        panel.begin { response in
            MainActor.assumeIsolated { done(response == .OK ? panel.urls : []) }
        }
        UILog.event("attach-panel", ["ms": ms(since: start), "kept": wasKept ? "1" : "0"])
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

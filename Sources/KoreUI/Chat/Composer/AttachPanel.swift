import AppKit

/// The + button's file picker. Each new open panel connects to the system's panel service
/// before it returns, holding the main thread: about 0.1 s, and over a second the first time in
/// a launch. So one panel is kept and reused, connected ahead of the first click when Kore goes
/// to the background or the pointer rests on +. Each click sets it up afresh (the chat's folder,
/// the chat its files go to) and shows it as a sheet on the window whose + it was, so no other
/// Kore window comes forward; a sheet returns at once and leaves the main thread running while
/// it's up (`runModal` held every chat's work).
@MainActor
package enum AttachPanel {
    /// The panel while it's up: the window it's a sheet on and the chat its files go to, both
    /// as they were at the click.
    package struct Open {
        package let panel: NSOpenPanel
        package weak var window: NSWindow?
        package weak var chat: Chat?
    }

    package private(set) static var open: Open?
    private static var kept: NSOpenPanel?
    private static var observer: NSObjectProtocol?
    /// A + in another window while the panel is up: shown there once this sheet has gone.
    private static var next: (() -> Void)?
    /// A storyline's pick, in place of the panel's (`storyPick`).
    private static var picked: [URL]?

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

    /// Files and folders, several at once, starting in `chat`'s folder, as a sheet on `window`;
    /// `done` gets the chosen ones (none on Cancel). Up on another window, the panel leaves it
    /// and opens here: the + clicked last is the one that counts.
    static func choose(for chat: Chat, over window: NSWindow?, done: @escaping @MainActor ([URL]) -> Void) {
        if let open {
            if open.panel.isVisible || open.panel.sheetParent != nil {
                if open.window !== window || window == nil {
                    next = { choose(for: chat, over: window, done: done) }
                    open.panel.cancel(nil)
                }
                return
            }
            self.open = nil
        }
        let start = ContinuousClock.now
        let wasKept = kept != nil
        let panel = kept ?? NSOpenPanel()
        kept = panel
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = chat.folder
        let host = window ?? NSApp.keyWindow
        open = Open(panel: panel, window: host, chat: chat)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                let urls = picked ?? (response == .OK ? panel.urls : [])
                picked = nil
                open = nil
                if let next {
                    // Left for another window's +: this chat gets nothing, that one gets the panel.
                    self.next = nil
                    DispatchQueue.main.async { MainActor.assumeIsolated { next() } }
                    return
                }
                done(urls)
            }
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
        UILog.event("attach-panel", ["ms": ms(since: start), "kept": wasKept ? "1" : "0", "sheet": host == nil ? "0" : "1"])
    }

    /// Ends the panel as though `urls` were chosen in it (a storyline's pick).
    package static func storyPick(_ urls: [URL]) {
        guard let open else { return }
        picked = urls
        open.panel.cancel(nil)
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

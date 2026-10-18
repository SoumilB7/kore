import AppKit
import KoreUI

/// The app as a storyline sees it: its folder's workspace, the active tab and its chat.
@MainActor
package struct AppProbe {
    /// The storyline's folder.
    let folder: URL?

    package var workspace: Workspace? {
        guard let folder else { return nil }
        let path = folder.resolvingSymlinksInPath().path
        return Workspace.all.allObjects.first { $0.folder.resolvingSymlinksInPath().path == path }
    }

    package var tab: ChatTab? { workspace?.activeTab }
    package var chat: Chat? { tab?.chat }
}

/// One run's flags, from the runner's arguments.
package struct RunFlags: Sendable {
    /// `--real-input`: pointer events through the window server (the owner OKs each run in chat).
    package var realInput = false
    /// `--real-keys`: posted keystrokes too.
    package var realKeys = false
    /// `--size WxH`: overrides each storyline's window.
    package var size: CGSize?
    /// `--replay name|folder|agent:id;…`: recorded sessions, by name.
    package var replays: [String: (folder: URL, session: String)] = [:]
}

/// Everything a step works with: the app, its window, the waits, the event log, the run's
/// scratch folders, and a place for other packages to keep per-storyline objects (`stash`).
@MainActor
package final class StoryContext {
    package let name: String
    package let flags: RunFlags
    /// The variant being told (its provider, for per-provider storylines).
    package var variant: Variant?
    /// This storyline's own folder for the app to open (`needs.folder`).
    package let folder: URL
    /// Where its report files go.
    package let outputs: URL
    /// The default wait for a step that names none.
    package var timeout: Duration = .seconds(5)
    /// The folder window's content size (`needs.window`, or the run's `--size`).
    package var windowSize = CGSize(width: 1000, height: 760)

    package var app: AppProbe { AppProbe(folder: folder) }
    package var window: NSWindow? { app.workspace?.window }

    /// Per-storyline objects by type, made on first use: `story.stash(InputDriver.self) { … }`.
    package func stash<T: AnyObject>(_ type: T.Type, make: () -> T) -> T {
        if let held = stashed[ObjectIdentifier(type)] as? T { return held }
        let made = make()
        stashed[ObjectIdentifier(type)] = made
        return made
    }

    private var stashed: [ObjectIdentifier: AnyObject] = [:]

    /// Lets stashed objects put back what they changed (the cursor, the front app), pass or fail.
    func finish() {
        for object in stashed.values { (object as? StoryFinishing)?.finish() }
        stashed = [:]
    }
    private let waits: Waits
    private let started = ContinuousClock.now

    // MARK: Events

    /// Every event of every chat since the storyline started, in order.
    package private(set) var events: [(at: Duration, chat: UUID, event: ChatEvent)] = []
    private var lastEventPass = 0

    func record(_ chat: Chat, _ event: ChatEvent) {
        events.append((ContinuousClock.now - started, chat.id, event))
        lastEventPass = waits.passes
        waits.poke()
    }

    /// The event log as text, one event a line, timed from the storyline's start.
    var eventLog: String {
        events.map { e in
            var text = String(describing: e.event)
            if text.count > 400 { text = String(text.prefix(400)) + "…" }
            let ms = Double(e.at.components.seconds) * 1000 + Double(e.at.components.attoseconds) / 1e15
            return String(format: "+%.0fms %@ %@", ms, String(e.chat.uuidString.prefix(8)), text.replacingOccurrences(of: "\n", with: "⏎"))
        }.joined(separator: "\n")
    }

    init(name: String, flags: RunFlags, folder: URL, outputs: URL, waits: Waits) {
        self.name = name
        self.flags = flags
        self.folder = folder
        self.outputs = outputs
        self.waits = waits
    }

    // MARK: Waiting

    /// Waits until `check` returns a value, re-checked after every run-loop pass, every event
    /// and every 50 ms. Throws `.timedOut(label)` after `timeout` (the step's default when nil).
    package func wait<T>(_ label: String, timeout: Duration? = nil, _ check: @escaping @MainActor () throws -> T?) async throws -> T {
        try await waits.until(label, timeout: timeout ?? self.timeout, check)
    }

    /// Waits for a condition to hold.
    package func until(_ label: String, timeout: Duration? = nil, _ condition: @escaping @MainActor () throws -> Bool) async throws {
        _ = try await wait(label, timeout: timeout) { try condition() ? true : nil }
    }

    /// Waits until the app settles: three run-loop passes in a row with no chat event.
    package func idle(timeout: Duration? = nil) async throws {
        try await until("the app to settle", timeout: timeout) { [unowned self] in waits.passes - lastEventPass >= 3 }
    }
}

/// A stashed object with something to undo when its storyline ends: called after the last step
/// (or the failure), before the window closes.
package protocol StoryFinishing: AnyObject {
    @MainActor func finish()
}

import AppKit
import KoreCore
import KoreUI

// The steps every storyline starts from: open the folder, start or resume a chat, wait, check,
// and keep evidence. Input steps (press, click, keys…) live in Input/; the scripted CLI's steps
// in CLI/.

/// Opens the storyline's folder in its own window, sized and placed by the runner.
package struct OpenFolder: Step {
    package var label: String { "Open the folder" }
    package var timeout: Duration? { .seconds(15) }
    package init() {}

    package func run(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        model.openFolder(story.folder)
        let window = try await story.wait("the folder's window") { story.window }
        window.setContentSize(story.windowSize)
        // Placed on screen only for real input; otherwise the host keeps it off screen.
        if story.flags.realInput, let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 40))
        }
        try await story.idle()
    }
}

/// Starts a chat in the active tab: the variant's provider unless one is named.
package struct StartChat: Step {
    let provider: String?
    package var label: String { "Start a \(provider ?? "variant's") chat" }
    package init(_ provider: String? = nil) { self.provider = provider }

    package func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
        let id = provider ?? story.variant?.provider ?? "claude"
        // A live run's chats talk to its model (`--live haiku`), never the CLI's default.
        var model: String?
        if case .live(let live) = story.flags.cli { model = live }
        guard workspace.start(provider: id, model: model) else { throw StoryFailure.modelMissing("a provider named \(id)") }
        _ = try await story.wait("the chat") { story.app.chat }
    }
}

/// Opens a recorded session (`--replay`) in the active tab.
package struct Resume: Step {
    let fixture: String
    package var label: String { "Resume the “\(fixture)” session" }
    package var timeout: Duration? { .seconds(20) }
    package init(_ fixture: String) { self.fixture = fixture }

    package func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
        guard let replay = story.flags.replays[fixture] else { throw StoryFailure.other("no --replay named \(fixture)") }
        let parts = replay.session.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let agent = SessionSummary.Agent(rawValue: parts[0]) else {
            throw StoryFailure.other("a session is agent:id, not \(replay.session)")
        }
        workspace.open(SessionSummary(id: parts[1], agent: agent, title: "Resumed", updated: .now))
        _ = try await story.wait("the resumed chat") { story.app.chat }
    }
}

/// Waits for an event of the active chat, since the storyline began.
package struct WaitForEvent: Step {
    let what: String
    let matches: @Sendable (ChatEvent) -> Bool
    package var label: String { "Wait for \(what)" }
    package let timeout: Duration?

    package init(_ what: String, timeout: Duration? = nil, _ matches: @escaping @Sendable (ChatEvent) -> Bool) {
        self.what = what
        self.timeout = timeout
        self.matches = matches
    }

    package func run(_ story: StoryContext) async throws {
        try await story.until(what) {
            guard let chat = story.app.chat?.id else { return false }
            return story.events.contains { $0.chat == chat && matches($0.event) }
        }
    }

    /// The chat's past, read back on resume.
    package static let replay = WaitForEvent("the replay", timeout: .seconds(30)) {
        if case .replayed = $0 { true } else { false }
    }
}

/// Waits until the app settles: no chat event for three run-loop passes.
package struct WaitIdle: Step {
    package var label: String { "Wait until it settles" }
    package init() {}
    package func run(_ story: StoryContext) async throws { try await story.idle() }
}

/// Something the storyline sets or does directly, not through the interface (a shorter wait).
package struct Do: Step {
    let what: String
    let action: @MainActor (StoryContext) throws -> Void
    package var label: String { what }
    package var timeout: Duration? { nil }

    package init(_ what: String, _ action: @escaping @MainActor (StoryContext) throws -> Void) {
        self.what = what
        self.action = action
    }

    package func run(_ story: StoryContext) async throws { try action(story) }
}

/// Checks the model, waiting up to the step's timeout for it to hold.
package struct Expect: Step {
    let what: String
    let check: @MainActor (StoryContext) throws -> Bool
    /// What the model holds instead, for the failure's message.
    let found: (@MainActor (StoryContext) -> String?)?
    package var label: String { "Expect \(what)" }
    package let timeout: Duration?

    package init(
        _ what: String, timeout: Duration? = nil, found: (@MainActor (StoryContext) -> String?)? = nil,
        _ check: @escaping @MainActor (StoryContext) throws -> Bool
    ) {
        self.what = what
        self.timeout = timeout
        self.found = found
        self.check = check
    }

    package func run(_ story: StoryContext) async throws {
        do {
            try await story.until(what) { try check(story) }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation(what + (found?(story).map { " (found \($0))" } ?? ""))
        }
    }
}

/// Saves the window as `<name>.png` in the run's output folder.
package struct Snapshot: Step {
    let name: String
    package var label: String { "Snapshot “\(name)”" }
    package init(_ name: String) { self.name = name }

    package func run(_ story: StoryContext) async throws {
        guard let window = story.window, let png = snapshot(window) else { throw StoryFailure.other("no window to snapshot") }
        try png.write(to: story.outputs.appendingPathComponent("\(name).png"))
    }
}

/// Writes the active chat's rows as `<name>.dump` (the `KORE_DUMP` format verify-landing compares).
package struct DumpRows: Step {
    let name: String
    package var label: String { "Dump the rows to “\(name).dump”" }
    package init(_ name: String) { self.name = name }

    package func run(_ story: StoryContext) async throws {
        guard let chat = story.app.chat else { throw StoryFailure.modelMissing("a chat") }
        try chat.dumpLines().joined(separator: "\n").write(
            to: story.outputs.appendingPathComponent("\(name).dump"), atomically: true, encoding: .utf8)
    }
}

import AppKit
import KoreUI

// The live check's screen tour (scripts/live-check.sh): one storyline per area, each the area's
// own storyline (its steps, as the gate runs them) and then a look at it as a person would: its
// frames settled and steady, nothing over text or cut off, the same at two heights where it
// should be, no work word left over, clicks that settle in time. `live-check.sh` runs the Claude
// and Codex tellings side by side, each in one app; areas that don't depend on the CLI run once,
// in one of the two.

/// An area of the tour: the storyline it walks (`wraps`), then `checks`.
class LiveArea: Storyline {
    override class var isFamily: Bool { self == LiveArea.self }
    override class var tags: Set<Tag> { [.liveCheck] }
    override class var variants: [Variant] { [.claude, .codex] }
    /// The storyline it walks first.
    class var wraps: Storyline.Type? { nil }
    override class var needs: Needs { wraps?.needs ?? Needs() }

    /// The wrapped storyline's steps, told for this variant.
    func walked() -> [any Step] {
        guard let type = Self.wraps else { return [] }
        let story = type.init()
        story.variant = variant
        return story.steps()
    }

    /// What's looked at after the walk.
    func checks() -> [any Step] { [] }

    override func steps() -> [any Step] { walked() + checks() }

    /// A chat of the variant's CLI with one answer in it.
    static func chat() -> [any Step] {
        [UseScript(CLIScript(turns: [CLIScript.reply("Hello there. A short answer to look at.")])), OpenFolder(), StartChat(), Send("Say hello"), TurnFinished(1)]
    }
}

// MARK: - Welcome and boxes

/// Welcome and its recent folders.
final class LiveWelcome: LiveArea {
    override class var variants: [Variant] { [.claude] }
    override func steps() -> [any Step] {
        Self.chat() + [ShowWelcome(), Look(name: "welcome", frames: 3, window: { _ in DevicesFromWelcome.welcome })]
    }
}

/// The Welcome's "+" (Add a box), as popup-jitter's WelcomeAddStill sets it going: KoreNet on, a
/// kore-host box on the tailnet, the SSH config naming a host, and the tailnet's bus saying
/// something every 20 ms while the popup is looked at. Its choices must hold still, whole in the window.
final class LiveBoxPlus: LiveArea {
    override class var variants: [Variant] { [.claude] }
    override func steps() -> [any Step] {
        let welcome: @MainActor (StoryContext) -> NSWindow? = { _ in DevicesFromWelcome.welcome }
        return Self.chat() + [
            DevicesSetUp(on: true, release: true, peers: ["mybox"]),
            Do("The SSH config names a host") { story in
                StorylineSeams.sshHosts = { true }
                _ = story.stash(LiveHostsReset.self) { LiveHostsReset() }
            },
            ShowWelcome(),
            Settles(inner: Do("Press the Welcome's +") { _ in
                guard let window = DevicesFromWelcome.welcome, let plus = StoryRegistry.entry(StoryID.Boxes.add.raw, in: window)?.press
                else { throw StoryFailure.elementNotFound(StoryID.Boxes.add.raw, nearby: []) }
                plus()
            }),
            Expect("mybox, Use SSH… and New box… listed") { _ in
                guard let window = DevicesFromWelcome.welcome else { return false }
                return [StoryID.Net.welcomePeer("mybox"), StoryID.Net.useSSH, StoryID.Net.newBox].allSatisfy { StoryRegistry.entry($0.raw, in: window)?.frame != nil }
            },
            Look(name: "boxplus", frames: 3, window: welcome, during: { _ in Devices.shared.changed() }),
            InsideWindow(ids: [StoryID.Net.welcomeAdd], window: welcome),
        ]
    }
}

/// Puts the SSH hosts seam back and closes the popup, pass or fail.
private final class LiveHostsReset: StoryFinishing {
    func finish() {
        StorylineSeams.sshHosts = nil
        NetPopupHost.shared.close()
    }
}

// MARK: - Tabs

/// New tab, switching, ⇧-select, ⌘W and ⇧⌘T.
final class LiveTabs: LiveArea {
    override class var wraps: Storyline.Type? { TabSelectCloseReopen.self }
    override func checks() -> [any Step] {
        [
            Settles(inner: Click(.tab(2))), Settles(inner: Click(.tab(5))), Settles(inner: Click(.tab(1))),
            Look(name: "tabs", frames: 3),
            Settles(inner: Press(.id(StoryID.Titlebar.newtab))),
            Look(name: "newtab", frames: 3),
        ]
    }
}

/// A tab dragged onto another groups them; the chip folds the group; the window closed and
/// opened again (as a person does it, from what it saved) has the group back. Kore is launched as
/// install.sh launches it (its variables in the environment): a dev run saves no windows at all.
final class LiveGroups: LiveArea {
    override class var wraps: Storyline.Type? { TabGroupMake.self }
    override func steps() -> [any Step] {
        [Do("Kore launched by the installer") { _ in
            Workspace.storyLaunch = ["KORE_BUILD_SHA": "0000000", "KORE_RELEASE_TAG": "v0.0.0", "KORE_SIGN_IDENTITY": "Kore"]
        }] + super.steps()
    }
    override func checks() -> [any Step] {
        [
            Settles(inner: PressChip()),
            Expect("folded") { try TabGroupProbe.group($0).folded },
            Look(name: "groups-folded", frames: 3),
            CloseAndReopen(),
            Expect("the group back after the window reopened", found: { story in
                let w = story.app.workspace
                return "\(w?.tabGroups.groups.count ?? 0) groups over \(w?.tabs.count ?? 0) tabs"
            }) { story in try TabGroupProbe.group(story).name == "Release" && TabGroupProbe.members(story).count == 2 },
            Look(name: "groups-reopened"),
        ]
    }
}

/// Closes the folder's window as a person does, then opens the folder again: what it saved on
/// the way out is all it has (no hand-off of the saved state).
struct CloseAndReopen: Step {
    var label: String { "Close the window, open the folder again" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace, let window = story.window else { throw StoryFailure.modelMissing("the window") }
        window.performClose(nil)
        if window.isVisible { window.close() }
        try await story.until("the window closed") { !window.isVisible }
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        model.openFolder(story.folder)
        try await story.until("the folder open again") { story.app.workspace !== workspace && story.window?.isVisible == true }
        story.window?.setContentSize(story.windowSize)
        try await story.idle()
    }
}

// MARK: - Chat

final class LiveChat: LiveArea {
    override class var wraps: Storyline.Type? { SendAndStream.self }
    override func checks() -> [any Step] { [Look(name: "chat", frames: 3)] }
}

/// A long chat: the message rail the same at two heights, nothing under it, jumps that settle.
final class LiveRail: LiveArea {
    override func steps() -> [any Step] {
        let rail = MessageRailMarks()
        rail.variant = variant
        // Its opening: the chat, the long session opened, the rail drawn.
        return Array(rail.steps().prefix(5)) + [
            SameAtHeights(what: "the message rail", id: StoryID.Transcript.rail),
            NoOverlap(what: "the rail", over: StoryID.Transcript.rail.raw, under: ["transcript.tool", "transcript.answer", "transcript.user"]),
            Settles(inner: Do("Click the first mark") { $0.app.chat?.storyTranscript.railJump(0) }, budget: 1500),
            Settles(inner: Do("Click the last mark") { story in
                story.app.chat?.storyTranscript.railJump((story.app.chat?.storyTranscript.railMarks.count ?? 1) - 1)
            }, budget: 1500),
            Look(name: "rail", frames: 3),
        ]
    }
}

/// Copy: a table with a link, part of a row.
final class LiveCopy: LiveArea {
    override class var wraps: Storyline.Type? { TableCopy.self }
    override func checks() -> [any Step] { [Look(name: "copy", frames: 3)] }
}

/// Copy across turns: several picked points at once.
final class LiveCopyTurns: LiveArea {
    override class var wraps: Storyline.Type? { SelectAcrossTurns.self }
    override func checks() -> [any Step] { [Look(name: "copy-turns")] }
}

// MARK: - Files, terminal, history, board

final class LiveFiles: LiveArea {
    override class var wraps: Storyline.Type? { FileTabState.self }
    override func checks() -> [any Step] { [Look(name: "files", frames: 3)] }
}

final class LiveExplorer: LiveArea {
    override class var variants: [Variant] { [.codex] }
    override class var wraps: Storyline.Type? { ExplorerFileOps.self }
    override func checks() -> [any Step] { [Look(name: "explorer", frames: 3)] }
}

/// The terminal: its caret blinks, so one frame.
final class LiveTerminal: LiveArea {
    override class var variants: [Variant] { [.claude] }
    override class var wraps: Storyline.Type? { WindowTerminal.self }
    override func checks() -> [any Step] { [Look(name: "terminal")] }
}

final class LiveHistory: LiveArea {
    override class var wraps: Storyline.Type? { HistorySearchesWords.self }
    override func checks() -> [any Step] { [Look(name: "history", frames: 3)] }
}

final class LiveBoard: LiveArea {
    override class var variants: [Variant] { [.codex] }
    override class var wraps: Storyline.Type? { BoardCreate.self }
    override func checks() -> [any Step] { [Look(name: "board", frames: 3)] }
}

// MARK: - Arsenal, devices, pickers, zoom, sizes

/// Arsenal on: the tab's CLI logo in Arsenal's blue and nothing else of the tab, then off: the
/// logo's own colours. Read off the window's pixels (ArsenalLogoTint).
final class LiveArsenal: LiveArea {
    override class var wraps: Storyline.Type? { ArsenalLogoTint.self }
    override func checks() -> [any Step] { [Look(name: "arsenal", frames: 3)] }
}

/// Devices' Add a box, through set up to Ready: the box card's line says Ready, no step left over.
final class LiveDevices: LiveArea {
    override class var variants: [Variant] { [.codex] }
    override class var wraps: Storyline.Type? { DevicesAddBox.self }
    override func checks() -> [any Step] {
        [Look(name: "devices", frames: 3), InsideWindow(ids: [StoryID.Net.panel])]
    }
}

final class LiveMode: LiveArea {
    override class var wraps: Storyline.Type? { ModePicker.self }
    override func checks() -> [any Step] { [Look(name: "mode", frames: 3)] }
}

final class LiveModel: LiveArea {
    override class var wraps: Storyline.Type? { ModelPicker.self }
    override func checks() -> [any Step] { [Look(name: "model", frames: 3)] }
}

/// ⌘= twice: the window at 120%, nothing cut off; ⌘0 back.
final class LiveZoom: LiveArea {
    override func steps() -> [any Step] {
        let zoomIn = Key(KeyChord(.character("="), .command))
        return Self.chat() + [
            Settles(inner: zoomIn), zoomIn,
            Expect("at 120%") { _ in abs(PinchZoom.storyScale() - 1.2) < 0.001 },
            Look(name: "zoom-120", frames: 3),
            InsideWindow(ids: Self.edges),
            Key(KeyChord(.character("0"), .command)),
            Expect("back to 100%") { _ in PinchZoom.storyScale() == 1 },
        ]
    }

    /// What sits at the window's edges.
    static let edges = [StoryID.Titlebar.newtab, StoryID.Titlebar.history, StoryID.Composer.send, StoryID.Composer.model, StoryID.Composer.mode]
}

/// A narrow and a wide window: the edges' controls whole, steady, nothing cut off.
final class LiveSizes: LiveArea {
    override func steps() -> [any Step] {
        Self.chat() + [
            Do("A narrow window, 560 × 700") { $0.window?.setContentSize(CGSize(width: 560, height: 700)) },
            Look(name: "narrow", frames: 3), InsideWindow(ids: LiveZoom.edges),
            Do("A wide window, 1800 × 1000") { $0.window?.setContentSize(CGSize(width: 1800, height: 1000)) },
            Look(name: "wide", frames: 3), InsideWindow(ids: LiveZoom.edges),
        ]
    }
}

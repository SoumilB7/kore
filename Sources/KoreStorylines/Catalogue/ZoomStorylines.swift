import AppKit
import KoreCore
import KoreUI
import src

/// ⌘= zooms the whole window, the way a browser's ⌘+ does, not the chat alone: two steps grow an
/// explorer row, the tab strip, the terminal's font and a popup's rows by 20% each, and ⌘0 gives
/// every one back its own size. Snapshots at 100% and 150%.
final class ZoomScalesWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let files = [("notes.md", "# Notes\n\nZoom check.\n"), ("src/app.swift", "let x = 1\n")]

    override func steps() -> [any Step] {
        let sizes = ZoomSizes()
        let zoomIn = Key(KeyChord(.character("="), .command))
        return [WriteFiles(Self.files)] + super.steps() + [
            Send("Say hello"),
            TurnFinished(1),
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals() },
            Key(.ctrl("`")),
            ExpectElement(.id(StoryID.Terminal.panel), .visible),
            Command(.toggleExplorer),
            Press(.treeRow("notes.md")),
            Do("Back to the chat, its file tab beside it") { $0.app.workspace?.storySelect(tabAt: 0) },
            Expect("the window at 100%") { _ in PinchZoom.storyScale() == 1 },
        ] + ZoomSizes.read(sizes, at: 1, label: "Read the window's sizes at 100%") + [
            Snapshot("zoom-100"),
            zoomIn, zoomIn,
            Expect("two steps in", found: { _ in "\(PinchZoom.storyScale())" }) { _ in abs(PinchZoom.storyScale() - 1.2) < 0.001 },
        ] + ZoomSizes.read(sizes, at: 1.2, label: "Expect every size grown to 120%") + [
            zoomIn, zoomIn, zoomIn,
            WaitIdle(),
            Snapshot("zoom-150"),
            Key(KeyChord(.character("0"), .command)),
            Expect("back to 100%") { _ in PinchZoom.storyScale() == 1 },
        ] + ZoomSizes.read(sizes, at: 1, label: "Expect every size back to its own")
    }
}

/// What the window measured at 100%, kept for the zoomed reads to compare with.
@MainActor
private final class ZoomSizes {
    struct Reading: CustomStringConvertible {
        var row: CGFloat, strip: CGFloat, terminal: CGFloat, popup: CGFloat
        var description: String { "row \(row), strip \(strip), terminal \(terminal)pt, popup row \(popup)" }
    }
    var base: Reading?

    /// A popup open over the explorer's row, the four sizes read, the popup closed.
    static func read(_ sizes: ZoomSizes, at scale: CGFloat, label: String) -> [any Step] {
        [
            WaitIdle(),
            RightClick(.treeRow("notes.md")),
            WaitForElement(.id(StoryID.Options.panel)),
            ReadSizes(sizes: sizes, scale: scale, label: label),
            Key(.escape),
            ExpectElement(.id(StoryID.Options.panel), .absent),
        ]
    }
}

private struct ReadSizes: Step {
    let sizes: ZoomSizes
    let scale: CGFloat
    let label: String
    var timeout: Duration? { nil }

    func run(_ story: StoryContext) async throws {
        let reading = try await story.wait("the explorer row, tab strip, terminal and popup laid out") { () -> ZoomSizes.Reading? in
            guard let row = StoryElement(StoryID.Explorer.row("notes.md"))?.frame?.height,
                  let strip = StoryElement(StoryID.Tabs.strip)?.frame?.height,
                  let terminal = story.app.workspace?.storyTerminalFontSize,
                  let popup = StoryElement(StoryID.Options.item(0))?.frame?.height,
                  row > 0, strip > 0, popup > 0 else { return nil }
            return ZoomSizes.Reading(row: row, strip: strip, terminal: terminal, popup: popup)
        }
        guard let base = sizes.base else {
            sizes.base = reading
            return
        }
        // Each one by the step, within a point's rounding.
        func near(_ value: CGFloat, _ base: CGFloat) -> Bool { abs(value - base * scale) <= 1 }
        guard near(reading.row, base.row), near(reading.strip, base.strip), abs(reading.terminal - base.terminal * scale) < 0.01,
              near(reading.popup, base.popup) else {
            throw StoryFailure.other("at \(scale)×: \(reading); at 100%: \(base)")
        }
    }
}

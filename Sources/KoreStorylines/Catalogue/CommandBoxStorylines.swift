import AppKit
import KoreUI

/// A command's IN / OUT box: clipped, with no scroll of its own, until it's clicked; clicked,
/// its output scrolls inside a capped box to its last line, ⌘A takes just that output and ⌘C copies
/// it; a click elsewhere closes it again.
final class CommandBoxFocus: ChatStoryline {
    static let output = (1...200).map { "out line \($0)" }.joined(separator: "\n")
    static let after = (1...40).map { "Paragraph \($0) after the command, long enough to make the transcript scroll." }
        .joined(separator: "\n\n")
    static let first = "Paragraph 1 after the command, long enough to make the transcript scroll."

    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [
            [.startTurn, .stream(.answer, "Listing it."), .tool(name: "Bash", detail: "seq 200", output: output),
             .stream(.answer, after), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        let tool = Locator.tool("Bash")
        return super.steps() + [
            Send("Show me"), TurnFinished(1), WaitIdle(),
            Press(.fold(turn: 1)),
            WaitForElement(tool.action(.toggle)),
            Scroll(tool, to: .top), WaitIdle(),
            ExpectElement(tool.action(.open), .absent),
            // Closed, it has no scroll view of its own: a turn of the wheel over it is the transcript's.
            Expect("the closed box to scroll with the transcript") { story in
                guard case .found(let element) = tool.action(.toggle).resolve(story.app),
                    let scroll = LongMessageOpens.scrollView(element.view)
                else { return false }
                return !String(describing: type(of: scroll)).contains("Opened")
            },
            // Its click is a tap, which the storyline's window (never key) doesn't pass on: its press.
            Press(tool.action(.toggle)),
            WaitForElement(tool.action(.open)),
            Expect("the output capped, scrolling inside", found: { story in Self.inner(tool, story).map { "\($0)" } }) { story in
                guard let (_, max) = Self.inner(tool, story) else { return false }
                return max > 0
            },
            Wheel(tool.action(.open), by: 20000), Wheel(tool.action(.open), by: 20000), Wheel(tool.action(.open), by: 20000),
            Expect("the output to scroll to its last line", found: { story in Self.inner(tool, story).map { "\($0)" } }) { story in
                guard let (offset, max) = Self.inner(tool, story) else { return false }
                return max > 0 && abs(offset - max) <= 1
            },
            Key(.cmd("a")),
            CopySelection(Self.output),
            Snapshot("command-box-open"),
            ClickText(Spot.lastAnswer(1, [0], at: Self.first, "Paragraph")),
            ExpectElement(tool.action(.open), .absent),
        ]
    }

    /// The opened output's scroll: how far it has gone, and how far it can.
    @MainActor static func inner(_ box: Locator, _ story: StoryContext) -> (CGFloat, CGFloat)? {
        guard case .found(let element) = box.action(.open).resolve(story.app),
            let scroll = LongMessageOpens.scrollView(element.view), let document = scroll.documentView
        else { return nil }
        let offset = scroll.contentView.bounds.minY - document.frame.minY
        return (offset, max(0, document.frame.height - scroll.contentView.bounds.height))
    }
}

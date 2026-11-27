import AppKit
import Foundation
import KoreUI

// A quote in an answer selects and copies as a paragraph does (owner, 0.3.10): a word, a line,
// a drag out of it into the next paragraph, ⌘A; nested, and in a list's point. And a code block's
// Copy, whatever its fence.

final class QuoteSelectCopy: ChatStoryline {
    static let reply = """
        Before the quote.

        > Resume from NOTES.md first.
        >
        > Then build the clone.

        After the quote.

        - A point with a quote:

          > Quoted in a point.

        > Outer quote.
        >
        > > Inner quote.

        ```
        a plain fence with one long line that runs on well past the width of the page, as a log line or a long command does, and then some more
        ```
        """
    static let first = "Resume from NOTES.md first."
    static let then = "Then build the clone."
    static let after = "After the quote."
    static let inPoint = "Quoted in a point."
    static let inner = "Inner quote."

    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Quote it"), TurnFinished(1), WaitIdle(),
            Snapshot("quote-rendered"),
            ClickText(.answer(1, [1, 0], at: Self.first, "Resume"), count: 2),
            CopySelection("Resume"),
            ClickText(.answer(1, [1, 1], at: Self.then, "build"), count: 3),
            CopySelection(Self.then),
            DragSelect(from: .answer(1, [1, 0], at: Self.first, "first"), to: .answer(1, [2], at: Self.after, " the")),
            CopySelection("> first.\n>\n> Then build the clone.\n\nAfter"),
            DragSelect(from: .answer(1, [0], at: "Before the quote.", "Before"), to: .answer(1, [2], at: Self.after, " the")),
            CopySelection("Before the quote.\n\n> Resume from NOTES.md first.\n>\n> Then build the clone.\n\nAfter"),
            ClickText(.answer(1, [3, 0, 1, 0], at: Self.inPoint, "point"), count: 2),
            CopySelection("point"),
            ClickText(.answer(1, [4, 1, 0], at: Self.inner, "Inner"), count: 2),
            CopySelection("Inner"),
            DragSelect(from: .answer(1, [4, 0], at: "Outer quote.", "Outer"), to: .answer(1, [4, 1, 0], at: Self.inner, " quote")),
            CopySelection("> Outer quote.\n>\n> > Inner"),
            // Copy is there before the pointer comes: a plain fence, one long line.
            Expect("Copy under the plain fence, unhovered") { _ in CodeBlockCopyBelow.copyBelow(0) }, Snapshot("plain-fence-copy"),
            HoverCode(0), Expect("and hovered") { _ in CodeBlockCopyBelow.copyBelow(0) },
            Press(.id(StoryID.Transcript.code([5]).part(.copy))),
            Expect("it copied the line") { _ in StoryTranscript.copied?.hasPrefix("a plain fence with one long line") == true },
        ]
    }
}

/// The owner's case: a long quote in a list's second point, between paragraphs (Kore-main's
/// answer of 2026-11-25 11:54).
final class QuoteInPointSelects: ChatStoryline {
    static let line = "Resume from NOTES.md (clones/box-identity, branch host-restart-bye): the host-restart rig run, then READY rebased on v0310 3607ba90, then the A/B box matrix. Build when load <30 and at most 1 other swift-build; Docker one rig at a time, stop it after, leave the owner's containers alone. mybox only via ssh mybox-cf. Short turns, no subagents."
    static let reply = """
        **To unblock Remote**, pick one:
        - open the Remote tab and set its mode to Auto, or to anything at or below this chat's;
        - or paste this into Remote yourself:

          > \(line)

        Remote has two things left, both needed for 0.3.10:
        """
    static let quote = [1, 1, 1, 0]
    static let after = "Remote has two things left, both needed for 0.3.10:"

    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("How do I unblock it?"), TurnFinished(1), WaitIdle(),
            Snapshot("quote-in-point"),
            ClickText(.answer(1, Self.quote, at: Self.line, "Docker"), count: 2),
            CopySelection("Docker"),
            ClickText(.answer(1, Self.quote, at: Self.line, "Resume"), count: 3),
            CopySelection(Self.line),
            DragSelect(from: .answer(1, Self.quote, at: Self.line, "Resume"), to: .answer(1, Self.quote, at: Self.line, " no subagents")),
            CopySelection("Resume from NOTES.md (clones/box-identity, branch host-restart-bye): the host-restart rig run, then READY rebased on v0310 3607ba90, then the A/B box matrix. Build when load <30 and at most 1 other swift-build; Docker one rig at a time, stop it after, leave the owner's containers alone. mybox only via ssh mybox-cf. Short turns,"),
            DragSelect(from: .answer(1, Self.quote, at: Self.line, "Short"), to: .answer(1, [2], at: Self.after, " has")),
            CopySelection("- > Short turns, no subagents.\n\nRemote"),
            Key(KeyChord(.character("a"), .command)),
            CopyContains(Self.line),
        ]
    }
}

/// The owner's answer as Kore-main wrote it, whole (its table after the quote).
final class QuoteInOwnerAnswer: ChatStoryline {
    static let reply = #"""
        No, it isn't all done, and Remote hasn't moved since last night. I tried again just now and Kore still refuses: "That chat's mode is above this one's: only you drive it." The chat list shows Remote at Auto like mine, so something else about its mode is higher. Only you can unblock it.

        **To unblock Remote**, pick one:
        - open the Remote tab and set its mode to Auto, or to anything at or below this chat's;
        - or paste this into Remote yourself:

          > Resume from NOTES.md (clones/box-identity, branch host-restart-bye): the host-restart rig run, then READY rebased on v0310 3607ba90, then the A/B box matrix. Build when load <30 and at most 1 other swift-build; Docker one rig at a time, stop it after, leave the owner's containers alone. mybox only via ssh mybox-cf. Short turns, no subagents.

        Remote has two things left, both needed for 0.3.10:
        - **The box-restart fix:** written, not committed, and not tested on the fake-box setup.
        - **The full box test grid:** box with SSH and box without, across every network setup. That's the "everything works end to end" proof you asked for, and it hasn't started.

        **Everyone else, 11:54:**

        | Item | Status |
        |---|---|
        | Staged in 0.3.10 | 35 commits |
        | Arsenal: review fixes for copies without SSH (incl. links kept) | committed, no READY yet |
        | Kore-3: quit hang, double paste and the rest | committed, no READY yet |
        | Chats: scroll and rail | committed, no READY yet; the rail position you just spotted is with them |
        | Kore-2: full UI test | menu tests pass; that test-runner crash is being checked first |

        **Still to do after that:** the full gate, the box grid, the latency run, and the live check with you on mybox and your phone.
        """#
    static let quote = [2, 1, 1, 0]

    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Is it all done?"), TurnFinished(1), WaitIdle(),
            Snapshot("owner-answer"),
            ClickText(.answer(1, Self.quote, at: QuoteInPointSelects.line, "Docker"), count: 2),
            CopySelection("Docker"),
            DragSelect(from: .answer(1, Self.quote, at: QuoteInPointSelects.line, "Resume"), to: .answer(1, Self.quote, at: QuoteInPointSelects.line, " no subagents")),
            CopyContains("mybox only via ssh mybox-cf. Short turns,"),
        ]
    }
}

/// ⌘C, and what it left holds `part`.
struct CopyContains: Step {
    let part: String
    init(_ part: String) { self.part = part }
    var label: String { "⌘C copies text with “\(part.prefix(40))”" }

    func run(_ story: StoryContext) async throws {
        StoryTranscript.clearCopied()
        try await Key(KeyChord(.character("c"), .command)).run(story)
        do {
            try await story.until("the copy") { StoryTranscript.copied?.contains(part) == true }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("⌘C to copy text with:\n\(part)\n— it copied:\n\(StoryTranscript.copied ?? "nothing")")
        }
    }
}

/// The same answer after a long one, read by scrolling up through it and back (its message
/// pinned on the way), as the owner had it: the quote still selects.
final class QuoteAfterScrolling: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        let long = (1...40).map { "Paragraph \($0) of a long answer before it, to scroll through." }.joined(separator: "\n\n")
        return CLIScript(turns: [CLIScript.reply(long), CLIScript.reply(QuoteInOwnerAnswer.reply)])
    }

    /// Scrolls the transcript by `dy` points (up when negative) in steps, as a wheel does.
    struct Scrolled: Step {
        let dy: CGFloat
        var label: String { "Scroll \(Int(dy)) pt" }
        func run(_ story: StoryContext) async throws {
            guard let view = try story.activeChat().storyTranscript.scrollView else { throw StoryFailure.modelMissing("the scroll view") }
            let steps = 12
            for _ in 0..<steps {
                var origin = view.contentView.bounds.origin
                origin.y = max(0, origin.y + dy / CGFloat(steps))
                view.contentView.scroll(to: origin)
                view.reflectScrolledClipView(view.contentView)
                try await Task.sleep(for: .milliseconds(40))
            }
            try await story.idle()
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Go on"), TurnFinished(1), WaitIdle(),
            Send("Is it all done?"), TurnFinished(2), WaitIdle(),
            Scrolled(dy: -900), Snapshot("scrolled-up"),
            Scrolled(dy: 500), Snapshot("partway-back"),
            ClickText(.answer(2, QuoteInOwnerAnswer.quote, at: QuoteInPointSelects.line, "Docker"), count: 2),
            CopySelection("Docker"),
            UnloadStoryline.ToEnd(),
            ClickText(.answer(2, QuoteInOwnerAnswer.quote, at: QuoteInPointSelects.line, "Resume"), count: 2),
            CopySelection("Resume"),
        ]
    }
}

/// Every way to take a quote's text, as a person tries them: a double and a triple click, a
/// drag inside it, a drag from the paragraph above into it and from the one below up into it,
/// ⌘A then ⌘C, and a right-click's Copy. At 100% (this one), at ⌘+'s 130%, and on a page a
/// pinch magnified.
class QuoteGestures: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { QuoteSelectCopy.script }
    /// What sets the text's size or the page's scale before the gestures.
    var sized: [any Step] { [] }

    static let first = QuoteSelectCopy.first, then = QuoteSelectCopy.then, after = QuoteSelectCopy.after
    static let line1: [Int] = [1, 0], line2: [Int] = [1, 1]

    override func steps() -> [any Step] {
        let spot = { (path: [Int], text: String, word: String) in Spot.answer(1, path, at: text, word) }
        return super.steps() + [Send("Quote it"), TurnFinished(1), WaitIdle()] + sized + [
            Snapshot("quote-gestures"),
            ClickText(spot(Self.line2, Self.then, "build"), count: 2),
            CopySelection("build"),
            ClickText(spot(Self.line1, Self.first, "NOTES"), count: 3),
            CopySelection(Self.first),
            DragSelect(from: spot(Self.line1, Self.first, "NOTES"), to: spot(Self.line1, Self.first, " first")),
            CopySelection("NOTES.md"),
            DragSelect(from: spot([0], "Before the quote.", "Before"), to: spot(Self.line1, Self.first, " NOTES")),
            CopySelection("Before the quote.\n\n> Resume from"),
            DragSelect(from: spot([2], Self.after, " the"), to: spot(Self.line2, Self.then, "build")),
            CopySelection("> build the clone.\n\nAfter"),
            ClickText(spot(Self.line2, Self.then, "clone"), count: 2),
            Key(KeyChord(.character("a"), .command)),
            CopyContains("> Resume from NOTES.md first.\n>\n> Then build the clone.\n\nAfter the quote."),
            ClickText(spot(Self.line2, Self.then, "clone"), count: 2),
            RightClickCopy(spot: spot(Self.line2, Self.then, "clone"), expected: "clone"),
        ]
    }

    /// A right-click on the selection, its Copy picked: the selection on the pasteboard.
    struct RightClickCopy: Step {
        let spot: Spot
        let expected: String
        var label: String { "Right-click \(spot), Copy: “\(expected)”" }

        func run(_ story: StoryContext) async throws {
            StoryTranscript.clearCopied()
            let (window, point) = try await spot.point(story)
            await story.input.rightClick(at: point, in: window)
            try await PickOption("Copy").run(story)
            do {
                try await story.until("the copy") { StoryTranscript.copied == expected }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("Copy to copy “\(expected)”; it copied “\(StoryTranscript.copied ?? "nothing")”")
            }
        }
    }
}

final class QuoteGesturesLarger: QuoteGestures {
    override var sized: [any Step] { [Do("Text at 130%") { _ in PinchZoom.storyRestoreScale(1.3) }, WaitIdle()] }
}

final class QuoteGesturesPinched: QuoteGestures {
    override var sized: [any Step] { [PinchAtQuote()] }

    /// A pinch at the quote's first line to about 1.5×, let go.
    struct PinchAtQuote: Step {
        var label: String { "Pinch the page to 1.5× at the quote" }
        func run(_ story: StoryContext) async throws {
            try await UnloadStoryline.GlideEnds().run(story)
            let (window, point) = try await Spot.answer(1, QuoteGestures.line1, at: QuoteGestures.first, "NOTES").point(story)
            guard PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point) else { throw StoryFailure.other("the page took no pinch") }
            for _ in 0..<25 {
                _ = PinchZoom.storySample(in: window, amount: 0.02, phase: .changed, at: point)
                try await Task.sleep(for: .milliseconds(8))
            }
            _ = PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point)
            try await story.until("the page magnified") { (PinchZoom.storyPageScale(in: window) ?? 1) > 1.4 && PinchZoom.storyPlacement(in: window) != nil }
            try await story.idle()
        }
    }
}

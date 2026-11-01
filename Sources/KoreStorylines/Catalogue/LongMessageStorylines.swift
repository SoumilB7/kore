import AppKit
import KoreUI

/// A long message stops at its first lines; a click on "Show full message" opens it a little:
/// its box grows, capped, and the rest scrolls inside it. ⌘A there takes just the message and ⌘C
/// copies it (to the storylines' own pasteboard); Escape closes it to the height it had, with the
/// transcript where it was. A click on its text opens it too, and a click elsewhere closes it.
/// Pinned at the top while its turn scrolls by, a click opens it the same way.
final class LongMessageOpens: ChatStoryline {
    static let prompt = (1...40).map { "Line \($0) of a long prompt, short enough to stay on one line." }.joined(separator: "\n")
    static let reply = (1...80).map { "Paragraph \($0) of the answer, long enough to push the message up and out of view." }
        .joined(separator: "\n\n")
    static let first = "Paragraph 1 of the answer, long enough to push the message up and out of view."

    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        let row = Locator.userMessage(1)
        let pinned = Self.pinned()
        return super.steps() + [
            Send(Self.prompt), TurnFinished(1), WaitIdle(),
            Scroll(row, to: .top),
            WaitForElement(row.action(.toggle)),
            Expect("the message closed: no text view of its own") { story in Self.opened(row, story) == nil },
            Note("closed", row),
            // A click, not a press: through the transcript's own handling of presses on text.
            Click(row.action(.toggle)),
            WaitForElement(row.action(.open)),
            ExpectOpened(name: "closed", box: row, text: row.action(.open)),
            Wheel(row.action(.open), by: 120),
            Expect("the text to scroll inside the box", found: { story in Self.inner(row, story).map { "offset \($0)" } }) { story in
                (Self.inner(row, story) ?? 0) > 0
            },
            Key(.cmd("a")),
            CopySelection(Self.prompt),
            Snapshot("long-message-opened"),
            Key(.escape),
            ExpectElement(row.action(.open), .absent),
            ExpectPlace(name: "closed", box: row),
            // A click on its text opens it; one elsewhere closes it.
            ClickText(Spot.message(1, at: Self.prompt, "Line 3")),
            WaitForElement(row.action(.open)),
            ClickText(Spot.answer(1, [0], at: Self.first, "answer")),
            ExpectElement(row.action(.open), .absent),
            ExpectPlace(name: "closed", box: row),
            // Pinned at the top once its row has gone above (a reader's scroll, a screen at a time).
            Scroll(.answer(turn: 1), to: .by(500)), WaitIdle(), Scroll(.answer(turn: 1), to: .by(500)), WaitIdle(),
            WaitForElement(pinned),
            Note("pinned", pinned),
            // Its click is a tap the storyline's window (never key) doesn't pass on: its press.
            Press(pinned),
            WaitForElement(pinned.action(.open)),
            ExpectOpened(name: "pinned", box: pinned, text: pinned.action(.open)),
            Wheel(pinned.action(.open), by: 120),
            Expect("the pinned text to scroll inside the box") { story in (Self.inner(pinned, story) ?? 0) > 0 },
            Key(.cmd("a")),
            CopySelection(Self.prompt),
            Snapshot("long-message-pinned-opened"),
            Key(.escape),
            ExpectElement(pinned.action(.open), .absent),
            ExpectPlace(name: "pinned", box: pinned),
        ]
    }

    /// The first message's pinned copy.
    @MainActor static func pinned() -> Locator {
        Locator("message 1 pinned", key: { app in
            guard let message = app.chat?.storyTranscript.entries.first(where: { $0.kind == .user }) else {
                return .failure(LocatorMiss("message 1 pinned: no message yet", pending: true))
            }
            return .success(StoryID.Transcript.pinned(message.id))
        })
    }

    /// The opened text's element, if it's there.
    @MainActor static func opened(_ box: Locator, _ story: StoryContext) -> StoryElement? {
        guard case .found(let element) = box.action(.open).resolve(story.app) else { return nil }
        return element
    }

    /// How far the opened text has scrolled inside its box.
    @MainActor static func inner(_ box: Locator, _ story: StoryContext) -> CGFloat? {
        guard let scroll = opened(box, story).flatMap({ scrollView($0.view) }), let document = scroll.documentView else { return nil }
        return scroll.contentView.bounds.minY - document.frame.minY
    }

    /// The opened text's most: twenty body lines.
    @MainActor static var cap: CGFloat { NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)) * 20 }

    @MainActor static func scrollView(_ view: NSView?) -> NSScrollView? {
        var view = view
        while let v = view {
            if let scroll = v as? NSScrollView { return scroll }
            view = v.superview
        }
        return nil
    }

    /// The box's height and the transcript's offset, as one place.
    final class Places { var places: [String: (height: CGFloat, offset: CGFloat)] = [:] }

    @MainActor static func place(_ story: StoryContext, _ box: Locator) throws -> (height: CGFloat, offset: CGFloat) {
        guard case .found(let element) = box.resolve(story.app), let frame = element.frame,
            let offset = scrollView(element.registeredView)?.contentView.bounds.origin.y
        else { throw StoryFailure.other("\(box) isn't on screen") }
        return (frame.height, offset)
    }
}

/// Notes a box's height and the transcript's offset under a name.
private struct Note: Step {
    let name: String
    let box: Locator
    init(_ name: String, _ box: Locator) {
        self.name = name
        self.box = box
    }
    var label: String { "Note \(box)'s height and the transcript's place as “\(name)”" }

    func run(_ story: StoryContext) async throws {
        _ = try await story.element(box)
        try await WaitIdle().run(story)
        story.stash(LongMessageOpens.Places.self) { .init() }.places[name] = try LongMessageOpens.place(story, box)
    }
}

/// Opened: the box taller than closed but capped, the transcript where it was.
private struct ExpectOpened: Step {
    let name: String
    let box: Locator
    let text: Locator
    var label: String { "Expect \(box) taller, capped, with the transcript where it was" }

    func run(_ story: StoryContext) async throws {
        guard let closed = story.stash(LongMessageOpens.Places.self, make: { .init() }).places[name] else { throw StoryFailure.other("nothing noted as \(name)") }
        let cap = LongMessageOpens.cap
        var seen = (height: CGFloat(0), offset: CGFloat(0), text: CGFloat(0))
        do {
            try await story.until("the box opened") {
                let now = try LongMessageOpens.place(story, box)
                guard case .found(let element) = text.resolve(story.app), let frame = element.frame else { return false }
                seen = (now.height, now.offset, frame.height)
                return now.height > closed.height + 40 && frame.height <= cap + 1 && frame.height > cap - 1
                    && abs(now.offset - closed.offset) <= 1
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation(
                "the box taller than \(Int(closed.height)) with its text capped at \(Int(cap)) and the transcript at \(closed.offset) "
                    + "(found box \(Int(seen.height)), text \(Int(seen.text)), offset \(seen.offset))")
        }
    }
}

/// Closed again: the height it had, the transcript where it was (±1 pt).
private struct ExpectPlace: Step {
    let name: String
    let box: Locator
    var label: String { "Expect \(box) as it was noted “\(name)”" }

    func run(_ story: StoryContext) async throws {
        guard let closed = story.stash(LongMessageOpens.Places.self, make: { .init() }).places[name] else { throw StoryFailure.other("nothing noted as \(name)") }
        var seen = closed
        do {
            try await story.until("the box back as it was") {
                seen = try LongMessageOpens.place(story, box)
                return abs(seen.height - closed.height) <= 1 && abs(seen.offset - closed.offset) <= 1
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("height \(closed.height) at offset \(closed.offset) (found \(seen.height) at \(seen.offset))")
        }
    }
}


/// A long message opened and closed at the top of a long answer, then a jump to the end in one
/// go (the scroll bar, End). Now and then the view lands below the last row, on a height the lazy
/// stack hasn't corrected: the blank check builds the scroll view again and the end is drawn.
final class LongMessageJumpToEnd: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(LongMessageOpens.reply)]) }

    override func steps() -> [any Step] {
        let row = Locator.userMessage(1)
        return super.steps() + [
            Send(LongMessageOpens.prompt), TurnFinished(1), WaitIdle(),
            Scroll(row, to: .top),
            WaitForElement(row.action(.toggle)),
            Click(row.action(.toggle)),
            WaitForElement(row.action(.open)),
            Wheel(row.action(.open), by: 120),
            Key(.cmd("a")),
            CopySelection(LongMessageOpens.prompt),
            Key(.escape),
            ExpectElement(row.action(.open), .absent),
            ClickText(Spot.message(1, at: LongMessageOpens.prompt, "Line 3")),
            WaitForElement(row.action(.open)),
            ClickText(Spot.answer(1, [0], at: LongMessageOpens.first, "answer")),
            ExpectElement(row.action(.open), .absent),
            WaitIdle(),
            Scroll(.answer(turn: 1), to: .bottom), WaitIdle(),
            Snapshot("long-message-jumped"),
            ExpectDrawnAtEnd(),
        ]
    }
}

/// Within the blank check's time and a rebuild: the visible part on the content, at its end, with
/// layers drawing there.
private struct ExpectDrawnAtEnd: Step {
    var label: String { "Expect the transcript's end drawn" }

    func run(_ story: StoryContext) async throws {
        var seen = "no scroll view"
        let transcript = try story.activeChat().storyTranscript
        do {
            try await story.until("the end drawn", timeout: .seconds(4)) {
                guard let scroll = transcript.scrollView, scroll.window != nil, let document = scroll.documentView else { return false }
                let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
                let drawn = Self.drawn(document, in: visible)
                seen = "document \(Int(document.frame.height)), visible \(Int(visible.minY))–\(Int(visible.maxY)), \(drawn) layers drawn"
                return document.bounds.intersects(visible) && visible.maxY >= document.bounds.maxY - 60 && drawn > 0
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("rows drawn at the end (found \(seen))")
        }
    }

    /// Layers with contents in the visible part, as the timeline's blank check counts them.
    @MainActor static func drawn(_ document: NSView, in visible: CGRect) -> Int {
        guard let root = document.layer else { return 0 }
        var count = 0
        func walk(_ layer: CALayer, depth: Int) {
            for sub in layer.sublayers ?? [] where !sub.isHidden && sub.opacity > 0 {
                let frame = sub.convert(sub.bounds, to: root)
                guard frame.intersects(visible) else { continue }
                if sub.contents != nil { count += 1 }
                if depth < 6 { walk(sub, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return count
    }
}


/// A transcript's scroll view built again, as for a blank one: the timeline still knows the view
/// it's in, with rows drawn. At the end it stays at the end; a reader above it stays there.
final class BlankTranscriptRebuilt: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(LongMessageOpens.reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("A long answer"), TurnFinished(1), WaitIdle(),
            RebuildAndExpect(atEnd: true),
            Scroll(.userMessage(1), to: .top), WaitIdle(),
            RebuildAndExpect(atEnd: false),
        ]
    }
}

private struct RebuildAndExpect: Step {
    let atEnd: Bool
    var label: String { "Build the scroll view again, \(atEnd ? "at the end" : "above it")" }

    func run(_ story: StoryContext) async throws {
        let transcript = try story.activeChat().storyTranscript
        guard let old = transcript.scrollView else { throw StoryFailure.other("no scroll view known before the rebuild") }
        let before = old.contentView.bounds.minY
        transcript.rebuildScrollView()
        var seen = "the old scroll view"
        do {
            try await story.until("the rebuilt view drawn", timeout: .seconds(3)) {
                guard let scroll = transcript.scrollView, scroll !== old, scroll.window != nil, let document = scroll.documentView else {
                    seen = transcript.scrollView == nil ? "no scroll view known" : "the old scroll view"
                    return false
                }
                let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
                let drawn = ExpectDrawnAtEnd.drawn(document, in: visible)
                seen = "document \(Int(document.frame.height)), visible \(Int(visible.minY))–\(Int(visible.maxY)), \(drawn) layers, was \(Int(before))"
                guard drawn > 0 else { return false }
                let end = visible.maxY >= document.bounds.maxY - 60
                return atEnd ? end : !end && abs(visible.minY - before) < 200
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("the rebuilt scroll view drawn \(atEnd ? "at the end" : "where it was") (found \(seen))")
        }
    }
}

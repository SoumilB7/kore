import AppKit
import KoreUI

// The transcript's one text selection (z-docs/research/transcript-selection.md): a press and a
// drag from any text to any other, across blocks, rows and turns; ⌘C copies markdown built from
// the model. Copies go to the storylines' own pasteboard, never the owner's clipboard.

/// From the middle of turn 1's paragraph into turn 2's code block: the list, the second message
/// and turn 2's first line between are selected, both answers draw their part, and ⌘C gives the
/// structure: inline code kept, list markers, the message as a quote, a fenced partial code
/// block. A third turn streaming in afterwards leaves the selection as it was.
final class SelectAcrossTurns: ChatStoryline {
    static let first = """
        ## Plan

        First we read the **config** file and check `port` values before anything else runs.

        - one item
        - and `another`
        """
    static let second = """
        Here is the code:

        ```swift
        let answer = 42
        let question = answer / 6
        ```

        That's all.
        """
    static let expected = """
        check `port` values before anything else runs.

        - one item
        - and `another`

        > Tell me more

        Here is the code:

        ```swift
        let answer = 42
        let question =\u{20}
        ```
        """

    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply(first), CLIScript.reply(second), CLIScript.reply("A third answer, streamed in while the selection stays.")])
    }

    override func steps() -> [any Step] {
        let from = Spot.answer(1, [1], at: "First we read the config file and check port values before anything else runs.", "check")
        let to = Spot.answer(2, [1], at: "let answer = 42\nlet question = answer / 6", "answer / 6")
        return super.steps() + [
            Send("Make a plan"), TurnFinished(1),
            Send("Tell me more"), TurnFinished(2),
            DragSelect(from: from, to: to),
            Snapshot("selected"),
            Expect("both answers draw their part of the selection") { story in
                let t = try story.activeChat().storyTranscript
                let (a, b) = (try Spot.answer(1).entry(story), try Spot.answer(2).entry(story))
                return t.highlightRects(a) > 0 && t.highlightRects(b) > 0
            },
            Expect("the transcript to hold focus") { try $0.activeChat().storyTranscript.selectionFocused },
            CopySelection(Self.expected),
            Send("And a third"), TurnFinished(3), WaitIdle(),
            Expect("the selection unchanged by the third turn", found: { try? $0.activeChat().storyTranscript.selectionMarkdown }) {
                try $0.activeChat().storyTranscript.selectionMarkdown == Self.expected
            },
        ]
    }
}

/// A double-click takes a word, a triple-click its paragraph, and a drag after a double-click
/// grows by whole words; Escape lets the selection go.
final class SelectWordsAndParagraphs: ChatStoryline {
    static let reply = """
        Some **bold** words and `code` here.

        A second paragraph that follows the first one.
        """
    static let first = "Some bold words and code here."
    static let second = "A second paragraph that follows the first one."

    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Write two paragraphs"), TurnFinished(1),
            ClickText(.answer(1, [0], at: Self.first, "old"), count: 2),
            CopySelection("**bold**"),
            ClickText(.answer(1, [0], at: Self.first, "words"), count: 3),
            CopySelection("Some **bold** words and `code` here."),
            DragSelect(from: .answer(1, [0], at: Self.first, "ords"), to: .answer(1, [1], at: Self.second, "aragraph"), clicks: 2),
            CopySelection("words and `code` here.\n\nA second paragraph"),
            Key(.escape),
            Expect("Escape to let the selection go") { try !$0.activeChat().storyTranscript.hasSelection },
        ]
    }
}

/// A click puts the start down; a ⇧-click in the next turn selects everything between.
final class ShiftClickExtends: ChatStoryline {
    static let first = "The first answer has a sentence to start in."
    static let second = "The second answer has one to end in."

    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(first), CLIScript.reply(second)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("One"), TurnFinished(1), Send("Two"), TurnFinished(2),
            ClickText(.answer(1, [0], at: Self.first, "sentence")),
            Expect("a click to select nothing yet") { try !$0.activeChat().storyTranscript.hasSelection },
            ClickText(.answer(2, [0], at: Self.second, " to end"), shift: true),
            CopySelection("sentence to start in.\n\n> Two\n\nThe second answer has one"),
        ]
    }
}

/// A resumed chat shows only its last ten turns: ⌘A takes those, as quotes and answers, without
/// laying out the texts it covers (a text selected whole fills its frame); once scrolling up has
/// loaded the earlier turns it takes them all. A selection kept while its rows scroll away and back comes back.
final class SelectAllLongChat: ChatStoryline {
    static let turns = 13
    static func answer(_ n: Int) -> String { "Answer \(n): a paragraph with **bold** and `code`.\n\n- point one of \(n)\n- point two of \(n)" }
    static func paragraph(_ n: Int) -> String { "Answer \(n): a paragraph with bold and code." }

    override class var tags: Set<Tag> { [.chat] }

    static func whole(_ range: ClosedRange<Int>) -> String {
        range.map { "> Question \($0)\n\n" + answer($0) }.joined(separator: "\n\n")
    }

    override func steps() -> [any Step] {
        super.steps() + [
            ReplayTurns((1...Self.turns).map { ("Question \($0)", Self.answer($0)) }),
            Expect("only the last ten turns shown") { story in
                let t = try story.activeChat().storyTranscript
                return try !t.isBuilt(Spot.answer(1).entry(story)) && t.isBuilt(Spot.answer(Self.turns).entry(story))
            },
            ClickText(.answer(Self.turns, [0], at: Self.paragraph(Self.turns), "paragraph")),
            Remember("work before ⌘A") { try $0.activeChat().storyTranscript.selectionWork.laidOut },
            Key(KeyChord(.character("a"), .command)),
            Expect("the rows on screen to draw the selection") { story in
                let t = try story.activeChat().storyTranscript
                let (a, b) = (try Spot.answer(Self.turns).entry(story), try Spot.answer(Self.turns - 1).entry(story))
                return t.highlightRects(a) > 0 && t.highlightRects(b) > 0
            },
            Expect("⌘A to lay out no text again (each is selected whole)", found: { story in
                (try? story.activeChat().storyTranscript.selectionWork.laidOut).map { "\($0) laid out" }
            }) { story in
                try story.activeChat().storyTranscript.selectionWork.laidOut == Remember.value(story, "work before ⌘A")
            },
            CopySelection(Self.whole((Self.turns - 9)...Self.turns)),
            // Up near the top, the earlier turns go in above by themselves.
            Scroll(.answer(turn: Self.turns), to: .top),
            Expect("the earlier turns loaded") { story in try story.activeChat().storyTranscript.isBuilt(try Spot.answer(1).entry(story)) },
            ClickText(.answer(1, [0], at: Self.paragraph(1), "paragraph")),
            Key(KeyChord(.character("a"), .command)),
            CopySelection(Self.whole(1...Self.turns)),
            DragSelect(from: .answer(1, [0], at: Self.paragraph(1), "with"), to: .answer(2, [0], at: Self.paragraph(2), "with")),
            Scroll(.answer(turn: 2), to: .bottom),
            Scroll(.answer(turn: Self.turns), to: .top),
            Expect("the selection kept while its rows scrolled away and back", found: { story in
                guard let t = try? story.activeChat().storyTranscript, let id = try? Spot.answer(1).entry(story) else { return nil }
                return "\(t.selectionMarkdown.prefix(60)) rects \(t.highlightRects(id))"
            }) { story in
                let t = try story.activeChat().storyTranscript
                let first = try Spot.answer(1).entry(story)
                return t.selectionMarkdown.hasPrefix("with **bold**") && t.highlightRects(first) > 0
            },
            Scroll(.answer(turn: Self.turns), to: .bottom),
            DragPastTop(from: .answer(Self.turns, [0], at: Self.paragraph(Self.turns), "paragraph")),
        ]
    }
}

/// Past turns loaded as a resumed session's history.
struct ReplayTurns: Step {
    let turns: [(message: String, answer: String)]
    init(_ turns: [(String, String)]) { self.turns = turns.map { (message: $0.0, answer: $0.1) } }
    var label: String { "Load \(turns.count) past turns" }

    func run(_ story: StoryContext) async throws {
        try story.activeChat().storyTranscript.replay(turns)
        try await story.until("the last turn's answer shown") {
            let t = try story.activeChat().storyTranscript
            return t.isBuilt(try Spot.answer(turns.count).entry(story))
        }
        try await WaitIdle().run(story)
    }
}

/// A turn whose steps fold into "Worked for…": a selection across it copies the turn's answer
/// and earlier write-ups, without the folded commands. Opened, the command and its output
/// copy as code blocks; closed again, the box is left out.
final class SelectAcrossTools: ChatStoryline {
    static let before = "Let me look at the folder."
    static let after = "There are two files."
    static let next = "Anything else is up to you."

    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [
            [.startTurn, .stream(.answer, before), .tool(name: "Bash", detail: "ls", output: "a.txt\nb.txt"), .stream(.answer, after), .finishTurn(.completed)],
            CLIScript.reply(next),
        ])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("What's here?"), TurnFinished(1), Send("Thanks"), TurnFinished(2),
            DragSelect(from: .lastAnswer(1, [0], at: Self.after, "two"), to: .answer(2, [0], at: Self.next, " is up")),
            CopySelection("two files.\n\n> Thanks\n\nAnything else"),
            DragSelect(from: .message(1, at: "What's here?", "here"), to: .lastAnswer(1, [0], at: Self.after, " files")),
            CopySelection("> here?\n\n" + Self.before + "\n\nThere are two"),
            Press(.fold(turn: 1)),
            Press(.tool("Bash")),
            Expect("the command's box open") { story in try story.activeChat().storyTranscript.selectableTexts(try Spot.tool("Bash").entry(story)).contains([0]) },
            DragSelect(from: .firstAnswer(1, [0], at: Self.before, "the folder"), to: .lastAnswer(1, [0], at: Self.after, " files")),
            CopySelection("the folder.\n\n```bash\nls\n```\n\n```\na.txt\nb.txt\n```\n\nThere are two"),
            DragSelect(from: Spot(row: .tool("Bash"), path: [0], offset: 1), to: Spot(row: .tool("Bash"), path: [0], offset: 7)),
            Expect("a drag inside the box to leave it open") { story in try story.activeChat().storyTranscript.selectableTexts(try Spot.tool("Bash").entry(story)).contains([0]) },
            CopySelection("```\n.txt\nb\n```"),
            Press(.tool("Bash")),
            DragSelect(from: .firstAnswer(1, [0], at: Self.before, "the folder"), to: .lastAnswer(1, [0], at: Self.after, " files")),
            CopySelection("the folder.\n\nBash ls\n\nThere are two"),
        ]
    }
}

/// Presses that aren't the transcript's text: a drag from the composer selects nothing; a click
/// on a link is the link's; a click away from text lets the selection go. (A pinned message is
/// left alone the same way, by its reported frame; in-process scrolls don't pin one reliably, so
/// it isn't driven here.)
final class PressesOutsideText: ChatStoryline {
    static func long(_ n: Int, lines: Int = 25) -> String {
        (1...lines).map { "Line \($0) of answer \(n), long enough to wrap in a narrow column and fill the transcript." }.joined(separator: "\n\n")
    }
    static let link = "See [the guide](https://example.com/guide) for more."

    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            ReplayTurns([("Long one", Self.long(1) + "\n\n" + Self.link), ("Long two", Self.long(2))]),
            DragFromElement(.id(StoryID.Composer.field), up: 300),
            Expect("a drag from the composer to select nothing") { try !$0.activeChat().storyTranscript.hasSelection },
            ClickText(.answer(1, [25], at: "See the guide for more.", "guide")),
            Expect("the link's click to open it (noted, not opened, under storylines)") { _ in
                StoryTranscript.openedLinks.last?.absoluteString == "https://example.com/guide"
            },
            DragSelect(from: .answer(1, [25], at: "See the guide for more.", "See"), to: .answer(1, [25], at: "See the guide for more.", " for")),
            Expect("a selection") { try $0.activeChat().storyTranscript.hasSelection },
            ClickBeside(.answer(1, [25], at: "See the guide for more.", "See")),
            Expect("a click away from text to let it go") { try !$0.activeChat().storyTranscript.hasSelection },
        ]
    }
}

/// Links in an answer: a file's opens it in a Kore tab (an HTML page in the web renderer) and
/// the system gets nothing; a web link is the system's (noted, never opened, under storylines).
final class ChatFileLink: ChatStoryline {
    static let page = "site/index.html"
    static let shown = "Open the page or the docs."
    static let docs = "https://example.com/docs"

    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        [
            WriteFiles([(Self.page, "<!doctype html><title>Page</title><p>Hello from the page.</p>")]),
            // The link names the run's own folder, so the script is made once it's known.
            UseFolderScript { folder in
                let file = folder.appendingPathComponent(Self.page).absoluteString
                return CLIScript(turns: [CLIScript.reply("Open [the page](\(file)) or [the docs](\(Self.docs)).")])
            },
            OpenFolder(),
            StartChat(),
            Send("Where is the page?"),
            TurnFinished(1),
            ClickText(.answer(1, [0], at: Self.shown, "docs")),
            Expect("the web link noted for the system, not opened in Kore") { _ in
                StoryTranscript.openedLinks.last?.absoluteString == Self.docs
                    && !StoryTranscript.linksOpenedInKore.contains { $0.absoluteString == Self.docs }
            },
            Expect.fileTabs("no file tab for it") { $0.isEmpty },
            ClickText(.answer(1, [0], at: Self.shown, "page")),
            Expect.fileTabs("the page in a preview tab") { $0 == [StoryFileTab(path: Self.page, preview: true, active: true)] },
            Expect("the page in the web renderer", found: { $0.app.workspace?.storyActiveRenderer ?? "no renderer" }) {
                $0.app.workspace?.storyActiveRenderer == "html"
            },
            Expect("the click opened in Kore, with nothing for the system") { _ in
                guard let link = StoryTranscript.openedLinks.last, link.isFileURL else { return false }
                return StoryTranscript.linksOpenedInKore.last == link && link.path(percentEncoded: false).hasSuffix(Self.page)
            },
        ]
    }
}

/// A bullet whose second line, after a line break, is a long file path in inline code, at 110%
/// zoom (Menlo at 13.2 pt, which once wrapped the selection's copy of it): a drag over that line and past its end, a
/// double- and a triple-click on it, and a drag across both lines highlight their glyphs and
/// nothing under them, in a wide window and a narrow one, and copy what they cover.
final class SelectCodeLineInBullet: ChatStoryline {
    static let path = "file:///Users/soumil/Code/Projects/kore/z-docs/design/chat-handoff.html"
    static let reply = "- The design doc is here: [chat-handoff.html](\(path))  \n  `\(path)`"
    static let shown = "The design doc is here: chat-handoff.html\n" + path
    static let item = [0, 0, 0]

    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        let code = Spot.answer(1, Self.item, at: Self.shown, "file:")
        let last = code.shifted(Self.path.utf16.count - 1)
        let line = { (name: String) -> [any Step] in
            [
                DragSelect(from: code, to: last, past: CGVector(dx: 60, dy: 0)),
                Snapshot(name),
                Self.onlyGlyphs("the code line's highlight on its glyphs only"),
                CopySelection("- `\(Self.path)`"),
            ]
        }
        return super.steps() + [
            Send("Where is the design doc?"), TurnFinished(1),
            Key(KeyChord(.character("="), .command)), WaitIdle(),
        ] + line("code-line-wide") + [
            ClickText(.answer(1, Self.item, at: Self.shown, "soumil"), count: 2),
            Self.onlyGlyphs("a double-click's word highlighted on its glyphs only"),
            CopySelection("- `soumil`"),
            ClickText(.answer(1, Self.item, at: Self.shown, "Projects"), count: 3),
            Self.onlyGlyphs("a triple-click's line highlighted on its glyphs only"),
            CopySelection("- `\(Self.path)`"),
            DragSelect(from: .answer(1, Self.item, at: Self.shown, "design doc"), to: last, past: CGVector(dx: 60, dy: 0)),
            Snapshot("both-lines-wide"),
            Self.onlyGlyphs("both lines highlighted on their glyphs only"),
            CopySelection("- design doc is here: [chat-handoff.html](\(Self.path))\n  `\(Self.path)`"),
            SizeWindow(width: 620), WaitIdle(),
        ] + line("code-line-narrow") + [
            Key(KeyChord(.character("0"), .command)), WaitIdle(),
        ]
    }

    static func onlyGlyphs(_ what: String) -> Expect {
        Expect(what, found: { story in
            guard let t = try? story.activeChat().storyTranscript, let id = try? Spot.answer(1).entry(story) else { return nil }
            return t.highlightDescription(id)
        }) { story in
            let t = try story.activeChat().storyTranscript
            let id = try Spot.answer(1).entry(story)
            return t.highlightRects(id) > 0 && t.strayHighlights(id).isEmpty
        }
    }
}

/// Gives the window's content a new width, its height kept.
struct SizeWindow: Step {
    let width: CGFloat
    var label: String { "Size the window \(Int(width)) pt wide" }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let content = window.contentView else { throw StoryFailure.other("no window") }
        window.setContentSize(CGSize(width: width, height: content.bounds.height))
    }
}

/// Sets the scripted CLI's script from the storyline's folder (a reply that names a file in it).
struct UseFolderScript: Step {
    let make: @MainActor (URL) -> CLIScript
    var label: String { "Use a script for the folder" }

    func run(_ story: StoryContext) async throws {
        try await UseScript(make(story.folder)).run(story)
    }
}

// MARK: Places and steps

/// A place in a text of the active chat: which row, which of its texts, and the offset of
/// `word` in what the text shows.
struct Spot: CustomStringConvertible {
    enum Row { case answer(Int), firstAnswer(Int), message(Int), tool(String) }
    let row: Row
    let path: [Int]
    let offset: Int

    static func answer(_ turn: Int, _ path: [Int] = [0], at shown: String = "", _ word: String = "") -> Spot {
        Spot(row: .answer(turn), path: path, offset: utf16(shown, word))
    }
    /// The turn's last answer (after its work).
    static func lastAnswer(_ turn: Int, _ path: [Int], at shown: String, _ word: String) -> Spot { answer(turn, path, at: shown, word) }
    /// The turn's first answer (before its work).
    static func firstAnswer(_ turn: Int, _ path: [Int], at shown: String, _ word: String) -> Spot {
        Spot(row: .firstAnswer(turn), path: path, offset: utf16(shown, word))
    }
    static func message(_ n: Int, at shown: String, _ word: String) -> Spot { Spot(row: .message(n), path: [0], offset: utf16(shown, word)) }
    static func tool(_ name: String, _ path: [Int] = [0], at shown: String = "", _ word: String = "") -> Spot {
        Spot(row: .tool(name), path: path, offset: utf16(shown, word))
    }

    private static func utf16(_ s: String, _ word: String) -> Int {
        guard !word.isEmpty, let r = s.range(of: word) else { return 0 }
        return s.utf16.distance(from: s.utf16.startIndex, to: r.lowerBound)
    }

    var description: String { "\(row)\(path)@\(offset)" }

    /// The same text, `by` UTF-16 units on.
    func shifted(_ by: Int) -> Spot { Spot(row: row, path: path, offset: offset + by) }

    @MainActor func entry(_ story: StoryContext) throws -> UUID { try entry(story: story) }

    @MainActor func entry(story: StoryContext) throws -> UUID {
        let t = try story.activeChat().storyTranscript
        switch row {
        case .answer(let n), .firstAnswer(let n):
            let turns = t.turns
            guard turns.indices.contains(n - 1) else { throw StoryFailure.modelMissing("turn \(n)") }
            let answers = t.entries.filter { $0.turn == turns[n - 1] && $0.kind == .answer }
            guard let e = { if case .firstAnswer = row { answers.first } else { answers.last } }() else {
                throw StoryFailure.modelMissing("turn \(n)'s answer")
            }
            return e.id
        case .message(let n):
            let messages = t.entries.filter { $0.kind == .user }
            guard messages.indices.contains(n - 1) else { throw StoryFailure.modelMissing("message \(n)") }
            return messages[n - 1].id
        case .tool(let name):
            guard let e = t.entries.first(where: { $0.kind == .tool && $0.toolName == name }) else { throw StoryFailure.modelMissing("\(name) call") }
            return e.id
        }
    }

    /// Its point in window coordinates, its row brought into view first, and then the text
    /// itself (a long row can hold it out of sight).
    @MainActor func point(_ story: StoryContext) async throws -> (NSWindow, CGPoint) {
        let id = try entry(story: story)
        let t = try story.activeChat().storyTranscript
        if !t.isBuilt(id) || t.textPoint(id, path, offset: offset) == nil { t.show(id) }
        try await Spot.holdStill(story)
        let first: CGPoint
        do {
            first = try await story.wait("\(self) laid out") { try story.activeChat().storyTranscript.textPoint(id, path, offset: offset) }
        } catch StoryFailure.timedOut {
            let t = try story.activeChat().storyTranscript
            throw StoryFailure.expectation("\(self) laid out: built \(t.isBuilt(id)), texts \(t.selectableTexts(id))")
        }
        if !Spot.visible(first, story), let content = story.window?.contentView {
            // The timeline's own scroll to the row first: it stops following the end.
            t.show(id)
            try await Spot.holdStill(story)
            if let now = t.textPoint(id, path, offset: offset), !Spot.visible(now, story) {
                t.scrollContent(by: content.bounds.height / 2 - now.y)
                try await Spot.holdStill(story)
            }
        }
        let p = try await story.wait("\(self) on screen") {
            try story.activeChat().storyTranscript.textPoint(id, path, offset: offset).flatMap { Spot.visible($0, story) ? $0 : nil }
        }
        guard let window = story.window else { throw StoryFailure.other("no window") }
        return (window, p)
    }

    /// On screen: below the title bar and above the composer.
    @MainActor static func visible(_ p: CGPoint, _ story: StoryContext) -> Bool {
        guard let content = story.window?.contentView else { return false }
        let composerTop = StoryElement(StoryID.Composer.field)?.frame.map { $0.maxY + 24 } ?? content.bounds.height * 0.2
        return p.y > composerTop && p.y < content.bounds.height - 60 && p.x > 0 && p.x < content.bounds.width
    }

    /// The timeline glides for a moment after a send or a reveal: waits until rows hold still.
    @MainActor static func holdStill(_ story: StoryContext) async throws {
        var last: (CGFloat?, ContinuousClock.Instant) = (nil, .now)
        try await story.until("the transcript to hold still", timeout: .seconds(6)) {
            let y = story.app.chat?.storyTranscript.selectionAnchorY
            if y != last.0 { last = (y, .now) }
            return ContinuousClock.now - last.1 > .milliseconds(250)
        }
    }
}

/// A press at one place and a drag to another (a double-click press first with `clicks: 2`).
struct DragSelect: Step {
    let from: Spot
    let to: Spot
    var clicks = 1
    /// Where the drag ends past `to` (window points, y up): off the line's end, say.
    var past = CGVector.zero
    var label: String { "Drag-select from \(from) to \(to)" + (past == .zero ? "" : " and \(Int(past.dx)), \(Int(past.dy)) pt on") }

    func run(_ story: StoryContext) async throws {
        let (window, a) = try await from.point(story)
        let (_, end) = try await to.point(story)
        let b = CGPoint(x: end.x + past.dx, y: end.y + past.dy)
        if clicks > 1 {
            await story.input.click(at: a, in: window, count: clicks - 1)
        }
        await story.input.drag(from: a, to: b, in: window, clicks: clicks)
    }
}

/// A click (or several) on a place, maybe with ⇧.
struct ClickText: Step {
    let spot: Spot
    var count = 1
    var shift = false
    init(_ spot: Spot, count: Int = 1, shift: Bool = false) {
        self.spot = spot
        self.count = count
        self.shift = shift
    }
    var label: String { "\(shift ? "⇧-" : "")\(count > 1 ? "\(count)× " : "")click \(spot)" }

    func run(_ story: StoryContext) async throws {
        let (window, p) = try await spot.point(story)
        await story.input.click(at: p, in: window, count: count, modifiers: shift ? .shift : [])
    }
}

/// A click in the row's margin, left of a text: on the transcript, away from text.
struct ClickBeside: Step {
    let spot: Spot
    init(_ spot: Spot) { self.spot = spot }
    var label: String { "Click beside \(spot)" }

    func run(_ story: StoryContext) async throws {
        let (window, p) = try await spot.point(story)
        await story.input.click(at: CGPoint(x: p.x - 30, y: p.y), in: window)
    }
}

/// A drag from an element's middle, up over the transcript.
struct DragFromElement: Step {
    let element: Locator
    let up: CGFloat
    init(_ element: Locator, up: CGFloat) {
        self.element = element
        self.up = up
    }
    var label: String { "Drag from \(element) up \(Int(up)) pt" }

    func run(_ story: StoryContext) async throws {
        try await Spot.holdStill(story)
        guard let window = story.window, let frame = try await story.element(element).frame else { throw StoryFailure.other("\(element) has no frame") }
        let a = CGPoint(x: frame.midX, y: frame.midY)
        await story.input.drag(from: a, to: CGPoint(x: a.x, y: a.y + up), in: window)
    }
}

/// ⌘C, then what it left on the storylines' pasteboard.
struct CopySelection: Step {
    let expected: String
    init(_ expected: String) { self.expected = expected }
    var label: String { "⌘C copies “\(expected.count > 40 ? expected.prefix(40) + "…" : Substring(expected))”" }

    func run(_ story: StoryContext) async throws {
        StoryTranscript.clearCopied()
        try await Key(KeyChord(.character("c"), .command)).run(story)
        do {
            try await story.until("the copy") { StoryTranscript.copied == expected }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("⌘C to copy:\n\(expected)\n— it copied:\n\(StoryTranscript.copied ?? "nothing")")
        }
    }
}

/// Keeps a number for a later step to compare with.
struct Remember: Step {
    let name: String
    let value: @MainActor (StoryContext) throws -> Int
    init(_ name: String, _ value: @escaping @MainActor (StoryContext) throws -> Int) {
        self.name = name
        self.value = value
    }
    var label: String { "Note \(name)" }

    final class Values { var values: [String: Int] = [:] }

    func run(_ story: StoryContext) async throws { story.stash(Values.self) { Values() }.values[name] = try value(story) }

    @MainActor static func value(_ story: StoryContext, _ name: String) -> Int? { story.stash(Values.self) { Values() }.values[name] }
}

/// Scrolling the active chat with all of it selected, measured as `NavCost` measures it: a text
/// selected whole costs its row nothing, so the numbers should match an unselected scroll.
struct MeasureSelectedScroll: Step {
    var label: String { "Measure scrolling with the whole chat selected" }
    var timeout: Duration? { .seconds(120) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let t = try story.activeChat().storyTranscript
        t.selectAll()
        let before = t.selectionWork.laidOut
        var lines: [String] = []
        for round in 1...2 {
            let s = await DevNavProbe.scroll(workspace)
            lines.append(String(format: "scroll all-selected %d: %d px, frames %d, over 33 ms %d, frame p95 %.1f ms, worst %.1f ms", round, Int(s.px), s.frames, s.over33, s.p95, s.worst))
        }
        lines.append("texts laid out again while scrolling with everything selected: \(t.selectionWork.laidOut - before)")
        let text = lines.map { "\(story.name) \($0)" }.joined(separator: "\n") + "\n"
        let url = story.outputs.appendingPathComponent("nav.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// A drag from a place up past the transcript's top, held there a moment: the transcript
/// scrolls up under it and the selection grows into the rows that come into view.
struct DragPastTop: Step {
    let from: Spot
    var label: String { "Drag from \(from) up past the top and hold" }

    func run(_ story: StoryContext) async throws {
        let (window, a) = try await from.point(story)
        let t = try story.activeChat().storyTranscript
        let before = t.selectionAnchorY
        guard let content = window.contentView else { return }
        // Autoscroll is timer-driven; a fixed 400 ms assumes enough frames under load.
        // Keep the pointer held until both observable effects arrive, with a bounded deadline.
        await story.input.drag(from: a, to: CGPoint(x: a.x, y: content.bounds.height - 8), in: window, hold: .seconds(2), until: {
            guard let after = t.selectionAnchorY, let before else { return false }
            return abs(after - before) > 100 && t.hasSelection
                && !t.selectionMarkdown.hasPrefix("Answer \(SelectAllLongChat.turns)")
        })
        guard let after = t.selectionAnchorY, let before, abs(after - before) > 100 else {
            throw StoryFailure.expectation("the transcript to scroll under the drag (moved \((t.selectionAnchorY ?? 0) - (before ?? 0)) pt)")
        }
        guard t.hasSelection, !t.selectionMarkdown.hasPrefix("Answer \(SelectAllLongChat.turns)") else {
            throw StoryFailure.expectation("the selection to reach rows above (it copies “\(t.selectionMarkdown.prefix(40))…”)")
        }
    }
}

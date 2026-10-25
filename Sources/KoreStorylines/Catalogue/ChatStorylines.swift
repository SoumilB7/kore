import AppKit
import KoreCore
import KoreUI

/// A chat with the scripted CLI, told once by Claude and once by Codex: the folder opens, the
/// script is set, a chat starts. Its subclasses give the script and what happens next.
class ChatStoryline: Storyline {
    override class var isFamily: Bool { self == ChatStoryline.self }
    override class var variants: [Variant] { [.claude, .codex] }
    class var script: CLIScript { CLIScript(turns: [CLIScript.reply("OK")]) }

    override func steps() -> [any Step] { [UseScript(Self.script), OpenFolder(), StartChat()] }
}

/// A message goes out, the answer streams in and the turn ends.
final class SendAndStream: ChatStoryline {
    static let reply = "Hello there, from the script. This answer streams in eight characters at a time."
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Say hello"),
            TurnFinished(1),
            Expect.rows("the whole answer as the last row") { $0.last?.kind == "assistant" && $0.last?.text == Self.reply },
            Expect("the turn to be over") { try !$0.activeChat().isRunning },
        ]
    }
}

/// Stop while a command runs: the turn ends as interrupted and the command's row closes.
final class StopMidTurn: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "sleep 600", wait: .interrupt)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Run the long job"),
            WaitForEvent("the command to start") { if case .toolStarted = $0 { true } else { false } },
            Stop(),
            TurnFinished(1),
            Expect("the turn to end as interrupted") { story in
                story.chatEvents().contains { if case .turnFinished(_, .interrupted, _) = $0 { true } else { false } }
            },
            Expect.rows("the command's row stopped, none left open") { rows in
                rows.contains { $0.kind == "tool" && $0.stopped } && !rows.contains { $0.kind == "tool" && !$0.done }
            },
        ]
    }
}

/// Messages sent while a turn runs wait below the chat as queued. The CLI takes two into that
/// turn, one after the other: each becomes a plain message where it went in, with no "Queued"
/// left on screen. One it never takes there starts the next turn.
final class QueuedMessage: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, .stream(.answer, "Working on it.\n\n"), .takeQueued, .stream(.answer, "On it.\n\n"),
                .takeQueued, .stream(.answer, "Nearly there.\n\n"), .wait(.queued("wrap up")), .finishTurn(.completed),
            ],
            CLIScript.reply("Wrapped."),
        ])
    }

    /// The "Queued" captions on screen.
    @MainActor static func captions() -> [String] {
        let prefix = StoryID(.composer, "queued").raw + "["
        return StoryRegistry.ids.filter { $0.hasPrefix(prefix) }
    }

    override func steps() -> [any Step] {
        let taken = { (text: String) in
            Expect.rows("“\(text)” shown inside the turn") { $0.contains { $0.kind == "user" && $0.text == text && $0.inTurn } }
        }
        return super.steps() + [
            Send("Start the job"),
            WaitForEvent("the turn to start") { if case .turnStarted = $0 { true } else { false } },
            Queue("please complete it now"),
            Queue("its taking too long"),
            Expect("the CLI to take both into the turn") { story in
                story.chatEvents().filter { if case .queuedMessage(_, .inTurn) = $0 { true } else { false } }.count == 2
            },
            taken("please complete it now"),
            taken("its taking too long"),
            Expect("no “Queued” left on screen", found: { _ in Self.captions().joined(separator: ", ") }) { _ in
                Self.captions().isEmpty
            },
            Queue("wrap up"),
            TurnFinished(2),
            Expect.rows("“wrap up” the next turn's own message") {
                $0.contains { $0.kind == "user" && $0.text == "wrap up" && !$0.inTurn }
            },
            Expect("no “Queued” left once it went", found: { _ in Self.captions().joined(separator: ", ") }) { _ in
                Self.captions().isEmpty
            },
        ]
    }
}

/// ⌘Z in the composer undoes the typing in the field and in the chat's draft alike, and ⇧⌘Z
/// brings it back to both.
final class ComposerUndo: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        func both(_ what: String, _ text: String) -> Expect {
            Expect(what, found: { story in
                "field “\(SwitchTab.composerText(story) ?? "?")”, draft “\(story.app.chat?.draft ?? "?")”"
            }) { story in
                SwitchTab.composerText(story) == text && story.app.chat?.draft == text
            }
        }
        return super.steps() + [
            WaitForFocus(.id(StoryID.Composer.field)),
            TypeText("hello"),
            both("“hello” in the field and the draft", "hello"),
            Key(.cmd("z")),
            both("the typing undone in the field and the draft", ""),
            Key(.cmdShift("z")),
            both("and redone in both", "hello"),
        ]
    }
}

/// A long draft, two lines typed and sixty pasted: the box stops at its ten lines with the
/// caret's end in view, a wheel turn over it scrolls its text and not the transcript (nor a
/// transcript scroll the box), a click in the middle puts the caret there, typing goes in there,
/// and Return sends it all.
final class ComposerLongDraft: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    static let typed = "First typed line\nSecond typed line\n"
    static let pasted = (1...60).map { "Pasted line \($0) of a long draft, a sentence or so." }.joined(separator: "\n")

    /// The composer's text view, under the field's centre.
    @MainActor static func text(_ story: StoryContext) -> NSTextView? {
        var view = StoryElement(StoryID.Composer.field)?.view
        while let current = view {
            if let text = current as? NSTextView { return text }
            view = current.superview
        }
        return nil
    }

    /// The caret is in the visible part of the text.
    @MainActor static func caretInView(_ text: NSTextView) -> Bool {
        guard let window = text.window else { return false }
        let screen = text.firstRect(forCharacterRange: text.selectedRange(), actualRange: nil)
        let rect = text.convert(window.convertFromScreen(screen), from: nil)
        return text.visibleRect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.minX, y: rect.midY))
    }

    /// Where the box's text is scrolled to, the transcript's last row's top, and the caret, as
    /// noted between steps.
    private var textTop: CGFloat?
    private var rowTop: CGFloat?
    private var caret: Int?

    @MainActor private static func lastRowTop(_ story: StoryContext) throws -> CGFloat? {
        try SwitchTab.rowIDs(story.activeChat()).last.flatMap { SwitchTab.top(of: $0) }
    }

    override func steps() -> [any Step] {
        let field = Locator.id(StoryID.Composer.field)
        let whole = Self.typed + Self.pasted
        let inserted = "INSERTED "
        return super.steps() + [
            ReplayTurns([("Long one", PressesOutsideText.long(1)), ("Long two", PressesOutsideText.long(2))]),
            WaitForFocus(field),
            TypeText("First typed line"), Key(KeyChord(.returnKey, .shift)),
            TypeText("Second typed line"), Key(KeyChord(.returnKey, .shift)),
            PasteText(Self.pasted),
            Expect("the whole text in the draft") { try $0.activeChat().draft == whole },
            Expect("the box at its ten lines, scrolled to the caret at the end", found: { story in
                guard let text = Self.text(story), let scroll = text.enclosingScrollView else { return "no composer text" }
                return "box \(scroll.frame.height) pt, text \(text.frame.height) pt, caret \(text.selectedRange().location)"
            }) { story in
                guard let text = Self.text(story), let scroll = text.enclosingScrollView, let font = text.font,
                    let line = text.layoutManager?.defaultLineHeight(for: font)
                else { return false }
                return abs(scroll.frame.height - (line * 10).rounded(.up)) < 1 && text.frame.height > scroll.frame.height * 2
                    && text.selectedRange().location == (whole as NSString).length && Self.caretInView(text)
            },
            Expect("the box's and the transcript's places, noted") { [unowned self] story in
                textTop = Self.text(story)?.visibleRect.minY
                rowTop = try Self.lastRowTop(story)
                return textTop != nil && rowTop != nil
            },
            Wheel(field, by: -300),
            Expect("the box's text scrolled up, the transcript where it was", found: { [unowned self] story in
                "text at \(Self.text(story)?.visibleRect.minY ?? -1) (was \(textTop ?? -1)), row at \((try? Self.lastRowTop(story)) ?? nil ?? -1) (was \(rowTop ?? -1))"
            }) { [unowned self] story in
                guard let top = Self.text(story)?.visibleRect.minY, let before = textTop, let row = try Self.lastRowTop(story), let was = rowTop
                else { return false }
                return top < before - 100 && abs(row - was) < 0.5
            },
            Click(field),
            Expect("the caret in the middle of the text, in view") { [unowned self] story in
                guard let text = Self.text(story), story.window?.firstResponder === text else { return false }
                let at = text.selectedRange()
                caret = at.location
                return at.length == 0 && at.location > 100 && at.location < (whole as NSString).length - 100 && Self.caretInView(text)
            },
            TypeText(inserted),
            Expect("the typing there, the caret after it and in view") { [unowned self] story in
                guard let at = caret, let text = Self.text(story) else { return false }
                let expected = (whole as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: inserted)
                return try story.activeChat().draft == expected && text.string == expected
                    && text.selectedRange().location == at + (inserted as NSString).length && Self.caretInView(text)
            },
            // The transcript scrolled leaves the box's text where it is.
            Expect("the box's place, noted") { [unowned self] story in
                textTop = Self.text(story)?.visibleRect.minY
                return textTop != nil
            },
            Scroll(.answer(turn: 2), to: .by(-300)),
            Expect("the box's text where it was") { [unowned self] story in
                guard let top = Self.text(story)?.visibleRect.minY, let before = textTop else { return false }
                return abs(top - before) < 0.5
            },
            Key(.returnKey),
            Expect("all of it sent to the CLI") { [unowned self] story in
                guard let at = caret else { return false }
                let sent = (whole as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: inserted)
                return try story.scriptedBackend().log.contains(.send(sent))
            },
            Expect("the composer empty") { story in try story.activeChat().draft.isEmpty && Self.text(story)?.string == "" },
        ]
    }
}

/// Fork from the second message: a new tab with the history before it, the message back in its
/// composer, and the original left as it was.
final class ForkFromMessage: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .fork, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("First answer"), CLIScript.reply("Second answer")]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("one"), TurnFinished(1), Send("two"), TurnFinished(2),
            Fork.fromMessage(2),
            Expect("a “(fork)” tab") { try $0.activeChat().storyTitle.hasSuffix("(fork)") },
            Expect.rows("only what came before message 2") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["one"] && rows.contains { $0.text == "First answer" }
                    && !rows.contains { $0.text == "Second answer" }
            },
            Expect("message 2 back in the composer") { try $0.activeChat().draft == "two" },
            Expect("the original chat unchanged") { story in
                story.app.workspace?.tabs.first?.chat?.rows.filter { $0.kind == "user" }.map(\.text) == ["one", "two"]
            },
        ]
    }
}

/// Fork through the first answer: the new tab ends with that answer, and its composer is empty.
final class ForkFromAnswer: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .fork, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("First answer"), CLIScript.reply("Second answer")]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("one"), TurnFinished(1), Send("two"), TurnFinished(2),
            Fork.fromAnswer(1),
            Expect("a “(fork)” tab") { try $0.activeChat().storyTitle.hasSuffix("(fork)") },
            Expect.rows("the conversation through answer 1") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["one"] && rows.last { $0.kind == "assistant" }?.text == "First answer"
            },
            Expect("an empty composer") { try $0.activeChat().draft.isEmpty },
        ]
    }
}

/// A fork is in History as soon as it's made, before anything is sent in it (Claude makes its
/// session only with the first message; Codex as the fork opens). A message later, there's
/// still one entry for it, under its title, and Kore's own record of it has given way to the
/// CLI's.
final class ForkListedInHistory: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .fork, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("First answer"), CLIScript.reply("Second answer")]) }

    /// History's rows for the fork, and Kore's records of the folder's forks.
    @MainActor private static func listed(_ story: StoryContext) -> [(id: String, title: String)] {
        guard let chat = story.app.chat else { return [] }
        return story.app.workspace?.storyHistory.filter { $0.title == chat.storyTitle } ?? []
    }

    @MainActor private static func records(_ story: StoryContext) -> Int {
        ["claude", "codex"].reduce(0) { $0 + KoreForks.shared.forks(cli: $1, folder: story.folder).count }
    }

    @MainActor private static func shown(_ story: StoryContext) -> Bool {
        let rows = listed(story)
        return rows.count == 1 && StoryRegistry.ids.contains(StoryID.History.row(rows[0].id).raw)
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("one"), TurnFinished(1),
            Fork.fromAnswer(1),
            Expect("a “(fork)” tab") { try $0.activeChat().storyTitle.hasSuffix("(fork)") },
            Press(.id(StoryID.Titlebar.history)),
            Expect("one History row for the fork, nothing sent in it", found: { "\(Self.listed($0))" }) { story in
                try Self.shown(story) && !(story.scriptedBackend().log.contains { if case .send = $0 { true } else { false } })
            },
            Key(.escape),
            Send("two"), TurnFinished(1),
            Press(.id(StoryID.Titlebar.history)),
            Expect("still one row for the fork, now the CLI's own", found: { "\(Self.listed($0)), records \(Self.records($0))" }) { story in
                Self.shown(story) && Self.records(story) == 0 && Self.listed(story).first?.id == story.app.chat?.sessionId
            },
        ]
    }
}

/// An approval card: deny it, and the CLI doesn't run the command; allow the next, and it does.
final class ApproveAndDeny: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals, .gate] }
    override class var script: CLIScript {
        func ask(_ id: String) -> [Beat] {
            let approval = Approval(
                id: id, title: "Run rm -rf build?", detail: "Bash", body: "rm -rf build", canAlwaysAllow: true, questions: [])
            return [
                .startTurn,
                .approval(
                    approval, allow: [.tool(name: "Bash", detail: "rm -rf build", output: "removed")],
                    deny: Beat.answer("Okay, I won't run it.")),
                .finishTurn(.completed),
            ]
        }
        return CLIScript(turns: [ask("first"), ask("second")])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Clean the build"),
            Answer(.deny),
            TurnFinished(1),
            Expect.rows("the refusal, and no command run") { rows in
                rows.contains { $0.text == "Okay, I won't run it." } && !rows.contains { $0.kind == "tool" && $0.tool == "Bash" && $0.result == "removed" }
            },
            Send("Clean it now"),
            Answer(.allow),
            TurnFinished(2),
            Expect.rows("the command run") { $0.contains { $0.kind == "tool" && $0.tool == "Bash" && $0.done } },
        ]
    }
}

/// A question card: nothing goes until Submit, and Submit waits for every question; several
/// can be picked where the question allows it, and Other takes a typed answer. The answers go
/// back as they always have: each question's picks in their order, then what was typed.
final class QuestionCardSubmit: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals, .gate] }
    static let layout = "Which layout?"
    static let colours = "Which colours?"
    override class var script: CLIScript {
        let questions = [
            Approval.Question(id: layout, text: layout, options: [.init(label: "Grid", description: ""), .init(label: "List", description: "")]),
            Approval.Question(
                id: colours, text: colours, options: [.init(label: "Red", description: ""), .init(label: "Blue", description: "")], multiple: true),
        ]
        let approval = Approval(id: "q1", title: "", detail: nil, body: nil, canAlwaysAllow: false, questions: questions)
        return CLIScript(turns: [[.startTurn, .approval(approval, allow: Beat.answer("Got it."), deny: []), .finishTurn(.completed)]])
    }

    private static func option(_ question: String, _ label: String) -> Press { Press(.id(StoryID.Approval.option(question, label))) }
    private static let submit = Press(.id(StoryID.Approval.card("q1").part(.submit)))

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(StoryID.Approval.card("q1").part(.submit))),
            Self.option(Self.layout, "List"),
            Self.option(Self.layout, "Grid"),
            Self.submit,
            Expect("nothing sent with a question unanswered") { story in
                try !story.scriptedBackend().log.contains { if case .respond = $0 { true } else { false } }
                    && story.activeChat().pendingApprovals.contains { $0.id == "q1" }
            },
            // The second question is the second tab's.
            Press(.id(StoryID.Approval.tab("q1", 1))),
            Self.option(Self.colours, "Red"),
            Self.option(Self.colours, "Blue"),
            Press(.id(StoryID.Approval.other(Self.colours))),
            Click(.id(StoryID.Approval.other(Self.colours).part(.field))),
            TypeText("Green"),
            Self.submit,
            TurnFinished(1),
            Expect("the picks and the typed answer sent") { story in
                try story.scriptedBackend().answers["q1"] == [Self.layout: ["Grid"], Self.colours: ["Red", "Blue", "Green"]]
            },
        ]
    }
}

/// An answer's rows are built without text selection views: SwiftUI's view per selectable text
/// was two fifths of building rows, so text becomes selectable only once the pointer reaches it.
final class AnswerRowsWithoutSelection: ChatStoryline {
    static let reply = """
        Some **markdown**, as answers have it.

        - one item
        - and `another`

        ```swift
        let answer = 42
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Show me some markdown"),
            TurnFinished(1),
            Expect("the answer on screen") { story in
                if case .found(let answer) = Locator.answer(turn: 1).resolve(story.app) { return answer.frame != nil }
                return false
            },
            WaitIdle(),
            Expect("no text selection views before the pointer reaches the text") { selectionViews(in: $0.window) == 0 },
        ]
    }
}

/// With the real pointer: an answer's text under the pointer still builds no selection view of
/// its own (the transcript's one selection lays a text out only when a press reaches it).
final class SelectableOnHover: ChatStoryline {
    static let reply = """
        A paragraph long enough to fill several lines of the answer, so the middle of its row is \
        text rather than the gap between blocks. It goes on a little longer than that, and then \
        some more, until the pointer can't miss it. One more sentence for good measure, and another.
        """
    override class var tags: Set<Tag> { [.chat, .realInput] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Write a paragraph"),
            TurnFinished(1),
            WaitIdle(),
            Expect("no text selection views yet") { selectionViews(in: $0.window) == 0 },
            Hover(.answer(turn: 1)),
            Expect("no text selection views under the pointer either") { selectionViews(in: $0.window) == 0 },
        ]
    }
}

/// SwiftUI's text selection views (one per selectable `Text` it has built) in the window: a
/// selection overlay hosting a text field in a window, a text interaction view in a bare hosting view.
@MainActor private func selectionViews(in window: NSWindow?) -> Int {
    func count(_ view: NSView) -> Int {
        let name = String(describing: type(of: view))
        let own = name.contains("SelectionOverlay") || name.contains("TextInteraction") ? 1 : 0
        return view.subviews.reduce(own) { $0 + count($1) }
    }
    return window?.contentView.map(count) ?? 0
}

/// The `/` key opens the command menu with the caret after the "/". The menu floats over the
/// chat: the transcript stays where it was beside it, and a click outside closes it. A pick puts
/// the command in the chip before the text; "/" typed mid-text filters the menu and a pick
/// replaces the chip; Codex skills go in the text as "$name". Backspace at the start takes the
/// chip off, a send goes out as "/command text", and a fork brings the chip back.
final class SlashMenuCaret: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        let commands = [
            SlashCommand(name: "compact", description: "Summarize the conversation", hint: "", kind: .command),
            SlashCommand(name: "review", description: "Review a pull request", hint: "", kind: .command),
            SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
            SlashCommand(name: "pdf", description: "Read and fill PDF files", hint: "", kind: .skill),
        ]
        return CLIScript(
            start: [
                .event(.controlsLoaded(ChatControls(
                    models: [ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: ["low"])],
                    model: "haiku", effort: "low", commands: commands)))
            ],
            turns: [CLIScript.reply("OK")])
    }

    /// The draft, and where the caret sits in the focused text (in UTF-16 units).
    @MainActor static func caret(_ story: StoryContext) -> (draft: String, at: Int)? {
        guard let editor = story.window?.firstResponder as? NSTextView else { return nil }
        return (editor.string, editor.selectedRange().location)
    }

    /// The chip's command, the field's text and the caret: `at` nil for the end of the text.
    static func expectComposer(_ what: String, chip: String?, _ draft: String, at: Int? = nil) -> Expect {
        Expect(what, found: { story in
            let chip = story.app.chat?.command.map { "/\($0.name)" } ?? "no chip"
            return chip + ", " + (caret(story).map { "“\($0.draft)” with the caret at \($0.at)" } ?? "no text in focus")
        }) { story in
            guard let now = caret(story), let chat = story.app.chat else { return false }
            return chat.command?.name == chip && now.draft == draft && chat.draft == draft
                && now.at == (at ?? (draft as NSString).length)
        }
    }

    /// Where the last answer's top is, before the menu opens.
    private var answerTop: CGFloat?

    @MainActor private static func lastRowTop(_ story: StoryContext) throws -> CGFloat? {
        try SwitchTab.rowIDs(story.activeChat()).last.flatMap { SwitchTab.top(of: $0) }
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let tab = Locator("the chat's tab") { app in
            app.workspace.map { .success(StoryID.Tabs.tab($0.activeTab.id)) } ?? .failure(LocatorMiss("no workspace"))
        }
        let row = { (name: String) in Locator.id(StoryID.Composer.command(name)) }
        let text = codex ? "fix the bug $pdf " : "fix the bug "
        let sent = "/review café → “ok” 🙂" + text.trimmingCharacters(in: .whitespaces)
        var steps: [any Step] = super.steps() + [
            Send("Hello"),
            TurnFinished(1),
            Expect("the answer in view") { [unowned self] story in
                answerTop = try Self.lastRowTop(story)
                return answerTop != nil
            },
            WaitForFocus(.id(StoryID.Composer.field)),
            // The key: "/" with the caret after it, the menu over the chat.
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(row("compact")),
            Snapshot("slash-menu"),
            Self.expectComposer("“/” with the caret after it", chip: nil, "/"),
            Expect("the answer where it was, the transcript not cut short by the menu") { [unowned self] story in
                guard let top = try Self.lastRowTop(story), let before = answerTop else { return false }
                return abs(top - before) < 0.5
            },
            Click(tab),
            ExpectElement(row("compact"), .absent),
            // The key again in that "/": the menu back, nothing added.
            Press(.id(StoryID.Composer.slash)),
            Press(row("review")),
            Self.expectComposer("/review in the chip, the field empty", chip: "review", ""),
            ExpectElement(row("compact"), .absent),
            // "/" mid-text filters at the caret; a pick replaces the chip and leaves the text.
            TypeText("fix the bug /com"),
            WaitForElement(row("compact")),
            ExpectElement(row("review"), .absent),
            Key(.returnKey),
            Self.expectComposer("/compact in the chip, “/com” gone", chip: "compact", "fix the bug "),
        ]
        if codex {
            steps += [
                TypeText("$pd"),
                Key(.returnKey),
                Self.expectComposer("the skill in the text", chip: "compact", text),
            ]
        }
        steps += [
            // Backspace at the start takes the chip off, the text stays.
            Key(KeyChord(.left, .command)),
            Key(KeyChord(.backspace)),
            Self.expectComposer("no chip, the text as it was", chip: nil, text, at: 0),
            // The key at the start: the full list, /review back in the chip, the caret before the text.
            Press(.id(StoryID.Composer.slash)),
            Press(row("review")),
            Self.expectComposer("/review in the chip again", chip: "review", text, at: 0),
            // Text whose UTF-8 and UTF-16 lengths differ, typed after the chip's text: each
            // keystroke redraws the composer between the field's text and the draft catching up.
            TypeText("café → “ok” 🙂"),
            Self.expectComposer("the typed text after it", chip: "review", "café → “ok” 🙂" + text, at: 14),
            Press(.id(StoryID.Composer.send)),
            TurnFinished(2),
            Expect("“\(sent)” sent to the CLI") { try $0.scriptedBackend().log.contains(.send(sent)) },
            Expect("the composer empty") { try $0.activeChat().command == nil && $0.activeChat().draft.isEmpty },
            // A typed-in-chip /compact still compacts.
            Press(.id(StoryID.Composer.slash)),
            Press(row("compact")),
            Press(.id(StoryID.Composer.send)),
            Expect("the CLI asked to compact") { try $0.scriptedBackend().log.contains(.compact) },
            Expect("the compaction over") { try !$0.activeChat().isCompacting },
        ]
        if codex {
            steps += [
                Press(.id(StoryID.Composer.slash)),
                Press(row("plan")),
                Press(.id(StoryID.Composer.send)),
                Expect("/plan turning plan mode on") { try $0.scriptedBackend().log.contains(.setPlanMode(true)) },
            ]
        }
        steps += [
            // A fork from the command's message brings it back in the chip.
            Fork.fromMessage(2),
            Expect("the fork's chip and text", found: { story in
                "chip \(story.app.chat?.command?.name ?? "none"), draft “\(story.app.chat?.draft ?? "?")”"
            }) { story in
                story.app.chat?.storyTitle.hasSuffix("(fork)") == true && story.app.chat?.command?.name == "review"
                    && story.app.chat?.draft == "café → “ok” 🙂" + text.trimmingCharacters(in: .whitespaces)
            },
        ]
        return steps
    }
}

/// The / key again with its menu showing closes the menu, and the "/word" goes: one the key put
/// in goes with the space it put before it, the text it took the place of back and selected;
/// one typed goes with a space after it, and nothing past the caret. ⌘Z puts it back.
final class SlashKeyCloses: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { SlashMenuCaret.script }

    override func steps() -> [any Step] {
        let row = Locator.id(StoryID.Composer.command("review"))
        let slash = Locator.id(StoryID.Composer.slash)
        return super.steps() + [
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(slash),
            WaitForElement(row),
            Press(slash),
            ExpectElement(row, .absent),
            SlashMenuCaret.expectComposer("the menu closed, the “/” gone", chip: nil, ""),
            Key(.cmd("z")),
            Expect("⌘Z: the “/” back") { try $0.activeChat().draft == "/" },
            Key(.cmd("a")),
            Key(KeyChord(.backspace)),
            SlashMenuCaret.expectComposer("cleared", chip: nil, ""),
            TypeText("fix the bug"),
            Press(slash),
            WaitForElement(row),
            SlashMenuCaret.expectComposer("“ /” after the word", chip: nil, "fix the bug /"),
            TypeText("re"),
            Press(slash),
            ExpectElement(row, .absent),
            SlashMenuCaret.expectComposer("“ /re” gone with the key's space", chip: nil, "fix the bug"),
            TypeText(" /rev"),
            WaitForElement(row),
            Press(slash),
            ExpectElement(row, .absent),
            SlashMenuCaret.expectComposer("the typed “/rev” gone, the space before it kept", chip: nil, "fix the bug "),
            Key(KeyChord(.left, .command)),
            TypeText("/re"),
            WaitForElement(row),
            Press(slash),
            ExpectElement(row, .absent),
            SlashMenuCaret.expectComposer("“/re” gone, the text after the caret kept", chip: nil, "fix the bug ", at: 0),
            Key(.cmd("a")),
            Press(slash),
            WaitForElement(row),
            SlashMenuCaret.expectComposer("the selection replaced by “/”", chip: nil, "/"),
            Press(slash),
            ExpectElement(row, .absent),
            Expect("the text back, selected", found: { story in
                (SlashMenuCaret.caret(story).map { "“\($0.draft)”" } ?? "no text in focus")
                    + ((story.window?.firstResponder as? NSTextView).map { " selected \($0.selectedRange())" } ?? "")
            }) { story in
                guard let editor = story.window?.firstResponder as? NSTextView else { return false }
                let draft = try story.activeChat().draft
                return editor.string == "fix the bug " && editor.selectedRange() == NSRange(location: 0, length: 12) && draft == "fix the bug "
            },
        ]
    }
}

/// Live (`--live haiku`, `--live gpt-6-luna`): a command picked into the chip is sent and runs.
/// Claude runs the folder's own /ping with the typed text as its arguments; Codex takes /goal as
/// a goal, not as a prompt.
final class SlashChipLive: Storyline {
    override class var tags: Set<Tag> { [.live] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let command = codex ? "goal" : "ping"
        let steps: [any Step] = [
            WriteFiles([(".claude/commands/ping.md", "---\ndescription: Probe ping\n---\nReply with the single word PING-$ARGUMENTS.\n")]),
            OpenFolder(),
            StartChat(),
            Expect("/\(command) offered", timeout: .seconds(60)) { story in
                story.app.chat?.storyCommands.contains(command) == true
            },
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            Press(.id(StoryID.Composer.command(command))),
            TypeText(codex ? "Reply with the single word DONE" : "chip"),
            Press(.id(StoryID.Composer.send)),
        ]
        if codex {
            return steps + [
                WaitForEvent("Codex to set the goal") { if case .notice("Goal set", _) = $0 { true } else { false } }
            ]
        }
        return steps + [
            WaitForEvent("the turn to end", timeout: .seconds(90)) { if case .turnFinished = $0 { true } else { false } },
            Expect.rows("/ping's answer") { $0.contains { $0.kind == "assistant" && $0.text.contains("PING-chip") } },
        ]
    }
}

/// A code block's Copy shows on hover just below the block at its right edge, in the row kept
/// for it, covering none of the code: on a short command and on one longer than the column.
final class CodeBlockCopyBelow: ChatStoryline {
    static let reply = """
        Run this:

        ```sh
        swift build
        ```

        Then this one:

        ```sh
        scripts/storylines.sh --cli scripted --provider claude --name CodeBlockCopyBelow --out ~/Library/Application\\ Support/KoreDev/scratch/code-copy
        ```

        Then open the app.
        """
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("How do I build it?"), TurnFinished(1), WaitIdle(),
            HoverCode(0), Expect("Copy under the short block, at its right edge") { _ in Self.copyBelow(0) }, Snapshot("code-copy-short"),
            HoverCode(1), Expect("Copy under the long block, at its right edge") { _ in Self.copyBelow(1) }, Snapshot("code-copy-long"),
        ]
    }

    /// The code blocks on screen, in the answer's order.
    @MainActor static func blocks() -> [String] {
        StoryRegistry.ids.filter { $0.hasPrefix("transcript.code[") && $0.hasSuffix("]") }
            .sorted { path($0).lexicographicallyPrecedes(path($1)) }
    }

    /// "transcript.code[0.3]" back to its path in the answer's markdown.
    static func path(_ id: String) -> [Int] {
        id.dropFirst("transcript.code[".count).dropLast().split(separator: ".").compactMap { Int($0) }
    }

    /// The nth block's Copy lies in its bottom row, below the well, and ends at its right edge.
    @MainActor static func copyBelow(_ n: Int) -> Bool {
        let ids = blocks()
        guard ids.indices.contains(n), let block = StoryRegistry.entry(ids[n])?.frame,
            let copy = StoryRegistry.entry(ids[n] + ".copy")?.frame
        else { return false }
        // Frames are the window's, y up: the block's bottom is its minY.
        return abs(copy.minY - block.minY) < 0.5 && copy.height <= 22.5 && abs(copy.maxX - block.maxX) < 1
    }
}

/// The nth code block on screen as under the pointer (its hover stand-in).
struct HoverCode: Step {
    let n: Int
    var label: String { "Hover code block \(n + 1)" }
    init(_ n: Int) { self.n = n }
    func run(_ story: StoryContext) async throws {
        // The answer's markdown is laid out after the turn ends: wait for the block.
        try await story.until("code block \(n + 1) on screen") { CodeBlockCopyBelow.blocks().count > n }
        let ids = await CodeBlockCopyBelow.blocks()
        try await Press(.id(StoryID.Transcript.code(CodeBlockCopyBelow.path(ids[n])).part(.hover))).run(story)
    }
}

/// ⌘R reloads only the active tab: a chat in another tab stays as it is.
final class ReloadTab: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("First answer")]) }

    override func steps() -> [any Step] {
        final class Seen { var chat: AnyObject?; var session: String? }
        let seen = Seen()
        return super.steps() + [
            Send("one"), TurnFinished(1),
            Expect("the chat as it is") { story in
                let chat = try story.activeChat()
                (seen.chat, seen.session) = (chat, chat.sessionId)
                return true
            },
            Command(.newTab),
            Command(.reloadTab),
            Key(.cmd("1")),
            Expect("another tab's reload leaves it alone") { try $0.activeChat() === seen.chat },
            Command(.reloadTab),
            Expect("its own reload opens it again, anew") { story in
                let chat = try story.activeChat()
                return chat !== seen.chat && chat.sessionId == seen.session
            },
        ]
    }
}

/// ⇧⌘R reloads the window: an idle chat opens again from its saved history in the same tab, on a
/// new CLI; a working one waits for its turn to end, unless ⌘R comes again.
final class ReloadWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("First answer"), [.startTurn, .wait(.release)] + Beat.answer("Second answer") + [.finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        final class Seen { var chat: AnyObject?; var session: String? }
        let seen = Seen()
        let remember = Expect("the chat as it is") { story in
            let chat = try story.activeChat()
            (seen.chat, seen.session) = (chat, chat.sessionId)
            return true
        }
        return super.steps() + [
            Send("one"), TurnFinished(1), remember,
            Command(.reload),
            Expect("the tab opens the same chat again, anew") { story in
                let chat = try story.activeChat()
                return chat !== seen.chat && chat.sessionId == seen.session
            },
            Expect.rows("its history read back") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["one"] && rows.contains { $0.text == "First answer" }
            },
            remember,
            Send("two"),
            Expect("a turn running") { try $0.activeChat().isRunning },
            Command(.reload),
            Expect("a working chat waits") { try $0.activeChat() === seen.chat },
            Command(.reload),
            Expect("asked again, it reloads at once") { try $0.activeChat() !== seen.chat },
        ]
    }
}

/// A turn that goes quiet while it waits on the model (a connection that died unnoticed): after
/// the watchdog's wait its spinner holds still with "No response" and Retry / Stop, its tab
/// shows ⚠, and Retry starts its CLI again on the same chat and asks it to carry on.
final class StalledTurn: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .wait(.release)], CLIScript.reply("Carried on")])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Wait 1 s for a stall") { _ in Chat.stallAfter.value = 1 },
            Send("Start the job"),
            WaitForEvent("the turn to start") { if case .turnStarted = $0 { true } else { false } },
            Expect("the turn seen as stalled", timeout: .seconds(8)) { try $0.activeChat().connection == .stalled },
            // Its spinner's Retry (pressing it finds it on screen).
            Press(.id(StoryID.Transcript.stalledRetry)),
            Expect("its CLI started again") { try $0.scriptedBackend().log.contains(.relaunch) },
            Expect("and was asked to carry on") { try $0.scriptedBackend().log.contains(.send("Continue")) },
            TurnFinished(2),
            Expect.rows("the answer after it") { $0.contains { $0.text == "Carried on" } },
            Expect("the connection fine again") { try $0.activeChat().connection == .ok },
        ]
    }
}

/// Messages queued behind a turn whose CLI Kore starts again (a stalled turn's Retry, a Stop
/// it never answered): the old process takes them with it unsent, so they go back to the
/// composer in order, and no "Queued" is left for something nobody will send.
class QueuedThroughRelaunch: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    class var viaStop: Bool { false }
    override class var script: CLIScript {
        var script = CLIScript(turns: [[.startTurn, .wait(.release)], CLIScript.reply("Carried on")])
        script.deaf = viaStop
        return script
    }

    override func steps() -> [any Step] {
        let relaunch: [any Step] = Self.viaStop ? [
            Stop(),
            Expect("after 5 s, its CLI ended by Kore", timeout: .seconds(9)) { try $0.scriptedBackend().log.contains(.relaunch) },
        ] : [
            Expect("the turn seen as stalled", timeout: .seconds(8)) { try $0.activeChat().connection == .stalled },
            Press(.id(StoryID.Transcript.stalledRetry)),
            Expect("its CLI started again") { try $0.scriptedBackend().log.contains(.relaunch) },
        ]
        let stall: [any Step] = Self.viaStop ? [] : [Do("Wait 1 s for a stall") { _ in Chat.stallAfter.value = 1 }]
        return super.steps() + stall + [
            Send("Start the job"),
            WaitForEvent("the turn to start") { if case .turnStarted = $0 { true } else { false } },
            Queue("first queued"),
            Queue("second queued"),
        ] + relaunch + [
            Expect("no “Queued” left", found: { _ in QueuedMessage.captions().joined(separator: ", ") }) { _ in
                QueuedMessage.captions().isEmpty
            },
            Expect("the queued text back in the composer", found: { $0.app.chat?.draft }) {
                $0.app.chat?.draft == "first queued\nsecond queued"
            },
        ] + (Self.viaStop ? [] : [
            TurnFinished(2),
            Expect.rows("only Continue sent, not the queued text") { rows in
                rows.contains { $0.text == "Carried on" } && !rows.contains { $0.kind == "user" && $0.text.contains("queued") }
            },
        ])
    }
}

/// The same through a Stop the CLI never answers.
final class QueuedThroughUnansweredStop: QueuedThroughRelaunch {
    override class var viaStop: Bool { true }
}

/// A Stop the CLI never answers: after 5 s Kore ends the CLI itself, the turn ends as
/// stopped, and the chat can send again.
final class UnansweredStop: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        var script = CLIScript(turns: [[.startTurn, .wait(.release)], CLIScript.reply("Back")])
        script.deaf = true
        return script
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Start the job"),
            WaitForEvent("the turn to start") { if case .turnStarted = $0 { true } else { false } },
            Stop(),
            Expect("the turn still running at first") { try $0.activeChat().isRunning },
            Expect("after 5 s, ended by Kore", timeout: .seconds(9)) { story in
                try !story.activeChat().isRunning && story.scriptedBackend().log.contains(.relaunch)
            },
            Send("again"),
            TurnFinished(2),
            Expect.rows("the next turn answered") { $0.contains { $0.text == "Back" } },
        ]
    }
}

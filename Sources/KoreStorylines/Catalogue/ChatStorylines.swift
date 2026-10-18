import AppKit
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

/// A message sent while a turn runs waits as queued, then the CLI takes it into that turn.
final class QueuedMessage: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, .stream(.answer, "Working on it."), .takeQueued, .stream(.answer, "And that too."),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Start the job"),
            WaitForEvent("the turn to start") { if case .turnStarted = $0 { true } else { false } },
            Queue("and also this"),
            WaitForEvent("the CLI to take it into the turn") {
                if case .queuedMessage(_, .inTurn) = $0 { true } else { false }
            },
            TurnFinished(1),
            Expect.rows("it shown inside the turn") { $0.contains { $0.kind == "user" && $0.text == "and also this" && $0.inTurn } },
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

    /// The draft, and where the caret sits in the field (in characters).
    @MainActor static func caret(_ story: StoryContext) -> (draft: String, at: Int)? {
        guard let editor = story.window?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return (editor.string, editor.selectedRange().location)
    }

    /// The chip's command, the field's text and the caret: `at` nil for the end of the text.
    static func expectComposer(_ what: String, chip: String?, _ draft: String, at: Int? = nil) -> Expect {
        Expect(what, found: { story in
            let chip = story.app.chat?.command.map { "/\($0.name)" } ?? "no chip"
            return chip + ", " + (caret(story).map { "“\($0.draft)” with the caret at \($0.at)" } ?? "no field editor")
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
        let sent = "/review " + text.trimmingCharacters(in: .whitespaces)
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
                    && story.app.chat?.draft == text.trimmingCharacters(in: .whitespaces)
            },
        ]
        return steps
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

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

/// With the real pointer: the answer's text becomes selectable when the pointer is over it.
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
            Expect("the answer's text selectable under the pointer") { selectionViews(in: $0.window) > 0 },
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

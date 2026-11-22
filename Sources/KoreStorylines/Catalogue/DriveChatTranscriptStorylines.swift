import AppKit
import Foundation
import KoreCore
import KoreUI
import src

// Every chat control driven once, its effect checked (`--tag drive`): the transcript's rows,
// the live rows under a turn, the changes view, the message rail and a message's actions.

@MainActor enum DriveTranscript {
    /// A control on the row of the active chat's first turn.
    static func turn(_ what: String, _ id: @escaping @MainActor (String) -> StoryID) -> Locator {
        Locator(what) { app in
            guard let turn = app.chat?.storyTranscript.turns.first else { return .failure(LocatorMiss("no turn yet", pending: true)) }
            return .success(id(turn))
        }
    }

    /// The thinking row of the active chat.
    static let thinking = Locator("the thinking row") { app in
        guard let entry = app.chat?.storyTranscript.entries.first(where: { $0.kind == .thinking }) else {
            return .failure(LocatorMiss("no thinking yet", pending: true))
        }
        return .success(StoryID.Transcript.thinking(entry.id))
    }

    /// A row of the changes view, by the file's name: its folder as the view writes it.
    static func changedFile(_ name: String) -> Locator {
        Locator("the changes view's \(name)") { _ in
            let prefix = "changes.file["
            guard let raw = StoryRegistry.ids.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(name + "]") }) else {
                return .failure(LocatorMiss("no row for \(name) yet", pending: true))
            }
            return .success(StoryID.Changes.file(String(raw.dropFirst(prefix.count).dropLast())))
        }
    }

    /// Whether a row's line (as `rowLines` reads it) is open.
    static func open(_ story: StoryContext, _ kind: String) -> Bool? {
        guard let line = story.app.chat?.storyTranscript.rowLines.first(where: { $0.hasPrefix(kind + "|") }) else { return nil }
        return line.hasSuffix("|true")
    }

    /// A resumed history of `count` short turns.
    static func history(_ count: Int) -> Do {
        Do("a history of \(count) turns") { story in
            try story.activeChat().storyTranscript.replay((1...count).map { (message: "Message \($0)", answer: "Answer \($0).") })
        }
    }
}

// MARK: - Live rows

/// A stalled turn's Stop: the CLI is told, and the turn ends stopped.
final class DriveStalledStop: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [[.startTurn, .wait(.interrupt), .finishTurn(.interrupted)]]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Wait 1 s for a stall") { _ in Chat.stallAfter.value = 1 },
            Send("Start the job"),
            WaitForEvent("the turn to start") { if case .turnStarted = $0 { true } else { false } },
            Expect("the turn seen as stalled", timeout: .seconds(8)) { try $0.activeChat().connection == .stalled },
            Press(.id(StoryID.Transcript.stalledStop)),
            DriveChat.asked("the stop sent to the CLI", .interrupt),
            TurnFinished(1),
            Expect("the turn ended stopped") { story in
                story.chatEvents().contains { if case .turnFinished(_, .interrupted, _) = $0 { true } else { false } }
            },
        ]
    }
}

/// Three reads in a row, as one "Explored 3": a click opens it to the reads, another closes it.
final class DriveExploredToggle: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript {
        let reads: [Beat] = DriveChat.read("r1", "a.md") + DriveChat.read("r2", "b.md") + DriveChat.read("r3", "c.md")
        let start: [Beat] = [.startTurn]
        let end: [Beat] = [.wait(.release), .stream(.answer, "Read them."), .finishTurn(.completed)]
        return CLIScript(turns: [start + reads + end])
    }

    override func steps() -> [any Step] {
        let row = Locator.id(StoryID.Transcript.explored("r1"))
        let read = StoryID.Transcript.tool("r2")
        return super.steps() + [
            Send("Read the notes"),
            WaitForEvent("the third read") { if case .toolFinished(let id, _, _, _) = $0 { id == "r3" } else { false } },
            WaitForElement(row),
            Expect("closed: the reads folded into it") { story in DriveTranscript.open(story, "explored") == false },
            // Clicked, not pressed: the row's press is its toggle; the click lands on its button.
            Click(row),
            Expect("open: the reads under it") { story in DriveTranscript.open(story, "explored") == true },
            WaitForElement(.id(read)),
            Click(row),
            Expect("closed again") { story in DriveTranscript.open(story, "explored") == false },
            ExpectElement(.id(read), .absent),
            Release(), TurnFinished(1),
        ]
    }
}

/// A long resumed history opens on its last turns: "Load earlier turns" brings more in.
final class DriveLoadEarlier: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [
            DriveTranscript.history(60), WaitIdle(),
            Expect("the earliest turns held back") { story in
                guard let first = story.app.chat?.storyTranscript.entries.first(where: { $0.kind == .user }) else { return false }
                return story.app.chat?.storyTranscript.isBuilt(first.id) == false
            },
            // Within a screen of the top the turns load as the row's press loads them, so the row
            // is gone before a press: its effect is checked, the press itself isn't driven.
            Scroll(.answer(turn: 60), to: .top),
            Expect("the earliest turns shown") { story in
                guard let first = story.app.chat?.storyTranscript.entries.first(where: { $0.kind == .user }) else { return false }
                return story.app.chat?.storyTranscript.isBuilt(first.id) == true
            },
        ]
    }
}

/// A fork's "Forked from …" line goes to the original chat while it's open.
final class DriveForkOriginal: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("First answer."), CLIScript.reply("Second answer.")]) }

    override func steps() -> [any Step] {
        let original = DriveChatNote<Chat?>(nil)
        return super.steps() + [
            Send("First"), TurnFinished(1),
            Send("Second"), TurnFinished(2),
            Do("note the original chat") { original.value = try $0.activeChat() },
            Fork.fromAnswer(1),
            Expect("the fork in front") { story in try story.activeChat() !== original.value },
            WaitForElement(.id(StoryID.Transcript.forkOriginal)),
            Press(.id(StoryID.Transcript.forkOriginal)),
            Expect("the original chat in front") { story in try story.activeChat() === original.value },
        ]
    }
}

// MARK: - Timeline rows

/// A turn that failed while the Mac slept: Continue asks the chat to carry on.
final class DriveSleptContinue: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .finishTurn(.slept("The connection was lost."))], CLIScript.reply("Carried on.")])
    }

    override func steps() -> [any Step] {
        let resume = driveWindowNamed("the slept turn's Continue", "transcript.slept", suffix: ".continue") { StoryID.Transcript.slept($0).part(.continue) }
        return super.steps() + [
            Send("Do the job"), TurnFinished(1),
            WaitForElement(resume),
            Press(resume),
            DriveChat.asked("asked to carry on", .send("Continue")),
            TurnFinished(2),
            Expect.rows("the answer after it") { $0.contains { $0.text == "Carried on." } },
        ]
    }
}

/// "Thought for …": a click opens the thinking, another closes it.
final class DriveThinkingToggle: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, .stream(.thinking, "Weighing the two layouts."), .wait(.release), .stream(.answer, "Tabs."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let was = DriveChatNote(false)
        return super.steps() + [
            Send("Pick a layout"),
            WaitForElement(DriveTranscript.thinking),
            WaitIdle(),
            Do("note whether it's open") { story in
                guard let open = DriveTranscript.open(story, "thinking") else { throw StoryFailure.modelMissing("the thinking row") }
                was.value = open
            },
            Press(DriveTranscript.thinking),
            Expect("a click turned it over") { DriveTranscript.open($0, "thinking") == !was.value },
            Press(DriveTranscript.thinking),
            Expect("another turned it back") { DriveTranscript.open($0, "thinking") == was.value },
            Release(), TurnFinished(1),
        ]
    }
}

/// An answer's Copy, from its accessibility actions: the answer on the pasteboard.
final class DriveAnswerCopyAction: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let reply = "The build number is 7781."
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("What's the build number?"), TurnFinished(1), WaitIdle(),
            Do("clear the pasteboard") { _ in StoryTranscript.clearCopied() },
            DriveChatAccessibilityAction(target: .answer(turn: 1), name: "Copy"),
            Expect("the answer copied", found: { _ in StoryTranscript.copied }) { _ in StoryTranscript.copied == Self.reply },
        ]
    }
}

/// An answer's Fork, from its accessibility actions: a fork through that turn, in a new tab.
final class DriveAnswerForkAction: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("First answer."), CLIScript.reply("Second answer.")]) }

    override func steps() -> [any Step] {
        let original = DriveChatNote<Chat?>(nil)
        let tabs = DriveChatNote(0)
        return super.steps() + [
            Send("First"), TurnFinished(1),
            Send("Second"), TurnFinished(2), WaitIdle(),
            Do("note the chat and its tabs") { story in
                original.value = try story.activeChat()
                tabs.value = story.app.workspace?.tabs.count ?? 0
            },
            DriveChatAccessibilityAction(target: .answer(turn: 1), name: "Fork"),
            Expect("a fork in a new tab, in front", found: { story in "\(story.app.workspace?.tabs.count ?? 0) tabs" }) { story in
                (story.app.workspace?.tabs.count ?? 0) == tabs.value + 1 && story.app.chat != nil && story.app.chat !== original.value
            },
            Expect("the chat in front titled as a fork", found: { $0.app.chat?.storyTitle }) { $0.app.chat?.storyTitle.isForkTitle == true },
        ]
    }
}

// MARK: - Changes view

/// A turn that changed two files, and its changes view open on them.
class DriveChangesView: ChatStoryline {
    override class var isFamily: Bool { self == DriveChangesView.self }
    override class var tags: Set<Tag> { [.drive] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, .fileEdit(path: "a.txt", content: "one\n"), .fileEdit(path: "b.txt", content: "two\n"),
            .stream(.answer, "Both written."), .finishTurn(.completed),
        ]])
    }

    var opening: [any Step] {
        let open = DriveTranscript.turn("the turn's View changes") { StoryID.Transcript.changes($0).part(.open) }
        return super.steps() + [
            Send("Write both files"), TurnFinished(1), WaitIdle(),
            WaitForElement(open),
            Press(open),
            WaitForElement(.id(StoryID.Changes.done)),
        ]
    }
}

/// A file in the list: a click picks it.
final class DriveChangesSelect: DriveChangesView {
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let a = DriveTranscript.changedFile("a.txt"), b = DriveTranscript.changedFile("b.txt")
        return opening + [
            WaitForElement(a.action(.selected)),
            ExpectElement(b.action(.selected), .absent),
            Press(b),
            WaitForElement(b.action(.selected)),
            ExpectElement(a.action(.selected), .absent),
        ]
    }
}

/// Done closes the view, and the composer has the keys again.
final class DriveChangesDone: DriveChangesView {
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        opening + [
            Press(.id(StoryID.Changes.done)),
            ExpectElement(.id(StoryID.Changes.done), .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
    }
}

// MARK: - Message rail

/// A click on another message's tick brings that message up: its tick is the lit one.
final class DriveRailClick: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    private struct ClickTick: Step {
        var label: String { "Click another message's tick on the rail" }
        var timeout: Duration? { .seconds(10) }

        func run(_ story: StoryContext) async throws {
            guard let transcript = story.app.chat?.storyTranscript,
                let tick = transcript.railTicks.first(where: { $0.index != transcript.railCurrent })
            else { throw StoryFailure.modelMissing("a tick on the rail besides the lit one") }
            let element = try await story.element(.id(StoryID.Transcript.rail))
            guard let frame = element.frame else { throw StoryFailure.other("the rail has no frame") }
            // Ticks are placed down from the rail's top; the window's y runs up.
            try await story.input.pointerClick(element, offset: CGVector(dx: 0, dy: frame.height / 2 - tick.y))
            do {
                try await story.until("message \(tick.index + 1) read", timeout: .seconds(8)) { transcript.railCurrent == tick.index }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation(
                    "message \(tick.index + 1) brought up by its tick (the lit one is \(transcript.railCurrent.map { "\($0 + 1)" } ?? "none"))")
            }
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            DriveTranscript.history(20), WaitIdle(),
            WaitForElement(.id(StoryID.Transcript.rail)),
            Expect("a mark per message") { ($0.app.chat?.storyTranscript.railMarks.count ?? 0) == 20 },
            ClickTick(),
        ]
    }
}

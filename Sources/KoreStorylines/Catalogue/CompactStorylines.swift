import Foundation
import KoreCore
import KoreUI

/// A compaction the user didn't ask for doesn't leave work stopped: Kore's own at its point,
/// right after a turn that ran to its end, is followed by "Continue"; so is the CLI's own when
/// its turn then ends with nothing after it. The wheel in a stopped chat sends nothing.
final class AutoCompactContinues: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [
            [.startTurn] + Beat.answer("Working on it") + [.context(used: 180_000), .finishTurn(.completed)],
            CLIScript.reply("Went on"),
            [.startTurn] + Beat.answer("Halfway") + [.event(.compacted(at: Date(), auto: true)), .finishTurn(.completed)],
            CLIScript.reply("Went on again"),
        ])
    }

    static func sends(_ story: StoryContext, _ text: String) throws -> Int {
        try story.scriptedBackend().log.filter { $0 == .send(text) }.count
    }

    override func steps() -> [any Step] {
        super.steps() + [
            SetAutoCompactPoint(70),
            Send("Do the work"), TurnFinished(1),
            Expect("Kore compacted at its point, then sent Continue", timeout: .seconds(5)) { story in
                try story.scriptedBackend().log.contains(.compact) && Self.sends(story, "Continue") == 1
            },
            TurnFinished(2),
            SetAutoCompactPoint(nil),
            // The wheel in a stopped chat: nothing sent after it.
            Compact(),
            Expect("no Continue after the wheel") { try Self.sends($0, "Continue") == 1 },
            // The CLI's own compaction ending its turn: Continue.
            Send("Next part"), TurnFinished(3),
            Expect("Continue after the CLI's compaction ended the turn", timeout: .seconds(5)) { try Self.sends($0, "Continue") == 2 },
            TurnFinished(4),
        ]
    }
}

/// A compaction can be stopped as a turn can: while it runs, Send is Stop, and pressing it
/// leaves the chat as it was before (no divider, no summary, no error, the same context), the
/// composer free for the next send. The wheel's is stopped with the button, a typed /compact's
/// with Esc.
final class StopCompaction: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(
            turns: [[.startTurn] + Beat.answer("First answer") + [.context(used: 50_000), .finishTurn(.completed)], CLIScript.reply("Went on")],
            compact: CLIScript.heldCompaction)
    }

    /// Nothing says the conversation was compacted, or that compacting failed.
    static func unchanged(_ story: StoryContext, context: String) throws -> Bool {
        let chat = try story.activeChat()
        let rows = chat.rows
        let compacted = story.chatEvents().contains { if case .compacted = $0 { true } else { false } }
        return !chat.isCompacting && !compacted && chat.storyContextUsed == context
            && !rows.contains { $0.kind == "divider" || $0.kind == "summary" || $0.kind == "notice" }
    }

    static func stopped(_ story: StoryContext) -> Int {
        story.chatEvents().filter { if case .compactionStopped = $0 { true } else { false } }.count
    }

    /// The context ring's reading before the compaction.
    private final class Before {
        var context = ""
    }

    static func before(_ story: StoryContext) -> String { story.stash(Before.self) { Before() }.context }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Say something"), TurnFinished(1),
            Do("Note the context") { story in story.stash(Before.self) { Before() }.context = try story.activeChat().storyContextUsed },
            // The wheel's, stopped with the button.
            StartCompact(),
            ExpectElement(.id(StoryID.Composer.stop)),
            Snapshot("compacting-stop"),
            Press(.id(StoryID.Composer.stop)),
            Expect("the compaction stopped, the chat as it was", timeout: .seconds(5), found: { story in
                "rows \((try? story.activeChat().rows.map(\.kind)) ?? []), stopped \(Self.stopped(story))"
            }) { story in
                try story.scriptedBackend().log.contains(.interrupt) && Self.stopped(story) == 1
                    && Self.unchanged(story, context: Self.before(story))
            },
            ExpectElement(.id(StoryID.Composer.send)),
            // A typed /compact, stopped with Esc.
            Send("/compact"),
            Expect("compacting again", timeout: .seconds(5)) { try $0.activeChat().isCompacting },
            ExpectElement(.id(StoryID.Composer.stop)),
            WaitForFocus(.id(StoryID.Composer.field)),
            Key(.escape),
            Expect("stopped again, still as it was", timeout: .seconds(5)) { story in
                try Self.stopped(story) == 2 && Self.unchanged(story, context: Self.before(story))
            },
            // Nothing in the way of the next send.
            Send("Carry on"), TurnFinished(2),
            Expect.rows("its answer") { $0.last?.kind == "assistant" && $0.last?.text == "Went on" },
        ]
    }
}

/// A compaction the CLI starts by itself in a turn, and Kore's own at its point, are stopped
/// the same way: the turn ends stopped, nothing is compacted, and no "Continue" follows.
final class StopAutoCompaction: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(
            turns: [
                [.startTurn] + Beat.answer("Halfway") + [.compaction(auto: true, hold: true)] + Beat.answer("Never said") + [.finishTurn(.completed)],
                [.startTurn] + Beat.answer("Working on it") + [.context(used: 180_000), .finishTurn(.completed)],
                CLIScript.reply("Went on"),
            ],
            compact: CLIScript.heldCompaction)
    }

    override func steps() -> [any Step] {
        super.steps() + [
            // The CLI's own, in the turn.
            Send("Do the work"),
            Expect("compacting in the turn", timeout: .seconds(5)) { story in
                let chat = try story.activeChat()
                return chat.isCompacting && chat.isRunning
            },
            Press(.id(StoryID.Composer.stop)),
            TurnFinished(1),
            Expect("the turn stopped, nothing compacted", timeout: .seconds(5)) { story in
                let events = story.chatEvents()
                let chat = try story.activeChat()
                return !chat.isCompacting && !chat.isRunning
                    && events.contains { if case .turnFinished(_, .interrupted, _) = $0 { true } else { false } }
                    && events.contains { if case .compactionStopped = $0 { true } else { false } }
                    && !events.contains { if case .compacted = $0 { true } else { false } }
                    && !chat.rows.contains { $0.kind == "divider" || $0.kind == "summary" || ($0.kind == "notice" && $0.isError) }
            },
            // Kore's own, at its point after a turn that ran to its end.
            SetAutoCompactPoint(70),
            Send("Next part"), TurnFinished(2),
            Expect("Kore compacting at its point", timeout: .seconds(5)) { try $0.activeChat().isCompacting },
            Press(.id(StoryID.Composer.stop)),
            Expect("stopped, and no Continue after it", timeout: .seconds(5)) { story in
                let log = try story.scriptedBackend().log
                return try !story.activeChat().isCompacting && !log.contains(.send("Continue"))
                    && !story.chatEvents().contains { if case .compacted = $0 { true } else { false } }
            },
            SetAutoCompactPoint(nil),
            Send("Carry on"), TurnFinished(3),
            Expect.rows("its answer") { $0.last?.kind == "assistant" && $0.last?.text == "Went on" },
        ]
    }
}

/// A Stop that lands once the compaction is done does nothing: the compaction stands, the CLI
/// isn't interrupted, and the next send goes as usual.
final class StopAfterCompaction: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("First answer"), CLIScript.reply("Went on")], compact: CLIScript.heldCompaction)
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Say something"), TurnFinished(1),
            StartCompact(),
            Release(),
            Expect("the compaction done") { try !$0.activeChat().isCompacting },
            // As the button's press does when it shows Stop a moment too long.
            Stop(),
            Expect("still compacted, nothing stopped", timeout: .seconds(2)) { story in
                let rows = try story.activeChat().rows
                let events = story.chatEvents()
                return try !story.scriptedBackend().log.contains(.interrupt)
                    && rows.contains { $0.kind == "divider" } && rows.contains { $0.kind == "summary" }
                    && !events.contains { if case .compactionStopped = $0 { true } else { false } }
            },
            ExpectElement(.id(StoryID.Composer.send)),
            Send("Carry on"), TurnFinished(2),
            Expect.rows("its answer") { $0.last?.kind == "assistant" && $0.last?.text == "Went on" },
        ]
    }
}

/// Sets the chat's auto-compact point, as the context card's notch does.
struct SetAutoCompactPoint: Step {
    let point: Int?
    init(_ point: Int?) { self.point = point }
    var label: String { "Set the auto-compact point to \(point.map { "\($0)%" } ?? "Off")" }

    func run(_ story: StoryContext) async throws {
        try story.activeChat().storySetAutoCompact(point)
    }
}

/// Quitting asks first while a chat works: the count it asks with is the chats with a turn
/// running, and none once it stops.
final class QuitCountsWorkingChats: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "sleep 600", wait: .interrupt)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Expect("no chat working yet") { $0.app.workspace?.workingChats == 0 },
            Send("Run the long job"),
            WaitForEvent("the command to start") { if case .toolStarted = $0 { true } else { false } },
            Expect("one chat working while its turn runs", timeout: .seconds(5)) { $0.app.workspace?.workingChats == 1 },
            Stop(),
            TurnFinished(1),
            Expect("none once it's stopped", timeout: .seconds(5), found: { story in
                "working \(story.app.workspace?.workingChats ?? -1), log \((try? story.scriptedBackend().log.map { "\($0)" }) ?? [])"
            }) { $0.app.workspace?.workingChats == 0 },
        ]
    }
}

/// ⌘, opens the chat's Account popup: Kore's settings live in the / menu, with no Settings window.
final class CommandCommaOpensAccount: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Key(.cmd(",")),
            Expect("the Account popup open", timeout: .seconds(3)) { try $0.activeChat().isAccountOpen },
        ]
    }
}

/// With no network: a message waits, said once, and goes when the network is back; a running
/// turn's spinner says it's offline, and goes back once the network is.
final class OfflineWaits: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [
            CLIScript.reply("Sent once back online"),
            [.startTurn, .tool(name: "Bash", detail: "sleep 600", wait: .interrupt)],
        ])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            SetNetwork(false),
            Send("Hello"),
            Expect("said once, nothing sent yet", timeout: .seconds(3)) { story in
                let notices = try story.activeChat().rows.filter { $0.kind == "notice" }.map(\.text)
                let sent = (try? story.scriptedBackend().log.contains(.send("Hello"))) ?? false
                return notices == ["Offline: this sends when the network is back"] && !sent
            },
            SetNetwork(true),
            TurnFinished(1),
            Expect("sent once the network was back") { try $0.scriptedBackend().log.contains(.send("Hello")) },
            Send("Run the long job"),
            WaitForEvent("the command to start") { if case .toolStarted = $0 { true } else { false } },
            SetNetwork(false),
            Expect("the spinner says it's offline", timeout: .seconds(3)) {
                try $0.activeChat().storyConnection == "Offline · waiting for the network"
            },
            SetNetwork(true),
            Expect("and goes back", timeout: .seconds(3)) { try $0.activeChat().storyConnection == nil },
            Stop(), TurnFinished(2),
            SetNetwork(nil),
        ]
    }
}

/// As if the network went (false) or came back (true); nil gives it back to the Mac's own.
struct SetNetwork: Step {
    let online: Bool?
    init(_ online: Bool?) { self.online = online }
    var label: String { online.map { $0 ? "The network comes back" : "The network goes" } ?? "The Mac's own network" }
    func run(_ story: StoryContext) async throws { NetworkWatch.shared.pin(online) }
}

/// A chat whose history starts at a compaction, with little after it, opens with the
/// conversation before the compaction shown too, not just the summary under a "Load earlier
/// conversation" row.
final class CompactedChatShowsEarlier: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    static let before = "Before the compaction"
    static let after = "After the compaction"

    override func steps() -> [any Step] {
        super.steps() + [
            SeedCompacted(provider: variant.provider ?? "claude"),
            Expect("the message from before the compaction shown", found: { story in
                try? story.activeChat().storyTranscript.entries.filter { $0.kind == .user }.map(\.text).joined(separator: " | ")
            }) { story in
                let entries = try story.activeChat().storyTranscript.entries
                let users = entries.filter { $0.kind == .user }.map(\.text)
                return users == [Self.before, Self.after] && entries.contains { $0.kind == .summary }
            },
            Expect("one page read") { _ in ScriptedWorld.shared.backends.last?.log.filter { $0 == .earlier }.count == 1 },
        ]
    }

    /// The session's history from its compaction on, the turn before it as the earlier page;
    /// then it's opened as a resumed chat.
    private struct SeedCompacted: Step {
        let provider: String
        var label: String { "Open a chat that was compacted" }

        func run(_ story: StoryContext) async throws {
            guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
            let world = ScriptedWorld.shared
            let session = "scripted-\(provider)-compacted"
            world.earlier[session] = turn(0, CompactedChatShowsEarlier.before, "The answer before it.")
            world.sessions[session] = [.compacted(at: Date()), .compactionSummary("What the chat did so far.")]
                + turn(1, CompactedChatShowsEarlier.after, "The answer after it.")
            workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Compacted", updated: .now))
            _ = try await story.wait("the resumed chat") { story.app.chat }
        }

        private func turn(_ i: Int, _ message: String, _ answer: String) -> [ChatEvent] {
            [
                .userMessage(text: message, attachments: [], id: "compacted-message-\(i)"),
                .turnStarted("compacted-turn-\(i)", origin: .user, at: Date()),
                .text("compacted-block-\(i)", .answer, answer),
                .turnFinished("compacted-turn-\(i)", .completed, duration: nil),
            ]
        }
    }
}

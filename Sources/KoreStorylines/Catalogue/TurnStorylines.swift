import Foundation
import KoreUI

/// Compacting from the context wheel: the "Conversation compacted" divider, then the summary.
final class CompactViaWheel: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Say something"), TurnFinished(1),
            Compact(),
            Expect.rows("a compaction divider, then the summary") { rows in
                guard let divider = rows.lastIndex(where: { $0.kind == "divider" }) else { return false }
                return rows[divider...].contains { $0.kind == "summary" && !$0.text.isEmpty }
            },
            Expect("the CLI asked to compact") { try $0.scriptedBackend().log.contains(.compact) },
        ]
    }
}

/// A mode picked in the menu reaches the CLI, and the composer shows it.
final class SwitchMode: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let mode = variant.provider == "codex" ? "approveForMe" : "acceptEdits"
        return super.steps() + [
            Send("Hello"), TurnFinished(1),
            SetMode(mode),
            Expect("the CLI told about \(mode)") { try $0.scriptedBackend().log.contains(.setMode(mode)) },
            Send("Carry on"), TurnFinished(2),
            Expect("the mode kept after a turn") { try $0.activeChat().mode == mode },
        ]
    }
}

/// A sub-agent's card: it's spawned, says its piece in its own lane, and finishes with a result.
final class SubAgentCard: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn,
            .agent(id: "agent-1", name: "Count the lines", says: "There are 3 lines.", result: "3"),
            .stream(.answer, "The helper counted 3 lines."),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Count the lines with a helper"), TurnFinished(1),
            Expect.rows("the agent's card") { $0.contains { $0.kind == "agent" && $0.text.contains("Count the lines") } },
            Expect("the agent spawned and finished, in that order") { story in
                let events = story.chatEvents()
                guard let spawned = events.firstIndex(where: { if case .agentSpawned(let a) = $0 { a.id == "agent-1" } else { false } }),
                    let finished = events.firstIndex(where: { if case .agentFinished(let id, _, _) = $0 { id == "agent-1" } else { false } })
                else { return false }
                return spawned < finished
            },
            Expect("its own words in its lane, not the chat's") { story in
                // Text streams in pieces: what the agent said is its pieces joined.
                let said = story.chatEvents().compactMap { if case .text(_, _, let text, .sub("agent-1")) = $0 { text } else { nil } }
                return said.joined().contains("3 lines")
            },
        ]
    }
}

/// An edit in a turn: the file changes on disk, and the turn reports what it changed.
final class ChangesLine: ChatStoryline {
    static let content = "# Notes\n\nWritten by the script.\n"
    override class var tags: Set<Tag> { [.chat, .files] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, .fileEdit(path: "notes.md", content: content), .stream(.answer, "Wrote notes.md."),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Write the notes"), TurnFinished(1),
            Expect("notes.md on disk") { story in
                (try? String(contentsOf: story.folder.appendingPathComponent("notes.md"), encoding: .utf8)) == Self.content
            },
            Expect("the turn's changes to name notes.md") { story in
                story.chatEvents().contains { event in
                    guard case .turnChanges(_, let changes) = event else { return false }
                    return changes.contains { $0.path.hasSuffix("notes.md") && $0.added > 0 }
                }
            },
            Expect.rows("the Edit row") { $0.contains { $0.kind == "tool" && $0.tool == "Edit" && $0.done } },
        ]
    }
}

/// A chat compacting between turns is at work: its tab shows the spinner, as a running turn's
/// does, and it counts among the working chats (the quit check), until the compaction is done.
final class CompactingTabWorking: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(
            turns: [CLIScript.reply("OK")],
            compact: [
                .event(.compactionStarted(auto: false)), .wait(.release),
                .event(.compacted(at: Date(), auto: false)), .event(.compactionSummary("The conversation so far, in brief.")),
            ])
    }

    override func steps() -> [any Step] {
        let spinner = Locator("the chat tab's spinner") { app in
            guard let tab = app.workspace?.activeTab else { return .failure(LocatorMiss("no tab", pending: true)) }
            return .success(StoryID.Tabs.tab(tab.id).part(.working))
        }
        return super.steps() + [
            Send("Say something"), TurnFinished(1),
            ExpectElement(spinner, .absent),
            StartCompact(),
            Expect("compacting, no turn running") { story in
                let chat = try story.activeChat()
                return chat.isCompacting && !chat.isRunning
            },
            ExpectElement(spinner),
            Expect("counted as a working chat") { $0.app.workspace?.workingChats == 1 },
            Snapshot("compacting-tab"),
            Release(),
            Expect("the compaction done") { try !$0.activeChat().isCompacting },
            ExpectElement(spinner, .absent),
            Expect("no working chat left") { $0.app.workspace?.workingChats == 0 },
        ]
    }
}

/// Clicks the context wheel to compact, without waiting for it to finish.
struct StartCompact: Step {
    var label: String { "Start compacting with the context wheel" }
    func run(_ story: StoryContext) async throws {
        try story.activeChat().storyCompact()
        try await story.until("the compaction to start") { try story.activeChat().isCompacting }
    }
}

/// Turns the CLI starts by itself (a peer's message, a finished agent's notification, a cron
/// firing, one already running when Kore attached) show as work as the user's do: the tab's
/// spinner and a working chat, from the CLI's turn start to its end.
final class CLITurnsShowWorking: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    static let origins: [(name: String, origin: TurnOrigin)] = [
        ("a peer's message", .peer), ("an agent's notification", .agentFinished), ("a cron firing", .schedule), ("its own", .cli),
    ]
    override class var script: CLIScript {
        // After the user's first turn, the CLI's own, each held open until the storyline looks.
        CLIScript(turns: [
            [.startTurn, .stream(.answer, "OK"), .finishTurn(.completed)]
                + origins.enumerated().flatMap { n, turn -> [Beat] in
                    let id = "cli-\(n)"
                    var beats: [Beat] = [.wait(.release), .event(.turnStarted(id, origin: turn.origin, at: Date()))]
                    if turn.origin == .peer { beats.append(.event(.peerMessage(from: "kore-2f", text: "A message from a peer", turn: id))) }
                    return beats + [.wait(.release), .event(.turnFinished(id, .completed, duration: nil))]
                }
        ])
    }

    override func steps() -> [any Step] {
        let spinner = Locator("the chat tab's spinner") { app in
            guard let tab = app.workspace?.activeTab else { return .failure(LocatorMiss("no tab", pending: true)) }
            return .success(StoryID.Tabs.tab(tab.id).part(.working))
        }
        return super.steps() + [Send("Hello"), TurnFinished(1), ExpectElement(spinner, .absent)]
            + Self.origins.flatMap { turn -> [any Step] in
                [
                    Release(),
                    ExpectElement(spinner),
                    Expect("\(turn.name): a working chat") { $0.app.workspace?.workingChats == 1 },
                    Release(),
                    ExpectElement(spinner, .absent),
                    Expect("\(turn.name) ended: none working") { $0.app.workspace?.workingChats == 0 },
                ]
            }
    }
}

/// A working chat's tab shows its provider's mark with the wave running through it (in place of
/// the generic spinner), and the plain mark again once the turn ends.
final class WorkingMarkShows: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .wait(.release), .stream(.answer, "Done."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let mark = Locator("the chat tab's working mark") { app in
            guard let tab = app.workspace?.activeTab else { return .failure(LocatorMiss("no tab", pending: true)) }
            return .success(StoryID.Tabs.tab(tab.id).part(.working))
        }
        return super.steps() + [
            Send("Work on it"),
            ExpectElement(mark),
            Expect("the wave running in it") { _ in StoryWorkingMarks.running > 0 },
            Snapshot("working-mark"),
            Release(), TurnFinished(1),
            ExpectElement(mark, .absent),
        ]
    }
}

/// NavCost with the first chat at work the whole time: switching past a tab whose mark is
/// moving costs what switching past an idle one does.
final class NavCostWorking: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override func steps() -> [any Step] {
        let held = CLIScript(turns: [
            [.startTurn, .stream(.answer, NavCost.answer(9, turn: 1), chunk: 4000), .finishTurn(.completed)],
            [.startTurn, .wait(.release), .finishTurn(.completed)],
        ])
        return [OpenFolder(), UseScript(held), StartChat("claude"), Send("first"), TurnFinished(1), Send("hold")]
            + NavCost.chat(2) + NavCost.chat(3) + [WaitIdle(), MeasureNav()]
    }
}

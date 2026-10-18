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

import KoreUI

/// Earlier write-ups remain complete when a finished turn folds its commands away.
final class FoldedWriteups: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let first = "Earlier findings\n\n" + String(repeating: "A detail that must remain readable.\n", count: 8)
    static let second = "Additional findings after the first command."

    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn,
            .event(.text("earlier", .answer, first)),
            .tool(name: "Bash", detail: "check", output: "checked"),
            .event(.text("middle", .answer, second)),
            .tool(name: "Bash", detail: "verify", output: "verified"),
            .event(.text("final", .answer, "Final result")),
            .event(.finalAnswer("final")),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Review the changes"), TurnFinished(1),
            Expect("all three write-ups built in full, commands folded") { story in
                let transcript = try story.activeChat().storyTranscript
                let replies = transcript.entries.filter { $0.kind == .answer }
                let tools = transcript.entries.filter { $0.kind == .tool }
                return replies.map(\.text) == [Self.first, Self.second, "Final result"]
                    && replies.allSatisfy { transcript.isBuilt($0.id) }
                    && tools.allSatisfy { !transcript.isBuilt($0.id) }
            },
            Snapshot("folded-writeups"),
        ]
    }
}

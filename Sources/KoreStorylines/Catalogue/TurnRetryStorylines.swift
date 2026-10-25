import KoreUI

/// A tool can be genuinely slow: quietness offers an escape without failing or replaying it.
final class QuietToolRetry: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "slow job", wait: .release)], CLIScript.reply("Resumed safely")])
    }
    override func steps() -> [any Step] {
        super.steps() + [
            Do("Use a short quiet-work threshold") { _ in Chat.stallAfter.value = 1 },
            Send("Start the work"),
            Expect("quiet work stays running and offers recovery", timeout: .seconds(8)) {
                try $0.activeChat().connection == .quietWork && $0.activeChat().isRunning
            },
            Expect("nothing restarted or sent automatically") { story in
                let log = try story.scriptedBackend().log
                return !log.contains(.relaunch) && !log.contains(.send("Continue"))
            },
            Press(.id(StoryID.Transcript.stalledRetry)),
            TurnFinished(2),
            Expect("one explicit resume followed the old attempt's shutdown") { story in
                let log = try story.scriptedBackend().log
                return log.contains(.relaunch) && log.filter { $0 == .send("Continue") }.count == 1
            },
            Expect.rows("the resumed answer") { $0.contains { $0.text == "Resumed safely" } },
        ]
    }
}

/// A stopped tool has no final answer, but its folded turn still exposes Retry.
final class InterruptedToolRetry: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "work", wait: .interrupt)], CLIScript.reply("Continued")])
    }
    override func steps() -> [any Step] {
        super.steps() + [
            Send("Start the work"),
            WaitForEvent("the tool to start") { if case .toolStarted = $0 { true } else { false } },
            Stop(), TurnFinished(1),
            Do("Keep an unsent composer draft") { try $0.activeChat().draft = "  keep this draft  " },
            PressEndedTurnRetry(), TurnFinished(2),
            Expect("the same session continued once and kept the composer") { story in
                let log = try story.scriptedBackend().log
                let draft = try story.activeChat().draft
                return log.filter { $0 == .send("Continue") }.count == 1 && log.contains(.relaunch)
                    && draft == "  keep this draft  "
            },
            Expect.rows("the resumed answer") { $0.contains { $0.text == "Continued" } },
        ]
    }
}

private struct PressEndedTurnRetry: Step {
    var label: String { "Press the stopped turn's inline Retry" }
    func run(_ story: StoryContext) async throws {
        guard let turn = story.chatEvents().compactMap({ event -> String? in
            if case .turnFinished(let id, _, _) = event { return id }
            return nil
        }).last else { throw StoryFailure.modelMissing("a stopped turn") }
        try await Press(.id(StoryID.Transcript.retry(turn))).run(story)
    }
}

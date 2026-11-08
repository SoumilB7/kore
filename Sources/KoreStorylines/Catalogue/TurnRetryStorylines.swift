import KoreUI

/// A tool can be genuinely slow: however quiet, it shows no warning and nothing restarts it.
final class QuietToolRetry: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "slow job", wait: .release), .finishTurn(.completed)]])
    }
    override func steps() -> [any Step] {
        super.steps() + [
            Do("Use a short quiet-work threshold") { _ in Chat.stallAfter.value = 1 },
            Send("Start the work"),
            WaitForEvent("the tool to start") { if case .toolStarted = $0 { true } else { false } },
            StayQuiet(),
            Expect("quiet work stays running with no warning") {
                try $0.activeChat().connection == .ok && $0.activeChat().isRunning
            },
            ExpectElement(.id(StoryID.Transcript.stalledRetry), .absent),
            Expect("nothing restarted or sent automatically") { story in
                let log = try story.scriptedBackend().log
                return !log.contains(.relaunch) && !log.contains(.send("Continue"))
            },
            Release(),
            TurnFinished(1),
        ]
    }
}

/// Holds past the stall wait while the tool says nothing.
private struct StayQuiet: Step {
    var label: String { "Stay quiet past the stall wait" }
    func run(_ story: StoryContext) async throws { try await Task.sleep(for: .seconds(4)) }
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

/// A turn the model's safeguards refused: its notice offers an earlier model from the CLI's list
/// and the message again with a line of context, not a plain Retry. Each does what it says.
final class RefusedTurnChoices: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.claude] }
    static let message = "Audit the cluster's IAM roles"
    static func model(_ id: String, _ name: String) -> ModelOption {
        ModelOption(id: id, name: name, resolved: id, efforts: ["low", "medium", "high"])
    }
    override class var script: CLIScript {
        CLIScript(
            start: [.event(.controlsLoaded(ChatControls(
                models: [model("default", "Default"), model("vendor-alpha-5", "Alpha 5"), model("vendor-alpha-4-8", "Alpha 4.8"),
                         model("vendor-beta-4-9", "Beta 4.9")],
                model: "default", effort: "medium", commands: [])))],
            turns: [
                [.startTurn, .refuse(Refusal(category: "cyber", model: "vendor-alpha-5-5")),
                 .finishTurn(.failed("API Error: the model's safeguards flagged this session"))],
                CLIScript.reply("Went on"),
            ])
    }
    override func steps() -> [any Step] {
        super.steps() + [
            Expect("Switch models when flagged starts on") { _ in RefusalFallback.saved },
            // Its switch sits at the foot of a Claude chat's model picker.
            Press(.id(StoryID.Composer.model)), WaitForElement(.id(StoryID.Composer.models)),
            Press(.id(StoryID.Composer.refusalSwitch)),
            Expect("off from the model picker") { _ in !RefusalFallback.saved },
            Press(.id(StoryID.Composer.refusalSwitch)),
            Expect("and on again") { _ in RefusalFallback.saved },
            Key(.escape),
            Send(Self.message), TurnFinished(1),
            PressRefused(\.addContext),
            Expect("the message is back in the composer, the context line first") { story in
                try story.activeChat().draft == Refusal.context + "\n\n" + Self.message
            },
            Snapshot("refused-turn"),
            Do("Clear the composer") { try $0.activeChat().draft = "" },
            PressRefused(\.retryOn),
            TurnFinished(2),
            Expect("the chat took the earlier model, then went on once") { story in
                let log = try story.scriptedBackend().log
                guard let model = log.firstIndex(of: .setModel("vendor-alpha-4-8")),
                      let send = log.firstIndex(of: .send("Continue")) else { return false }
                return model < send && log.filter { $0 == .send("Continue") }.count == 1 && !log.contains(.relaunch)
            },
            Expect.rows("the answer on the new model") { $0.contains { $0.text == "Went on" } },
        ]
    }
}

private struct PressRefused: Step {
    let button: KeyPath<RefusedButtons, StoryID>
    init(_ button: KeyPath<RefusedButtons, StoryID>) { self.button = button }
    var label: String { "Press the refused turn's \(button == \RefusedButtons.retryOn ? "Retry on" : "Add context")" }
    func run(_ story: StoryContext) async throws {
        guard let turn = story.chatEvents().compactMap({ event -> String? in
            if case .refused(let id, _) = event { return id }
            return nil
        }).last else { throw StoryFailure.modelMissing("a refused turn") }
        try await ExpectElement(.id(StoryID.Transcript.retry(turn)), .absent).run(story)
        try await Press(.id(RefusedButtons(turn: turn)[keyPath: button])).run(story)
    }
}

private struct RefusedButtons {
    let turn: String
    var retryOn: StoryID { StoryID.Transcript.retryOn(turn) }
    var addContext: StoryID { StoryID.Transcript.addContext(turn) }
}

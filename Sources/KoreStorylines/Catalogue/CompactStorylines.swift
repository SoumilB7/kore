import Foundation
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

/// Sets the chat's auto-compact point, as the context card's notch does.
struct SetAutoCompactPoint: Step {
    let point: Int?
    init(_ point: Int?) { self.point = point }
    var label: String { "Set the auto-compact point to \(point.map { "\($0)%" } ?? "Off")" }

    func run(_ story: StoryContext) async throws {
        try story.activeChat().storySetAutoCompact(point)
    }
}

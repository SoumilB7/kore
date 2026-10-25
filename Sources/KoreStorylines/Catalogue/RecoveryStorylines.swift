import KoreCore
import KoreUI

/// Closed tabs return in reverse close order, with the exact unsent composer text. Opening
/// a closed session from history first makes Reopen focus that tab rather than duplicate it.
final class RecoverClosedDrafts: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Saved reply.")]) }
    static let firstDraft = "first draft stays open"
    static let secondDraft = "  unsent β\nsecond line\t  "
    static let thirdDraft = "draft without a sent turn\nnever send 🙂  "

    override func steps() -> [any Step] {
        super.steps() + [
            Send("first saved conversation"), TurnFinished(1),
            FocusActiveRecoveryComposer(), PasteText(Self.firstDraft),
            Self.draft(Self.firstDraft),
            StartChat(), Send("second saved conversation"), TurnFinished(1),
            Do("Remember the second session") { story in
                let memory = story.stash(RecoveryMemory.self) { RecoveryMemory() }
                guard let session = try story.activeChat().sessionId else { throw StoryFailure.modelMissing("the second session id") }
                memory.session = session
            },
            FocusActiveRecoveryComposer(), PasteText(Self.secondDraft),
            Self.draft(Self.secondDraft),
            StartChat(), FocusActiveRecoveryComposer(), PasteText(Self.thirdDraft),
            Self.draft(Self.thirdDraft),
            Expect("three tabs, with only two messages sent") { story in
                story.app.workspace?.tabs.count == 3 && Self.sent() == ["first saved conversation", "second saved conversation"]
            },
            Command(.closeTab),
            Expect("the newest tab closed") { $0.app.workspace?.tabs.count == 2 },
            Command(.closeTab),
            Expect("only the first tab remains") { $0.app.workspace?.tabs.count == 1 },
            Self.draft(Self.firstDraft),
            Key(.cmdShift("t")),
            Expect("the last closed session returns first") { story in
                let memory = story.stash(RecoveryMemory.self) { RecoveryMemory() }
                return story.app.workspace?.tabs.count == 2 && story.app.chat?.sessionId == memory.session
            },
            WaitForFocus(.id(StoryID.Composer.field)), Self.draft(Self.secondDraft),
            RecoverClosedTab(),
            Expect("the earlier closed tab returns next") { $0.app.workspace?.tabs.count == 3 },
            WaitForFocus(.id(StoryID.Composer.field)), Self.draft(Self.thirdDraft),
            Self.nothingSent,
            Snapshot("recovered-unsent-draft"),
            // Close the saved session, then open it through History before Reopen consumes
            // its stack entry: the existing session must be selected, never duplicated.
            Do("Select the second session again") { $0.app.workspace?.storySelect(tabAt: 1) },
            Command(.closeTab),
            Do("Open the same closed session through history") { story in
                guard let workspace = story.app.workspace,
                    let provider = story.variant?.provider,
                    let agent = SessionSummary.Agent(rawValue: provider),
                    let session = story.stash(RecoveryMemory.self, make: { RecoveryMemory() }).session
                else { throw StoryFailure.modelMissing("the saved session") }
                workspace.open(SessionSummary(id: session, agent: agent, title: "Second saved conversation", updated: .now))
            },
            Expect("history reopened one session tab") { $0.app.workspace?.tabs.count == 3 },
            RecoverClosedTab(),
            Expect("Reopen focuses the existing session without a duplicate") { story in
                guard let workspace = story.app.workspace,
                    let session = story.stash(RecoveryMemory.self, make: { RecoveryMemory() }).session
                else { return false }
                return workspace.tabs.count == 3 && workspace.activeTab.chat?.sessionId == session
                    && workspace.tabs.filter { $0.chat?.sessionId == session }.count == 1
            },
            WaitForFocus(.id(StoryID.Composer.field)), Self.draft(Self.secondDraft),
            Self.nothingSent,
        ]
    }

    private static func draft(_ expected: String) -> Expect {
        Expect("the exact unsent draft in the model and composer") { story in
            try story.activeChat().draft == expected && SwitchTab.composerText(story) == expected
        }
    }

    private static var nothingSent: Expect {
        Expect("restoring a draft sends no message or queued input") { story in
            Self.sent() == ["first saved conversation", "second saved conversation"] && story.app.chat?.isRunning == false
        }
    }

    @MainActor private static func sent() -> [String] {
        ScriptedWorld.shared.backends.flatMap(\.log).compactMap {
            switch $0 {
            case .send(let text), .queued(let text): text
            default: nil
            }
        }
    }
}

private struct RecoverClosedTab: Step {
    var label: String { "Reopen the most recently closed tab" }
    @MainActor func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace, workspace.can(.reopenClosedTab) else {
            throw StoryFailure.expectation("Reopen Closed Tab to be available")
        }
        workspace.perform(.reopenClosedTab)
        try await story.idle()
    }
}

@MainActor private final class RecoveryMemory {
    var session: String?
}

/// The composer is shared across chat tabs. A model switch can precede its next AppKit
/// update while the previous chat's text view still owns focus: wait for its bound value,
/// then click the mounted field before sending real input.
private struct FocusActiveRecoveryComposer: Step {
    var label: String { "Focus the active chat's mounted composer" }
    @MainActor func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        try await story.until("the shared composer to show the active chat's draft") {
            story.app.chat === chat && SwitchTab.composerText(story) == chat.draft
        }
        try await Click(.id(StoryID.Composer.field)).run(story)
        try await WaitForFocus(.id(StoryID.Composer.field)).run(story)
    }
}

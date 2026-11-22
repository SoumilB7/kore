import AgentTools
import Foundation
import KoreUI
import src

/// Always allow keeps the kind (the owner via Kore-main, 2026-11-20 and 11-22): on a "Claude
/// stopped: it needs `sudo apt install cowsay`" card, Always allow's tooltip shows the kind it
/// keeps (`Bash(sudo apt install *)`), and pressing it asks the idle chat to go on. The card is the
/// one `ClaudeAutoStops` makes at a turn's end; the rule in the project's local settings, the
/// pass and a later `sudo apt install x` running are `AutoStopTests`' (a scripted Claude).
final class AutoAlwaysKind: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready."), CLIScript.reply("Installed.")]) }

    static let id = ClaudeAutoStops.idPrefix + "t1"
    static let command = "sudo apt install cowsay"

    override func steps() -> [any Step] {
        let card = StoryID.Approval.card(Self.id)
        return super.steps() + [
            Send("hello"), TurnFinished(1),
            Do("the turn ended on a refused `sudo apt install cowsay`") { story in
                let chat = try story.activeChat()
                let stop = ClaudeAutoStops.Card(
                    id: Self.id, command: Self.command, cwd: chat.folder.path, critical: false,
                    rule: KoreAlwaysRule.rule(for: Self.command, cwd: chat.folder.path))
                chat.approvals.apply(.approvalRequested(stop.approval))
            },
            WaitForElement(.id(card.part(.always))),
            Expect("its title says what Claude needs") { story in
                try story.activeChat().pendingApprovals.first { $0.id == Self.id }?.title == "Claude stopped: it needs `sudo apt install cowsay`"
            },
            Expect("Run once and Dismiss beside it") { _ in StoryElement(card.part(.allow)) != nil && StoryElement(card.part(.deny)) != nil },
            Expect("its tooltip shows the kind it keeps") { story in
                try story.activeChat().pendingApprovals.first { $0.id == Self.id }?.alwaysHelp == "Always allow `sudo apt install …`"
            },
            Press(.id(card.part(.always))),
            Expect("Always allow: gone") { story in try !story.activeChat().pendingApprovals.contains { $0.id == Self.id } },
            TurnFinished(2),
            Expect.rows("the chat is asked to go on") { rows in rows.contains { $0.kind == "user" && $0.text == ClaudeAutoStops.continueMessage(Self.command) } },
        ]
    }
}

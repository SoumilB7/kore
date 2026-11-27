import AgentTools
import Foundation
import KoreCore
import KoreUI
import src

/// "Take Kore's old ask list out of my settings" on a Claude Auto card: with Kore's old ask-list
/// hook in the run's Claude settings (its CLAUDE_CONFIG_DIR, never the owner's ~/.claude), the card
/// offers it; pressed, the hook is gone from that file, its other keys stay, and the chat says so.
final class DriveAskListOut: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    static let id = ClaudeAutoStops.idPrefix + "asklist"
    static let command = "sudo apt install cowsay"
    /// Kore's old entry, as an older Kore wrote it.
    static let hook = "'/Applications/Kore.app/Contents/MacOS/kore' hook pretool"

    /// The run's Claude settings file; nil when the run has no Claude config dir of its own.
    static var file: URL? { StoryHost.claudeSettings(ClaudeAskSettings.file()) }  // the run's: the seam ignores the real path

    override func steps() -> [any Step] {
        let card = StoryID.Approval.card(Self.id)
        return super.steps() + [
            Do("Kore's old ask list in the run's Claude settings, beside a key of the person's own") { _ in
                guard let file = Self.file else { throw StoryFailure.other("the run has no CLAUDE_CONFIG_DIR of its own") }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(#"{"theme":"dark"}"#.utf8).write(to: file)
                try ClaudeAskSettings.install(file, command: Self.hook)
            },
            Expect("it's in, under the run's own folder", found: { _ in Self.file?.path }) { _ in
                guard let file = Self.file else { return false }
                return ClaudeAskSettings.installed(file) && file.path.hasPrefix(OwnerConfig.home.appendingPathComponent(".claude").path) == false
            },
            Send("hello"), TurnFinished(1),
            Do("the turn ended on a refused `sudo apt install cowsay`") { story in
                let chat = try story.activeChat()
                let stop = ClaudeAutoStops.Card(
                    id: Self.id, command: Self.command, cwd: chat.folder.path, critical: false,
                    rule: KoreAlwaysRule.rule(for: Self.command, cwd: chat.folder.path))
                chat.approvals.apply(.approvalRequested(stop.approval))
            },
            WaitForElement(.id(card.part(.settings))),
            Press(.id(card.part(.settings))),
            Expect("the hook out of the run's settings, the person's own key kept", found: { _ in
                Self.file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "no file"
            }) { _ in
                guard let file = Self.file, let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return !ClaudeAskSettings.installed(file) && text.contains("\"theme\"") && !text.contains("hook pretool")
            },
            Expect.rows("the chat says it's out") { rows in rows.contains { $0.text.contains("Kore's ask list is out of your Claude settings") } },
        ]
    }
}

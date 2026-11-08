import AgentTools
import Foundation
import KoreUI
import src

/// Always allow keeps the kind (the owner via Kore-main, 2026-11-20): on an Auto asks card for
/// `sudo apt install cowsay`, Always allow sends `Bash(sudo apt install *)` (its tooltip says so);
/// the CLI keeps it in the project's local settings, as claude 2.1.318 does, and Kore's hook then
/// lets the next `sudo apt install x` through while still asking about other sudo calls and
/// critical removals. The card is the one `ClaudeTranslator` makes: the CLI's frames are its unit
/// tests'.
final class AutoAlwaysKind: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    static let id = "r-sudo"

    /// Kore's hook for a call in this chat's folder, with the settings it reads there (a scratch
    /// config folder for the user's: never the real one).
    private static func hookAsks(_ command: String, in folder: URL) -> Bool {
        let input: [String: Any] = ["permission_mode": "auto", "tool_name": "Bash", "tool_input": ["command": command], "cwd": folder.path]
        let environment = ["CLAUDE_PROJECT_DIR": folder.path, "CLAUDE_CONFIG_DIR": folder.appendingPathComponent(".kore-config").path, "HOME": folder.path]
        return KoreAskList.answer(input, rules: { KoreAskList.settingsRules(input, environment: environment) }) != nil
    }

    override func steps() -> [any Step] {
        let card = StoryID.Approval.card(Self.id)
        return super.steps() + [
            Send("hello"), TurnFinished(1),
            Expect("Kore's hook asks about sudo apt install") { story in Self.hookAsks("sudo apt install cowsay", in: try story.activeChat().folder) },
            Do("the CLI: Auto asks: sudo apt install cowsay") { story in
                let chat = try story.activeChat()
                let rule = KoreAlwaysRule.rule(for: "sudo apt install cowsay", cwd: chat.folder.path)
                var ask = Approval(
                    id: Self.id, title: "Auto asks: sudo apt install cowsay (Kore asks you first: sudo.)", detail: nil, body: "sudo apt install cowsay",
                    canAlwaysAllow: rule != nil, questions: [])
                ask.autoStop = true
                ask.alwaysRule = rule
                ask.tool = "Bash"
                chat.approvals.apply(.approvalRequested(ask))
            },
            WaitForElement(.id(card.part(.always))),
            Expect("its tooltip shows the kind it keeps") { story in
                try story.activeChat().pendingApprovals.first { $0.id == Self.id }?.alwaysHelp == "Always allow `sudo apt install …`"
            },
            Press(.id(card.part(.always))),
            Expect("Always allow: gone") { story in try !story.activeChat().pendingApprovals.contains { $0.id == Self.id } },
            Do("the CLI keeps Bash(sudo apt install *) in the project's local settings") { story in
                let folder = try story.activeChat().folder.appendingPathComponent(".claude")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(#"{"permissions":{"allow":["Bash(sudo apt install *)"]}}"#.utf8).write(to: folder.appendingPathComponent("settings.local.json"))
            },
            Expect("the next sudo apt install x doesn't ask") { story in !Self.hookAsks("sudo apt install x", in: try story.activeChat().folder) },
            Expect("other sudo calls still ask") { story in Self.hookAsks("sudo reboot", in: try story.activeChat().folder) },
            Expect("a critical removal still asks") { story in Self.hookAsks("sudo rm -rf /", in: try story.activeChat().folder) },
        ]
    }
}

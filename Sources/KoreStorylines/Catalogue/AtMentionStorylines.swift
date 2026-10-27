import AppKit
import KoreUI

/// "@" in the composer opens one search over the folder's files, the models and the rest:
/// "@Read" and Return attach README.md as a chip, the "@Read" gone; "@hai" and Return switch the
/// chat to Haiku with nothing typed left behind.
final class AtMentionPicks: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(
            start: [
                .event(.controlsLoaded(ChatControls(
                    models: [
                        ModelOption(id: "opus", name: "Opus", resolved: "opus", efforts: ["low"]),
                        ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: ["low"]),
                    ],
                    model: "opus", effort: "low", commands: [])))
            ],
            turns: [CLIScript.reply("OK")])
    }

    override func steps() -> [any Step] {
        let row = { (id: String) in Locator.id(StoryID.Composer.mention(id)) }
        return [
            UseScript(Self.script),
            WriteFiles([("README.md", "# readme\n"), ("Sources/Main.swift", "print(1)\n")]),
            OpenFolder(),
            StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            TypeText("see @Read"),
            WaitForElement(row("file:README.md")),
            Snapshot("at-menu"),
            Key(.returnKey),
            ExpectElement(row("file:README.md"), .absent),
            Expect("README.md in a chip, “@Read” gone", found: { story in
                guard let chat = story.app.chat else { return "no chat" }
                return "chips \(chat.attachments.map(\.name)), draft “\(chat.draft)”"
            }) { story in
                let chat = try story.activeChat()
                return chat.attachments.map(\.name) == ["README.md"] && chat.draft == "see "
            },
            TypeText("@hai"),
            WaitForElement(row("model:haiku")),
            Key(.returnKey),
            ExpectElement(row("model:haiku"), .absent),
            Expect("Haiku the chat's model, nothing typed left", found: { story in
                guard let chat = story.app.chat else { return "no chat" }
                return "model \(chat.storyModel ?? "none"), draft “\(chat.draft)”"
            }) { story in
                let chat = try story.activeChat()
                return chat.storyModel == "haiku" && chat.draft == "see " && chat.attachments.count == 1
            },
            Expect("the CLI asked to switch") { try $0.scriptedBackend().log.contains(.setModel("haiku")) },
        ]
    }
}

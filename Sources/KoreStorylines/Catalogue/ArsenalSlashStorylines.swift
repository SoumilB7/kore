import Foundation
import KoreLink
import KoreUI
import src

/// "/" commands in a message to another chat (the owner, 2026-11-15): one from that chat's own "/"
/// list goes as the composer sends it, with who sent it; sign-in, account, permission and settings
/// commands stay the user's, as do the ones Kore has a command of its own for (mode, model) and
/// "!" lines; one the chat doesn't list is refused.
final class ArsenalSlash: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript {
        let commands = [
            SlashCommand(name: "review", description: "Review the changes", hint: "", kind: .command),
            SlashCommand(name: "permissions", description: "Manage permissions", hint: "", kind: .command),
            SlashCommand(name: "config", description: "Settings", hint: "", kind: .command),
        ]
        return CLIScript(
            start: [.event(.controlsLoaded(ChatControls(models: [], model: nil, effort: nil, commands: commands)))],
            turns: [CLIScript.reply("Ready."), CLIScript.reply("Ready."), CLIScript.reply("Reviewed.")])
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/ksl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                ArsenalMemory.clear()
                Arsenal.shared.setAllowed(true)
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
            Do("a in \(codex ? "Full access" : "Edit automatically")") { story in
                try AgentCast.of(story).chat("a").storySetMode(codex ? "fullAccess" : "acceptEdits")
            },
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            CastChat("b"), SendTo("b", "hello"), TurnsDone("b", 1),
            KoreAs(["send", "{b}", "/permissions"], a, "a permission command: the user's", status: 1, says: "Only you run /permissions"),
            KoreAs(["send", "{b}", "/config"], a, "a settings one", status: 1, says: "Only you run /config"),
            KoreAs(["send", "{b}", "/account"], a, "the account", status: 1, says: "Only you run /account"),
            KoreAs(["send", "{b}", "/model haiku"], a, "a model: kore model's", status: 1, says: "kore model"),
            KoreAs(["send", "{b}", "/nope"], a, "one b doesn't list", status: 1, says: "isn't in this chat's"),
            KoreAs(["send", "{b}", "!ls"], a, "a “!” line", status: 1, says: "Only you run a “!” shell line"),
            KoreAs(["send", "{b}", "/review the diff"], a, "one b lists", expect: ["Sent."]),
            TurnsDone("b", 2),
            Expect.rows("b ran it, saying who sent it") { rows in
                rows.contains { $0.kind == "notice" && $0.text.hasPrefix("Arsenal · sent by") }
                    && rows.contains { $0.kind == "user" && $0.text.contains("review the diff") }
            },
        ]
    }
}

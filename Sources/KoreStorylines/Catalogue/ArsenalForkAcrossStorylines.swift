import Foundation
import KoreLink
import KoreUI
import src

/// A fork into the other CLI (the owner, 2026-11-15): `kore fork . --codex` from a Claude chat
/// (`--claude` from a Codex one) opens a new chat of that CLI in a tab of its own in front, as
/// Import in a new chat does it: the whole conversation carried above a "Continued in" divider,
/// its mode no freer than the caller's, its Arsenal off. With `--at`, refused: it carries it all.
final class ArsenalForkAcross: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    /// A model that offers Claude's Auto, so a Claude caller ranks above Codex's Ask for approval.
    override class var script: CLIScript {
        let model = ModelOption(id: "lyra-3", name: "Lyra 3", resolved: "lyra-3", efforts: ["low", "medium"], supportsAutoMode: true)
        return CLIScript(
            start: [.event(.controlsLoaded(ChatControls(models: [model], model: model.id, effort: "low", commands: [])))],
            turns: [CLIScript.reply("The build is 7781.")])
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kfa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let other = codex ? "claude" : "codex"
        let otherName = codex ? "Claude" : "Codex"
        let a = KoreCaller.chat("a")
        let imports = Imports()
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed; its history as its CLI wrote it") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                ArsenalMemory.clear()
                Arsenal.shared.setAllowed(true)
                let file = story.outputs.appendingPathComponent("a-history.jsonl")
                try FileManager.default.createDirectory(at: story.outputs, withIntermediateDirectories: true)
                let lines = codex ? ImportFixtures.codex : ImportFixtures.claude
                try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
                let provider = codex ? "codex" : "claude"
                StorylineSeams.historyFile = { cli, _ in cli == provider ? file : nil }
                imports.before = ScriptedWorld.shared.imports.count
            },
            SendTo("a", "Check the build number."), TurnsDone("a", 1),
            Do("a in \(codex ? "Full access" : "Auto")") { story in try AgentCast.of(story).chat("a").storySetMode(codex ? "fullAccess" : "auto") },
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            KoreAs(["fork", ".", "--at", "-1", "--\(other)"], a, "a point in it: refused", status: 1, says: "leave out at"),
            KoreAs(["fork", ".", "--\(other)"], a, "a forked into \(otherName)", expect: ["Forked it into \(otherName)."]),
            Expect("a \(otherName) tab in front: a's conversation, the divider; no freer than a, Arsenal off", timeout: .seconds(15)) { story in
                let fork = try story.activeChat()
                let a = try AgentCast.of(story).chat("a")
                let rows = fork.rows
                return fork.provider.id == other && fork.arsenal == nil && fork.noFreer(than: a)
                    && rows.filter { $0.kind == "user" }.map(\.text) == ["Check the build number."]
                    && rows.contains { $0.kind == "divider" && $0.text.hasPrefix("Continued in") }
            },
            Expect("carried once, by Kore's import") { _ in ScriptedWorld.shared.imports.count == imports.before + 1 },
            Do("the seam back") { _ in StorylineSeams.historyFile = nil },
        ]
    }
}

/// How many imports the scripted world had before the fork.
private final class Imports: @unchecked Sendable {
    var before = 0
}

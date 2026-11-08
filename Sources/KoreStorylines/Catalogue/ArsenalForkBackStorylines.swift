import Foundation
import KoreLink
import KoreUI
import src

/// A fork at a message counted from the end (the owner, 2026-11-15): the message scroller's card
/// shows each one's count ("-3") while the pointer is over it, and `kore fork --at -2` forks at the
/// one that card says -2 on, as its menu's Fork does: the conversation before it, it in the fork's
/// composer. Past the first, refused with how many there are.
final class ArsenalForkBack: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("1."), CLIScript.reply("2."), CLIScript.reply("3.")])
    }

    private func count(_ index: Int, shows back: Int) -> [any Step] {
        [
            Do("the pointer on mark \(index)") { story in try AgentCast.of(story).chat("a").storyTranscript.railHover(index) },
            Expect("its card says -\(back)") { _ in StoryElement(StoryID.Transcript.railCount(back)) != nil },
        ]
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kfb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let a = KoreCaller.chat("a")
        let codex = variant == .codex
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
            SendTo("a", "one"), TurnsDone("a", 1),
            SendTo("a", "two"), TurnsDone("a", 2),
            SendTo("a", "three"), TurnsDone("a", 3),
            // A Codex chat has Arsenal only in Full access.
            Do("a in Full access, on Codex") { story in if codex { try AgentCast.of(story).chat("a").storySetMode("fullAccess") } },
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            WaitForElement(.id(StoryID.Transcript.rail)),
            Expect("no count while the pointer is away") { _ in StoryElement(StoryID.Transcript.railCount(1)) == nil },
        ] + count(0, shows: 3) + count(2, shows: 1) + count(1, shows: 2) + [
            Do("the pointer leaves") { story in try AgentCast.of(story).chat("a").storyTranscript.railHover(nil) },
            Expect("the count gone with it") { _ in StoryElement(StoryID.Transcript.railCount(2)) == nil },
            KoreAs(["fork", ".", "--at", "-2"], a, "a forked at -2", expect: ["Forked it."]),
            Expect("the fork: what came before “two”, and “two” in its composer", timeout: .seconds(15)) { story in
                let fork = try story.activeChat()
                let users = fork.rows.filter { $0.kind == "user" }.map(\.text)
                return fork !== (try AgentCast.of(story).chat("a")) && users == ["one"] && fork.draft == "two" && fork.arsenal == nil
            },
            KoreAs(["fork", ".", "--at", "-4"], a, "past the first: refused, with how many", status: 1, says: "-1 to -3"),
        ]
    }
}

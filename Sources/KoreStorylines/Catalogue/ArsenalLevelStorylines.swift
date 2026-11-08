import Foundation
import KoreLink
import KoreUI
import src

/// Act unlimited on another chat's mode and commands, at the caller's level (the owner,
/// 2026-11-15): it moves another chat up or down to any mode that leaves it no freer than itself
/// (a chat in Edit automatically can't put another in Auto), and allows another's permission card
/// once only from Auto or above. Plans, Always allow and sign-ins stay the user's.
final class ArsenalLevel: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    /// A model that offers Claude's Auto.
    override class var script: CLIScript {
        let model = ModelOption(id: "lyra-3", name: "Lyra 3", resolved: "lyra-3", efforts: ["low", "medium"], supportsAutoMode: true)
        return CLIScript(start: [.event(.controlsLoaded(ChatControls(models: [model], model: model.id, effort: "low", commands: [])))], turns: [
            CLIScript.reply("Ready."),
            [.startTurn, .approval(AgentChannelAll.card, allow: Beat.answer("Listed."), deny: []), .finishTurn(.completed)],
        ])
    }

    private func mode(_ role: String, _ wanted: String, _ what: String) -> Expect {
        Expect("\(what): \(role) in \(wanted)") { story in try AgentCast.of(story).chat(role).mode == wanted }
    }

    private func user(_ role: String, _ id: String) -> Do {
        Do("the user puts \(role) in \(id)") { story in try AgentCast.of(story).chat(role).storySetMode(id) }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kal-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        let card = AgentChannelAll.card.id
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
        ] + (codex ? [user("a", "fullAccess")] : [user("a", "acceptEdits")]) + [
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            Expect("a at Act unlimited") { story in try AgentCast.of(story).chat("a").arsenal == .drive },
            CastChat("b"), SendTo("b", "hello"), TurnsDone("b", 1),
        ] + (codex ? [
            // A caller in Full access: any of b's modes, up and down.
            user("b", "askForApproval"),
            KoreAs(["mode", "{b}", "approveForMe"], a, "b up to Approve for me", expect: ["Mode Approve for me."]),
            mode("b", "approveForMe", "raised"),
            KoreAs(["mode", "{b}", "askForApproval"], a, "and down again", expect: ["Mode Ask for approval."]),
            mode("b", "askForApproval", "lowered"),
        ] : [
            // A caller in Edit automatically: b up to it, not past it.
            user("b", "plan"),
            KoreAs(["mode", "{b}", "default"], a, "b up from Plan to Manual", expect: ["Mode Manual."]),
            mode("b", "default", "raised"),
            KoreAs(["mode", "{b}", "acceptEdits"], a, "b up to Edit automatically, a's own", expect: ["Mode Edit automatically."]),
            mode("b", "acceptEdits", "raised to a's"),
            KoreAs(["mode", "{b}", "auto"], a, "not past a: Auto", status: 1, says: "only you can"),
            mode("b", "acceptEdits", "as it was"),
            KoreAs(["options", "{b}"], a, "b's options say which a may pick") { status, out, _ in status == 0 },
            // a's own chat still only lowers.
            KoreAs(["mode", ".", "auto"], a, "its own: never up", status: 1, says: "Only you can raise"),
            user("b", "default"),
        ]) + [
            // A permission card in b.
            KoreAs(["send", "{b}", "list it"], a, "b runs into a card", expect: ["Sent."]),
            Expect("b's card") { story in try AgentCast.of(story).chat("b").pendingApprovals.contains { $0.id == card } },
        ] + (codex ? [] : [
            KoreAs(["answer", "{b}", card, "--allow"], a, "Edit automatically can't allow", status: 1, says: "Only a chat at Auto or above"),
            Expect("still waiting") { story in try AgentCast.of(story).chat("b").pendingApprovals.contains { $0.id == card } },
            user("a", "auto"),
        ]) + [
            KoreAs(["answer", "{b}", card, "--allow"], a, "allowed once", expect: ["Allowed once."]),
            Expect("b's card gone, its turn on") { story in try AgentCast.of(story).chat("b").pendingApprovals.isEmpty },
            TurnsDone("b", 2),
            Expect.rows("b says who allowed it") { rows in rows.contains { $0.kind == "notice" && $0.text.hasPrefix("Arsenal · allowed") } },
        ]
    }
}

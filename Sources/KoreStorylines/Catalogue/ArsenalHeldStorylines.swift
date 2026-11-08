import Foundation
import KoreLink
import KoreUI
import src

/// A cross-session message Claude held (`ClaudePeerHolds`, the owner via Kore-main 2026-11-18):
/// b shows one card a line long, which waits through b's turns and is listed by `kore pending`.
/// The chat whose message is held never lets it in; another chat at Act unlimited does, and b
/// says who. A hold no flag can lift is Deny-only: Allow is dim, and refused to agents. The user's
/// own Allow on the card works as any card's. The card here is the one `ClaudePeerHolds` makes:
/// the CLI's frames and the policy window are its unit tests'.
final class ArsenalHeld: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready."), CLIScript.reply("Ready."), CLIScript.reply("Ready.")]) }

    private static let card = ClaudePeerHolds.cardID

    /// The card b's backend raises for a message held from `sender`.
    private func hold(_ sender: String, denyOnly: Bool = false) -> Do {
        Do("Claude holds a message to b from \(sender)\(denyOnly ? ", by a setting Kore can't change" : "")") { story in
            let cast = AgentCast.of(story)
            let b = try cast.chat("b")
            let name = sender == "a" ? try cast.chat("a").title : sender
            var approval = Approval(
                id: Self.card, title: "A message from “\(name)” is held: it bypasses permissions and this chat doesn't", detail: nil, body: nil,
                canAlwaysAllow: false, questions: [])
            approval.held = [.init(from: "uds:/tmp/cc-socks/1.sock", name: name)]
            approval.tool = "PeerMessage"
            if denyOnly { approval.allowNote = "A setting Kore can't change holds it: only Deny works here." }
            b.approvals.apply(.approvalRequested(approval))
        }
    }

    private func card(_ what: String, _ there: Bool) -> Expect {
        Expect(what) { story in try AgentCast.of(story).chat("b").pendingApprovals.contains { $0.id == Self.card } == there }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kah-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let a = KoreCaller.chat("a")
        let c = KoreCaller.chat("c")
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
            SendTo("a", "first"), TurnsDone("a", 1),
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            CastChat("c"), SendTo("c", "third"), TurnsDone("c", 1),
            Do("c at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("c")) },
            CastChat("b"), SendTo("b", "second"), TurnsDone("b", 1),

            // a's message held in b: the card, on screen, through a turn, in kore pending.
            hold("a"),
            WaitForElement(.id(StoryID.Approval.card(Self.card).part(.allow))),
            SendTo("b", "carry on"), TurnsDone("b", 2),
            card("the card waits through b's turn", true),
            KoreAs(["pending", "{b}"], c, "kore pending lists it") { status, out, _ in status == 0 && out.contains("is held: it bypasses permissions") },

            // The sender never lets its own message in; another chat does, and b says who.
            KoreAs(["answer", "{b}", Self.card, "--allow"], a, "a, whose message it is", status: 1, says: "This chat sent one of the held messages"),
            card("still held", true),
            KoreAs(["answer", "{b}", Self.card, "--allow"], c, "c lets it in", expect: ["Let in."]),
            card("the card gone", false),

            // Deny-only: Allow dim on the card, refused to agents; Deny works.
            hold("Kore-remote", denyOnly: true),
            WaitForElement(.id(StoryID.Approval.card(Self.card).part(.allow))),
            Press(.id(StoryID.Approval.card(Self.card).part(.allow))),
            card("Allow does nothing there: the card stays", true),
            KoreAs(["answer", "{b}", Self.card, "--allow"], c, "refused past a setting", status: 1, says: "only Deny"),
            KoreAs(["answer", "{b}", Self.card, "--deny"], c, "denied", expect: ["Denied."]),
            card("gone after Deny", false),

            // The user's own Allow.
            hold("Kore-remote"),
            WaitForElement(.id(StoryID.Approval.card(Self.card).part(.allow))),
            Press(.id(StoryID.Approval.card(Self.card).part(.allow))),
            card("gone after the user's Allow", false),
        ]
    }
}

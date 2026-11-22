import AgentTools
import Foundation
import KoreLink
import KoreUI
import src

/// Auto's cards (the owner via Kore-main, 2026-11-19 and 11-22): Claude's "Claude stopped" card
/// (the last call of a turn refused) and Codex's reviewer denial have Run once; another chat's
/// agent runs one only from Auto with Act unlimited or above (`arsenalRunAutoAsk`'s unit tests),
/// so a's, below Auto, may only dismiss it. Run once asks the idle chat to go on. A critical
/// removal's card has Dismiss (Claude) or OK (Codex) only. The cards here are the ones
/// `ClaudeAutoStops` and `CodexAutoStops` make: the CLIs' frames are `AutoStopTests`' and the
/// unit tests'.
final class ArsenalAutoAsk: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready."), CLIScript.reply("Ready."), CLIScript.reply("On it.")]) }

    private func raise(_ id: String, _ title: String, refusal: String? = nil, retry: String? = nil) -> Do {
        Do("b's CLI: \(title)") { story in
            var card = Approval(id: id, title: title, detail: refusal, body: nil, canAlwaysAllow: false, questions: [])
            card.autoStop = true
            card.allowNote = refusal
            card.retryMessage = retry
            try AgentCast.of(story).chat("b").approvals.apply(.approvalRequested(card))
        }
    }

    /// Claude's card, as `ClaudeAutoStops` makes it at the turn's end.
    private func stopped(_ id: String, _ command: String, critical: Bool) -> Do {
        Do("b's turn ended on a refused `\(command)`") { story in
            let chat = try AgentCast.of(story).chat("b")
            let card = ClaudeAutoStops.Card(
                id: ClaudeAutoStops.idPrefix + id, command: command, cwd: chat.folder.path, critical: critical,
                rule: critical ? nil : KoreAlwaysRule.rule(for: command, cwd: chat.folder.path))
            chat.approvals.apply(.approvalRequested(card.approval))
        }
    }

    private func card(_ id: String, _ there: Bool, _ what: String) -> Expect {
        Expect(what) { story in try AgentCast.of(story).chat("b").pendingApprovals.contains { $0.id == id } == there }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kaa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        let ask = codex ? CodexAutoStops.idPrefix + "rv1" : ClaudeAutoStops.idPrefix + "t1"
        let stop = codex ? CodexAutoStops.idPrefix + "rv9" : ClaudeAutoStops.idPrefix + "t9"
        let title = codex ? "Auto stopped: curl -sI https://example.com (No authorization for network access.)" : ClaudeAutoStops.title("sudo reboot")
        let raiseAsk = codex ? raise(ask, title, retry: CodexAutoStops.retry("curl -sI https://example.com")) : stopped("t1", "sudo reboot", critical: false)
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
        ] + (codex ? [Do("a in Full access") { story in try AgentCast.of(story).chat("a").storySetMode("fullAccess") }] : []) + [
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            CastChat("b"), SendTo("b", "hello"), TurnsDone("b", 1),

            // An ask: on screen with Run once; a's agent, below Auto, can't run it, only deny.
            raiseAsk,
            WaitForElement(.id(StoryID.Approval.card(ask).part(.allow))),
            KoreAs(["pending", "{b}"], a, "kore pending lists it") { status, out, _ in status == 0 && out.contains(String(title.prefix(30))) },
        ] + (codex ? [] : [
            KoreAs(["answer", "{b}", ask, "--allow"], a, "an agent below Auto can't run it", status: 1, says: "Only a chat at Auto or above"),
            card(ask, true, "still asking"),
        ]) + [
            KoreAs(["answer", "{b}", ask, "--deny"], a, "an agent may deny it", expect: ["Denied."]),
            card(ask, false, "denied: gone"),

            // The person's Run once.
            raiseAsk,
            WaitForElement(.id(StoryID.Approval.card(ask).part(.allow))),
            Press(.id(StoryID.Approval.card(ask).part(.allow))),
            card(ask, false, "Run once: gone"),
            // The idle chat is asked to go on.
            TurnsDone("b", 2),
            Expect.rows("b asked to run it once") { rows in
                rows.contains { $0.kind == "user" && $0.text == (codex ? "Run once: `curl -sI https://example.com`" : ClaudeAutoStops.continueMessage("sudo reboot")) }
            },
        ] + [
            // Critical: the card says why, with OK (Codex) or Dismiss (Claude) only, no Run once.
            codex ? raise(stop, "Auto stopped: rm -rf ~ (critical)", refusal: CodexAutoStops.criticalLine) : stopped("t9", "rm -rf ~", critical: true),
            WaitForElement(.id(StoryID.Approval.card(stop).part(.deny))),
            Expect("no Run once on it") { _ in StoryElement(StoryID.Approval.card(stop).part(.allow)) == nil },
            Press(.id(StoryID.Approval.card(stop).part(.deny))),
            card(stop, false, "dismissed: gone"),
        ]
    }
}

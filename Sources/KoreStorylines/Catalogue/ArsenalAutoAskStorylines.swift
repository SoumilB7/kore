import Foundation
import KoreLink
import KoreUI
import src

/// Auto asks (the owner via Kore-main, 2026-11-19): an Auto chat's ask (Kore's ask list, a safety
/// check) is a card with Run once and Deny that only a person runs; another chat's agent may only
/// Deny it. A call Auto refused outright is a card that says why, with OK only. On Codex, Run
/// once is Codex's one retry of a reviewer's denial, and the idle chat is asked to try again. The
/// cards here are the ones `ClaudeTranslator`, `ClaudeAutoStops` and `CodexAutoStops` make: the
/// CLIs' frames are their unit tests'.
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

    private func card(_ id: String, _ there: Bool, _ what: String) -> Expect {
        Expect(what) { story in try AgentCast.of(story).chat("b").pendingApprovals.contains { $0.id == id } == there }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kaa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        let ask = codex ? CodexAutoStops.idPrefix + "rv1" : "r-hook"
        let stop = codex ? CodexAutoStops.idPrefix + "rv9" : ClaudeAutoStops.idPrefix + "t9"
        let title = codex ? "Auto stopped: curl -sI https://example.com (No authorization for network access.)" : "Auto asks: sudo reboot (Kore asks you first: sudo.)"
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

            // An ask: on screen with Run once; another chat's agent can't run it, only deny.
            raise(ask, title, retry: codex ? CodexAutoStops.retry("curl -sI https://example.com") : nil),
            WaitForElement(.id(StoryID.Approval.card(ask).part(.allow))),
            KoreAs(["pending", "{b}"], a, "kore pending lists it") { status, out, _ in status == 0 && out.contains(String(title.prefix(30))) },
            KoreAs(["answer", "{b}", ask, "--allow"], a, "an agent can't run it", status: 1, says: "Only you can run a command Auto asks about"),
            card(ask, true, "still asking"),
            KoreAs(["answer", "{b}", ask, "--deny"], a, "an agent may deny it", expect: ["Denied."]),
            card(ask, false, "denied: gone"),

            // The person's Run once.
            raise(ask, title, retry: codex ? CodexAutoStops.retry("curl -sI https://example.com") : nil),
            WaitForElement(.id(StoryID.Approval.card(ask).part(.allow))),
            Press(.id(StoryID.Approval.card(ask).part(.allow))),
            card(ask, false, "Run once: gone"),
        ] + (codex ? [
            // Codex: the idle chat is asked to try it again.
            TurnsDone("b", 2),
            Expect.rows("b asked to run it once") { rows in rows.contains { $0.kind == "user" && $0.text == "Run once: `curl -sI https://example.com`" } },
        ] : []) + [
            // Refused outright: the card says why, with OK only (no Run once).
            raise(stop, codex ? "Auto stopped: rm -rf ~ (critical)" : "Auto stopped: rm -rf ~ (a removal Auto never runs)",
                refusal: codex ? CodexAutoStops.criticalLine : ClaudeAutoStops.safetyLine),
            WaitForElement(.id(StoryID.Approval.card(stop).part(.deny))),
            Expect("no Run once on it") { _ in StoryElement(StoryID.Approval.card(stop).part(.allow)) == nil },
            Press(.id(StoryID.Approval.card(stop).part(.deny))),
            card(stop, false, "OK: gone"),
        ]
    }
}

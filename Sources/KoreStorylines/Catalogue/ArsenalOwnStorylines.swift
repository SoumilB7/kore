import Foundation
import KoreLink
import KoreUI

/// Arsenal's Own through the real `kore`: chosen in the tab's tiers popup, it changes the chat it
/// runs in as the composer would (model, effort, name, compact, the mode only downwards), says so in
/// the chat, and reaches no other chat. Back at Watch, none of it.
final class ArsenalOwn: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript {
        let efforts = ["low", "medium", "high"]
        return CLIScript(
            start: [.event(.controlsLoaded(ChatControls(
                models: [
                    ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: efforts),
                    ModelOption(id: "verse", name: "Verse", resolved: "verse", efforts: efforts),
                ], model: "haiku", effort: "medium", commands: [])))],
            turns: [CLIScript.reply("Ready.")])
    }

    /// Opens `role`'s tiers from the titlebar's icon and picks the row whose title starts with `prefix`.
    private struct PickTier: Step {
        let role: String
        let prefix: String
        var label: String { "\(role)'s tiers: \(prefix)" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            try await OpenArsenalTiers(role: role).run(story)
            let rows = StoryID.Options.rows
            guard let index = rows.firstIndex(where: { $0.title.hasPrefix(prefix) }), rows[index].enabled else {
                throw StoryFailure.expectation("an enabled “\(prefix)…” row in \(rows.map(\.title))")
            }
            try await Press(.id(StoryID.Options.item(index))).run(story)
        }
    }

    private func tier(_ wanted: ArsenalTier?, _ what: String) -> Expect {
        Expect("\(what): a \(wanted?.rawValue ?? "off")") { story in try AgentCast.of(story).chat("a").arsenal == wanted }
    }

    private func chat(_ what: String, _ check: @escaping @MainActor (Chat) -> Bool) -> Expect {
        Expect(what) { story in check(try AgentCast.of(story).chat("a")) }
    }

    private func said(_ line: String) -> Expect {
        Expect.rows("the chat says “\(line)”") { rows in rows.contains { $0.kind == "notice" && $0.text == line } }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kao-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socket = directory.appendingPathComponent(AgentChannel.socketName).path
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        let notCovered = "doesn't cover that"
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(true)
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
        ] + (codex ? [
            Do("a in Codex's Full access") { story in try AgentCast.of(story).chat("a").storySetMode("fullAccess") },
            chat("Full access") { $0.mode == "fullAccess" },
        ] : []) + [
            // Watch: reads, and changes nothing.
            Key(.cmdOption("k")),
            tier(.watch, "⌥⌘K"),
            KoreAs(["model", "verse"], a, "Watch can't switch the model", status: 5, says: notCovered),

            // Own, from the tiers popup: the chat's last tier from then on.
            PickTier(role: "a", prefix: "Own:"),
            tier(.own, "picked in the popup"),
            KoreAs(["whoami"], a, "whoami says Own", expect: ["{a}", "· own"]),
            KoreAs(["options"], a, "the choices", expect: ["haiku · Haiku", "(haiku, verse)", "(low, medium, high)"]),
            KoreAs(["model", "verse"], a, "the model", expect: ["Model Verse."]),
            chat("the composer has it") { $0.storyModel == "verse" },
            said("Arsenal · model Verse"),
            KoreAs(["model", "quill"], a, "a model the chat doesn't offer", status: 1, says: "This chat offers: haiku, verse"),
            KoreAs(["effort", "high"], a, "the effort", expect: ["Effort high."]),
            chat("effort high") { $0.storyEffort == "high" },
            KoreAs(["rename", "Own test"], a, "a new name", expect: ["Renamed."]),
            chat("the tab has it") { $0.storyTitle == "Own test" },
            KoreAs(["compact"], a, "compact, idle", expect: ["Compacting."]),

            // Only its own chat, and no name another open chat has; format characters dropped.
            CastChat("b"),
            KoreAs(["model", "{b}", "haiku"], a, "another chat", status: 5, says: "Own changes only this chat."),
            KoreAs(["rename", "{b.title}"], a, "b's name", status: 1, says: "Another open chat is named that."),
            KoreAs(["rename", "Own\u{202E} test 2"], a, "a bidi override dropped", expect: ["Renamed."]),
            chat("the name without it") { $0.storyTitle == "Own test 2" },

            // "Allow commands in Plan" on: Plan would approve commands by itself, so it's the user's.
            Do("the user turns on Allow commands in Plan for a") { story in try AgentCast.of(story).chat("a").storySetPlanAllow(true) },
            KoreAs(["mode", "plan"], a, "not to Plan while it allows commands", status: 1, says: "Allow commands in Plan"),
            chat("not planning") { !$0.storyPlanning },
            Do("and off again") { story in try AgentCast.of(story).chat("a").storySetPlanAllow(false) },
            KoreAs(["show", "{b}"], a, "still reads it") { status, _, _ in status == 0 },

            // Back to Watch: Own's commands go with it.
            PickTier(role: "a", prefix: "Watch:"),
            tier(.watch, "Watch again"),
            KoreAs(["effort", "low"], a, "Watch again can't", status: 5, says: notCovered),
            PickTier(role: "a", prefix: "Own:"),
            tier(.own, "Own again"),
        ] + (codex ? [
            // Codex: Own lowers the mode, and leaving Full access ends its access, after the answer.
            KoreAs(["mode", "approveForMe"], a, "lower, out of Full access", expect: ["Mode Approve for me.", "Kore access ends"]),
            chat("the mode is lower") { $0.mode == "approveForMe" },
            tier(nil, "out of Full access"),
            Expect("no socket") { _ in AgentChannel.current == nil && !FileManager.default.fileExists(atPath: socket) },
        ] : [
            // Claude: from Auto, not to Edit automatically, which accepts edits Auto would review.
            Do("the user puts a in Auto") { story in try AgentCast.of(story).chat("a").storySetMode("auto") },
            chat("Auto") { $0.mode == "auto" },
            KoreAs(["mode", "acceptEdits"], a, "Auto to Edit automatically is the user's", status: 1, says: "Auto would review"),
            chat("still Auto") { $0.mode == "auto" },
            Do("the user puts a back in Manual") { story in try AgentCast.of(story).chat("a").storySetMode("default") },
            // Down to Plan; never up.
            KoreAs(["mode", "acceptEdits"], a, "raising stays the user's", status: 1, says: "Only you can raise a chat's mode."),
            chat("the mode as it was") { $0.mode == "default" },
            KoreAs(["mode", "plan"], a, "lower, to Plan", expect: ["Mode Plan."]),
            chat("Plan") { $0.mode == "plan" },
            KoreAs(["mode", "default"], a, "back up isn't Own's", status: 1, says: "Only you can raise a chat's mode."),
        ])
    }
}

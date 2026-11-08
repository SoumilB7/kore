import Foundation
import KoreLink
import KoreUI

/// The Arsenal button end to end (`z-docs/design/arsenal-button.html`): the switch, the K on the tab,
/// `kore` through the real binary, last tier, stop all, and Codex's sandbox.
final class ArsenalButton: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    @MainActor private static func tab(_ role: String, _ story: StoryContext) throws -> UUID {
        let chat = try AgentCast.of(story).chat(role)
        guard let id = story.app.workspace?.tabs.first(where: { $0.chat === chat })?.id else {
            throw StoryFailure.modelMissing("\(role)'s tab")
        }
        return id
    }

    /// Clicks the K of `role`'s tab, under the pointer as it would be; `dim`: the K of a chat that
    /// can't have it. Each has an id of its own, so the click waits for the one wanted to draw.
    private struct ClickK: Step {
        let role: String
        var dim = false
        var label: String { "click the \(dim ? "dim " : "")K on \(role)'s tab" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            let tab = try ArsenalButton.tab(role, story)
            let k = Locator.id(dim ? StoryID.Tabs.arsenalUnavailable(tab) : StoryID.Tabs.arsenal(tab))
            try await ExpectHittable(k).run(story)
            try await Click(k).run(story)
        }
    }

    private struct NoK: Step {
        let role: String
        var label: String { "no K on \(role)'s tab, hovered" }

        @MainActor func run(_ story: StoryContext) async throws {
            try await ExpectElement(.id(StoryID.Tabs.arsenal(try ArsenalButton.tab(role, story))), .absent).run(story)
        }
    }

    private struct OpenTiers: Step {
        let role: String
        var label: String { "open \(role)'s tiers" }

        @MainActor func run(_ story: StoryContext) async throws {
            try await Click(.id(StoryID.Tabs.arsenalTiers(try ArsenalButton.tab(role, story)))).run(story)
        }
    }

    private struct Full: Step {
        let role: String
        var label: String { "\(role) in Codex's Full access" }

        @MainActor func run(_ story: StoryContext) async throws {
            let chat = try AgentCast.of(story).chat(role)
            chat.storySetMode("fullAccess")
            try await story.until("Full access") { chat.mode == "fullAccess" }
        }
    }

    /// Opens Account and flips "Let chats use Arsenal".
    private func flipSwitch() -> [any Step] {
        [
            Do("open Account") { story in try story.activeChat().storyOpenAccount() },
            Press(.id(StoryID.Composer.arsenalSwitch)),
            Key(.escape),
        ]
    }

    private func tier(_ role: String, _ wanted: ArsenalTier?, _ what: String) -> Expect {
        Expect("\(what): \(role) \(wanted?.rawValue ?? "off")") { story in try AgentCast.of(story).chat(role).arsenal == wanted }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kab-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socket = directory.appendingPathComponent(AgentChannel.socketName).path
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        func closed(_ what: String) -> Expect {
            Expect("\(what): no channel, no socket") { _ in AgentChannel.current == nil && !FileManager.default.fileExists(atPath: socket) }
        }
        let open = Expect("the socket") { _ in AgentChannel.current != nil && FileManager.default.fileExists(atPath: socket) }
        return super.steps() + [
            Do("a's chat, at a socket of this run's") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(false)
                Arsenal.shared.storyHover = true
            },
            SendTo("a", "hello"), TurnsDone("a", 1),

            // The switch off: no button, no socket, one dim row to the switch.
            NoK(role: "a"),
            closed("switch off"),
            KoreAs(["ls"], a, "switch off: nothing to reach", status: 5, says: "agent control is off"),
            Press(.id(StoryID.Composer.slash)),
            Press(.id(StoryID.Composer.command("arsenal"))),
            ExpectElement(.id(StoryID.Composer.arsenalSwitch)),
            Press(.id(StoryID.Composer.arsenalSwitch)),
            Key(.escape),
            Expect("the switch is on") { _ in Arsenal.shared.allowed },
            closed("switch on, no chat on"),
        ] + (codex ? [
            // Codex's default sandbox: the K says why, and nothing turns on.
            ClickK(role: "a", dim: true),
            ExpectElement(.id(StoryID.Options.panel)),
            Key(.escape),
            tier("a", nil, "default sandbox"),
            closed("default sandbox"),
            Full(role: "a"),
        ] : []) + [
            // One click on: Watch, and `kore` works through the real binary.
            ClickK(role: "a"),
            tier("a", .watch, "first click"),
            open,
            KoreAs(["whoami"], a, "whoami names the chat", expect: ["{a}", "· watch"]),
            KoreAs(["ls"], a, "ls lists it", expect: ["{a}"]),

            // One click off: follows end, the socket closes.
            StartFollower("f", ["log", ".", "-f"], a),
            ClickK(role: "a"),
            tier("a", nil, "second click"),
            Followed("f", "the follow ended", timeout: .seconds(5)) { _, status, _ in status != nil },
            closed("off"),
            KoreAs(["ls"], a, "off: nothing to reach", status: 5, says: "agent control is off"),

            // Last tier, and the popup: Watch can be chosen, what isn't built can't.
            ClickK(role: "a"),
            tier("a", .watch, "back on at its last tier"),
            OpenTiers(role: "a"),
            ExpectElement(.id(StoryID.Options.item(3))),
            Press(.id(StoryID.Options.item(3))),
            tier("a", .watch, "a tier not built does nothing"),
            Key(.escape),
            OpenTiers(role: "a"),
            Press(.id(StoryID.Options.item(0))),
            tier("a", nil, "Off in the popup"),
            closed("off in the popup"),
            ClickK(role: "a"),
            tier("a", .watch, "on again"),

            // Stop agent control: every chat off, the switch as it was.
            CastChat("b"),
        ] + (codex ? [Full(role: "b")] : []) + [
            ClickK(role: "b"),
            tier("b", .watch, "b on"),
            Do("Account, from the chat in front") { story in try story.activeChat().storyOpenAccount() },
            Press(.id(StoryID.Composer.arsenalStop)),
            Key(.escape),
            tier("a", nil, "stop all"), tier("b", nil, "stop all"),
            Expect("the switch is still on") { _ in Arsenal.shared.allowed },
            closed("stop all"),

            // The switch off clears every chat, and the K goes.
            ClickK(role: "a"), ClickK(role: "b"),
            tier("a", .watch, "on"), tier("b", .watch, "on"),
        ] + flipSwitch() + [
            tier("a", nil, "switch off"), tier("b", nil, "switch off"),
            closed("switch off again"),
            NoK(role: "b"),
        ] + (codex ? flipSwitch() + [
            // Leaving Full access ends it: the sandbox would refuse it anyway.
            ClickK(role: "b"),
            tier("b", .watch, "Full access"),
            Do("b back to the default sandbox") { story in try AgentCast.of(story).chat("b").storySetMode("askForApproval") },
            tier("b", nil, "left Full access"),
            closed("left Full access"),
        ] : [])
    }
}

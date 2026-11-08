import Foundation
import KoreLink
import KoreUI

/// Brings `role`'s tab to the front and clicks Arsenal's icon in the titlebar: the tiers open.
struct OpenArsenalTiers: Step {
    let role: String
    var label: String { "\(role)'s tiers, from the titlebar's icon" }
    var timeout: Duration? { .seconds(10) }

    @MainActor func run(_ story: StoryContext) async throws {
        try await story.idle()
        let chat = try AgentCast.of(story).chat(role)
        guard let workspace = story.app.workspace, let tab = workspace.tabs.first(where: { $0.chat === chat }) else {
            throw StoryFailure.modelMissing("\(role)'s tab")
        }
        if workspace.activeTab !== tab {
            try await Click(.id(StoryID.Tabs.tab(tab.id))).run(story)
            try await story.until("\(role) in front") { story.app.workspace?.activeTab.id == tab.id }
        }
        let icon = Locator.id(StoryID.Titlebar.arsenal)
        try await ExpectHittable(icon).run(story)
        try await Click(icon).run(story)
        try await WaitForElement(.id(StoryID.Options.panel)).run(story)
    }
}

/// The Arsenal button end to end (`z-docs/design/arsenal-button.html`): the tab's right-click and
/// ⌥⌘K turn it on (the switch too, the first time), the icon in the titlebar shows only while the
/// chat in front has it, and opens the tiers, Off and Stop agent control; `kore` through the real
/// binary, last tier, stop all, the switch, and Codex's sandbox. "/" and the tabs have none of it.
final class ArsenalButton: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }
    private static let note = "notes.md"

    @MainActor private static func tab(_ role: String, _ story: StoryContext) throws -> UUID {
        let chat = try AgentCast.of(story).chat(role)
        guard let id = story.app.workspace?.tabs.first(where: { $0.chat === chat })?.id else {
            throw StoryFailure.modelMissing("\(role)'s tab")
        }
        return id
    }

    /// Right-clicks `role`'s tab and finds its Arsenal row, worded `title`; `choose`: clicks it, else
    /// expects it dim and closes the popup.
    private struct TabRow: Step {
        let role: String
        let title: String
        var choose = true
        var label: String { "right-click \(role)'s tab: “\(title)”" + (choose ? "" : ", dim") }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            try await RightClick(.id(StoryID.Tabs.tab(try ArsenalButton.tab(role, story)))).run(story)
            try await WaitForElement(.id(StoryID.Options.panel)).run(story)
            let rows = StoryID.Options.rows
            guard let index = rows.firstIndex(where: { $0.title.hasPrefix("Arsenal") }) else {
                throw StoryFailure.expectation("an Arsenal row in \(rows.map(\.title))")
            }
            guard rows[index].title == title, rows[index].enabled == choose else {
                throw StoryFailure.expectation("“\(title)”\(choose ? "" : ", dim"); found “\(rows[index].title)”, enabled \(rows[index].enabled)")
            }
            if choose { try await Press(.id(StoryID.Options.item(index))).run(story) } else { try await Key(.escape).run(story) }
        }
    }

    /// `role`'s tab in front (as ⌘ and its number would; a click on a chat tab is `OpenArsenalTiers`'s).
    private struct Front: Step {
        let role: String
        var label: String { "\(role)'s tab in front" }

        @MainActor func run(_ story: StoryContext) async throws {
            let tab = try ArsenalButton.tab(role, story)
            if let workspace = story.app.workspace, let index = workspace.tabs.firstIndex(where: { $0.id == tab }) {
                workspace.storySelect(tabAt: index)
            }
            try await story.until("\(role) in front") { story.app.workspace?.activeTab.id == tab }
        }
    }

    /// Presses the open popup's row titled `title`, found by its title.
    private struct PressRow: Step {
        let title: String
        var label: String { "press “\(title)”" }

        @MainActor func run(_ story: StoryContext) async throws {
            guard let index = StoryID.Options.rows.firstIndex(where: { $0.title == title }) else {
                throw StoryFailure.expectation("a “\(title)” row in \(StoryID.Options.rows.map(\.title))")
            }
            try await Press(.id(StoryID.Options.item(index))).run(story)
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
        let key = Key(.cmdOption("k"))
        func closed(_ what: String) -> Expect {
            Expect("\(what): no channel, no socket") { _ in AgentChannel.current == nil && !FileManager.default.fileExists(atPath: socket) }
        }
        let open = Expect("the socket") { _ in AgentChannel.current != nil && FileManager.default.fileExists(atPath: socket) }
        let icon = ExpectElement(.id(StoryID.Titlebar.arsenal))
        let noIcon = ExpectElement(.id(StoryID.Titlebar.arsenal), .absent)
        return [WriteFiles([(Self.note, "A file tab.\n")])] + super.steps() + [
            Do("a's chat, at a socket of this run's") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(false)
            },
            SendTo("a", "hello"), TurnsDone("a", 1),

            // The switch off: no icon, no socket; "/" has no Arsenal.
            noIcon,
            closed("switch off"),
            KoreAs(["ls"], a, "switch off: nothing to reach", status: 5, says: "agent control is off"),
            Press(.id(StoryID.Composer.slash)),
            ExpectElement(.id(StoryID.Composer.command("account"))),
            ExpectElement(.id(StoryID.Composer.command("arsenal")), .absent),
            Key(.escape),
        ] + (codex ? [
            // Codex's default sandbox: the row is dim and says why; nothing turns on, the switch stays off.
            TabRow(role: "a", title: "Arsenal · Codex needs Full access", choose: false),
            key,
            tier("a", nil, "default sandbox"),
            Expect("the switch is still off") { _ in !Arsenal.shared.allowed },
            closed("default sandbox"),
            Full(role: "a"),
        ] : []) + [
            // The right-click, with the switch off: the switch on and Watch, said once in the chat.
            TabRow(role: "a", title: "Arsenal"),
            Expect("the switch is on") { _ in Arsenal.shared.allowed },
            tier("a", .watch, "right-click"),
            Expect.rows("the chat says so once") { rows in rows.filter { $0.kind == "notice" && $0.text.hasPrefix("Chats can use Arsenal") }.count == 1 },
            open,
            icon,
            Snapshot("titlebar-arsenal-watch"),
            KoreAs(["whoami"], a, "whoami names the chat", expect: ["{a}", "· watch"]),
            KoreAs(["ls"], a, "ls lists it", expect: ["{a}"]),

            // The right-click again: off, follows end, the socket closes.
            StartFollower("f", ["log", ".", "-f"], a),
            TabRow(role: "a", title: "Arsenal · Watch"),
            tier("a", nil, "right-click again"),
            Followed("f", "the follow ended", timeout: .seconds(5)) { _, status, _ in status != nil },
            closed("off"),
            KoreAs(["ls"], a, "off: nothing to reach", status: 5, says: "agent control is off"),

            // ⌥⌘K: the chat in front, on and off; the icon's Off turns it off too.
            noIcon,
            key,
            tier("a", .watch, "⌥⌘K"),
            icon,
            key,
            tier("a", nil, "⌥⌘K again"),
            noIcon,
            key,
            OpenArsenalTiers(role: "a"),
            PressRow(title: "Off"),
            tier("a", nil, "Off from the icon"),
            noIcon,

            // Last tier, and the popup: Watch can be chosen, what isn't built can't.
            key,
            tier("a", .watch, "back on at its last tier"),
            // A file in front: no icon; a again: the icon.
        ] + FileTabState.open(Self.note) + [
            noIcon,
            Front(role: "a"),
            icon,
            OpenArsenalTiers(role: "a"),
            Expect("the popup: Off, the tiers, Stop agent control") { _ in
                let rows = StoryID.Options.rows.map(\.title)
                return rows.first == "Off" && rows.contains { $0.hasPrefix("Watch:") } && rows.last == "Stop agent control"
            },
            PressRow(title: "Full: not built yet"),
            tier("a", .watch, "a tier not built does nothing"),
            Key(.escape),
            OpenArsenalTiers(role: "a"),
            Press(.id(StoryID.Options.item(0))),
            tier("a", nil, "Off in the popup"),
            closed("off in the popup"),
            key,
            tier("a", .watch, "on again"),

            // Stop agent control: every chat off, the switch as it was.
            CastChat("b"),
        ] + (codex ? [Full(role: "b")] : []) + [
            key,
            tier("b", .watch, "⌥⌘K on b, in front"),
            tier("a", .watch, "a as it was"),
            OpenArsenalTiers(role: "b"),
            PressRow(title: "Stop agent control"),
            tier("a", nil, "stop all from the icon"), tier("b", nil, "stop all from the icon"),
            Expect("the switch stays on") { _ in Arsenal.shared.allowed },
            closed("stop all from the icon"),
            noIcon,
            key, Front(role: "a"), key,
            tier("a", .watch, "on for Account's stop"), tier("b", .watch, "on for Account's stop"),
            Do("Account, from the chat in front") { story in try story.activeChat().storyOpenAccount() },
            Press(.id(StoryID.Composer.arsenalStop)),
            Key(.escape),
            tier("a", nil, "stop all"), tier("b", nil, "stop all"),
            Expect("the switch is still on") { _ in Arsenal.shared.allowed },
            closed("stop all"),

            // The switch off clears every chat, and the icon goes.
            key, Front(role: "b"), key,
            tier("a", .watch, "on"), tier("b", .watch, "on"),
        ] + flipSwitch() + [
            tier("a", nil, "switch off"), tier("b", nil, "switch off"),
            closed("switch off again"),
            noIcon,
        ] + (codex ? [
            // Leaving Full access ends it: the sandbox would refuse it anyway.
            TabRow(role: "b", title: "Arsenal"),
            tier("b", .watch, "Full access"),
            Do("b back to the default sandbox") { story in try AgentCast.of(story).chat("b").storySetMode("askForApproval") },
            tier("b", nil, "left Full access"),
            closed("left Full access"),
        ] : [])
    }
}

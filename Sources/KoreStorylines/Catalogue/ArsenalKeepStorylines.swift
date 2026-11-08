import Foundation
import KoreLink
import KoreUI
import src

/// A chat's Arsenal tier is kept across closing it and coming back (the owner, 2026-11-15): its tab
/// reopened is a new chat for the same session, as a restart's is, and it's on again at the tier it
/// had, with the socket. The user's Off, and Stop agent control, forget it.
final class ArsenalKeep: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    /// `role`'s tab in front, then closed with ⌘W.
    private struct CloseTab: Step {
        let role: String
        var label: String { "close \(role)'s tab" }

        @MainActor func run(_ story: StoryContext) async throws {
            let chat = try AgentCast.of(story).chat(role)
            guard let workspace = story.app.workspace, let tab = workspace.tabs.first(where: { $0.chat === chat }) else {
                throw StoryFailure.modelMissing("\(role)'s tab")
            }
            workspace.linkSelect(tab)
            try await Command(.closeTab).run(story)
            try await story.until("\(role)'s tab closed") { !workspace.tabs.contains { $0.chat === chat } }
        }
    }

    /// ⇧⌘T: the closed tab back, a new chat for its session, cast as `role`.
    private struct Reopen: Step {
        let role: String
        var label: String { "reopen \(role)'s tab" }

        @MainActor func run(_ story: StoryContext) async throws {
            let cast = AgentCast.of(story)
            let session = try cast.chat(role).sessionId
            guard let workspace = story.app.workspace, workspace.can(.reopenClosedTab) else { throw StoryFailure.expectation("a tab to reopen") }
            workspace.perform(.reopenClosedTab)
            try await story.until("\(role)'s session back") { story.app.chat?.sessionId == session && story.app.chat !== (try? cast.chat(role)) }
            cast.chats[role] = try story.activeChat()
        }
    }

    private func tier(_ wanted: ArsenalTier?, _ what: String) -> Expect {
        Expect("\(what): a \(wanted?.rawValue ?? "off")", timeout: .seconds(10)) { story in try AgentCast.of(story).chat("a").arsenal == wanted }
    }

    private func kept(_ wanted: ArsenalTier?, _ what: String) -> Expect {
        Expect("\(what): kept \(wanted?.rawValue ?? "none")") { story in ArsenalMemory.tier(try AgentCast.of(story).chat("a")) == wanted }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kak-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let open = Expect("the socket") { _ in AgentChannel.current != nil }
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed, nothing kept") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                ArsenalMemory.clear()
                Arsenal.shared.setAllowed(true)
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
        ] + (codex ? [
            Do("a in Codex's Full access") { story in try AgentCast.of(story).chat("a").storySetMode("fullAccess") },
            Expect("Full access") { story in try AgentCast.of(story).chat("a").mode == "fullAccess" },
        ] : []) + [
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            tier(.drive, "chosen"),
            kept(.drive, "chosen"),
            CastChat("b"),

            // Closed and back: on at the tier it had, as after a restart.
            CloseTab(role: "a"),
            kept(.drive, "closed"),
            Reopen(role: "a"),
        ] + (codex ? [
            // A Codex chat back in another mode can't have it: it waits, and comes back with Full
            // access, which only the user gives (Kore doesn't raise a mode).
            Expect("Codex: waiting for Full access") { story in
                let a = try AgentCast.of(story).chat("a")
                return a.mode == "fullAccess" ? a.arsenal == .drive : a.arsenal == nil && a.arsenalWaiting
            },
            Do("the user puts a in Full access") { story in try AgentCast.of(story).chat("a").storySetMode("fullAccess") },
        ] : []) + [
            tier(.drive, "reopened"),
            open,
            Expect("its grant, under the new chat") { story in try AgentGrants.tier(chat: AgentCast.of(story).id("a")) == .drive },

            // The user's Off forgets it.
            Do("the user turns a off") { story in Arsenal.shared.turnOff(try AgentCast.of(story).chat("a")) },
            kept(nil, "off"),
            CloseTab(role: "a"),
            Reopen(role: "a"),
            tier(nil, "reopened after Off"),

            // Stop agent control forgets every chat's.
            Do("a at Read (Codex: in Full access first)") { story in
                let a = try AgentCast.of(story).chat("a")
                if codex { a.storySetMode("fullAccess") }
                Arsenal.shared.choose(.watch, a)
            },
            kept(.watch, "Read"),
            Do("Stop agent control") { _ in Arsenal.shared.stopAll() },
            kept(nil, "stopped"),
            CloseTab(role: "a"),
            Reopen(role: "a"),
            tier(nil, "reopened after Stop agent control"),
        ]
    }
}

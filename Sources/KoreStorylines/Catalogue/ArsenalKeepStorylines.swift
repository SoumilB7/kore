import Foundation
import KoreLink
import KoreUI
import src

/// A chat's Arsenal tier is kept across closing it and coming back (the owner, 2026-11-15): its tab
/// reopened is a new chat for the same session, as a restart's is, and it's on again at the tier it
/// had, with the socket; so after Kore quits and launches again, the switch read back from its
/// defaults. The user's Off, and Stop agent control, forget it.
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

    /// Kore quit and launched again, in this process: the window saved and closed, the grants (and
    /// so the socket) and the switch let go from memory, the switch read back from the defaults as
    /// a launch reads it (`AgentGrants.install`), then the window opened from what it saved.
    private struct Relaunched: Step {
        var label: String { "Kore relaunched" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            let cast = AgentCast.of(story)
            let a = try cast.chat("a")
            let session = a.sessionId
            // The relaunched window's first history read drops a restored tab, or a closed tab's
            // recovery, whose session its CLI doesn't list (deleted elsewhere). The scripted CLI
            // lists only forks: a's session, said in, as the CLI's own list would have it.
            if let session { ScriptedWorld.shared.list(session, provider: a.provider.id, folder: a.folder, title: "hello") }
            guard let workspace = story.app.workspace, let window = story.window else { throw StoryFailure.modelMissing("the window") }
            let folder = story.folder
            let saved = try workspace.storySaved()
            window.close()
            try await story.until("the window closed") { story.app.workspace?.window?.isVisible != true }
            AgentGrants.stopAll()
            Arsenal.shared.adopt(allowed: false)
            AgentGrants.install()
            guard Arsenal.shared.allowed else { throw StoryFailure.expectation("the switch read back on") }
            guard Workspace.storyRestore(folder: folder, saved: saved) else { throw StoryFailure.other("the folder's window is still open") }
            try await OpenFolder().run(story)
            try await story.until("a's session back") {
                story.app.workspace !== workspace && story.window?.isVisible == true
                    && story.app.workspace?.tabs.contains { $0.chat?.sessionId == session } == true
            }
            guard let now = story.app.workspace, let tab = now.tabs.first(where: { $0.chat?.sessionId == session }) else { return }
            now.linkSelect(tab)
            cast.chats["a"] = tab.chat
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

            // Kore quit and launched again (a reinstall's restart): the switch comes back from the
            // defaults, and with it the tier and the socket.
            Relaunched(),
        ] + (codex ? [
            Expect("Codex: on, or waiting for Full access") { story in
                let a = try AgentCast.of(story).chat("a")
                return a.mode == "fullAccess" ? a.arsenal == .drive : a.arsenal == nil && a.arsenalWaiting
            },
            Do("the user puts a in Full access") { story in try AgentCast.of(story).chat("a").storySetMode("fullAccess") },
        ] : []) + [
            tier(.drive, "relaunched"),
            kept(.drive, "relaunched"),
            open,
            Expect("its grant, under the relaunched chat") { story in try AgentGrants.tier(chat: AgentCast.of(story).id("a")) == .drive },

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

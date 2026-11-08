import Foundation
import KoreLink
import KoreUI
import src

/// Act unlimited opens a past chat as History opens it (`kore open`): in a tab of its own, in front,
/// its Arsenal off; one already open comes to the front. History lists another open folder's past
/// chats at Act unlimited, and only the caller's own at Read (the owner, 2026-11-15).
final class ArsenalOpen: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    @MainActor private final class Past { var session = "" }

    /// `kore <arguments>` as a, with b's past session's start where `{session}` stands.
    private struct AsA: Step {
        let arguments: [String]
        let what: String
        /// Its exit status, its output and the session's start.
        let check: @MainActor (Int32, String, String) -> Bool
        var label: String { "kore \(arguments.joined(separator: " ")) (in a): \(what)" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            let session = String(story.stash(Past.self) { Past() }.session.prefix(8))
            let check = self.check
            try await KoreAs(arguments.map { $0.replacingOccurrences(of: "{session}", with: session) }, .chat("a"), what) { status, out, _ in
                check(status, out, session)
            }.run(story)
        }
    }

    /// The History popover's reread of the folder's chats.
    private struct Reread: Step {
        var label: String { "History reread" }
        @MainActor func run(_ story: StoryContext) async throws { await story.app.workspace?.storyRefreshHistory() }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kao-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
            SendTo("a", "hello"), TurnsDone("a", 1),
        ] + (codex ? [Do("a in Codex's Full access") { story in try AgentCast.of(story).chat("a").storySetMode("fullAccess") }] : []) + [
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            Expect("a at Act unlimited") { story in try AgentCast.of(story).chat("a").arsenal == .drive },

            // b: a chat said something in, then closed: a past chat of the folder.
            CastChat("b"), SendTo("b", "plans"), TurnsDone("b", 1),
            Do("b's session, and b closed") { story in
                let b = try AgentCast.of(story).chat("b")
                let session = b.sessionId ?? ""
                story.stash(Past.self) { Past() }.session = session
                // The scripted CLI lists only forks: b's session, as the CLI's own list would have it.
                ScriptedWorld.shared.list(session, provider: b.provider.id, folder: b.folder, title: "plans")
                guard let workspace = story.app.workspace, let tab = workspace.tabs.first(where: { $0.chat === b }) else { throw StoryFailure.modelMissing("b's tab") }
                workspace.linkSelect(tab)
            },
            Command(.closeTab),
            Expect("b closed") { story in !(story.app.workspace?.tabs.contains { $0.chat === (try? AgentCast.of(story).chat("b")) } ?? true) },
            Reread(),
            AsA(arguments: ["history"], what: "lists b's session by its start") { status, out, session in status == 0 && session.count == 8 && out.contains(session) },

            // Opened: its own tab, in front, the same session, Arsenal off.
            AsA(arguments: ["open", "{session}"], what: "opens b") { status, out, _ in status == 0 && out.contains("Opened") },
            Expect("b's session in front, Arsenal off") { story in
                let shown = try story.activeChat()
                let closed = try AgentCast.of(story).chat("b")
                return shown.sessionId == story.stash(Past.self) { Past() }.session && shown.arsenal == nil && shown !== closed
            },
            AsA(arguments: ["open", "{session}"], what: "open again: in front, no new tab") { status, out, _ in status == 0 && out.contains("It was open") },
            AsA(arguments: ["open", "zzzzzzzz"], what: "no such session") { status, out, _ in status == 1 && out.contains("has that id") },

            // Another folder's past chats: at Act unlimited, a folder a window has open.
            AsA(arguments: ["history", "--folder", "/tmp/no-window-\(UUID().uuidString.prefix(6))"], what: "a folder no window has") { status, out, _ in
                status == 1 && out.contains("No Kore window has that folder open")
            },
            Do("a at Read") { story in Arsenal.shared.choose(.watch, try AgentCast.of(story).chat("a")) },
            AsA(arguments: ["history", "--folder", "/tmp"], what: "Read: only its own folder") { status, out, _ in status == 1 && out.contains("need Act unlimited") },
            AsA(arguments: ["open", "{session}"], what: "Read can't open") { status, _, _ in status == 5 },
        ]
    }
}

import Foundation
import KoreCore
import KoreLink
import KoreUI
import src

/// Act unlimited closes a chat as its tab's close does (`kore_close`, the owner, 2026-11-17): a past
/// chat opened, then closed by its short id, is gone from the tabs and back in History. A title
/// never closes one, even the only chat with it: refused with the ids to pick from. A chat never
/// closes itself.
final class ArsenalClose: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    @MainActor private final class Past {
        var session = ""
        /// The opened chat's short id.
        var short = ""
    }

    /// `kore <arguments>` as a, `{session}` and `{short}` filled in when it runs.
    private struct AsA: Step {
        let arguments: [String]
        let what: String
        var mcp: [String] = []
        let check: @MainActor (Int32, String, Past) -> Bool
        var label: String { "kore \(arguments.joined(separator: " ")) (in a): \(what)" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            let past = story.stash(Past.self) { Past() }
            let fill = { (text: String) in
                text.replacingOccurrences(of: "{session}", with: String(past.session.prefix(8))).replacingOccurrences(of: "{short}", with: past.short)
            }
            let check = self.check
            var step = KoreAs(arguments.map(fill), .chat("a"), what, input: mcp.isEmpty ? nil : mcp.map(fill).joined(separator: "\n") + "\n") { status, out, _ in
                check(status, out, past)
            }
            if !mcp.isEmpty { step.executable = KoreReach.pathFolder.map { URL(fileURLWithPath: $0).appendingPathComponent("kore") } }
            try await step.run(story)
        }
    }

    /// The History popover's reread of the folder's chats.
    private struct Reread: Step {
        var label: String { "History reread" }
        @MainActor func run(_ story: StoryContext) async throws { await story.app.workspace?.storyRefreshHistory() }
    }

    private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

    /// `kore_close` over `kore mcp`: its reply's text and whether it's an error.
    private static func close(_ chat: String, _ what: String, _ check: @escaping @MainActor (String, Bool, Past) -> Bool) -> AsA {
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"kore_close","arguments":{"chat":"\#(chat)"}}}"#
        return AsA(arguments: ["mcp"], what: what, mcp: [initialize, call]) { status, out, past in
            let reply = AgentJSON.objects(out).first { $0["id"] as? Int == 2 }
            let content = AgentJSON.path(reply, "result", "content") as? [[String: Any]]
            let text = content?.first?["text"] as? String ?? ""
            return status == 0 && check(text, AgentJSON.path(reply, "result", "isError") as? Bool ?? true, past)
        }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kac-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

            // b: a chat said something in, then closed by the user: a past chat of the folder.
            CastChat("b"), SendTo("b", "plans"), TurnsDone("b", 1),
            Do("b's session, and b closed") { story in
                let b = try AgentCast.of(story).chat("b")
                story.stash(Past.self) { Past() }.session = b.sessionId ?? ""
                // The scripted CLI lists only forks: b's session, as the CLI's own list would have it.
                ScriptedWorld.shared.list(b.sessionId ?? "", provider: b.provider.id, folder: b.folder, title: "plans")
                guard let workspace = story.app.workspace, let tab = workspace.tabs.first(where: { $0.chat === b }) else { throw StoryFailure.modelMissing("b's tab") }
                workspace.linkSelect(tab)
            },
            Command(.closeTab),
            Reread(),

            // Opened again, in front: then closed by an agent.
            AsA(arguments: ["open", "{session}"], what: "opens b") { status, out, _ in status == 0 && out.contains("Opened") },
            Do("the opened chat's short id") { story in
                let shown = try story.activeChat()
                story.stash(Past.self) { Past() }.short = String(shown.id.uuidString.prefix(8)).lowercased()
            },
            Self.close("plans", "by its title: refused, with its id") { text, error, past in
                error && text.contains("never a title") && text.contains(past.short)
            },
            Expect("still open") { story in
                let session = story.stash(Past.self) { Past() }.session
                return story.app.workspace?.tabs.contains { $0.chat?.sessionId == session } == true
            },
            AsA(arguments: ["close", "."], what: "itself: refused") { status, out, _ in status == 1 && out.contains("never closes itself") },
            Self.close("{short}", "by its short id: closed") { text, error, past in
                !error && text.contains("Closed “plans”") && text.contains("kore open \(past.session.prefix(8).lowercased())")
            },
            Expect("gone from the tabs") { story in
                let session = story.stash(Past.self) { Past() }.session
                return story.app.workspace?.tabs.contains { $0.chat?.sessionId == session } == false
            },
            Reread(),
            AsA(arguments: ["history"], what: "back in History, not open") { status, out, past in
                let line = out.split(separator: "\n").first { $0.contains(past.session.prefix(8)) }
                return status == 0 && line != nil && line?.contains("(open)") == false
            },
            AsA(arguments: ["close", "{short}"], what: "closed already: no such chat") { status, out, _ in status == 1 && out.contains("No open chat has the id") },
        ]
    }
}

import Foundation
import KoreCore
import KoreLink
import KoreUI
import src

/// Tab groups as an Arsenal ability (the owner via Kore-main, 2026-11-24), through `kore mcp` as a
/// chat's agent calls it: two chats opened silently into one group stay behind the caller's tab;
/// kore_list_chats shows the group in the window's view; kore_arrange's show takes one out of the
/// group and puts it in front; ungroup leaves the tabs where they are.
final class ArsenalTabGroups: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    /// The new chats' short ids, as kore_new_chat answered them.
    final class Made: @unchecked Sendable { var ids: [String] = [] }

    /// `kore mcp` under chat a, its lines made when the step runs (they name chats made before it).
    struct MCP: Step {
        let what: String
        let lines: @MainActor () -> [String]
        let check: @MainActor ([Int: [String: Any]], StoryContext) throws -> Bool
        var label: String { "kore mcp (a): \(what)" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            var step = KoreAs(["mcp"], .chat("a"), what, input: ([ArsenalReach.initialize] + lines()).joined(separator: "\n") + "\n") { status, out, story in
                let replies = Dictionary(AgentJSON.objects(out).compactMap { o in (o["id"] as? Int).map { ($0, o) } }) { a, _ in a }
                return try status == 0 && check(replies, story)
            }
            step.executable = KoreReach.pathFolder.map { URL(fileURLWithPath: $0).appendingPathComponent("kore") }
            try await step.run(story)
        }
    }

    private static func data(_ reply: [String: Any]?) -> [String: Any] {
        AgentJSON.objects(ArsenalReach.text(reply).text).first ?? [:]
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/katg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let made = Made()
        let tab = { (story: StoryContext, short: String) in story.app.workspace?.tabs.first { $0.chat.map { String($0.id.uuidString.prefix(8)).lowercased() } == short } }
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal at Act unlimited") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                let a = try story.activeChat()
                cast.chats["a"] = a
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(true)
                a.storySetMode(codex ? "fullAccess" : "default")
                Arsenal.shared.choose(.drive, a)
            },
            SendTo("a", "hello"), TurnsDone("a", 1),

            // Two silent chats into one group: the caller's tab stays in front.
            MCP(what: "two silent chats in group Workers", lines: {
                [ArsenalReach.call(2, "kore_new_chat", #"{"silent":true,"group":"Workers"}"#), ArsenalReach.call(3, "kore_new_chat", #"{"silent":true,"group":"Workers"}"#)]
            }) { replies, _ in
                let answers = [Self.data(replies[2]), Self.data(replies[3])]
                made.ids = answers.compactMap { $0["short"] as? String }
                return made.ids.count == 2 && answers.allSatisfy { ($0["message"] as? String)?.hasSuffix("In group “Workers”.") == true }
            },
            Expect("a still in front; the two in Workers, its chip in the strip") { story in
                guard let w = story.app.workspace, let group = w.tabGroups.groups.first else { return false }
                return try w.activeTab.chat === AgentCast.of(story).chat("a") && w.members(of: group.id).count == 2
                    && StoryElement(StoryID.TabGroups.chip(group.id)) != nil
            },
            Snapshot("silent-in-group"),

            // Listed: the window's view has the group, by a.
            MCP(what: "kore_list_chats shows the group", lines: { [ArsenalReach.call(2, "kore_list_chats", "{}")] }) { replies, _ in
                let windows = Self.data(replies[2])["windows"] as? [[String: Any]] ?? []
                guard let here = windows.first(where: { $0["here"] as? Bool == true }), let group = (here["groups"] as? [[String: Any]])?.first else { return false }
                return group["name"] as? String == "Workers" && group["tabs"] as? [String] == made.ids && (here["tabs"] as? [String])?.count == 3
            },

            // Shown: out of the group, in front; the answer is the strip's order.
            MCP(what: "show the second one", lines: { [ArsenalReach.call(2, "kore_arrange", #"{"tabs":["\#(made.ids[1])"],"show":true}"#)] }) { replies, _ in
                let said = ArsenalReach.text(replies[2])
                return !said.error && said.text.contains("*\(made.ids[1])") && said.text.contains("[Workers: \(made.ids[0])]")
            },
            Expect("the second in front, out of Workers") { story in
                guard let w = story.app.workspace, let shown = tab(story, made.ids[1]) else { return false }
                return w.activeTab === shown && w.tabGroups.group(of: shown.id) == nil
            },
            Snapshot("shown-out-of-group"),

            // Ungrouped: the tabs stay where they are, the chip goes.
            MCP(what: "ungroup Workers", lines: { [ArsenalReach.call(2, "kore_arrange", #"{"group":"Workers","ungroup":true}"#)] }) { replies, _ in
                let said = ArsenalReach.text(replies[2])
                return !said.error && !said.text.contains("[")
            },
            Expect("no groups, three tabs") { story in
                guard let w = story.app.workspace else { return false }
                return w.tabGroups.isEmpty && w.tabs.count == 3
            },
        ]
    }
}

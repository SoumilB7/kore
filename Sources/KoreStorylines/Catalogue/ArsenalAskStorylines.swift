import Foundation
import KoreLink
import KoreUI
import src

/// Chat to chat (the owner, 2026-11-17, `z-docs/design/arsenal-ask.html`): a asks b by its id; the
/// question reaches b as its next message, marked "From a · Arsenal", with Kore's note on how to
/// answer that only b's agent reads. While b answers it asks no one (one hop). b answers with a
/// file from its folder; a's wait gets the answer and the file in a's `.kore/inbox/`, and both
/// chats show one quiet line. a fetches a file the same way (a taken name gets " 2"); a secret,
/// a folder no window has, a title, and a chat below Act unlimited are refused with a line.
final class ArsenalAsk: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [
            // Each chat's own turns, in order: hello, the first ask, "list it" (a card), the second ask.
            CLIScript.reply("Ready."), CLIScript.reply("Looking."),
            [.startTurn, .approval(AgentChannelAll.card, allow: Beat.answer("Listed."), deny: []), .finishTurn(.completed)],
            CLIScript.reply("OK."),
        ])
    }

    @MainActor private final class Past { var ask = "" }

    /// `kore <arguments>` as `role`, with the ask's id where `{ask}` stands.
    private struct As: Step {
        let role: String
        let arguments: [String]
        let what: String
        let check: @MainActor (Int32, String) -> Bool
        var label: String { "kore \(arguments.joined(separator: " ")) (in \(role)): \(what)" }
        var timeout: Duration? { .seconds(30) }

        @MainActor func run(_ story: StoryContext) async throws {
            let ask = story.stash(Past.self) { Past() }.ask
            let check = self.check
            try await KoreAs(arguments.map { $0.replacingOccurrences(of: "{ask}", with: ask) }, .chat(role), what) { status, out, _ in
                check(status, out)
            }.run(story)
        }
    }

    private func rows(_ role: String, _ what: String, _ check: @escaping @MainActor ([(kind: String, text: String)]) -> Bool) -> Expect {
        Expect(what, timeout: .seconds(15)) { story in check(try AgentCast.of(story).chat(role).rows.map { ($0.kind, $0.text) }) }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kak-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let question = "Which migration added the users table?"
        let answer = "0007_users.sql creates users and moves the old accounts rows into it."
        let inbox = { (story: StoryContext) in story.folder.appendingPathComponent(".kore/inbox").path }
        let full = { (role: String) -> [any Step] in
            codex ? [Do("\(role) in Codex's Full access") { story in try AgentCast.of(story).chat(role).storySetMode("fullAccess") }] : []
        }
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed; the folder's files") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                ArsenalMemory.clear()
                ArsenalAsks.shared.reset()
                Arsenal.shared.setAllowed(true)
                let db = story.folder.appendingPathComponent("db")
                try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
                try Data("create table users (id int);".utf8).write(to: db.appendingPathComponent("0007_users.sql"))
                try Data("KEY=1".utf8).write(to: story.folder.appendingPathComponent(".env"))
                try? FileManager.default.removeItem(atPath: inbox(story))
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
        ] + full("a") + [
            Do("a at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("a")) },
            CastChat("b"), SendTo("b", "hello"), TurnsDone("b", 1),
        ] + full("b") + [
            // Refused, each with a line in a's chat.
            As(role: "a", arguments: ["ask", "{b}", question], what: "b below Act unlimited") { status, out in status == 1 && out.contains("isn't Act unlimited") },
            Do("b at Act unlimited") { story in Arsenal.shared.choose(.drive, try AgentCast.of(story).chat("b")) },
            As(role: "a", arguments: ["ask", "hello", question], what: "by a title (both chats have it)") { status, out in
                status == 1 && out.contains("never a title")
            },
            As(role: "a", arguments: ["ask", ".", question], what: "itself") { status, out in status == 1 && out.contains("doesn't ask itself") },
            rows("a", "a's lines say why") { rows in
                rows.contains { $0.kind == "notice" && $0.text.hasPrefix("⊘ Not asked:") && $0.text.contains("isn't Act unlimited") }
                    && rows.contains { $0.kind == "notice" && $0.text.contains("never a title") }
            },

            // Asked: b's next message, with who asked and Kore's note for its agent.
            As(role: "a", arguments: ["ask", "{b}", question], what: "asks b") { status, out in status == 0 && out.contains("Asked") },
            Do("the ask's id") { story in
                story.stash(Past.self) { Past() }.ask = ArsenalAsks.shared.asks.values.first { $0.open }?.id ?? ""
            },
            rows("a", "a: Asked b") { rows in rows.contains { $0.kind == "notice" && $0.text.hasPrefix("→ Asked") && $0.text.hasSuffix(question) } },
            TurnsDone("b", 2),
            rows("b", "b: from a, then the question") { rows in
                rows.contains { $0.kind == "notice" && $0.text.hasPrefix("From ") && $0.text.hasSuffix(" · Arsenal") }
                    && rows.contains { $0.kind == "user" && $0.text == question }
            },
            Expect("b's agent read how to answer, with the ask's id") { story in
                let b = try AgentCast.of(story).chat("b")
                let ask = story.stash(Past.self) { Past() }.ask
                let notes = ScriptedWorld.shared.backend(session: b.sessionId)?.log.compactMap { call -> String? in
                    if case .note(let note) = call { note } else { nil }
                } ?? []
                return !ask.isEmpty && notes.contains { $0.contains("Arsenal ask from the chat") && $0.contains("ask \(ask)") }
            },

            // One hop: b, answering, asks no one.
            As(role: "b", arguments: ["ask", "{a}", "and you?"], what: "b asks back while answering") { status, out in status == 1 && out.contains("one hop") },

            // The answer, with a file from b's folder.
            As(role: "b", arguments: ["reply", "{ask}", answer, "db/0007_users.sql"], what: "b answers with a file") { status, out in
                status == 0 && out.contains("Answered")
            },
            As(role: "a", arguments: ["wait", "--ask", "{ask}", "--timeout", "20"], what: "a's wait has the answer and the file") { status, out in
                status == 0 && out.contains("· answered") && out.contains(answer) && out.contains(".kore/inbox/0007_users.sql")
            },
            rows("a", "a: b answered, the file, the answer under it") { rows in
                rows.contains { $0.kind == "notice" && $0.text.contains("answered, with 0007_users.sql → .kore/inbox/0007_users.sql\n" + answer) }
            },
            rows("b", "b: Answered a, with the file") { rows in rows.contains { $0.kind == "notice" && $0.text.hasPrefix("→ Answered") && $0.text.hasSuffix("with 0007_users.sql") } },
            Expect("the file in a's inbox") { story in FileManager.default.fileExists(atPath: inbox(story) + "/0007_users.sql") },
            As(role: "b", arguments: ["reply", "{ask}", "again"], what: "answered once") { status, out in status == 1 && out.contains("answered already") },

            // Fetch: the same file again (a name taken: " 2"), and the refusals.
            As(role: "a", arguments: ["fetch", "db/0007_users.sql"], what: "fetched, a free name") { status, out in
                status == 0 && out.contains("Fetched 0007_users.sql from this Mac → .kore/inbox/0007_users 2.sql")
            },
            As(role: "a", arguments: ["fetch", ".env"], what: "a secret") { status, out in status == 1 && out.contains(".env looks like a secret") },
            As(role: "a", arguments: ["fetch", "/etc/hosts"], what: "outside the open folders") { status, out in
                status == 1 && out.contains("outside this Mac's open folders")
            },
            rows("a", "a's fetch lines") { rows in
                rows.contains { $0.kind == "notice" && $0.text.hasPrefix("↓ Fetched 0007_users.sql") }
                    && rows.contains { $0.kind == "notice" && $0.text == "⊘ Not fetched: .env looks like a secret" }
            },

            // Never mid-turn: b held on a card, the ask waits for its turn to end.
            As(role: "a", arguments: ["send", "{b}", "list it"], what: "b runs into a card") { status, out in status == 0 && out.contains("Sent") },
            Expect("b held on its card") { story in try AgentCast.of(story).chat("b").pendingApprovals.contains { $0.id == AgentChannelAll.card.id } },
            As(role: "a", arguments: ["ask", "{b}", "And the sessions table?"], what: "asks b mid-turn") { status, out in status == 0 && out.contains("Asked") },
            Expect("held: not in b while its turn runs") { story in
                let b = try AgentCast.of(story).chat("b")
                return b.isBusy && !b.rows.contains { $0.text == "And the sessions table?" }
                    && ArsenalAsks.shared.asks.values.contains { $0.question == "And the sessions table?" && !$0.delivered }
            },
            As(role: "a", arguments: ["answer", "{b}", AgentChannelAll.card.id, "--deny"], what: "b's card denied: its turn ends") { status, _ in status == 0 },
            rows("b", "then it goes, as b's next message") { rows in rows.contains { $0.kind == "user" && $0.text == "And the sessions table?" } },
            Do("asks forgotten") { _ in ArsenalAsks.shared.reset() },
        ]
    }
}

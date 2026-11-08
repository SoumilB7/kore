import Foundation
import KoreCore
import KoreLink
import KoreUI

/// What every chat's CLI is given so its agent can reach Kore (`KoreReach`): the `kore` MCP server
/// in its launch arguments, the instruction saying it's there, and `kore` on its PATH. Under the
/// chat, `kore mcp` (run as `kore` from that PATH) lists every tool; with Arsenal off a call says how
/// the user turns it on. At Drive the next turn carries Kore's note and a model is found by a loose
/// name. (Claude) Codex's Read only reads any file without asking, so a Manual chat opens no Codex
/// chat; an Auto one opens one in Read only when it asks for it.
final class ArsenalReach: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript {
        CLIScript(
            start: [.event(.controlsLoaded(ChatControls(
                models: [
                    ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: []),
                    ModelOption(id: "gpt-6-sol", name: "GPT-6 Sol", resolved: "gpt-6-sol", efforts: []),
                ], model: "haiku", effort: nil, commands: [])))],
            turns: [CLIScript.reply("Ready."), CLIScript.reply("Ready."), CLIScript.reply("Ready."), CLIScript.reply("Ready.")])
    }

    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

    static func call(_ id: Int, _ tool: String, _ arguments: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
    }

    /// `kore mcp` under chat a, run as the `kore` its CLI's PATH finds.
    private func mcp(_ lines: [String], _ what: String, _ check: @escaping @MainActor ([Int: [String: Any]]) throws -> Bool) -> KoreAs {
        var step = KoreAs(["mcp"], .chat("a"), what, input: lines.joined(separator: "\n") + "\n") { status, out, _ in
            let replies = Dictionary(AgentJSON.objects(out).compactMap { o in (o["id"] as? Int).map { ($0, o) } }) { a, _ in a }
            return try status == 0 && check(replies)
        }
        step.executable = KoreReach.pathFolder.map { URL(fileURLWithPath: $0).appendingPathComponent("kore") }
        return step
    }

    /// A tool call's text, and whether it was an error.
    static func text(_ reply: [String: Any]?) -> (text: String, error: Bool) {
        let content = AgentJSON.path(reply, "result", "content") as? [[String: Any]]
        return (content?.first?["text"] as? String ?? "", AgentJSON.path(reply, "result", "isError") as? Bool ?? true)
    }

    private func role(_ name: String, _ what: String, _ check: @escaping @MainActor (Chat) -> Bool) -> Expect {
        Expect(what) { story in check(try AgentCast.of(story).chat(name)) }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kar-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let name = codex ? "Codex" : "Claude"
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed, no chat on") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(true)
            },
            Expect("the launch: the kore server, its tools allowed, the instructions; the pass and socket by name") { _ in
                guard let helper = KoreReach.helper?.path else { return false }
                let told = KoreReach.variables(pass: "p")
                guard told["KORE_AGENT_PASS"] == "p", told["KORE_AGENT_SOCKET"] == AgentWatchReads.socketPath else { return false }
                if codex {
                    let args = KoreReach.codexArguments()
                    return args.contains("mcp_servers.kore_app.command=\"\(helper)\"") && args.contains(#"mcp_servers.kore_app.args=["mcp"]"#)
                        && args.contains(#"mcp_servers.kore_app.env_vars=["KORE_AGENT_PASS","KORE_AGENT_SOCKET"]"#)
                        && !args.contains { $0.contains("KORE_AGENT_PASS=") } && KoreReach.instructions(with: "Imported.").hasPrefix("Imported.\n\n")
                        && KoreReach.instructions.contains("kore_new_chat")
                }
                let args = KoreReach.claudeLaunchArguments(instructions: nil)
                guard let at = args.firstIndex(of: "--mcp-config"), at + 1 < args.count,
                    let config = AgentJSON.objects(args[at + 1]).first,
                    let prompt = args.firstIndex(of: "--append-system-prompt").map({ args[$0 + 1] })
                else { return false }
                return AgentJSON.path(config, "mcpServers", "kore_app", "command") as? String == helper
                    && AgentJSON.path(config, "mcpServers", "kore_app", "args") as? [String] == ["mcp"]
                    && args.contains("--allowedTools") && args.contains("mcp__kore_app") && prompt.contains("kore_new_chat")
            },
            Expect("kore on the CLI's PATH, first") { _ in
                guard let folder = KoreReach.pathFolder else { return false }
                let kore = URL(fileURLWithPath: folder).appendingPathComponent("kore").resolvingSymlinksInPath().path
                let path = KoreReach.environment(["PATH": "/usr/bin:\(folder)"], [:], pathFirst: folder)["PATH"]
                return kore == KoreRun.binary.resolvingSymlinksInPath().path && path == "\(folder):/usr/bin"
            },
            SendTo("a", "hello"), TurnsDone("a", 1),

            // Off: every tool listed all the same; a call says how the user turns it on.
            mcp(
                [Self.initialize, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, Self.call(3, "kore_new_chat", #"{"provider":"codex"}"#)],
                "off: every tool, and a call says how to turn Arsenal on"
            ) { replies in
                let tools = (AgentJSON.path(replies[2], "result", "tools") as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let call = Self.text(replies[3])
                return (AgentJSON.path(replies[1], "result", "instructions") as? String ?? "").contains("kore_new_chat")
                    && tools.count == 19 && ["kore_new_chat", "kore_send", "kore_list_chats", "kore_read_chat", "kore_set_model"].allSatisfy(tools.contains)
                    && call.error && call.text.contains("Arsenal is off for this chat") && call.text.contains("⌥⌘K")
            },

            Do("a in \(codex ? "Full access" : "Manual"), Arsenal at Drive") { story in
                let a = try AgentCast.of(story).chat("a")
                a.storySetMode(codex ? "fullAccess" : "default")
                Arsenal.shared.choose(.drive, a)
            },
            role("a", "Drive") { $0.arsenal == .drive },
            SendTo("a", "next"), TurnsDone("a", 2),
            role("a", "that turn carried Kore's note, once") { a in
                let notes = ScriptedWorld.shared.backend(session: a.sessionId)?.log.compactMap { call -> String? in
                    if case .note(let note) = call { note } else { nil }
                } ?? []
                return notes.count == 1 && notes[0].hasPrefix("Kore note: Arsenal is now drive for this chat (\(String(a.id.uuidString.prefix(8)).lowercased()))")
            },

            // A model by a loose name, as the CLI lists it.
            mcp([Self.initialize, Self.call(2, "kore_new_chat", #"{"model":"gpt 6 sol","text":"write a paragraph"}"#)], "a new chat on “gpt 6 sol”") { replies in
                let call = Self.text(replies[2])
                return !call.error && call.text.contains("Opened a \(name) chat. Sent.")
            },
            Expect("in front, on gpt-6-sol, Arsenal off") { story in
                let shown = try story.activeChat()
                let a = try AgentCast.of(story).chat("a")
                let launched = ScriptedWorld.shared.backend(session: shown.sessionId)?.options.model
                return shown !== a && shown.arsenal == nil && launched == "gpt-6-sol"
            },
        ] + (codex ? [] : [
            // Codex from Manual: none, as Read only reads any file without asking.
            mcp([Self.initialize, Self.call(2, "kore_new_chat", #"{"provider":"codex"}"#)], "no Codex chat from Manual") { replies in
                let call = Self.text(replies[2])
                return call.error && call.text.contains("Only you can open a Codex chat")
            },
            // From Auto: in Read only when asked.
            Do("a in Auto") { story in try AgentCast.of(story).chat("a").storySetMode("auto") },
            mcp([Self.initialize, Self.call(2, "kore_new_chat", #"{"provider":"codex","mode":"read only","text":"write a paragraph"}"#)], "a Codex chat in Read only from Auto") { replies in
                let call = Self.text(replies[2])
                return !call.error && call.text.contains("Opened a Codex chat. Sent.")
            },
            Expect("a Codex chat in Read only, no freer than a, Arsenal off") { story in
                let shown = try story.activeChat()
                let a = try AgentCast.of(story).chat("a")
                return shown.provider.id == "codex" && shown.controls.mode == "readOnly" && shown.noFreer(than: a) && shown.arsenal == nil
                    && Arsenal.unavailable(shown) != nil
            },
            Do("the user puts a in Edit automatically") { story in try AgentCast.of(story).chat("a").storySetMode("acceptEdits") },
            mcp([Self.initialize, Self.call(2, "kore_new_chat", #"{"provider":"codex","mode":"readOnly"}"#)], "none from Edit automatically, Read only included") { replies in
                let call = Self.text(replies[2])
                return call.error && call.text.contains("Only you can")
            },
        ]) + [
            Do("off again") { story in AgentCast.of(story).finish() },
        ]
    }
}

/// Live (`--live <cheap model>`): a chat at Drive is asked in the owner's words (with the cheap
/// gpt-6-luna for the model the owner named) for a Codex tab on a model named loosely, with nothing
/// telling it how beyond what Kore gives every chat. A new Codex tab comes up in front on gpt-6-luna
/// with the agent's message; it's stopped once the message is in, to keep the run small. What each
/// chat said goes to `agent-notes.txt`.
final class ArsenalAskLive: Storyline {
    override class var tags: Set<Tag> { [.live] }
    override class var variants: [Variant] { [.claude, .codex] }

    static let ask = "open another tab which is codex model gpt 6 luna and tell it to write a paragraph"

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kas-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return [
            Do("agent control at a socket of this run's, which chats are told of") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                AgentChannel.directory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                AgentGrants.stopAll()
            },
            OpenFolder(), StartChat(),
        ] + (variant == .codex ? [SetMode("fullAccess")] : []) + [
            Do("Arsenal on, at Drive") { story in
                let chat = try story.activeChat()
                AgentCast.of(story).chats["a"] = chat
                Arsenal.shared.setAllowed(true)
                Arsenal.shared.choose(.drive, chat)
            },
            Expect("Drive, and the socket") { story in try story.activeChat().arsenal == .drive && AgentChannel.current != nil },
            Send(Self.ask),
            AllowUntilDone(),
            Expect("a Codex tab in front, on gpt-6-luna, with the agent's message", timeout: .seconds(120), found: { story in
                try? "\(story.activeChat().provider.id) \(story.activeChat().storyModel ?? "-")"
            }) { story in
                let chat = try story.activeChat()
                let rows = story.app.chat?.rows ?? []
                return chat !== (try AgentCast.of(story).chat("a")) && chat.provider.id == "codex" && chat.arsenal == nil
                    && chat.storyModel == "gpt-6-luna" && rows.contains { $0.kind == "notice" && $0.text.hasPrefix("Arsenal · sent by") }
                    && rows.contains { $0.kind == "user" && $0.text.lowercased().contains("paragraph") }
            },
            Do("stop it there; note what each chat said") { story in
                let cast = AgentCast.of(story)
                let made = try story.activeChat()
                for row in story.app.chat?.rows ?? [] where ["notice", "user"].contains(row.kind) {
                    cast.note("new tab \(made.provider.id) \(made.storyModel ?? "-") \(made.controls.mode) \(row.kind): \(row.text.prefix(300))", to: story.outputs)
                }
                made.storyStop()
                let a = try cast.chat("a")
                _ = story.app.workspace?.arsenalShow(a)
            },
            Do("the caller's turn, noted") { story in
                let cast = AgentCast.of(story)
                for row in story.app.chat?.rows ?? [] where row.kind != "thinking" {
                    cast.note("caller \(row.kind): \(row.text.prefix(300))", to: story.outputs)
                }
                cast.finish()
            },
        ]
    }
}

import Foundation

/// `kore mcp`: Kore as an MCP server on stdio (JSON-RPC, one message a line), which Kore gives every
/// chat's CLI at launch (`KoreReach`). Under a chat it lists every tool, whatever the chat's access
/// now: the CLI reads the list once, and the user may turn Arsenal on later. Each call is one
/// connection to Kore, which checks the chat's tier then: off, a call answers how the user turns it
/// on; below the tool's tier, which tier it needs. Outside Kore's chats it lists what Kore allows.
enum MCPServer {
    typealias Object = AgentClient.Object

    struct Tool {
        let name: String
        let command: String
        let description: String
        /// Argument name → (JSON type, description).
        let args: [(String, String, String)]
        let required: [String]
    }

    static let chatArg = ("chat", "string", "The chat: its title (any part only it has), its short id, or . for this chat.")

    static let tools: [Tool] = [
        Tool(name: "kore_whoami", command: "agent.whoami", description: "Who Kore sees calling (this chat or an outside tool) and its Kore access tier.", args: [], required: []),
        Tool(name: "kore_caps", command: "agent.caps", description: "The Kore commands this caller's access allows.", args: [], required: []),
        Tool(
            name: "kore_list_chats", command: "chats.list",
            description: "List the chats open in Kore (its tabs): id, title, CLI, folder, state (working, idle, needs-you), mode, model, waiting cards.", args: [],
            required: []),
        Tool(
            name: "kore_show_chat", command: "chat.show", description: "One chat in detail: state, model, effort, context use, waiting cards.",
            args: [chatArg], required: ["chat"]),
        Tool(
            name: "kore_read_chat", command: "tx.read", description: "Read a chat's transcript, newest last, a page at a time.",
            args: [
                chatArg, ("last", "integer", "How many rows (default 20, at most 200)."),
                ("before", "string", "A row id: read the rows before it (the next page back)."),
            ], required: ["chat"]),
        Tool(
            name: "kore_pending", command: "cards.list",
            description: "Cards waiting on the user across chats (permissions, questions, plans). Read only: only the user answers them.",
            args: [("chat", "string", "Only this chat's cards.")], required: []),
        Tool(
            name: "kore_history", command: "history.list", description: "A Kore window's past chats, newest first.",
            args: [
                ("folder", "string", "The window's folder (default: this chat's window)."), ("query", "string", "Words the title holds."),
                ("archived", "boolean", "Archived chats instead."), ("offset", "integer", "Skip this many (pages of 50)."),
            ], required: []),
        Tool(
            name: "kore_options", command: "chat.options",
            description: "This chat's models, efforts and modes, and which modes it may lower to (Own access).", args: [], required: []),
        Tool(name: "kore_rename", command: "chat.rename", description: "Rename this chat (Own access).", args: [("to", "string", "The new name.")], required: ["to"]),
        Tool(
            name: "kore_set_model", command: "chat.model", description: "Switch this chat's model to one kore_options lists (Own access).",
            args: [("to", "string", "The model's id or name.")], required: ["to"]),
        Tool(
            name: "kore_set_effort", command: "chat.effort", description: "Set this chat's effort to a level its model offers (Own access).",
            args: [("to", "string", "The level.")], required: ["to"]),
        Tool(
            name: "kore_set_fast", command: "chat.fast", description: "Turn this chat's fast mode on or off (Own access).",
            args: [("on", "boolean", "On or off.")], required: ["on"]),
        Tool(
            name: "kore_lower_mode", command: "chat.mode",
            description: "Lower this chat's mode, to one kore_options marks allowed. Only the user raises a mode (Own access).",
            args: [("to", "string", "The mode's id or label.")], required: ["to"]),
        Tool(name: "kore_compact", command: "chat.compact", description: "Compact this chat once the current turn ends (Own access).", args: [], required: []),
        Tool(
            name: "kore_new_chat", command: "chat.new",
            description: "Open a new chat in a new Kore tab, in front, in this window, and send it a first message if given. Use when the user asks for another tab, chat or agent. It starts at this chat's mode or lower, with its own Arsenal off. Returns its short id for kore_send (Drive access).",
            args: [
                ("provider", "string", "claude or codex (default: this chat's)."),
                ("model", "string", "A model the CLI lists, by id or name, written loosely (\"gpt 6 sol\" is gpt-6-sol). Default: the CLI's."),
                ("mode", "string", "A mode at or below this chat's (default: the CLI's usual one, capped)."), ("text", "string", "The first message."),
            ], required: []),
        Tool(
            name: "kore_send", command: "chat.send", description: "Send a message to another chat, as the user would type it, queued while it works. It shows who sent it. Only chats at this chat's mode or lower (Drive access).",
            args: [chatArg, ("text", "string", "The message.")], required: ["chat", "text"]),
        Tool(name: "kore_stop", command: "chat.stop", description: "Stop another chat's turn (Drive access).", args: [chatArg], required: ["chat"]),
        Tool(name: "kore_show_tab", command: "tab.show", description: "Bring a chat's tab to the front (Drive access).", args: [chatArg], required: ["chat"]),
        Tool(
            name: "kore_answer", command: "cards.answer",
            description: "Answer another chat's question card (kore_pending lists them), one answer per question, or deny any card. Only the user approves (Drive access).",
            args: [
                chatArg, ("card", "string", "The card's id."), ("answers", "array", "One option label (or typed text) per question, in order."),
                ("deny", "boolean", "Deny the card instead."),
            ], required: ["chat", "card"]),
    ]

    static func run() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let message = (try? JSONSerialization.jsonObject(with: data)) as? Object else {
                reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            // Notifications (no id) need no answer.
            guard let id = message["id"] else { continue }
            let params = message["params"] as? Object ?? [:]
            switch message["method"] as? String {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                answer(id, [
                    "protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "kore", "version": "1"],
                    "instructions": serverInstructions,
                ])
            case "ping":
                answer(id, [:])
            case "tools/list":
                answer(id, ["tools": listed().map(describe)])
            case "tools/call":
                answer(id, call(params["name"] as? String ?? "", params["arguments"] as? Object ?? [:]))
            default:
                reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
        return 0
    }

    static let serverInstructions = """
        Kore's own controls, for when the user asks for something in Kore: open a tab with a new claude or codex \
        chat (kore_new_chat), message another chat (kore_send), list and read chats, change this chat's model. \
        They act only while the user has Arsenal on for this chat; a tool says so when it's off.
        """

    /// The chat's pass: this runs under one of Kore's chats.
    static var inChat: Bool { !(ProcessInfo.processInfo.environment["KORE_AGENT_PASS"] ?? "").isEmpty }

    /// Under a chat, every tool; outside, those Kore allows now (none while it can't be reached).
    static func listed() -> [Tool] {
        if inChat { return tools }
        guard let client = try? AgentClient() else { return [] }
        let commands = Set(client.welcome["commands"] as? [String] ?? [])
        return tools.filter { commands.contains($0.command) }
    }

    /// Kore's off, or this chat's Arsenal is: what the agent tells the user.
    static let offLine = "Arsenal is off for this chat. The user turns it on: right-click its tab → Arsenal, or ⌥⌘K (a Codex chat needs Full access)."

    /// No socket: agent control is off in Kore (or, outside its chats, Kore may not be running).
    static var unreachableLine: String {
        inChat ? "Kore's agent control is off, so Arsenal is off for this chat. The user turns it on: right-click its tab → Arsenal, or ⌥⌘K."
            : "Kore isn't running, or agent control is off."
    }

    /// The tier each command needs, lowest first.
    static func tierNeeded(_ command: String) -> String {
        if ["chat.new", "chat.send", "chat.stop", "tab.show", "cards.answer"].contains(command) { return "drive" }
        if ownCommands.contains(command) { return "own" }
        return "watch"
    }

    static let ownCommands = ["chat.options", "chat.rename", "chat.model", "chat.effort", "chat.fast", "chat.mode", "chat.compact"]

    static func describe(_ tool: Tool) -> Object {
        var properties: Object = [:]
        for (name, type, description) in tool.args {
            properties[name] = type == "array" ? ["type": type, "items": ["type": "string"], "description": description] : ["type": type, "description": description]
        }
        return [
            "name": tool.name, "description": tool.description,
            "inputSchema": ["type": "object", "properties": properties, "required": tool.required],
        ]
    }

    static func call(_ name: String, _ arguments: Object) -> Object {
        guard let tool = tools.first(where: { $0.name == name }) else { return failure("No such tool: \(name).") }
        var args = arguments.filter { key, _ in tool.args.contains { $0.0 == key } }
        // Own's tools act on the chat this runs in.
        if ownCommands.contains(tool.command) { args["chat"] = args["chat"] ?? "." }
        do {
            let client = try AgentClient()
            // Kore checks the tier too: this only says it in the agent's terms.
            let allowed = client.welcome["commands"] as? [String] ?? []
            if !allowed.contains(tool.command) {
                let tier = client.welcome["tier"] as? String ?? "off"
                return failure("This needs Arsenal's \(tierNeeded(tool.command).capitalized) tier; this chat has \(tier.capitalized). "
                    + "The user picks a tier from the Arsenal icon at the top right of Kore's window.")
            }
            let data = try client.run(tool.command, args)
            let text = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch .unreachable {
            return failure(unreachableLine)
        } catch .refused(let code, let message) {
            return failure(code == "denied" && inChat ? offLine : message)
        } catch {
            return failure("Kore closed the connection.")
        }
    }

    static func failure(_ message: String) -> Object { ["content": [["type": "text", "text": message]], "isError": true] }

    static func answer(_ id: Any, _ result: Object) { reply(["jsonrpc": "2.0", "id": id, "result": result]) }

    static func reply(_ message: Object) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

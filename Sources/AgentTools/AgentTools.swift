import Foundation

/// Kore's `kore_app` tools as an MCP server lists them: one list for `kore mcp` on the Mac and
/// `kore-host mcp` on a box, so a chat's agent sees the same tools wherever its CLI runs. Each tool
/// is one command on Kore's agent channel (`z-docs/agent-protocol.md`); Kore decides every call
/// by the chat's Arsenal tier. Foundation only: `kore` stays small and starts fast.
package enum AgentTools {
    package typealias Object = [String: Any]

    package struct Tool: Sendable {
        package let name: String
        package let command: String
        package let description: String
        /// Argument name, JSON type, description.
        package let args: [(String, String, String)]
        package let required: [String]
    }

    static let chatArg = ("chat", "string", "The chat: its title (any part only it has), its short id, or . for this chat.")
    /// Own's tools: this chat, or with Drive another chat it reaches.
    static let ownChatArg = ("chat", "string", "Default: this chat. With Act unlimited, another chat at or below this chat's mode (title, short id).")

    /// A chat on a box opens its new chats on that box, in its folder; `place` opens one on the Mac.
    static let placeArg = ("place", "string", "box (default: this chat's box and folder) or mac (a Kore window on the Mac).")

    /// Every tool, in the order an agent reads them. `box`: as a chat on a box sees them.
    package static func tools(box: Bool = false) -> [Tool] {
        guard box else { return all }
        return all.map { tool in
            guard tool.command == "chat.new" else { return tool }
            return Tool(name: tool.name, command: tool.command, description: tool.description, args: tool.args + [placeArg], required: tool.required)
        }
    }

    package static func tool(_ name: String, box: Bool = false) -> Tool? { tools(box: box).first { $0.name == name } }

    static let all: [Tool] = [
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
                ("folder", "string", "The window's folder (default: this chat's window; another open folder's with Act unlimited)."), ("query", "string", "Words the title holds."),
                ("archived", "boolean", "Archived chats instead."), ("offset", "integer", "Skip this many (pages of 50)."),
            ], required: []),
        Tool(
            name: "kore_options", command: "chat.options",
            description: "A chat's models, efforts and modes, and which modes it may lower to (Act limited; another chat with Act unlimited).", args: [ownChatArg], required: []),
        Tool(name: "kore_rename", command: "chat.rename", description: "Rename this chat, or another with Act unlimited (Act limited).", args: [ownChatArg, ("to", "string", "The new name.")], required: ["to"]),
        Tool(
            name: "kore_set_model", command: "chat.model",
            description: "Switch a chat's model to one its CLI lists (kore_options): this chat (Act limited), or another it reaches (Act unlimited). A Codex chat takes Codex models.",
            args: [ownChatArg, ("to", "string", "The model's id or name, written loosely (\"gpt 6 sol\"); a one-letter typo is forgiven when only one model is that close.")], required: ["to"]),
        Tool(
            name: "kore_set_effort", command: "chat.effort", description: "Set a chat's effort to a level its model offers: this chat (Act limited), or another it reaches (Act unlimited).",
            args: [ownChatArg, ("to", "string", "The level.")], required: ["to"]),
        Tool(
            name: "kore_set_fast", command: "chat.fast", description: "Turn a chat's fast mode on or off: this chat (Act limited), or another it reaches (Act unlimited).",
            args: [ownChatArg, ("on", "boolean", "On or off.")], required: ["on"]),
        Tool(
            name: "kore_lower_mode", command: "chat.mode",
            description: "Lower a chat's mode, to one kore_options marks allowed: this chat (Act limited), or another it reaches (Act unlimited). Only the user raises a mode.",
            args: [ownChatArg, ("to", "string", "The mode's id or label.")], required: ["to"]),
        Tool(name: "kore_compact", command: "chat.compact", description: "Compact this chat once the current turn ends, or another it reaches with Act unlimited (Act limited).", args: [ownChatArg], required: []),
        Tool(
            name: "kore_new_chat", command: "chat.new",
            description: "Open a new chat in a new Kore tab, in front, in this window, and send it a first message if given. Use when the user asks for another tab, chat or agent. It starts at this chat's mode or lower, with its own Arsenal off. Returns its short id for kore_send (Act unlimited).",
            args: [
                ("provider", "string", "claude or codex (default: this chat's)."),
                ("model", "string", "A model the CLI lists, by id or name, written loosely (\"gpt 6 sol\" is gpt-6-sol). Default: the CLI's."),
                ("mode", "string", "A mode at or below this chat's (default: the CLI's usual one, capped)."), ("text", "string", "The first message."),
            ], required: []),
        Tool(
            name: "kore_fork", command: "chat.fork",
            description: "Fork a chat into a new Kore tab, in front, carrying its conversation (to a message with at, else all of it), in that chat's mode, its Arsenal off, and send it a message if given. Counts as a new chat (Act unlimited).",
            args: [
                ("chat", "string", "The chat to fork: . for this one, or another it reaches (title, short id)."),
                ("at", "string", "Fork before this user message: -N for the Nth from the end (-1 the last, as the chat's message scroller counts), its row id (kore_read_chat) or its text. Default: after the last answer."),
                ("provider", "string", "claude or codex: fork into the other CLI, carrying the whole conversation (no at). Default: the chat's own."),
                ("model", "string", "A model the fork's CLI lists (default: the chat's, or that CLI's usual)."), ("text", "string", "A message to send the fork."),
            ], required: ["chat"]),
        Tool(
            name: "kore_wait", command: "chat.wait",
            description: "Wait until another chat's current turn ends, or a card asks the user: returns its state and last answer. Use after kore_send or kore_new_chat to get the reply (Read).",
            args: [
                chatArg, ("ask", "string", "Instead of a chat: an ask this chat made (kore_ask's id); returns its answer and where its file landed."),
                ("timeout", "integer", "Seconds, 300 at most (default 300)."),
            ], required: []),
        Tool(
            name: "kore_send", command: "chat.send", description: "Send a message to another chat, as the user would type it, queued while it works. It shows who sent it. Only chats at this chat's mode or lower (Act unlimited).",
            args: [chatArg, ("text", "string", "The message. A \"/\" command that chat's CLI has goes too, except sign-in, account, permission and settings ones (mode and model: their own tools); never a \"!\" line.")], required: ["chat", "text"]),
        Tool(name: "kore_stop", command: "chat.stop", description: "Stop another chat's turn (Act unlimited).", args: [chatArg], required: ["chat"]),
        Tool(
            name: "kore_open_chat", command: "chat.open",
            description: "Open a past chat (kore_history lists them) in a tab, in front, as History opens it; its tab if it's open already (Act unlimited).",
            args: [("session", "string", "Its session id, or the start of it."), ("folder", "string", "Its folder (default: this chat's window).")],
            required: ["session"]),
        Tool(
            name: "kore_close", command: "chat.close",
            description: "Close another chat as its tab's close does; History keeps it, and kore_open_chat brings it back. By its id only (short or full), never a title. Refused while it works or anything in it would be lost (Act unlimited).",
            args: [("chat", "string", "Its short id (kore_list_chats) or full id.")], required: ["chat"]),
        Tool(
            name: "kore_ask", command: "chat.ask",
            description: "Ask another chat a question. Kore sends it as that chat's next message once it's idle, marked as from this chat, and its answer comes back with kore_wait (ask) and as a line here. Both chats need Act unlimited; by id only; one hop (a chat answering an ask can't ask); 20 an hour; ends after 30 min.",
            args: [("chat", "string", "Its short id (kore_list_chats) or full id."), ("text", "string", "The question.")], required: ["chat", "text"]),
        Tool(
            name: "kore_reply", command: "chat.reply",
            description: "Answer an ask this chat was asked (its id is in Kore's note with the question). A file from this chat's folder can go with it, into the asker's .kore/inbox/ (fetch's rules) (Act unlimited).",
            args: [("ask", "string", "The ask's id."), ("text", "string", "The answer."), ("path", "string", "A file in this chat's folder to send with it.")],
            required: ["ask", "text"]),
        Tool(
            name: "kore_fetch", command: "file.fetch",
            description: "Copy one file from a folder a Kore window has open (this Mac's, or a box's as device:path) into this chat's .kore/inbox/. Copies only, 50 MB at most, never a secret-looking path (.env, keys, credentials, .ssh); 50 an hour (Act unlimited; from another device, Act device).",
            args: [("path", "string", "device:path (a box's name, then its path), or a path on this chat's device.")], required: ["path"]),
        Tool(name: "kore_show_tab", command: "tab.show", description: "Bring a chat's tab to the front (Act unlimited).", args: [chatArg], required: ["chat"]),
        Tool(
            name: "kore_answer", command: "cards.answer",
            description: "Answer another chat's question card (kore_pending lists them), one answer per question; deny any card; or allow a permission card once, from a chat at Auto or above. A peer-hold card (messages from other sessions Claude held) is let in with allow, never by a chat whose own message is held. Plans, Always allow and sign-ins stay the user's (Act unlimited).",
            args: [
                chatArg, ("card", "string", "The card's id."), ("answers", "array", "One option label (or typed text) per question, in order."),
                ("deny", "boolean", "Deny the card instead."), ("allow", "boolean", "Allow a permission card once (this chat at Auto or above), or let a peer-hold card's messages in."),
            ], required: ["chat", "card"]),
    ]

    /// What the server tells the CLI about itself.
    package static let serverInstructions = """
        Kore's own controls, for when the user asks for something in Kore: open a tab with a new claude or codex \
        chat (kore_new_chat), message another chat (kore_send), list and read chats, change this chat's model. \
        They act only while the user has Arsenal on for this chat; a tool says so when it's off.
        """

    /// The tier each command needs, lowest first: wire ids (`tierName` names them).
    package static func tierNeeded(_ command: String) -> String {
        if ["chat.new", "chat.fork", "chat.send", "chat.stop", "tab.show", "cards.answer", "chat.open", "chat.close", "chat.ask", "chat.reply", "file.fetch"].contains(command) { return "drive" }
        if ownCommands.contains(command) { return "own" }
        return "watch"
    }

    package static let ownCommands = ["chat.options", "chat.rename", "chat.model", "chat.effort", "chat.fast", "chat.mode", "chat.compact"]

    /// A tier's name as the user sees it, from its wire id (`watch`, `own`, `drive`, `device`, `full`, `off`).
    package static func tierName(_ id: String) -> String {
        switch id {
        case "watch": "Read"
        case "own": "Act limited"
        case "drive": "Act unlimited"
        case "device": "Act device"
        case "full": "Full"
        case "off", "": "Off"
        default: id
        }
    }

    /// How long a caller waits for Kore's answer to a command, in seconds: the same for `kore`,
    /// `kore mcp` and a box chat's calls (which add `linkMargin`). A wait holds until the chat's
    /// turn ends (`timeout`, 300 s at most); the CLI makes a fork; a file crosses to or from a box;
    /// a box's History opens its chat over the link.
    package static func answerWait(_ command: String, _ args: Object = [:]) -> Int {
        switch command {
        case "chat.wait": min(max(args["timeout"] as? Int ?? 300, 1), 300) + 15
        case "chat.fork": 75
        case "file.fetch", "chat.reply": 120
        case "chat.open": 30
        default: 10
        }
    }

    /// A box chat's call crosses the box's link to the Mac and back: kore-host waits this much
    /// longer than a caller on the Mac would.
    package static let linkMargin = 20

    /// Nothing came back within `answerWait`: what the agent reads on the Mac and on a box.
    package static let noAnswerLine = "Kore didn't answer in time."

    /// More calls at once than a chat may make: a chat's own process on the Mac
    /// (`AgentSlots.perProcess`), a box chat's calls in flight.
    package static let callsAtOnce = 4
    package static let tooManyLine = "Too many connections to Kore from this process, or at once."

    /// A call's arguments as the command takes them: only the tool's own, and Own's tools act on
    /// the chat this runs in unless one is named.
    package static func arguments(_ tool: Tool, _ given: Object) -> Object {
        var args = given.filter { key, _ in tool.args.contains { $0.0 == key } }
        if ownCommands.contains(tool.command) { args["chat"] = args["chat"] ?? "." }
        return args
    }

    /// Kore's off, or this chat's Arsenal is: what the agent tells the user. A chat on a box
    /// reaches Kore through this server alone, so Codex's sandbox doesn't come into it.
    package static func offLine(box: Bool = false) -> String {
        box
            ? "Arsenal is off for this chat. The user turns it on: right-click its tab → Arsenal, or ⌥⌘K."
            : "Arsenal is off for this chat. The user turns it on: right-click its tab → Arsenal, or ⌥⌘K (a Codex chat needs Full access)."
    }

    /// A command above the chat's tier: which one it needs.
    package static func tierLine(_ command: String, has tier: String) -> String {
        "This needs Arsenal's \(tierName(tierNeeded(command))) tier; this chat has \(tierName(tier)). "
            + "The user picks a tier from the Arsenal icon at the top right of Kore's window."
    }

    /// Kore's line for a call (its result, or a `bye`) as the agent reads it, the same from
    /// `kore mcp` on the Mac and from kore-host on a box: the command's data, or why not. Off, or
    /// turned off as it asked, says how the user turns Arsenal on (`inChat`: a chat's caller).
    package static func answer(_ line: Object, box: Bool, inChat: Bool = true) -> (ok: Bool, code: String?, text: String) {
        if line["type"] as? String == "result", line["ok"] as? Bool == true { return (true, nil, text(line["data"] as? Object ?? [:])) }
        let code = line["code"] as? String ?? "refused"
        let off = inChat && ["denied", "stopped"].contains(code)
        return (false, code, off ? offLine(box: box) : line["message"] as? String ?? "Kore refused.")
    }

    /// A command's data as the agent reads it.
    package static func text(_ data: Object) -> String {
        (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    package static func describe(_ tool: Tool) -> Object {
        var properties: Object = [:]
        for (name, type, description) in tool.args {
            properties[name] = type == "array" ? ["type": type, "items": ["type": "string"], "description": description] : ["type": type, "description": description]
        }
        return [
            "name": tool.name, "description": tool.description,
            "inputSchema": ["type": "object", "properties": properties, "required": tool.required],
        ]
    }
}

/// An MCP server on stdio (JSON-RPC, one message a line): initialize, ping, the tools and their
/// calls. Blocking; it ends when stdin does.
package enum MCPStdio {
    package typealias Object = AgentTools.Object

    /// `list`: the tools to list. `call`: a call's result (`content`, `isError`).
    package static func run(list: () -> [AgentTools.Tool], call: (String, Object) -> Object) -> Int32 {
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
                    "instructions": AgentTools.serverInstructions,
                ])
            case "ping":
                answer(id, [:])
            case "tools/list":
                answer(id, ["tools": list().map(AgentTools.describe)])
            case "tools/call":
                answer(id, call(params["name"] as? String ?? "", params["arguments"] as? Object ?? [:]))
            default:
                reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
        return 0
    }

    package static func success(_ text: String) -> Object { ["content": [["type": "text", "text": text]], "isError": false] }
    package static func failure(_ message: String) -> Object { ["content": [["type": "text", "text": message]], "isError": true] }

    static func answer(_ id: Any, _ result: Object) { reply(["jsonrpc": "2.0", "id": id, "result": result]) }

    static func reply(_ message: Object) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

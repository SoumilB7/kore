import Foundation

/// `kore mcp`: Kore's reads as an MCP server on stdio (JSON-RPC, one message a line). Its tools
/// are the commands the caller's access allows, asked of Kore at each list; each call is one
/// connection to Kore, so access changed in Kore holds from the next call.
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
            description: "Every chat open in Kore: id, title, CLI, folder, state (working, idle, needs-you), mode, model, waiting cards.", args: [],
            required: []),
        Tool(
            name: "kore_show_chat", command: "chat.show", description: "One chat in detail: state, model, effort, context use, waiting cards.",
            args: [chatArg], required: ["chat"]),
        Tool(
            name: "kore_read_transcript", command: "tx.read", description: "A chat's transcript rows, newest last, a page at a time.",
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
                answer(id, ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "kore", "version": "1"]])
            case "ping":
                answer(id, [:])
            case "tools/list":
                answer(id, ["tools": allowed().map(describe)])
            case "tools/call":
                answer(id, call(params["name"] as? String ?? "", params["arguments"] as? Object ?? [:]))
            default:
                reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
        return 0
    }

    /// The tools Kore allows this caller now (none while Kore can't be reached).
    static func allowed() -> [Tool] {
        guard let client = try? AgentClient() else { return [] }
        let commands = Set(client.welcome["commands"] as? [String] ?? [])
        return tools.filter { commands.contains($0.command) }
    }

    static func describe(_ tool: Tool) -> Object {
        var properties: Object = [:]
        for (name, type, description) in tool.args { properties[name] = ["type": type, "description": description] }
        return [
            "name": tool.name, "description": tool.description,
            "inputSchema": ["type": "object", "properties": properties, "required": tool.required],
        ]
    }

    static func call(_ name: String, _ arguments: Object) -> Object {
        guard let tool = tools.first(where: { $0.name == name }) else { return failure("No such tool: \(name).") }
        var args = arguments.filter { key, _ in tool.args.contains { $0.0 == key } }
        // Own's tools act on the chat this runs in.
        if tool.command.hasPrefix("chat."), tool.command != "chat.show" { args["chat"] = "." }
        do {
            let client = try AgentClient()
            let data = try client.run(tool.command, args)
            let text = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch .unreachable {
            return failure("Kore isn't running, or agent control is off.")
        } catch .refused(_, let message) {
            return failure(message)
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

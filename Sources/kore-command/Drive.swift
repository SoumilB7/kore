import Foundation

/// Drive's commands: `kore new`, `send`, `stop`, `tab`, `answer`, on chats at or below this chat's mode.
enum Drive {
    typealias Object = AgentClient.Object

    static let usage = [
        "new": "[--claude|--codex] [--model M] [--mode X] [\"message\"]", "send": "<chat> \"message\"", "stop": "<chat>", "tab": "<chat>",
        "answer": "<chat> <card> <answer>... | <chat> <card> --deny",
    ]

    static func fits(_ name: String, _ o: Reads.Options) -> Bool {
        let n = o.positional.count
        switch name {
        case "new": return n <= 1
        case "send": return n == 2
        case "stop", "tab": return n == 1
        default: return o.deny ? n == 2 : n >= 3
        }
    }

    static func run(_ name: String, _ client: AgentClient, _ o: Reads.Options) throws(AgentClient.Failure) {
        let p = o.positional
        let data: Object
        switch name {
        case "new":
            var args: Object = [:]
            if let provider = o.provider { args["provider"] = provider }
            if let model = o.model { args["model"] = model }
            if let mode = o.mode { args["mode"] = mode }
            if let text = p.first { args["text"] = text }
            data = try client.run("chat.new", args)
        case "send": data = try client.run("chat.send", ["chat": p[0], "text": p[1]])
        case "stop": data = try client.run("chat.stop", ["chat": p[0]])
        case "tab": data = try client.run("tab.show", ["chat": p[0]])
        default:
            var args: Object = ["chat": p[0], "card": p[1]]
            if o.deny { args["deny"] = true } else { args["answers"] = Array(p.dropFirst(2)) }
            data = try client.run("cards.answer", args)
        }
        if o.json { return Reads.printJSON(data) }
        let short = Reads.str(data["short"])
        Reads.say(short.isEmpty ? Reads.str(data["message"]) : "\(short)  \(Reads.str(data["message"]))")
    }
}

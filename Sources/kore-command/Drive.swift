import AgentTools
import Foundation

/// Drive's commands: `kore new`, `send`, `stop`, `tab`, `answer`, `close`, on chats at or below this chat's mode.
enum Drive {
    typealias Object = AgentClient.Object

    static let usage = [
        "new": "[--claude|--codex] [--model M] [--mode X] [\"message\"]", "send": "<chat> \"message\"", "stop": "<chat>", "tab": "<chat>",
        "fork": "<chat> [--at -N|<message>] [--claude|--codex] [--model M] [\"message\"]", "wait": "<chat> | --ask <id> [--timeout s]",
        "ask": "<short id> \"question\"", "reply": "<ask id> \"answer\" [file]", "fetch": "<device:path | path>",
        "answer": "<chat> <card> <answer>... | <chat> <card> --deny | <chat> <card> --allow", "open": "<session> [--folder F]", "close": "<short id>",
    ]

    static func fits(_ name: String, _ o: Reads.Options) -> Bool {
        let n = o.positional.count
        switch name {
        case "new": return n <= 1
        case "fork": return (1...2).contains(n)
        case "wait": return o.ask != nil ? n == 0 : n == 1
        case "ask": return n == 2
        case "reply": return (2...3).contains(n)
        case "fetch": return n == 1
        case "send": return n == 2
        case "stop", "tab", "open", "close": return n == 1
        default: return o.deny || o.allow ? n == 2 : n >= 3
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
        case "fork":
            var args: Object = ["chat": p[0]]
            if let at = o.at { args["at"] = at }
            if let provider = o.provider { args["provider"] = provider }
            if let model = o.model { args["model"] = model }
            if p.count > 1 { args["text"] = p[1] }
            // The CLI makes the fork: it can take a moment.
            client.timeout(AgentTools.answerWait("chat.fork"))
            data = try client.run("chat.fork", args)
        case "wait":
            var args: Object = o.ask.map { ["ask": $0] } ?? ["chat": p[0]]
            if let t = o.timeout { args["timeout"] = t }
            client.timeout(AgentTools.answerWait("chat.wait", args))
            data = try client.run("chat.wait", args)
            if o.json { return Reads.printJSON(data) }
            if o.ask != nil {
                Reads.say("· \(Reads.str(data["state"]))" + (data["timedOut"] as? Bool == true ? " (no answer yet at the timeout)" : ""))
                if let file = data["file"] as? String { Reads.say("file: \(file)") }
                if let answer = data["answer"] as? String { Reads.say(answer) }
                return
            }
            let timedOut = data["timedOut"] as? Bool == true
            Reads.say("· \(Reads.str(data["state"]))" + (timedOut ? " (still working at the timeout)" : ""))
            if let answer = data["answer"] as? String { Reads.say(answer) }
            return
        case "send": data = try client.run("chat.send", ["chat": p[0], "text": p[1]])
        case "ask":
            data = try client.run("chat.ask", ["chat": p[0], "text": p[1]])
            if o.json { return Reads.printJSON(data) }
            return Reads.say("\(Reads.str(data["ask"]))  \(Reads.str(data["message"]))")
        case "reply":
            var args: Object = ["ask": p[0], "text": p[1]]
            if p.count > 2 { args["path"] = p[2] }
            client.timeout(AgentTools.answerWait("chat.reply"))
            data = try client.run("chat.reply", args)
        case "fetch":
            client.timeout(AgentTools.answerWait("file.fetch"))
            data = try client.run("file.fetch", ["path": p[0]])
            if o.json { return Reads.printJSON(data) }
            return Reads.say(Reads.str(data["message"]))
        case "stop": data = try client.run("chat.stop", ["chat": p[0]])
        case "tab": data = try client.run("tab.show", ["chat": p[0]])
        case "close": data = try client.run("chat.close", ["chat": p[0]])
        case "open":
            var args: Object = ["session": p[0]]
            if let folder = o.folder { args["folder"] = folder }
            client.timeout(AgentTools.answerWait("chat.open"))
            data = try client.run("chat.open", args)
        default:
            var args: Object = ["chat": p[0], "card": p[1]]
            if o.deny { args["deny"] = true } else if o.allow { args["allow"] = true } else { args["answers"] = Array(p.dropFirst(2)) }
            data = try client.run("cards.answer", args)
        }
        if o.json { return Reads.printJSON(data) }
        let short = Reads.str(data["short"])
        Reads.say(short.isEmpty ? Reads.str(data["message"]) : "\(short)  \(Reads.str(data["message"]))")
    }
}

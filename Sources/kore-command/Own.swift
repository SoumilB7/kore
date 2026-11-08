import Foundation

/// Own's commands: the chat `kore` runs in, changed as its composer would. Each takes `.` (or no
/// chat) and the value: `kore model haiku`, `kore mode plan`, `kore fast on`.
enum Own {
    typealias Object = AgentClient.Object

    /// What each takes after its name, for its usage line.
    static let usage = [
        "rename": "<name>", "model": "<model>", "effort": "<level>", "fast": "on|off", "mode": "<mode>", "compact": "", "options": "",
    ]

    static func fits(_ name: String, _ positional: [String]) -> Bool {
        switch name {
        case "compact", "options": positional.count <= 1
        case "fast": (1...2).contains(positional.count) && ["on", "off"].contains(positional.last ?? "")
        default: (1...2).contains(positional.count)
        }
    }

    /// The chat (`.` unless two are given) and the value.
    private static func split(_ positional: [String], valued: Bool) -> (chat: String, value: String?) {
        guard valued else { return (positional.first ?? ".", nil) }
        return positional.count == 2 ? (positional[0], positional[1]) : (".", positional.first)
    }

    static func set(_ name: String, _ client: AgentClient, _ o: Reads.Options) throws(AgentClient.Failure) {
        let (chat, value) = split(o.positional, valued: name != "compact")
        var args: Object = ["chat": chat]
        if name == "fast" { args["on"] = value == "on" } else if let value { args["to"] = value }
        let data = try client.run("chat.\(name)", args)
        if o.json { return Reads.printJSON(data) }
        Reads.say(Reads.str(data["message"]))
    }

    static func options(_ client: AgentClient, _ o: Reads.Options) throws(AgentClient.Failure) {
        let data = try client.run("chat.options", ["chat": o.positional.first ?? "."])
        if o.json { return Reads.printJSON(data) }
        let models = data["models"] as? [Object] ?? []
        let modes = data["modes"] as? [Object] ?? []
        let current = Reads.str(data["model"])
        let model = models.first { Reads.str($0["id"]) == current }
        var rows: [(String, String, String)] = []
        rows.append(("model", model.map { "\(current) · \(Reads.str($0["name"]))" } ?? current, list(models.map { Reads.str($0["id"]) })))
        if let effort = data["effort"] as? String { rows.append(("effort", effort, list(model?["efforts"] as? [String] ?? []))) }
        let mode = modes.first { Reads.str($0["id"]) == Reads.str(data["mode"]) }
        let lower = modes.filter { $0["allowed"] as? Bool == true && Reads.str($0["id"]) != Reads.str(data["mode"]) }.map { Reads.str($0["label"]) }
        rows.append(("mode", mode.map { Reads.str($0["label"]) } ?? Reads.str(data["mode"]), lower.isEmpty ? "" : "lower: " + lower.joined(separator: ", ")))
        if let fast = data["fast"] as? Bool { rows.append(("fast", fast ? "on" : "off", "")) }
        let width = rows.map { $0.1.count }.max() ?? 0
        for (key, value, more) in rows { Reads.say("\(Reads.pad(key, 6))  " + (more.isEmpty ? value : "\(Reads.pad(value, width))  \(more)")) }
    }

    private static func list(_ items: [String]) -> String { items.isEmpty ? "" : "(\(items.joined(separator: ", ")))" }
}

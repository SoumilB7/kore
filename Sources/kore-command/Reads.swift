import Darwin
import Foundation

/// `kore ls`, `show`, `log`, `pending`, `history`, `whoami`, `caps`: one command to Kore each,
/// printed short for a person, or as Kore sent it with `--json`.
enum Reads {
    typealias Object = AgentClient.Object

    /// Exit codes: 0 done, 1 not found or failed, 2 usage, 5 refused (agent control off, no access).
    static func run(_ name: String, _ rest: [String]) -> Int32 {
        if name == "mcp" { return MCPServer.run() }
        var options = Options(rest)
        guard options.problem == nil else { return fail(options.problem ?? "", code: 2) }
        if ["show", "log"].contains(name), options.positional.isEmpty {
            return fail(name == "show" ? "kore show <chat>" : "kore log <chat> [-n N] [-f]", code: 2)
        }
        do {
            let client = try AgentClient()
            switch name {
            case "whoami": try whoami(client, options)
            case "caps": try caps(client, options)
            case "ls": try ls(client, options)
            case "show": try show(client, options.positional[0], options)
            case "log": try log(client, options.positional[0], &options)
            case "pending": try pending(client, options)
            case "history": try history(client, options)
            default: return fail(usage, code: 2)
            }
            return 0
        } catch .unreachable {
            return fail("Kore isn't running, or agent control is off.", code: 5)
        } catch .refused(let code, let message) {
            return fail(message, code: ["denied", "mismatch", "tier", "stopped", "version", "rate_limited"].contains(code) ? 5 : 1)
        } catch {
            return fail("Kore closed the connection.", code: 1)
        }
    }

    static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("kore: \(message)\n".utf8))
        return code
    }

    struct Options {
        var json = false
        var follow = false
        var archived = false
        var last: Int?
        var folder: String?
        var search: String?
        var positional: [String] = []
        var problem: String?

        init(_ args: [String]) {
            var rest = args[...]
            while let arg = rest.popFirst() {
                switch arg {
                case "--json": json = true
                case "-f", "--follow": follow = true
                case "--archived": archived = true
                case "-n", "--last":
                    guard let n = rest.popFirst().flatMap({ Int($0) }), n > 0 else { problem = "\(arg) takes a number"; return }
                    last = n
                case "--folder":
                    guard let f = rest.popFirst() else { problem = "--folder takes a folder"; return }
                    folder = f
                case "--search":
                    guard let q = rest.popFirst() else { problem = "--search takes words"; return }
                    search = q
                default:
                    if arg.hasPrefix("-"), arg.count > 1 { problem = "unknown option \(arg)"; return }
                    positional.append(arg)
                }
            }
        }
    }

    // MARK: Commands

    static func whoami(_ client: AgentClient, _ o: Options) throws(AgentClient.Failure) {
        let data = try client.run("agent.whoami")
        if o.json { return printJSON(data) }
        let caller = data["caller"] as? Object ?? [:]
        let tier = data["tier"] as? String ?? "off"
        if caller["class"] as? String == "chat" {
            print("chat \(str(caller["short"]))  \(str(caller["title"]))  · \(tier)")
        } else {
            print("external · \(tier)")
        }
    }

    static func caps(_ client: AgentClient, _ o: Options) throws(AgentClient.Failure) {
        let data = try client.run("agent.caps")
        if o.json { return printJSON(data) }
        print("Kore access: \(str(data["tier"]))")
        for command in data["commands"] as? [String] ?? [] { print("  \(command)") }
    }

    static func ls(_ client: AgentClient, _ o: Options) throws(AgentClient.Failure) {
        let data = try client.run("chats.list")
        if o.json { return printJSON(data) }
        let chats = data["chats"] as? [Object] ?? []
        guard !chats.isEmpty else { return print("No chats are open.") }
        let state = width(chats, "state"), provider = width(chats, "provider")
        for chat in chats {
            var line = "\(str(chat["short"]))  \(pad(str(chat["state"]), state))  \(pad(str(chat["provider"]), provider))  \(str(chat["title"]))"
            line += "  · \(str(chat["window"]))"
            if let cards = chat["cards"] as? Int, cards > 0 { line += cards == 1 ? "  · 1 card" : "  · \(cards) cards" }
            if chat["own"] as? Bool == true { line += "  (this chat)" }
            print(line)
        }
    }

    static func show(_ client: AgentClient, _ ref: String, _ o: Options) throws(AgentClient.Failure) {
        let data = try client.run("chat.show", ["chat": ref])
        if o.json { return printJSON(data) }
        let chat = data["chat"] as? Object ?? [:]
        print(str(chat["title"]))
        var rows: [(String, String)] = [("id", str(chat["id"])), ("state", str(chat["state"]))]
        var cli = str(chat["provider"])
        if let model = chat["model"] as? String { cli += " · \(model)" }
        if let effort = data["effort"] as? String { cli += " · \(effort)" }
        rows.append(("cli", cli))
        var mode = (chat["modeLabel"] as? String) ?? str(chat["mode"])
        if chat["planOn"] as? Bool == true { mode += " · plan" }
        rows.append(("mode", mode))
        rows.append(("folder", str(chat["folder"])))
        if let context = data["context"] as? Object, let used = context["used"] as? Int {
            var text = context["pct"].map { "\($0)% · " } ?? ""
            text += tokens(used)
            if let window = context["window"] as? Int { text += " of \(tokens(window))" }
            rows.append(("context", text))
        }
        if let session = data["session"] as? String { rows.append(("session", session)) }
        if let queued = chat["queued"] as? Int, queued > 0 { rows.append(("queued", "\(queued)")) }
        for (key, value) in rows { print("  \(pad(key, 8))  \(value)") }
        for card in data["pending"] as? [Object] ?? [] { print("  waiting   \(str(card["kind"])): \(str(card["title"]))") }
    }

    static func log(_ client: AgentClient, _ ref: String, _ o: inout Options) throws(AgentClient.Failure) {
        var args: Object = ["chat": ref]
        if let last = o.last { args["last"] = last }
        guard o.follow else {
            let data = try client.run("tx.read", args)
            if o.json { return printJSON(data) }
            Rows.printAll(data["rows"] as? [Object] ?? [])
            return
        }
        let data = try client.run("tx.follow", args)
        client.timeout(0)
        var rows = Rows()
        if o.json { printJSON(data) } else { rows.take(data["rows"] as? [Object] ?? [], settled: false) }
        // Until Kore closes the connection, or the chat goes. ^C ends it.
        while let raw = try client.nextRaw() {
            guard let line = (try? JSONSerialization.jsonObject(with: raw)) as? Object, line["type"] as? String == "event" else { continue }
            if o.json {
                FileHandle.standardOutput.write(raw + Data([0x0A]))
            } else {
                switch line["event"] as? String {
                case "row": if let row = line["row"] as? Object { rows.take([row], settled: false) }
                case "state":
                    let state = str(line["state"])
                    if state != "working" { rows.settle() }
                    print("· \(state)")
                case "gone": print("· closed")
                default: break
                }
            }
            if line["event"] as? String == "gone" { break }
        }
    }

    static func pending(_ client: AgentClient, _ o: Options) throws(AgentClient.Failure) {
        var args: Object = [:]
        if let chat = o.positional.first { args["chat"] = chat }
        let data = try client.run("cards.list", args)
        if o.json { return printJSON(data) }
        let cards = data["cards"] as? [Object] ?? []
        guard !cards.isEmpty else { return print("Nothing is waiting.") }
        for card in cards {
            print("\(str(card["chatShort"]))  \(str(card["chatTitle"]))  · \(str(card["kind"])): \(str(card["title"]))")
            if let detail = card["detail"] as? String, !detail.isEmpty { print("    \(oneLine(detail))") }
            for question in card["questions"] as? [Object] ?? [] {
                let options = (question["options"] as? [String] ?? []).joined(separator: " / ")
                print("    \(oneLine(str(question["text"])))" + (options.isEmpty ? "" : "  [\(options)]"))
            }
        }
    }

    static func history(_ client: AgentClient, _ o: Options) throws(AgentClient.Failure) {
        var args: Object = ["cwd": FileManager.default.currentDirectoryPath]
        if let folder = o.folder { args["folder"] = folder }
        if let search = o.search { args["query"] = search }
        if o.archived { args["archived"] = true }
        let data = try client.run("history.list", args)
        if o.json { return printJSON(data) }
        let sessions = data["sessions"] as? [Object] ?? []
        guard !sessions.isEmpty else { return print("No past chats in \(str(data["folder"])).") }
        let parse = ISO8601DateFormatter()
        let show = DateFormatter()
        show.dateFormat = "MMM d HH:mm"
        let provider = width(sessions, "provider")
        for s in sessions {
            let when = (s["updated"] as? String).flatMap(parse.date(from:)).map(show.string(from:)) ?? ""
            print("\(pad(when, 12))  \(pad(str(s["provider"]), provider))  \(str(s["title"]))" + (s["open"] as? Bool == true ? "  (open)" : ""))
        }
        if data["more"] as? Bool == true { print("…") }
    }

    // MARK: Text

    static func str(_ value: Any?) -> String {
        switch value {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    static func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }

    static func width(_ rows: [Object], _ key: String) -> Int { rows.map { str($0[key]).count }.max() ?? 0 }

    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    static func tokens(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

    static func printJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}

/// A transcript's rows as text: a row shows once it's settled (done, stopped, or one that never
/// streams), and once only.
struct Rows {
    typealias Object = AgentClient.Object
    private var shown = Set<String>()
    private var waiting: [String: Object] = [:]
    private var order: [String] = []

    static let steady: Set = ["user", "notice", "peer", "divider", "mode", "summary"]

    static func printAll(_ rows: [Object]) {
        var printer = Rows()
        printer.take(rows, settled: true)
    }

    mutating func take(_ rows: [Object], settled: Bool) {
        for row in rows {
            let id = Reads.str(row["id"])
            guard !shown.contains(id) else { continue }
            let kind = Reads.str(row["kind"])
            if settled || row["done"] as? Bool == true || row["stopped"] as? Bool == true || row["error"] as? Bool == true || Self.steady.contains(kind) {
                waiting[id] = nil
                order.removeAll { $0 == id }
                show(row)
            } else {
                if waiting[id] == nil { order.append(id) }
                waiting[id] = row
            }
        }
    }

    /// The turn ended: what's still waiting shows as it last was.
    mutating func settle() {
        let rows = order.compactMap { waiting[$0] }
        order = []
        waiting = [:]
        for row in rows { show(row) }
    }

    private mutating func show(_ row: Object) {
        shown.insert(Reads.str(row["id"]))
        let text = Reads.str(row["text"])
        let cut = row["textLen"] != nil ? " …" : ""
        switch Reads.str(row["kind"]) {
        case "thinking": return
        case "user": print("\n› " + indented(text, "  ") + cut)
        case "answer", "plan", "summary": print(text + cut)
        case "tool":
            let tool = row["tool"] as? Object ?? [:]
            let what = [Reads.str(tool["summary"]), Reads.str(tool["path"])].first { !$0.isEmpty } ?? ""
            print("· \(Reads.str(tool["name"]))" + (what.isEmpty ? "" : " \(Reads.oneLine(what))") + (row["error"] as? Bool == true ? "  ✗" : ""))
        case "agent": print("◦ \(Reads.str(row["agent"])): \(Reads.oneLine(text))")
        case "peer": print("« " + indented(text, "  "))
        case "notice": print("! " + Reads.oneLine(text))
        default: if !text.isEmpty { print("— \(Reads.oneLine(text)) —") }
        }
    }

    private func indented(_ text: String, _ prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n" + prefix)
    }
}

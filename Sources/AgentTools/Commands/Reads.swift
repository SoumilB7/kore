import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `kore ls`, `show`, `log`, `pending`, `history`, `whoami`, `caps`: one command to Kore each,
/// printed short for a person, or as Kore sent it with `--json`.
package enum Reads {
    typealias Object = AgentTools.Object

    /// Exit codes: 0 done, 1 not found or failed, 2 usage, 5 refused (agent control off, no access).
    /// `connect`: a caller of Kore's (the Mac's agent socket, or a box's); `unreachable`: what it
    /// says when there's none.
    package static func run(_ name: String, _ rest: [String], unreachable: String, connect: () throws(AgentFailure) -> any AgentCalls) -> Int32 {
        var options = Options(rest)
        guard options.problem == nil else { return fail(options.problem ?? "", code: 2) }
        if ["show", "log"].contains(name), options.positional.isEmpty {
            return fail(name == "show" ? "kore show <chat>" : "kore log <chat> [-n N] [-f]", code: 2)
        }
        if let wanted = Own.usage[name], !Own.fits(name, options.positional) { return fail("kore \(name) \(wanted)", code: 2) }
        if let wanted = Drive.usage[name], !Drive.fits(name, options) { return fail("kore \(name) \(wanted)", code: 2) }
        do {
            let client = try connect()
            switch name {
            case "whoami": try whoami(client, options)
            case "caps": try caps(client, options)
            case "ls": try ls(client, options)
            case "show": try show(client, options.positional[0], options)
            case "log": try log(client, options.positional[0], &options)
            case "pending": try pending(client, options)
            case "history": try history(client, options)
            case "options": try Own.options(client, options)
            case "fast", "compact", "rename", "model", "effort", "mode": try Own.set(name, client, options)
            case "new", "fork", "send", "stop", "tab", "answer", "wait", "open", "close", "ask", "reply", "fetch": try Drive.run(name, client, options)
            default: return fail("no such command: \(name)", code: 2)
            }
            return 0
        } catch .unreachable {
            return fail(unreachable, code: 5)
        } catch .notKore {
            return fail("What's at Kore's socket isn't the Kore this came with.", code: 5)
        } catch .refused(let code, let message) {
            return fail(message, code: ["denied", "mismatch", "tier", "stopped", "version", "rate_limited", "not_own"].contains(code) ? 5 : 1)
        } catch .timedOut {
            return fail(AgentTools.noAnswerLine, code: 1)
        } catch {
            return fail("Kore closed the connection.", code: 1)
        }
    }

    /// Their usage lines, for `kore help` on the Mac and on a box.
    package static let usage = """
        kore ls               the open chats
               kore show <chat>      one chat: state, model, context, waiting cards
               kore log <chat> [-n N] [-f]
                                     its last rows; -f follows it
               kore pending [<chat>] cards waiting on you
               kore history [--folder F] [--search Q] [--archived]
                                     a window's past chats
               kore options          what Act limited may set on this chat now
               kore rename <name>    rename this chat
               kore model <model>    switch this chat's model
               kore effort <level>   set its effort
               kore fast on|off      its fast mode
               kore mode <mode>      lower its mode (only you raise one)
               kore compact          compact it, once this turn ends
               kore new [--claude|--codex] [--model M] [--mode X] [--folder F] [--silent] ["message"]
                                     a new chat in this window, in front (Act unlimited); --folder:
                                     another folder's window, opened if none is (path or device:path,
                                     Act device); --silent: the tab in front stays, Kore stays behind.
                                     Silent for several chats, background workers, fan-out, tabs the
                                     user didn't ask to see; in front for one chat the user wants to
                                     read. Unclear: one in front, several silent
               kore fork <chat> [--at -N|<message>] [--claude|--codex] [--model M] ["message"]
                                     fork a chat (. for this one) into a tab in front (Act unlimited)
               kore wait <chat> [--timeout s]
                                     until its turn ends or a card asks: its answer
               kore ask <short id> "question"
                                     ask another Act unlimited chat; kore wait --ask <id> for the answer
               kore reply <ask id> "answer" [file]
                                     answer an ask this chat was asked, a file of its folder with it
               kore fetch <device:path | path>
                                     copy a file from an open folder into .kore/inbox/ (50 MB, no secrets;
                                     another device's needs Act device)
               kore send <chat> "message" [--folder F] [--silent]
                                     send to another chat, queued while it works; one that isn't
                                     open (closed, in History: its id or title) opens first
               kore stop <chat>      stop its turn
               kore tab <chat>       bring its tab to the front
               kore open <session> [--folder F] [--silent]
                                     open a past chat (kore history lists them) in front
               kore close <short id> close a chat as its tab's close does; History keeps it
               kore answer <chat> <card> <answer>... | --deny | --allow | --always
                                     answer a question card, one answer per question
               kore whoami           who Kore sees calling, and its access
               kore caps             what that access allows
        """

    package static let notes = """
        Act limited's commands change the chat they run in, or with Act unlimited a chat named first:
        kore model <chat> <model>. Act unlimited reaches the chats it can read at or below this chat's mode.
        A chat is its title (any part only it has), its short id, or . for the chat this runs in.
        Every read takes --json.
        """

    /// The commands that go to Kore (`run`), by name.
    package static let names: Set = [
        "ls", "show", "log", "pending", "history", "whoami", "caps", "options", "rename", "model", "effort", "fast", "mode", "compact", "new", "fork",
        "send", "stop", "tab", "answer", "wait", "open", "close", "ask", "reply", "fetch",
    ]

    package static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data(safe("kore: \(message)\n").utf8))
        return code
    }

    struct Options {
        var json = false
        var follow = false
        var archived = false
        var last: Int?
        var folder: String?
        var search: String?
        /// Drive's `new`: the CLI, model and mode; `answer --deny`.
        var provider: String?
        var model: String?
        var mode: String?
        /// `new --place`: a box chat's new chat on its box (the default) or the Mac.
        var place: String?
        var deny = false
        /// `new`, `open` and `send --silent`: the tab in front stays, Kore isn't activated.
        var silent = false
        /// `answer --allow`: a permission card allowed once.
        var allow = false
        /// `answer --always`: Always allow on an Auto-asks card.
        var always = false
        /// `wait --ask`: an ask's id.
        var ask: String?
        /// `fork --at`, `wait --timeout`.
        var at: String?
        var timeout: Int?
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
                case "--claude", "--codex": provider = String(arg.dropFirst(2))
                case "--model":
                    guard let m = rest.popFirst() else { problem = "--model takes a model"; return }
                    model = m
                case "--mode":
                    guard let m = rest.popFirst() else { problem = "--mode takes a mode"; return }
                    mode = m
                case "--place":
                    guard let m = rest.popFirst() else { problem = "--place takes box or mac"; return }
                    place = m
                case "--deny": deny = true
                case "--silent": silent = true
                case "--allow": allow = true
                case "--always": always = true
                case "--at":
                    guard let m = rest.popFirst() else { problem = "--at takes a message"; return }
                    at = m
                case "--ask":
                    guard let a = rest.popFirst() else { problem = "--ask takes an ask's id"; return }
                    ask = a
                case "--timeout":
                    guard let n = rest.popFirst().flatMap({ Int($0) }), n > 0 else { problem = "--timeout takes seconds"; return }
                    timeout = n
                default:
                    if arg.hasPrefix("-"), arg.count > 1 { problem = "unknown option \(arg)"; return }
                    positional.append(arg)
                }
            }
        }
    }

    // MARK: Commands

    static func whoami(_ client: any AgentCalls, _ o: Options) throws(AgentFailure) {
        let data = try client.run("agent.whoami")
        if o.json { return printJSON(data) }
        let caller = data["caller"] as? Object ?? [:]
        let tier = data["tier"] as? String ?? "off"
        if caller["class"] as? String == "chat" {
            say("chat \(str(caller["short"]))  \(str(caller["title"]))  · \(tierName(tier))")
        } else {
            say("external · \(tierName(tier))")
        }
    }

    static func tierName(_ id: String) -> String { AgentTools.tierName(id) }

    static func caps(_ client: any AgentCalls, _ o: Options) throws(AgentFailure) {
        let data = try client.run("agent.caps")
        if o.json { return printJSON(data) }
        say("Kore access: \(tierName(str(data["tier"])))")
        for command in data["commands"] as? [String] ?? [] { say("  \(command)") }
    }

    static func ls(_ client: any AgentCalls, _ o: Options) throws(AgentFailure) {
        let data = try client.run("chats.list")
        if o.json { return printJSON(data) }
        let chats = data["chats"] as? [Object] ?? []
        guard !chats.isEmpty else { return say("No chats are open.") }
        let state = width(chats, "state"), provider = width(chats, "provider")
        for chat in chats {
            var line = "\(str(chat["short"]))  \(pad(str(chat["state"]), state))  \(pad(str(chat["provider"]), provider))  \(str(chat["title"]))"
            line += "  · \(str(chat["window"]))"
            if let cards = chat["cards"] as? Int, cards > 0 { line += cards == 1 ? "  · 1 card" : "  · \(cards) cards" }
            if chat["own"] as? Bool == true { line += "  (this chat)" }
            say(line)
        }
    }

    static func show(_ client: any AgentCalls, _ ref: String, _ o: Options) throws(AgentFailure) {
        let data = try client.run("chat.show", ["chat": ref])
        if o.json { return printJSON(data) }
        let chat = data["chat"] as? Object ?? [:]
        say(str(chat["title"]))
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
        for (key, value) in rows { say("  \(pad(key, 8))  \(value)") }
        for card in data["pending"] as? [Object] ?? [] { say("  waiting   \(str(card["kind"])): \(str(card["title"]))") }
    }

    static func log(_ client: any AgentCalls, _ ref: String, _ o: inout Options) throws(AgentFailure) {
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
        // Each line as it's printed, into a pipe too (an agent's shell reads one).
        setvbuf(stdout, nil, _IOLBF, 0)
        var rows = Rows()
        if o.json { printJSON(data) } else { rows.take(data["rows"] as? [Object] ?? [], settled: false) }
        // Until Kore closes the connection, or the chat goes. ^C ends it.
        while let raw = try client.nextRaw() {
            guard let line = (try? JSONSerialization.jsonObject(with: raw)) as? Object, line["type"] as? String == "event" else { continue }
            if o.json {
                FileHandle.standardOutput.write(safeJSON(raw) + Data([0x0A]))
            } else {
                switch line["event"] as? String {
                case "row": if let row = line["row"] as? Object { rows.take([row], settled: false) }
                case "state":
                    let state = str(line["state"])
                    if state != "working" { rows.settle() }
                    say("· \(state)")
                case "gone": say("· closed")
                default: break
                }
            }
            if line["event"] as? String == "gone" { break }
        }
    }

    static func pending(_ client: any AgentCalls, _ o: Options) throws(AgentFailure) {
        var args: Object = [:]
        if let chat = o.positional.first { args["chat"] = chat }
        let data = try client.run("cards.list", args)
        if o.json { return printJSON(data) }
        let cards = data["cards"] as? [Object] ?? []
        guard !cards.isEmpty else { return say("Nothing is waiting.") }
        for card in cards {
            say("\(str(card["chatShort"]))  \(str(card["chatTitle"]))  · \(str(card["kind"])): \(str(card["title"]))  · card \(str(card["id"]))")
            if let detail = card["detail"] as? String, !detail.isEmpty { say("    \(oneLine(detail))") }
            for question in card["questions"] as? [Object] ?? [] {
                let options = (question["options"] as? [String] ?? []).joined(separator: " / ")
                say("    \(oneLine(str(question["text"])))" + (options.isEmpty ? "" : "  [\(options)]"))
            }
        }
    }

    static func history(_ client: any AgentCalls, _ o: Options) throws(AgentFailure) {
        var args: Object = [:]
        if let folder = o.folder { args["folder"] = folder }
        if let search = o.search { args["query"] = search }
        if o.archived { args["archived"] = true }
        let data = try client.run("history.list", args)
        if o.json { return printJSON(data) }
        let sessions = data["sessions"] as? [Object] ?? []
        guard !sessions.isEmpty else { return say("No past chats in \(str(data["folder"])).") }
        let parse = ISO8601DateFormatter()
        let show = DateFormatter()
        show.dateFormat = "MMM d HH:mm"
        let provider = width(sessions, "provider")
        for s in sessions {
            let when = (s["updated"] as? String).flatMap(parse.date(from:)).map(show.string(from:)) ?? ""
            // The session's start, for `kore open`.
            say("\(pad(when, 12))  \(String(str(s["id"]).prefix(8)))  \(pad(str(s["provider"]), provider))  \(str(s["title"]))" + (s["open"] as? Bool == true ? "  (open)" : ""))
        }
        if data["more"] as? Bool == true { say("…") }
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
        FileHandle.standardOutput.write(safeJSON(data) + Data([0x0A]))
    }

    /// A line for a terminal: what chats hold can't move its cursor or retitle it.
    static func say(_ line: String) { print(safe(line)) }

    /// Text without C0 or C1 controls (or DEL), but for newlines and tabs.
    package static func safe(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)) {
            out.append(scalar)
        }
        return String(out)
    }

    /// JSON whose DEL and C1 controls, which JSON leaves as they are, are escaped: the same text,
    /// and safe in a terminal. (C0 controls are escaped already.)
    static func safeJSON(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var bytes = data.makeIterator()
        var pending = bytes.next()
        while let byte = pending {
            pending = bytes.next()
            if byte == 0x7F {
                out.append(contentsOf: Array("\\u007f".utf8))
            } else if byte == 0xC2, let next = pending, (0x80...0x9F).contains(next) {
                out.append(contentsOf: Array(String(format: "\\u%04x", Int(next)).utf8))
                pending = bytes.next()
            } else {
                out.append(byte)
            }
        }
        return out
    }
}

/// A transcript's rows as text: a row shows once it's settled (done, stopped, or one that never
/// streams), and once only.
struct Rows {
    typealias Object = AgentTools.Object
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
        case "user": Reads.say("\n› " + indented(text, "  ") + cut)
        case "answer", "plan", "summary": Reads.say(text + cut)
        case "tool":
            let tool = row["tool"] as? Object ?? [:]
            let what = [Reads.str(tool["summary"]), Reads.str(tool["path"])].first { !$0.isEmpty } ?? ""
            Reads.say("· \(Reads.str(tool["name"]))" + (what.isEmpty ? "" : " \(Reads.oneLine(what))") + (row["error"] as? Bool == true ? "  ✗" : ""))
        case "agent": Reads.say("◦ \(Reads.str(row["agent"])): \(Reads.oneLine(text))")
        case "peer": Reads.say("« " + indented(text, "  "))
        case "notice": Reads.say("! " + Reads.oneLine(text))
        default: if !text.isEmpty { Reads.say("— \(Reads.oneLine(text)) —") }
        }
    }

    private func indented(_ text: String, _ prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n" + prefix)
    }
}

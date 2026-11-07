import AppKit
import Darwin
import Foundation
import KoreCore
import KoreLink
import KoreUI

// The agent channel checked whole (`z-docs/agent-protocol.md`): every read through the built
// `kore` run the way an agent runs it, from inside a chat's process tree with that chat's pass,
// and every refusal (switch, grants, identity, tier, rate), the audit lines, the ways it closes,
// and `kore mcp`. `AgentChannelCost` measures what the channel costs while Kore runs.

/// A tag for the agent channel's own runs (`--tag agent`), apart from the gate.
extension Tag {
    static let agentChannel: Tag = "agent"
    static let agentCost: Tag = "agentcost"
    static let agentQuit: Tag = "agentquit"
}

/// The chats a storyline gave roles to (`a`, `b`, …), its followers, and what it put back at the
/// end, pass or fail: no grant, the switch off, no socket folder.
@MainActor
final class AgentCast: StoryFinishing {
    /// The second folder's path, for a run with a chat in another window.
    var otherFolder: String?
    var chats: [String: Chat] = [:]
    var followers: [String: KoreRun] = [:]
    var notes: [String] = []
    var directory: URL?
    /// Keeps the host out of App Nap while it measures (a shown Kore window isn't napped).
    var activity: NSObjectProtocol?

    func chat(_ role: String) throws -> Chat {
        guard let chat = chats[role] else { throw StoryFailure.modelMissing("the chat “\(role)”") }
        return chat
    }

    func id(_ role: String) throws -> String { try chat(role).id.uuidString }
    func short(_ role: String) throws -> String { String(try id(role).prefix(8)).lowercased() }

    /// `{a}` → chat a's short id, `{a.id}` → its id, `{a.title}` → its title, `{sock}` → the socket.
    func fill(_ text: String) throws -> String {
        var out = text.replacingOccurrences(of: "{sock}", with: AgentWatchReads.socketPath)
        if let otherFolder { out = out.replacingOccurrences(of: "{d.folder}", with: otherFolder) }
        for (role, chat) in chats {
            out = out.replacingOccurrences(of: "{\(role).id}", with: chat.id.uuidString)
            out = out.replacingOccurrences(of: "{\(role).title}", with: chat.title)
            out = out.replacingOccurrences(of: "{\(role)}", with: String(chat.id.uuidString.prefix(8)).lowercased())
        }
        return out
    }

    func note(_ line: String, to outputs: URL) {
        notes.append(line)
        let url = outputs.appendingPathComponent("agent-notes.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func finish() {
        for run in followers.values { run.stop() }
        followers = [:]
        AgentGrants.stopAll()
        AgentGrants.setEnabled(false)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    static func of(_ story: StoryContext) -> AgentCast { story.stash(AgentCast.self) { AgentCast() } }
}

/// Who runs `kore`.
enum KoreCaller {
    /// Outside every chat (a terminal), with no pass, or with chat `copied`'s pass.
    case outside(copied: String? = nil)
    /// Under chat `role`'s CLI with its own pass.
    case chat(String)
    /// Under chat `tree`'s CLI carrying chat `pass`'s pass (nil: none; "?": one Kore never made).
    case tree(String, pass: String?)

    var label: String {
        switch self {
        case .outside(nil): "outside"
        case .outside(let copied?): "outside, \(copied)'s pass"
        case .chat(let role): "in \(role)"
        case .tree(let tree, let pass): "in \(tree)'s tree, \(pass.map { $0 == "?" ? "a made-up pass" : "\($0)'s pass" } ?? "no pass")"
        }
    }

    @MainActor
    func resolve(_ cast: AgentCast) throws -> (pass: String?, under: String?) {
        func pass(_ role: String) throws -> String { role == "?" ? AgentPasses.make() : try cast.chat(role).agentPass }
        switch self {
        case .outside(let copied): return (try copied.map(pass), nil)
        case .chat(let role): return (try pass(role), try pass(role))
        case .tree(let tree, let role): return (try role.map(pass), try pass(tree))
        }
    }
}

/// Runs `kore <arguments>` to its end as `caller` and checks its exit status and output.
struct KoreAs: Step {
    let arguments: [String]
    let caller: KoreCaller
    let what: String
    var input: String?
    var executable: URL?
    var environment: [String: String] = [:]
    let check: @MainActor (Int32, String, StoryContext) throws -> Bool
    var label: String { "kore \(arguments.joined(separator: " ")) (\(caller.label)): \(what)" }
    var timeout: Duration? { .seconds(20) }

    init(_ arguments: [String], _ caller: KoreCaller, _ what: String, input: String? = nil, _ check: @escaping @MainActor (Int32, String, StoryContext) throws -> Bool) {
        self.arguments = arguments
        self.caller = caller
        self.what = what
        self.input = input
        self.check = check
    }

    /// Exits 0 and prints every one of `expect` (placeholders filled).
    init(_ arguments: [String], _ caller: KoreCaller, _ what: String, expect: [String]) {
        self.init(arguments, caller, what) { status, out, story in
            let cast = AgentCast.of(story)
            return try status == 0 && expect.allSatisfy { out.contains(try cast.fill($0)) }
        }
    }

    /// Exits `status` and says `says`.
    init(_ arguments: [String], _ caller: KoreCaller, _ what: String, status wanted: Int32, says: String) {
        self.init(arguments, caller, what) { status, out, _ in status == wanted && out.contains(says) }
    }

    /// Exits 0 with one JSON object that `check` likes.
    static func json(_ arguments: [String], _ caller: KoreCaller, _ what: String, _ check: @escaping @MainActor ([String: Any], AgentCast) throws -> Bool) -> KoreAs {
        KoreAs(arguments + ["--json"], caller, what) { status, out, story in
            guard status == 0, let object = AgentJSON.objects(out).first else { return false }
            return try check(object, AgentCast.of(story))
        }
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        let (pass, under) = try caller.resolve(cast)
        let run = KoreRun()
        try run.start(
            try arguments.map(cast.fill), pass: pass, under: under, input: try input.map { Data(try cast.fill($0).utf8) }, executable: executable,
            environment: environment)
        try await story.until("kore to exit", timeout: timeout) { run.status != nil }
        let status = run.status ?? -1
        let ms = run.elapsed.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 } ?? -1
        cast.note(String(format: "run %@ (%@) exit=%d ms=%.1f", arguments.joined(separator: " "), caller.label, status, ms), to: story.outputs)
        guard try check(status, run.output, story) else {
            throw StoryFailure.expectation("\(what) (exit \(status): \(run.output.prefix(600)))")
        }
    }
}

/// The agent channel's lines as they come: a hello (with the caller's pass), `lines`, and the
/// welcome or bye plus `replies` lines back, through a bare socket (zsh's zsocket), as `caller`.
struct RawLines: Step {
    let lines: [String]
    let replies: Int
    let caller: KoreCaller
    let what: String
    var helloExtra: String?
    let check: @MainActor ([[String: Any]], AgentCast) throws -> Bool
    var label: String { "\(lines.count) raw line(s) (\(caller.label)): \(what)" }
    var timeout: Duration? { .seconds(20) }

    init(_ lines: [String], replies: Int, _ caller: KoreCaller, _ what: String, helloExtra: String? = nil, _ check: @escaping @MainActor ([[String: Any]], AgentCast) throws -> Bool) {
        self.lines = lines
        self.replies = replies
        self.caller = caller
        self.what = what
        self.helloExtra = helloExtra
        self.check = check
    }

    static let script = """
        zmodload zsh/net/socket || exit 9
        zsocket $KORE_AGENT_SOCKET || exit 8
        fd=$REPLY
        hello='{"type":"hello","proto":1,"client":"raw"'
        [[ -n ${KORE_AGENT_PASS-} ]] && hello+=',"pass":"'$KORE_AGENT_PASS'"'
        [[ -n ${RAW_HELLO_EXTRA-} ]] && hello+=",$RAW_HELLO_EXTRA"
        print -r -u $fd -- "$hello}"
        while IFS= read -r line; do print -r -u $fd -- "$line"; done
        for (( i = 0; i <= $1; i++ )); do IFS= read -r -t 5 -u $fd reply || break; print -r -- "$reply"; done
        """

    /// A command line.
    static func cmd(_ id: String, _ name: String, _ args: String = "{}") -> String {
        "{\"type\":\"cmd\",\"id\":\"\(id)\",\"cmd\":\"\(name)\",\"args\":\(args)}"
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        let script = story.outputs.appendingPathComponent("agent-raw.zsh")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let (pass, under) = try caller.resolve(cast)
        let run = KoreRun()
        let input = try lines.map(cast.fill).map { $0 + "\n" }.joined()
        try run.start(
            [script.path, "\(replies)"], pass: pass, under: under, input: Data(input.utf8), executable: URL(fileURLWithPath: "/bin/zsh"),
            environment: helloExtra.map { ["RAW_HELLO_EXTRA": $0] } ?? [:])
        try await story.until("the raw client to finish", timeout: timeout) { run.status != nil }
        let objects = AgentJSON.objects(run.output)
        guard try check(objects, cast) else { throw StoryFailure.expectation("\(what) (got: \(run.output.prefix(800)))") }
    }
}

enum AgentJSON {
    static func objects(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    static func path(_ object: Any?, _ keys: String...) -> Any? {
        var value = object
        for key in keys { value = (value as? [String: Any])?[key] }
        return value
    }
}

/// Starts `kore log -f` (or any long `kore`) as `caller`, kept as `name` until stopped or ended.
struct StartFollower: Step {
    let name: String
    let arguments: [String]
    let caller: KoreCaller
    var label: String { "start “\(name)”: kore \(arguments.joined(separator: " ")) (\(caller.label))" }

    init(_ name: String, _ arguments: [String], _ caller: KoreCaller) {
        self.name = name
        self.arguments = arguments
        self.caller = caller
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        let (pass, under) = try caller.resolve(cast)
        let run = KoreRun()
        try run.start(try arguments.map(cast.fill), pass: pass, under: under)
        cast.followers[name] = run
        // Following once its first result is in.
        try await story.until("its first result") { !run.output.isEmpty || run.status != nil }
        guard run.status == nil else { throw StoryFailure.expectation("it ended at once: \(run.output.prefix(400))") }
    }
}

/// Checks what follower `name` printed (and whether it ended), waiting for it.
struct Followed: Step {
    let name: String
    let what: String
    let check: @MainActor (String, Int32?, AgentCast) throws -> Bool
    var label: String { "“\(name)” \(what)" }
    let timeout: Duration?

    init(_ name: String, _ what: String, timeout: Duration? = nil, _ check: @escaping @MainActor (String, Int32?, AgentCast) throws -> Bool) {
        self.name = name
        self.what = what
        self.timeout = timeout
        self.check = check
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        guard let run = cast.followers[name] else { throw StoryFailure.modelMissing("follower \(name)") }
        do {
            try await story.until(what) { try check(run.output, run.status, cast) }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("\(what) (status \(run.status.map(String.init) ?? "running"), printed: \(run.output.suffix(800)))")
        }
    }
}

/// A chat by role: the next tab's (a new one unless it's the first), the variant's provider.
struct CastChat: Step {
    let role: String
    let newTab: Bool
    var label: String { "chat “\(role)”" + (newTab ? " in a new tab" : "") }

    init(_ role: String, newTab: Bool = true) {
        self.role = role
        self.newTab = newTab
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        if newTab {
            guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
            let before = story.app.chat
            workspace.perform(.newTab)
            try await story.until("the new tab") { story.app.chat !== before || story.app.chat == nil }
            try await StartChat().run(story)
        }
        cast.chats[role] = try story.activeChat()
    }
}

/// Sends to chat `role` (whichever tab is shown) and waits for it to show.
struct SendTo: Step {
    let role: String
    let text: String
    var label: String { "send “\(text.prefix(40))” in \(role)" }

    init(_ role: String, _ text: String) {
        self.role = role
        self.text = text
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let chat = try AgentCast.of(story).chat(role)
        chat.storySend(text)
        try await story.until("the message in the chat") {
            story.chatEvents(chat).contains { if case .userMessage(let body, _, _) = $0 { body == text } else { false } }
        }
    }
}

/// Waits for chat `role`'s nth finished turn.
struct TurnsDone: Step {
    let role: String
    let n: Int
    let timeout: Duration?
    var label: String { "\(role)'s turn \(n) finished" }

    init(_ role: String, _ n: Int, timeout: Duration? = .seconds(60)) {
        self.role = role
        self.n = n
        self.timeout = timeout
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let chat = try AgentCast.of(story).chat(role)
        try await story.until("turn \(n) to finish") {
            story.chatEvents(chat).filter { if case .turnFinished = $0 { true } else { false } }.count >= n
        }
    }
}

/// Answers chat `role`'s first card (allow).
struct AllowIn: Step {
    let role: String
    var label: String { "allow \(role)'s card" }
    init(_ role: String) { self.role = role }

    @MainActor func run(_ story: StoryContext) async throws {
        let chat = try AgentCast.of(story).chat(role)
        let card = try await story.wait("a card") { chat.pendingApprovals.first }
        chat.storyAnswer(card, .allow)
        try await story.until("the card to go") { !chat.pendingApprovals.contains { $0.id == card.id } }
    }
}

/// Waits a while (a rate limit's minute), with nothing else going on.
private struct MinuteWait: Step {
    let seconds: Int
    var label: String { "wait \(seconds) s" }
    var timeout: Duration? { .seconds(seconds + 10) }
    @MainActor func run(_ story: StoryContext) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// The run's `ui.log` (`KORE_LOG_DIR`), every line written so far.
@MainActor
enum AgentAudit {
    static var url: URL? {
        guard let dir = ProcessInfo.processInfo.environment["KORE_LOG_DIR"], !["", "0", "off", "no"].contains(dir.lowercased()) else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent("ui.log")
    }

    static func lines() throws -> [String] {
        guard let url else { throw StoryFailure.other("run with KORE_LOG_DIR=<dir> so ui.log is written") }
        KoreLog.syncAll()
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// An agent line's event and fields.
    static func parse(_ line: String) -> (event: String, fields: [String: String])? {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let words = parts[1].split(separator: " ")
        guard let event = words.first, event.hasPrefix("agent-") else { return nil }
        var fields: [String: String] = [:]
        for word in words.dropFirst() {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        return (String(event), fields)
    }

    static func commands() throws -> [[String: String]] {
        try lines().compactMap(parse).filter { $0.event == "agent-cmd" }.map(\.fields)
    }
}

// MARK: - Everything, scripted

/// The agent channel end to end, both CLIs, through `kore` as an agent runs it. Chat a reads;
/// b checks identity and the rate limit; c tries what Watch can't. Then each way the channel
/// closes. Run with `KORE_LOG_DIR` set (the audit steps read `ui.log`).
final class AgentChannelAll: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel] }
    static let first = "Say hello"
    static let reply = "Hello, read by kore."
    static let second = "List the folder"
    static let listed = "Listed it."
    static let third = "Ask me something"
    static let fourth = "Write the long one"
    static let card = Approval(id: "ls1", title: "Run ls -la", detail: "List the folder", body: "ls -la", canAlwaysAllow: false, questions: [])
    static let question = Approval(
        id: "q1", title: "", detail: nil, body: nil, canAlwaysAllow: false,
        questions: [
            Approval.Question(id: "Which colour?", text: "Which colour?", header: "Colour", options: [.init(label: "Red", description: ""), .init(label: "Blue", description: "")])
        ])
    static let long = (1...40).map { "Sentence \($0) of the streamed answer, long enough to arrive in many pieces." }.joined(separator: " ")
    static let forbidden = [
        "chat.send", "chat.new", "chat.stop", "chat.queue", "chat.rename", "chat.model", "chat.effort", "chat.mode", "chat.compact",
        "chat.fork", "chat.rollback", "chat.close", "chat.archive", "cards.answer", "window.open", "file.open", "terminal.open",
        "usage.read", "tx.search", "chat.wait", "agent.setTier", "agent.grant", "agent.enable", "agent.stopAll",
    ]

    override class var script: CLIScript {
        CLIScript(turns: [
            CLIScript.reply(reply),
            [.startTurn, .approval(card, allow: Beat.answer(listed), deny: []), .finishTurn(.completed)],
            [.startTurn, .approval(question, allow: Beat.answer("Got it."), deny: []), .finishTurn(.completed)],
            [.startTurn, .stream(.answer, long), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kac-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var socket: String { directory.appendingPathComponent(AgentChannel.socketName).path }
        let exists = { FileManager.default.fileExists(atPath: socket) }
        func mode(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
        let a = KoreCaller.chat("a"), b = KoreCaller.chat("b"), c = KoreCaller.chat("c")
        let unreachable = "Kore isn't running, or agent control is off."
        var auditMark = 0
        let term = "term-out"

        return super.steps() + [
            Do("the cast, agent control in a folder of this run's, all off") { story in
                let cast = AgentCast.of(story)
                cast.chats["a"] = try story.activeChat()
                cast.directory = directory
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(false)
                _ = try AgentAudit.lines()
            },
            CastChat("b"), CastChat("c"),
            SendTo("a", Self.first), TurnsDone("a", 1),

            // 1. The switch off: nothing there, and `kore` says so at once.
            Do("grant a Watch with the switch off") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("a")) },
            Expect("1. switch off: no channel, no socket, no folder") { _ in
                AgentChannel.current == nil && !FileManager.default.fileExists(atPath: directory.path)
            },
            KoreAs(["ls"], a, "1. refused at once, plainly") { status, out, story in
                status == 5 && out.contains(unreachable) && (AgentCast.of(story).notes.last.map(Self.fast) ?? false)
            },

            // 2. On, but no grant.
            Do("switch on, no grants") { _ in
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
            },
            Expect("2. on with no grant: still no socket") { _ in AgentChannel.current == nil && !exists() },

            // 3. Watch: every read, short and --json.
            Do("grant a Watch") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("a")) },
            Expect("3. the socket 0600 in a 0700 folder", found: { _ in "socket \(mode(socket).map { String($0, radix: 8) } ?? "none"), folder \(mode(directory.path).map { String($0, radix: 8) } ?? "none")" }) { _ in
                AgentChannel.current != nil && mode(socket) == 0o600 && mode(directory.path) == 0o700
            },
            KoreAs(["whoami"], a, "this chat, watching", expect: ["chat {a}  {a.title}  · watch"]),
            KoreAs.json(["whoami"], a, "whoami's data") { o, cast in
                try AgentJSON.path(o, "caller", "class") as? String == "chat" && AgentJSON.path(o, "caller", "chat") as? String == cast.id("a")
                    && AgentJSON.path(o, "caller", "short") as? String == cast.short("a") && o["tier"] as? String == "watch" && o["proto"] as? Int == 1
            },
            KoreAs(["caps"], a, "the tier and its nine commands") { status, out, _ in
                status == 0 && out.contains("Kore access: watch") && AgentCommand.all.allSatisfy { out.contains("  \($0.name)\n") }
            },
            KoreAs.json(["caps"], a, "caps' data") { o, _ in
                o["tier"] as? String == "watch" && (o["commands"] as? [String]) == AgentCommand.all.map(\.name)
            },
            KoreAs(["ls"], a, "three chats, a marked as this one") { status, out, story in
                let cast = AgentCast.of(story)
                let lines = out.split(separator: "\n")
                guard status == 0, lines.count == 3 else { return false }
                let own = try lines.first { $0.hasPrefix(try cast.short("a")) }
                return own?.contains("(this chat)") == true && own?.contains("idle") == true && lines.filter { $0.contains("(this chat)") }.count == 1
            },
            KoreAs.json(["ls"], a, "ls' data") { o, cast in
                let chats = o["chats"] as? [[String: Any]] ?? []
                let ids = Set(chats.compactMap { $0["id"] as? String })
                return try ids == Set(["a", "b", "c"].map(cast.id)) && chats.filter { $0["own"] as? Bool == true }.map { $0["id"] as? String } == [try cast.id("a")]
                    && chats.allSatisfy { ["idle", "working", "needs-you"].contains($0["state"] as? String ?? "") && $0["provider"] as? String != nil }
            },
            KoreAs(["show", "."], a, "this chat in detail", expect: ["{a.title}\n", "  id        {a.id}", "  state     idle", "  folder    "]),
            KoreAs.json(["show", "{a}"], a, "show's data, by short id") { o, cast in
                try AgentJSON.path(o, "chat", "id") as? String == cast.id("a") && (o["rows"] as? Int ?? 0) >= 2 && (o["pending"] as? [Any])?.isEmpty == true
            },
            KoreAs(["log", "."], a, "the first turn", expect: ["› " + Self.first, Self.reply]),
            KoreAs(["log", ".", "-n", "1"], a, "only the last row") { status, out, _ in
                status == 0 && out.contains(Self.reply) && !out.contains(Self.first)
            },
            KoreAs.json(["log", ".", "-n", "1"], a, "one row, more before it") { o, cast in
                try (o["rows"] as? [Any])?.count == 1 && o["more"] as? Bool == true && o["chat"] as? String == cast.id("a")
            },
            KoreAs(["history"], a, "the window's past chats, short") { status, out, _ in
                status == 0 && (out.hasPrefix("No past chats in ") || !out.isEmpty)
            },
            KoreAs.json(["history"], a, "history's data") { o, _ in o["folder"] as? String != nil && o["sessions"] is [Any] && o["more"] is Bool },
            KoreAs(["show", "nothing-like-this"], a, "no such chat: exit 1", status: 1, says: "No open chat matches"),

            // A follow sees the next turns: a card, an answer, a streamed reply.
            Do("stream at 60 pieces a second") { _ in
                ScriptedWorld.shared.rate = 60
                for backend in ScriptedWorld.shared.backends { backend.rate = 60 }
            },
            StartFollower("text", ["log", ".", "-f"], a),
            StartFollower("json", ["log", "{a}", "-f", "--json", "-n", "1"], a),
            Expect("two followers, the taps on") { _ in AgentChannel.current?.connections == 2 && AgentTaps.on },
            SendTo("a", Self.second),
            Followed("json", "saw the message and the wait") { out, _, _ in
                out.contains("\"text\":\"\(Self.second)\"") && out.contains("\"state\":\"needs-you\"")
            },
            KoreAs(["pending"], a, "the approval card", expect: ["{a}  {a.title}  · permission: " + Self.card.title, "    " + (Self.card.detail ?? "")]),
            KoreAs.json(["pending"], a, "the card's data") { o, cast in
                let cards = o["cards"] as? [[String: Any]] ?? []
                return try cards.count == 1 && cards[0]["id"] as? String == "ls1" && cards[0]["kind"] as? String == "permission"
                    && cards[0]["chat"] as? String == cast.id("a")
            },
            AllowIn("a"), TurnsDone("a", 2),
            Followed("text", "printed the message, the wait, the answer and idle") { out, _, _ in
                out.contains("› " + Self.second) && out.contains("· needs-you") && out.contains(Self.listed) && out.hasSuffix("· idle\n")
            },
            SendTo("a", Self.third),
            KoreAs(["pending", "{a}"], a, "the question card, its options", expect: ["· questions: ", "Which colour?  [Red / Blue]"]),
            KoreAs.json(["pending"], a, "the question's data") { o, _ in
                let card = (o["cards"] as? [[String: Any]])?.first
                return card?["kind"] as? String == "questions" && (AgentJSON.path(card, "questions") as? [[String: Any]])?.first?["options"] as? [String] == ["Red", "Blue"]
            },
            Do("stop that turn") { story in try AgentCast.of(story).chat("a").storyStop() },
            TurnsDone("a", 3),
            // 180 s, not 60: this turn's wait is slow in the test harness (`story.chatEvents` filters every
            // event so far on each pass). It took 6.7 s run first, on Claude, and 38 s to over 60 s when
            // Codex ran second in the same host; Codex alone took 6.4 s. Why second is slower isn't traced.
            SendTo("a", Self.fourth), TurnsDone("a", 4, timeout: .seconds(180)),
            Followed("text", "printed the streamed answer whole, once") { out, _, _ in
                out.components(separatedBy: Self.long).count == 2 && out.hasSuffix("· idle\n")
            },
            Followed("json", "had the answer's row once, whole") { out, _, _ in
                let rows = AgentJSON.objects(out).filter { $0["event"] as? String == "row" }.compactMap { $0["row"] as? [String: Any] }
                let answer = rows.filter { ($0["text"] as? String).map { Self.long.hasPrefix($0) && $0.count > 40 } ?? false }
                return answer.count == 1 && answer[0]["text"] as? String == Self.long
            },
            Do("stop both followers") { story in
                for run in AgentCast.of(story).followers.values { run.stop() }
                AgentCast.of(story).followers = [:]
            },
            Expect("no follower, the taps off") { _ in AgentChannel.current?.connections == 0 && !AgentTaps.on },

            // 4. What Watch can't do, and nothing changes a grant.
            Do("grant c Watch") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("c")) },
            RawLines(
                Self.forbidden.enumerated().map { RawLines.cmd("f\($0.offset)", $0.element, "{\"chat\":\".\",\"tier\":\"full\",\"text\":\"hi\"}") }
                    + [RawLines.cmd("caps", "agent.caps", "{\"tier\":\"full\"}")],
                replies: Self.forbidden.count + 1, c, "4. every higher-tier or control command refused", helloExtra: "\"tier\":\"full\""
            ) { replies, _ in
                guard replies.first?["type"] as? String == "welcome", replies.first?["tier"] as? String == "watch", replies.count == Self.forbidden.count + 2 else { return false }
                let refused = replies.dropFirst().dropLast()
                return refused.allSatisfy { $0["ok"] as? Bool == false && $0["code"] as? String == "unknown_command" }
                    && AgentJSON.path(replies.last, "data", "tier") as? String == "watch"
            },
            Expect("4. no grant or switch changed") { story in
                let cast = AgentCast.of(story)
                return try AgentGrants.enabled && AgentGrants.tier(chat: cast.id("a")) == .watch && AgentGrants.tier(chat: cast.id("b")) == .off
                    && AgentGrants.tier(chat: cast.id("c")) == .watch && AgentGrants.external == .off && AgentGrants.tiers.count == 2
            },

            // 5. Who is calling.
            KoreAs(["whoami"], .tree("a", pass: "?"), "5. a made-up pass in a's tree: mismatch", status: 5, says: "doesn't match"),
            KoreAs(["whoami"], .tree("a", pass: nil), "5. no pass in a's tree: mismatch", status: 5, says: "doesn't match"),
            KoreAs(["whoami"], .tree("b", pass: "a"), "5. a's pass in b's tree: mismatch", status: 5, says: "doesn't match"),
            KoreAs(["whoami"], b, "5. b itself, no grant: denied", status: 5, says: "Kore access is off for this chat."),
            KoreAs(["whoami"], .outside(), "5. outside, no pass: refused", status: 5, says: "Only Kore's chats"),
            KoreAs(["whoami"], .outside(copied: "a"), "5. a's pass copied outside: mismatch", status: 5, says: "doesn't match"),
            KoreAs(["show", "{b.title}"], a, "5. a title two chats share (b, c): ambiguous", status: 1, says: "Several chats match"),
            Do("an isolated shell for the terminal") { try $0.app.workspace?.storyPrepareTerminals() },
            Key(.ctrl("`")),
            Expect("a shell") { $0.app.workspace?.storyTerminal.focused == true },
            TypeText("KORE_AGENT_SOCKET='\(socket)' '\(KoreRun.binary.path)' whoami > \(term) 2>&1; echo exit=$? >> \(term)"), Key(.returnKey),
            Expect("5. Kore's terminal is outside: refused while outsiders are off", timeout: .seconds(10)) { story in
                let out = (try? String(contentsOf: story.folder.appendingPathComponent(term), encoding: .utf8)) ?? ""
                return out.contains("Only Kore's chats") && out.contains("exit=5")
            },
            Do("let outsiders watch (the seam)") { _ in AgentGrants.setExternal(.watch) },
            TypeText("KORE_AGENT_SOCKET='\(socket)' '\(KoreRun.binary.path)' whoami > \(term) 2>&1; echo exit=$? >> \(term)"), Key(.returnKey),
            Expect("5. Kore's terminal: external", timeout: .seconds(10)) { story in
                let out = (try? String(contentsOf: story.folder.appendingPathComponent(term), encoding: .utf8)) ?? ""
                return out.contains("external · watch") && out.contains("exit=0")
            },
            Do("outsiders off again") { _ in AgentGrants.setExternal(.off) },
            Key(.ctrl("`")),

            // 6. 30 a minute, then the next minute.
            Do("grant b Watch") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("b")) },
            Do("mark the audit") { _ in auditMark = try AgentAudit.commands().count },
            RawLines((1...31).map { RawLines.cmd("r\($0)", "agent.whoami") }, replies: 31, b, "6. 30 served, the 31st refused") { replies, _ in
                let results = replies.dropFirst()
                return results.count == 31 && results.prefix(30).allSatisfy { $0["ok"] as? Bool == true }
                    && results.last?["code"] as? String == "rate_limited" && results.last?["id"] as? String == "r31"
            },
            Expect("7. an audit line for each of the 30, one saying the rest were held back") { story in
                let lines = try AgentAudit.commands().dropFirst(auditMark)
                let b = try AgentCast.of(story).id("b")
                let throttled = try AgentAudit.lines().compactMap(AgentAudit.parse).contains { $0.event == "agent-throttled" && $0.fields["chat"] == b }
                return lines.count == 30 && lines.allSatisfy { $0["result"] == "ok" && $0["chat"] == b && $0["cmd"] == "agent.whoami" } && throttled
            },
            KoreAs(["whoami"], b, "6. kore says so, exit 5", status: 5, says: "Too many commands: 30 a minute."),
            KoreAs(["whoami"], a, "6. a's own budget untouched", expect: ["· watch"]),
            MinuteWait(seconds: 61),
            KoreAs(["whoami"], b, "6. a minute on, b is served again", expect: ["chat {b}"]),

            // 9. `kore mcp`.
            KoreAs(
                ["mcp"], a, "9. initialize, Watch's seven tools, each read tool once",
                input: [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                    #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
                    #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"kore_whoami","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"kore_caps","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"kore_list_chats","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"kore_show_chat","arguments":{"chat":"."}}}"#,
                    #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"kore_read_transcript","arguments":{"chat":".","last":2}}}"#,
                    #"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"kore_pending","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"kore_history","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"kore_send","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":18,"method":"chats/send"}"#,
                ].joined(separator: "\n") + "\n"
            ) { status, out, story in
                let cast = AgentCast.of(story)
                let replies = Dictionary(AgentJSON.objects(out).compactMap { o in (o["id"] as? Int).map { ($0, o) } }) { a, _ in a }
                func text(_ id: Int) -> [String: Any]? {
                    guard AgentJSON.path(replies[id], "result", "isError") as? Bool == false,
                        let text = ((AgentJSON.path(replies[id], "result", "content") as? [[String: Any]])?.first?["text"]) as? String
                    else { return nil }
                    return AgentJSON.objects(text).first
                }
                let tools = (AgentJSON.path(replies[2], "result", "tools") as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                return try status == 0 && AgentJSON.path(replies[1], "result", "serverInfo", "name") as? String == "kore"
                    && Set(tools) == ["kore_whoami", "kore_caps", "kore_list_chats", "kore_show_chat", "kore_read_transcript", "kore_pending", "kore_history"]
                    && replies[3]?["result"] != nil
                    && AgentJSON.path(text(10), "caller", "chat") as? String == cast.id("a")
                    && text(11)?["tier"] as? String == "watch"
                    && (text(12)?["chats"] as? [Any])?.count == 3
                    && AgentJSON.path(text(13), "chat", "id") as? String == cast.id("a")
                    && (text(14)?["rows"] as? [Any])?.count == 2
                    && text(15)?["cards"] is [Any]
                    && text(16)?["sessions"] is [Any]
                    && AgentJSON.path(replies[17], "result", "isError") as? Bool == true
                    && AgentJSON.path(replies[18], "error", "code") as? Int == -32601
            },
            KoreAs(
                ["mcp"], .outside(), "9. outside with no access: no tools, a call refused",
                input: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
                    + #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"kore_list_chats","arguments":{}}}"# + "\n"
            ) { status, out, _ in
                let replies = AgentJSON.objects(out)
                return status == 0 && (AgentJSON.path(replies.first, "result", "tools") as? [Any])?.isEmpty == true
                    && AgentJSON.path(replies.last, "result", "isError") as? Bool == true
            },

            // 7. The audit: one line a command, ids only.
            Do("mark the audit") { _ in auditMark = try AgentAudit.commands().count },
            KoreAs(["whoami"], a, "7. one ok", expect: ["· watch"]),
            KoreAs(["show", "no-such-chat"], a, "7. one no_chat", status: 1, says: "No open chat matches"),
            KoreAs(["ls"], .outside(), "7. refused at hello: no command", status: 5, says: "Only Kore's chats"),
            RawLines([RawLines.cmd("x", "chat.send", "{\"text\":\"secret words\"}"), RawLines.cmd("y", "tx.read", "{\"chat\":\"{a}\"}")], replies: 2, c, "7. one refused, one read") { replies, _ in
                replies.count == 3
            },
            Expect("7. four new agent-cmd lines, as they went") { story in
                let cast = AgentCast.of(story)
                let lines = try AgentAudit.commands().dropFirst(auditMark).map { $0 }
                guard lines.count == 4 else { return false }
                return try lines[0] == ["caller": "chat", "chat": cast.id("a"), "cmd": "agent.whoami", "result": "ok"]
                    && lines[1] == ["caller": "chat", "chat": cast.id("a"), "cmd": "chat.show", "result": "no_chat"]
                    && lines[2] == ["caller": "chat", "chat": cast.id("c"), "cmd": "unknown", "result": "unknown_command"]
                    && lines[3] == ["caller": "chat", "chat": cast.id("c"), "cmd": "tx.read", "target": cast.id("a"), "result": "ok"]
            },
            Expect("7. every agent line holds ids and codes only, never text") { _ in
                let texts = [Self.first, Self.reply, Self.second, Self.listed, Self.third, "Which colour", "Sentence 1", "secret words", "nothing-like-this"]
                let lines = try AgentAudit.lines()
                let agent = lines.compactMap(AgentAudit.parse)
                let keys: Set = ["caller", "chat", "cmd", "target", "result", "tier", "code", "what"]
                let uuid = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/
                return !agent.isEmpty && !lines.contains { line in texts.contains { line.contains($0) } }
                    && agent.allSatisfy { e in
                        Set(e.fields.keys).isSubset(of: keys) && [e.fields["chat"], e.fields["target"]].compactMap { $0 }.allSatisfy { $0.wholeMatch(of: uuid) != nil }
                    }
            },

            // 8. Every way it closes.
            StartFollower("f1", ["log", ".", "-f"], a),
            StartFollower("f2", ["log", "{a}", "-f", "--json"], b),
            Do("8. stop all") { _ in AgentGrants.stopAll() },
            Expect("8. stop all: no channel, no socket") { _ in AgentChannel.current == nil && !exists() },
            Followed("f1", "8. ended cleanly", timeout: .seconds(3)) { _, status, _ in status == 0 },
            Followed("f2", "8. ended cleanly", timeout: .seconds(3)) { _, status, _ in status == 0 },
            KoreAs(["ls"], a, "8. refused after stop all", status: 5, says: unreachable),
            Expect("8. stop all in the log") { _ in try AgentAudit.lines().contains { $0.contains("\tagent-stop-all") } },

            Do("grant a again") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("a")) },
            Expect("the socket back") { _ in AgentChannel.current != nil && exists() },
            StartFollower("f3", ["log", ".", "-f"], a),
            Do("8. a's grant, the last, off") { story in AgentGrants.set(.off, chat: try AgentCast.of(story).id("a")) },
            Expect("8. last grant off: no channel, no socket") { _ in AgentChannel.current == nil && !exists() },
            Followed("f3", "8. ended cleanly", timeout: .seconds(3)) { _, status, _ in status == 0 },

            Do("grant c only") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("c")) },
            StartFollower("f4", ["log", ".", "-f", "--json"], c),
            Do("8. close c's tab") { story in
                let cast = AgentCast.of(story)
                guard let workspace = story.app.workspace, let index = workspace.tabs.firstIndex(where: { $0.chat === cast.chats["c"] }) else {
                    throw StoryFailure.modelMissing("c's tab")
                }
                workspace.storySelect(tabAt: index)
                guard story.app.chat === cast.chats["c"] else { throw StoryFailure.expectation("c's tab shown") }
                workspace.perform(.closeTab)
            },
            Expect("c's tab gone") { story in !(story.app.workspace?.tabs.contains { $0.chat === AgentCast.of(story).chats["c"] } ?? true) },
            Followed("f4", "8. chat closed: its follow told and ended", timeout: .seconds(5)) { out, status, _ in
                status != nil && out.contains("\"event\":\"gone\"")
            },
            KoreAs(["ls"], .outside(), "8. nothing left to reach", status: 5, says: unreachable),
            Expect("8. chat closed: no channel, no socket") { _ in AgentChannel.current == nil && !exists() },

            Do("grant a again") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("a")) },
            StartFollower("f5", ["log", ".", "-f"], a),
            Do("8. Kore quits (its will-terminate note)") { _ in
                NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            },
            Expect("8. quit: no channel, no socket") { _ in AgentChannel.current == nil && !exists() },
            Followed("f5", "8. ended cleanly", timeout: .seconds(3)) { _, status, _ in status == 0 },
            Do("the switch back off") { _ in
                AgentGrants.stopAll()
                AgentGrants.setEnabled(false)
            },
        ]
    }

    /// A run that took under half a second.
    static func fast(_ note: String) -> Bool {
        guard let ms = note.split(separator: "ms=").last.flatMap({ Double($0) }) else { return false }
        return ms >= 0 && ms < 500
    }
}

// MARK: - Live

/// Live (`--live <cheap model>`): a chat with Watch asks its model to run
/// `kore whoami` in its shell. The real tool shell carries the chat's pass and runs under its CLI,
/// so Kore names that chat.
final class AgentWhoamiLive: Storyline {
    override class var tags: Set<Tag> { [.live] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        // The CLIs run with the environment Kore read at launch (a login shell's), so a socket
        // given in KORE_AGENT_SOCKET before the run is the one their shells see.
        let given = ProcessInfo.processInfo.environment["KORE_AGENT_SOCKET"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let directory = given ?? URL(fileURLWithPath: "/tmp/kal-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var link: String { directory.appendingPathComponent("kore").path }
        // Codex's workspace sandbox (its default mode) refuses the socket's connect, so its probe
        // runs with full access: what's checked is the pass and the tree, not the sandbox.
        let codex: [any Step] = variant == .codex ? [SetMode("fullAccess")] : []
        return [
            Do("agent control on, at a socket the chat's CLI is told of") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                AgentChannel.directory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? FileManager.default.removeItem(atPath: link)
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: KoreRun.binary.path)
                setenv("KORE_AGENT_SOCKET", AgentWatchReads.socketPath, 1)
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
            },
            OpenFolder(), StartChat(),
            Do("grant the chat Watch") { story in
                let chat = try story.activeChat()
                AgentCast.of(story).chats["a"] = chat
                AgentGrants.set(.watch, chat: chat.id.uuidString)
            },
            Expect("the socket") { _ in AgentChannel.current != nil },
        ] + codex + [
            Send("Run this exact shell command and reply with only its output, nothing else: \(link) whoami; echo pass=${#KORE_AGENT_PASS}"),
            AllowUntilDone(),
            Expect("the answer names this chat, watching", found: { story in
                (story.app.chat?.rows ?? []).last?.text ?? "no answer"
            }) { story in
                let short = String(try story.activeChat().id.uuidString.prefix(8)).lowercased()
                return (story.app.chat?.rows ?? []).contains { $0.kind != "user" && $0.text.contains("chat \(short)") && $0.text.contains("watch") }
            },
            Do("off again") { story in
                unsetenv("KORE_AGENT_SOCKET")
                AgentCast.of(story).finish()
            },
        ]
    }
}

/// Allows every card the turn raises until it ends.
struct AllowUntilDone: Step {
    var label: String { "allow each card until the turn ends" }
    var timeout: Duration? { .seconds(180) }

    @MainActor func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        while true {
            let next: Approval? = try await story.wait("a card or the turn's end", timeout: .seconds(180)) {
                if let card = chat.pendingApprovals.first { return .some(card) }
                let done = story.chatEvents(chat).contains { if case .turnFinished = $0 { true } else { false } }
                return done ? .some(nil) : nil
            }
            guard let card = next else { return }
            chat.storyAnswer(card, .allow)
            try await story.until("the card to go") { !chat.pendingApprovals.contains { $0.id == card.id } }
        }
    }
}

// MARK: - Cost

/// What this process uses now, from the kernel: CPU time, threads, descriptors, footprint and
/// wakeups.
enum ProcessCost {
    struct Sample {
        var at = ContinuousClock.now
        var cpu = 0.0
        var threads = 0
        var fds = 0
        var footprint: UInt64 = 0
        var wakeups: UInt64 = 0
    }

    static func sample(_ pid: pid_t = getpid()) -> Sample {
        var s = Sample()
        var usage = rusage_info_v4()
        let got = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if got == 0 {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ns = Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
            s.cpu = ns / 1e9
            s.footprint = usage.ri_phys_footprint
            s.wakeups = usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
        }
        var task = proc_taskinfo()
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 { s.threads = Int(task.pti_threadnum) }
        // Asked with no buffer, this gives the highest slot used plus some: a count needs a buffer.
        let room = max(Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)), 0)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: room / MemoryLayout<proc_fdinfo>.stride)
        s.fds = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))) / MemoryLayout<proc_fdinfo>.stride
        return s
    }

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

/// The main run loop's passes while recording: how many, and how many held it past 16 and 50 ms.
@MainActor
final class Hitches {
    static let shared = Hitches()
    private var observer: CFRunLoopObserver?
    private var began = 0.0
    private(set) var passes = 0
    private(set) var over16 = 0
    private(set) var over50 = 0
    private(set) var longest = 0.0

    func start() {
        stop()
        passes = 0
        over16 = 0
        over50 = 0
        longest = 0
        began = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    self.began = now
                } else if self.began > 0 {
                    let ms = (now - self.began) * 1000
                    self.passes += 1
                    if ms > 16 { self.over16 += 1 }
                    if ms > 50 { self.over50 += 1 }
                    self.longest = max(self.longest, ms)
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
}

/// A phase of a cost run: its name in `agent-phase` (for a sampler outside), then `hold` seconds
/// of nothing and the steps given, measured from inside: CPU, threads, descriptors, footprint,
/// wakeups and the main thread's long passes, one line in `agent-phases.txt`.
struct Phase: Step {
    let name: String
    let hold: Int
    let steps: [any Step]
    var label: String { "phase \(name)" + (hold > 0 ? ", \(hold) s idle" : "") }
    var timeout: Duration? { .seconds(600) }

    init(_ name: String, hold: Int = 0, _ steps: [any Step] = []) {
        self.name = name
        self.hold = hold
        self.steps = steps
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let phase = story.outputs.appendingPathComponent("agent-phase")
        try "\(name) \(Date().timeIntervalSince1970)\n".write(to: phase, atomically: true, encoding: .utf8)
        let before = ProcessCost.sample()
        Hitches.shared.start()
        if hold > 0 { try await Task.sleep(for: .seconds(hold)) }
        for step in steps {
            story.timeout = step.timeout ?? .seconds(5)
            try await step.run(story)
        }
        let after = ProcessCost.sample()
        Hitches.shared.stop()
        let wall = ProcessCost.seconds(after.at - before.at)
        let h = Hitches.shared
        let line = String(
            format: "%@ wall=%.1fs cpu=%.2f%% threads=%d→%d fds=%d→%d footprint=%.2f→%.2fMB wakeups/s=%.1f passes=%d over16=%d over50=%d longest=%.1fms",
            name, wall, (after.cpu - before.cpu) / wall * 100, before.threads, after.threads, before.fds, after.fds,
            Double(before.footprint) / 1_048_576, Double(after.footprint) / 1_048_576, Double(after.wakeups - before.wakeups) / wall,
            h.passes, h.over16, h.over50, h.longest)
        AgentCast.of(story).note(line, to: story.outputs)
        try "done \(name)\n".write(to: phase, atomically: true, encoding: .utf8)
    }
}

/// `runs` round trips of `kore <arguments>`, one after another, each in the next chat of `roles`
/// (each chat has its own 30 a minute): the time each took inside its shell, p50/p95/max.
struct RoundTrips: Step {
    let arguments: [String]
    let runs: Int
    let roles: [String]
    var label: String { "\(runs) × kore \(arguments.joined(separator: " "))" }
    var timeout: Duration? { .seconds(300) }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        let file = story.outputs.appendingPathComponent("agent-ms-\(arguments[0]).txt")
        try? FileManager.default.removeItem(at: file)
        for i in 0..<runs {
            let role = roles[i % roles.count]
            let (pass, under) = try KoreCaller.chat(role).resolve(cast)
            let run = KoreRun()
            try run.start(arguments, pass: pass, under: under, environment: ["KORE_RUN_MS": file.path])
            try await story.until("kore to exit", timeout: .seconds(10)) { run.status != nil }
            guard run.status == 0 else { throw StoryFailure.expectation("run \(i) in \(role): exit \(run.status ?? -1): \(run.output.prefix(300))") }
        }
        let ms = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Double($0) }.sorted()
        guard ms.count == runs else { throw StoryFailure.expectation("\(ms.count) timings of \(runs)") }
        func p(_ q: Double) -> Double { ms[min(ms.count - 1, Int((Double(ms.count) * q).rounded(.up)) - 1)] }
        cast.note(String(format: "roundtrip %@ runs=%d p50=%.1fms p95=%.1fms max=%.1fms", arguments.joined(separator: " "), runs, p(0.5), p(0.95), ms.last ?? 0), to: story.outputs)
    }
}

/// `kore ls` under `/usr/bin/time -l`, `runs` times: the helper's peak RSS and footprint.
struct HelperMemory: Step {
    let runs: Int
    let roles: [String]
    var label: String { "\(runs) × kore ls under time -l" }
    var timeout: Duration? { .seconds(120) }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        var rss: [Double] = []
        var footprint: [Double] = []
        for i in 0..<runs {
            let (pass, under) = try KoreCaller.chat(roles[i % roles.count]).resolve(cast)
            let run = KoreRun()
            try run.start(["-l", KoreRun.binary.path, "ls"], pass: pass, under: under, executable: URL(fileURLWithPath: "/usr/bin/time"))
            try await story.until("kore to exit", timeout: .seconds(10)) { run.status != nil }
            for line in run.output.split(separator: "\n") {
                let words = line.split(separator: " ")
                guard let n = words.first.flatMap({ Double($0) }) else { continue }
                if line.hasSuffix("maximum resident set size") { rss.append(n / 1_048_576) }
                if line.hasSuffix("peak memory footprint") { footprint.append(n / 1_048_576) }
            }
        }
        guard rss.count == runs else { throw StoryFailure.expectation("\(rss.count) readings of \(runs)") }
        cast.note(String(format: "helper ls peakRSS max=%.2fMB footprint max=%.2fMB", rss.max() ?? 0, footprint.max() ?? 0), to: story.outputs)
    }
}

/// Sends the long answer's message in chat `role` and, until its turn ends, a `kore ls` every two
/// seconds from the next chat of `roles` (30 a minute).
struct StreamWithCommands: Step {
    let role: String
    let turn: Int
    let roles: [String]
    var label: String { "a streamed answer in \(role), kore ls every 2 s" + (roles.isEmpty ? " (none)" : "") }
    var timeout: Duration? { .seconds(180) }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        let chat = try cast.chat(role)
        try await SendTo(role, "Write the long one \(turn)").run(story)
        var i = 0
        var next = ContinuousClock.now
        while story.chatEvents(chat).filter({ if case .turnFinished = $0 { true } else { false } }).count < turn {
            if !roles.isEmpty, ContinuousClock.now >= next {
                next = ContinuousClock.now + .seconds(2)
                let (pass, under) = try KoreCaller.chat(roles[i % roles.count]).resolve(cast)
                i += 1
                let run = KoreRun()
                try run.start(["ls"], pass: pass, under: under)
                try await story.until("kore to exit", timeout: .seconds(10)) { run.status != nil }
                guard run.status == 0 else { throw StoryFailure.expectation("kore ls: exit \(run.status ?? -1)") }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !roles.isEmpty { cast.note("commands during the answer: \(i)", to: story.outputs) }
    }
}

/// `kore mcp` started (initialize, tools/list) and left idle `hold` seconds: its CPU and memory.
struct IdleMCP: Step {
    let role: String
    let hold: Int
    var label: String { "kore mcp idle \(hold) s" }
    var timeout: Duration? { .seconds(hold + 30) }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        let (pass, under) = try KoreCaller.chat(role).resolve(cast)
        let run = KoreRun()
        let hello = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
        try run.start(["mcp"], pass: pass, under: under, input: Data(hello.utf8), keepInput: true)
        try await story.until("its tools", timeout: .seconds(10)) { run.output.contains("\"id\":2") }
        // The stand-in's child is `kore mcp`.
        guard let shell = run.pid else { throw StoryFailure.other("no pid") }
        let pid = try await story.wait("kore mcp's pid", timeout: .seconds(5)) { Self.child(of: shell) }
        try "\(pid)\n".write(to: story.outputs.appendingPathComponent("agent-mcp-pid"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        let before = ProcessCost.sample(pid)
        try await Task.sleep(for: .seconds(hold))
        let after = ProcessCost.sample(pid)
        var task = proc_taskinfo()
        _ = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        let wall = ProcessCost.seconds(after.at - before.at)
        cast.note(
            String(
                format: "mcp idle wall=%.1fs cpu=%.3f%% rss=%.2fMB footprint=%.2fMB threads=%d wakeups/s=%.2f", wall, (after.cpu - before.cpu) / wall * 100,
                Double(task.pti_resident_size) / 1_048_576, Double(after.footprint) / 1_048_576, after.threads, Double(after.wakeups - before.wakeups) / wall),
            to: story.outputs)
        run.closeInput()
        try await story.until("kore mcp to end at its input's end", timeout: .seconds(5)) { run.status != nil }
    }

    static func child(of parent: pid_t) -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0 ? pids.prefix(Int(n)).first { $0 > 0 } : nil
    }
}

/// `kore whoami` from every chat of `roles` at once: each is served (none finds the socket full).
struct AtOnce: Step {
    let roles: [String]
    var label: String { "\(roles.count) × kore whoami at once" }
    var timeout: Duration? { .seconds(30) }

    @MainActor func run(_ story: StoryContext) async throws {
        let cast = AgentCast.of(story)
        var runs: [(String, KoreRun)] = []
        for role in roles {
            let (pass, under) = try KoreCaller.chat(role).resolve(cast)
            let run = KoreRun()
            try run.start(["whoami"], pass: pass, under: under)
            runs.append((role, run))
        }
        try await story.until("all to exit", timeout: .seconds(20)) { runs.allSatisfy { $0.1.status != nil } }
        let failed = runs.filter { $0.1.status != 0 }
        cast.note("at once: \(runs.count - failed.count) of \(runs.count) served" + failed.map { " [\($0.0): \($0.1.output.trimmingCharacters(in: .whitespacesAndNewlines))]" }.joined(), to: story.outputs)
    }
}

/// What the channel costs (`--tag agentcost`, release build, one provider): idle with the switch
/// off, then on with a grant; 100 round trips each of `kore ls`, `show`, `pending` and the
/// helper's memory; a streamed answer with no follower, one, and four plus a command every two
/// seconds; `kore mcp` idle. Numbers in `agent-notes.txt`; phases in `agent-phase` for a sampler.
final class AgentChannelCost: ChatStoryline {
    override class var tags: Set<Tag> { [.agentCost] }
    override class var variants: [Variant] { [.claude] }
    static let long = (1...180).map { "Sentence \($0) of a long streamed answer, as a model writes it." }.joined(separator: " ")
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("Ready."), [.startTurn, .stream(.answer, long), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kcc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let roles = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"]
        let grant = { (story: StoryContext, role: String) in AgentGrants.set(.watch, chat: try AgentCast.of(story).id(role)) }
        return super.steps() + [
            Do("the cast, the pid, all off") { story in
                let cast = AgentCast.of(story)
                cast.chats["a"] = try story.activeChat()
                cast.directory = directory
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(false)
                try "\(getpid())\n".write(to: story.outputs.appendingPathComponent("agent-pid"), atomically: true, encoding: .utf8)
                cast.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "measuring")
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
        ] + roles.dropFirst().map { CastChat($0) } + [
            WaitIdle(),
            Phase("off", hold: 30),
            Do("switch on, a granted Watch") { story in
                AgentGrants.setEnabled(true)
                try grant(story, "a")
            },
            Phase("on-idle", hold: 30),
            Do("every chat granted Watch") { story in for role in roles { try grant(story, role) } },
            Phase("latency", [
                RoundTrips(arguments: ["ls"], runs: 100, roles: roles),
                RoundTrips(arguments: ["show", "."], runs: 100, roles: roles),
                RoundTrips(arguments: ["pending"], runs: 100, roles: roles),
            ]),
            MinuteWait(seconds: 61),
            Phase("memory", [HelperMemory(runs: 10, roles: roles)]),
            AtOnce(roles: roles),
            Do("stream at 60 pieces a second") { _ in
                ScriptedWorld.shared.rate = 60
                for backend in ScriptedWorld.shared.backends { backend.rate = 60 }
            },
            Phase("stream-0", [StreamWithCommands(role: "a", turn: 2, roles: [])]),
            StartFollower("p1", ["log", "{a}", "-f", "--json"], .chat("b")),
            Phase("stream-1", [StreamWithCommands(role: "a", turn: 3, roles: [])]),
            Do("stop p1") { story in AgentCast.of(story).followers["p1"]?.stop() },
            // Answers alike vary by more than a follower costs, so each is measured beside one
            // with nobody following.
            Phase("stream-0b", [StreamWithCommands(role: "a", turn: 4, roles: [])]),
            StartFollower("t1", ["log", "{a}", "-f"], .chat("b")),
            Phase("stream-1b", [StreamWithCommands(role: "a", turn: 5, roles: [])]),
            Do("stop t1") { story in AgentCast.of(story).followers["t1"]?.stop() },
            Phase("stream-0c", [StreamWithCommands(role: "a", turn: 6, roles: [])]),
            StartFollower("p2", ["log", "{a}", "-f", "--json"], .chat("c")),
            StartFollower("p3", ["log", "{a}", "-f"], .chat("d")),
            StartFollower("p4", ["log", "{a}", "-f", "--json"], .chat("e")),
            StartFollower("p5", ["log", "{a}", "-f"], .chat("f")),
            Phase("stream-4", [StreamWithCommands(role: "a", turn: 7, roles: ["g", "h", "i", "j", "k"])]),
            Followed("p5", "printed the whole answer") { out, _, _ in out.contains(Self.long) },
            Do("stop the followers") { story in for run in AgentCast.of(story).followers.values { run.stop() } },
            Phase("stream-0d", [StreamWithCommands(role: "a", turn: 8, roles: [])]),
            Phase("mcp-idle", [IdleMCP(role: "a", hold: 30)]),
        ]
    }
}

/// A closed window can stay in `Workspace.all` until it's freed: the channel doesn't list it.
final class AgentClosedWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kaw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return super.steps() + [
            Do("agent control on, a terminal may watch") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
                AgentGrants.setExternal(.watch)
                AgentGrants.set(.watch, chat: try story.activeChat().id.uuidString)
            },
            KoreAs(["ls"], .outside(), "the chat is listed") { status, out, _ in status == 0 && !out.contains("No chats are open.") },
            Do("close its window") { story in story.window?.close() },
            Expect("the window is closed") { story in story.window?.isVisible == false },
            KoreAs(["ls"], .outside(), "nothing is listed") { status, out, _ in status == 0 && out.contains("No chats are open.") },
        ]
    }
}

/// What a Watch grant reads: chats in the caller's own folder and chats whose own access is above
/// Off, and a chat in another folder with access off isn't there, not even by its id. Text that
/// looks like a key comes back masked.
final class AgentWatchLimit: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    // Made up here so that nothing in the repository looks like a key to a scanner.
    static let apiKey = "sk-" + String(repeating: "a1B2c3D4", count: 4)
    static let codeKey = "gh" + "p_" + String(repeating: "Z9y8X7w6", count: 4)
    static let password = "hunter" + "2-is-long"
    static let leaky = "Use \(apiKey) and \(codeKey), password: \(password), done."
    static let card = Approval(id: "ls1", title: "Run ls -la", detail: "List the folder", body: "ls -la", canAlwaysAllow: false, questions: [])
    override class var script: CLIScript {
        CLIScript(turns: [
            CLIScript.reply(leaky),
            [.startTurn, .approval(card, allow: Beat.answer("Listed."), deny: []), .finishTurn(.completed)],
        ])
    }

    static func shows(_ role: String, _ out: String, _ story: StoryContext) throws -> Bool {
        out.contains(try AgentCast.of(story).fill("{\(role)}"))
    }

    static func masked(_ out: String) -> Bool {
        out.contains(AgentSecrets.mask) && ![apiKey, codeKey, password].contains { out.contains($0) }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kaw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let a = KoreCaller.chat("a")
        let missing = "No open chat matches"
        return super.steps() + [
            Do("agent control on; a has Watch") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
                AgentGrants.set(.watch, chat: try cast.id("a"))
            },
            SendTo("a", "hello from here"), TurnsDone("a", 1),
            CastChat("b"),
            OtherFolderChat(role: "d"),
            SendTo("d", "plans over there"), TurnsDone("d", 1),
            SendTo("d", "list it"),
            WaitingOnCard(role: "d"),

            // Another folder, access off: not there.
            KoreAs(["ls"], a, "lists its folder's chats, off or not, and not the other's") { status, out, story in
                try status == 0 && Self.shows("a", out, story) && Self.shows("b", out, story) && !Self.shows("d", out, story)
            },
            KoreAs(["ls", "--json"], a, "nor in JSON") { status, out, story in try status == 0 && Self.shows("a", out, story) && !Self.shows("d", out, story) },
            KoreAs(["show", "{d}"], a, "show refused, by short id", status: 1, says: missing),
            KoreAs(["show", "{d.id}"], a, "show refused, by whole id", status: 1, says: missing),
            KoreAs(["show", "{d.title}"], a, "show refused, by title", status: 1, says: missing),
            KoreAs(["log", "{d}"], a, "log refused", status: 1, says: missing),
            KoreAs(["log", "{d}", "-f"], a, "follow refused", status: 1, says: missing),
            KoreAs(["pending", "{d}"], a, "its cards refused", status: 1, says: missing),
            KoreAs(["pending"], a, "its cards not listed") { status, out, _ in status == 0 && out.contains("Nothing is waiting") },
            KoreAs(["history", "--folder", "{d.folder}"], a, "its folder's past chats refused", status: 1, says: "own folder"),

            // Its access on: there. Its access off again: gone, and a follow of it ends.
            Do("d gets Watch") { story in AgentGrants.set(.watch, chat: try AgentCast.of(story).id("d")) },
            KoreAs(["ls"], a, "now listed") { status, out, story in try status == 0 && Self.shows("d", out, story) },
            KoreAs(["pending"], a, "and its card", expect: [Self.card.title]),
            StartFollower("f", ["log", "{d}", "-f", "--json"], a),
            Do("d's access off") { story in AgentGrants.set(.off, chat: try AgentCast.of(story).id("d")) },
            Followed("f", "the follow is told and ends", timeout: .seconds(5)) { out, status, _ in status != nil && out.contains("\"event\":\"gone\"") },
            KoreAs(["show", "{d}"], a, "refused again", status: 1, says: missing),

            // A caller outside Kore's chats has no folder: only what's above Off, and no history.
            Do("outsiders may watch (the seam)") { _ in AgentGrants.setExternal(.watch) },
            KoreAs(["ls"], .outside(), "outside: only a, the chat with access") { status, out, story in
                try status == 0 && Self.shows("a", out, story) && !Self.shows("b", out, story) && !Self.shows("d", out, story)
            },
            KoreAs(["log", "{b}"], .outside(), "outside: an Off chat refused", status: 1, says: missing),
            KoreAs(["log", "{d}"], .outside(), "outside: another folder's Off chat refused", status: 1, says: missing),
            KoreAs(["history"], .outside(), "outside: no past chats", status: 1, says: "only from a chat in Kore"),
            Do("outsiders off") { _ in AgentGrants.setExternal(.off) },

            // What looks like a key.
            KoreAs(["log", "{a}"], a, "keys masked in text") { status, out, _ in status == 0 && Self.masked(out) },
            KoreAs(["log", "{a}", "--json"], a, "and in JSON") { status, out, _ in status == 0 && Self.masked(out) },
            Do("close the other window") { story in
                let chat = try AgentCast.of(story).chat("d")
                Workspace.all.allObjects.first { $0.tabs.contains { $0.chat === chat } }?.window?.close()
            },
        ]
    }

    /// A chat in a window of another folder, by role.
    private struct OtherFolderChat: Step {
        let role: String
        var label: String { "chat “\(role)” in another folder's window" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
            // Its own for each variant: a closed window of the same folder can stay in `Workspace.all`.
            let folder = story.outputs.appendingPathComponent("other-\(story.folder.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.openFolder(folder)
            let path = folder.standardizedFileURL.path
            let workspace = try await story.wait("its window") {
                Workspace.all.allObjects.first { $0.window != nil && !$0.isClosed && $0.folder.standardizedFileURL.path == path }
            }
            guard workspace.start(provider: story.variant?.provider ?? "claude", model: nil) else { throw StoryFailure.modelMissing("the provider") }
            let cast = AgentCast.of(story)
            cast.chats[role] = try await story.wait("its chat") { workspace.activeTab.chat }
            cast.otherFolder = path
        }
    }

    private struct WaitingOnCard: Step {
        let role: String
        var label: String { "“\(role)” is waiting on a card" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            let chat = try AgentCast.of(story).chat(role)
            try await story.until("the card", timeout: timeout) { if case .waiting = chat.attention { true } else { false } }
        }
    }
}

/// What a caller and `kore` won't take: text that would drive a terminal, a socket another process
/// has taken over, something else at Kore's socket.
final class AgentSafety: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel] }
    override class var variants: [Variant] { [.claude] }
    /// Colour, a bell, a C1 CSI, DEL and a carriage return.
    static let hostile = "plain \u{1B}[31mred\u{07} \u{9B}31mcsi\u{7F} \rend"
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(hostile)]) }

    static func controls(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 != "\n" && $0 != "\t" && ($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) }
    }

    /// Connects and says hello, then a child process sends a command, twice. The first child stays
    /// alive while Kore looks (it does at once; the parent waits, as its own reading would name it
    /// again); the second has gone by then.
    static let handOff = """
        zmodload zsh/net/socket || exit 9
        for child in stays goes; do
            zsocket $KORE_AGENT_SOCKET || exit 8
            fd=$REPLY
            print -r -u $fd -- '{"type":"hello","proto":1,"client":"raw"}'
            IFS= read -r -t 5 -u $fd line; print -r -- "$line"
            if [[ $child == stays ]]; then
                ( print -r -u $fd -- '{"type":"cmd","id":"1","cmd":"agent.whoami"}'; sleep 1 ) &
            else
                ( print -r -u $fd -- '{"type":"cmd","id":"1","cmd":"agent.whoami"}' )
            fi
            sleep 0.4
            if IFS= read -r -t 2 -u $fd line; then print -r -- "$line"; else print -r -- '{"type":"ended"}'; fi
            exec {fd}>&-
        done
        wait
        """

    /// A server that isn't Kore: prints what it's told, once it's told anything.
    static let impostor = """
        zmodload zsh/net/socket || exit 9
        zsocket -l $1 || exit 8
        listener=$REPLY
        print ready
        zsocket -a $listener || { print nobody; exit 0 }
        fd=$REPLY
        IFS= read -r -t 2 -u $fd line && print -r -- "told: $line"
        print done
        """

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kas-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fake = URL(fileURLWithPath: "/tmp/kaf-\(UUID().uuidString.prefix(8)).sock")
        return super.steps() + [
            Do("agent control on, a terminal may watch") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
                AgentGrants.setExternal(.watch)
                AgentGrants.set(.watch, chat: try story.activeChat().id.uuidString)
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
            KoreAs(["log", "{a}"], .outside(), "chat text can't drive the terminal") { status, out, _ in
                status == 0 && !Self.controls(out) && out.contains("plain [31mred 31mcsi end")
            },
            KoreAs(["log", "{a}", "--json"], .outside(), "nor in JSON, with the text kept") { status, out, _ in
                status == 0 && !Self.controls(out) && out.contains("\\u001b[31mred") && out.contains("\\u009b31mcsi")
            },
            HandedOff(),
            TurnedAway(),
            Impostor(socket: fake.path),
        ]
    }

    private struct HandedOff: Step {
        var label: String { "a child process using its parent's connection is refused" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            let script = story.outputs.appendingPathComponent("agent-handoff.zsh")
            try AgentSafety.handOff.write(to: script, atomically: true, encoding: .utf8)
            let run = KoreRun()
            try run.start([script.path], executable: URL(fileURLWithPath: "/bin/zsh"))
            try await story.until("it to finish", timeout: timeout) { run.status != nil }
            let replies = AgentJSON.objects(run.output)
            guard replies.count == 4, replies[0]["type"] as? String == "welcome", replies[1]["type"] as? String == "bye", replies[1]["code"] as? String == "mismatch",
                replies[2]["type"] as? String == "welcome", replies[3]["type"] as? String == "ended"
            else {
                throw StoryFailure.expectation("got: \(run.output.prefix(400))")
            }
        }
    }

    /// Four processes hold all 16 places without a hello; the real `kore` is told why, each time.
    private struct TurnedAway: Step {
        var label: String { "kore, with every place taken, says so and exits 5" }
        var timeout: Duration? { .seconds(20) }

        static let holder = """
            zmodload zsh/net/socket || exit 9
            for i in 1 2 3 4; do zsocket $KORE_AGENT_SOCKET || exit 8; done
            print ready
            sleep 3
            """

        @MainActor func run(_ story: StoryContext) async throws {
            let script = story.outputs.appendingPathComponent("agent-holder.zsh")
            try Self.holder.write(to: script, atomically: true, encoding: .utf8)
            let holders = (0..<4).map { _ in KoreRun() }
            for holder in holders { try holder.start([script.path], executable: URL(fileURLWithPath: "/bin/zsh")) }
            defer { holders.forEach { $0.stop() } }
            try await story.until("all 16 places held", timeout: .seconds(3)) { holders.allSatisfy { $0.output.contains("ready") } }
            try await Task.sleep(for: .milliseconds(100))
            // Several, as what `kore` finds depends on how soon Kore has closed it.
            for _ in 0..<5 {
                let kore = KoreRun()
                try kore.start(["whoami"], pass: "a-pass-to-keep")
                try await story.until("kore to exit", timeout: .seconds(5)) { kore.status != nil }
                guard kore.status == 5, kore.output.contains("Too many connections") else {
                    throw StoryFailure.expectation("exit \(kore.status ?? -1): \(kore.output.prefix(200))")
                }
            }
        }
    }

    private struct Impostor: Step {
        let socket: String
        var label: String { "kore tells nothing to a server that isn't Kore" }
        var timeout: Duration? { .seconds(20) }

        @MainActor func run(_ story: StoryContext) async throws {
            let script = story.outputs.appendingPathComponent("agent-impostor.zsh")
            try AgentSafety.impostor.write(to: script, atomically: true, encoding: .utf8)
            let server = KoreRun()
            try server.start([script.path, socket], executable: URL(fileURLWithPath: "/bin/zsh"))
            defer {
                server.stop()
                unlink(socket)
            }
            try await story.until("the server to listen", timeout: .seconds(5)) { server.output.contains("ready") }
            let kore = KoreRun()
            try kore.start(["whoami"], pass: "a-pass-to-keep", environment: ["KORE_AGENT_SOCKET": socket])
            try await story.until("kore to exit", timeout: .seconds(10)) { kore.status != nil }
            try await story.until("the server to finish", timeout: .seconds(10)) { server.status != nil }
            guard kore.status == 5, kore.output.contains("isn't the Kore"), !server.output.contains("told:") else {
                throw StoryFailure.expectation("kore: exit \(kore.status ?? -1) \(kore.output.prefix(200)); server: \(server.output.prefix(200))")
            }
        }
    }
}

/// Kore quitting for real with agent control on: `scripts/tests/agent-quit.sh` watches from
/// outside, since this host doesn't outlive it. Without that script's folder it only opens a chat.
final class AgentQuitPath: ChatStoryline {
    override class var tags: Set<Tag> { [.agentQuit] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    override func steps() -> [any Step] {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["KORE_AGENT_QUIT_DIR"] else { return super.steps() }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let quits = env["KORE_AGENT_QUIT_HOW"] == "quit"
        return super.steps() + [
            Do("agent control on at the script's socket, a terminal may watch the chat") { story in
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
                AgentGrants.setExternal(.watch)
                AgentGrants.set(.watch, chat: try story.activeChat().id.uuidString)
            },
            Expect("the socket") { _ in AgentChannel.current != nil },
            Do("tell the script") { story in
                let short = String(try story.activeChat().id.uuidString.prefix(8)).lowercased()
                try "\(getpid()) \(short)\n".write(to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
            },
            EndOnceFollowed(directory: directory, quits: quits),
        ]
    }
}

/// Waits for the script's follower; then Kore quits, or waits for the script's signal.
private struct EndOnceFollowed: Step {
    let directory: URL
    let quits: Bool
    var label: String { "the script's kore log -f follows, then Kore " + (quits ? "quits its own way" : "takes a signal") }
    var timeout: Duration? { .seconds(120) }

    @MainActor func run(_ story: StoryContext) async throws {
        try await story.until("a follower", timeout: .seconds(60)) { AgentTaps.on }
        if quits {
            // ⌘Q once only warns: agent control and its follower carry on.
            QuitGuard.shared.press(byKey: true, hasWindow: true)
            guard QuitGuard.shared.armed, AgentChannel.current != nil, AgentTaps.on else {
                throw StoryFailure.expectation("agent control still on, and its follower, after one ⌘Q")
            }
            // What says the follower was on when Kore quit: this host writes no report.
            try "".write(to: directory.appendingPathComponent("quitting"), atomically: true, encoding: .utf8)
            // The second is the quit.
            QuitGuard.shared.press(byKey: true, hasWindow: true)
        }
        try await Task.sleep(for: .seconds(60))
    }
}

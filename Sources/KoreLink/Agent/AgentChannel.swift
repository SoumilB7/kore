import AppKit
import Darwin
import Foundation
import KoreCore
import KoreUI

/// Kore's agent channel (`z-docs/agent-protocol.md`): the socket the `kore` command and agents in
/// Kore's chats read Kore through, apart from the local link. It exists only while the master
/// switch is on and some grant is live (`AgentGrants`); otherwise there's no socket, queue,
/// observer or timer. Each connection names its caller once, from the kernel and Kore's records
/// (`AgentCaller`), and each command is checked against that caller's tier as it is then.
@MainActor
package final class AgentChannel {
    /// The channel open now; nil while closed.
    package private(set) static var current: AgentChannel?

    /// `~/Library/Application Support/Kore/agent`; tests and storylines use their own.
    package static var directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kore", isDirectory: true).appendingPathComponent("agent", isDirectory: true)
    package static let socketName = "kore.sock"

    /// Commands a caller may run a minute.
    static let perMinute = 30
    /// Connections at once.
    static let clientsMax = 16

    package let socketPath: String
    private let queue = DispatchQueue(label: "dev.kore.agent")
    private let listener: LinkListener
    private var clients: [UUID: Client] = [:]
    /// Each caller's budget (a chat's, or every external caller's together), for this opening.
    private var limits: [String: RateLimiter] = [:]
    private var dirty = Set<String>()
    private var flushDue = false
    private var quitObserver: NSObjectProtocol?

    private final class Client {
        let token: UUID
        let connection: AgentConnection
        let peer: AgentCaller.Peer
        /// Set by its hello: the chat it runs in, or nil for an external caller.
        var named = false
        var chat: String?
        var follows: [String: Follow] = [:]

        struct Follow {
            /// The `tx.follow` command's id, which its events carry.
            let id: String
            var marks: [UUID: Int] = [:]
            var state: String
        }

        init(token: UUID, connection: AgentConnection, peer: AgentCaller.Peer) {
            self.token = token
            self.connection = connection
            self.peer = peer
        }

        var key: String { chat.map { "chat:" + $0 } ?? "external" }
        var callerClass: String { chat == nil ? "external" : "chat" }
    }

    // MARK: Opening and closing

    /// Opens or closes the socket to match the switch and the grants.
    package static func sync() {
        if AgentGrants.wanted {
            guard current == nil else { return }
            do {
                current = try AgentChannel(directory: directory)
            } catch {
                UILog.event("agent-open-failed", ["errno": "\((error as? LinkListener.Failure).map { "\($0)" } ?? "?")"])
            }
        } else {
            current?.close(.stopped)
        }
    }

    private init(directory: URL) throws {
        socketPath = directory.appendingPathComponent(Self.socketName).path
        listener = try LinkListener(path: socketPath, queue: queue)
        listener.start { [weak self] fd in
            // On the channel's queue: who it is comes from the kernel before anything is read.
            guard let peer = AgentCaller.peer(fd) else {
                Darwin.close(fd)
                return
            }
            LinkHost.onMain { self?.accepted(fd, peer) }
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentChannel.current?.close(.stopped) }
        }
        UILog.event("agent-open")
    }

    /// Closes every connection (with `bye`) and the socket, and lets go of every hook.
    package func close(_ code: AgentCode) {
        guard AgentChannel.current === self else { return }
        AgentChannel.current = nil
        let bye = Self.encode(AgentBye(code: code, message: "Agent control is off in Kore."))
        for client in clients.values { client.connection.finish(after: bye) }
        clients = [:]
        listener.close()
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        followsChanged()
        UILog.event("agent-closed", ["code": code.rawValue])
    }

    /// A chat's access went off (`chat` nil: external callers'): its connections end.
    func revoked(chat: String?) {
        for (key, client) in clients where client.named && client.chat == chat {
            client.connection.finish(after: Self.encode(AgentBye(code: .stopped, message: "Kore access is off for this caller.")))
            clients[key] = nil
        }
        followsChanged()
    }

    // MARK: Connections

    private func accepted(_ fd: Int32, _ peer: AgentCaller.Peer) {
        guard AgentChannel.current === self, clients.count < Self.clientsMax else {
            Darwin.close(fd)
            return
        }
        // A grant whose chat has closed counts no more; with none left, the socket goes.
        AgentGrants.prune(open: Set(LinkSnapshot.chatsByID().keys))
        guard AgentGrants.wanted else {
            Darwin.close(fd)
            close(.stopped)
            return
        }
        let token = UUID()
        let connection = AgentConnection(
            fd: fd, queue: queue,
            onLines: { [weak self] lines in LinkHost.onMain { self?.received(lines, token) } },
            onClose: { [weak self] in LinkHost.onMain { self?.dropped(token) } })
        clients[token] = Client(token: token, connection: connection, peer: peer)
        connection.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentProto.helloWithin) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[token], !client.named else { return }
                self.refuse(client, .invalid, "No hello.")
            }
        }
    }

    private func dropped(_ token: UUID) {
        guard let client = clients.removeValue(forKey: token) else { return }
        if !client.follows.isEmpty { followsChanged() }
    }

    private func refuse(_ client: Client, _ code: AgentCode, _ message: String) {
        clients[client.token] = nil
        client.connection.finish(after: Self.encode(AgentBye(code: code, message: message)))
        UILog.event("agent-refused", ["caller": client.callerClass, "chat": client.chat, "code": code.rawValue])
        if !client.follows.isEmpty { followsChanged() }
    }

    private func received(_ lines: [Data], _ token: UUID) {
        for line in lines {
            guard AgentChannel.current === self, let client = clients[token] else { return }
            guard let message = try? JSONDecoder().decode(AgentIn.self, from: line) else {
                if client.named {
                    send(client, AgentResult<AgentEmpty>(id: "", ok: false, code: .invalid, message: "Not a JSON object."))
                    continue
                }
                return refuse(client, .invalid, "Not a JSON object.")
            }
            guard client.named else {
                hello(message, client)
                continue
            }
            guard message.type == "cmd", let id = message.id, let name = message.cmd else {
                send(client, AgentResult<AgentEmpty>(id: message.id ?? "", ok: false, code: .invalid, message: "Expected a command."))
                continue
            }
            command(id, name, message.args ?? AgentArgs(), client)
        }
    }

    // MARK: Hello

    private func hello(_ message: AgentIn, _ client: Client) {
        guard message.type == "hello" else { return refuse(client, .invalid, "Say hello first.") }
        guard message.proto == AgentProto.version else { return refuse(client, .version, "Kore speaks agent protocol \(AgentProto.version).") }
        let verdict = AgentCaller.verdict(ancestors: client.peer.ancestors, pass: message.pass, clis: AgentPasses.shared.pids())
        switch verdict {
        case .mismatch:
            return refuse(client, .mismatch, "This caller's pass doesn't match the chat it runs in.")
        case .external:
            guard AgentGrants.external != .off else {
                return refuse(client, .denied, "Only Kore's chats with Kore access can use this for now.")
            }
            client.named = true
        case .chat(let pass):
            guard let chat = LinkSnapshot.chatsByID().values.first(where: { $0.agentPass == pass }) else {
                return refuse(client, .denied, "That chat isn't open in Kore.")
            }
            client.chat = chat.id.uuidString
            guard tier(client) != .off else { return refuse(client, .denied, "Kore access is off for this chat.") }
            client.named = true
        }
        let tier = tier(client)
        UILog.event("agent-hello", ["caller": client.callerClass, "chat": client.chat, "tier": tier.rawValue])
        send(client, AgentWelcome(caller: callerInfo(client), tier: tier, commands: AgentCommand.allowed(tier).map(\.name)))
    }

    private func tier(_ client: Client) -> AgentTier {
        client.chat.map { AgentGrants.tier(chat: $0) } ?? AgentGrants.external
    }

    private func callerInfo(_ client: Client) -> AgentCallerInfo {
        let chat = client.chat.flatMap { LinkSnapshot.chatsByID()[$0] }
        return AgentCallerInfo(
            class: client.callerClass, chat: client.chat, short: client.chat.map(AgentReads.short), title: chat?.title)
    }

    // MARK: Commands

    private func command(_ id: String, _ name: String, _ args: AgentArgs, _ client: Client) {
        lastResult = "ok"
        var target: String?
        let code: AgentCode? = {
            let tier = tier(client)
            guard tier != .off else { return .stopped }
            guard limits[client.key, default: RateLimiter(limit: Self.perMinute, per: 60)].take() else { return .rateLimited }
            guard let command = AgentCommand.all.first(where: { $0.name == name }) else { return .unknownCommand }
            guard command.tier <= tier else { return .tier }
            return nil
        }()
        if let code {
            fail(client, id, code, Self.message(code))
        } else {
            target = run(id, name, args, client)
        }
        // One line per command: who, which, on what, and how it went. Never text.
        UILog.event(
            "agent-cmd",
            ["caller": client.callerClass, "chat": client.chat, "cmd": name, "target": target, "result": lastResult])
        if code == .stopped { refuse(client, .stopped, Self.message(.stopped)) }
    }

    /// The last command's outcome, for its log line.
    private var lastResult = "ok"

    /// Runs an allowed command; returns the chat it read, for the log.
    private func run(_ id: String, _ name: String, _ args: AgentArgs, _ client: Client) -> String? {
        let own = client.chat
        switch name {
        case AgentCommand.whoami.name:
            send(client, AgentResult(id: id, ok: true, data: AgentWhoami(caller: callerInfo(client), tier: tier(client))))
        case AgentCommand.caps.name:
            let tier = tier(client)
            send(client, AgentResult(id: id, ok: true, data: AgentCaps(tier: tier, commands: AgentCommand.allowed(tier).map(\.name))))
        case AgentCommand.chats.name:
            send(client, AgentResult(id: id, ok: true, data: AgentChats(chats: AgentReads.chats(own: own))))
        case AgentCommand.cards.name:
            let chats: [Chat]
            if args.chat != nil {
                guard let chat = resolve(args.chat, client, id) else { return nil }
                chats = [chat]
            } else {
                chats = LinkSnapshot.workspaces().flatMap(LinkSnapshot.chats)
            }
            send(client, AgentResult(id: id, ok: true, data: AgentCards(cards: chats.flatMap(AgentReads.cards))))
            return chats.count == 1 ? chats[0].id.uuidString : nil
        case AgentCommand.show.name:
            guard let chat = resolve(args.chat, client, id) else { return nil }
            send(client, AgentResult(id: id, ok: true, data: AgentReads.detail(chat, own: own)))
            return chat.id.uuidString
        case AgentCommand.read.name:
            guard let chat = resolve(args.chat, client, id) else { return nil }
            send(client, AgentResult(id: id, ok: true, data: AgentReads.rows(chat, last: args.last, before: args.before)))
            return chat.id.uuidString
        case AgentCommand.follow.name:
            guard let chat = resolve(args.chat, client, id) else { return nil }
            follow(chat, id, args, client)
            return chat.id.uuidString
        case AgentCommand.unfollow.name:
            guard let chat = resolve(args.chat, client, id) else { return nil }
            client.follows[chat.id.uuidString] = nil
            followsChanged()
            send(client, AgentResult<AgentEmpty>(id: id, ok: true))
            return chat.id.uuidString
        case AgentCommand.history.name:
            guard let workspace = window(args, client, id) else { return nil }
            let data = AgentReads.history(workspace, query: args.query, archived: args.archived ?? false, offset: args.offset ?? 0)
            send(client, AgentResult(id: id, ok: true, data: data))
        default:
            fail(client, id, .unknownCommand, Self.message(.unknownCommand))
        }
        return nil
    }

    private func fail(_ client: Client, _ id: String, _ code: AgentCode, _ message: String) {
        lastResult = code.rawValue
        send(client, AgentResult<AgentEmpty>(id: id, ok: false, code: code, message: message))
    }

    static func message(_ code: AgentCode) -> String {
        switch code {
        case .rateLimited: "Too many commands: \(perMinute) a minute."
        case .unknownCommand: "Kore has no such command."
        case .tier: "This chat's Kore access doesn't cover that."
        case .stopped: "Kore access is off for this caller."
        default: code.rawValue
        }
    }

    private func resolve(_ ref: String?, _ client: Client, _ id: String) -> Chat? {
        guard let ref, !ref.isEmpty else {
            fail(client, id, .noChat, "Name a chat: its title, its short id, or . for this one.")
            return nil
        }
        let chats = LinkSnapshot.chatsByID()
        let titled = chats.values.map { (id: $0.id.uuidString, title: $0.title) }
        switch AgentRefs.resolve(ref, chats: titled, own: client.chat) {
        case .chat(let found):
            if let chat = chats[found] { return chat }
            fail(client, id, .noChat, "That chat isn't open in Kore.")
        case .none:
            fail(client, id, .noChat, "No open chat matches \u{201C}\(ref)\u{201D}.")
        case .notInChat:
            fail(client, id, .noChat, "This caller isn't in a Kore chat, so . names none.")
        case .ambiguous(let ids):
            let names = ids.compactMap { chats[$0] }.map { "\(AgentReads.short($0.id.uuidString)) \($0.title)" }
            fail(client, id, .ambiguous, "Several chats match: " + names.joined(separator: ", "))
        }
        return nil
    }

    /// The window a history read is for: the folder named, the caller's chat's, the one holding
    /// the caller's directory, or the only one.
    private func window(_ args: AgentArgs, _ client: Client, _ id: String) -> Workspace? {
        let windows = LinkSnapshot.workspaces()
        func path(_ text: String) -> String { URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL.path }
        if let folder = args.folder {
            let wanted = path(folder)
            if let w = windows.first(where: { $0.folder.standardizedFileURL.path == wanted }) { return w }
            fail(client, id, .noWindow, "No Kore window has that folder open.")
            return nil
        }
        if let own = client.chat.flatMap({ LinkSnapshot.chatsByID()[$0] }), let w = LinkSnapshot.workspace(of: own) { return w }
        if let cwd = args.cwd.map(path) {
            let holding = windows.filter { cwd == $0.folder.standardizedFileURL.path || cwd.hasPrefix($0.folder.standardizedFileURL.path + "/") }
            if let w = holding.max(by: { $0.folder.path.count < $1.folder.path.count }) { return w }
        }
        if windows.count == 1 { return windows[0] }
        fail(client, id, .noWindow, windows.isEmpty ? "No Kore window is open." : "Several windows are open: name one's folder.")
        return nil
    }

    // MARK: Following

    private func follow(_ chat: Chat, _ id: String, _ args: AgentArgs, _ client: Client) {
        let chatId = chat.id.uuidString
        let entries = chat.transcript.entries
        let count = min(max(args.last ?? AgentReads.page, 0), AgentReads.pageMax)
        var follow = Client.Follow(id: id, state: AgentReads.state(chat))
        for e in entries.suffix(AgentReads.followWindow) { follow.marks[e.id] = AgentReads.mark(e) }
        client.follows[chatId] = follow
        let rows = entries.suffix(count).map { AgentReads.row($0, folder: chat.folder) }
        send(client, AgentResult(id: id, ok: true, data: AgentRows(chat: chatId, rows: rows, more: entries.count > count)))
        followsChanged()
    }

    /// The taps are on exactly while some caller follows a chat.
    private func followsChanged() {
        let following = AgentChannel.current === self && clients.values.contains { !$0.follows.isEmpty }
        AgentTaps.on = following
        AgentTaps.event = following ? { chat, _ in AgentChannel.current?.noted(chat) } : nil
        if !following { dirty = [] }
    }

    private func noted(_ chat: Chat) {
        let id = chat.id.uuidString
        guard clients.values.contains(where: { $0.follows[id] != nil }) else { return }
        dirty.insert(id)
        guard !flushDue else { return }
        flushDue = true
        // Events come in bursts while a turn streams: one look per tenth of a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushDue = false
                self?.flush()
            }
        }
    }

    /// Each followed chat that changed: its new and changed rows, and its status if it moved.
    private func flush() {
        guard AgentChannel.current === self, !dirty.isEmpty else { return }
        let chats = LinkSnapshot.chatsByID()
        let ids = dirty
        dirty = []
        for client in clients.values {
            for chatId in ids {
                guard var follow = client.follows[chatId] else { continue }
                guard let chat = chats[chatId] else {
                    send(client, AgentEvent(id: follow.id, chat: chatId, event: "gone"))
                    client.follows[chatId] = nil
                    continue
                }
                var marks: [UUID: Int] = [:]
                for e in chat.transcript.entries.suffix(AgentReads.followWindow) {
                    let mark = AgentReads.mark(e)
                    marks[e.id] = mark
                    if follow.marks[e.id] != mark {
                        send(client, AgentEvent(id: follow.id, chat: chatId, event: "row", row: AgentReads.row(e, folder: chat.folder)))
                    }
                }
                follow.marks = marks
                let state = AgentReads.state(chat)
                if state != follow.state {
                    follow.state = state
                    send(client, AgentEvent(id: follow.id, chat: chatId, event: "state", state: state))
                }
                client.follows[chatId] = follow
            }
        }
        followsChanged()
    }

    // MARK: Lines

    private func send(_ client: Client, _ value: some Encodable) {
        client.connection.send(Self.encode(value))
    }

    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    // MARK: For tests and storylines

    /// Connections open now.
    package var connections: Int { clients.count }
    /// Callers named by their hello, as `chat:<id>` or `external`.
    package var callers: [String] { clients.values.filter(\.named).map(\.key).sorted() }
}

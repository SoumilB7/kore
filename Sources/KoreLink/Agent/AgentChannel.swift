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
    /// Lines a caller may send past `perMinute`, each answered, before its connection ends.
    static let strikes = 30
    /// Log lines a caller may cause a minute; the rest are one `agent-throttled` line.
    static let logLinesPerMinute = 120
    /// The commands served. Tests add one above Own to reach `.tier` from it.
    static var commands = AgentCommand.all

    package let socketPath: String
    private let queue = DispatchQueue(label: "dev.kore.agent")
    private let listener: AgentListener
    private let slots = AgentSlots()
    private var clients: [UUID: Client] = [:]
    /// Each caller's budget (a chat's, or every external caller's together), for this opening.
    private var limits: [String: RateLimiter] = [:]
    private var strikesLeft: [String: RateLimiter] = [:]
    private var logBudgets: [String: RateLimiter] = [:]
    private var throttleLogged: [String: Date] = [:]
    /// Drive's limits per caller: messages a minute, new chats an hour, and the chats it made
    /// that are open now.
    static let sendsPerMinute = 10
    static let newPerHour = 3
    static let madeOpen = 4
    private var sendBudgets: [String: RateLimiter] = [:]
    private var newBudgets: [String: RateLimiter] = [:]
    private var made: [String: NSHashTable<Chat>] = [:]
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
                UILog.event("agent-open-failed", ["errno": "\((error as? AgentListener.Failure).map { "\($0)" } ?? "?")"])
            }
        } else {
            current?.close(.stopped)
        }
    }

    private init(directory: URL) throws {
        socketPath = directory.appendingPathComponent(Self.socketName).path
        listener = try AgentListener(path: socketPath, queue: queue)
        let slots = self.slots
        listener.start { [weak self] fd in
            // On the channel's queue: who it is comes from the kernel before anything is read, and
            // whether it gets a place before it costs the main thread anything.
            guard let who = AgentCaller.identity(fd) else {
                Darwin.close(fd)
                return
            }
            guard slots.take(who.pid) else {
                Self.turnAway(fd, Self.tooMany)
                if slots.noteTurnedAway() { LinkHost.onMain { UILog.event("agent-throttled", ["what": "connections"]) } }
                return
            }
            guard let peer = AgentCaller.peer(fd, pid: who.pid, token: who.token) else {
                slots.release(who.pid)
                Self.turnAway(fd, Self.unknownProcess)
                return
            }
            LinkHost.onMain {
                if let self { self.accepted(fd, peer) } else { Darwin.close(fd) }
            }
        }
        // A chat closing ends its follows and its own callers, and its grant: once it's out of
        // its window (after this turn of the run loop).
        AgentTaps.closed = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AgentChannel.current?.chatsClosed() } }
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentChannel.current?.close(.stopped) }
        }
        UILog.event("agent-open")
    }

    /// What a connection turned away on the queue is told. Made once: this path is what a process
    /// reconnecting in a loop keeps hitting.
    private nonisolated static let tooMany = encode(AgentBye(code: .rateLimited, message: "Too many connections to Kore from this process, or at once.")) + Data([0x0A])
    private nonisolated static let unknownProcess = encode(AgentBye(code: .mismatch, message: "Kore couldn't tell which process this is.")) + Data([0x0A])

    /// Says why, as far as the socket's buffer takes it without waiting, and closes.
    private nonisolated static func turnAway(_ fd: Int32, _ line: Data) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        Darwin.close(fd)
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
        AgentTaps.closed = nil
        followsChanged()
        UILog.event("agent-closed", ["code": code.rawValue])
    }

    /// A chat's access went off (`chat` nil: external callers'): its connections end, and whoever
    /// could read it only because of that access stops following it.
    func revoked(chat: String?) {
        for (key, client) in clients where client.named && client.chat == chat {
            client.connection.finish(after: Self.encode(AgentBye(code: .stopped, message: "Kore access is off for this caller.")))
            clients[key] = nil
        }
        for client in clients.values where !client.follows.isEmpty {
            let readable = Set(AgentReads.readable(own: client.chat).map(\.id.uuidString))
            for (chatId, follow) in client.follows where !readable.contains(chatId) {
                send(client, AgentEvent(id: follow.id, chat: chatId, event: "gone"))
                client.follows[chatId] = nil
            }
        }
        followsChanged()
    }

    /// Some chat closed: each follow of a chat no longer open gets `gone`, a closed chat's own
    /// callers are let go, its grant drops, and with no grant left the socket closes.
    private func chatsClosed() {
        let open = AgentReads.chatsByID()
        for client in clients.values {
            for (chatId, follow) in client.follows where open[chatId] == nil {
                send(client, AgentEvent(id: follow.id, chat: chatId, event: "gone"))
                client.follows[chatId] = nil
            }
        }
        AgentGrants.prune(open: Set(open.keys))
        for client in clients.values where client.named {
            if let chat = client.chat, open[chat] == nil { refuse(client, .stopped, "This chat closed.") }
        }
        followsChanged()
        if !AgentGrants.wanted { close(.stopped) }
    }

    // MARK: Connections

    private func accepted(_ fd: Int32, _ peer: AgentCaller.Peer) {
        let slots = self.slots
        let queue = self.queue
        func turnAway() {
            Darwin.close(fd)
            queue.async { slots.release(peer.pid) }
        }
        guard AgentChannel.current === self else { return turnAway() }
        // A grant whose chat has closed counts no more; with none left, the socket goes.
        AgentGrants.prune(open: Set(AgentReads.chatsByID().keys))
        guard AgentGrants.wanted else {
            turnAway()
            close(.stopped)
            return
        }
        let token = UUID()
        let pid = peer.pid
        let holder = ConnectionHolder()
        let connection = AgentConnection(
            fd: fd, queue: queue, token: peer.token, peerToken: { LinkIdentity.peerToken($0) },
            onLines: { [weak self] lines in
                LinkHost.onMain {
                    self?.received(lines, token)
                    holder.connection?.batchDone()
                }
            },
            onMoved: { [weak self] in LinkHost.onMain { self?.moved(token) } },
            onClose: { [weak self] in LinkHost.onMain { self?.dropped(token) } },
            onGone: { slots.release(pid) })
        holder.connection = connection
        newestConnection = connection
        clients[token] = Client(token: token, connection: connection, peer: peer)
        connection.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentProto.helloWithin) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[token], !client.named else { return }
                self.refuse(client, .invalid, "No hello.")
            }
        }
    }

    /// Lets a connection's callbacks reach it, once it's made.
    private final class ConnectionHolder: @unchecked Sendable {
        weak var connection: AgentConnection?
    }

    /// Another process is using this connection: it isn't who Kore named.
    private func moved(_ token: UUID) {
        guard let client = clients[token] else { return }
        refuse(client, .mismatch, "Another process took over this connection.")
    }

    private func dropped(_ token: UUID) {
        guard let client = clients.removeValue(forKey: token) else { return }
        if !client.follows.isEmpty { followsChanged() }
    }

    private func refuse(_ client: Client, _ code: AgentCode, _ message: String) {
        clients[client.token] = nil
        client.connection.finish(after: Self.encode(AgentBye(code: code, message: message)))
        log("agent-refused", client, ["caller": client.callerClass, "chat": client.chat, "code": code.rawValue])
        if !client.follows.isEmpty { followsChanged() }
    }

    /// Writes a log line a caller caused, while its budget lasts: after that one line a minute
    /// says so, so a caller can't write the audit trail out of the log.
    private func log(_ event: String, _ client: Client, _ fields: KeyValuePairs<String, String?>) {
        if logBudgets[client.key, default: RateLimiter(limit: Self.logLinesPerMinute, per: 60)].take() {
            UILog.event(event, fields)
        } else {
            throttled(client)
        }
    }

    private func throttled(_ client: Client) {
        let now = Date()
        guard now.timeIntervalSince(throttleLogged[client.key] ?? .distantPast) >= 60 else { return }
        throttleLogged[client.key] = now
        UILog.event("agent-throttled", ["caller": client.callerClass, "chat": client.chat, "what": "commands"])
    }

    private func received(_ lines: [Data], _ token: UUID) {
        for line in lines {
            guard AgentChannel.current === self, let client = clients[token] else { return }
            guard client.named else {
                guard let message = try? JSONDecoder().decode(AgentIn.self, from: line) else {
                    return refuse(client, .invalid, "Not a JSON object.")
                }
                hello(message, client)
                continue
            }
            // Every line counts, whatever it holds, before anything looks inside it.
            guard limits[client.key, default: RateLimiter(limit: Self.perMinute, per: 60)].take() else {
                guard strikesLeft[client.key, default: RateLimiter(limit: Self.strikes, per: 60)].take() else {
                    return refuse(client, .rateLimited, Self.message(.rateLimited))
                }
                throttled(client)
                let id = (try? JSONDecoder().decode(AgentIn.self, from: line))?.id ?? ""
                send(client, AgentResult<AgentEmpty>(id: id, ok: false, code: .rateLimited, message: Self.message(.rateLimited)))
                continue
            }
            guard let message = try? JSONDecoder().decode(AgentIn.self, from: line) else {
                send(client, AgentResult<AgentEmpty>(id: "", ok: false, code: .invalid, message: "Not a JSON object."))
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
            guard let chat = AgentReads.chatsByID().values.first(where: { $0.agentPass == pass }) else {
                return refuse(client, .denied, "That chat isn't open in Kore.")
            }
            client.chat = chat.id.uuidString
            guard tier(client) != .off else { return refuse(client, .denied, "Kore access is off for this chat.") }
            client.named = true
        }
        let tier = tier(client)
        log("agent-hello", client, ["caller": client.callerClass, "chat": client.chat, "tier": tier.rawValue])
        send(client, AgentWelcome(caller: callerInfo(client), tier: tier, commands: AgentCommand.allowed(tier).map(\.name)))
    }

    private func tier(_ client: Client) -> AgentTier {
        client.chat.map { AgentGrants.tier(chat: $0) } ?? AgentGrants.external
    }

    private func callerInfo(_ client: Client) -> AgentCallerInfo {
        let chat = client.chat.flatMap { AgentReads.chatsByID()[$0] }
        return AgentCallerInfo(
            class: client.callerClass, chat: client.chat, short: client.chat.map(AgentReads.short), title: chat.map { AgentReads.title($0.title) })
    }

    // MARK: Commands

    private func command(_ id: String, _ name: String, _ args: AgentArgs, _ client: Client) {
        lastResult = "ok"
        var target: String?
        let code: AgentCode? = {
            let tier = tier(client)
            guard tier != .off else { return .stopped }
            return AgentCommand.refusal(name, tier: tier, among: Self.commands)
        }()
        if let code {
            fail(client, id, code, Self.message(code))
        } else {
            target = run(id, name, args, client)
        }
        // One line per command: who, which, on what, and how it went. Never text.
        // A command's name only if it's one of Kore's: what a caller typed isn't logged.
        let known = Self.commands.contains { $0.name == name } ? name : "unknown"
        log("agent-cmd", client, ["caller": client.callerClass, "chat": client.chat, "cmd": known, "target": target, "result": lastResult])
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
                chats = AgentReads.readable(own: own)
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
        case AgentCommand.options.name:
            guard let chat = changeable(args, client, id) else { return nil }
            let o = chat.arsenalOptions
            send(client, AgentResult(id: id, ok: true, data: AgentOptions(
                chat: chat.id.uuidString,
                models: o.models.map { .init(id: $0.id, name: $0.name, efforts: $0.efforts) }, model: o.model, effort: o.effort,
                modes: o.modes.map { .init(id: $0.id, label: $0.label, allowed: $0.allowed) }, mode: o.mode, fast: o.fast)))
            return chat.id.uuidString
        case AgentCommand.rename.name, AgentCommand.model.name, AgentCommand.effort.name, AgentCommand.mode.name:
            guard let chat = changeable(args, client, id) else { return nil }
            guard let value = args.to, !value.isEmpty, value.utf8.count <= 1024 else {
                fail(client, id, .invalid, "Say what to set it to.")
                return chat.id.uuidString
            }
            let outcome = switch name {
            case AgentCommand.rename.name: chat.arsenalRename(value, taken: AgentReads.chatsByID().values.filter { $0 !== chat }.map(\.title))
            case AgentCommand.model.name: chat.arsenalModel(value)
            case AgentCommand.effort.name: chat.arsenalEffort(value)
            default: chat.arsenalMode(value)
            }
            done(outcome, chat, client, id)
            return chat.id.uuidString
        case AgentCommand.fast.name:
            guard let chat = changeable(args, client, id) else { return nil }
            guard let on = args.on else {
                fail(client, id, .invalid, "Say on or off.")
                return chat.id.uuidString
            }
            done(chat.arsenalFast(on), chat, client, id)
            return chat.id.uuidString
        case AgentCommand.compact.name:
            guard let chat = changeable(args, client, id) else { return nil }
            done(chat.arsenalCompact(), chat, client, id)
            return chat.id.uuidString
        case AgentCommand.new.name:
            return newChat(args, client, id)
        case AgentCommand.send.name:
            guard let chat = other(args, client, id) else { return nil }
            guard let text = args.text, text.utf8.count <= Self.textMax else {
                fail(client, id, .invalid, "Say the message, \(Self.textMax / 1024) KiB at most.")
                return chat.id.uuidString
            }
            guard sendBudgets[client.key, default: RateLimiter(limit: Self.sendsPerMinute, per: 60)].take() else {
                fail(client, id, .limit, "\(Self.sendsPerMinute) messages a minute at most.")
                return chat.id.uuidString
            }
            done(chat.arsenalSend(text, from: callerName(client)), chat, client, id)
            return chat.id.uuidString
        case AgentCommand.stop.name:
            guard let chat = other(args, client, id) else { return nil }
            let running = chat.isBusy
            chat.stop()
            send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chat.id.uuidString, message: running ? "Stopped." : "Nothing was running.")))
            return chat.id.uuidString
        case AgentCommand.showTab.name:
            guard let chat = changeable(args, client, id) else { return nil }
            guard let workspace = AgentReads.workspace(of: chat), workspace.arsenalShow(chat) else {
                fail(client, id, .noChat, "That chat has no tab of its own (it's on a board).")
                return chat.id.uuidString
            }
            send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chat.id.uuidString, message: "In front.")))
            return chat.id.uuidString
        case AgentCommand.answer.name:
            guard let chat = other(args, client, id) else { return nil }
            guard let card = args.card, card.utf8.count <= 256, (args.answers ?? []).allSatisfy({ $0.utf8.count <= 4096 }), (args.answers ?? []).count <= 16 else {
                fail(client, id, .invalid, "Name the card, and give an answer per question or deny.")
                return chat.id.uuidString
            }
            done(chat.arsenalAnswer(card, args.answers ?? [], deny: args.deny ?? false), chat, client, id)
            return chat.id.uuidString
        default:
            fail(client, id, .unknownCommand, Self.message(.unknownCommand))
        }
        return nil
    }

    /// The longest message a caller may send.
    static let textMax = 64 * 1024

    /// The chat a change names (`.` when none is named): the caller's own, or with Drive one it may drive.
    private func changeable(_ args: AgentArgs, _ client: Client, _ id: String) -> Chat? {
        guard let chat = resolve(args.chat ?? ".", client, id) else { return nil }
        if chat.id.uuidString == client.chat { return chat }
        return drivable(chat, client, id)
    }

    /// A chat other than the caller's own, that it may drive: a message, a stop or an answer to
    /// itself would come from inside its own turn.
    private func other(_ args: AgentArgs, _ client: Client, _ id: String) -> Chat? {
        guard let chat = resolve(args.chat, client, id) else { return nil }
        guard chat.id.uuidString != client.chat else {
            fail(client, id, .refused, "Not this chat: it's the one asking.")
            return nil
        }
        return drivable(chat, client, id)
    }

    /// Drive reaches any chat it can read whose mode is at or below its own (the owner's rule,
    /// 2026-11-08: "any chat at its level"). What it can read is Watch's limit.
    private func drivable(_ chat: Chat, _ client: Client, _ id: String) -> Chat? {
        guard tier(client) >= .drive, let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }) else {
            fail(client, id, .notOwn, "Own changes only this chat.")
            return nil
        }
        guard chat.noFreer(than: own) else {
            fail(client, id, .notOwn, "That chat's mode is above this one's: only you drive it.")
            return nil
        }
        return chat
    }

    /// The caller as the receiving chat names it: its title in quotes, and its short id, which
    /// no title can be or fake ("sent by you" can't be made).
    private func callerName(_ client: Client) -> String {
        guard let chat = client.chat, let own = AgentReads.chatsByID()[chat] else { return "an agent" }
        let title = AgentReads.title(own.title).filter { !"“”\"\n\r".contains($0) }.prefix(60)
        return "“\(title)” · \(AgentReads.short(chat))"
    }

    /// A new chat in the caller's window, in front, at or below its mode; its first message, if given.
    private func newChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }), let window = AgentReads.workspace(of: own) else {
            fail(client, id, .noWindow, "Only a chat in Kore opens chats, in its own window.")
            return nil
        }
        let mine = made[client.key, default: .weakObjects()]
        made[client.key] = mine
        let open = AgentReads.chatsByID()
        guard mine.allObjects.filter({ open[$0.id.uuidString] != nil }).count < Self.madeOpen else {
            fail(client, id, .limit, "\(Self.madeOpen) chats this one opened are open: close one first.")
            return nil
        }
        if let text = args.text, text.utf8.count > Self.textMax {
            fail(client, id, .invalid, "A message can be \(Self.textMax / 1024) KiB at most.")
            return nil
        }
        // Spent only by a chat that opens: a mode refused costs nothing.
        var budget = newBudgets[client.key, default: RateLimiter(limit: Self.newPerHour, per: 3600)]
        guard budget.take() else {
            fail(client, id, .limit, "\(Self.newPerHour) new chats an hour at most.")
            return nil
        }
        switch window.arsenalNewChat(provider: args.provider ?? own.provider.id, model: args.model, mode: args.mode, under: own) {
        case .failure(let refusal):
            fail(client, id, .refused, refusal.message)
            return nil
        case .success(let chat):
            newBudgets[client.key] = budget
            mine.add(chat)
            var message = "Opened a \(chat.provider.name) chat."
            if let text = args.text, !text.isEmpty {
                switch chat.arsenalSend(text, from: callerName(client)) {
                case .success: message += " Sent."
                case .failure(let refusal): message += " " + refusal.message
                }
            }
            let chatId = chat.id.uuidString
            send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chatId, message: message, short: AgentReads.short(chatId))))
            return chatId
        }
    }

    private func done(_ outcome: Result<String, ArsenalRefusal>, _ chat: Chat, _ client: Client, _ id: String) {
        switch outcome {
        case .success(let message):
            send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chat.id.uuidString, message: message)))
        case .failure(let refusal):
            fail(client, id, .refused, refusal.message)
        }
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
        // Only what this caller may read: the rest isn't there to it, not even by its id.
        let chats = Dictionary(AgentReads.readable(own: client.chat).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
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

    /// The window a history read is for: the caller's own chat's, and no other. A caller outside
    /// Kore's chats has no folder of its own.
    private func window(_ args: AgentArgs, _ client: Client, _ id: String) -> Workspace? {
        guard let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }), let workspace = AgentReads.workspace(of: own) else {
            fail(client, id, .noWindow, "Past chats can be read only from a chat in Kore, for its own folder.")
            return nil
        }
        if let folder = args.folder {
            let wanted = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
            guard wanted == workspace.folder.standardizedFileURL.path else {
                fail(client, id, .noWindow, "Past chats can be read only for this chat's own folder.")
                return nil
            }
        }
        return workspace
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
        let ids = dirty
        dirty = []
        for client in clients.values where !client.follows.isEmpty {
            let readable = AgentReads.readable(own: client.chat)
            for chatId in ids {
                guard var follow = client.follows[chatId] else { continue }
                guard let chat = readable.first(where: { $0.id.uuidString == chatId }) else {
                    send(client, AgentEvent(id: follow.id, chat: chatId, event: "gone"))
                    client.follows[chatId] = nil
                    continue
                }
                let state = AgentReads.state(chat)
                // The marks are what this caller was sent: a row still growing keeps its old one.
                var marks: [UUID: Int] = [:]
                for e in chat.transcript.entries.suffix(AgentReads.followWindow) {
                    let mark = AgentReads.mark(e)
                    if follow.marks[e.id] != mark, AgentReads.settled(e) || state != "working" {
                        send(client, AgentEvent(id: follow.id, chat: chatId, event: "row", row: AgentReads.row(e, folder: chat.folder)))
                        marks[e.id] = mark
                    } else {
                        marks[e.id] = follow.marks[e.id]
                    }
                }
                follow.marks = marks
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

    /// Encoded and masked on the channel's queue: a page of long rows costs the main thread
    /// nothing. Every line a caller gets comes through `encode`.
    private func send(_ client: Client, _ value: some Encodable & Sendable) {
        client.connection.send { Self.encode(value) }
    }

    nonisolated static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return Data("{}".utf8) }
        return Data(AgentSecrets.mask(String(decoding: data, as: UTF8.self)).utf8)
    }

    // MARK: For tests and storylines

    /// Connections open now.
    package var connections: Int { clients.count }
    /// The last connection made, while anything holds it: tests see it go.
    weak var newestConnection: AgentConnection?
    /// Callers named by their hello, as `chat:<id>` or `external`.
    package var callers: [String] { clients.values.filter(\.named).map(\.key).sorted() }
}

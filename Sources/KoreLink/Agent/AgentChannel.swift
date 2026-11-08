import AgentTools
import AppKit
import Darwin
import Foundation
import HostClient
import KoreCore
import KoreUI
import LinkProtocol
import src
import Tailnet

/// Kore's agent channel (`z-docs/agent-protocol.md`): the socket the `kore` command and agents in
/// Kore's chats read Kore through, apart from the local link. It exists only while the master
/// switch is on and some grant is live (`AgentGrants`); otherwise there's no socket, queue,
/// observer or timer. Each connection names its caller once, from the kernel and Kore's records
/// (`AgentCaller`), and each command is checked against that caller's tier as it is then.
@MainActor
package final class AgentChannel {
    /// The channel open now; nil while closed.
    package private(set) static var current: AgentChannel?

    /// `~/Library/Application Support/Kore/agent` (`KoreFolders`); tests and storylines use their own.
    package static var directory: URL = KoreReach.defaultDirectory {
        // Chats launched from now on are told of a socket other than the default (`KoreReach`).
        didSet { KoreReach.socket = directory.appendingPathComponent(socketName).path }
    }
    package static let socketName = "kore.sock"

    /// Commands a caller may run a minute (`ArsenalRules`, kore-host's too).
    static let perMinute = ArsenalRules.perMinute
    /// Lines a caller may send past `perMinute`, each answered, before its connection ends.
    static let strikes = ArsenalRules.strikes
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
    static let sendsPerMinute = ArsenalRules.sendsPerMinute
    static let newPerHour = ArsenalRules.newPerHour
    static let madeOpen = ArsenalRules.madeOpen
    /// The longest a `chat.wait` holds, in seconds.
    static let waitMax = ArsenalRules.waitMax
    private var sendBudgets: [String: RateLimiter] = [:]
    private var newBudgets: [String: RateLimiter] = [:]
    private var made: [String: NSHashTable<Chat>] = [:]
    private var dirty = Set<String>()
    private var flushDue = false
    private var quitObserver: NSObjectProtocol?

    private final class Client {
        let token: UUID
        /// A caller on the socket, or a chat on a box (one call, its lines to `answer`).
        let connection: AgentConnection?
        let peer: AgentCaller.Peer?
        let answer: ((Data) -> Void)?
        /// Set by its hello: the chat it runs in, or nil for an external caller.
        var named = false
        var chat: String?
        var follows: [String: Follow] = [:]
        /// `chat.wait`s, by the chat waited on.
        var waits: [String: Wait] = [:]

        struct Wait {
            /// The command's id, which its result carries.
            let id: String
            let token = UUID()
        }

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
            answer = nil
        }

        /// A box chat's call (link 1.6): named by the Mac's records, not by a hello.
        init(token: UUID, chat: String, answer: @escaping (Data) -> Void) {
            self.token = token
            connection = nil
            peer = nil
            self.answer = answer
            self.chat = chat
            named = true
        }

        /// One line to it.
        func send(_ line: @escaping @Sendable () -> Data) {
            if let connection { connection.send(line) } else { answer?(line()) }
        }

        /// `last`, then the end of it.
        func finish(after last: Data) {
            if let connection { connection.finish(after: last) } else { answer?(last) }
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
    private nonisolated static let tooMany = encode(AgentBye(code: .rateLimited, message: AgentTools.tooManyLine)) + Data([0x0A])
    private nonisolated static let unknownProcess = encode(AgentBye(code: .mismatch, message: "Kore couldn't tell which process this is.")) + Data([0x0A])
    /// A caller that reaches the socket as it goes (agent control just went off) is told so.
    private nonisolated static let switchedOff = encode(AgentBye(code: .stopped, message: "Agent control is off in Kore.")) + Data([0x0A])

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
        for client in clients.values { client.finish(after: bye) }
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
            client.finish(after: Self.encode(AgentBye(code: .stopped, message: "Kore access is off for this caller.")))
            clients[key] = nil
        }
        for client in clients.values where !client.follows.isEmpty || !client.waits.isEmpty {
            let readable = Set(AgentReads.readable(own: client.chat).map(\.id.uuidString))
            for (chatId, follow) in client.follows where !readable.contains(chatId) {
                send(client, AgentEvent(id: follow.id, chat: chatId, event: "gone"))
                client.follows[chatId] = nil
            }
            endWaits(client, keeping: readable)
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
            endWaits(client, keeping: Set(open.keys))
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
            // Its hello may be in already: `SocketEnd` sends the bye and reads to its end, so a
            // close with that unread doesn't reset the line away.
            SocketEnd.start(fd, owed: Self.switchedOff)
            queue.async { slots.release(peer.pid) }
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
        if !client.follows.isEmpty || !client.waits.isEmpty { followsChanged() }
    }

    private func refuse(_ client: Client, _ code: AgentCode, _ message: String) {
        clients[client.token] = nil
        client.finish(after: Self.encode(AgentBye(code: code, message: message)))
        log("agent-refused", client, ["caller": client.callerClass, "chat": client.chat, "code": code.rawValue])
        if !client.follows.isEmpty || !client.waits.isEmpty { followsChanged() }
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
        let verdict = AgentCaller.verdict(ancestors: client.peer?.ancestors ?? [], pass: message.pass, clis: AgentPasses.shared.pids())
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
            guard tier(client) != .off else { return refuse(client, .denied, AgentChannel.offLine) }
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
        case AgentCommand.open.name:
            return openChat(args, client, id)
        case AgentCommand.history.name:
            guard let workspace = window(args, client, id) else { return nil }
            let data = AgentReads.history(workspace, query: args.query, archived: args.archived ?? false, offset: args.offset ?? 0)
            send(client, AgentResult(id: id, ok: true, data: data))
        case AgentCommand.options.name:
            guard let chat = changeable(args, client, id) else { return nil }
            let o = chat.arsenalOptions(under: callerChat(client))
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
            default: chat.arsenalMode(value, under: callerChat(client))
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
        case AgentCommand.fork.name:
            return forkChat(args, client, id)
        case AgentCommand.wait.name:
            return wait(args, client, id)
        case AgentCommand.send.name:
            return sendChat(args, client, id)
        case AgentCommand.stop.name:
            guard let chat = other(args, client, id) else { return nil }
            let running = chat.isBusy
            chat.stop()
            send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chat.id.uuidString, message: running ? "Stopped." : "Nothing was running.")))
            return chat.id.uuidString
        case AgentCommand.close.name:
            return closeChat(args, client, id)
        case AgentCommand.ask.name:
            return askChat(args, client, id)
        case AgentCommand.reply.name:
            return replyAsk(args, client, id)
        case AgentCommand.fetch.name:
            return fetchFile(args, client, id)
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
            done(chat.arsenalAnswer(card, args.answers ?? [], deny: args.deny ?? false, allow: args.allow ?? false, by: callerChat(client)), chat, client, id)
            return chat.id.uuidString
        default:
            fail(client, id, .unknownCommand, Self.message(.unknownCommand))
        }
        return nil
    }

    /// A chat closed as its tab's close closes it (`Workspace.arsenalClose`), named by its full or
    /// short id only (`AgentRefs.resolveID`): titles repeat, so a title names none, and the ids that
    /// hold it come back to pick from. Never the caller's own; one it drives.
    private func closeChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let ref = args.chat, !ref.isEmpty, ref.utf8.count <= 128 else {
            fail(client, id, .noChat, "Name the chat by its short id (kore ls) or its full id.")
            return nil
        }
        let chats = Dictionary(AgentReads.readable(own: client.chat).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let named = { (ids: [String]) in ids.compactMap { chats[$0] }.map { "\(AgentReads.short($0.id.uuidString)) “\(AgentReads.title($0.title))”" }.joined(separator: ", ") }
        let chat: Chat
        switch AgentRefs.resolveID(ref, chats: chats.values.map { (id: $0.id.uuidString, title: $0.title) }) {
        case .chat(let found):
            guard let found = chats[found] else {
                fail(client, id, .noChat, "That chat isn't open in Kore.")
                return nil
            }
            chat = found
        case .itself:
            fail(client, id, .refused, "A chat never closes itself.")
            return nil
        case .none:
            fail(client, id, .noChat, "No open chat has the id \u{201C}\(ref)\u{201D}.")
            return nil
        case .byTitle(let ids):
            fail(client, id, .ambiguous, "Close takes an id, never a title: " + named(ids))
            return nil
        case .ambiguous(let ids):
            fail(client, id, .ambiguous, "Several chats have that short id: give the full one. " + named(ids))
            return nil
        }
        let chatId = chat.id.uuidString
        guard chatId != client.chat else {
            fail(client, id, .refused, "A chat never closes itself.")
            return chatId
        }
        guard drivable(chat, client, id) != nil else { return chatId }
        guard let window = AgentReads.workspace(of: chat) else {
            fail(client, id, .noWindow, "That chat has no window.")
            return chatId
        }
        let short = AgentReads.short(chatId)
        switch window.arsenalClose(chat) {
        case .failure(let refusal): fail(client, id, .refused, refusal.message)
        case .success(let said): send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chatId, message: said, short: short)))
        }
        return chatId
    }

    // MARK: Sending, and waking a chat

    /// `chat.send`: a message to a chat it drives, queued while that chat works. An open chat it
    /// names goes as it always went (`sendOpen`); with `folder`, only that folder's window's open
    /// chats are looked at. A name no open chat has is looked for in History: the chat is woken
    /// (`wake`), opened as `chat.open` opens it, then sent the message.
    private func sendChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        var scope: Workspace?
        if args.folder != nil {
            guard let window = window(args, client, id) else { return nil }
            scope = window
        }
        if let ref = args.chat, !ref.isEmpty, case .none = lookup(ref, client, in: scope).found {
            return wake(ref, args, client, id, in: scope)
        }
        guard let chat = other(args, client, id, in: scope) else { return nil }
        return sendOpen(chat, args, client, id)
    }

    /// A message to an open chat it drives, as the composer sends it.
    private func sendOpen(_ chat: Chat, _ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let text = args.text, text.utf8.count <= Self.textMax else {
            fail(client, id, .invalid, "Say the message, \(Self.textMax / 1024) KiB at most.")
            return chat.id.uuidString
        }
        if let free = sendBudgets[client.key, default: RateLimiter(limit: Self.sendsPerMinute, per: 60)].nextFree() {
            fail(client, id, .limit, "\(Self.sendsPerMinute) messages a minute at most: " + Self.freesUp(free))
            return chat.id.uuidString
        }
        // Spent only by a message the chat takes.
        let outcome = chat.arsenalSend(text, from: callerName(client))
        if case .success = outcome { _ = sendBudgets[client.key, default: RateLimiter(limit: Self.sendsPerMinute, per: 60)].take() }
        done(outcome, chat, client, id)
        return chat.id.uuidString
    }

    /// Sends that wait for a chat being woken, by its window and History id: the first opens it,
    /// the rest go after it in the order they came, so one chat opens once and its messages keep
    /// their order however close together they arrive.
    private var waking: [WakeKey: [(Result<(chat: Chat, opened: Bool), ArsenalRefusal>) -> Void]] = [:]

    /// A woken chat's send is answered once: when its CLI has the message, or at the patience's end.
    @MainActor
    private final class WakeAnswer {
        var answered = false
        var patience: Task<Void, Never>?
    }

    /// Why a woken chat's message didn't go, as its caller is told.
    private struct WakeRefusal: Error {
        let code: AgentCode
        let text: String
    }

    private struct WakeKey: Hashable {
        let window: ObjectIdentifier
        let session: String
    }

    /// How long a woken chat's caller waits for its CLI to take the message before it's told the
    /// message waits there (the CLI's own start tries again for up to 17 s).
    package static var wakePatience: Duration = .seconds(40)

    /// A chat named by its CLI session id, or by a past chat History lists in the window (the
    /// caller's, or `folder`'s): opened as `chat.open` opens it (`Workspace.arsenalOpen`: its tab,
    /// its CLI's session resumed, its mode capped at the caller's, its Arsenal off), then sent the
    /// message as `sendOpen` sends it. The same tier, limits and reach as `chat.open` then
    /// `chat.send`: a new chat for the limits, and only a chat this caller could read and drive
    /// once it's open, so never one in another folder (opened, its Arsenal is off). Answered once
    /// its CLI has the message, or with why it doesn't.
    private func wake(_ ref: String, _ args: AgentArgs, _ client: Client, _ id: String, in scope: Workspace?) -> String? {
        let quoted = "\u{201C}\(ref.prefix(80))\u{201D}"
        // A caller outside Kore's chats has no window, so no History: as before.
        guard let own = callerChat(client), let home = AgentReads.workspace(of: own) else {
            fail(client, id, .noChat, "No open chat matches \(quoted).")
            return nil
        }
        let window = scope ?? home
        let place = window.boxFolder ?? LinkSnapshot.homeRelative(window.folder.path)
        // An open chat named by its CLI session id, as kore history and kore show give it.
        let wanted = ref.trimmingCharacters(in: .whitespaces).lowercased()
        let readable = AgentReads.readable(own: client.chat).filter { scope == nil || AgentReads.workspace(of: $0) === scope }
        let bySession = readable.filter { chat in
            guard let session = chat.listedId?.lowercased() else { return false }
            return session == wanted || (wanted.count >= 6 && session.hasPrefix(wanted))
        }
        if bySession.count == 1 {
            guard let chat = otherThan(client, bySession[0], id) else { return bySession[0].id.uuidString }
            return sendOpen(chat, args, client, id)
        }
        if bySession.count > 1 {
            let names = bySession.map { "\(AgentReads.short($0.id.uuidString)) \u{201C}\(AgentReads.title($0.title))\u{201D}" }
            fail(client, id, .ambiguous, "Several open chats' sessions start with \(quoted): " + names.joined(separator: ", ") + ".")
            return nil
        }
        // What `sendOpen` and `chat.open` check, before anything opens.
        guard let text = args.text, text.utf8.count <= Self.textMax else {
            fail(client, id, .invalid, "Say the message, \(Self.textMax / 1024) KiB at most.")
            return nil
        }
        if let refusal = Chat.arsenalRefusal(text) {
            fail(client, id, .refused, refusal.message)
            return nil
        }
        if Chat.arsenalLead(text) == "/" {
            fail(client, id, .refused, "\(quoted) isn't open, and a \u{201C}/\u{201D} command goes only to an open chat, whose list has it: open it first (kore open).")
            return nil
        }
        if let free = sendBudgets[client.key, default: RateLimiter(limit: Self.sendsPerMinute, per: 60)].nextFree() {
            fail(client, id, .limit, "\(Self.sendsPerMinute) messages a minute at most: " + Self.freesUp(free))
            return nil
        }
        guard roomForNew(client, id) else { return nil }
        // History is read (a box's over its link), one wake's lookup after another in a window, so
        // sends to a chat it's opening line up in the order they came. Answered once the chat is
        // open and has the message.
        let lookups = ObjectIdentifier(window)
        let previous = wakeLookups[lookups]
        let token = UUID()
        let lookup = Task { @MainActor [weak self, weak client] in
            await previous?.task.value
            defer { if self?.wakeLookups[lookups]?.token == token { self?.wakeLookups[lookups] = nil } }
            var past = await window.arsenalPast(fresh: false)
            var found = AgentRefs.resolvePast(ref, sessions: past.map { (id: $0.id, title: $0.title, archived: $0.archived) })
            // A list read before the chat closed may not have it yet: read once more before saying so.
            if case .none = found {
                past = await window.arsenalPast(fresh: true)
                found = AgentRefs.resolvePast(ref, sessions: past.map { (id: $0.id, title: $0.title, archived: $0.archived) })
            }
            guard let self, let client, AgentChannel.current === self, self.tier(client) >= .drive else { return }
            let summary: SessionSummary
            switch found {
            case .none:
                return self.fail(client, id, .noChat, "No open or past chat matches \(quoted) in \(place).")
            case .ambiguous(let ids):
                let byId = Dictionary(past.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let names = ids.compactMap { byId[$0] }.map { "\(AgentRefs.short($0.id)) \u{201C}\(AgentReads.title($0.title))\u{201D}" }
                return self.fail(client, id, .ambiguous, "Several past chats match \(quoted): " + names.joined(separator: ", ") + ". Name one by its id; nothing was sent.")
            case .session(let session):
                guard let found = past.first(where: { $0.id == session }) else { return self.fail(client, id, .noChat, "No open or past chat matches \(quoted) in \(place).") }
                summary = found
            }
            let title = "\u{201C}\(AgentReads.title(summary.title))\u{201D}"
            // Opened, its Arsenal is off: only a chat in the caller's own folder is one it reads then.
            guard window.folder.standardizedFileURL.path == home.folder.standardizedFileURL.path else {
                return self.fail(
                    client, id, .notOwn,
                    "\(title) is in History in \(place), another folder: opened from here its Arsenal is off, so this chat couldn't reach it. Nothing was opened or sent.")
            }
            self.wakeAndSend(summary, in: window, text: text, client, id)
        }
        wakeLookups[lookups] = (token, lookup)
        return nil
    }

    /// Each window's last wake lookup: the next waits for it.
    private var wakeLookups: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Opens the past chat (once, however many sends wait for it) and sends it this caller's message.
    private func wakeAndSend(_ summary: SessionSummary, in window: Workspace, text: String, _ client: Client, _ id: String) {
        let key = WakeKey(window: ObjectIdentifier(window), session: summary.id)
        let first = waking[key] == nil
        guard let own = callerChat(client) else { return fail(client, id, .noWindow, "This chat closed.") }
        waking[key, default: []].append { [weak self, weak client] result in
            guard let self, let client, AgentChannel.current === self, self.tier(client) >= .drive else { return }
            switch result {
            case .failure(let refusal):
                self.fail(client, id, .refused, refusal.message)
            case .success(let (chat, opened)):
                if opened && first { self.spentNew(chat, client) }
                self.sendWoken(chat, opened: opened && first, text: text, client, id)
            }
        }
        guard first else { return }
        Task { @MainActor [weak self] in
            let result = await window.arsenalOpen(session: summary.id, under: own)
            guard let self else { return }
            // Every send that waited, in the order they came: each message is in the chat before the next.
            for send in self.waking.removeValue(forKey: key) ?? [] { send(result) }
        }
    }

    /// The woken chat's message, under `chat.send`'s rules for this caller now (its reach, its
    /// limit), answered when the CLI has it: a CLI that didn't start says why, and the message
    /// is back in the chat's composer, never lost without a word.
    private func sendWoken(_ chat: Chat, opened: Bool, text: String, _ client: Client, _ id: String) {
        let chatId = chat.id.uuidString
        let short = AgentReads.short(chatId)
        let title = "\u{201C}\(AgentReads.title(chat.title))\u{201D}"
        let lead = opened ? "Opened \(title). " : ""
        // Opened, it must be one this caller reads and drives, as `chat.send` would find it.
        guard AgentReads.readable(own: client.chat).contains(where: { $0 === chat }) else {
            return fail(client, id, .notOwn, lead + "This chat can't reach it now: not sent.")
        }
        guard otherThan(client, chat, id) != nil else { return }
        if let free = sendBudgets[client.key, default: RateLimiter(limit: Self.sendsPerMinute, per: 60)].nextFree() {
            return fail(client, id, .limit, lead + "\(Self.sendsPerMinute) messages a minute at most: " + Self.freesUp(free))
        }
        let queued = chat.status.isRunning
        let once = WakeAnswer()
        let answer: @MainActor (Result<String, WakeRefusal>) -> Void = { [weak self, weak client] outcome in
            guard !once.answered else { return }
            once.answered = true
            once.patience?.cancel()
            guard let self, let client else { return }
            switch outcome {
            case .success(let said): self.send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chatId, message: lead + said, short: short)))
            case .failure(let refusal): self.fail(client, id, refusal.code, lead + refusal.text)
            }
        }
        let outcome = chat.arsenalSend(text, from: callerName(client)) { taken in
            switch taken {
            case .success: answer(.success(queued ? "Queued: it goes when the turn running there ends." : "Sent."))
            case .failure(let error):
                if AgentReads.chatsByID()[chatId] == nil {
                    answer(.failure(WakeRefusal(code: .noChat, text: "It closed before its CLI took the message: not sent.")))
                } else {
                    let back = queued ? "" : " The message is back in its composer."
                    answer(.failure(WakeRefusal(code: .refused, text: "Not sent: \(chat.provider.name) couldn't take it (\(Chat.reason(error))).\(back)")))
                }
            }
        }
        switch outcome {
        case .failure(let refusal):
            answer(.failure(WakeRefusal(code: .refused, text: refusal.message)))
        case .success:
            // Spent only by a message the chat takes.
            _ = sendBudgets[client.key, default: RateLimiter(limit: Self.sendsPerMinute, per: 60)].take()
            guard !once.answered else { return }
            once.patience = Task { @MainActor in
                try? await Task.sleep(for: Self.wakePatience)
                guard !Task.isCancelled else { return }
                answer(.success("Its CLI is still starting: the message goes once it has (kore log \(short) shows it)."))
            }
        }
    }

    // MARK: Chat to chat

    /// Why a chat named for an ask names none.
    private struct RefWhy: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// A chat named by its id only, as close names one; why not (for "Not asked: ") otherwise.
    private func byID(_ ref: String?, _ client: Client) -> Result<Chat, RefWhy> {
        guard let ref, !ref.isEmpty, ref.utf8.count <= 128 else { return .failure(RefWhy("name the chat by its short id (kore ls) or its full id")) }
        let chats = Dictionary(AgentReads.readable(own: client.chat).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let named = { (ids: [String]) in ids.compactMap { chats[$0] }.map { "\(AgentReads.short($0.id.uuidString)) “\(AgentReads.title($0.title))”" }.joined(separator: ", ") }
        switch AgentRefs.resolveID(ref, chats: chats.values.map { (id: $0.id.uuidString, title: $0.title) }) {
        case .chat(let found): return chats[found].map(Result.success) ?? .failure(RefWhy("\(ref) is closed"))
        case .itself: return .failure(RefWhy("a chat doesn't ask itself"))
        case .none: return .failure(RefWhy("\(ref.prefix(40)) is closed"))
        case .byTitle(let ids): return .failure(RefWhy("ask takes an id, never a title: " + named(ids)))
        case .ambiguous(let ids): return .failure(RefWhy("several chats have that short id, give the full one: " + named(ids)))
        }
    }

    /// A refusal the asker's chat shows as a line, in the same words the agent reads.
    private func refuseLine(_ chat: Chat?, _ client: Client, _ id: String, _ what: String, _ why: String) {
        let text = "Not \(what): \(why)"
        chat?.note("⊘ " + text)
        fail(client, id, .refused, text)
    }

    /// `chat.ask`: a question to another Act unlimited chat, by its id, sent once it's idle
    /// (`ArsenalAsks`). Answers with the ask's id at once; the answer comes to `chat.wait`. A box's
    /// chat asks a Mac's as a Mac's asks a box's (the owner, 2026-11-19): a message, as `chat.send`
    /// sends one; only a fetch from another device needs Act device.
    private func askChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let asker = callerChat(client) else {
            fail(client, id, .noWindow, "Only a chat in Kore asks another.")
            return nil
        }
        guard let question = args.text?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty, question.utf8.count <= Self.textMax else {
            fail(client, id, .invalid, "Say the question, \(Self.textMax / 1024) KiB at most.")
            return nil
        }
        let target: Chat
        switch byID(args.chat, client) {
        case .failure(let why):
            refuseLine(asker, client, id, "asked", why.text)
            return nil
        case .success(let chat): target = chat
        }
        let targetId = target.id.uuidString
        let name = AgentReads.title(target.title)
        if target === asker {
            refuseLine(asker, client, id, "asked", "a chat doesn't ask itself")
            return targetId
        }
        guard target.noFreer(than: asker) else {
            refuseLine(asker, client, id, "asked", "\(name)'s mode lets it do more on its own than this chat's")
            return targetId
        }
        let shared = ArsenalAsks.shared
        if let why = shared.askRefusal(asker: asker.id.uuidString, target: targetId, targetName: name, targetTier: AgentGrants.tier(chat: targetId)) {
            refuseLine(asker, client, id, "asked", why)
            return targetId
        }
        let ask = shared.ask(asker, target, question: question)
        send(client, AgentResult(id: id, ok: true, data: AgentAskSent(
            chat: targetId, ask: ask.id,
            message: "Asked “\(name)” (ask \(ask.id)): it goes as its next message once it's idle. The answer comes to kore_wait with ask \(ask.id), and as a line in this chat; an ask ends after \(Int(ArsenalAsks.lifetime / 60)) min.")))
        return targetId
    }

    /// `chat.reply`: the answer to an ask this chat was asked, with a file from its own folder if
    /// given (fetch's rules), into the asker's inbox.
    private func replyAsk(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let replier = callerChat(client), let home = AgentReads.workspace(of: replier) else {
            fail(client, id, .noWindow, "Only a chat in Kore answers an ask.")
            return nil
        }
        guard let askId = args.ask?.trimmingCharacters(in: .whitespaces).lowercased(), !askId.isEmpty,
            let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= Self.textMax
        else {
            fail(client, id, .invalid, "Name the ask and say the answer, \(Self.textMax / 1024) KiB at most.")
            return nil
        }
        let shared = ArsenalAsks.shared
        if let why = shared.replyRefusal(askId, from: replier.id.uuidString) {
            refuseLine(replier, client, id, "answered", why)
            return nil
        }
        guard let ask = shared.asks[askId] else { return nil }
        guard let path = args.path, !path.isEmpty else {
            if let done = shared.answer(askId, text: text, file: nil) { shared.answered(done) }
            send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: ask.asker, message: "Answered “\(ask.askerName)”.")))
            return ask.asker
        }
        guard let asker = AgentReads.chatsByID()[ask.asker], let window = AgentReads.workspace(of: asker) else {
            refuseLine(replier, client, id, "answered", "\(ask.askerName) is closed")
            return ask.asker
        }
        if let why = shared.fetchRefusal(replier.id.uuidString) {
            refuseLine(replier, client, id, "answered", why)
            return ask.asker
        }
        let own = home.arsenalPlace
        let source: FilePlace
        switch ArsenalFetch.place(path, base: own, names: Workspace.arsenalBoxNames()) {
        case .failure(let refusal):
            refuseLine(replier, client, id, "answered", refusal.line)
            return ask.asker
        case .success(let place): source = place
        }
        let inbox = window.arsenalInbox
        let held = Workspace.arsenalBoxes(Set([source.alias, inbox.alias].compactMap { $0 }))
        Task { @MainActor [weak self, weak client] in
            // Its own folder only, on its own device.
            let roots = source.alias == own.alias ? [own.path] : []
            let result = await ArsenalFetch.run(source, roots: roots, into: inbox, boxes: held.boxes, acrossDevices: true)
            held.release()
            guard let self, let client else { return }
            switch result {
            case .failure(let refusal):
                self.refuseLine(replier, client, id, "answered", refusal.line)
            case .success(let landed):
                shared.spentFetch(replier.id.uuidString)
                guard let done = shared.answer(askId, text: text, file: landed.path) else {
                    return self.refuseLine(replier, client, id, "answered", shared.replyRefusal(askId, from: replier.id.uuidString) ?? "that ask ended")
                }
                shared.answered(done, file: .init(name: landed.name, where: ArsenalFetch.inbox + "/" + landed.name))
                self.send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: ask.asker, message: "Answered “\(ask.askerName)”, with \(landed.name).")))
            }
        }
        return ask.asker
    }

    /// `file.fetch`: one file from a folder a Kore window has open, on this Mac or a box, into
    /// this chat's `.kore/inbox/` (`ArsenalFetch`); from another device than the chat's, at Act
    /// device only.
    private func fetchFile(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let asker = callerChat(client), let window = AgentReads.workspace(of: asker) else {
            fail(client, id, .noWindow, "Only a chat in Kore fetches, into its own folder.")
            return nil
        }
        guard let path = args.path, !path.isEmpty, path.utf8.count <= 4096 else {
            fail(client, id, .invalid, "Name the file: device:path, or a path on this chat's device.")
            return nil
        }
        let shared = ArsenalAsks.shared
        if let why = shared.fetchRefusal(asker.id.uuidString) {
            refuseLine(asker, client, id, "fetched", why)
            return nil
        }
        let inbox = window.arsenalInbox
        let source: FilePlace
        switch ArsenalFetch.place(path, base: window.arsenalPlace, names: Workspace.arsenalBoxNames()) {
        case .failure(let refusal):
            refuseLine(asker, client, id, "fetched", refusal.line)
            return nil
        case .success(let place): source = place
        }
        let held = Workspace.arsenalBoxes(Set([source.alias, inbox.alias].compactMap { $0 }))
        let roots = Workspace.arsenalRoots(on: source.alias)
        let across = tier(client) >= .device
        Task { @MainActor [weak self, weak client] in
            let result = await ArsenalFetch.run(source, roots: roots, into: inbox, boxes: held.boxes, acrossDevices: across)
            held.release()
            guard let self, let client else { return }
            switch result {
            case .failure(let refusal):
                self.refuseLine(asker, client, id, "fetched", refusal.line)
            case .success(let landed):
                shared.spentFetch(asker.id.uuidString)
                let line = "Fetched \(source.name) from \(source.device) → \(ArsenalFetch.inbox)/\(landed.name)"
                asker.note("↓ " + line)
                self.send(client, AgentResult(id: id, ok: true, data: AgentFetched(file: landed.path, message: line + ".")))
            }
        }
        return nil
    }

    /// `chat.wait` on an ask this chat made: its answer once it comes (or `timeout`), or how it ended.
    private func waitAsk(_ askId: String, _ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        let askId = askId.trimmingCharacters(in: .whitespaces).lowercased()
        guard let ask = ArsenalAsks.shared.asks[askId], ask.asker == client.chat else {
            fail(client, id, .noChat, "This chat made no ask with that id.")
            return nil
        }
        final class Once { var sent = false }
        let once = Once()
        let reply = { [weak self, weak client] (ask: ArsenalAsks.Ask, timedOut: Bool) in
            guard let self, let client, !once.sent else { return }
            once.sent = true
            let state = switch ask.ended {
            case .answered: "answered"
            case .expired: "expired"
            case .gone: "gone"
            case nil: "waiting"
            }
            self.send(client, AgentResult(id: id, ok: true, data: AgentAskWaited(ask: ask.id, state: state, answer: ask.answer, file: ask.file, timedOut: timedOut)))
        }
        ArsenalAsks.shared.whenEnded(askId) { reply($0, false) }
        guard !once.sent else { return ask.target }
        let seconds = min(max(args.timeout ?? Self.waitMax, 1), Self.waitMax)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            MainActor.assumeIsolated {
                if let now = ArsenalAsks.shared.asks[askId] { reply(now, true) }
            }
        }
        return ask.target
    }

    /// The caller's own chat, when it's one of Kore's.
    private func callerChat(_ client: Client) -> Chat? { client.chat.flatMap { AgentReads.chatsByID()[$0] } }

    /// The longest message a caller may send.
    static let textMax = ArsenalRules.textMax

    /// The chat a change names (`.` when none is named): the caller's own, or with Drive one it may drive.
    private func changeable(_ args: AgentArgs, _ client: Client, _ id: String) -> Chat? {
        guard let chat = resolve(args.chat ?? ".", client, id) else { return nil }
        if chat.id.uuidString == client.chat { return chat }
        return drivable(chat, client, id)
    }

    /// A chat other than the caller's own, that it may drive: a message, a stop or an answer to
    /// itself would come from inside its own turn.
    private func other(_ args: AgentArgs, _ client: Client, _ id: String, in scope: Workspace? = nil) -> Chat? {
        guard let chat = resolve(args.chat, client, id, in: scope) else { return nil }
        return otherThan(client, chat, id)
    }

    /// `chat` when it isn't the caller's own and the caller drives it (`other`'s checks).
    private func otherThan(_ client: Client, _ chat: Chat, _ id: String) -> Chat? {
        guard chat.id.uuidString != client.chat else {
            fail(client, id, .refused, "Not this chat: it's the one asking.")
            return nil
        }
        return drivable(chat, client, id)
    }

    /// Act unlimited (`drive`) reaches any chat it can read whose mode is at or below its own (the
    /// owner's rule, 2026-11-08: "any chat at its level"). What it can read is Read's (`watch`) limit.
    private func drivable(_ chat: Chat, _ client: Client, _ id: String) -> Chat? {
        guard tier(client) >= .drive, let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }) else {
            fail(client, id, .notOwn, "Act limited changes only this chat.")
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
    /// A chat on a box opens it on that box, or with `place` `mac` in a window on this Mac.
    private func newChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }), let home = AgentReads.workspace(of: own) else {
            fail(client, id, .noWindow, "Only a chat in Kore opens chats, in its own window.")
            return nil
        }
        let window: Workspace
        switch args.place {
        case nil, "box": window = home
        case "mac":
            guard let mac = home.macWindow else {
                fail(client, id, .noWindow, "No Kore window is open on the Mac.")
                return nil
            }
            window = mac
        default:
            fail(client, id, .invalid, "place is box or mac.")
            return nil
        }
        guard roomForNew(client, id) else { return nil }
        if let text = args.text, text.utf8.count > Self.textMax {
            fail(client, id, .invalid, "A message can be \(Self.textMax / 1024) KiB at most.")
            return nil
        }
        switch window.arsenalNewChat(provider: args.provider ?? own.provider.id, model: args.model, mode: args.mode, under: own) {
        case .failure(let refusal):
            fail(client, id, .refused, refusal.message)
            return nil
        case .success(let chat):
            spentNew(chat, client)
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

    /// Room for a chat it makes: fewer than `madeOpen` of them open, and `newPerHour` not spent.
    /// Only a chat that opens spends it (`spentNew`).
    private func roomForNew(_ client: Client, _ id: String) -> Bool {
        let open = AgentReads.chatsByID()
        let mine = made[client.key]?.allObjects.filter { open[$0.id.uuidString] != nil } ?? []
        guard mine.count < Self.madeOpen else {
            fail(client, id, .limit, "\(Self.madeOpen) chats this one opened are open: close one first.")
            return false
        }
        if let free = newBudgets[client.key, default: RateLimiter(limit: Self.newPerHour, per: 3600)].nextFree() {
            fail(client, id, .limit, "\(Self.newPerHour) new chats an hour at most: " + Self.freesUp(free))
            return false
        }
        return true
    }

    private func spentNew(_ chat: Chat, _ client: Client) {
        _ = newBudgets[client.key, default: RateLimiter(limit: Self.newPerHour, per: 3600)].take()
        let mine = made[client.key, default: .weakObjects()]
        made[client.key] = mine
        mine.add(chat)
    }

    /// When the next one frees up, for a limit's refusal.
    static func freesUp(_ date: Date, now: Date = Date()) -> String { ArsenalRules.freesUp(date, now: now) }

    /// A fork of a chat it reaches (its own included), opened as the fork in a message's menu opens
    /// one: in front, the conversation with it, in that chat's mode, Arsenal off. A new chat for the
    /// limits. Where it starts is the CLI's to say, so it answers when the tab is open.
    private func forkChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let chat = changeable(args, client, id) else { return nil }
        guard AgentReads.workspace(of: chat) != nil else {
            fail(client, id, .noChat, "That chat has no window of its own (it's on a board).")
            return chat.id.uuidString
        }
        guard roomForNew(client, id) else { return chat.id.uuidString }
        if let text = args.text, text.utf8.count > Self.textMax {
            fail(client, id, .invalid, "A message can be \(Self.textMax / 1024) KiB at most.")
            return chat.id.uuidString
        }
        let at = args.at.map { String($0.prefix(4096)) }
        // Into the other CLI: the whole conversation, carried as Import carries it.
        let across = args.provider.flatMap { $0 == chat.provider.id ? nil : $0 }
        if across != nil, at != nil {
            fail(client, id, .invalid, "A fork into another CLI carries the whole conversation: leave out at.")
            return chat.id.uuidString
        }
        let message = args.text.flatMap { $0.isEmpty ? nil : $0 }
        Task { @MainActor [weak self, weak client] in
            let start = across == nil ? await chat.arsenalForkStart(at: at) : nil
            // Its access, its reach and the limits again, after the wait for the CLI.
            guard let self, let client, AgentChannel.current === self, self.tier(client) >= .drive else { return }
            guard let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }), chat === own || chat.noFreer(than: own),
                let window = AgentReads.workspace(of: chat)
            else { return self.fail(client, id, .notOwn, "That chat's mode is above this one's: only you drive it.") }
            guard self.roomForNew(client, id) else { return }
            let opened: Result<Chat, ArsenalRefusal>
            if let across {
                opened = await window.arsenalForkAcross(chat, to: across, model: args.model, under: own)
                guard AgentChannel.current === self, self.tier(client) >= .drive else { return }
            } else {
                switch start {
                case .failure(let refusal): opened = .failure(refusal)
                case .success(let (start, draft)):
                    opened = window.arsenalOpenFork(chat, start, draft: draft, model: args.model, message: message != nil)
                case nil: return
                }
            }
            switch opened {
            case .failure(let refusal):
                self.fail(client, id, .refused, refusal.message)
            case .success(let fork):
                self.spentNew(fork, client)
                var said = across == nil ? "Forked it." : "Forked it into \(fork.provider.name)."
                if let message {
                    switch fork.arsenalSend(message, from: self.callerName(client)) {
                    case .success: said += " Sent."
                    case .failure(let refusal): said += " " + refusal.message
                    }
                }
                let forkId = fork.id.uuidString
                self.send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: forkId, message: said, short: AgentReads.short(forkId))))
            }
        }
        return chat.id.uuidString
    }

    // MARK: Waiting

    /// Until the chat's turn ends or a card asks (or `timeout`, 300 s at most): its state and last
    /// answer. Held by the follow taps, so nothing polls; only the command counts toward the limit.
    private func wait(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        if let ask = args.ask { return waitAsk(ask, args, client, id) }
        guard let chat = resolve(args.chat, client, id) else { return nil }
        let chatId = chat.id.uuidString
        guard chatId != client.chat else {
            fail(client, id, .refused, "Not this chat: its turn is the one asking.")
            return chatId
        }
        guard AgentReads.state(chat) == "working" else {
            waited(client, id, chat, timedOut: false)
            return chatId
        }
        guard client.waits[chatId] == nil else {
            fail(client, id, .refused, "Already waiting on that chat.")
            return chatId
        }
        let wait = Client.Wait(id: id)
        client.waits[chatId] = wait
        followsChanged()
        let seconds = min(max(args.timeout ?? Self.waitMax, 1), Self.waitMax)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self, weak client] in
            MainActor.assumeIsolated {
                guard let self, let client, client.waits[chatId]?.token == wait.token else { return }
                client.waits[chatId] = nil
                if let chat = AgentReads.chatsByID()[chatId] {
                    self.waited(client, id, chat, timedOut: true)
                } else {
                    self.fail(client, id, .noChat, "That chat closed.")
                }
                self.followsChanged()
            }
        }
        return chatId
    }

    private func waited(_ client: Client, _ id: String, _ chat: Chat, timedOut: Bool) {
        let answer = chat.transcript.entries.last { $0.kind == .answer }.flatMap { AgentReads.row($0, folder: chat.folder).text }
        send(client, AgentResult(id: id, ok: true, data: AgentWaited(
            chat: chat.id.uuidString, state: AgentReads.state(chat), answer: answer, cards: AgentReads.cards(chat).count, timedOut: timedOut)))
    }

    /// Waits on a chat no longer there, or no longer readable: answered so.
    private func endWaits(_ client: Client, keeping readable: Set<String>) {
        for (chatId, wait) in client.waits where !readable.contains(chatId) {
            fail(client, wait.id, .noChat, "That chat closed, or can't be read now.")
            client.waits[chatId] = nil
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

    /// A chat's caller refused for having no grant: what the agent tells the user.
    static let offLine = AgentTools.offLine()

    static func message(_ code: AgentCode) -> String { ArsenalRules.message(code) }

    private func resolve(_ ref: String?, _ client: Client, _ id: String, in scope: Workspace? = nil) -> Chat? {
        guard let ref, !ref.isEmpty else {
            fail(client, id, .noChat, "Name a chat: its title, its short id, or . for this one.")
            return nil
        }
        let (found, chats) = lookup(ref, client, in: scope)
        switch found {
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

    /// The open chats `ref` names for this caller, and those it looked among: only what it may read
    /// (the rest isn't there to it, not even by its id), and with `scope` only that window's.
    private func lookup(_ ref: String, _ client: Client, in scope: Workspace?) -> (found: AgentRefs.Found, chats: [String: Chat]) {
        let readable = AgentReads.readable(own: client.chat).filter { chat in scope.map { AgentReads.workspace(of: chat) === $0 } ?? true }
        let chats = Dictionary(readable.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let titled = chats.values.map { (id: $0.id.uuidString, title: $0.title) }
        return (AgentRefs.resolve(ref, chats: titled, own: client.chat), chats)
    }

    /// The window a history read or an open is for: the caller's own chat's, or with Act unlimited
    /// that of any folder a Kore window has open (the owner, 2026-11-15). A caller outside Kore's
    /// chats has no folder of its own.
    private func window(_ args: AgentArgs, _ client: Client, _ id: String) -> Workspace? {
        guard let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }), let workspace = AgentReads.workspace(of: own) else {
            fail(client, id, .noWindow, "Past chats can be read only from a chat in Kore, for its own folder.")
            return nil
        }
        guard let folder = args.folder else { return workspace }
        let named = Self.windows(named: folder, from: workspace)
        if named.contains(where: { $0 === workspace }) { return workspace }
        guard tier(client) >= .drive else {
            fail(client, id, .noWindow, "Past chats can be read only for this chat's own folder: other folders need Act unlimited.")
            return nil
        }
        guard let other = named.first else {
            fail(client, id, .noWindow, "No Kore window has that folder open.")
            return nil
        }
        return other
    }

    /// The open windows `folder` names, as a chat in `home` names one, the same on the Mac and on a
    /// box: a path on the chat's own device (under its folder when relative), `device:path`, or the
    /// folder as `kore_list_chats` shows it.
    static func windows(named folder: String, from home: Workspace) -> [Workspace] {
        let open = AgentReads.workspaces()
        let listed = open.filter { ($0.boxFolder ?? LinkSnapshot.homeRelative($0.folder.path)) == folder }
        guard case .success(let place) = ArsenalFetch.place(folder, base: home.arsenalPlace, names: Workspace.arsenalBoxNames()) else { return listed }
        return open.filter { $0.arsenalIsFolder(place) } + listed
    }

    /// A past chat opened as History opens it (`Workspace.arsenalOpen`), in its folder's window, in
    /// front: a new chat for the limits when it wasn't open already.
    private func openChat(_ args: AgentArgs, _ client: Client, _ id: String) -> String? {
        guard let session = args.session, !session.isEmpty, session.utf8.count <= 128 else {
            fail(client, id, .invalid, "Name the past chat: its session id, as kore history shows it.")
            return nil
        }
        guard let own = client.chat.flatMap({ AgentReads.chatsByID()[$0] }), let window = window(args, client, id) else { return nil }
        guard roomForNew(client, id) else { return nil }
        // A box window's opens over the link: answered when the box has it.
        Task { @MainActor [weak self, weak client] in
            let result = await window.arsenalOpen(session: session, under: own)
            guard let self, let client, AgentChannel.current === self else { return }
            switch result {
            case .failure(let refusal):
                self.fail(client, id, .refused, refusal.message)
            case .success(let (chat, opened)):
                if opened { self.spentNew(chat, client) }
                let chatId = chat.id.uuidString
                let message = opened ? "Opened “\(AgentReads.title(chat.title))”." : "It was open: in front."
                self.send(client, AgentResult(id: id, ok: true, data: AgentDone(chat: chatId, message: message, short: AgentReads.short(chatId))))
            }
        }
        // Its log line names no chat: the one it opens isn't known yet.
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
        let following = AgentChannel.current === self && clients.values.contains { !$0.follows.isEmpty || !$0.waits.isEmpty }
        AgentTaps.on = following
        AgentTaps.event = following ? { chat, _ in AgentChannel.current?.noted(chat) } : nil
        if !following { dirty = [] }
    }

    private func noted(_ chat: Chat) {
        let id = chat.id.uuidString
        guard clients.values.contains(where: { $0.follows[id] != nil || $0.waits[id] != nil }) else { return }
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
        // A wait ends when its chat's turn does, or a card asks.
        let open = AgentReads.chatsByID()
        for client in clients.values where !client.waits.isEmpty {
            for chatId in ids {
                guard let wait = client.waits[chatId], let chat = open[chatId], AgentReads.state(chat) != "working" else { continue }
                client.waits[chatId] = nil
                waited(client, wait.id, chat, timedOut: false)
            }
        }
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
        client.send { Self.encode(value) }
    }

    nonisolated static func encode(_ value: some Encodable) -> Data { ArsenalRules.encode(value) }

    // MARK: A chat on a box

    /// One tool call from a box chat's agent (link 1.6, `AgentBoxCalls`): run as a caller in that
    /// chat would run it, against the chat's tier and its limits, and answered with the line its
    /// command's result (or refusal) would be. Its lines go nowhere else.
    func boxCall(chat: String, _ name: String, _ args: [String: Any]) async -> Data {
        await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
            // As many at once as a chat on the Mac holds connections (`AgentSlots.perProcess`).
            guard clients.values.filter({ $0.connection == nil && $0.chat == chat }).count < AgentSlots.perProcess else {
                return done.resume(returning: Self.encode(AgentBye(code: .rateLimited, message: AgentTools.tooManyLine)))
            }
            let token = UUID()
            var answered = false
            let client = Client(token: token, chat: chat) { [weak self] line in
                guard !answered else { return }
                answered = true
                self?.clients[token] = nil
                done.resume(returning: line)
            }
            clients[token] = client
            // A chat whose access went off since the call was made.
            guard tier(client) != .off else { return refuse(client, .denied, Self.offLine) }
            let line = (try? JSONSerialization.data(withJSONObject: ["type": "cmd", "id": Self.boxCallID, "cmd": name, "args": args])) ?? Data()
            received([line], token)
            // A result to come (a wait, a fork) holds its client; one that never comes isn't left
            // waiting when the channel closes.
            if !answered, clients[token] == nil { client.finish(after: Self.encode(AgentBye(code: .stopped, message: Self.message(.stopped)))) }
            // kore-host gives up after this: let go then, as a Mac caller's connection closes at its
            // timeout, so a result that never comes doesn't hold one of its places.
            guard !answered else { return }
            let seconds = AgentTools.answerWait(name, args) + AgentTools.linkMargin
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.clients[token] != nil else { return }
                    client.finish(after: Self.encode(AgentBye(code: .refused, message: AgentTools.noAnswerLine)))
                    self.followsChanged()
                }
            }
        }
    }

    static let boxCallID = "box"

    // MARK: For tests and storylines

    /// Connections open now.
    package var connections: Int { clients.count }
    /// The last connection made, while anything holds it: tests see it go.
    weak var newestConnection: AgentConnection?
    /// Callers named by their hello, as `chat:<id>` or `external`.
    package var callers: [String] { clients.values.filter(\.named).map(\.key).sorted() }
}

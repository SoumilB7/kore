import AppKit
import Foundation
import KoreCore
import KoreUI

/// One connection of an allowed companion (`LinkRun`): from a ring's reply until the client goes.
/// It holds the socket, the one client, the tick that turns Kore's state into what the client is
/// sent, and the title row's mark while connected. Nothing of it exists between connections, and
/// ending it removes all of it (`z-docs/link-protocol.md`).
@MainActor
package final class LinkHost {
    /// The link awake now; nil while asleep.
    package private(set) static var current: LinkHost?

    /// How long a ring's socket waits for its client before it's removed.
    package static var connectWithin: TimeInterval = 30
    /// How long a new connection has to prove itself.
    static let helloWithin: TimeInterval = 10
    /// Ticks a second, while linked.
    static let rate: TimeInterval = 0.25
    /// How many of a transcript's last entries a client follows, at first and at most.
    static let window = 60
    static let windowMax = 2000
    /// Transcripts followed at once.
    static let followMax = 8

    package let run: LinkRun
    package var name: String { run.name }
    package let socketPath: String
    /// This connection's own secret: a new one for every ring.
    package let secret: Data
    private let queue = DispatchQueue(label: "dev.kore.link")
    private let listener: LinkListener
    private var mark: LinkMark { run.mark }

    /// The client on the socket, proven or not yet.
    private var session: Session?
    private var timer: Timer?
    private var attention = LinkAttention()
    /// Wire entries already made, per chat, by entry id: re-made only from the first changed one.
    private var cache: [String: (epoch: String, entries: [String: LinkEntry])] = [:]
    private var dirtyChats = Set<String>()
    private var ticks = 0
    /// How long each tick took (the last 2000), for the navigation budget.
    package private(set) var tickTimes: [Duration] = []

    /// One connection's state.
    private final class Session {
        let connection: LinkConnection
        let nonce = LinkProof.random(32)
        var proven = false
        var projector = LinkProjector()
        var snapshotDue = true
        var subs: [String: Sub] = [:]
        /// Followed transcripts, oldest first (the one dropped past `followMax`).
        var followOrder: [String] = []
        var bucket = MessageBucket()
        var commands = RateLimiter(limit: 30, per: 60)
        var sends = RateLimiter(limit: 10, per: 60)

        struct Sub {
            var last: Int
            var fresh = true
            var known = Set<String>()
        }

        init(connection: LinkConnection) { self.connection = connection }
    }

    // MARK: Waking and ending

    /// Wakes a connection for the allowed `run`: a socket, in its own directory, with a new secret.
    package static func wake(run: LinkRun, directory: URL = defaultDirectory) throws -> LinkHost {
        if let current { current.end(.disconnected) }
        let host = try LinkHost(run: run, directory: directory)
        current = host
        return host
    }

    /// Allows `name` for this run and wakes its first connection (tests and storylines).
    package static func wake(name: String, requirement: SecRequirement, directory: URL = defaultDirectory) throws -> LinkHost {
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        return try wake(run: LinkRun.allow(name: name, requirement: requirement, key: (text as String?) ?? ""), directory: directory)
    }

    /// `~/Library/Application Support/Kore/link`.
    package static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kore", isDirectory: true).appendingPathComponent("link", isDirectory: true)
    }

    private init(run: LinkRun, directory: URL) throws {
        self.run = run
        secret = Data(base64Encoded: LinkProof.random(32)) ?? Data()
        // A socket an earlier run left behind is removed here.
        if let stale = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in stale where file.hasSuffix(".sock") { unlink(directory.appendingPathComponent(file).path) }
        }
        let token = LinkProof.random(9).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        socketPath = directory.appendingPathComponent("\(token).sock").path
        listener = try LinkListener(path: socketPath, queue: queue)
        let pinned = PinnedRequirement(run.requirement)
        listener.start { [weak self] fd in
            // On the link's queue: who it is is checked before anything is read.
            guard LinkIdentity.peerPasses(fd, pinned.value) else {
                Darwin.close(fd)
                return
            }
            LinkHost.onMain { self?.accepted(fd) }
        }
        UILog.event("link-woken", [:])
        // The socket lives only while a client is on its way: one that never comes leaves nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectWithin) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, LinkHost.current === self, !self.linked, self.session == nil else { return }
                self.end(.disconnected)
            }
        }
    }

    /// Ends this connection: `bye` to a client still there, the socket removed, every hook let
    /// go. The companion stays allowed for the run (`LinkRun.revoke` ends that).
    package func end(_ reason: LinkMessage.ByeReason) {
        guard LinkHost.current === self else { return }
        LinkHost.current = nil
        if let session { session.connection.finish(after: try? LinkMessage.bye(reason).encoded()) }
        session = nil
        listener.close()
        timer?.invalidate()
        timer = nil
        cache = [:]
        LinkTaps.on = false
        LinkTaps.event = nil
        Workspace.showLinkMark(nil)
        LinkPanel.closePopup()
        UILog.event("link-ended", ["reason": reason.rawValue])
    }

    /// Runs `work` on the main thread, in order.
    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: Connections

    private func accepted(_ fd: Int32) {
        guard LinkHost.current === self, session == nil else {
            // One client at a time.
            Darwin.close(fd)
            return
        }
        let connection = LinkConnection(
            fd: fd, queue: queue,
            onFrames: { [weak self] frames in LinkHost.onMain { self?.received(frames) } },
            onClose: { [weak self] oversize in LinkHost.onMain { self?.dropped(oversize: oversize) } },
            onSlow: { [weak self] in LinkHost.onMain { self?.end(.slow) } })
        let session = Session(connection: connection)
        self.session = session
        connection.start()
        send(.challenge(nonce: session.nonce))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloWithin) { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session, self.session === session, !session.proven else { return }
                self.refuse(.auth)
            }
        }
    }

    /// The client went away: this connection ends. The companion reconnects by ringing again.
    private func dropped(oversize: Bool) {
        guard LinkHost.current === self, let session else { return }
        self.session = nil
        if oversize { return end(.invalid) }
        if session.proven { UILog.event("link-dropped", [:]) }
        end(.disconnected)
    }

    /// A connection that didn't prove itself: `bye`, then closed. Before any client was linked,
    /// the link stays open for the right one.
    private func refuse(_ reason: LinkMessage.ByeReason) {
        guard let session else { return }
        self.session = nil
        session.connection.finish(after: try? LinkMessage.bye(reason).encoded())
        UILog.event("link-refused", ["reason": reason.rawValue])
    }

    private func send(_ message: LinkMessage) {
        guard let session, let data = try? message.encoded() else { return }
        session.connection.send(data)
    }

    private func received(_ frames: [Data]) {
        for frame in frames {
            guard let session, LinkHost.current === self else { return }
            guard let message = try? LinkMessage.decode(frame) else {
                return session.proven ? end(.invalid) : refuse(.invalid)
            }
            guard session.proven else {
                hello(message, session)
                continue
            }
            switch session.bucket.take() {
            case .ok: break
            case .over:
                if case .cmd(let id, _) = message { send(.result(.init(id: id, ok: false, code: .rateLimited))) }
                continue
            case .far:
                return end(.rateLimited)
            }
            handle(message, session)
        }
    }

    private func hello(_ message: LinkMessage, _ session: Session) {
        guard case .hello(let proto, let client, let proof, let commands) = message else { return refuse(.invalid) }
        guard proto.major == LinkProto.major else { return refuse(.version) }
        guard LinkProof.check(proof, secret: secret, nonce: session.nonce) else { return refuse(.auth) }
        session.proven = true
        run.offer(commands)
        LinkTaps.event = { [weak self] chat, event in self?.noted(chat, event) }
        LinkTaps.on = true
        Workspace.showLinkMark(mark)
        UILog.event("link-linked", ["build": String(client.build.prefix(32)), "commands": "\(run.commands.count)"])
        send(
            .welcome(
                .init(
                    proto: LinkProto.version, epoch: LinkRun.epoch, host: .init(name: Host.current().localizedName ?? "Mac", koreVersion: Self.version),
                    providers: LinkSnapshot.providers(), policy: .init(sendMaxLevel: LinkPolicy.sendMaxLevel), caps: ["tx", "attn"])))
        session.snapshotDue = true
        tick()
        send(attention.ledger.state(after: 0))
        startTicking()
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.rate, repeats: true) { _ in MainActor.assumeIsolated { LinkHost.current?.tick() } }
        // The default mode only: it waits while a window resizes, a menu is open or a scroller is dragged.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    // MARK: Messages from the client

    private func handle(_ message: LinkMessage, _ session: Session) {
        switch message {
        case .bye:
            // The client is going; it may ring again this run.
            end(.quit)
        case .txOpen(let chatId, let last):
            let count = min(max(last ?? Self.window, 1), Self.windowMax)
            session.subs[chatId] = Session.Sub(last: count)
            session.followOrder.removeAll { $0 == chatId }
            session.followOrder.append(chatId)
            while session.followOrder.count > Self.followMax {
                let oldest = session.followOrder.removeFirst()
                session.subs[oldest] = nil
                session.projector.close(oldest)
            }
            session.projector.close(chatId)
            tick()
        case .txMore(let chatId, let count):
            guard var sub = session.subs[chatId] else { return }
            sub.last = min(sub.last + max(count, 0), Self.windowMax)
            sub.fresh = true
            session.subs[chatId] = sub
            session.projector.close(chatId)
            tick()
        case .txClose(let chatId):
            session.subs[chatId] = nil
            session.followOrder.removeAll { $0 == chatId }
            session.projector.close(chatId)
        case .entryMore(let id, let chatId, let entryId, let field, let offset):
            let entry = LinkSnapshot.chatsByID()[chatId]?.transcript.entries.first { $0.id.uuidString == entryId }
            let text: String =
                switch field {
                case .text: entry?.text ?? ""
                case .input: entry?.input ?? ""
                case .result: entry?.result ?? ""
                case .unknown: ""
                }
            let piece = LinkSnapshot.piece(text, from: offset)
            send(.entryChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
        case .cardMore(let id, let chatId, let cardId, let offset):
            let approval = LinkSnapshot.chatsByID()[chatId]?.approvals.pending.first { $0.id == cardId }
            let piece = LinkSnapshot.piece(approval.flatMap(LinkSnapshot.fullContent) ?? "", from: offset)
            send(.cardChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
        case .cmd(let id, let command):
            send(.result(perform(id, command, session)))
            tick()
        case .challenge, .hello, .welcome, .command, .snapshot, .delta, .txPage, .txDelta, .txReset, .entryChunk, .cardChunk, .result, .attnState,
            .attnEvent, .unknown:
            // Kore's own messages, or a type from a newer client: skipped.
            break
        }
    }

    private func perform(_ id: String, _ command: LinkCommand, _ session: Session) -> LinkMessage.Result {
        guard session.commands.take() else { return .init(id: id, ok: false, code: .rateLimited) }
        if case .send = command, !session.sends.take() { return .init(id: id, ok: false, code: .rateLimited) }
        let chat = command.chatId.flatMap { LinkSnapshot.chatsByID()[$0] }
        let outcome = LinkActions.apply(command, chat: chat)
        UILog.event("link-cmd", ["type": command.type, "chat": command.chatId, "code": outcome.code?.rawValue ?? "ok"])
        if outcome.ok { mark.record(Self.describe(command, chat: chat ?? outcome.newChat)) }
        return .init(
            id: id, ok: outcome.ok, code: outcome.code, message: outcome.message, chatId: outcome.newChat?.id.uuidString,
            windowId: outcome.newWindowId)
    }

    /// An action as the mark lists it: what it did, and in which chat. Never what was said.
    static func describe(_ command: LinkCommand, chat: Chat?) -> String {
        let what: String =
            switch command {
            case .send: "Sent a message"
            case .stop: "Stopped"
            case .answer(_, _, let action, _, _):
                switch action {
                case .allow: "Allowed"
                case .deny: "Denied"
                case .approvePlan: "Approved a plan"
                case .keepPlanning: "Kept planning"
                case .submitAnswers: "Answered"
                case .implement: "Implemented the plan"
                case .stay: "Stayed in plan"
                default: "Answered"
                }
            case .setMode: "Lowered the mode"
            case .setPlan(_, let on): on ? "Turned plan on" : "Turned plan off"
            case .planReady(_, let choice): choice == .implement ? "Implemented the plan" : "Stayed in plan"
            case .new: "Started a chat"
            case .unknown: "Acted"
            }
        return chat.map { "\(what) · \($0.title)" } ?? what
    }

    // MARK: Kore's side

    private func noted(_ chat: Chat, _ event: ChatEvent) {
        dirtyChats.insert(chat.id.uuidString)
        if let turn = attention.noted(chat, event) { send(turn) }
    }

    /// What changed since the last tick, to the client: windows and every chat once a second,
    /// chats marked by their events in between, followed transcripts from their first changed
    /// entry. It never touches how Kore draws a chat.
    package func tick() {
        guard let session, session.proven else { return }
        let start = ContinuousClock.now
        defer {
            tickTimes.append(ContinuousClock.now - start)
            if tickTimes.count > 2000 { tickTimes.removeFirst(tickTimes.count - 2000) }
        }
        ticks += 1
        let everySecond = ticks % Int(1 / Self.rate) == 0
        if everySecond { Workspace.showLinkMark(mark) }
        let chats = LinkSnapshot.chatsByID()
        for message in attention.look(chats, everything: false) { send(message) }
        let wantsAll = everySecond || session.snapshotDue
        let followed = Set(session.subs.keys)
        var changedFrom: [String: Int] = [:]
        for id in followed {
            guard let chat = chats[id] else { continue }
            if let from = chat.transcript.linkDirtyFrom { changedFrom[id] = from }
            chat.transcript.linkDirtyFrom = nil
        }
        let txDue = session.subs.contains { $0.value.fresh } || !changedFrom.isEmpty || !dirtyChats.intersection(followed).isEmpty
        guard wantsAll || !dirtyChats.isEmpty || txDue else { return }
        let windows = wantsAll ? LinkSnapshot.workspaces().map(LinkSnapshot.window) : nil
        let metaIds = wantsAll ? Set(chats.keys) : dirtyChats.intersection(chats.keys)
        let metas = metaIds.sorted().compactMap { chats[$0].map(LinkSnapshot.meta) }
        var tx: [TxSlice] = []
        for (id, sub) in session.subs {
            guard let chat = chats[id] else { continue }
            guard sub.fresh || changedFrom[id] != nil || dirtyChats.contains(id) else { continue }
            let slice = self.slice(chat, sub, from: changedFrom[id])
            session.subs[id]?.fresh = false
            session.subs[id]?.known = Set(slice.order)
            tx.append(slice)
        }
        session.snapshotDue = false
        dirtyChats = []
        let batch = LinkBatch(windows: windows, chats: metas, chatIds: wantsAll ? Set(chats.keys) : nil, tx: tx)
        for message in session.projector.apply(batch) { send(message) }
        cache = cache.filter { followed.contains($0.key) }
    }

    /// A followed transcript's window: its order, and its entries from the first changed one (all
    /// of them for a client that hasn't had it).
    private func slice(_ chat: Chat, _ sub: Session.Sub, from changed: Int?) -> TxSlice {
        let id = chat.id.uuidString
        let store = chat.transcript
        let epoch = "\(ObjectIdentifier(store).hashValue)"
        var made = cache[id].flatMap { $0.epoch == epoch ? $0.entries : nil } ?? [:]
        let entries = store.entries
        let lo = max(0, entries.count - sub.last)
        let window = entries[lo...]
        let order = window.map { $0.id.uuidString }
        let from = max(lo, changed ?? entries.count)
        var out: [LinkEntry] = []
        for (index, entry) in zip(window.indices, window) {
            let key = entry.id.uuidString
            let stale = index >= from || made[key] == nil
            if stale { made[key] = LinkSnapshot.entry(entry, folder: chat.folder) }
            if sub.fresh || stale || !sub.known.contains(key), let wire = made[key] { out.append(wire) }
        }
        cache[id] = (epoch, made)
        let turnIds = Set(window.compactMap(\.turn))
        let turns = turnIds.sorted().compactMap { store.linkTurn($0).map(LinkSnapshot.turn) }
        return TxSlice(chatId: id, epoch: epoch, order: order, entries: out, full: sub.fresh, turns: turns, hasEarlier: lo > 0)
    }

    // MARK: For tests and storylines

    /// A client is linked and proven.
    package var linked: Bool { session?.proven == true }
    /// The user chose one of the companion's commands in "/": told to the client, no reply.
    func command(_ id: String) {
        guard linked else { return }
        UILog.event("link-command", [:])
        send(.command(id: id))
    }
    /// The mark's recent lines.
    package var recent: [String] { mark.recent }
}

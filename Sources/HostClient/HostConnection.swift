import Foundation
import KoreCore
import LinkProtocol
import Observation
import src

/// A chat on the box that follows its transcript and state: the link's chat backend.
@MainActor
package protocol HostFollower: AnyObject {
    var chatId: String? { get }
    /// `tx.page`, `tx.delta` and `tx.reset` for its chat, its `tx.open`'s refusal, and the frame's bytes.
    func received(_ message: LinkMessage, raw: Data, seq: Int?)
    /// Its chat's state from a snapshot or delta; nil once the box closed it.
    func meta(_ meta: ChatMeta?)
    /// The link came up (true) or went (false).
    func linked(_ up: Bool)
}

/// One box over the link: the handshake, the box's state, the chats followed, commands and their
/// results, and the box's local copy. Asleep until a window on the box opens (`retain`), and
/// asleep again once the last one closes: no process, timer or socket.
///
/// While the box can't be reached, commands wait in order and go once it's back; a ping every 15 s
/// notices a link that died quietly (two without a word from the box), and it dials again, waiting
/// longer each time.
@MainActor @Observable
package final class HostConnection {
    package enum Phase: Equatable, Sendable {
        case idle, connecting, online, offline
        /// The box turned the client away (`bye` auth or version): no dialling again until asked.
        case refused(String)
    }

    package let alias: String
    package let grant: String
    package private(set) var phase = Phase.idle
    /// When the box last said anything, as of the last time it went quiet: what "offline" shows.
    package private(set) var lastHeard: Date?
    package private(set) var windows: [LinkWindow] = []
    package private(set) var folders: [BoxFolder] = []
    /// GitHub's CLI on the box is signed in, as the box last said; nil until it says.
    package private(set) var ghSignedIn: Bool?
    /// The CLIs' logins on the box, and GitHub's (made on first use).
    @ObservationIgnored package private(set) lazy var accounts = BoxAccounts(connection: self)
    @ObservationIgnored package private(set) var chats: [String: ChatMeta] = [:]
    @ObservationIgnored package private(set) var clis: [CLIState] = []
    @ObservationIgnored package private(set) var providers: [ProviderInfo] = []
    /// `welcome.host.kind`: "box" for kore-host.
    @ObservationIgnored package private(set) var hostKind: String?
    @ObservationIgnored package let cache: HostCache

    /// How often a ping goes, and how many may go unanswered.
    @ObservationIgnored package var pingEvery: Duration = .seconds(15)
    @ObservationIgnored package var missedLimit = 2
    /// Waits before each dial after the link went, the last repeating.
    @ObservationIgnored package var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30), .seconds(60)]
    /// A dial that hasn't had its welcome by then is given up.
    @ObservationIgnored package var handshakeLimit: Duration = .seconds(20)

    @ObservationIgnored private let makeTransport: @MainActor () -> any HostTransport
    @ObservationIgnored private var transport: (any HostTransport)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var redial: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var users = 0
    /// The box's snapshot came on this link: commands go straight out.
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var heard = false
    @ObservationIgnored private var heardAt: Date?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var outbox: [(id: String, payload: Data)] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var waiting: [String: CheckedContinuation<LinkMessage.Result, Never>] = [:]
    @ObservationIgnored private var folderAsks: [String: CheckedContinuation<[BoxFolder], Never>] = [:]
    @ObservationIgnored private var followers: [String: Weak] = [:]
    @ObservationIgnored private var wantRaw: Set<String> = []
    @ObservationIgnored private var raws: [String: Data] = [:]
    @ObservationIgnored private var early: [String: LinkMessage.Result] = [:]
    @ObservationIgnored private var saveQueued = false
    @ObservationIgnored private var snapshotWatchers: [String: @MainActor () -> Void] = [:]

    private struct Weak {
        weak var follower: (any HostFollower)?
    }

    /// The Mac's grant name on the box (`kore-host allow <name>`), unless set otherwise.
    package static let defaultGrant = "laptop"

    package init(
        alias: String, grant: String = defaultGrant, command: String = SSHTransport.defaultCommand, cache: HostCache? = nil,
        transport: (@MainActor () -> any HostTransport)? = nil
    ) {
        self.alias = alias
        self.grant = grant
        self.cache = cache ?? HostCache(alias: alias)
        makeTransport = transport ?? { SSHTransport(alias: alias, grant: grant, command: command) }
        if let state = self.cache.state() {
            windows = state.windows
            chats = Dictionary(state.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            clis = state.clis
            providers = state.providers
            folders = state.folders
            lastHeard = state.updated.map(Date.init(timeIntervalSince1970:))
            heardAt = lastHeard
        }
    }

    // MARK: Shared, per alias

    private static var open: [String: HostConnection] = [:]

    /// The alias's connection, made on first ask; the same one while any window uses it.
    package static func named(_ alias: String, grant: String = defaultGrant, command: String = SSHTransport.defaultCommand) -> HostConnection {
        if let connection = open[alias] { return connection }
        let connection = HostConnection(alias: alias, grant: grant, command: command)
        open[alias] = connection
        return connection
    }

    /// A window on the box opened: the link starts with the first.
    package func retain() {
        users += 1
        if users == 1 { dial() }
    }

    /// One closed: the link ends with the last, and nothing of it runs.
    package func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        stop()
        if Self.open[alias] === self { Self.open[alias] = nil }
    }

    package var isOnline: Bool { phase == .online && ready }

    /// Dials again now (a refused link, after the user fixed the grant).
    package func retry() {
        guard users > 0, transport == nil else { return }
        redial?.cancel()
        attempts = 0
        dial()
    }

    /// Runs `action` after each snapshot (each time the link comes up); nil stops it.
    package func onSnapshot(_ key: String, _ action: (@MainActor () -> Void)?) { snapshotWatchers[key] = action }

    // MARK: Following chats

    package func follow(_ follower: any HostFollower) {
        guard let id = follower.chatId else { return }
        followers[id] = Weak(follower: follower)
        if ready { transport?.send(HostWire.txOpen(chatId: id)) }
    }

    package func unfollow(_ follower: any HostFollower) {
        guard let id = follower.chatId, followers[id]?.follower === follower else { return }
        followers[id] = nil
        if ready { transport?.send(HostWire.txClose(chatId: id)) }
    }

    // MARK: Commands

    /// Sends a command (`payload` gets its id) and waits for its result: at once while linked,
    /// else when the link is back.
    package func command(_ payload: (String) -> Data) async -> LinkMessage.Result {
        serial += 1
        let id = "c\(serial)"
        let data = payload(id)
        if case .refused(let why) = phase { return LinkMessage.Result(id: id, ok: false, code: .unknown, message: why) }
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            if ready, let transport {
                inFlight.insert(id)
                transport.send(data)
            } else {
                outbox.append((id, data))
            }
        }
    }

    /// A command whose result's own bytes are wanted too (fields 1.4's types don't read).
    package func commandRaw(_ payload: (String) -> Data) async -> (LinkMessage.Result, Data?) {
        let id = "c\(serial + 1)"
        wantRaw.insert(id)
        let result = await command(payload)
        wantRaw.remove(id)
        return (result, raws.removeValue(forKey: result.id))
    }

    /// A later result for a command already answered (`<id>:done`, a sign-in's end): at once when
    /// it came already, else when it comes.
    package func later(_ id: String) async -> LinkMessage.Result {
        if let result = early.removeValue(forKey: id) { return result }
        return await withCheckedContinuation { waiting[id] = $0 }
    }

    /// The folders the box serves: asked again while linked, else as last known.
    package func listFolders() async -> [BoxFolder] {
        guard ready, let transport else { return folders }
        serial += 1
        let id = "f\(serial)"
        transport.send(HostWire.foldersList(id: id))
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.answerFolders(id, nil)
        }
        let listed = await withCheckedContinuation { folderAsks[id] = $0 }
        timeout.cancel()
        return listed
    }

    private func answerFolders(_ id: String, _ list: [BoxFolder]?) {
        guard let ask = folderAsks.removeValue(forKey: id) else { return }
        if let list {
            folders = list
            saveSoon()
        }
        ask.resume(returning: list ?? folders)
    }

    // MARK: The link

    private func dial() {
        guard users > 0, transport == nil else { return }
        redial = nil
        if phase != .offline { phase = .connecting }
        let transport = makeTransport()
        self.transport = transport
        ready = false
        do {
            try transport.start()
        } catch {
            self.transport = nil
            dropped("couldn't start: \(error.localizedDescription)")
            return
        }
        pump = Task { [weak self] in
            for await event in transport.events {
                guard let self, self.transport === transport else { return }
                switch event {
                case .frame(let data): self.take(data)
                case .closed(let reason): self.dropped(reason)
                }
            }
        }
        let limit = handshakeLimit
        pinger = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, !Task.isCancelled, self.transport === transport, !self.ready else { return }
            self.drop("no answer from the box")
        }
    }

    /// Closes the transport; its end comes back as `dropped`.
    private func drop(_ reason: String) {
        transport?.close()
        if transport != nil { dropped(reason) }
    }

    private func stop() {
        redial?.cancel()
        redial = nil
        let transport = transport
        if ready { transport?.send(HostWire.bye()) }
        teardown()
        transport?.close()
        phase = .idle
        // Whatever waits gets its answer: nothing will carry it now.
        for (id, _) in outbox { finish(id, ok: false, message: "\(alias) closed") }
        outbox = []
        for id in Array(waiting.keys) { finish(id, ok: false, message: "\(alias) closed") }
    }

    private func teardown() {
        pump?.cancel()
        pinger?.cancel()
        pump = nil
        pinger = nil
        transport = nil
        let was = ready
        ready = false
        if was { for follower in liveFollowers { follower.linked(false) } }
        for id in Array(folderAsks.keys) { answerFolders(id, nil) }
    }

    private func dropped(_ reason: String?) {
        guard transport != nil || pump != nil else { return }
        teardown()
        // Sent, never answered: the box may or may not have it.
        for id in inFlight { finish(id, ok: false, message: "The link to \(alias) dropped before it answered") }
        inFlight = []
        if case .refused = phase { return }
        if phase == .online || lastHeard == nil { lastHeard = heardAt ?? lastHeard }
        phase = .offline
        HostLog.note(alias, "dropped", reason)
        guard users > 0 else { return }
        let wait = backoff[min(attempts, backoff.count - 1)]
        attempts += 1
        redial = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.dial()
        }
    }

    private func take(_ data: Data) {
        heard = true
        heardAt = Date()
        let inbound: HostInbound
        do {
            inbound = try HostWire.decode(data)
        } catch {
            HostLog.note(alias, "unreadable frame", nil)
            return
        }
        switch inbound {
        case .folders(let id, let list):
            answerFolders(id, list)
        case .link(let message, let seq):
            handle(message, raw: data, seq: seq)
        }
    }

    private func handle(_ message: LinkMessage, raw: Data, seq: Int?) {
        switch message {
        case .challenge:
            transport?.send(HostWire.hello(build: HostLog.build))
        case .welcome(let welcome):
            hostKind = HostWire.hostKind(raw)
            providers = welcome.providers
        case .bye(let reason):
            switch reason {
            case .auth: refuse("\(alias) didn't accept this Mac's grant \"\(grant)\"")
            case .version: refuse("\(alias) runs a link this Kore can't read")
            default: drop("the box said \(reason.rawValue)")
            }
        case .snapshot(_, let windows, let chats, let extras):
            self.windows = windows
            let old = self.chats
            self.chats = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            if let clis = extras?.clis { self.clis = clis }
            becameReady()
            for (id, entry) in followers where self.chats[id] != nil || old[id] != nil {
                entry.follower?.meta(self.chats[id])
            }
            for watcher in snapshotWatchers.values { watcher() }
            saveSoon()
        case .delta(_, let windows, let chats, let removed, let extras):
            if let windows { self.windows = windows }
            if let clis = extras?.clis { self.clis = clis }
            for chat in chats ?? [] {
                self.chats[chat.id] = chat
                followers[chat.id]?.follower?.meta(chat)
            }
            for id in removed ?? [] {
                self.chats[id] = nil
                followers[id]?.follower?.meta(nil)
            }
            saveSoon()
        case .txPage(let chatId, _, _, _, _), .txReset(let chatId):
            followers[chatId]?.follower?.received(message, raw: raw, seq: seq)
        case .txDelta(let delta):
            followers[delta.chatId]?.follower?.received(message, raw: raw, seq: seq)
        case .result(let result):
            if result.id.hasPrefix("tx.open:") {
                followers[String(result.id.dropFirst("tx.open:".count))]?.follower?.received(message, raw: raw, seq: nil)
            } else if inFlight.remove(result.id) != nil || waiting[result.id] != nil {
                if wantRaw.remove(result.id) != nil { raws[result.id] = raw }
                waiting.removeValue(forKey: result.id)?.resume(returning: result)
            } else if result.id.hasSuffix(HostWire.doneSuffix) {
                // A sign-in's end, before anyone waits on it.
                early[result.id] = result
            }
        default:
            break
        }
        if let gh = HostWire.ghSignedIn(message, raw: raw), gh != ghSignedIn { ghSignedIn = gh }
    }

    /// The box's state is in: followed chats catch up, waiting commands go, pings begin.
    private func becameReady() {
        guard !ready else { return }
        ready = true
        phase = .online
        attempts = 0
        lastHeard = nil
        for follower in liveFollowers {
            if let id = follower.chatId { transport?.send(HostWire.txOpen(chatId: id)) }
            follower.linked(true)
        }
        let queued = outbox
        outbox = []
        for (id, payload) in queued {
            inFlight.insert(id)
            transport?.send(payload)
        }
        startPings()
    }

    private func startPings() {
        pinger?.cancel()
        let every = pingEvery, limit = missedLimit
        pinger = Task { [weak self] in
            var missed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let self, !Task.isCancelled, self.ready else { return }
                missed = self.heard ? 0 : missed + 1
                if missed >= limit {
                    self.drop("\(limit) pings went unanswered")
                    return
                }
                self.heard = false
                self.serial += 1
                self.transport?.send(HostWire.ping(id: "ping.\(self.serial)"))
            }
        }
    }

    private func refuse(_ why: String) {
        phase = .refused(why)
        let transport = transport
        teardown()
        transport?.close()
        for (id, _) in outbox { finish(id, ok: false, message: why) }
        outbox = []
        for id in Array(waiting.keys) { finish(id, ok: false, message: why) }
        inFlight = []
        HostLog.note(alias, "refused", why)
    }

    private func finish(_ id: String, ok: Bool, message: String) {
        waiting.removeValue(forKey: id)?.resume(returning: LinkMessage.Result(id: id, ok: ok, code: .unknown, message: message))
    }

    private var liveFollowers: [any HostFollower] {
        followers = followers.filter { $0.value.follower != nil }
        return followers.values.compactMap(\.follower)
    }

    /// The box's state goes to disk once for a burst of changes.
    private func saveSoon() {
        guard !saveQueued else { return }
        saveQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveQueued = false
            var state = HostCache.State()
            state.windows = self.windows
            state.chats = self.chats.values.sorted { $0.id < $1.id }
            state.clis = self.clis
            state.providers = self.providers
            state.folders = self.folders
            state.updated = self.heardAt?.timeIntervalSince1970
            self.cache.save(state)
        }
    }

    // MARK: Reading the state

    /// The chats the box has in a folder, in its tab order: its window's tabs (the window
    /// `folders.list` named for it).
    package func chats(in folder: String) -> [ChatMeta] {
        let window = folders.first { $0.path == folder }?.windowId
        let ids = windows.filter { $0.id == window || $0.path == folder }.flatMap { $0.tabs.compactMap(\.chatId) }
        return ids.compactMap { chats[$0] }
    }

    /// A CLI's models, as its pickers list them.
    package func models(_ provider: String) -> [ModelOption] {
        (clis.first { $0.provider == provider }?.models ?? []).map {
            ModelOption(id: $0.id, name: $0.name, resolved: $0.name, efforts: $0.efforts, supportsAutoMode: $0.auto, supportsFastMode: $0.fast)
        }
    }
}

/// HostClient's lines in `~/Library/Logs/Kore/hosts.log`: the alias and what the link did, and
/// SSH's own last line when it ended; never a message.
package enum HostLog {
    private static let log = KoreLog.named("hosts")

    package static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    package static func note(_ alias: String, _ what: String, _ detail: String?) {
        log.write(what, ["host": alias, "detail": detail])
    }
}

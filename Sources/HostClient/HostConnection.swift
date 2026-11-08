import Foundation
import KoreCore
import LinkProtocol
import Observation
import src

/// A chat on the box that follows its events and state: the link's chat backend.
@MainActor
package protocol HostFollower: AnyObject {
    var chatId: String? { get }
    /// Where its copy stands: what `chat.follow` asks for.
    var following: ChatFollow? { get }
    /// Its chat's events (1.5 `chat.events`).
    func streamed(_ events: ChatEvents)
    /// The box can't send them: the chat is gone, or the grant or the box can't stream them.
    func refused(_ message: String)
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
        /// The box turned the client away: no dialling again until asked.
        case refused(Refused)
    }

    /// Why the box turned this Mac away, as its `bye` said.
    package enum Refused: Equatable, Sendable {
        /// It doesn't know this Mac (`bye auth`).
        case auth
        /// It and this Kore don't speak the same link (`bye version`).
        case version
        /// Another Kore with this Mac's grant took over (`bye replaced`).
        case replaced

        /// The words a box's window and chats say for it.
        package func line(_ alias: String) -> String {
            switch self {
            case .auth: "\(alias) doesn't know this Mac"
            case .version: "\(alias) and this Kore don't match · update one"
            case .replaced: "Another Kore here holds \(alias)"
            }
        }
    }

    package let alias: String
    package let grant: String
    package private(set) var phase = Phase.idle
    /// When the box last said anything, as of the last time it went quiet: what "offline" shows.
    package private(set) var lastHeard: Date?
    package private(set) var windows: [LinkWindow] = []
    package private(set) var folders: [BoxFolder] = []
    /// Why the link last ended, in SSH's or the box's last words ("command not found").
    @ObservationIgnored package private(set) var lastReason: String?
    /// GitHub's CLI on the box is signed in, as the box last said; nil until it says.
    package private(set) var ghSignedIn: Bool?
    /// The box's kore-host is older than this Kore (`HostWire.older`), as its welcome said.
    @ObservationIgnored package private(set) var hostOlder = false
    /// The CLIs' logins on the box, and GitHub's (made on first use).
    @ObservationIgnored package private(set) lazy var accounts = BoxAccounts(connection: self)
    @ObservationIgnored package private(set) var chats: [String: ChatMeta] = [:]
    @ObservationIgnored package private(set) var clis: [CLIState] = []
    @ObservationIgnored package private(set) var providers: [ProviderInfo] = []
    /// The welcome's: what the box offers this grant (1.5's "stream" with full control), and the
    /// grant's control.
    @ObservationIgnored package private(set) var caps: [String] = []
    @ObservationIgnored package private(set) var control: LinkControlLevel?
    @ObservationIgnored package let cache: HostCache

    /// A link up this long counts as stable: the next drop dials again from the shortest wait.
    @ObservationIgnored package var stableAfter: Duration = .seconds(30)
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
    /// Commands' ids end with this run's own tag: a box keeps recent `chat.call` ids, so ids
    /// never repeat across runs.
    @ObservationIgnored private let tag = String(UUID().uuidString.prefix(8)).lowercased()
    /// Commands a dropped link sends again (forwarded calls: the box answers a repeat once).
    @ObservationIgnored private var resend: [String: Data] = [:]
    @ObservationIgnored private var outbox: [(id: String, payload: Data)] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var waiting: [String: CheckedContinuation<LinkMessage.Result, Never>] = [:]
    @ObservationIgnored private var folderAsks: [String: CheckedContinuation<[BoxFolder], Never>] = [:]
    @ObservationIgnored private var followers: [String: Weak] = [:]
    @ObservationIgnored private var wantRaw: Set<String> = []
    /// Forwarded calls waiting, and their answers as the box gave them (`ChatCallResult`).
    @ObservationIgnored private var calls: Set<String> = []
    @ObservationIgnored private var answers: [String: ChatCallResult] = [:]
    @ObservationIgnored private var uploadWaits: [String: CheckedContinuation<LinkMessage.Result, Never>] = [:]
    @ObservationIgnored private var raws: [String: Data] = [:]
    @ObservationIgnored private var early: [String: LinkMessage.Result] = [:]
    @ObservationIgnored private var saveQueued = false
    @ObservationIgnored private var snapshotWatchers: [String: @MainActor () -> Void] = [:]
    /// `sync.changed`'s readers, by the box folder they sync.
    @ObservationIgnored private var syncReaders: [String: @MainActor (Data) -> Void] = [:]

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
        // Sends a quit Kore didn't get to: they go once the box is back; their answers aren't
        // waited on (the chat shows them when the box does).
        for pending in self.cache.outbox() {
            outbox.append((pending.id, pending.payload))
            resend[pending.id] = pending.payload
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

    /// The alias's connection while a window holds it; nil otherwise (nothing is made).
    package static func live(_ alias: String) -> HostConnection? { open[alias] }

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

    /// Hands each `sync.changed` for a box folder to `read` (its frame's bytes); nil stops it.
    package func onSync(_ folder: String, _ read: (@MainActor (Data) -> Void)?) { syncReaders[folder] = read }

    // MARK: Following chats

    package func follow(_ follower: any HostFollower) {
        guard let id = follower.chatId else { return }
        followers[id] = Weak(follower: follower)
        if ready { askEvents(follower) }
    }

    package func unfollow(_ follower: any HostFollower) {
        guard let id = follower.chatId, followers[id]?.follower === follower else { return }
        followers[id] = nil
        if ready, streams { transport?.send(StreamWire.encode(ChatUnfollow(chatId: id))) }
    }

    /// The box streams chats to this grant (1.5, full control).
    package var streams: Bool { caps.contains("stream") }

    private func askEvents(_ follower: any HostFollower) {
        guard streams else {
            return follower.refused(control == .full ? "\(alias) needs an update to open its chats" : "\(alias) lets this Mac only watch: set it up again")
        }
        if let ask = follower.following { transport?.send(StreamWire.encode(ask)) }
    }

    // MARK: Commands

    /// Sends a command (`payload` gets its id) and waits for its result: at once while linked,
    /// else when the link is back.
    package func command(_ payload: (String) -> Data) async -> LinkMessage.Result {
        await command(payload, resending: false)
    }

    /// `resending`: a link that drops before the answer sends it again once it's back (a forwarded
    /// call, which the box runs once per id).
    private func command(_ payload: (String) -> Data, resending: Bool) async -> LinkMessage.Result {
        serial += 1
        let id = "c\(serial).\(tag)"
        let data = payload(id)
        if case .refused(let why) = phase { return LinkMessage.Result(id: id, ok: false, code: .unknown, message: why.line(alias)) }
        if resending {
            resend[id] = data
            keepOutbox()
        }
        defer {
            if resending {
                resend[id] = nil
                keepOutbox()
            }
        }
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
        await commandRaw(payload, resending: false)
    }

    private func commandRaw(_ payload: (String) -> Data, resending: Bool) async -> (LinkMessage.Result, Data?) {
        var asked = ""
        let result = await command({ id in
            asked = id
            wantRaw.insert(id)
            return payload(id)
        }, resending: resending)
        wantRaw.remove(asked)
        return (result, raws.removeValue(forKey: result.id))
    }

    /// One forwarded backend call on a chat (1.5 `chat.call`): its answer, typed, sent again after
    /// a drop.
    package func call(_ chatId: String, _ command: ChatCommand) async -> ChatCallResult {
        var asked = ""
        let result = await self.command({ id in
            asked = id
            calls.insert(id)
            return StreamWire.encode(ChatCall(id: id, chatId: chatId, command: command))
        }, resending: true)
        calls.remove(asked)
        return answers.removeValue(forKey: result.id) ?? ChatCallResult(id: result.id, ok: result.ok, code: result.code, message: result.message)
    }

    /// Uploads a file to the box (1.1's `blob.put.*`): its blob id, or why not.
    package func upload(_ data: Data, name: String, mime: String) async -> Result<String, HostRefusal> {
        guard ready, let transport else { return .failure(HostRefusal(message: "\(alias) can't be reached")) }
        serial += 1
        let uploadId = "u\(serial).\(tag)"
        transport.send(HostWire.encode(.blobPutBegin(uploadId: uploadId, name: name, mime: mime, size: data.count, sha256: HostWire.sha256(data))))
        var index = 0
        var offset = 0
        while offset < data.count {
            let piece = data[offset..<min(offset + LinkUploads.chunkMax, data.count)]
            transport.send(HostWire.encode(.blobPutChunk(uploadId: uploadId, index: index, data: piece.base64EncodedString())))
            index += 1
            offset += piece.count
        }
        transport.send(HostWire.encode(.blobPutEnd(uploadId: uploadId)))
        let result = await withCheckedContinuation { uploadWaits["blob.put:" + uploadId] = $0 }
        guard result.ok, let blob = result.blobId else { return .failure(HostRefusal(result, alias: alias)) }
        return .success(blob)
    }

    /// A later result for a command already answered (`<id>:done`, a sign-in's end): at once when
    /// it came already, else when it comes.
    package func later(_ id: String) async -> LinkMessage.Result {
        if let result = early.removeValue(forKey: id) { return result }
        return await withCheckedContinuation { waiting[id] = $0 }
    }

    /// Adds a folder already on the box (a path typed on the Mac): the folder, or why not. A path
    /// starting with `~` takes the box's home, as its windows show it.
    package func addFolder(_ typed: String) async -> Result<BoxFolder, HostRefusal> {
        let path = absolute(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        let (result, raw) = await commandRaw { HostWire.addFolder(id: $0, path: path) }
        guard result.ok, let list = HostWire.folders(raw) else {
            return .failure(HostRefusal(message: result.code == .goneFolder ? "Not found on \(alias)" : result.message ?? "\(alias) refused it"))
        }
        folders = list
        saveSoon()
        let wanted = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let folder = list.first(where: { $0.path == wanted }) ?? list.last else { return .failure(HostRefusal(message: "Not found on \(alias)")) }
        return .success(folder)
    }

    /// `~/x` as the box's absolute path, from a folder whose window shows it under `~`.
    private func absolute(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        for folder in folders {
            guard let window = windows.first(where: { $0.id == folder.windowId }), window.path.hasPrefix("~"),
                folder.path.hasSuffix(String(window.path.dropFirst()))
            else { continue }
            let home = String(folder.path.dropLast(window.path.count - 1))
            return home + path.dropFirst()
        }
        return path
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
            self.drop("no answer")
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
        endUploads("\(alias) closed")
    }

    private func endUploads(_ why: String) {
        for (id, wait) in uploadWaits { wait.resume(returning: LinkMessage.Result(id: id, ok: false, code: .unknown, message: why)) }
        uploadWaits = [:]
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
        // Sent, never answered: the box may or may not have it. A forwarded call goes again (the box
        // runs it once); anything else says so.
        for id in inFlight.sorted() {
            if let data = resend[id] { outbox.append((id, data)) } else { finish(id, ok: false, message: "Lost \(alias) before it answered") }
        }
        inFlight = []
        endUploads("Lost \(alias)")
        // A sign-in's end won't come over a link that's gone.
        for id in waiting.keys where id.hasSuffix(HostWire.doneSuffix) { finish(id, ok: false, message: "Lost \(alias) before it answered") }
        if case .refused = phase { return }
        if phase == .online || lastHeard == nil { lastHeard = heardAt ?? lastHeard }
        phase = .offline
        lastReason = reason
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
        case .events(let events):
            followers[events.chatId]?.follower?.streamed(events)
        case .folders(let id, let list):
            // `folders.list`'s own answer; any other result with folders (`folder.add`) is a result.
            if folderAsks[id] != nil {
                answerFolders(id, list)
            } else if let message = try? LinkMessage.decode(data) {
                handle(message, raw: data)
            }
        case .link(let message):
            handle(message, raw: data)
        }
    }

    private func handle(_ message: LinkMessage, raw: Data) {
        switch message {
        case .challenge:
            transport?.send(HostWire.hello(build: HostLog.build))
        case .welcome(let welcome):
            hostOlder = HostWire.older(welcome)
            providers = welcome.providers
            caps = welcome.caps
            control = welcome.policy.control
        case .bye(let reason):
            switch reason {
            case .auth: refuse(.auth)
            case .version: refuse(.version)
            case .replaced: refuse(.replaced)
            default: drop("\(alias) said \(reason.rawValue)")
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
            if let clis = extras?.clis, clis != self.clis {
                self.clis = clis
                // The box's model lists changed: open chats' pickers take them.
                for (id, entry) in followers where chats?.contains(where: { $0.id == id }) != true {
                    entry.follower?.meta(self.chats[id])
                }
            }
            for chat in chats ?? [] {
                self.chats[chat.id] = chat
                followers[chat.id]?.follower?.meta(chat)
            }
            for id in removed ?? [] {
                self.chats[id] = nil
                followers[id]?.follower?.meta(nil)
            }
            saveSoon()
        case .result(let result):
            if result.id.hasPrefix("chat.follow:") {
                followers[String(result.id.dropFirst("chat.follow:".count))]?.follower?.refused(result.message ?? "This chat isn't on \(alias) any more")
            } else if let wait = uploadWaits.removeValue(forKey: result.id) {
                wait.resume(returning: result)
            } else if inFlight.remove(result.id) != nil || waiting[result.id] != nil {
                if wantRaw.remove(result.id) != nil { raws[result.id] = raw }
                if calls.contains(result.id) { answers[result.id] = try? JSONDecoder().decode(ChatCallResult.self, from: raw) }
                waiting.removeValue(forKey: result.id)?.resume(returning: result)
            } else if result.id.hasSuffix(HostWire.doneSuffix) {
                // A sign-in's end, before anyone waits on it.
                early[result.id] = result
            }
        case .unknown(let type) where type == HostWire.syncChanged:
            if let folder = HostWire.syncFolder(raw) { syncReaders[folder]?(raw) }
        default:
            break
        }
        if let gh = HostWire.ghSignedIn(message, raw: raw), gh != ghSignedIn { ghSignedIn = gh }
    }

    /// The box's state is in: followed chats catch up, waiting commands go. Liveness is SSH's own
    /// (`ServerAliveInterval`), so nothing wakes the box to ask.
    private func becameReady() {
        guard !ready else { return }
        ready = true
        phase = .online
        lastHeard = nil
        for follower in liveFollowers {
            askEvents(follower)
            follower.linked(true)
        }
        let queued = outbox
        outbox = []
        for (id, payload) in queued {
            inFlight.insert(id)
            transport?.send(payload)
        }
        // Waits reset only once the link has stayed up a while: one that drops at once backs off.
        pinger?.cancel()
        let stable = stableAfter
        pinger = Task { [weak self] in
            try? await Task.sleep(for: stable)
            guard let self, !Task.isCancelled, self.ready else { return }
            self.attempts = 0
        }
    }

    /// Calls that go again after a drop are kept on disk, so a quit Kore sends them when it's back
    /// (the box runs each id once).
    private func keepOutbox() {
        let kept = resend.sorted { $0.key < $1.key }.map { HostCache.Pending(id: $0.key, payload: $0.value) }
        cache.saveOutbox(kept)
    }

    private func refuse(_ reason: Refused) {
        phase = .refused(reason)
        let why = reason.line(alias)
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

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
    /// The box closed the last link because this Mac's hello came too late.
    @ObservationIgnored package private(set) var lateHello = false
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
    /// 1.10: the last move command's bytes on the link, both ways (a move's cost).
    @ObservationIgnored package var lastMoveBytes = 0
    @ObservationIgnored package private(set) var control: LinkControlLevel?
    @ObservationIgnored package let cache: HostCache
    /// The CLIs whose login its chats' usage asked for (`LinkChatBackend`): once each.
    @ObservationIgnored package var loginsAsked: Set<String> = []

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
    /// Of those, the messages kept on disk across a quit (only sends: a Stop, a compaction or a
    /// rollback from before a quit never runs after it), with when and for which chat.
    @ObservationIgnored private var kept: [String: (at: Date, chatId: String)] = [:]
    /// Messages dropped for waiting too long, by chat: said in the chat when it follows.
    @ObservationIgnored private var expired: [String: Int] = [:]
    @ObservationIgnored private var outbox: [(id: String, payload: Data)] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var waiting: [String: CheckedContinuation<LinkMessage.Result, Never>] = [:]
    @ObservationIgnored private var folderAsks: [String: CheckedContinuation<[BoxFolder], Never>] = [:]
    @ObservationIgnored private var historyAsks: [String: CheckedContinuation<[HistorySession], Never>] = [:]
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
    /// Told the ids of chats whose meta came (a snapshot's every chat, a delta's), by key.
    @ObservationIgnored private var metaWatchers: [String: @MainActor ([String]) -> Void] = [:]
    /// Told when the box's windows or chats changed (a snapshot, a delta that names either), by key.
    @ObservationIgnored private var tabWatchers: [String: @MainActor () -> Void] = [:]
    /// Box windows' open explorer folders (1.8 `fs.watch`), by window, and who hears their changes.
    @ObservationIgnored package var fileWatchers: [String: (folders: Set<String>, changed: (@MainActor (BoxChange) -> Void)?)] = [:]
    /// Running searches' pages (1.8 `fs.hits`), by command id.
    @ObservationIgnored var fileHits: [String: @MainActor ([FileHit]) -> Void] = [:]
    /// `sync.changed`'s readers, by the box folder they sync.
    @ObservationIgnored private var syncReaders: [String: @MainActor (Data) -> Void] = [:]
    /// 1.8's pushes' readers (`BoxStreams.key`): a terminal's, a git root's.
    @ObservationIgnored var boxReaders: [String: @MainActor (Data) -> Void] = [:]

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
        let now = Date()
        for pending in self.cache.outbox() {
            guard let at = pending.at, now.timeIntervalSince(at) < HostCache.sendLifetime else {
                if let chat = pending.chatId { expired[chat, default: 0] += 1 }
                HostLog.note(alias, "send expired", pending.id)
                continue
            }
            outbox.append((pending.id, pending.payload))
            resend[pending.id] = pending.payload
            if let chat = pending.chatId { kept[pending.id] = (at, chat) }
        }
        if !expired.isEmpty { keepOutbox() }
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

    /// Kore is quitting: each linked box is told goodbye (its shells end with it, as a Mac's do)
    /// and the words are written before Kore goes. SSH carries them on after.
    package static func quitAll() {
        for connection in open.values {
            guard connection.ready, let transport = connection.transport else { continue }
            transport.send(HostWire.bye())
            transport.drain(timeout: 0.5)
        }
    }

    /// The alias's connection while a window holds it; nil otherwise (nothing is made).
    package static func live(_ alias: String) -> HostConnection? { open[alias] }

    /// Makes `connection` its alias's, as `named` would have made it: a test's, over a transport
    /// and a copy of its own.
    package static func adopt(_ connection: HostConnection) { open[connection.alias] = connection }

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
    /// Watches chats' metas as they come (1.10: a moved chat's replica, followed or not).
    package func onChatMeta(_ key: String, _ action: (@MainActor ([String]) -> Void)?) { metaWatchers[key] = action }

    /// Runs `action` each time the box's windows or chats change: a snapshot, or a delta naming
    /// either (a chat opened on the box, the phone, another Mac). Nil stops it.
    package func onTabs(_ key: String, _ action: (@MainActor () -> Void)?) { tabWatchers[key] = action }

    package func onSync(_ folder: String, _ read: (@MainActor (Data) -> Void)?) { syncReaders[folder] = read }

    // MARK: Following chats

    package func follow(_ follower: any HostFollower) {
        guard let id = follower.chatId else { return }
        followers[id] = Weak(follower: follower)
        if let count = expired.removeValue(forKey: id) {
            follower.refused(count == 1 ? "A message from before Kore quit waited over a day and wasn't sent" : "\(count) messages from before Kore quit waited over a day and weren't sent")
        }
        if ready { askEvents(follower) }
    }

    package func unfollow(_ follower: any HostFollower) {
        guard let id = follower.chatId, followers[id]?.follower === follower else { return }
        followers[id] = nil
        if ready, streams { transport?.send(StreamWire.encode(ChatUnfollow(chatId: id))) }
    }

    /// The box streams chats to this grant (1.5, full control).
    package var streams: Bool { caps.contains("stream") }

    /// Sends a message that gets no answer (a key, a size) while linked; false, and nothing
    /// sent, while not: it isn't kept for later.
    @discardableResult
    package func post(_ payload: Data) -> Bool {
        guard ready, let transport else { return false }
        transport.send(payload)
        return true
    }

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
    private func command(_ payload: (String) -> Data, resending: Bool, keeping chatId: String? = nil) async -> LinkMessage.Result {
        serial += 1
        let id = "c\(serial).\(tag)"
        let data = payload(id)
        if case .refused(let why) = phase { return LinkMessage.Result(id: id, ok: false, code: .unknown, message: why.line(alias)) }
        if resending {
            resend[id] = data
            if let chatId { kept[id] = (Date(), chatId) }
            keepOutbox()
        }
        defer { answered(id) }
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
    /// a drop. A message carries the chat's Arsenal tier and any note owed (1.6).
    package func call(_ chatId: String, _ command: ChatCommand, arsenal: String? = nil, note: String? = nil) async -> ChatCallResult {
        var asked = ""
        let result = await self.command({ id in
            asked = id
            calls.insert(id)
            return StreamWire.encode(ChatCall(id: id, chatId: chatId, command: command, arsenal: arsenal, note: note))
        }, resending: true, keeping: Self.keeps(command) ? chatId : nil)
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

    /// A folder's closed chats on the box, newest closed first, to reopen; from 1.9 also the past
    /// sessions its CLIs keep for the folder, and with `archived` the archived ones only. Empty
    /// while it can't be reached. (Its first page: 50, which a History popup shows.)
    package func closedChats(windowId: String, archived: Bool = false) async -> [HistorySession] {
        guard ready, let transport else { return [] }
        serial += 1
        let id = "h\(serial).\(tag)"
        transport.send(HostWire.encode(.historyList(id: id, windowId: windowId, query: nil, archived: archived, offset: 0)))
        let timeout = Task { [weak self] in
            // Codex lists its sessions through its app-server on the box: a moment longer.
            try? await Task.sleep(for: .seconds(20))
            self?.historyAsks.removeValue(forKey: id)?.resume(returning: [])
        }
        let listed = await withCheckedContinuation { historyAsks[id] = $0 }
        timeout.cancel()
        return listed
    }

    /// The box keeps a folder's history itself (1.9): opened, renamed and archived from here.
    package var keepsHistory: Bool { caps.contains("history") }

    /// `history.open`, `history.rename` or `history.archive` on the box: the result, or why not.
    package func history(_ kind: ControlKind, _ args: ControlArgs) async -> Result<LinkMessage.Result, HostRefusal> {
        let result = await command { HostWire.command(id: $0, .control(kind, args)) }
        return result.ok ? .success(result) : .failure(HostRefusal(result, alias: alias))
    }

    /// A closed chat back among the box's chats: its id, or why not.
    package func reopen(_ chatId: String) async -> Result<String, HostRefusal> {
        let result = await command { HostWire.command(id: $0, .control(.tabReopen, ControlArgs(sourceId: chatId))) }
        guard result.ok, let id = result.chatId else { return .failure(HostRefusal(result, alias: alias)) }
        return .success(id)
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
        for (_, ask) in historyAsks { ask.resume(returning: []) }
        historyAsks = [:]
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
        case .box(let type, let data):
            if let key = BoxStreams.key(type, data) { boxReaders[key]?(data) }
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
            // The box's own wait for this Mac's hello ran out (a Mac that slept mid-handshake): it
            // dials again.
            case .slow:
                lateHello = true
                drop("\(alias) waited too long for this Mac")
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
            for watcher in metaWatchers.values { watcher(Array(self.chats.keys)) }
            for watcher in tabWatchers.values { watcher() }
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
            if let chats, !chats.isEmpty { for watcher in metaWatchers.values { watcher(chats.map(\.id)) } }
            if windows != nil || chats?.isEmpty == false { for watcher in tabWatchers.values { watcher() } }
            saveSoon()
        case .historyPage(let id, _, let sessions, _):
            historyAsks.removeValue(forKey: id)?.resume(returning: sessions)
        case .result(let result):
            if result.id.hasPrefix("chat.follow:") {
                followers[String(result.id.dropFirst("chat.follow:".count))]?.follower?.refused(result.message ?? "This chat isn't on \(alias) any more")
            } else if let wait = uploadWaits.removeValue(forKey: result.id) {
                wait.resume(returning: result)
            } else if resend[result.id] != nil, waiting[result.id] == nil {
                // A send kept from before a quit, answered now: done with.
                inFlight.remove(result.id)
                answered(result.id)
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
        case .unknown(let type) where type == BoxToolCall.type:
            toolCall(raw)
        case .unknown(let type) where type == FilesChanged.type:
            filesChanged(raw)
        case .unknown(let type) where type == FilesHits.type:
            filesHits(raw)
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
        lateHello = false
        for follower in liveFollowers {
            askEvents(follower)
            follower.linked(true)
        }
        // A new link watches nothing yet: the windows' open folders again, and they list them
        // again (what changed meanwhile).
        if !fileWatchers.isEmpty {
            Task { [weak self] in
                await self?.sendWatches()
                for watcher in self?.fileWatchers.values.map({ $0 }) ?? [] { watcher.changed?(BoxChange(folders: watcher.folders)) }
            }
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
    /// A forwarded call is done with (answered here, or by the box's answer cache): it isn't sent
    /// again, now or after a quit.
    private func answered(_ id: String) {
        guard resend.removeValue(forKey: id) != nil else { return }
        let wasKept = kept.removeValue(forKey: id) != nil
        if wasKept { keepOutbox() }
    }

    /// Only a message is kept across a quit.
    private static func keeps(_ command: ChatCommand) -> Bool {
        if case .send = command { return true }
        return false
    }

    private func keepOutbox() {
        let kept = self.kept.compactMap { id, entry in
            resend[id].map { HostCache.Pending(id: id, payload: $0, at: entry.at, chatId: entry.chatId) }
        }.sorted { $0.id < $1.id }
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

    // MARK: Arsenal on the box (1.6)

    /// Answers a box chat's tool calls (`agent.call`): Kore's agent channel, which decides each by
    /// that chat's tier here. Unset, every call is refused.
    package static var toolCalls: (@MainActor (HostConnection, BoxToolCall) async -> BoxToolResult)?

    /// Only a full grant's link carries calls; each is answered on the link it came on, if that
    /// link is still up.
    private func toolCall(_ raw: Data) {
        guard control == .full, let call = try? JSONDecoder().decode(BoxToolCall.self, from: raw) else { return }
        let link = transport
        Task { [weak self] in
            guard let self else { return }
            var result = await Self.toolCalls?(self, call) ?? BoxToolResult(id: call.id, ok: false, code: "denied", text: "Kore's agent control is off.")
            result.id = call.id
            guard let link, self.transport === link, self.ready else { return }
            link.send(BoxTools.encode(result))
        }
    }

    // MARK: Reading the state

    /// A served folder's window on the box: as `folders.list` named it, else by its path (a window
    /// opened before the box listed its folders here, or with this Mac's copy gone).
    package func windowId(of folder: String) -> String {
        folders.first { $0.path == folder }?.windowId ?? BoxFolder.windowId(folder)
    }

    /// The chats the box has in a folder, in its tab order: its window's tabs.
    package func chats(in folder: String) -> [ChatMeta] {
        let window = windowId(of: folder)
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

import Foundation
import LinkProtocol
import src

/// One client on the box's socket: the challenge, a hello proven with its grant's secret, then
/// the snapshot, followed transcripts and commands. Nothing of it runs between messages.
@MainActor
final class LinkClient {
    private let socket: HostSocket
    unowned let host: HostDaemon
    private let nonce = LinkProof.random(32)
    private(set) var grant: Grant?
    private(set) var proven = false
    private var rev = 0
    /// Followed chats: the window (entries from the end) and the transcript's revision.
    private var following: [String: (last: Int, txRev: Int)] = [:]
    private var helloWait: DispatchWorkItem?
    /// Chats whose events this full grant follows (link 1.5), and its uploads.
    private var streaming: Set<String> = []
    private var uploads = LinkUploads()
    /// Catch-ups still to send, a part at a time as the socket drains (a log can be megabytes).
    private var catchUps: [CatchUp] = []

    private struct CatchUp {
        var chatId: String
        var log: String
        var reset: Bool
        var items: ArraySlice<StreamItem>
        /// Its start is still being read off the main thread: live items wait behind it.
        var loading = false
    }
    /// The explorer's open folders, watched for this client (`fs.watch`).
    private var watches: FolderWatches?
    /// The search running for this client, stopped by the next or by the link ending.
    private var searching: SearchRun?
    /// `sync.watch`es, by folder; they end with the link.
    private var syncs: [String: SyncWatch] = [:]

    init(socket: HostSocket, host: HostDaemon) {
        self.socket = socket
        self.host = host
    }

    func begin() {
        socket.start(max: LinkFrame.inboundMax, frame: { [weak self] data in self?.received(data) }, ended: { [weak self] in self?.gone() })
        socket.drained = { [weak self] in
            self?.sendCatchUps()
            self?.sendSyncPieces()
            if let self { self.host.terminals.drained(self) }
        }
        send(.challenge(nonce: nonce))
        // A client that hasn't proven itself in 10 s is closed: the one wait while it connects.
        let wait = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard self?.proven == false else { return }
                HostJournal.note("refused", ["reason": "no hello in 10 s"])
                self?.end(.slow)
            }
        }
        helloWait = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: wait)
    }

    func send(_ message: LinkMessage) { socket.send(message) }

    func end(_ reason: LinkMessage.ByeReason) {
        helloWait?.cancel()
        send(.bye(reason))
        socket.close()
        gone()
    }

    private func gone() {
        helloWait?.cancel()
        for watch in syncs.values { watch.stop() }
        syncs = [:]
        watches?.stop()
        watches = nil
        searching?.cancel()
        searching = nil
        syncPieces = []
        boxAsksEnded()
        host.ended(self)
        for chatId in streaming { host.unfollowed(chatId) }
        streaming = []
        for chatId in following.keys { host.txFollowersChanged(chatId) }
    }

    private func uploadFailed(_ uploadId: String, _ failure: LinkUploads.Failure) {
        send(.result(.init(id: "blob.put:" + uploadId, ok: false, code: failure.code, message: failure.message)))
    }

    func follows(_ chatId: String) -> Bool { following[chatId] != nil }

    func streams(_ chatId: String) -> Bool { streaming.contains(chatId) }

    func sendRaw(_ data: Data) { socket.send(data) }

    /// Bytes waiting for this client: a terminal reads on only below `HostSocket.lowWater`.
    var backlog: Int { socket.backlog }

    /// A chat's items, in frames; this client's own rows are marked `by` it. Live items go at once
    /// (a part at most); a catch-up goes a part at a time, each once the socket has drained, and
    /// live items for that chat wait behind it.
    func events(_ hc: HostChat, _ items: [StreamItem], reset: Bool) {
        guard reset || !items.isEmpty else { return }
        if reset { catchUps.removeAll { $0.chatId == hc.id && !$0.loading } }
        if let at = catchUps.firstIndex(where: { $0.chatId == hc.id }) {
            catchUps[at].items += items
            if reset, !catchUps[at].loading { catchUps[at].reset = true }
        } else {
            catchUps.append(CatchUp(chatId: hc.id, log: hc.stream.id, reset: reset, items: items[...]))
        }
        sendCatchUps()
    }

    /// A follow's catch-up is being read: live items for the chat wait until it's in.
    func catchUpStarts(_ chatId: String, log: String) {
        catchUps.removeAll { $0.chatId == chatId }
        catchUps.append(CatchUp(chatId: chatId, log: log, reset: false, items: [], loading: true))
    }

    /// The catch-up read: it goes first, then what came live meanwhile that it doesn't hold.
    func catchUpRead(_ hc: HostChat, _ items: [StreamItem], reset: Bool) {
        guard let at = catchUps.firstIndex(where: { $0.chatId == hc.id && $0.loading }) else { return events(hc, items, reset: reset) }
        let last = items.last?.s ?? Int.min
        catchUps[at].items = items[...] + catchUps[at].items.filter { $0.s > last }
        catchUps[at].reset = reset
        catchUps[at].log = hc.stream.id
        catchUps[at].loading = false
        sendCatchUps()
    }

    /// Sends waiting catch-ups a frame at a time, while the socket's queue is short: each frame
    /// filled to `StreamWire.frameBudget` by its items' real sizes.
    private func sendCatchUps() {
        while let at = catchUps.firstIndex(where: { !$0.loading }), socket.backlog < HostSocket.lowWater {
            var next = catchUps.remove(at: at)
            var part: [Data] = []
            var size = 0
            while let item = next.items.first {
                let data = StreamWire.encoded(item)
                if !part.isEmpty, size + data.count > StreamWire.frameBudget { break }
                part.append(data)
                size += data.count + 1
                next.items = next.items.dropFirst()
            }
            socket.send(StreamWire.frame(chatId: next.chatId, log: next.log, reset: next.reset, encoded: part))
            if !next.items.isEmpty {
                next.reset = false
                catchUps.insert(next, at: at)
            }
        }
    }

    /// The grant as its file says now: a revoked or changed one ends the connection, a lowered one
    /// takes effect at once.
    func current() -> Grant? {
        guard let grant else { return nil }
        guard let now = GrantStore(host.paths.grants).current(grant.name, secret: grant.secret) else {
            HostJournal.note("revoked", ["grant": grant.name])
            end(.auth)
            return nil
        }
        self.grant = now
        return now
    }

    /// 1.5's messages, read by their type: full grants only.
    private func stream(_ type: String, _ data: Data) {
        guard let grant = current() else { return }
        guard grant.control == .full else {
            if type == "chat.call" {
                sendRaw(StreamWire.encode(ChatCallResult(id: "", ok: false, code: .deniedControl, message: "Driving a chat needs a grant with full control.")))
            }
            return
        }
        switch type {
        case "chat.follow":
            guard let request = try? JSONDecoder().decode(ChatFollow.self, from: data) else { return }
            streaming.insert(request.chatId)
            host.follow(self, request)
        case "chat.unfollow":
            guard let request = try? JSONDecoder().decode(ChatUnfollow.self, from: data) else { return }
            streaming.remove(request.chatId)
            host.unfollowed(request.chatId)
        case "chat.call":
            host.call(data, from: self)
        case BoxToolResult.type:
            host.toolAnswered(data, from: self)
        default:
            break
        }
    }

    // MARK: In

    private func received(_ data: Data) {
        guard let message = try? LinkMessage.decode(data) else { return end(.invalid) }
        guard proven else { return hello(message) }
        switch message {
        case .bye:
            host.terminals.closeAll(of: self)
            socket.close()
            gone()
        case .txOpen(let chatId, let last):
            guard let hc = host.chat(chatId) else {
                return send(.result(.init(id: "tx.open:" + chatId, ok: false, code: .goneChat, message: "No such chat on this box.")))
            }
            following[chatId] = (min(max(last ?? 60, 1), 2000), 0)
            hc.txFollowed = true
            page(hc, last: nil)
        case .txMore(let chatId, let count):
            guard let hc = host.chat(chatId), let follow = following[chatId] else { return }
            following[chatId]?.last = min(follow.last + max(count, 0), 2000)
            page(hc, last: nil)
        case .txClose(let chatId):
            following[chatId] = nil
            host.txFollowersChanged(chatId)
        case .entryMore(let id, let chatId, let entryId, let field, let offset):
            entryMore(id: id, chatId: chatId, entryId: entryId, field: field, offset: offset)
        case .cardMore(let id, let chatId, let cardId, let offset):
            let text = host.chat(chatId)?.chat?.approvals.pending.first { $0.id == cardId }.flatMap(HostMeta.fullContent) ?? ""
            let piece = LinkProjection.piece(text, from: offset)
            send(.cardChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
        case .unknown(let type) where BoxAsk.types.contains(type):
            boxAsk(type, data)
        case .unknown(let type):
            stream(type, data)
        case .blobPutBegin(let uploadId, let name, let mime, let size, let sha256):
            guard current()?.control == .full else { return uploadFailed(uploadId, .init(.deniedControl, "Uploads need a grant with full control.")) }
            if let failure = uploads.begin(uploadId, name: name, mime: mime, size: size, sha256: sha256) { uploadFailed(uploadId, failure) }
        case .blobPutChunk(let uploadId, let index, let data):
            if let failure = uploads.chunk(uploadId, index: index, base64: data) { uploadFailed(uploadId, failure) }
        case .blobPutEnd(let uploadId):
            switch uploads.end(uploadId) {
            case .failure(let failure): uploadFailed(uploadId, failure)
            case .success(let file):
                guard let blob = host.keep(file) else { return uploadFailed(uploadId, .init(.busy, "The box couldn't keep the file.")) }
                send(.result(.init(id: "blob.put:" + uploadId, ok: true, blobId: blob)))
            }
        case .historyList(let id, let windowId, let query, let archived, let offset):
            // A folder's closed chats and its CLIs' past sessions (1.9: act and full grants).
            guard let control = current()?.control, control != .watch else {
                return send(.result(.init(id: "history.list:" + id, ok: false, code: .deniedControl, message: "This grant only watches.")))
            }
            Task { [weak self] in
                guard let self else { return }
                let all = await host.history(windowId: windowId, query: query, archived: archived)
                let page = Array(all.dropFirst(max(offset, 0)).prefix(50))
                send(.historyPage(id: id, windowId: windowId, sessions: page, more: all.count > max(offset, 0) + page.count))
            }
        case .cmd(let id, .control(let kind, let args)) where kind == .syncWatch || kind == .syncUnwatch:
            guard current() != nil else { return }
            send(.result(sync(kind, folder: args.folder, id: id)))
            if kind == .syncWatch, let folder = args.folder.map(HostDaemon.standard) { syncs[folder]?.start() }
        case .cmd(let id, .control(let kind, let args)) where kind.onFiles:
            files(kind, args, id: id)
        case .cmd(let id, let command):
            guard let grant = current() else { return }
            let result = host.apply(command, id: id, control: grant.control) { [weak self] result in self?.send(.result(result)) }
            if let result { send(.result(result)) }
        default:
            break
        }
    }

    private func hello(_ message: LinkMessage) {
        guard case .hello(let proto, _, let proof, _, let name) = message else { return end(.invalid) }
        guard proto.major == LinkProto.major else {
            HostJournal.note("refused", ["grant": name, "reason": "link \(proto.major).\(proto.minor)"])
            return end(.version)
        }
        guard let name, let grant = GrantStore(host.paths.grants).load(name), let secret = Data(base64Encoded: grant.secret),
            LinkProof.check(proof, secret: secret, nonce: nonce)
        else {
            HostJournal.note("refused", ["grant": name, "reason": "auth"])
            return end(.auth)
        }
        // The newest proven connection of a grant wins: the older one (a link that died while the
        // Mac slept) is told it was replaced.
        host.replace(self, grant: grant)
        helloWait?.cancel()
        self.grant = grant
        proven = true
        HostJournal.note("connect", ["grant": grant.name, "control": grant.control.rawValue])
        send(.welcome(host.welcome(control: grant.control)))
        rev += 1
        let full = grant.control == .full
        let clis = full && !host.clis.isEmpty ? host.clis : nil
        send(.snapshot(rev: rev, windows: host.windows, chats: host.chats.map { HostMeta.meta($0, raise: full) }, extras: LinkExtras(clis: clis, ghSignedIn: host.ghSignedIn)))
        send(.attnState(aid: 0, open: [], recent: []))
    }

    // MARK: Files (1.7)

    /// `fs.list`, `fs.read`, `fs.mkdir`: full grants only, each checked by the box's rules, then
    /// done off the main thread; the answer is a `FilesResult`.
    private func files(_ kind: ControlKind, _ args: ControlArgs, id: String) {
        guard let control = current()?.control else { return }
        if case .deny(let code, let message) = LinkPolicy.checkBox(kind, args, nil, control: control == .full ? .full : .standard) {
            return sendRaw(StreamWire.encode(FilesResult.refused(id, code, message)))
        }
        let home = HostPaths.home().path
        let files = HostFiles(home: home, served: host.config.folders)
        if kind == .fsWatch { return sendRaw(StreamWire.encode(watch(args.folders ?? [], files: files, id: id))) }
        // An upload's bytes, written in place (`fs.write` with `blob`).
        let upload: URL? = kind == .fsWrite ? args.blob.flatMap { host.blobs[$0] } : nil
        if kind == .fsWrite, args.blob != nil, upload == nil {
            return sendRaw(StreamWire.encode(FilesResult.refused(id, .goneBlob, "That upload isn't on the box any more.")))
        }
        let trash = HostFiles.Trash.standard(home: home)
        // A new search stops the one before it; its pages go as they're found.
        let run = SearchRun { [weak self] hits in
            let page = StreamWire.encode(FilesHits(id: id, hits: hits))
            Task { @MainActor in self?.sendRaw(page) }
        }
        if kind == .fsSearch {
            searching?.cancel()
            searching = run
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> FilesResult in
                switch kind {
                case .fsList: return files.list(id: id, path: args.path, hidden: args.hidden == true)
                case .fsRead: return files.read(id: id, path: args.path ?? "", max: args.max, base: args.base)
                case .fsMkdir: return files.mkdir(id: id, path: args.path ?? "")
                case .fsWrite:
                    let bytes: Data? =
                        if let upload { try? Data(contentsOf: upload) } else if let text = args.text { Data(text.utf8) } else { args.data.flatMap { Data(base64Encoded: $0) } }
                    guard let bytes else { return .refused(id, .invalid, "Nothing to write.") }
                    return files.write(id: id, path: args.path ?? "", bytes: bytes, base: args.base)
                case .fsCreate: return files.create(id: id, path: args.path ?? "", dir: args.dir == true)
                case .fsRename: return files.rename(id: id, from: args.from ?? "", to: args.to ?? "")
                case .fsDelete: return files.delete(id: id, path: args.path ?? "", trash: trash)
                case .fsSearch:
                    return files.search(id: id, root: args.root ?? "", query: args.query ?? "", text: args.mode == "text", max: args.max, run: run)
                default: return .refused(id, .invalid, "Not taken here.")
                }
            }.value
            self?.sendRaw(StreamWire.encode(result))
            // A file changed over the link: git's states there may have too (1.8).
            if result.ok, let self {
                switch kind {
                case .fsWrite, .fsCreate, .fsDelete: if let path = args.path { self.host.git.touched(path) }
                case .fsRename: for path in [args.from, args.to].compactMap({ $0 }) { self.host.git.touched(path) }
                default: break
                }
            }
        }
    }

    /// `fs.watch`: these folders (inside served folders, links checked) watched for this client
    /// from now on, the ones before dropped; an empty list ends them.
    private func watch(_ asked: [String], files: HostFiles, id: String) -> FilesResult {
        var wanted: [(path: String, real: String)] = []
        for folder in asked {
            guard case .success(let place) = files.place(folder, .served), HostFiles.look(place.real)?.kind == .dir else { continue }
            wanted.append(place)
        }
        if wanted.isEmpty {
            watches?.stop()
            watches = nil
            return FilesResult(id: id, ok: true, watching: true)
        }
        let watches = self.watches ?? FolderWatches { [weak self] changed in
            self?.sendRaw(StreamWire.encode(changed))
            // An open folder's entries changed (any process's doing): git may say so too.
            for folder in changed.folders { self?.host.git.touched(folder) }
        }
        self.watches = watches
        return FilesResult(id: id, ok: true, watching: watches.set(wanted))
    }

    // MARK: Sync

    /// `sync.watch` / `sync.unwatch` for a folder the box serves (or one inside it). A watch
    /// starts after its result goes, so the list follows the result.
    private func sync(_ kind: ControlKind, folder: String?, id: String) -> LinkMessage.Result {
        guard let control = grant?.control, control != .watch else { return .init(id: id, ok: false, code: .deniedControl, message: "This grant only watches.") }
        if case .deny(let code, let message) = LinkPolicy.checkBox(kind, ControlArgs(folder: folder), nil, control: control == .full ? .full : .standard) {
            return .init(id: id, ok: false, code: code, message: message)
        }
        guard let folder = folder.map(HostDaemon.standard), host.serves(folder) else {
            return .init(id: id, ok: false, code: .goneFolder, message: "That folder isn't on this box.")
        }
        syncs.removeValue(forKey: folder)?.stop()
        guard kind == .syncWatch else { return .init(id: id, ok: true) }
        guard syncs.count < Self.maxWatches else {
            return .init(id: id, ok: false, code: .busy, message: "Too many folders are syncing on this connection.")
        }
        syncs[folder] = SyncWatch(folder: folder) { [weak self] data in self?.sendSync(data) }
        return .init(id: id, ok: true)
    }

    /// `sync.watch`es one connection may hold at once.
    static let maxWatches = 4

    /// `sync.changed` pieces waiting: a big folder's list goes a piece at a time, each once the
    /// socket has drained, so it never passes the socket's cap.
    private var syncPieces: [Data] = []

    private func sendSync(_ data: Data) {
        syncPieces.append(data)
        sendSyncPieces()
    }

    private func sendSyncPieces() {
        while !syncPieces.isEmpty, socket.backlog < HostSocket.lowWater { socket.send(syncPieces.removeFirst()) }
    }

    // MARK: Out

    func nextRev() -> Int {
        rev += 1
        return rev
    }

    func delta(windows: [LinkWindow]?, chats: [ChatMeta]) {
        rev += 1
        send(.delta(rev: rev, windows: windows, chats: chats.isEmpty ? nil : chats, removed: nil))
    }

    /// The followed window of a chat: its last entries, and their turns.
    func page(_ hc: HostChat, last: Int?) {
        guard var follow = following[hc.id] else { return }
        follow.txRev += 1
        following[hc.id] = follow
        // A page stays under the client's frame limit: fewer of the newest entries when they don't fit.
        var count = min(last ?? follow.last, hc.entries.count)
        while true {
            let shown = Array(hc.entries.suffix(count))
            let turnIds = Set(shown.compactMap(\.turn))
            let turns = turnIds.compactMap { hc.turns[$0] }.sorted { $0.startedAt < $1.startedAt }
            let page = LinkMessage.txPage(chatId: hc.id, txRev: follow.txRev, entries: shown, turns: turns, hasEarlier: hc.entries.count > shown.count)
            if count <= 1 || ((try? page.encoded())?.count ?? 0) <= Self.pageBudget {
                return send(page)
            }
            count /= 2
        }
    }

    /// The most a page's frame carries, under `LinkFrame.outboundMax`.
    static let pageBudget = 900 * 1024

    func txDelta(_ hc: HostChat, upserts: [LinkEntry], removed: [String], order: [String]?, turns: [LinkTurn]) {
        guard var follow = following[hc.id] else { return }
        follow.txRev += 1
        following[hc.id] = follow
        send(.txDelta(.init(chatId: hc.id, txRev: follow.txRev, upserts: upserts, removed: removed, order: order, turns: turns.isEmpty ? nil : turns)))
    }

    /// The rest of a long field, from the live chat's log (a chat asleep has only what was sent).
    private func entryMore(id: String, chatId: String, entryId: String, field: LinkMessage.Field, offset: Int) {
        let entry = host.chat(chatId)?.chat?.transcriptView.entries.first { $0.id.uuidString == entryId }
        let text: String? =
            switch field {
            case .text: entry?.text
            case .input: entry?.input
            case .result: entry?.result
            case .unknown: nil
            }
        guard let text else { return send(.result(.init(id: id, ok: false, code: .goneChat, message: "That entry's whole text isn't here now."))) }
        let piece = LinkProjection.piece(text, from: offset)
        send(.entryChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
    }
}

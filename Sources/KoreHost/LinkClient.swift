import Foundation
import LinkProtocol
import src

/// One client on the box's socket: the challenge, a hello proven with its grant's secret, then
/// the snapshot, followed transcripts and commands. Nothing of it runs between messages.
@MainActor
final class LinkClient {
    private let socket: HostSocket
    private unowned let host: HostDaemon
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
    private var catchUps: [(chatId: String, log: String, reset: Bool, items: ArraySlice<StreamItem>)] = []
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
        }
        send(.challenge(nonce: nonce))
        // A client that hasn't proven itself in 10 s is closed: the one wait while it connects.
        let wait = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard self?.proven == false else { return }
                HostJournal.note("refused", ["reason": "no hello in 10 s"])
                self?.end(.auth)
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
        syncPieces = []
        host.ended(self)
        for chatId in streaming { host.unfollowed(chatId) }
        streaming = []
    }

    private func uploadFailed(_ uploadId: String, _ failure: LinkUploads.Failure) {
        send(.result(.init(id: "blob.put:" + uploadId, ok: false, code: failure.code, message: failure.message)))
    }

    func follows(_ chatId: String) -> Bool { following[chatId] != nil }

    func streams(_ chatId: String) -> Bool { streaming.contains(chatId) }

    func sendRaw(_ data: Data) { socket.send(data) }

    /// A chat's items, in frames; this client's own rows are marked `by` it. Live items go at once
    /// (a part at most); a catch-up goes a part at a time, each once the socket has drained, and
    /// live items for that chat wait behind it.
    func events(_ hc: HostChat, _ items: [StreamItem], reset: Bool) {
        guard reset || !items.isEmpty else { return }
        if reset { catchUps.removeAll { $0.chatId == hc.id } }
        if let at = catchUps.firstIndex(where: { $0.chatId == hc.id }) {
            catchUps[at].items += items
        } else {
            catchUps.append((hc.id, hc.stream.id, reset, items[...]))
        }
        sendCatchUps()
    }

    /// Sends waiting catch-ups while the socket's queue is short.
    private func sendCatchUps() {
        while !catchUps.isEmpty, socket.backlog < HostSocket.lowWater {
            var next = catchUps.removeFirst()
            var part: [StreamItem] = []
            var size = 0
            while let item = next.items.first, size < StreamWire.frameBudget * 2 || part.isEmpty {
                part.append(item)
                size += item.e.map { _ in 256 } ?? 64
                next.items = next.items.dropFirst()
                if part.count >= 2000 { break }
            }
            for frame in StreamWire.frames(chatId: next.chatId, log: next.log, reset: next.reset, items: part) { socket.send(frame) }
            if !next.items.isEmpty {
                next.reset = false
                catchUps.insert(next, at: 0)
            }
        }
    }

    /// The grant as its file says now: a revoked or changed one ends the connection, a lowered one
    /// takes effect at once.
    private func current() -> Grant? {
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
            socket.close()
            gone()
        case .txOpen(let chatId, let last):
            guard let hc = host.chat(chatId) else {
                return send(.result(.init(id: "tx.open:" + chatId, ok: false, code: .goneChat, message: "No such chat on this box.")))
            }
            following[chatId] = (min(max(last ?? 60, 1), 2000), 0)
            page(hc, last: nil)
        case .txMore(let chatId, let count):
            guard let hc = host.chat(chatId), let follow = following[chatId] else { return }
            following[chatId]?.last = min(follow.last + max(count, 0), 2000)
            page(hc, last: nil)
        case .txClose(let chatId):
            following[chatId] = nil
        case .entryMore(let id, let chatId, let entryId, let field, let offset):
            entryMore(id: id, chatId: chatId, entryId: entryId, field: field, offset: offset)
        case .cardMore(let id, let chatId, let cardId, let offset):
            let text = host.chat(chatId)?.chat?.approvals.pending.first { $0.id == cardId }.flatMap(HostMeta.fullContent) ?? ""
            let piece = LinkProjection.piece(text, from: offset)
            send(.cardChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
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
        case .historyList(let id, let windowId, let query, _, let offset):
            // A folder's closed chats, to reopen (full grants).
            guard current()?.control == .full else { return }
            let all = host.closedHistory(windowId: windowId, query: query)
            let page = Array(all.dropFirst(max(offset, 0)).prefix(50))
            send(.historyPage(id: id, windowId: windowId, sessions: page, more: all.count > max(offset, 0) + page.count))
        case .cmd(let id, .control(let kind, let args)) where kind == .syncWatch || kind == .syncUnwatch:
            guard current() != nil else { return }
            send(.result(sync(kind, folder: args.folder, id: id)))
            if kind == .syncWatch, let folder = args.folder.map(HostDaemon.standard) { syncs[folder]?.start() }
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

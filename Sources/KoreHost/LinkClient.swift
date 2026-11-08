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
    private var relaying: Set<String> = []
    private var uploads = LinkUploads()

    init(socket: HostSocket, host: HostDaemon) {
        self.socket = socket
        self.host = host
    }

    func begin() {
        socket.start(max: LinkFrame.inboundMax, frame: { [weak self] data in self?.received(data) }, ended: { [weak self] in self?.gone() })
        send(.challenge(nonce: nonce))
        // A client that hasn't proven itself in 10 s is closed: the one wait while it connects.
        let wait = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.proven == false { self?.end(.auth) } } }
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
        host.ended(self)
        for chatId in relaying { host.unfollowed(chatId) }
        relaying = []
    }

    private func uploadFailed(_ uploadId: String, _ failure: LinkUploads.Failure) {
        send(.result(.init(id: "blob.put:" + uploadId, ok: false, code: failure.code, message: failure.message)))
    }

    func follows(_ chatId: String) -> Bool { following[chatId] != nil }

    func relays(_ chatId: String) -> Bool { relaying.contains(chatId) }

    func sendRaw(_ data: Data) { socket.send(data) }

    /// A chat's items, in frames; this client's own rows are marked `by` it, which it skips live.
    func events(_ hc: HostChat, _ items: [RelayItem], reset: Bool) {
        guard reset || !items.isEmpty else { return }
        for frame in RelayWire.frames(chatId: hc.id, log: hc.relay.id, reset: reset, items: items) { socket.send(frame) }
    }

    /// 1.5's messages, read by their type: full grants only.
    private func relay(_ type: String, _ data: Data) {
        guard grant?.control == .full else {
            if type == "chat.call" {
                sendRaw(RelayWire.encode(ChatCallResult(id: "", ok: false, code: .deniedControl, message: "Driving a chat needs a grant with full control.")))
            }
            return
        }
        switch type {
        case "chat.follow":
            guard let request = try? JSONDecoder().decode(ChatFollow.self, from: data) else { return }
            relaying.insert(request.chatId)
            host.follow(self, request)
        case "chat.unfollow":
            guard let request = try? JSONDecoder().decode(ChatUnfollow.self, from: data) else { return }
            relaying.remove(request.chatId)
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
            relay(type, data)
        case .blobPutBegin(let uploadId, let name, let mime, let size, let sha256):
            guard grant?.control == .full else { return uploadFailed(uploadId, .init(.deniedControl, "Uploads need a grant with full control.")) }
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
        case .cmd(let id, let command):
            let result = host.apply(command, id: id, control: grant?.control ?? .watch) { [weak self] result in self?.send(.result(result)) }
            if let result { send(.result(result)) }
        default:
            break
        }
    }

    private func hello(_ message: LinkMessage) {
        guard case .hello(let proto, _, let proof, _, let name) = message else { return end(.invalid) }
        guard proto.major == LinkProto.major else { return end(.version) }
        guard let name, let grant = GrantStore(host.paths.grants).load(name), let secret = Data(base64Encoded: grant.secret),
            LinkProof.check(proof, secret: secret, nonce: nonce)
        else { return end(.auth) }
        guard host.admit(self, grant: grant) else { return end(.invalid) }
        helloWait?.cancel()
        self.grant = grant
        proven = true
        send(.welcome(host.welcome(control: grant.control)))
        rev += 1
        let full = grant.control == .full
        let clis = full && !host.clis.isEmpty ? host.clis : nil
        send(.snapshot(rev: rev, windows: host.windows, chats: host.chats.map { HostMeta.meta($0, raise: full) }, extras: LinkExtras(clis: clis, ghSignedIn: host.ghSignedIn)))
        send(.attnState(aid: 0, open: [], recent: []))
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
        let shown = Array(hc.entries.suffix(last ?? follow.last))
        let turnIds = Set(shown.compactMap(\.turn))
        let turns = turnIds.compactMap { hc.turns[$0] }.sorted { $0.startedAt < $1.startedAt }
        send(.txPage(chatId: hc.id, txRev: follow.txRev, entries: shown, turns: turns, hasEarlier: hc.entries.count > shown.count))
    }

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

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
    }

    func follows(_ chatId: String) -> Bool { following[chatId] != nil }

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
        send(.snapshot(rev: rev, windows: host.windows, chats: host.chats.map(HostMeta.meta)))
        send(.attnState(aid: 0, open: [], recent: []))
    }

    // MARK: Out

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

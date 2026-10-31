import Foundation

/// A phone without a phone: speaks the protocol over a link and keeps what it was told, as the
/// app's store does. Storylines and tests drive Kore's host through it.
@MainActor
package final class RemoteTestClient {
    package let link: any RemoteLink
    package private(set) var welcome: WireMessage.Welcome?
    package private(set) var windows: [WireWindow] = []
    package private(set) var chats: [String: ChatMeta] = [:]
    package private(set) var rev = 0
    package private(set) var transcripts: [String: Transcript] = [:]
    package private(set) var results: [String: (ok: Bool, code: ResultCode?)] = [:]
    package private(set) var open: [String: AttnItem] = [:]
    package private(set) var turnEnds: [AttnTurn] = []
    package private(set) var lastAid = 0
    package private(set) var received: [String] = []
    package private(set) var bytes = 0
    package private(set) var closed = false
    private var reader: Task<Void, Never>?
    private var counter = 0

    package struct Transcript: Sendable {
        package var order: [String] = []
        package var entries: [String: WireEntry] = [:]
        package var turns: [String: WireTurn] = [:]
        package var hasEarlier = false
        package var resets = 0

        /// Entries in order.
        package var list: [WireEntry] { order.compactMap { entries[$0] } }
    }

    package init(link: any RemoteLink) {
        self.link = link
        reader = Task { [weak self, link] in
            for await data in link.incoming { self?.take(data) }
            self?.closed = true
        }
    }

    // MARK: Sending

    package func hello(mode: WireMessage.Presence = .foreground, attnAfter: Int? = nil) {
        send(.hello(proto: Proto.version, device: .init(name: "Test phone", build: "0"), mode: mode, attnAfter: attnAfter, resume: nil))
    }

    package func presence(_ mode: WireMessage.Presence, visibleChat: String? = nil) {
        send(.presence(mode: mode, visibleChat: visibleChat))
    }

    package func open(_ chatId: String, last: Int? = nil) { send(.txOpen(chatId: chatId, last: last)) }
    package func more(_ chatId: String, count: Int) { send(.txMore(chatId: chatId, count: count)) }
    package func close(_ chatId: String) {
        transcripts[chatId] = nil
        send(.txClose(chatId: chatId))
    }

    /// Sends a command; its result lands in `results` under the returned id.
    @discardableResult
    package func command(_ command: RemoteCommand, id: String? = nil) -> String {
        counter += 1
        let id = id ?? "cmd-\(counter)"
        send(.cmd(id: id, command))
        return id
    }

    package func disconnect() {
        reader?.cancel()
        link.close()
        closed = true
    }

    private func send(_ message: WireMessage) {
        guard let data = try? Envelope(message).encoded() else { return }
        link.send(data)
    }

    // MARK: Receiving

    private func take(_ data: Data) {
        bytes += data.count
        guard let envelope = try? Envelope.decode(data) else { return }
        received.append(envelope.message.type)
        apply(envelope.message)
        if let seq = envelope.seq { send(.ack(seq)) }
    }

    private func apply(_ message: WireMessage) {
        switch message {
        case .welcome(let w): welcome = w
        case .snapshot(let rev, let windows, let chats):
            self.rev = rev
            self.windows = windows
            self.chats = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        case .delta(let rev, let windows, let chats, let removed):
            guard rev > self.rev else { return }
            self.rev = rev
            if let windows { self.windows = windows }
            for chat in chats ?? [] { self.chats[chat.id] = chat }
            for id in removed ?? [] { self.chats[id] = nil }
        case .txPage(let chatId, _, let entries, let turns, let hasEarlier):
            var t = transcripts[chatId] ?? Transcript()
            t.order = entries.map(\.id)
            t.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            t.turns = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            t.hasEarlier = hasEarlier
            transcripts[chatId] = t
        case .txDelta(let d):
            guard var t = transcripts[d.chatId] else { return }
            for id in d.removed { t.entries[id] = nil }
            for entry in d.upserts {
                if t.entries[entry.id] == nil, d.order == nil { t.order.append(entry.id) }
                t.entries[entry.id] = entry
            }
            t.order = d.order ?? t.order.filter { t.entries[$0] != nil }
            for turn in d.turns ?? [] { t.turns[turn.id] = turn }
            if let earlier = d.hasEarlier { t.hasEarlier = earlier }
            transcripts[d.chatId] = t
        case .txReset(let chatId):
            var t = Transcript()
            t.resets = (transcripts[chatId]?.resets ?? 0) + 1
            transcripts[chatId] = t
        case .result(let id, let ok, let code, _): results[id] = (ok, code)
        case .attnState(let aid, let open, let recent):
            lastAid = aid
            self.open = Dictionary(open.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
            turnEnds += recent
        case .attnEvent(let aid, let op, let item, let key, let turn):
            lastAid = max(lastAid, aid)
            switch op {
            case .open: if let item { open[item.key] = item }
            case .clear: if let key { open[key] = nil }
            case .turn: if let turn { turnEnds.append(turn) }
            case .unknown: break
            }
        default: break
        }
    }

    // MARK: Reading

    /// The first chat with this title.
    package func chat(titled title: String) -> ChatMeta? { chats.values.first { $0.title == title } }
}

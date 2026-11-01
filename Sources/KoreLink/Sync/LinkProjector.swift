import Foundation

/// What the host saw at one tick, as wire values: what changed since the last one, for one client.
package struct LinkBatch: Sendable {
    /// Every window, when the host looked at them (nil: not looked at; unchanged).
    package var windows: [LinkWindow]?
    /// Chats looked at this tick (the dirty ones, or all).
    package var chats: [ChatMeta]
    /// Every chat's id, when the host looked at them all (nil: none removed).
    package var chatIds: Set<String>?
    /// Transcripts the client follows.
    package var tx: [TxSlice]
    /// The Mac's state and the CLIs' models, with full control (nil: not looked at; unchanged).
    package var extras: LinkExtras?

    package init(
        windows: [LinkWindow]? = nil, chats: [ChatMeta] = [], chatIds: Set<String>? = nil, tx: [TxSlice] = [], extras: LinkExtras? = nil
    ) {
        self.windows = windows
        self.chats = chats
        self.chatIds = chatIds
        self.tx = tx
        self.extras = extras
    }
}

/// One followed transcript's window: its last entries in order, those whose wire value may have
/// changed, and its turns.
package struct TxSlice: Sendable {
    package var chatId: String
    /// Changes when the chat's transcript was replaced as a whole: the client starts it again.
    package var epoch: String
    package var order: [String]
    /// The entries to compare: every one in `order` when `full`, else those that may have changed.
    package var entries: [LinkEntry]
    package var full: Bool
    package var turns: [LinkTurn]
    package var hasEarlier: Bool

    package init(chatId: String, epoch: String, order: [String], entries: [LinkEntry], full: Bool, turns: [LinkTurn], hasEarlier: Bool) {
        self.chatId = chatId
        self.epoch = epoch
        self.order = order
        self.entries = entries
        self.full = full
        self.turns = turns
        self.hasEarlier = hasEarlier
    }
}

/// The last state one client was sent, and the smallest messages that bring it to the next. A
/// client that falls behind skips ticks; the next diff carries everything in one message.
package struct LinkProjector: Sendable {
    package private(set) var rev = 0
    private var windows: [LinkWindow]?
    private var mac: MacState?
    private var clis: [CLIState]?
    private var chats: [String: ChatMeta] = [:]
    private var subs: [String: Sub] = [:]

    private struct Sub: Sendable {
        var epoch: String
        var txRev: Int
        var order: [String]
        var entries: [String: LinkEntry]
        var turns: [String: LinkTurn]
        var hasEarlier: Bool
    }

    package init() {}

    /// The client has had a snapshot.
    package var started: Bool { windows != nil }

    /// Whether the client follows this chat's transcript.
    package func follows(_ chatId: String) -> Bool { subs[chatId] != nil }

    /// The messages that take the client from what it has to `batch`.
    package mutating func apply(_ batch: LinkBatch) -> [LinkMessage] {
        var out: [LinkMessage] = []
        if !started {
            guard let windows = batch.windows else { return [] }
            rev = 1
            self.windows = windows
            chats = Dictionary(batch.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            mac = batch.extras?.mac
            clis = batch.extras?.clis
            out.append(.snapshot(rev: rev, windows: windows, chats: batch.chats, extras: batch.extras))
        } else {
            let windows = batch.windows.flatMap { $0 == self.windows ? nil : $0 }
            if let windows { self.windows = windows }
            let mac = batch.extras?.mac.flatMap { $0 == self.mac ? nil : $0 }
            if let mac { self.mac = mac }
            let clis = batch.extras?.clis.flatMap { $0 == self.clis ? nil : $0 }
            if let clis { self.clis = clis }
            let extras = mac == nil && clis == nil ? nil : LinkExtras(mac: mac, clis: clis)
            var upserts: [ChatMeta] = []
            for chat in batch.chats where chats[chat.id] != chat {
                chats[chat.id] = chat
                upserts.append(chat)
            }
            var removed: [String] = []
            if let ids = batch.chatIds {
                removed = chats.keys.filter { !ids.contains($0) }.sorted()
                for id in removed { chats[id] = nil }
            }
            if windows != nil || !upserts.isEmpty || !removed.isEmpty || extras != nil {
                rev += 1
                out.append(
                    .delta(
                        rev: rev, windows: windows, chats: upserts.isEmpty ? nil : upserts, removed: removed.isEmpty ? nil : removed,
                        extras: extras))
            }
        }
        for slice in batch.tx { out += apply(slice) }
        return out
    }

    private mutating func apply(_ slice: TxSlice) -> [LinkMessage] {
        guard var sub = subs[slice.chatId], sub.epoch == slice.epoch else {
            // New, or its transcript was replaced: the whole window again.
            let replaced = subs[slice.chatId] != nil
            guard slice.full else { return [] }
            let byId = Dictionary(slice.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            let entries = slice.order.compactMap { byId[$0] }
            subs[slice.chatId] = Sub(
                epoch: slice.epoch, txRev: 1, order: entries.map(\.id), entries: Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }),
                turns: Dictionary(slice.turns.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }), hasEarlier: slice.hasEarlier)
            let page = LinkMessage.txPage(chatId: slice.chatId, txRev: 1, entries: entries, turns: slice.turns, hasEarlier: slice.hasEarlier)
            return replaced ? [.txReset(chatId: slice.chatId), page] : [page]
        }
        let kept = Set(slice.order)
        let removed = sub.order.filter { !kept.contains($0) }
        var upserts: [LinkEntry] = []
        for entry in slice.entries where kept.contains(entry.id) && sub.entries[entry.id] != entry {
            sub.entries[entry.id] = entry
            upserts.append(entry)
        }
        // An entry new to the window that this slice didn't carry can't be sent yet.
        let order = slice.order.filter { sub.entries[$0] != nil }
        for id in removed { sub.entries[id] = nil }
        // Only appends keep the order implied; anything else sends it.
        let survivors = sub.order.filter { kept.contains($0) }
        let implied = survivors + upserts.map(\.id).filter { !sub.order.contains($0) }
        let sendOrder = order != implied
        var turns: [LinkTurn] = []
        for turn in slice.turns where sub.turns[turn.id] != turn {
            sub.turns[turn.id] = turn
            turns.append(turn)
        }
        let earlier = slice.hasEarlier != sub.hasEarlier ? slice.hasEarlier : nil
        sub.hasEarlier = slice.hasEarlier
        sub.order = order
        guard !upserts.isEmpty || !removed.isEmpty || sendOrder || !turns.isEmpty || earlier != nil else {
            subs[slice.chatId] = sub
            return []
        }
        sub.txRev += 1
        subs[slice.chatId] = sub
        return [
            .txDelta(
                .init(
                    chatId: slice.chatId, txRev: sub.txRev, upserts: upserts, removed: removed, order: sendOrder ? order : nil,
                    turns: turns.isEmpty ? nil : turns, hasEarlier: earlier))
        ]
    }

    /// The client stopped following a transcript.
    package mutating func close(_ chatId: String) { subs[chatId] = nil }

    /// Everything the client follows, and where each is at (for a resume).
    package var following: [String: Int] { subs.mapValues(\.txRev) }
}

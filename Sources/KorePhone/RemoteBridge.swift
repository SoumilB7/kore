import Foundation
import KoreRemote
import KoreUI

/// Turns Kore's state into what each connected phone is sent, a few times a second. Only what
/// changed is looked at: chats marked by their events (and, once a second, every chat, for
/// changes that aren't events), and transcripts from their first changed entry. It never touches
/// how Kore draws a chat (`hidden`, `loadEarlier`, its rows), so a phone reading a chat costs the
/// Mac's own views nothing. The tick runs in the run loop's default mode only, so it waits while
/// a window resizes, a menu is open or a scroller is dragged.
@MainActor
final class RemoteBridge {
    /// How many of a transcript's last entries a phone follows, at first and at most.
    static let window = 60
    static let windowMax = 2000
    /// Ticks a second.
    static let rate: TimeInterval = 0.25

    private weak var host: RemoteHost?
    private var timer: Timer?
    private var dirtyChats = Set<String>()
    private var ticks = 0
    /// Wire entries already made, per chat, by entry id: re-made only from the first changed one.
    private var cache: [String: (epoch: String, entries: [String: WireEntry])] = [:]
    /// How long each tick took, for the navigation budget (the last 2000).
    private(set) var tickTimes: [Duration] = []

    func start(_ host: RemoteHost) {
        self.host = host
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.rate, repeats: true) { _ in MainActor.assumeIsolated { [weak self] in self?.tick() } }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cache = [:]
        dirtyChats = []
    }

    func dirty(_ chat: Chat) { dirtyChats.insert(chat.id.uuidString) }
    func dirty(id: String) { dirtyChats.insert(id) }

    /// Every open chat by its wire id.
    static func chatsByID() -> [String: Chat] {
        var out: [String: Chat] = [:]
        for workspace in RemoteSnapshot.workspaces() {
            for chat in RemoteSnapshot.chats(workspace) { out[chat.id.uuidString] = chat }
        }
        return out
    }

    // MARK: The tick

    func tick() {
        guard let host, !host.connections.isEmpty else { return }
        let start = ContinuousClock.now
        defer {
            tickTimes.append(ContinuousClock.now - start)
            if tickTimes.count > 2000 { tickTimes.removeFirst(tickTimes.count - 2000) }
        }
        ticks += 1
        let everySecond = ticks % Int(1 / Self.rate) == 0
        let chats = Self.chatsByID()
        for message in host.attention.look(chats, everything: false) { host.broadcast(message) }

        let foreground = host.connections.filter(\.foreground)
        let followed = Set(foreground.flatMap { $0.subs.keys })
        let wantsAll = everySecond || foreground.contains(where: \.snapshotDue)
        guard !foreground.isEmpty, wantsAll || !dirtyChats.isEmpty else {
            dirtyChats = []
            return
        }
        let windows = wantsAll ? RemoteSnapshot.workspaces().map(RemoteSnapshot.window) : nil
        let metaIds = wantsAll ? Set(chats.keys) : dirtyChats.intersection(chats.keys)
        let metas = metaIds.sorted().compactMap { chats[$0].map { RemoteSnapshot.meta($0, grant: host.grant) } }
        // Each followed transcript's first changed entry, read once for every phone.
        var changedFrom: [String: Int] = [:]
        for id in followed {
            guard let chat = chats[id] else { continue }
            if let from = chat.transcript.remoteDirtyFrom { changedFrom[id] = from }
            chat.transcript.remoteDirtyFrom = nil
        }
        for connection in foreground {
            var tx: [TxSlice] = []
            for (id, sub) in connection.subs {
                guard let chat = chats[id] else { continue }
                guard sub.fresh || changedFrom[id] != nil || dirtyChats.contains(id) else { continue }
                let slice = self.slice(chat, sub, from: changedFrom[id])
                connection.subs[id]?.fresh = false
                connection.subs[id]?.known = Set(slice.order)
                tx.append(slice)
            }
            let full = connection.snapshotDue
            connection.snapshotDue = false
            let batch = RemoteBatch(
                windows: windows, chats: full || wantsAll ? Array(metas) : metas, chatIds: wantsAll ? Set(chats.keys) : nil, tx: tx)
            guard full || batch.windows != nil || !batch.chats.isEmpty || !tx.isEmpty else { continue }
            connection.session.enqueue(.batch(batch))
        }
        dirtyChats = []
        // Entries no phone follows any more are let go.
        cache = cache.filter { followed.contains($0.key) }
    }

    /// A followed transcript's window: its order, and its entries from the first changed one
    /// (all of them for a phone that hasn't had it).
    private func slice(_ chat: Chat, _ sub: RemoteHost.Connection.Sub, from changed: Int?) -> TxSlice {
        let id = chat.id.uuidString
        let store = chat.transcript
        let epoch = "\(ObjectIdentifier(store).hashValue)"
        var made = cache[id].flatMap { $0.epoch == epoch ? $0.entries : nil } ?? [:]
        let entries = store.entries
        let lo = max(0, entries.count - sub.last)
        let window = entries[lo...]
        let order = window.map { $0.id.uuidString }
        let from = max(lo, changed ?? entries.count)
        var out: [WireEntry] = []
        for (index, entry) in zip(window.indices, window) {
            let key = entry.id.uuidString
            let stale = index >= from || made[key] == nil
            if stale { made[key] = RemoteSnapshot.entry(entry, folder: chat.folder) }
            if sub.fresh || stale || !sub.known.contains(key), let wire = made[key] { out.append(wire) }
        }
        cache[id] = (epoch, made)
        let turnIds = Set(window.compactMap(\.turn))
        let turns = turnIds.sorted().compactMap { store.remoteTurn($0).map(RemoteSnapshot.turn) }
        return TxSlice(chatId: id, epoch: epoch, order: order, entries: out, full: sub.fresh, turns: turns, hasEarlier: lo > 0)
    }

    /// The rest of a long field of an entry (`entry.more`), 64K at a time.
    static func chunk(id: String, chatId: String, entryId: String, field: WireMessage.Field, offset: Int) -> WireMessage {
        let entry = chatsByID()[chatId]?.transcript.entries.first { $0.id.uuidString == entryId }
        let text: String =
            switch field {
            case .text: entry?.text ?? ""
            case .input: entry?.input ?? ""
            case .result: entry?.result ?? ""
            case .unknown: ""
            }
        let scalars = Array(text.unicodeScalars)
        let start = min(max(offset, 0), scalars.count)
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[start..<min(start + RemoteSnapshot.textCap, scalars.count)])
        return .entryChunk(id: id, text: String(piece), offset: start, total: scalars.count)
    }
}

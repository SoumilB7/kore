import Foundation
import KoreUI
import LinkProtocol
import Observation
import src

/// What the feed reads of Kore: the running app's windows and chats (`LinkSnapshot`), or a test's.
@MainActor
package protocol LinkFeedSource: AnyObject {
    func chats() -> [String: Chat]
    func windows(full: Bool) -> [LinkWindow]
    func meta(_ chat: Chat, full: Bool) -> ChatMeta
    func extras(_ chats: [Chat]) -> LinkExtras
}

/// Kore's windows and chats, as the link has always read them.
@MainActor
package final class LinkSnapshotSource: LinkFeedSource {
    package init() {}
    package func chats() -> [String: Chat] { LinkSnapshot.chatsByID() }
    package func windows(full: Bool) -> [LinkWindow] { LinkSnapshot.workspaces().map { LinkSnapshot.window($0, full: full) } }
    package func meta(_ chat: Chat, full: Bool) -> ChatMeta { LinkSnapshot.meta(chat, full: full) }
    package func extras(_ chats: [Chat]) -> LinkExtras { LinkExtras(mac: LinkSnapshot.mac(), clis: LinkSnapshot.clis(chats)) }
}

/// One client's outgoing side, off the main actor: its projector (the last state it was sent),
/// the diff against each tick's batch, the encoding and the send, all on the client's own serial
/// queue. Everything Kore sends a client goes through here, so results and batches keep their order.
package final class LinkSink: @unchecked Sendable {
    package let queue: DispatchQueue
    /// Queue-confined.
    private var projector: LinkProjector
    private let write: @Sendable (Data) -> Void
    /// Tests: called on the queue after each batch, with whether it ran on the main thread.
    package var applied: (@Sendable (_ onMain: Bool, _ messages: Int) -> Void)?

    /// `write` runs on `queue`, one encoded message at a time.
    package init(queue: DispatchQueue, projector: LinkProjector = LinkProjector(), write: @escaping @Sendable (Data) -> Void) {
        self.queue = queue
        self.projector = projector
        self.write = write
    }

    package func apply(_ batch: LinkBatch) {
        queue.async { [self] in
            let messages = projector.apply(batch)
            for message in messages { if let data = try? message.encoded() { write(data) } }
            applied?(Thread.isMainThread, messages.count)
        }
    }

    package func send(_ message: LinkMessage) {
        queue.async { [self] in if let data = try? message.encoded() { write(data) } }
    }

    package func send(_ messages: [LinkMessage]) {
        guard !messages.isEmpty else { return }
        queue.async { [self] in for message in messages { if let data = try? message.encoded() { write(data) } } }
    }

    package func sendRaw(_ data: Data) { queue.async { [self] in write(data) } }

    /// Takes up a projector kept from an earlier session (a resume): the next batch diffs from it.
    package func adopt(_ kept: LinkProjector) { queue.async { [self] in projector = kept } }

    /// The client stopped following a transcript (or follows it afresh): its next slice is whole.
    package func close(_ chatId: String) { queue.async { [self] in projector.close(chatId) } }

    /// The projector as it stands once everything queued before is done (kept for a resume).
    package func projected(_ done: @escaping @Sendable (LinkProjector) -> Void) { queue.async { [self] in done(projector) } }
}

/// The local link's view of Kore, for every client at once (phase 18 §2): the doorbell's companion
/// and each phone over KoreNet. It reads Kore's state on the main actor once per tick, for all
/// clients, and hands each client the batch; each client's projector diffs, encodes and sends it
/// off the main actor (`LinkSink`).
///
/// Nothing runs on a timer while nothing changes: chats mark themselves dirty (their events, their
/// transcripts, and Observation on what their meta reads), the windows likewise, and a dirty mark
/// schedules one tick a quarter second on, in the run loop's default mode (it waits while a window
/// resizes or a scroller is dragged). The tick reads and sends snapshots only while at least one
/// client is on screen (`presence`); clients in the background get attention only.
@MainActor
package final class LinkFeed {
    package static let shared = LinkFeed(source: LinkSnapshotSource())

    /// A tick at most this often.
    package static var rate: TimeInterval = 0.25
    /// How many of a transcript's last entries a client follows, at first and at most.
    static let window = 60
    static let windowMax = 2000
    /// Transcripts followed at once.
    static let followMax = 8
    /// After the last phone goes, attention is kept this long for its resume.
    package static var keepAfterPhones: TimeInterval = 120

    /// One client as the feed sees it.
    @MainActor
    package final class Client {
        package let sink: LinkSink
        /// Full control (the doorbell's grant): windows' groups, chats' controls, the Mac's state.
        package let full: Bool
        package let phone: Bool
        /// The local link's companion (the doorbell): served as it always was, a tick four times a
        /// second and every window, chat and the Mac's state read again once a second, so fields
        /// that change without an event (elapsed time, context %) keep coming.
        package let sweeps: Bool
        /// Its user is looking at it (`presence`); a client that never says is on screen.
        package fileprivate(set) var onScreen = true
        /// It has nothing yet, or came back on screen: every chat's meta at the next tick.
        package fileprivate(set) var needsAll = true
        /// Waiting for its cursors: nothing goes to it yet.
        package var holding = false
        package fileprivate(set) var subs: [String: Sub] = [:]
        fileprivate var followOrder: [String] = []
        /// Tests: ticks that sent it a batch.
        package fileprivate(set) var batches = 0

        package struct Sub {
            var last: Int
            var fresh = true
            var known = Set<String>()
        }

        package init(sink: LinkSink, full: Bool, phone: Bool, sweeps: Bool = false) {
            self.sweeps = sweeps
            self.sink = sink
            self.full = full
            self.phone = phone
        }

        package var follows: Set<String> { Set(subs.keys) }
    }

    private let source: any LinkFeedSource
    package private(set) var clients: [Client] = []
    private(set) var attention = LinkAttention()
    /// Wire entries already made, per chat, by entry id: re-made only from the first changed one.
    private var cache: [String: (epoch: String, entries: [String: LinkEntry])] = [:]
    private var dirtyChats = Set<String>()
    /// Chats whose meta is observed now, per flavour (full or not).
    private var observed: [Bool: Set<String>] = [true: [], false: []]
    private var layoutDirty = true
    private var layoutObserved: [Bool: Bool] = [true: false, false: false]
    private var extrasDirty = true
    private var extrasObserved = false
    private var attentionObserved = Set<String>()
    private var scheduled: Timer?
    private var keepTimer: Timer?
    /// The companion's repeating tick, while one is attached.
    private var sweepTimer: Timer?
    private var sweepCount = 0
    private var sweepNow = false
    /// The companion's once-a-second look (its mark shown in new windows).
    package var swept: (() -> Void)?
    /// The taps are on (a client is attached, or a phone left less than `keepAfterPhones` ago).
    package private(set) var live = false
    /// How long each tick took on the main actor (the last 2000), for the navigation budget.
    package private(set) var tickTimes: [Duration] = []
    /// Ticks run (tests).
    package private(set) var ticks = 0
    /// Called when the windows changed (the doorbell shows its mark in new ones).
    package var layoutChanged: (() -> Void)?

    /// Whether this feed installs Kore's taps (`LinkTaps`); a test's feeds are handed events by
    /// hand, so they never take the running app's.
    private let taps: Bool

    package init(source: any LinkFeedSource, taps: Bool = true) {
        self.source = source
        self.taps = taps
    }

    // MARK: Clients

    package func attach(_ client: Client) {
        guard !clients.contains(where: { $0 === client }) else { return }
        clients.append(client)
        keepTimer?.invalidate()
        keepTimer = nil
        turnOn()
        if client.sweeps, sweepTimer == nil {
            let timer = Timer(timeInterval: Self.rate, repeats: true) { _ in MainActor.assumeIsolated { [weak self] in self?.sweepTick() } }
            // The default mode only: it waits while a window resizes, a menu is open or a scroller is dragged.
            RunLoop.main.add(timer, forMode: .default)
            sweepTimer = timer
        }
        schedule(now: true)
    }

    /// The companion's tick (four a second); every fourth reads everything again.
    package func sweepTick() {
        sweepCount += 1
        sweepNow = sweepCount % Int(1 / Self.rate) == 0
        if sweepNow { swept?() }
        tick()
    }

    /// A client went. With no client left the taps go (after `keepAfterPhones` when a phone left,
    /// so its resume still hears what finished meanwhile).
    package func detach(_ client: Client) {
        clients.removeAll { $0 === client }
        if !clients.contains(where: \.sweeps) {
            sweepTimer?.invalidate()
            sweepTimer = nil
            sweepCount = 0
        }
        guard clients.isEmpty else { return }
        scheduled?.invalidate()
        scheduled = nil
        immediate = false
        if client.phone, Self.keepAfterPhones > 0 {
            keepTimer?.invalidate()
            let timer = Timer(timeInterval: Self.keepAfterPhones, repeats: false) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.clients.isEmpty else { return }
                    self.turnOff()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            keepTimer = timer
        } else {
            turnOff()
        }
    }

    private func turnOn() {
        guard !live else { return }
        live = true
        attention = LinkAttention()
        guard taps else { return }
        LinkTaps.event = { [weak self] chat, event in self?.noted(chat, event) }
        LinkTaps.dirty = { [weak self] in self?.transcriptMarked() }
        LinkTaps.layout = { [weak self] in self?.markLayout() }
        LinkTaps.on = true
    }

    private func turnOff() {
        guard live else { return }
        live = false
        keepTimer?.invalidate()
        keepTimer = nil
        if taps {
            LinkTaps.on = false
            LinkTaps.event = nil
            LinkTaps.dirty = nil
            LinkTaps.layout = nil
        }
        cache = [:]
        observed = [true: [], false: []]
        layoutObserved = [true: false, false: false]
        extrasObserved = false
        attentionObserved = []
        dirtyChats = []
        layoutDirty = true
        extrasDirty = true
    }

    /// `presence{onScreen}`: off screen it gets attention only; back on screen it gets what it
    /// missed (every chat's meta diffed, its transcripts whole), at the next tick.
    package func presence(_ client: Client, onScreen: Bool) {
        let back = onScreen && !client.onScreen
        client.onScreen = onScreen
        guard back else { return }
        client.needsAll = true
        for id in client.subs.keys { client.subs[id]?.fresh = true }
        schedule(now: true)
    }

    /// The client is ready for its first batch (its cursors came, or none will).
    package func release(_ client: Client) {
        client.holding = false
        client.needsAll = true
        schedule(now: true)
    }

    /// A command ran: what it changed goes out at once (as the local link always did).
    package func poke() { tick() }

    /// What needs the user now, and the turn ends after `after` (nil: none of those).
    package func attentionState(after: Int?) -> LinkMessage { attention.ledger.state(after: after) }

    /// The attention id a resume's cursor names, if this run of Kore made it.
    package func attentionResume(_ aid: Int?) -> Int? {
        guard let aid, aid <= attention.ledger.aid else { return nil }
        return aid
    }

    // MARK: Transcripts a client follows

    package enum Follow { case ok, gone }

    package func follow(_ client: Client, _ chatId: String, last: Int?) {
        let count = min(max(last ?? Self.window, 1), Self.windowMax)
        client.subs[chatId] = Client.Sub(last: count)
        client.followOrder.removeAll { $0 == chatId }
        client.followOrder.append(chatId)
        while client.followOrder.count > Self.followMax {
            let oldest = client.followOrder.removeFirst()
            client.subs[oldest] = nil
            client.sink.close(oldest)
        }
        client.sink.close(chatId)
        schedule(now: true)
    }

    package func more(_ client: Client, _ chatId: String, count: Int) {
        guard var sub = client.subs[chatId] else { return }
        sub.last = min(sub.last + max(count, 0), Self.windowMax)
        sub.fresh = true
        client.subs[chatId] = sub
        client.sink.close(chatId)
        schedule(now: true)
    }

    package func unfollow(_ client: Client, _ chatId: String) {
        client.subs[chatId] = nil
        client.followOrder.removeAll { $0 == chatId }
        client.sink.close(chatId)
    }

    // MARK: Dirty marks

    func noted(_ chat: Chat, _ event: ChatEvent) {
        dirtyChats.insert(chat.id.uuidString)
        if let turn = attention.noted(chat, event) {
            for client in clients where !client.holding { client.sink.send(turn) }
        }
        schedule(now: false, attentionOnly: true)
    }

    func transcriptMarked() { schedule(now: false) }

    package func markLayout() {
        layoutDirty = true
        layoutChanged?()
        schedule(now: false)
    }

    /// A chat's meta may have changed (Observation, on whatever thread changed it).
    private nonisolated func observedChange(_ id: String, full: Bool) {
        Self.onMain { [weak self] in
            guard let self else { return }
            self.observed[full]?.remove(id)
            self.dirtyChats.insert(id)
            self.schedule(now: false)
        }
    }

    private nonisolated func observedLayout(full: Bool) {
        Self.onMain { [weak self] in
            self?.layoutObserved[full] = false
            self?.markLayout()
        }
    }

    private nonisolated func observedExtras() {
        Self.onMain { [weak self] in
            self?.extrasObserved = false
            self?.extrasDirty = true
            self?.schedule(now: false)
        }
    }

    private nonisolated func observedAttention(_ id: String) {
        Self.onMain { [weak self] in
            self?.attentionObserved.remove(id)
            self?.attention.mark(id)
            self?.schedule(now: false, attentionOnly: true)
        }
    }

    /// Observation calls back from inside a change (`willSet`), usually on the main thread: the
    /// mark is made after it, never during.
    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    /// One tick, a quarter second on (at once when `now`), unless one is already due. A mark for
    /// the snapshot while nobody looks waits for a client to come on screen.
    private func schedule(now: Bool, attentionOnly: Bool = false) {
        guard !clients.isEmpty else { return }
        guard attentionOnly || clients.contains(where: { $0.onScreen && !$0.holding }) else { return }
        if now {
            // A client's own ask (it came, followed a chat, came back on screen): next on the queue.
            guard !immediate else { return }
            immediate = true
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, self.immediate else { return }
                self.tick()
            } }
            return
        }
        guard scheduled == nil, !immediate else { return }
        let timer = Timer(timeInterval: Self.rate, repeats: false) { _ in MainActor.assumeIsolated { [weak self] in self?.tick() } }
        // The default mode only: it waits while a window resizes, a menu is open or a scroller is dragged.
        RunLoop.main.add(timer, forMode: .default)
        scheduled = timer
    }

    /// A tick is due at once.
    private var immediate = false

    /// A tick is due (tests).
    package var due: Bool { scheduled != nil || immediate }

    // MARK: The tick

    /// What changed since the last tick, to each client: attention to all, windows and chats to
    /// those on screen, followed transcripts from their first changed entry.
    package func tick() {
        scheduled?.invalidate()
        scheduled = nil
        immediate = false
        let serving = clients.filter { !$0.holding }
        guard !serving.isEmpty else { return }
        let start = ContinuousClock.now
        defer {
            tickTimes.append(ContinuousClock.now - start)
            if tickTimes.count > 2000 { tickTimes.removeFirst(tickTimes.count - 2000) }
        }
        ticks += 1
        let sweeping = sweepNow
        sweepNow = false
        let chats = source.chats()
        // The companion's cards are looked at every tick, as they always were.
        if serving.contains(where: \.sweeps) { for id in attention.withItems { attention.mark(id) } }
        // A chat with a card open that closed: its items clear.
        for id in attention.withItems where chats[id] == nil { attention.mark(id) }
        let opened = attention.look(chats, everything: false)
        if !opened.isEmpty { for client in serving { client.sink.send(opened) } }
        for id in attention.withItems where !attentionObserved.contains(id) {
            guard let chat = chats[id] else { continue }
            attentionObserved.insert(id)
            withObservationTracking { _ = LinkAttention.items(chat) } onChange: { [weak self] in self?.observedAttention(id) }
        }
        let watching = serving.filter(\.onScreen)
        guard !watching.isEmpty else { return }

        for id in chats.keys where observed[false]?.contains(id) != true && observed[true]?.contains(id) != true { dirtyChats.insert(id) }
        let chatIds = Set(chats.keys)
        var windows: [Bool: [LinkWindow]] = [:]
        var metas: [Bool: [ChatMeta]] = [:]
        var extras: LinkExtras?
        /// Whether a client gets every chat this tick: it has nothing yet, or it's the companion's second.
        func wantsAll(_ client: Client) -> Bool { client.needsAll || (sweeping && client.sweeps) }
        for full in [false, true] {
            let group = watching.filter { $0.full == full }
            guard !group.isEmpty else { continue }
            let all = group.contains(where: wantsAll)
            if layoutDirty || all { windows[full] = observedWindows(full: full) }
            let ids = all ? chatIds : dirtyChats.intersection(chatIds)
            metas[full] = ids.sorted().compactMap { id in chats[id].map { observedMeta($0, id: id, full: full) } }
            if full, extrasDirty || all { extras = observedExtras(Array(chats.values)) }
        }
        // Followed transcripts: from the first entry changed since the last look.
        let followed = watching.reduce(into: Set<String>()) { $0.formUnion($1.follows) }
        var changedFrom: [String: Int] = [:]
        for id in followed {
            guard let chat = chats[id] else { continue }
            if let from = chat.transcript.linkDirtyFrom { changedFrom[id] = from }
            chat.transcript.linkDirtyFrom = nil
        }
        for client in watching {
            var tx: [TxSlice] = []
            for (id, sub) in client.subs {
                guard let chat = chats[id], sub.fresh || changedFrom[id] != nil || dirtyChats.contains(id) else { continue }
                let slice = self.slice(chat, sub, from: changedFrom[id])
                client.subs[id]?.fresh = false
                client.subs[id]?.known = Set(slice.order)
                tx.append(slice)
            }
            // A phone takes the chats that changed; the companion's second (or a first batch) takes them all.
            var chatsFor = metas[client.full] ?? []
            if !wantsAll(client) { chatsFor = chatsFor.filter { dirtyChats.contains($0.id) } }
            let batch = LinkBatch(windows: windows[client.full], chats: chatsFor, chatIds: chatIds, tx: tx, extras: client.full ? extras : nil)
            client.needsAll = false
            client.batches += 1
            client.sink.apply(batch)
        }
        layoutDirty = false
        extrasDirty = extrasDirty && extras == nil
        dirtyChats = []
        cache = cache.filter { followed.contains($0.key) }
    }

    private func observedMeta(_ chat: Chat, id: String, full: Bool) -> ChatMeta {
        guard observed[full]?.contains(id) != true else { return source.meta(chat, full: full) }
        observed[full]?.insert(id)
        let source = source
        return withObservationTracking { source.meta(chat, full: full) } onChange: { [weak self] in self?.observedChange(id, full: full) }
    }

    private func observedWindows(full: Bool) -> [LinkWindow] {
        guard layoutObserved[full] != true else { return source.windows(full: full) }
        layoutObserved[full] = true
        let source = source
        return withObservationTracking { source.windows(full: full) } onChange: { [weak self] in self?.observedLayout(full: full) }
    }

    private func observedExtras(_ chats: [Chat]) -> LinkExtras {
        guard !extrasObserved else { return source.extras(chats) }
        extrasObserved = true
        let source = source
        return withObservationTracking { source.extras(chats) } onChange: { [weak self] in self?.observedExtras() }
    }

    /// A followed transcript's window: its order, and its entries from the first changed one (all
    /// of them for a client that hasn't had it).
    private func slice(_ chat: Chat, _ sub: Client.Sub, from changed: Int?) -> TxSlice {
        let id = chat.id.uuidString
        let store = chat.transcript
        let epoch = "\(ObjectIdentifier(store).hashValue)"
        var made = cache[id].flatMap { $0.epoch == epoch ? $0.entries : nil } ?? [:]
        let entries = store.entries
        let lo = max(0, entries.count - sub.last)
        let window = entries[lo...]
        let order = window.map { $0.id.uuidString }
        let from = max(lo, changed ?? entries.count)
        var out: [LinkEntry] = []
        for (index, entry) in zip(window.indices, window) {
            let key = entry.id.uuidString
            let stale = index >= from || made[key] == nil
            if stale { made[key] = LinkSnapshot.entry(entry, folder: chat.folder, reading: ChatLinkReading(chat: chat)) }
            if sub.fresh || stale || !sub.known.contains(key), let wire = made[key] { out.append(wire) }
        }
        cache[id] = (epoch, made)
        let turnIds = Set(window.compactMap(\.turn))
        let turns = turnIds.sorted().compactMap { store.linkTurn($0).map(LinkSnapshot.turn) }
        return TxSlice(chatId: id, epoch: epoch, order: order, entries: out, full: sub.fresh, turns: turns, hasEarlier: lo > 0)
    }
}

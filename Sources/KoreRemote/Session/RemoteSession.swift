import Foundation

/// One connected phone, in memory: numbers what the host sends, tracks what the phone
/// acknowledged, holds back while too much is unacknowledged, and answers a repeated command with
/// the result it already had. Work arrives through `enqueue`, in order, from the main actor.
package actor RemoteSession {
    package nonisolated let id = UUID()
    package nonisolated let link: any RemoteLink

    /// What the host asks the session to do, in order.
    package enum Work: Sendable {
        /// State at one tick: sent as deltas, or held and merged while the phone is behind.
        case batch(RemoteBatch)
        /// Anything else for the phone (welcome, attention, a page, a chunk).
        case message(WireMessage)
        /// A command's outcome, kept for a repeat of the same command id.
        case result(id: String, ok: Bool, code: ResultCode?, message: String?)
        /// The phone went to the background: it has no state to keep up to date any more.
        case forget
        /// Stop following a chat's transcript.
        case close(chatId: String)
        /// Takes on what an earlier session of the same phone had sent, and sends it again.
        case adopt(Carry)
    }

    /// What a session leaves for the next connection of the same phone.
    package struct Carry: Sendable {
        package var projector: Projector
        package var unacknowledged: [WireMessage]
    }

    /// Unacknowledged bytes past which the session holds state back.
    package static let window = 512 * 1024
    /// Recent messages kept for a resume, at most.
    package static let ringSize = 256
    /// How long a command's result is kept for a repeat of its id.
    package static let dedupeFor: TimeInterval = 3600

    private var seq = 0
    private var unacked: [(seq: Int, bytes: Int, message: WireMessage)] = []
    private var projector = Projector()
    private var pending: RemoteBatch?
    private var results: [String: (at: Date, message: WireMessage)] = [:]
    private var running: Set<String> = []
    private let work: AsyncStream<Work>.Continuation
    private let queue: AsyncStream<Work>

    package init(link: any RemoteLink) {
        self.link = link
        (queue, work) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Performs queued work until the link closes.
    package func run() async {
        for await item in queue { perform(item) }
    }

    package nonisolated func enqueue(_ item: Work) { work.yield(item) }

    package nonisolated func end() {
        work.finish()
        link.close()
    }

    // MARK: Inbound

    /// What the host acts on, from one message the phone sent; nil for what the session handles
    /// itself (acknowledgements, a repeated command).
    package func receive(_ data: Data) -> WireMessage? {
        guard let envelope = try? Envelope.decode(data) else { return nil }
        switch envelope.message {
        case .ack(let n):
            acknowledge(n)
            return nil
        case .cmd(let id, _):
            if let kept = results[id], Date().timeIntervalSince(kept.at) < Self.dedupeFor {
                send(kept.message)
                return nil
            }
            // Already being carried out: its result goes out once.
            guard running.insert(id).inserted else { return nil }
            return envelope.message
        case .hello, .presence, .txOpen, .txMore, .txClose, .entryMore:
            return envelope.message
        default:
            // Host messages coming back are refused.
            return nil
        }
    }

    // MARK: Outbound

    private func perform(_ item: Work) {
        switch item {
        case .batch(let batch):
            pending = pending.map { $0.merged(with: batch) } ?? batch
            flush()
        case .message(let message): send(message)
        case .result(let id, let ok, let code, let text):
            let message = WireMessage.result(id: id, ok: ok, code: code, message: text)
            running.remove(id)
            results[id] = (Date(), message)
            if results.count > 1000 {
                let cutoff = Date().addingTimeInterval(-Self.dedupeFor)
                results = results.filter { $0.value.at > cutoff }
            }
            send(message)
        case .forget:
            projector = Projector()
            pending = nil
        case .close(let chatId):
            projector.close(chatId)
            pending?.tx.removeAll { $0.chatId == chatId }
        case .adopt(let carry):
            projector = carry.projector
            for message in carry.unacknowledged { send(message) }
        }
    }

    /// Sends held state while the phone keeps up.
    private func flush() {
        guard let batch = pending, !behind else { return }
        pending = nil
        for message in projector.apply(batch) { send(message) }
    }

    private func send(_ message: WireMessage) {
        seq += 1
        guard let data = try? Envelope(message, seq: seq).encoded() else { return }
        unacked.append((seq, data.count, message))
        if unacked.count > Self.ringSize * 4 { unacked.removeFirst(unacked.count - Self.ringSize * 4) }
        link.send(data)
    }

    private func acknowledge(_ n: Int) {
        unacked.removeAll { $0.seq <= n }
        flush()
    }

    /// Too much sent that the phone hasn't acknowledged.
    package var behind: Bool { unacked.reduce(0) { $0 + $1.bytes } > Self.window }

    /// Whether the phone has had its snapshot (else the next batch must hold every window and chat).
    package var started: Bool { projector.started || pending?.windows != nil }

    package var lastSeq: Int { seq }

    /// For the phone's next connection: what was sent, and what it hadn't acknowledged.
    package func carry() -> Carry {
        Carry(projector: projector, unacknowledged: unacked.suffix(Self.ringSize).map(\.message))
    }
}

extension RemoteBatch {
    /// Two ticks as one: the newer value of everything, and every entry either carried.
    package func merged(with newer: RemoteBatch) -> RemoteBatch {
        var chats = Dictionary(self.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for chat in newer.chats { chats[chat.id] = chat }
        var tx = Dictionary(self.tx.map { ($0.chatId, $0) }, uniquingKeysWith: { _, b in b })
        for slice in newer.tx {
            guard let older = tx[slice.chatId], older.epoch == slice.epoch else {
                tx[slice.chatId] = slice
                continue
            }
            var entries = Dictionary(older.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            for entry in slice.entries { entries[entry.id] = entry }
            var merged = slice
            merged.full = older.full || slice.full
            merged.entries = slice.order.compactMap { entries[$0] }
            tx[slice.chatId] = merged
        }
        return RemoteBatch(
            windows: newer.windows ?? windows, chats: Array(chats.values).sorted { $0.id < $1.id }, chatIds: newer.chatIds ?? chatIds,
            tx: Array(tx.values).sorted { $0.chatId < $1.chatId })
    }
}

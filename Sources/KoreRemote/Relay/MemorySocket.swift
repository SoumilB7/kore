import Foundation

/// One end of an in-memory WebSocket.
final class MemorySocket: RelaySocket, @unchecked Sendable {
    enum Ending { case normal, dropped }

    private let inbox: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private let peer = Locked<MemorySocket?>(nil)
    private let iterator: Locked<AsyncStream<Data>.Iterator?>
    private let state = Locked<(closed: Bool, peerEnded: Ending?)>((false, nil))

    private init() {
        (inbox, feed) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        iterator = Locked(inbox.makeAsyncIterator())
    }

    /// (the relay's end, the client's end)
    static func pair() -> (MemorySocket, MemorySocket) {
        let a = MemorySocket()
        let b = MemorySocket()
        a.peer.withLock { $0 = b }
        b.peer.withLock { $0 = a }
        return (a, b)
    }

    /// The relay hands its client a message.
    func deliver(_ data: Data) { peer.withLock { $0 }?.feed.yield(data) }

    /// The relay's next message from its client (nil once it's gone).
    func next() async -> Data? {
        var it = iterator.withLock { $0.take() }
        defer { iterator.withLock { $0 = it } }
        return await it?.next()
    }

    var endedByPeer: Ending? { state.withLock { $0.peerEnded } }

    // The client's side.
    func send(_ data: Data) async throws {
        guard !state.withLock({ $0.closed }), let other = peer.withLock({ $0 }) else { throw ChannelError.closed }
        other.feed.yield(data)
    }

    func receive() async throws -> Data {
        var it = iterator.withLock { $0.take() }
        defer { iterator.withLock { $0 = it } }
        guard let data = await it?.next() else { throw ChannelError.closed }
        return data
    }

    /// The client closes, saying goodbye.
    func close() { finish(.normal) }

    /// The connection drops, without a goodbye (tests).
    func drop() { finish(.dropped) }

    /// The relay puts this end out.
    func end() { finish(.normal) }

    private func finish(_ how: Ending) {
        let other = state.withLock { s -> MemorySocket? in
            guard !s.closed else { return nil }
            s.closed = true
            return peer.withLock { $0 }
        }
        feed.finish()
        other?.state.withLock { $0.peerEnded = $0.peerEnded ?? how }
        other?.feed.finish()
    }
}

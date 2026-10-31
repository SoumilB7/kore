import Foundation

/// Two ends of an in-memory byte pipe (tests).
package final class PipeChannel: ByteChannel {
    package let remoteHost: String
    private let inbox: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private let peer = Locked<PipeChannel?>(nil)
    private let iterator: Locked<AsyncStream<Data>.Iterator?>

    private init(remoteHost: String) {
        self.remoteHost = remoteHost
        (inbox, feed) = AsyncStream.makeStream()
        iterator = Locked(inbox.makeAsyncIterator())
    }

    package static func pair(phoneHost: String = "100.64.0.9") -> (mac: PipeChannel, phone: PipeChannel) {
        let mac = PipeChannel(remoteHost: phoneHost)
        let phone = PipeChannel(remoteHost: "100.64.0.1")
        mac.peer.withLock { $0 = phone }
        phone.peer.withLock { $0 = mac }
        return (mac, phone)
    }

    package func receive() async throws -> Data {
        var it = iterator.withLock { $0.take() }
        defer { iterator.withLock { $0 = it } }
        guard let data = await it?.next() else { throw ChannelError.closed }
        return data
    }

    package func send(_ data: Data) async throws {
        guard let other = peer.withLock({ $0 }) else { throw ChannelError.closed }
        other.feed.yield(data)
    }

    package func close() {
        let other = peer.withLock { p in
            defer { p = nil }
            return p
        }
        feed.finish()
        other?.peer.withLock { $0 = nil }
        other?.feed.finish()
    }
}

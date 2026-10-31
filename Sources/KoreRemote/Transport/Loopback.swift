import Foundation
import Synchronization

/// One end of a connection to a phone: what the host writes, and what arrives. A session never
/// knows which transport it's on.
package protocol RemoteLink: AnyObject, Sendable {
    /// Each message as it arrives, in order; ends when the link closes.
    var incoming: AsyncStream<Data> { get }
    func send(_ data: Data)
    func close()
}

/// Both ends of an in-memory link, for tests and storylines: what one end sends, the other
/// receives, in order.
package final class LoopbackLink: RemoteLink {
    package let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    private let peer = Mutex<LoopbackLink?>(nil)
    /// Bytes this end has sent, for flow and cost checks.
    private let sentBytes = Mutex(0)

    private init() {
        (incoming, inbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// A connected pair: (host's end, phone's end).
    package static func pair() -> (host: LoopbackLink, phone: LoopbackLink) {
        let host = LoopbackLink()
        let phone = LoopbackLink()
        host.peer.withLock { $0 = phone }
        phone.peer.withLock { $0 = host }
        return (host, phone)
    }

    package func send(_ data: Data) {
        sentBytes.withLock { $0 += data.count }
        peer.withLock { $0 }?.inbox.yield(data)
    }

    package func close() {
        let other = peer.withLock { p in
            defer { p = nil }
            return p
        }
        inbox.finish()
        other?.peer.withLock { $0 = nil }
        other?.inbox.finish()
    }

    package var bytesSent: Int { sentBytes.withLock { $0 } }
}

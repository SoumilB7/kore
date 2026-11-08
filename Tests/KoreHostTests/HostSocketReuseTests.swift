import Foundation
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// A client's link closes while its sources are still being let go, and the next connection is
/// handed the same descriptor number: what that one is sent is its own, none of it taken by the
/// closed one's watch.
@MainActor
@Suite("host socket reuse", .serialized, .timeLimit(.minutes(1)))
struct HostSocketReuseTests {
    @Test func aClosedLinksWatchNeverTakesTheNextConnectionsBytes() async throws {
        for _ in 0..<50 {
            let (old, oldPeer) = try Sockets.pair()
            var stolen = 0
            let first = HostSocket(fd: old)
            first.start(max: 1 << 20, frame: { _ in stolen += 1 }, ended: {})
            first.close()
            Sockets.closeFD(oldPeer)
            // The next connection: most often given the number just freed.
            let (next, nextPeer) = try Sockets.pair()
            var got = 0
            let second = HostSocket(fd: next)
            second.start(max: 1 << 20, frame: { _ in got += 1 }, ended: {})
            let frame = LinkFrame.frame(Data("hello".utf8))
            for _ in 0..<3 { _ = frame.withUnsafeBytes { write(nextPeer, $0.baseAddress!, $0.count) } }
            let end = ContinuousClock.now + .seconds(30)
            while got < 3, ContinuousClock.now < end { await Task.yield() }
            #expect(got == 3 && stolen == 0, "got \(got), the closed one took \(stolen)")
            second.close()
            Sockets.closeFD(nextPeer)
        }
    }
}

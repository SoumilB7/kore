import Foundation
import HostClient
import LinkProtocol
import Testing

/// The reconnect waits on a box that comes up and dies again: a link that dies within seconds of
/// opening keeps backing off; only one that stayed up `stableAfter` dials again from the shortest.
@MainActor
@Suite(.serialized)
struct ReconnectBackoffTests {
    final class Dials { var hosts: [FakeHost] = [] }

    func connection(_ dials: Dials, stable: Duration) -> HostConnection {
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            return client
        }
        connection.backoff = [.milliseconds(30), .seconds(5)]
        connection.stableAfter = stable
        return connection
    }

    /// Dial `n` answers, comes up, then the box goes.
    func upThenGone(_ dials: Dials, _ connection: HostConnection, _ n: Int, after: Duration = .zero) async {
        #expect(await until { dials.hosts.count == n })
        _ = await dials.hosts[n - 1].handshake(windows: [], chats: [])
        #expect(await until { connection.isOnline })
        try? await Task.sleep(for: after)
        dials.hosts[n - 1].close()
        #expect(await until { connection.phase == .offline })
    }

    @Test func aLinkThatDiesAtOnceKeepsBackingOff() async throws {
        let dials = Dials()
        let connection = connection(dials, stable: .seconds(30))
        connection.retain()
        await upThenGone(dials, connection, 1)
        await upThenGone(dials, connection, 2)
        // The second drop waits the next step (5 s), not the first again.
        try await Task.sleep(for: .milliseconds(600))
        #expect(dials.hosts.count == 2)
        connection.release()
    }

    @Test func aLinkThatStayedUpDialsAgainFromTheShortestWait() async throws {
        let dials = Dials()
        let connection = connection(dials, stable: .milliseconds(100))
        connection.retain()
        await upThenGone(dials, connection, 1)
        await upThenGone(dials, connection, 2, after: .milliseconds(300))
        #expect(await until(1) { dials.hosts.count == 3 })
        connection.release()
    }
}

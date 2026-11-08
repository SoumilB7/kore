import Foundation
import HostClient
import LinkProtocol
import Testing

/// The reconnect waits on a box that comes up and dies again: a link that dies within seconds of
/// opening keeps backing off; only one that stayed up `stableAfter` dials again from the shortest.
/// Time is the test's own (`VirtualClock`): how long a link stayed up is what the clock was moved,
/// not how fast a busy machine ran.
@MainActor
@Suite(.serialized)
struct ReconnectBackoffTests {
    final class Dials { var hosts: [FakeHost] = [] }

    func connection(_ dials: Dials, _ clock: VirtualClock, stable: Duration) -> HostConnection {
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            return client
        }
        connection.backoff = [.milliseconds(30), .seconds(5)]
        connection.stableAfter = stable
        connection.sleep = clock.sleep
        return connection
    }

    /// Dial `n` answers, comes up and stays up `up` on the clock, then the box goes.
    func upThenGone(_ dials: Dials, _ connection: HostConnection, _ clock: VirtualClock, _ n: Int, up: Duration = .zero) async {
        #expect(await until(30) { dials.hosts.count == n })
        _ = await dials.hosts[n - 1].handshake(windows: [], chats: [])
        #expect(await until(30) { connection.isOnline })
        if up > .zero {
            await clock.pending(connection.stableAfter)
            clock.advance(up)
        }
        dials.hosts[n - 1].close()
        #expect(await until(30) { connection.phase == .offline })
    }

    @Test func aLinkThatDiesAtOnceKeepsBackingOff() async throws {
        let dials = Dials()
        let clock = VirtualClock()
        let connection = connection(dials, clock, stable: .seconds(30))
        connection.retain()
        await upThenGone(dials, connection, clock, 1)
        await clock.pending(.milliseconds(30))
        clock.advance(.milliseconds(30))
        await upThenGone(dials, connection, clock, 2)
        // The second drop waits the next step (5 s), not the first again.
        await clock.pending(.seconds(5))
        #expect(clock.asked.filter { $0 == .milliseconds(30) || $0 == .seconds(5) } == [.milliseconds(30), .seconds(5)])
        clock.advance(.seconds(4))
        #expect(dials.hosts.count == 2)
        connection.release()
    }

    @Test func anUnreachableBoxStopsDiallingAfterTheLongestWaitsUntilAnEvent() async throws {
        let dials = Dials()
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            host.close()
            return client
        }
        connection.backoff = [.milliseconds(5), .milliseconds(10)]
        connection.retain()
        // The first dial, one at 5 ms, then `triesAtLongest` at 10 ms: then nothing.
        let tries = 2 + HostConnection.triesAtLongest
        #expect(await until { connection.parked })
        #expect(dials.hosts.count == tries)
        try await Task.sleep(for: .milliseconds(60))
        #expect(dials.hosts.count == tries)
        // A wake (or a network change) dials it again.
        connection.probe("wake")
        #expect(await until { dials.hosts.count == tries + 1 })
        connection.release()
    }

    @Test func aLinkThatStayedUpDialsAgainFromTheShortestWait() async throws {
        let dials = Dials()
        let clock = VirtualClock()
        let connection = connection(dials, clock, stable: .milliseconds(100))
        connection.retain()
        await upThenGone(dials, connection, clock, 1, up: .milliseconds(100))
        await clock.pending(.milliseconds(30))
        clock.advance(.milliseconds(30))
        await upThenGone(dials, connection, clock, 2, up: .milliseconds(300))
        // Up past `stableAfter`: the wait starts again from the shortest.
        await clock.pending(.milliseconds(30))
        clock.advance(.milliseconds(30))
        #expect(await until(30) { dials.hosts.count == 3 })
        #expect(clock.asked.filter { $0 == .milliseconds(30) || $0 == .seconds(5) } == [.milliseconds(30), .milliseconds(30)])
        connection.release()
    }
}

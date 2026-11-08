import Foundation
import HostClient
import LinkProtocol
import Testing

/// One `attach` per box per Mac: everything that holds a box's link (its windows, the Welcome,
/// History, probes) gets the same connection, even one taken before the last holder let go and
/// retained after. kore-host keeps the newest link per grant, so a second one here would knock
/// the first off (`bye replaced`) and the window would say another Kore holds the box.
@MainActor
@Suite(.serialized)
struct OneLinkPerBoxTests {
    final class Dials { var hosts: [FakeHost] = [] }

    func adopted(_ dials: Dials) -> (String, HostConnection) {
        let alias = "onelink-\(UUID().uuidString.prefix(6))"
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            return client
        }
        HostConnection.adopt(connection)
        return (alias, connection)
    }

    @Test func aWindowMadeWhileTheWelcomeHeldTheBoxSharesItsLink() async throws {
        let dials = Dials()
        let (alias, first) = adopted(dials)
        // The Welcome shows the box: it holds the link.
        let welcome = HostConnection.named(alias)
        welcome.retain()
        #expect(await until { dials.hosts.count == 1 })
        _ = await dials.hosts[0].handshake(windows: [], chats: [])
        #expect(await until { welcome.isOnline })
        // A folder opens: its window takes the link, then the Welcome lets go before the window
        // retains it (the link sleeps in between).
        let window = HostConnection.named(alias)
        welcome.release()
        #expect(await until { dials.hosts[0].closed })
        #expect(HostConnection.existing(alias) == nil)
        window.retain()
        #expect(await until { dials.hosts.count == 2 })
        _ = await dials.hosts[1].handshake(windows: [], chats: [])
        #expect(await until { window.isOnline })
        // A second window, History, a probe: the same link, no other dial.
        let second = HostConnection.named(alias)
        second.retain()
        let history = HostConnection.named(alias)
        history.retain()
        let probe = HostConnection.named(alias)
        probe.retain()
        probe.release()
        #expect(first === window && window === second && second === history && history === probe)
        #expect(HostConnection.existing(alias) === window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(dials.hosts.count == 2 && !dials.hosts[1].closed)
        #expect(window.phase == .online)
        for _ in 0..<3 { window.release() }
        #expect(HostConnection.existing(alias) == nil)
        #expect(await until { dials.hosts[1].closed })
    }

    @Test func aChangedGrantDialsNextTime() {
        let alias = "onelink-\(UUID().uuidString.prefix(6))"
        let made = HostConnection.named(alias, grant: "laptop")
        let again = HostConnection.named(alias, grant: "studio-mac")
        #expect(made === again && again.grant == "studio-mac")
        #expect(HostConnection.named(alias).grant == "studio-mac")
    }
}

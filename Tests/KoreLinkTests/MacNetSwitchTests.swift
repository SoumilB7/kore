import Foundation
import HostClient
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreLink

/// The phones' listener follows KoreNet's switch (step 5a): on and its tailnet chosen, it looks
/// (and opens with the Add device window); off, everything goes. Waits are for the switch's and
/// the listener's own events.
@MainActor
@Suite("mac net switch", .serialized, .timeLimit(.minutes(1)))
struct MacNetSwitchTests {
    @Test func theListenerFollowsTheSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macnet-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "macnet-switch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tailnet = StubTailnet()
        let env = NetEnvironment(
            installed: { (.state(.running), tailnet) }, sidecar: { _ in throw TailnetError.sidecar("none") }, secrets: MemorySecrets(),
            defaults: defaults, support: root, upgradeDial: { _, _, _ in throw TailnetError.sidecar("none") }, macName: { "MacBook" })
        let net = KoreNetSwitch(
            defaults: defaults, directory: NodeDirectory(defaults: defaults), rekeyer: NodeRekeyer(migration: NodeMigration(root: root, defaults: defaults)),
            global: false, connections: { [] }, environment: { env })
        let settled = Feed<String>()
        net.settled = { settled.send($0) }
        let mac = MacNetSwitch.follow(net, feed: LinkFeed(source: CountingSource(), taps: false))
        let changes = Feed<String>()
        mac.changed = { changes.send($0) }
        defer { mac.stop() }
        // Off: nothing read, nothing bound, even with the window open.
        mac.openAddWindow()
        #expect(!mac.listening && tailnet.listens == 0)
        mac.closeAddWindow()
        // On: the tailnet is chosen and the listener looks; the window opens the port.
        net.set(true)
        await settled.next { $0 == "chose" }
        await drainMain()
        #expect(mac.host.macName == "MacBook" && mac.host.book.url.path.hasPrefix(root.path))
        mac.openAddWindow()
        await changes.next { $0 == "listening" }
        #expect(mac.bound == ["100.64.0.1", "fd7a:115c:a1e0::1"])
        // Off again: the port closes.
        net.set(false)
        await changes.next { $0 == "closed" }
        #expect(!mac.listening && !mac.addOpen)
    }
}

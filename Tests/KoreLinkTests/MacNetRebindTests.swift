import Darwin
import Foundation
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreLink

/// KoreNet off, then on again (or Kore restarting in one process): the new listener's bind can
/// come while the old one's descriptors are still closing (their sources close them, on their own
/// queue, later on a busy Mac). It waits for that close, then binds; it never shares the port.
@Suite("mac net binds again", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacNetRebindTests {
    /// A tailnet on 127.0.0.1 whose binds are real, on one fixed port.
    final class Local: Tailnet {
        let port: UInt16
        init() throws {
            let probe = try Sockets.listenTCP("127.0.0.1", port: 0)
            port = try #require(Sockets.localPort(probe))
            Sockets.closeFD(probe)
        }
        func status() throws -> TailnetStatus { StubTailnet.status(ips: ["127.0.0.1"]) }
        func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
        func events() -> AsyncStream<TailnetEvent> { AsyncStream { $0.finish() } }
        func listen(port _: UInt16) throws -> [TailnetListenSocket] { [.tcp(try Sockets.listenTCP("127.0.0.1", port: port))] }
        func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
    }

    func listener(_ host: StubMacHost, _ changes: Feed<String>) -> MacNet {
        let net = MacNet(host: host, feed: LinkFeed(source: CountingSource(), taps: false), asks: DeviceAsks(), clock: TurnedClock().function)
        net.schedule = HandTimers().schedule
        net.background = { $0() }
        net.foreground = { work in MainActor.assumeIsolated { work() } }
        net.changed = { changes.send($0) }
        net.boxLinks = { [] }
        net.reachBox = { _ in {} }
        return net
    }

    @Test func offThenOnBindsThePortAgainOnceTheOldDescriptorsClose() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The wait's bound is not what's under test here: the close itself is.
        let bound = MacNet.closeWait
        MacNet.closeWait = 60
        defer { MacNet.closeWait = bound }
        let tailnet = try Local()
        let host = StubMacHost(folder: folder, tailnet: tailnet)
        defer { host.finish() }
        // A phone allowed: the port is wanted.
        let pixel = Phone()
        try host.book.update { devices in
            devices.append(DeviceRecord(
                id: pixel.id, name: pixel.name, kind: .phone, abilities: [.read, .ask], identityKey: pixel.key.publicKey,
                nodeKeys: [pixel.nodeKey], userId: 7, fqdn: "pixel.tail.ts.net.", raiseKey: pixel.raise.publicKey, issuedBy: host.device,
                added: Date()))
        }

        let firstChanges = Feed<String>()
        let first = listener(host, firstChanges)
        first.refresh()
        await firstChanges.next { $0 == "listening" }

        // Off, with its sources' queue held: the close of its descriptor waits, the port held.
        let queue = first.listenQueue
        queue.suspend()
        first.stop()
        #expect(throws: (any Error).self) { try Sockets.listenTCP("127.0.0.1", port: tailnet.port) }

        // On again: its bind is refused while the old descriptor is open, and it waits for it.
        let secondChanges = Feed<String>()
        let second = listener(host, secondChanges)
        defer { second.stop() }
        second.refresh()
        await secondChanges.next { $0 == "failed bind-EADDRINUSE" }
        #expect(!second.listening)

        // The old close runs: the new listener binds, without a retry step.
        queue.resume()
        await secondChanges.next { $0 == "listening" }
        #expect(second.listening && !second.retrying)
        // The port is the new listener's alone.
        #expect(throws: (any Error).self) { try Sockets.listenTCP("127.0.0.1", port: tailnet.port) }
    }

    /// A listener replaced (its switch still on, as at a restart in one process) never binds
    /// again, whatever asks it to look: the port can't be left held by one nobody stops.
    @Test func aRetiredListenerNeverTakesThePortAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tailnet = try Local()
        let host = StubMacHost(folder: folder, tailnet: tailnet)
        defer { host.finish() }
        let pixel = Phone()
        try host.book.update { devices in
            devices.append(DeviceRecord(
                id: pixel.id, name: pixel.name, kind: .phone, abilities: [.read, .ask], identityKey: pixel.key.publicKey,
                nodeKeys: [pixel.nodeKey], userId: 7, fqdn: "pixel.tail.ts.net.", raiseKey: pixel.raise.publicKey, issuedBy: host.device,
                added: Date()))
        }
        let changes = Feed<String>()
        let net = listener(host, changes)
        net.refresh()
        await changes.next { $0 == "listening" }
        net.retire()
        await changes.next { $0 == "closed" }
        net.refresh()
        net.phonesChanged()
        await drainMain()
        #expect(!net.listening)
    }
}

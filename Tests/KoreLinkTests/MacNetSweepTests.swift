import Darwin
import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// A tailnet whose `listen` binds real loopback TCP on every address its status gives (or hands
/// over a sidecar's socket, or fails as told), so `MacNet`'s real accept path runs.
final class LoopbackTailnet: Tailnet {
    struct Held {
        var ips = ["127.0.0.1"]
        /// The port `listen` binds (0: the kernel's pick, kept for the next binds).
        var port: UInt16 = 0
        var handoff: Int32?
        var failure: (any Error)?
        var bound: [Int32] = []
        var whoisCalls = 0
    }

    let held = Mutex(Held())
    let whoKey: String
    private let gate = Mutex<DispatchSemaphore?>(nil)

    init(whoKey: String = "nodekey:pixel") { self.whoKey = whoKey }

    /// WhoIs waits from now until `open()`.
    func hold() { gate.withLock { $0 = DispatchSemaphore(value: 0) } }
    func open() {
        guard let gate = gate.withLock({ g in defer { g = nil }; return g }) else { return }
        for _ in 0..<64 { gate.signal() }
    }

    func status() throws -> TailnetStatus { StubTailnet.status(ips: held.withLock { $0.ips }) }
    func whois(_ address: String) throws -> TailnetWhoIs {
        held.withLock { $0.whoisCalls += 1 }
        gate.withLock { $0 }?.wait()
        return StubTailnet.who(key: whoKey)
    }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { $0.finish() } }
    func listen(port: UInt16) throws -> [TailnetListenSocket] {
        // A handoff socket goes once: the listener closes what it was given, so a later listen
        // never gets a number closed already.
        let (ips, fixed, handoff, failure) = held.withLock { h in
            defer { h.handoff = nil }
            return (h.ips, h.port, h.handoff, h.failure)
        }
        if let failure { throw failure }
        if let handoff { return [.handoff(handoff)] }
        var made: [Int32] = []
        do {
            for ip in ips {
                let fd = try Sockets.listenTCP(ip, port: fixed == 0 ? (made.first.flatMap(Sockets.localPort) ?? 0) : fixed)
                made.append(fd)
            }
        } catch {
            made.forEach(Sockets.closeFD)
            throw error
        }
        held.withLock {
            if $0.port == 0 { $0.port = made.first.flatMap(Sockets.localPort) ?? 0 }
            $0.bound += made
        }
        return made.map { .tcp($0) }
    }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
    var port: UInt16 { held.withLock { $0.port } }

    /// A port free on both 127.0.0.1 and ::1, for the binds from now on.
    func reserveBothFamilies() throws {
        for _ in 0..<20 {
            let six = try Sockets.listenTCP("::1", port: 0)
            defer { Sockets.closeFD(six) }
            guard let port = Sockets.localPort(six), let four = try? Sockets.listenTCP("127.0.0.1", port: port) else { continue }
            Sockets.closeFD(four)
            held.withLock { $0.port = port }
            return
        }
        throw SocketError.failed("no port free on both", EADDRINUSE)
    }
}

/// Waits, yielding (never sleeping), until `check` holds; false after 5 s.
@MainActor
func eventually(_ check: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while !check() {
        guard ContinuousClock.now < end else { return false }
        await Task.yield()
    }
    return true
}

/// Whether the phone's session came up within 5 s. The wait runs in a task of its own, polled: a
/// welcome that never comes fails the test instead of hanging the run.
@MainActor
func comesUp(_ end: LiveEnd) async -> Bool {
    let up = Mutex(false)
    let waiter = Task.detached { await end.up(); up.withLock { $0 = true } }
    let came = await eventually { up.withLock { $0 } }
    if !came { waiter.cancel() }
    return came
}

/// The phone listener on this Mac, swept: each test fails on the code before its fix.
@Suite("korenet sweep, mac listener", .serialized)
@MainActor
struct MacNetSweepTests {
    @MainActor
    final class Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mns-\(UUID().uuidString)", isDirectory: true)
        let tailnet = LoopbackTailnet()
        let host: StubMacHost
        let net: MacNet
        let clock: TurnedClock
        var changes: [String] = []
        let phone = Phone()

        init(clock: TurnedClock = TurnedClock(), withPhone: Bool = true, moving: Bool = false) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            host = StubMacHost(folder: folder, tailnet: tailnet)
            self.clock = clock
            // A clock that moves a minute per look: the limiter turns no one away.
            let function: @Sendable () -> Date
            if moving {
                let minutes = Mutex(clock.now)
                function = {
                    minutes.withLock { now in
                        now = now.addingTimeInterval(61)
                        return now
                    }
                }
            } else {
                function = clock.function
            }
            net = MacNet(host: host, feed: LinkFeed(source: CountingSource(), taps: false), asks: DeviceAsks(), clock: function)
            net.changed = { [weak self] in self?.changes.append($0) }
            net.pushDevices = { _ in }
            if withPhone {
                let phone = phone
                let added = clock.now
                let device = host.device
                try host.book.update { devices in
                    devices.append(DeviceRecord(
                        id: phone.id, name: phone.name, kind: .phone, abilities: [.read, .ask], identityKey: phone.key.publicKey,
                        nodeKeys: [phone.nodeKey], userId: 7, fqdn: "pixel.tail.ts.net.", raiseKey: phone.raise.publicKey, issuedBy: device, added: added))
                }
            }
        }

        var macRecord: DeviceRecord {
            DeviceRecord(
                id: host.device, name: "MacBook", kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: host.key.publicKey,
                nodeKeys: ["nodekey:mac"], userId: 7, fqdn: "macbook.tail.ts.net.", added: Date(timeIntervalSince1970: 0))
        }

        func count(_ what: String) -> Int { changes.filter { $0 == what }.count }

        /// The phone over real TCP to the bound port.
        func dialPhone() throws -> LiveEnd {
            let fd = try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: tailnet.port)
            let book = DeviceBook(url: folder.appendingPathComponent("phone/devices.json"))
            let mac = macRecord
            try book.update { $0 = [mac] }
            let setup = NetSession.Client(
                local: NetLocal(device: phone.id, kind: .phone, nodeKey: phone.nodeKey, signer: phone.key), route: .tailnet,
                peer: NetPeerFacts(nodeKey: "nodekey:mac", userId: 7), book: book, server: host.device, service: "link")
            return LiveEnd(NetSession(fd: fd, role: .client(setup), clock: clock.function))
        }

        func finish() {
            net.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The sidecar's handoff socket at its end (the helper died): the listener closes, instead of
    /// a read source that stays readable firing on the accept queue forever.
    @Test func handoffEOFClosesTheListenerInsteadOfSpinning() async throws {
        let rig = try Rig(withPhone: false)
        defer { rig.finish() }
        let (mine, helper) = try Sockets.pair()
        rig.tailnet.held.withLock { $0.handoff = mine }
        rig.net.openAddWindow()
        #expect(await eventually { rig.count("listening") == 1 })
        Sockets.closeFD(helper)
        #expect(await eventually { rig.count("closed") == 1 }, "the accept source is still spinning on EOF")
        #expect(!rig.net.listening)
    }

    /// KoreNet off while 16 handshakes were under way, then on again: a phone still gets its
    /// welcome (the handshake count started again at the stop).
    @Test func stopDuringHandshakesDoesNotLockOutLaterPhones() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.net.refresh()
        #expect(await eventually { rig.count("listening") == 1 })
        var halves: [Int32] = []
        defer { halves.forEach(Sockets.closeFD) }
        for _ in 0..<MacNet.maxHandshakes {
            let (a, b) = try Sockets.pair()
            halves.append(a)
            rig.net.greet(b, remote: "100.64.0.9", whois: StubTailnet.who(key: rig.phone.nodeKey))
        }
        #expect(rig.net.handshaking == MacNet.maxHandshakes)
        rig.net.stop()
        #expect(rig.net.handshaking == 0)
        rig.net.refresh()
        #expect(await eventually { rig.count("listening") == 2 })
        let end = try rig.dialPhone()
        #expect(await comesUp(end), "a phone after stop() never got its welcome: the handshake count leaked")
    }

    /// Tailscale added an address that overlaps the one held: the old sockets go first, so the
    /// new bind isn't refused by this Mac's own listener (which used to leave none at all).
    @Test func anOverlappingRebindTakesTheNewAddresses() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try rig.tailnet.reserveBothFamilies()
        rig.net.refresh()
        #expect(await eventually { rig.count("listening") == 1 })
        #expect(rig.net.bound == ["127.0.0.1"])
        rig.tailnet.held.withLock { $0.ips = ["127.0.0.1", "::1"] }
        rig.net.refresh()
        #expect(await eventually { rig.count("listening") == 2 }, "\(rig.changes)")
        #expect(rig.net.listening && rig.net.bound == ["127.0.0.1", "::1"])
        // And it answers there.
        let end = try rig.dialPhone()
        #expect(await comesUp(end))
    }

    /// A rebind that fails for any other reason keeps the working listener.
    @Test func aFailedRebindKeepsTheWorkingListener() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.net.refresh()
        #expect(await eventually { rig.count("listening") == 1 })
        rig.tailnet.held.withLock {
            $0.ips = ["127.0.0.1", "::1"]
            $0.failure = TailnetError.sidecar("helper busy")
        }
        rig.net.refresh()
        #expect(await eventually { rig.count("kept") == 1 }, "\(rig.changes)")
        #expect(rig.net.listening && rig.net.bound == ["127.0.0.1"] && rig.count("closed") == 0, "\(rig.changes)")
        let end = try rig.dialPhone()
        #expect(await comesUp(end))
    }

    /// WhoIs lookups under way count against the 16 handshakes: a flood waiting on a slow
    /// LocalAPI is closed at the door, not queued as threads.
    @Test func whoisUnderWayCountsAgainstTheRoom() async throws {
        let rig = try Rig(moving: true)
        defer {
            rig.tailnet.open()
            rig.finish()
        }
        rig.tailnet.hold()
        rig.net.refresh()
        #expect(await eventually { rig.count("listening") == 1 })
        var clients: [Int32] = []
        defer { clients.forEach(Sockets.closeFD) }
        var refused = 0
        for i in 0..<(MacNet.maxHandshakes + 4) {
            let fd = try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: rig.tailnet.port)
            clients.append(fd)
            if i < MacNet.maxHandshakes {
                #expect(await eventually { rig.tailnet.held.withLock { $0.whoisCalls } == i + 1 })
            } else {
                Sockets.setNonBlocking(fd)
                if await eventually({ (try? Sockets.read(fd, max: 16))?.isEmpty == true }) { refused += 1 }
            }
        }
        #expect(refused == 4)
        #expect(rig.tailnet.held.withLock { $0.whoisCalls } == MacNet.maxHandshakes && rig.net.whoising == MacNet.maxHandshakes)
    }
}

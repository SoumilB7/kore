import Darwin
import Foundation
import HostClient
import KoreNet
import KoreTrust
import Synchronization
import Tailnet
import Testing

@testable import KoreLink

/// A tailnet whose status and binds fail as a test says: `failures` refuse the next binds one
/// each, `always` refuses every bind, `statusFailure` every status read. A bind that goes
/// through binds nothing (a test hands connections to `MacNet.greet` itself).
final class FlakyTailnet: Tailnet {
    struct Held {
        var failures: [any Error] = []
        var always: (any Error)?
        var statusFailure: (any Error)?
        var listens = 0
    }

    let held = Mutex(Held())
    var listens: Int { held.withLock { $0.listens } }

    func status() throws -> TailnetStatus {
        if let failure = held.withLock({ $0.statusFailure }) { throw failure }
        return StubTailnet.status()
    }
    func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { $0.finish() } }
    func listen(port: UInt16) throws -> [TailnetListenSocket] {
        let failure = held.withLock { h -> (any Error)? in
            h.listens += 1
            if let always = h.always { return always }
            return h.failures.isEmpty ? nil : h.failures.removeFirst()
        }
        if let failure { throw failure }
        return []
    }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }

    static let notAvailable = SocketError.failed("bind 100.64.0.1:47470", EADDRNOTAVAIL)
    static let inUse = SocketError.failed("bind 100.64.0.1:47470", EADDRINUSE)
}

/// The phones' listener heals by itself (2026-11-15: a failed bind left the Mac with no port
/// until something else happened to look): a failed look is retried at 1, 5, 30 s and 2 min, then
/// waits for an event; every failure is logged as one word. And at launch, with no window
/// holding a link, a box owed a push is dialled once for it. Hand timers, no sleeps.
@Suite("mac net heals", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacNetHealTests {
    @MainActor
    final class Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnh-\(UUID().uuidString)", isDirectory: true)
        let tailnet = FlakyTailnet()
        let host: StubMacHost
        let net: MacNet
        let timers = HandTimers()
        var changes: [String] = []
        let changed = Feed<String>()
        /// The boxes dialled for a push, by key, and the holds let go.
        var reached: [String] = []
        var released: [String] = []

        init(phone: Bool = true) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            host = StubMacHost(folder: folder, tailnet: tailnet)
            net = MacNet(host: host, feed: LinkFeed(source: CountingSource(), taps: false), asks: DeviceAsks(), clock: TurnedClock().function)
            net.schedule = timers.schedule
            net.background = { $0() }
            net.foreground = { work in MainActor.assumeIsolated { work() } }
            net.changed = { [weak self] in
                self?.changes.append($0)
                self?.changed.send($0)
            }
            net.boxLinks = { [] }
            net.reachBox = { [weak self] key in
                self?.reached.append(key)
                return { [weak self] in self?.released.append(key) }
            }
            if phone {
                let device = host.device
                let pixel = Phone()
                try host.book.update { devices in
                    devices.append(DeviceRecord(
                        id: pixel.id, name: pixel.name, kind: .phone, abilities: [.read, .ask], identityKey: pixel.key.publicKey,
                        nodeKeys: [pixel.nodeKey], userId: 7, fqdn: "pixel.tail.ts.net.", raiseKey: pixel.raise.publicKey, issuedBy: device,
                        added: Date()))
                }
            }
        }

        func count(_ what: String) -> Int { changes.filter { $0 == what }.count }

        /// An enrolled box on KoreNet, as Kore keeps it; `pushed` what it last took.
        @discardableResult
        func box(pushed: NodeDirectory.Pushed? = nil) -> DeviceRecord {
            let box = DeviceRecord(
                id: UUID(), name: "mybox", kind: .box, abilities: [.read, .ask, .run], identityKey: SoftwareIdentity().publicKey,
                nodeKeys: ["ssh", "nodekey:box"], userId: 7, fqdn: "mybox.tail.ts.net.", added: Date())
            host.directory.upsert(.init(device: box.id, name: "mybox", ssh: "mybox", nodeKey: "nodekey:box", identityKey: box.identityKey, enrolled: true))
            if let pushed { host.directory.notePushed(pushed, device: box.id) }
            return box
        }

        func finish() {
            net.stop()
            host.finish()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Retries

    @Test func aBindThatFailsIsRetriedAndHeals() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.tailnet.held.withLock { $0.failures = [FlakyTailnet.notAvailable] }
        rig.net.refresh()
        #expect(rig.changes == ["failed bind-EADDRNOTAVAIL"] && !rig.net.listening && rig.net.retrying)
        rig.timers.advance(0.9)
        #expect(rig.tailnet.listens == 1)
        rig.timers.advance(0.1)
        #expect(rig.net.listening && rig.net.binds == 1 && !rig.net.retrying)
        #expect(rig.changes == ["failed bind-EADDRNOTAVAIL", "listening"])
        // Healed: nothing more is scheduled.
        rig.timers.advance(10_000)
        #expect(rig.tailnet.listens == 2)
    }

    @Test func theRetriesStopAfterTheirStepsAndAnEventStartsThemAgain() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.tailnet.held.withLock { $0.always = FlakyTailnet.notAvailable }
        rig.net.refresh()
        var tries: [Int] = []
        for step in MacNet.retrySteps {
            rig.timers.advance(step)
            tries.append(rig.tailnet.listens)
        }
        #expect(MacNet.retrySteps == [1, 5, 30, 120] && tries == [2, 3, 4, 5])
        #expect(rig.count("waits") == 1 && !rig.net.retrying)
        // No poll: an hour on, nothing tried.
        rig.timers.advance(3600)
        #expect(rig.tailnet.listens == 5)
        // An event (Tailscale's bus, wake, a network change): the steps begin again.
        rig.net.refresh()
        #expect(rig.tailnet.listens == 6 && rig.net.retrying)
        rig.timers.advance(1)
        #expect(rig.tailnet.listens == 7)
    }

    @Test func noPhoneAllowedMeansNoRetry() throws {
        let rig = try Rig(phone: false)
        defer { rig.finish() }
        rig.tailnet.held.withLock { $0.always = FlakyTailnet.notAvailable }
        rig.net.refresh()
        #expect(rig.tailnet.listens == 0 && !rig.net.retrying)
    }

    @Test func anUnreadableStatusKeepsTheListenerAndRetries() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.net.refresh()
        #expect(rig.net.listening)
        rig.tailnet.held.withLock { $0.statusFailure = TailnetError.http(503) }
        rig.net.refresh()
        #expect(rig.net.listening && rig.count("closed") == 0 && rig.count("kept") == 1)
        #expect(rig.changes.contains("failed status-localapi-http-503") && rig.net.retrying)
        rig.tailnet.held.withLock { $0.statusFailure = nil }
        rig.timers.advance(1)
        #expect(rig.net.listening && !rig.net.retrying && rig.count("closed") == 0)
    }

    @Test func tailscaleStoppedClosesWithoutRetrying() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let stopped = StubTailnet(StubTailnet.status(.stopped, ips: []))
        rig.host.tailnet = stopped
        rig.net.refresh()
        #expect(!rig.net.listening && !rig.net.retrying && !rig.changes.contains { $0.hasPrefix("failed") })
    }

    /// The port held (this Mac's own sockets still closing, or Tailscale moved its addresses):
    /// it looks again once they're closed, at once; held still, the retries take over.
    @Test func anAddressInUseLooksAgainOnceItsOwnSocketsClose() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.tailnet.held.withLock { $0.failures = [FlakyTailnet.inUse] }
        rig.net.refresh()
        await rig.changed.next { $0 == "listening" }
        #expect(rig.changes == ["failed bind-EADDRINUSE", "listening"] && rig.tailnet.listens == 2)
        // Held by someone else: one look more, then the steps.
        rig.tailnet.held.withLock { $0.always = FlakyTailnet.inUse }
        rig.net.stop()
        rig.changes = []
        rig.net.refresh()
        // The first part's failure, then this part's two.
        for _ in 0..<3 { await rig.changed.next { $0 == "failed bind-EADDRINUSE" } }
        await drainMain()
        #expect(rig.tailnet.listens == 4 && rig.net.retrying, "\(rig.changes)")
    }

    // MARK: Why, in one word

    struct Silent: Error, CustomStringConvertible { var description: String { "" } }

    @Test func everyFailureSaysWhyInOneWord() throws {
        let errors: [any Error] = [
            SocketError.failed("bind 100.64.0.1:47470", EADDRNOTAVAIL), SocketError.failed("bind [fd7a::1]:47470", EADDRINUSE),
            SocketError.failed("", 0), SocketError.failed("bind", 9999), SocketError.wildcard(""), SocketError.badAddress(""), SocketError.closed,
            SocketError.timedOut, SocketError.notThisUser, TailnetError.unavailable(.absent), TailnetError.unauthorized, TailnetError.http(503),
            TailnetError.malformed(""), TailnetError.notTailnet(""), TailnetError.sidecar(""), TailnetError.notRunning(.stopped), Silent(),
            NSError(domain: "", code: 0),
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        for error in errors {
            let word = MacNet.cause(error)
            #expect(!word.isEmpty && word.count <= 48 && word.unicodeScalars.allSatisfy(allowed.contains), "\(error) → \"\(word)\"")
        }
        #expect(MacNet.cause(errors[0]) == "bind-EADDRNOTAVAIL" && MacNet.cause(errors[1]) == "bind-EADDRINUSE")
        #expect(MacNet.cause(TailnetError.notRunning(.stopped)) == "tailscale-Stopped" && MacNet.cause(SocketError.failed("bind", 9999)) == "bind-errno-9999")
        #expect(MacNet.word("") == "unknown" && MacNet.word("--") == "unknown")
    }

    /// A socket on an address that isn't this node's: refused, closed, and said.
    @Test func aSocketOnAnotherAddressIsAProblem() throws {
        final class Wrong: Tailnet {
            func status() throws -> TailnetStatus { StubTailnet.status(ips: ["100.64.0.1"]) }
            func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
            func events() -> AsyncStream<TailnetEvent> { AsyncStream { $0.finish() } }
            func listen(port: UInt16) throws -> [TailnetListenSocket] { [.tcp(try Sockets.listenTCP("127.0.0.1", port: 0))] }
            func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
        }
        let found = MacNet.bind(Wrong(), had: [], listening: false)
        #expect(found.problem == "not-own-address" && found.made == nil && !found.clash)
        #expect(MacNet.bind(FlakyTailnet(), had: ["100.64.0.1", "fd7a:115c:a1e0::1"], listening: true).problem == nil)
    }

    // MARK: At launch, a box owed a push

    @Test func atLaunchABoxOwedAPushIsDialledOnceAndLetGoWhenItTakesIt() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = rig.box()
        // No window, no link: the identity is read at the first look.
        rig.net.refresh()
        #expect(rig.net.device == rig.host.device && rig.reached == ["mybox"])
        // Its link comes up and takes the push: the hold goes.
        let link = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(link)
        let set = try #require(link.posted.first)
        #expect(set.merge == true && set.records.count == 1)
        rig.net.took(DevicesWire.Result(id: set.id, ok: true, rev: 3))
        #expect(rig.released == ["mybox"])
        // Looks later (events) don't dial again.
        rig.net.refresh()
        rig.timers.advance(60)
        #expect(rig.reached == ["mybox"])
    }

    @Test func atLaunchABoxThatNeverAnswersIsLetGoAfter30Seconds() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.box()
        rig.net.refresh()
        #expect(rig.reached == ["mybox"] && rig.released.isEmpty)
        rig.timers.advance(MacNet.reachFor)
        #expect(rig.released == ["mybox"])
    }

    @Test func atLaunchACaughtUpBoxIsNotDialled() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let rev = try rig.host.book.read().rev
        rig.box(pushed: .init(by: rig.host.device, bookRev: rev, boxRev: 3))
        rig.net.refresh()
        #expect(rig.net.device == rig.host.device && rig.reached.isEmpty)
    }

    @Test func atLaunchAPausedOrOffBoxIsNotDialled() throws {
        let rig = try Rig()
        defer {
            NetPauses.shared.set("paused-box", paused: false)
            rig.finish()
        }
        let off = rig.box()
        rig.host.directory.update { $0[off.id.uuidString.lowercased()]?.on = false }
        let paused = DeviceRecord(
            id: UUID(), name: "paused", kind: .box, abilities: [.read], identityKey: SoftwareIdentity().publicKey, nodeKeys: ["ssh"], userId: nil, fqdn: "",
            added: Date())
        rig.host.directory.upsert(.init(device: paused.id, name: "paused", ssh: "paused-box", nodeKey: "nodekey:p", identityKey: paused.identityKey, enrolled: true))
        NetPauses.shared.set("paused-box", paused: true)
        rig.net.refresh()
        #expect(rig.reached.isEmpty)
    }

    /// No phone and no window: no port, but the identity is still read and an owed box dialled
    /// (a phone removed while the box was away is a push it owes).
    @Test func atLaunchWithNoPortAnOwedBoxIsStillDialled() throws {
        let rig = try Rig(phone: false)
        defer { rig.finish() }
        rig.box()
        rig.net.refresh()
        #expect(!rig.net.listening && rig.reached == ["mybox"])
    }
}

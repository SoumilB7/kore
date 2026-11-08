import Foundation
import KoreNet
import KoreTrust
@testable import LinkProtocol
import Synchronization
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// A tailnet that answers from what a test set: no LocalAPI, no sockets, no network.
final class StubTailnet: Tailnet {
    let state = Mutex<(status: TailnetStatus, whois: [String: TailnetWhoIs], listens: Int)>((StubTailnet.status(), [:], 0))

    init(_ status: TailnetStatus = StubTailnet.status()) { state.withLock { $0.status = status } }

    var listens: Int { state.withLock { $0.listens } }
    func set(_ status: TailnetStatus) { state.withLock { $0.status = status } }

    func status() throws -> TailnetStatus { state.withLock { $0.status } }
    func whois(_ address: String) throws -> TailnetWhoIs {
        guard let who = state.withLock({ $0.whois[address] }) else { throw TailnetError.notTailnet(address) }
        return who
    }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { $0.finish() } }
    /// Counted; nothing bound (a test hands connections to `MacNet.greet` itself).
    func listen(port: UInt16) throws -> [TailnetListenSocket] {
        state.withLock { $0.listens += 1 }
        return []
    }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }

    static func status(_ state: BackendState = .running, ips: [String] = ["100.64.0.1", "fd7a:115c:a1e0::1"], user: Int64? = 7, tags: [String]? = nil) -> TailnetStatus {
        TailnetStatus(
            backendState: state, selfNode: .init(publicKey: "nodekey:mac", tailscaleIPs: ips, userID: user, tags: tags, dnsName: "macbook.tail.ts.net."))
    }

    static func who(key: String, user: Int64 = 7, login: String = "me@example.com", name: String = "pixel.tail.ts.net.", tags: [String] = [], cap: String? = nil) -> TailnetWhoIs {
        let tagText = tags.map { "\"\($0)\"" }.joined(separator: ",")
        let capText = cap.map { #","CapMap":{"\#(KoreCapDomain)":[\#($0)]}"# } ?? ""
        let json = #"{"Node":{"Key":"\#(key)","Name":"\#(name)","Tags":[\#(tagText)]},"UserProfile":{"ID":\#(user),"LoginName":"\#(login)"}\#(capText)}"#
        return try! JSONDecoder().decode(TailnetWhoIs.self, from: Data(json.utf8))
    }
}

/// KoreNet on a test Mac: its book in a scratch folder, its identity in memory.
@MainActor
final class StubMacHost: MacNetHost {
    var tailnet: (any Tailnet)?
    let book: DeviceBook
    let macName = "MacBook"
    nonisolated let device = UUID()
    nonisolated let key = SoftwareIdentity()

    init(folder: URL, tailnet: (any Tailnet)?) {
        book = DeviceBook(url: folder.appendingPathComponent("devices.json"))
        self.tailnet = tailnet
    }

    func identityReader() -> (@Sendable () throws -> (device: UUID, signer: any IdentitySigner))? {
        let (device, key) = (device, key)
        return { (device, key) }
    }
}

/// A phone's keys.
struct Phone {
    var id = UUID()
    var name = "Pixel 9"
    var key = SoftwareIdentity()
    var raise = SoftwareIdentity()
    var nodeKey = "nodekey:pixel"
    var address = "100.64.0.9"
}

/// Timers a test fires by hand.
@MainActor
final class HandTimers {
    private var due: [(at: TimeInterval, work: @MainActor () -> Void, live: Bool)] = []
    private(set) var now: TimeInterval = 0

    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void {
        { [weak self] seconds, work in
            guard let self else { return {} }
            let index = self.due.count
            self.due.append((self.now + seconds, work, true))
            return { [weak self] in self?.due[index].live = false }
        }
    }

    /// Moves time on, running what came due.
    func advance(_ seconds: TimeInterval) {
        now += seconds
        for index in due.indices where due[index].live && due[index].at <= now {
            due[index].live = false
            due[index].work()
        }
    }
}

/// A Mac serving phones over socketpairs: `MacNet` with a stub tailnet, its own feed, cards
/// answered by hand, timers turned by hand, audit lines kept.
@MainActor
final class MacRig {
    let folder: URL
    let tailnet = StubTailnet()
    let host: StubMacHost
    let feed = LinkFeed(source: CountingSource(), taps: false)
    let asks = DeviceAsks()
    let net: MacNet
    let clock = TurnedClock()
    let timers = HandTimers()
    var shown: [DeviceCardInfo] = []
    var pushed: [[DeviceRecord]] = []
    var audits: [String] = []
    /// Cards as they're shown, cards taken away, audit lines, and the net's changes.
    let cards = Feed<String>()
    let dismissed = Feed<Int>()
    let audited = Feed<String>()
    let changes = Feed<String>()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("macnet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host = StubMacHost(folder: folder, tailnet: tailnet)
        asks.schedule = timers.schedule
        net = MacNet(host: host, feed: feed, asks: asks, clock: clock.function)
        asks.present = { [weak self] info, _ in
            self?.shown.append(info)
            self?.cards.send(info.title)
        }
        asks.dismiss = { [weak self] in self?.dismissed.send(1) }
        net.changed = { [weak self] in self?.changes.send($0) }
        net.schedule = timers.schedule
        net.background = { $0() }
        net.foreground = { work in MainActor.assumeIsolated { work() } }
        net.pushDevices = { [weak self] in self?.pushed.append($0) }
        NetAudit.watch = { [weak self] line in
            self?.audits.append(line)
            self?.audited.send(line)
        }
        net.learn(status: StubTailnet.status(), identity: (host.device, host.key))
    }

    func finish() {
        net.stop()
        NetAudit.watch = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func audits(_ event: String) -> [String] { audits.filter { $0.hasPrefix(event + " ") || $0 == event } }

    /// The next audit line of `event`.
    @discardableResult
    func audit(_ event: String) async -> String { await audited.next { $0.hasPrefix(event + " ") || $0 == event } }

    /// The next change of the net named `what`.
    func change(_ what: String) async { await changes.next { $0 == what } }

    /// The Mac as a phone pins it.
    var macRecord: DeviceRecord {
        DeviceRecord(
            id: host.device, name: "MacBook", kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: host.key.publicKey,
            nodeKeys: ["nodekey:mac"], userId: 7, fqdn: "macbook.tail.ts.net.", added: Date(timeIntervalSince1970: 0))
    }

    /// The phone's record as an Allow would keep it.
    func record(_ phone: Phone, paused: Bool = false) -> DeviceRecord {
        var record = DeviceRecord(
            id: phone.id, name: phone.name, kind: .phone, abilities: [.read, .ask], identityKey: phone.key.publicKey, nodeKeys: [phone.nodeKey],
            userId: 7, fqdn: "pixel.tail.ts.net.", raiseKey: phone.raise.publicKey, issuedBy: host.device, added: clock.now)
        if paused { record.paused = true }
        return record
    }

    func allow(_ phone: Phone, paused: Bool = false) throws {
        let made = record(phone, paused: paused)
        try host.book.update { $0.append(made) }
    }

    /// The phone dials: the Mac's half goes to `MacNet.greet` as an accepted connection would;
    /// the phone's half runs on its own queue, fed by its socket.
    func dial(_ phone: Phone, whois: TailnetWhoIs? = nil, enroll: Bool = false, resume: NetControl.Resume? = nil) throws -> LiveEnd {
        let (a, b) = try Sockets.pair()
        let book = DeviceBook(url: folder.appendingPathComponent("phone-\(phone.id.uuidString)-\(UUID().uuidString)/devices.json"))
        try book.update { $0 = [macRecord] }
        let local = NetLocal(device: phone.id, kind: .phone, nodeKey: phone.nodeKey, signer: phone.key)
        var setup = NetSession.Client(
            local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: "nodekey:mac", userId: 7), book: book, server: host.device, service: "link",
            resume: resume)
        if enroll { setup.enroll = .init(name: phone.name, kind: .phone, identityKey: phone.key.publicKey, raiseKey: phone.raise.publicKey) }
        let end = LiveEnd(NetSession(fd: a, role: .client(setup), clock: clock.function))
        net.greet(b, remote: phone.address, whois: whois ?? StubTailnet.who(key: phone.nodeKey))
        return end
    }
}

extension NetSession.State {
    var peer: NetPeer? {
        if case .established(let p) = self { return p }
        return nil
    }
}

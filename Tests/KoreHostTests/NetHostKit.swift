import Foundation
import KoreNet
import KoreTrust
import Synchronization
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// A tailnet that answers from what a test set: no LocalAPI, no sockets.
final class FakeTailnet: Tailnet {
    let state = Mutex<(status: TailnetStatus, whois: [String: TailnetWhoIs])>((TailnetStatus(backendState: .stopped, selfNode: nil), [:]))

    init(status: TailnetStatus) { state.withLock { $0.status = status } }

    func status() throws -> TailnetStatus { state.withLock { $0.status } }
    func whois(_ address: String) throws -> TailnetWhoIs {
        guard let who = state.withLock({ $0.whois[address] }) else { throw TailnetError.notTailnet(address) }
        return who
    }
    /// Bus subscriptions held now (a real bus stays open until its reader lets go).
    let buses = Mutex(0)
    func events() -> AsyncStream<TailnetEvent> {
        buses.withLock { $0 += 1 }
        return AsyncStream { continuation in
            continuation.onTermination = { [self] _ in self.buses.withLock { $0 -= 1 } }
        }
    }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }

    static func status(_ state: BackendState = .stopped, ips: [String] = ["100.64.0.2"], user: Int64? = 7, tags: [String]? = nil) -> TailnetStatus {
        TailnetStatus(backendState: state, selfNode: .init(publicKey: "nodekey:box", tailscaleIPs: ips, userID: user, tags: tags))
    }

    static func who(key: String, user: Int64 = 7, login: String = "me@example.com", name: String = "mac-1.tail.ts.net.", tags: [String] = [], cap: String? = nil) -> TailnetWhoIs {
        let tagText = tags.map { "\"\($0)\"" }.joined(separator: ",")
        let capText = cap.map { #","CapMap":{"\#(KoreCapDomain)":[\#($0)]}"# } ?? ""
        let json = #"{"Node":{"Key":"\#(key)","Name":"\#(name)","Tags":[\#(tagText)]},"UserProfile":{"ID":\#(user),"LoginName":"\#(login)"}\#(capText)}"#
        return try! JSONDecoder().decode(TailnetWhoIs.self, from: Data(json.utf8))
    }
}

/// A clock tests move by hand.
final class HandClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Journal lines one test saw (its own watcher: suites run side by side).
final class Journal: Sendable {
    private let seen = Mutex<[String]>([])
    private let id = Mutex<UUID?>(nil)
    init() { id.withLock { $0 = HostJournal.watch { [weak self] line in self?.seen.withLock { $0.append(line) } } } }
    deinit { if let id = id.withLock({ $0 }) { HostJournal.unwatch(id) } }
    var lines: [String] { seen.withLock { $0 } }
    func audit(_ event: String) -> [String] { lines.filter { $0.hasPrefix("audit \(event)") } }
}

/// A box daemon in a scratch folder with KoreNet in front of it (a fake tailnet; no port bound),
/// and Macs, phones and boxes dialling it over socketpairs.
@MainActor
final class NetRig {
    let rig: HostRig
    let net: HostNet
    let tailnet: FakeTailnet
    let clock = HandClock()
    let identity: BoxIdentity
    var store: DeviceStore { rig.host.devices }

    init(status: TailnetStatus = FakeTailnet.status()) throws {
        rig = try HostRig()
        rig.host.now = { [clock] in clock.now }
        try rig.host.start()
        identity = try BoxIdentity.loadOrCreate(rig.paths)
        // `kore-host join` just ran: the claim window is open.
        try NetJoin.mark(rig.paths, at: clock.now)
        tailnet = FakeTailnet(status: status)
        let made = tailnet
        rig.host.makeTailnet = { made }
        net = try #require(rig.host.net)
        net.join(tailnet)
    }

    func finish() { rig.finish() }

    /// The box as a device's own book holds it.
    var boxRecord: DeviceRecord {
        DeviceRecord(
            id: identity.device, name: "box-1", kind: .box, abilities: [.read], identityKey: identity.signer.publicKey, nodeKeys: ["nodekey:box"],
            userId: 7, fqdn: "box-1.tail.ts.net.", added: clock.now)
    }

    /// A device's record as the box would hold it.
    func record(_ device: Device, owner: Bool? = nil, nodeKeys: [String]? = nil, issuedBy: UUID? = nil) -> DeviceRecord {
        DeviceRecord(
            id: device.id, name: device.name, kind: device.kind, abilities: DeviceStore.abilities(device.kind), owner: owner ?? (device.kind == .mac),
            identityKey: device.key.publicKey, nodeKeys: nodeKeys ?? [device.nodeKey], userId: 7, fqdn: device.name + ".tail.ts.net.", issuedBy: issuedBy,
            added: clock.now)
    }

    func allow(_ device: Device, owner: Bool? = nil, issuedBy: UUID? = nil) throws {
        let made = record(device, owner: owner, issuedBy: issuedBy)
        try store.book.update { $0.append(made) }
    }

    /// A device dialling the box: the box's half goes through `HostNet.greet` as an accepted
    /// connection would (WhoIs `whois`, or the SSH route).
    func dial(_ device: Device, route: Binding.Route = .tailnet, whois: TailnetWhoIs? = nil, enroll: NetControl.Enroll? = nil) throws -> Dialled {
        let (a, b) = try Sockets.pair()
        let book = DeviceBook(url: rig.root.appendingPathComponent("macs/\(device.id.uuidString).json"))
        var box = boxRecord
        if route == .ssh { box.nodeKeys = [Binding.Route.sshNodeKey] }
        try book.update { $0 = [box] }
        let own = route == .ssh ? Binding.Route.sshNodeKey : device.nodeKey
        let peer = route == .ssh ? NetPeerFacts.ssh : NetPeerFacts(nodeKey: "nodekey:box", userId: 7)
        let local = NetLocal(device: device.id, kind: device.kind, nodeKey: own, signer: device.key)
        var setup = NetSession.Client(local: local, route: route, peer: peer, book: book, server: identity.device, service: "link")
        setup.enroll = enroll
        let session = Dialled(NetSession(fd: a, role: .client(setup), clock: { [clock] in clock.now }))
        let who = whois ?? FakeTailnet.who(key: device.nodeKey)
        let facts = route == .ssh ? NetPeerFacts.ssh : HostNet.facts(who)
        net.greet(b, route: route, facts: facts, whois: route == .ssh ? nil : who)
        return session
    }
}

/// One device's identity.
struct Device {
    var id = UUID()
    var name: String
    var kind: NodeKind
    var key = SoftwareIdentity()
    var nodeKey: String

    init(_ name: String, kind: NodeKind = .mac, nodeKey: String? = nil) {
        self.name = name
        self.kind = kind
        self.nodeKey = nodeKey ?? "nodekey:\(name)"
    }
}

/// The device's end of a session: what came, decoded as link bodies.
@MainActor
final class Dialled {
    let session: NetSession
    var got: [Data] = []

    /// Pumped along with the session (an attach relay).
    var also: (() -> Void)?

    init(_ session: NetSession) { self.session = session }

    var up: Bool { if case .established = session.state { true } else { false } }
    var closed: String? { if case .closed(let why) = session.state { why } else { nil } }
    var types: [String] { got.compactMap(StreamWire.type) }

    func send(_ value: some Encodable) throws { try session.send(StreamWire.encode(value), queue: .interactive, stream: 1) }
    func sendRaw(_ data: Data) throws { try session.send(data, queue: .interactive, stream: 1) }

    func pump() {
        also?()
        got += session.pump().map(\.payload)
    }

    /// Waits (yielding to the main queue, never sleeping) until `check` holds.
    func until(_ check: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !check() {
            pump()
            guard ContinuousClock.now < end else {
                Issue.record("waited 5 s: \(types) \(closed ?? "up")", sourceLocation: sourceLocation)
                throw Waited.timeout
            }
            await Task.yield()
        }
    }

    func decoded<T: Decodable>(_ type: T.Type) -> [T] { got.compactMap { try? JSONDecoder().decode(T.self, from: $0) } }
}

/// The far side of a hello rewrite: frames from the client go through `NetAttach.inject`.
extension NetRig {
    /// Dials over SSH with the hello rewritten as `attach --proto 2` would.
    func dialAttach(_ device: Device, grant: Grant, enroll: NetControl.Enroll?) throws -> Dialled {
        // client ↔ [a b] attach-side relay [c d] ↔ greet
        let (clientFd, relayIn) = try Sockets.pair()
        let (relayOut, boxFd) = try Sockets.pair()
        let book = DeviceBook(url: rig.root.appendingPathComponent("macs/\(device.id.uuidString).json"))
        var box = boxRecord
        box.nodeKeys = [Binding.Route.sshNodeKey]
        try book.update { $0 = [box] }
        let local = NetLocal(device: device.id, kind: device.kind, nodeKey: Binding.Route.sshNodeKey, signer: device.key)
        var setup = NetSession.Client(local: local, route: .ssh, peer: .ssh, book: book, server: identity.device, service: "link")
        setup.enroll = enroll
        let session = Dialled(NetSession(fd: clientFd, role: .client(setup), clock: { [clock] in clock.now }))
        let relay = Relay(fromClient: relayIn, toBox: relayOut, grant: grant)
        session.also = { relay.pump() }
        net.greet(boxFd, route: .ssh, facts: .ssh, whois: nil)
        return session
    }
}

/// Moves bytes between two descriptors (the attach relay in a test), rewriting the client's hello.
@MainActor
final class Relay {
    let fromClient: Int32
    let toBox: Int32
    let grant: Grant
    var held = Data()
    var helloDone = false

    init(fromClient: Int32, toBox: Int32, grant: Grant) {
        self.fromClient = fromClient
        self.toBox = toBox
        self.grant = grant
        Sockets.setNonBlocking(fromClient)
        Sockets.setNonBlocking(toBox)
    }

    func pump() {
        if let bytes = try? Sockets.read(fromClient, max: 65536), !bytes.isEmpty {
            if helloDone {
                try? Sockets.writeAll(toBox, Data(bytes))
            } else {
                held.append(contentsOf: bytes)
                if let out = NetAttach.inject(held, grant: grant) {
                    helloDone = true
                    try? Sockets.writeAll(toBox, out)
                }
            }
        }
        if let bytes = try? Sockets.read(toBox, max: 65536), !bytes.isEmpty { try? Sockets.writeAll(fromClient, Data(bytes)) }
    }
}

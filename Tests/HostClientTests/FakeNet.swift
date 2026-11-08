import Foundation
import HostClient
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import src

/// Things that happen, awaited as they happen: each `next` takes the first one that matches,
/// already here or still to come. No polling, no wall clock; a suite's time limit bounds a hang.
final class Feed<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var waiters: [(match: (T) -> Bool, wake: CheckedContinuation<T, Never>)] = []

    init() {}

    func send(_ item: T) {
        lock.lock()
        if let i = waiters.firstIndex(where: { $0.match(item) }) {
            let waiter = waiters.remove(at: i)
            lock.unlock()
            waiter.wake.resume(returning: item)
            return
        }
        items.append(item)
        lock.unlock()
    }

    @discardableResult
    func next(_ match: @escaping @Sendable (T) -> Bool = { _ in true }) async -> T {
        await withCheckedContinuation { wake in
            lock.lock()
            if let i = items.firstIndex(where: match) {
                let item = items.remove(at: i)
                lock.unlock()
                wake.resume(returning: item)
                return
            }
            waiters.append((match, wake))
            lock.unlock()
        }
    }
}

/// A decoded message, handed across queues.
struct Got: @unchecked Sendable {
    var session: Int
    var object: [String: Any]
    var type: String? { object["t"] as? String }
    var command: String? { (object["cmd"] as? [String: Any])?["type"] as? String }
    var id: String? { object["id"] as? String }
}

/// A tailnet answering from what a test set: status, WhoIs, the bus (pushed by hand, its
/// subscribers counted) and dials that reach a `FakeNetBox`. No LocalAPI, no sockets of its own.
final class FakeTailnet: Tailnet {
    struct Held {
        var status: TailnetStatus
        var whois: [String: TailnetWhoIs] = [:]
        var dial: (@Sendable (String) throws -> Int32)?
        var buses: [Int: AsyncStream<TailnetEvent>.Continuation] = [:]
        var nextBus = 0
        var statusReads = 0
    }

    let held: Mutex<Held>

    init(_ state: BackendState = .running, peers: [TailnetStatus.Peer] = []) {
        held = Mutex(Held(status: TailnetStatus(
            backendState: state, selfNode: .init(publicKey: "nodekey:mac", tailscaleIPs: ["100.64.0.1"], userID: 7), peers: peers)))
    }

    var buses: Int { held.withLock { $0.buses.count } }
    /// Each bus subscription as it ends.
    let busEnded = Feed<Int>()
    var statusReads: Int { held.withLock { $0.statusReads } }

    func status() throws -> TailnetStatus {
        held.withLock {
            $0.statusReads += 1
            return $0.status
        }
    }

    func whois(_ address: String) throws -> TailnetWhoIs {
        guard let who = held.withLock({ $0.whois[address] }) else { throw TailnetError.notTailnet(address) }
        return who
    }

    func events() -> AsyncStream<TailnetEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TailnetEvent.self)
        let id = held.withLock { h -> Int in
            h.nextBus += 1
            h.buses[h.nextBus] = continuation
            return h.nextBus
        }
        continuation.onTermination = { [weak self] _ in
            self?.held.withLock { _ = $0.buses.removeValue(forKey: id) }
            self?.busEnded.send(id)
        }
        return stream
    }

    func push(_ event: TailnetEvent) { for bus in held.withLock({ $0.buses.values }) { bus.yield(event) } }

    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }

    func dial(_ address: String, port: UInt16) throws -> Int32 {
        guard let dial = held.withLock({ $0.dial }) else { throw TailnetError.notTailnet(address) }
        return try dial(address)
    }

    /// The box at 100.64.0.2 with node key `key`, its WhoIs this Mac's own user's.
    func addBox(key: String = "nodekey:box", online: Bool = true) {
        let json = #"{"PublicKey":"\#(key)","TailscaleIPs":["100.64.0.2"],"Online":\#(online),"UserID":7}"#
        let peer = try! JSONDecoder().decode(TailnetStatus.Peer.self, from: Data(json.utf8))
        let who = #"{"Node":{"Key":"\#(key)","Name":"box-1.tail.ts.net."},"UserProfile":{"ID":7,"LoginName":"me@example.com"}}"#
        held.withLock {
            $0.status.peers = [peer]
            $0.whois["100.64.0.2"] = try! JSONDecoder().decode(TailnetWhoIs.self, from: Data(who.utf8))
        }
    }
}

/// A box's end of KoreNet sessions over socketpairs: its identity, its book of devices, and per
/// session a scripted link (the welcome and snapshot, then what the test sends). Pumped on its own
/// queue by the socket, as kore-host is.
final class FakeNetBox: @unchecked Sendable {
    let device = UUID()
    let identity = SoftwareIdentity()
    let book: DeviceBook
    let nodeKey: String
    private let queue = DispatchQueue(label: "fake.net.box")
    private let lock = NSLock()
    private var sessions: [Session] = []
    private var got: [(session: Int, object: [String: Any])] = []
    /// Who connected, by route, in order.
    private(set) var dialled: [Binding.Route] = []
    /// Each session's index as it's accepted, and what the Mac sent on any.
    let accepted = Feed<Int>()
    let received = Feed<Got>()
    /// Answers each session's link with a welcome and snapshot (false: never, a silent box).
    var welcomes = true
    var minor = 12
    /// An SSH-route stranger with an enroll is taken (the grant upgrade).
    var takesEnroll = true

    final class Session {
        let session: NetSession
        var source: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var welcomed = false
        init(_ session: NetSession) { self.session = session }
    }

    init(root: URL, nodeKey: String = "nodekey:box") {
        book = DeviceBook(url: root.appendingPathComponent("box-\(UUID().uuidString.prefix(6)).json"))
        self.nodeKey = nodeKey
    }

    /// The box as the Mac's book pins it over SSH.
    var pinned: DeviceRecord {
        DeviceRecord(
            id: device, name: "box-1", kind: .box, abilities: [.read, .ask, .run], identityKey: identity.publicKey, nodeKeys: [Binding.Route.sshNodeKey],
            userId: nil, fqdn: "", added: Date())
    }

    var node: NetNodeWire.Node { NetNodeWire.Node(device: device, identityKey: identity.publicKey, name: "box-1", on: true, nodeKey: nodeKey) }

    func allow(mac: UUID, key: Data) throws {
        try book.update {
            $0.append(DeviceRecord(
                id: mac, name: "MacBook", kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: key, nodeKeys: [Binding.Route.sshNodeKey],
                userId: nil, fqdn: "", added: Date()))
        }
    }

    /// A connected socket to a new session on this box over `route`.
    func accept(_ route: Binding.Route) throws -> Int32 {
        let (mac, box) = try Sockets.pair()
        let facts = route == .ssh ? NetPeerFacts.ssh : NetPeerFacts(nodeKey: "nodekey:mac", userId: 7)
        var setup = NetSession.Server(
            local: NetLocal(device: device, kind: .box, nodeKey: route == .ssh ? Binding.Route.sshNodeKey : nodeKey, signer: identity), route: route,
            peer: facts, book: book, tickets: ResumeTickets())
        setup.ownUser = 7
        let book = book
        let takes = takesEnroll
        setup.stranger = { hello in
            guard route == .ssh, takes, let enroll = hello.enroll else { return .refuse(NetControl.Reason.unknown) }
            let record = DeviceRecord(
                id: hello.device, name: enroll.name, kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: enroll.identityKey,
                nodeKeys: [Binding.Route.sshNodeKey], userId: nil, fqdn: "", added: Date())
            return .enroll(record) { _ in (try? book.update { $0.append(record) }) != nil }
        }
        let session = Session(NetSession(fd: box, role: .server(setup)))
        queue.sync {
            dialled.append(route)
            sessions.append(session)
            let index = sessions.count - 1
            let watched = dup(box)
            let source = DispatchSource.makeReadSource(fileDescriptor: watched, queue: queue)
            source.setCancelHandler { Sockets.closeFD(watched) }
            source.setEventHandler { [weak self] in self?.pump(index) }
            session.source = source
            session.session.start()
            source.resume()
            accepted.send(index)
        }
        return mac
    }

    private func pump(_ index: Int) {
        let s = sessions[index]
        for message in s.session.pump() {
            let object = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any] ?? [:]
            lock.withLock { got.append((index, object)) }
            received.send(Got(session: index, object: object))
        }
        if case .established = s.session.state, !s.welcomed, welcomes {
            s.welcomed = true
            send(index, json: [
                "t": "welcome", "proto": ["major": 1, "minor": minor], "epoch": "e1", "host": ["name": "box-1", "koreVersion": "1", "kind": "box"],
                "providers": [], "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream"],
            ])
            send(index, LinkMessage.snapshot(rev: 1, windows: [], chats: [], extras: nil))
        }
        if case .closed = s.session.state {
            s.source?.cancel()
            s.source = nil
        }
    }

    func send(_ index: Int, _ message: LinkMessage) { send(index, data: (try? message.encoded()) ?? Data()) }

    func send(_ index: Int, json: [String: Any]) { send(index, data: (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()) }

    private func send(_ index: Int, data: Data) {
        let s = sessions[index]
        try? s.session.send(data, queue: .interactive, stream: 1)
        // Socketpairs take small writes at once; what's left goes on the next pump.
        _ = s.session.pump()
    }

    /// Ends a session as the network would (no `bye`).
    func cut(_ index: Int) { queue.sync { Sockets.shutdownBoth(sessions[index].session.descriptor) } }

    /// What the Mac sent on a session, of a type, in order.
    func sent(_ type: String, session index: Int? = nil) -> [[String: Any]] {
        lock.withLock { got.filter { ($0.object["t"] as? String) == type && (index == nil || $0.session == index) }.map(\.object) }
    }

    /// The Mac's `cmd`s of a kind (`folders.list`), in order.
    func commands(_ type: String) -> [[String: Any]] { sent("cmd").filter { ($0["cmd"] as? [String: Any])?["type"] as? String == type } }

    var count: Int { queue.sync { sessions.count } }

    func established(_ index: Int) -> Bool {
        queue.sync {
            guard index < sessions.count, case .established = sessions[index].session.state else { return false }
            return true
        }
    }

    func run(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

    func reply(_ index: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        queue.async { self.send(index, data: data) }
    }
}

/// A clock a test moves: `sleep` waits until `advance` passes its end, so a backoff, a probe's
/// wait or a handshake limit is a step, never a real wait.
final class VirtualClock: Sendable {
    private struct Sleeper {
        var id: Int
        var duration: Duration
        var end: Duration
        var wake: CheckedContinuation<Void, Never>
    }

    private let held = Mutex<(now: Duration, next: Int, sleepers: [Sleeper], asked: [Duration])>((.zero, 0, [], []))
    /// Each wait as it starts, and each one ended early (its task cancelled), by its duration.
    private let started = Feed<Duration>()
    private let cancelled = Feed<Duration>()

    /// Returns once a wait of `duration` has started (one already waiting counts).
    func pending(_ duration: Duration) async {
        // A start seen earlier may have ended since: each one wakes a look at who waits now.
        while !held.withLock({ $0.sleepers.contains { $0.duration == duration } }) { await started.next { $0 == duration } }
    }

    /// Returns once a wait of `duration` was given up (an answer came first).
    func gaveUp(_ duration: Duration) async { await cancelled.next { $0 == duration } }

    /// Every wait asked for, in order.
    var asked: [Duration] { held.withLock { $0.asked } }
    var waiting: Int { held.withLock { $0.sleepers.count } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async {
        let id = held.withLock { h -> Int in
            h.next += 1
            h.asked.append(duration)
            return h.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
                let resumeNow = held.withLock { h -> Bool in
                    guard !Task.isCancelled else { return true }
                    h.sleepers.append(Sleeper(id: id, duration: duration, end: h.now + duration, wake: wake))
                    return false
                }
                if resumeNow { wake.resume() } else { started.send(duration) }
            }
        } onCancel: {
            let woken = held.withLock { h -> Sleeper? in
                guard let i = h.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return h.sleepers.remove(at: i)
            }
            if let woken {
                woken.wake.resume()
                cancelled.send(woken.duration)
            }
        }
    }

    /// Moves time on: every wait ending by then returns.
    func advance(_ by: Duration) {
        let due = held.withLock { h -> [CheckedContinuation<Void, Never>] in
            h.now += by
            let ready = h.sleepers.filter { $0.end <= h.now }
            h.sleepers.removeAll { $0.end <= h.now }
            return ready.map(\.wake)
        }
        for wake in due { wake.resume() }
    }
}

/// A router a test drives: KoreNet transports from `make` while it gives them.
@MainActor
final class FakeRouter: NetRouter {
    var make: (@MainActor () -> (any HostTransport)?)?
    var uses: [Bool] = []
    var nodes: [NetNodeWire.Node] = []
    var asked = 0

    func transport(for connection: HostConnection) -> (any HostTransport)? {
        asked += 1
        return make?()
    }

    func using(_ connection: HostConnection, _ inUse: Bool) { uses.append(inUse) }
    func said(_ node: NetNodeWire.Node, on connection: HostConnection) { nodes.append(node) }
}

/// A transport over KoreNet to `box`, as this Mac (`mac`) whose book pins the box.
func netTransport(to box: FakeNetBox, mac: MacIdentity, book: DeviceBook, route: Binding.Route = .tailnet) -> NetTransport {
    NetTransport(route: route) {
        let fd = try box.accept(route)
        let local = NetLocal(device: mac.device, kind: .mac, nodeKey: route == .ssh ? Binding.Route.sshNodeKey : "nodekey:mac", signer: mac.signer)
        let peer = route == .ssh ? NetPeerFacts.ssh : NetPeerFacts(nodeKey: box.nodeKey, userId: 7)
        var setup = NetSession.Client(local: local, route: route, peer: peer, book: book, server: box.device, service: "link")
        setup.ownUser = 7
        return NetTransport.Opened(fd: fd, setup: setup)
    }
}

/// A Mac and a box that knows it, each with a book that pins the other.
@MainActor
func pairedBox(_ root: URL) throws -> (box: FakeNetBox, mac: MacIdentity, book: DeviceBook) {
    let box = FakeNetBox(root: root)
    let mac = MacIdentity(device: UUID(), signer: SoftwareIdentity())
    try box.allow(mac: mac.device, key: mac.signer.publicKey)
    let book = DeviceBook(url: root.appendingPathComponent("mac-\(UUID().uuidString.prefix(6)).json"))
    var pinned = box.pinned
    pinned.nodeKeys = [box.nodeKey]
    pinned.userId = 7
    try book.update { $0.append(pinned) }
    return (box, mac, book)
}

/// A scratch folder short enough for socket paths.
func netScratch() -> URL {
    let url = URL(fileURLWithPath: "/tmp/kn-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A value tests change while closures read it.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

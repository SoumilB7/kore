import Darwin
import Foundation
import KoreNet
import KoreTrust
import Synchronization
import Tailnet

/// One owner's tailnet in memory: every node (Macs, boxes, phones) by its tailnet address, their
/// Tailscale state, and the connections dialled between them. Each node sees it through its own
/// `NodeNet` (a `Tailnet`): Status, WhoIs, the IPN bus, listen and dial.
///
/// Connections are real loopback TCP. A Mac listens the way Kore's own tailnet hands
/// connections over (`TailnetListenSocket.handoff`: the accepted descriptor with the dialler's
/// tailnet address), so `MacNet`'s real accept, limiter and WhoIs run with each node's own
/// address. A box binds its real port on 127.0.0.1 (`HostNet`'s own bind), and a dial to it is
/// handed to `HostNet.greet` after the box's own WhoIs: on loopback every source is 127.0.0.1, so
/// the box's accept loop can't tell nodes apart (its per-source limiter is covered by its own
/// tests).
final class SharedTailnet: Sendable {
    enum Kind: String, Sendable { case mac, box, phone }

    struct Node: Sendable {
        var name: String
        var kind: Kind
        var ip: String
        var nodeKey: String
        var user: Int64 = 7
        var state: BackendState = .running
        /// What the node binds as its own address (a box binds a real 127.0.0.1 port).
        var bindIP: String
        /// A Mac's handoff sockets, one per `listen` (the tailnet's ends), newest last: a dial goes
        /// to the newest whose listener still holds its end.
        var handoffs: [Int32] = []
        /// Where dials to this box go (set by the box rig).
        var greet: (@Sendable (_ fd: Int32, _ remote: String) -> Bool)?
        /// Binds made, and binds still to be refused (`EADDRNOTAVAIL`, as while Tailscale re-adds
        /// an address).
        var listens = 0
        var refuseListens = 0
        var os: String { kind == .mac ? "macOS" : kind == .box ? "linux" : "android" }
        var online: Bool { state == .running }
    }

    private struct State {
        var nodes: [String: Node] = [:]
        var buses: [String: [Int: AsyncStream<TailnetEvent>.Continuation]] = [:]
        var nextBus = 0
        /// Every connection's two descriptors' far ends, by node, so a node's death cuts them.
        var links: [(a: String, b: String, fds: [FDRef])] = []
        var dials = 0
    }

    private let state = Mutex(State())
    /// Something happened on the tailnet (the world's pulse).
    let pulse: @Sendable () -> Void

    init(pulse: @escaping @Sendable () -> Void) { self.pulse = pulse }

    func add(_ node: Node) {
        state.withLock { $0.nodes[node.ip] = node }
        push(changed: node.ip)
    }

    func node(_ ip: String) -> Node? { state.withLock { $0.nodes[ip] } }
    func node(named name: String) -> Node? { state.withLock { $0.nodes.values.first { $0.name == name } } }

    func update(_ ip: String, _ change: (inout Node) -> Void) {
        state.withLock { if var n = $0.nodes[ip] { change(&n); $0.nodes[ip] = n } }
    }

    /// Tailscale on a node switched (running, stopped, signed out): its own bus hears its state;
    /// every other node hears it come or go as a peer.
    func setState(_ ip: String, _ backend: BackendState) {
        update(ip) { $0.state = backend }
        if backend != .running { cut(ip) }
        push(changed: ip)
    }

    /// A node's key changed (a phone app reinstalled: a new node).
    func remove(_ ip: String) {
        cut(ip)
        state.withLock { $0.nodes[ip] = nil }
        push(changed: ip)
    }

    // MARK: A node's view

    func status(of ip: String) -> TailnetStatus {
        state.withLock { s in
            guard let me = s.nodes[ip] else { return TailnetStatus(backendState: .noState, selfNode: nil) }
            var selfNode = TailnetStatus.SelfNode(
                publicKey: me.nodeKey, tailscaleIPs: me.state == .running ? [me.bindIP] : [], userID: me.user, dnsName: me.name + ".tail.ts.net.")
            selfNode.hostName = me.name
            let peers = me.state == .running ? s.nodes.values.filter { $0.ip != ip }.sorted { $0.ip < $1.ip }.map(Self.peer) : []
            // Waiting for its sign-in: the page, as tsnet's status carries it.
            let page = me.state == .needsLogin ? "https://login.example/a/\(me.name)" : nil
            return TailnetStatus(backendState: me.state, selfNode: selfNode, peers: peers, authURL: page)
        }
    }

    static func peer(_ n: Node) -> TailnetStatus.Peer {
        let json = #"{"PublicKey":"\#(n.nodeKey)","TailscaleIPs":["\#(n.ip)"],"Online":\#(n.online),"UserID":\#(n.user),"HostName":"\#(n.name)","OS":"\#(n.os)","CurAddr":"\#(n.ip):41641"}"#
        return try! JSONDecoder().decode(TailnetStatus.Peer.self, from: Data(json.utf8))
    }

    func whois(_ address: String, from ip: String) throws -> TailnetWhoIs {
        let host = address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" }) : String(address.split(separator: ":").first ?? "")
        guard let n = state.withLock({ s -> Node? in
            guard s.nodes[ip]?.state == .running else { return nil }
            return s.nodes[host]
        }) else { throw TailnetError.notTailnet(address) }
        let json = #"{"Node":{"Key":"\#(n.nodeKey)","Name":"\#(n.name).tail.ts.net.","Tags":[]},"UserProfile":{"ID":\#(n.user),"LoginName":"me@example.com"}}"#
        return try JSONDecoder().decode(TailnetWhoIs.self, from: Data(json.utf8))
    }

    func events(of ip: String) -> AsyncStream<TailnetEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TailnetEvent.self)
        let id = state.withLock { s -> Int in
            s.nextBus += 1
            s.buses[ip, default: [:]][s.nextBus] = continuation
            return s.nextBus
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.buses[ip]?.removeValue(forKey: id) } }
        // Tailscale's bus starts with the state and the whole status (the watch mask's initial bits).
        let now = status(of: ip)
        continuation.yield(.state(now.backendState))
        continuation.yield(.status(now))
        return stream
    }

    /// Every bus hears what changed about `ip`: its own its state and status, the others the peer.
    private func push(changed ip: String) {
        let (buses, node) = state.withLock { ($0.buses, $0.nodes[ip]) }
        for (owner, list) in buses {
            let status = status(of: owner)
            for bus in list.values {
                if owner == ip {
                    bus.yield(.state(status.backendState))
                    bus.yield(.status(status))
                } else {
                    bus.yield(.peer(nodeID: 0, key: node?.nodeKey, online: node?.online ?? false))
                    bus.yield(.status(status))
                }
            }
        }
        pulse()
    }

    /// A Mac's bind. The port is one per address, as a real one: while an earlier listener still
    /// holds its end (not closed yet), a second bind is refused (`EADDRINUSE`).
    func listen(_ ip: String) throws -> [TailnetListenSocket] {
        guard let me = node(ip), me.kind == .mac else { return [] }
        guard me.state == .running else { throw TailnetError.notRunning(me.state) }
        let refused = state.withLock { s -> Int32? in
            s.nodes[ip]?.listens += 1
            if let n = s.nodes[ip]?.refuseListens, n > 0 {
                s.nodes[ip]?.refuseListens = n - 1
                return EADDRNOTAVAIL
            }
            // Ends whose listener closed go; one still held keeps the port.
            let held = s.nodes[ip]?.handoffs ?? []
            let dead = held.filter { !Self.peerOpen($0) }
            for fd in dead { Sockets.closeFD(fd) }
            s.nodes[ip]?.handoffs = held.filter { !dead.contains($0) }
            return dead.count < held.count ? EADDRINUSE : nil
        }
        defer { pulse() }
        if let refused { throw SocketError.failed("bind \(me.bindIP):47470", refused) }
        let (ours, theirs) = try Sockets.pair()
        state.withLock { $0.nodes[ip]?.handoffs.append(ours) }
        return [.handoff(theirs)]
    }

    /// The far end of a socketpair is still open: its acks read away, an EOF says it closed.
    static func peerOpen(_ fd: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, Int32(MSG_DONTWAIT))
            if n > 0 { continue }
            return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
        }
    }

    /// The next `count` binds on `ip` are refused.
    func refuseListens(_ ip: String, _ count: Int) { update(ip) { $0.refuseListens = count } }
    func listens(_ ip: String) -> Int { node(ip)?.listens ?? 0 }

    /// A connected loopback TCP pair: (dialler's end, listener's end).
    static func tcpPair() throws -> (Int32, Int32) {
        let listener = try Sockets.listenTCP("127.0.0.1", port: 0)
        defer { Sockets.closeFD(listener) }
        guard let port = Sockets.localPort(listener) else { throw TailnetError.sidecar("no port") }
        let client = try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: port)
        let server = Sockets.accept(listener)
        guard server >= 0 else {
            Sockets.closeFD(client)
            throw SocketError.failed("accept", errno)
        }
        return (client, server)
    }

    /// Something sent on a link that its other end hasn't read yet: work under way (a handshake's
    /// welcome, a push), however long a busy Mac takes to get to it.
    var inFlight: Bool { state.withLock { s in s.links.contains { $0.fds.contains { $0.unread > 0 } } } }

    func dial(from ip: String, to address: String) throws -> Int32 {
        let (me, target) = state.withLock { ($0.nodes[ip], $0.nodes[address]) }
        guard let me, me.state == .running else { throw TailnetError.notRunning(me?.state ?? .noState) }
        guard let target, target.online else { throw TailnetError.sidecar("\(address) is offline") }
        let (client, server) = try Self.tcpPair()
        // Both ends, by descriptor and socket identity, to cut them should either node die.
        let refs = [FDRef(client), FDRef(server)].compactMap { $0 }
        state.withLock {
            $0.links.append((ip, address, refs))
            $0.dials += 1
        }
        defer { pulse() }
        switch target.kind {
        case .mac:
            let body = Data(#"{"conn":{"remote":"\#(me.ip):41641"}}"#.utf8)
            // The newest listener first; one its owner let go of fails the send and goes.
            for handoff in target.handoffs.reversed() {
                do {
                    try SidecarWire.send(handoff, body, attach: server)
                } catch {
                    state.withLock { $0.nodes[address]?.handoffs.removeAll { $0 == handoff } }
                    Sockets.closeFD(handoff)
                    continue
                }
                Sockets.closeFD(server)
                drainAcks(handoff)
                return client
            }
            Sockets.closeFD(client)
            Sockets.closeFD(server)
            throw SocketError.failed("connect", ECONNREFUSED)
        case .box:
            guard let greet = target.greet, greet(server, me.ip) else {
                Sockets.closeFD(client)
                Sockets.closeFD(server)
                throw SocketError.failed("connect", ECONNREFUSED)
            }
            return client
        case .phone:
            Sockets.closeFD(client)
            Sockets.closeFD(server)
            throw SocketError.failed("connect", ECONNREFUSED)
        }
    }

    /// The listener's acks on the handoff socket, read so they never fill it.
    private func drainAcks(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, Int32(MSG_DONTWAIT))
            if n <= 0 { return }
        }
    }

    /// Every connection to or from `ip` ends as a dead node's would: no bye, the sockets just go.
    func cut(_ ip: String) {
        let (gone, handoffs) = state.withLock { s -> ([FDRef], [Int32]) in
            let hit = s.links.filter { $0.a == ip || $0.b == ip }
            s.links.removeAll { $0.a == ip || $0.b == ip }
            let h = s.nodes[ip]?.handoffs ?? []
            s.nodes[ip]?.handoffs = []
            return (hit.flatMap(\.fds), h)
        }
        // Shut, never closed: the descriptors are their owners' to close.
        for ref in gone { ref.shut() }
        for fd in handoffs { Sockets.closeFD(fd) }
        pulse()
    }

    var dials: Int { state.withLock { $0.dials } }

    func closeAll() {
        let (refs, handoffs, buses) = state.withLock { s -> ([FDRef], [Int32], [AsyncStream<TailnetEvent>.Continuation]) in
            let all = s.links.flatMap(\.fds)
            let handoffs = s.nodes.values.flatMap(\.handoffs)
            let buses = s.buses.values.flatMap(\.values)
            s.links = []
            for ip in s.nodes.keys { s.nodes[ip]?.handoffs = [] }
            s.buses = [:]
            return (all, handoffs, buses)
        }
        // Outside the lock: a bus's end takes it again.
        for bus in buses { bus.finish() }
        for ref in refs { ref.shut() }
        for fd in handoffs { Sockets.closeFD(fd) }
    }
}

/// A descriptor and the socket it named when made: shut only while it still names that socket
/// (its owner may have closed it, and the number gone to another).
struct FDRef: Sendable {
    let fd: Int32
    let dev: dev_t
    let ino: ino_t

    init?(_ fd: Int32) {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        self.fd = fd
        dev = st.st_dev
        ino = st.st_ino
    }

    func shut() {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == dev, st.st_ino == ino else { return }
        Sockets.shutdownBoth(fd)
    }

    /// Bytes that arrived at this end and aren't read yet (0 once it's gone).
    var unread: Int32 {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == dev, st.st_ino == ino else { return 0 }
        var count: Int32 = 0
        // FIONREAD, _IOR('f', 127, int): Swift doesn't import the macro.
        return ioctl(fd, UInt(0x4004_667F), &count) == 0 ? count : 0
    }
}

/// One node's own view of the shared tailnet (its LocalAPI).
final class NodeNet: Tailnet {
    let net: SharedTailnet
    let ip: String

    init(_ net: SharedTailnet, ip: String) {
        self.net = net
        self.ip = ip
    }

    func status() throws -> TailnetStatus { net.status(of: ip) }
    func whois(_ address: String) throws -> TailnetWhoIs { try net.whois(address, from: ip) }
    func events() -> AsyncStream<TailnetEvent> { net.events(of: ip) }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { try net.listen(ip) }
    func dial(_ address: String, port: UInt16) throws -> Int32 { try net.dial(from: ip, to: address) }
}

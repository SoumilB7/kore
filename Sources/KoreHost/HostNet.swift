import Foundation
import KoreHostSys
import KoreNet
import KoreTrust
import LinkProtocol
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// kore-host on KoreNet (phase 18 §4), only while the box is on it (`kore-host net on`, `join`;
/// off by default, and a Mac's `net.set` can switch it off): port 47470 on this box's tailnet addresses only (on Linux
/// also held to `tailscale0` with `SO_BINDTODEVICE`), never 0.0.0.0 or ::. Bound while Tailscale
/// is up: an interface or address change (netlink on Linux; the IPN bus on a Mac dev build, held
/// only until bound) makes it look again, nothing polls. An unclaimed box listens too: its first
/// owner Mac has to reach it.
///
/// Each connection: the pre-auth limits (3 a minute per source, one frame of at most 4 KiB, 2 s),
/// a WhoIs of its address, then a KoreNet session (the device's identity proof over B). A device
/// with a record goes to `HostDaemon.accepted`; one without is told `bye unknown` and, when it's
/// this box's own user's (or carries Kore's app capability), kept as pending. `attach --proto 2`
/// brings the same sessions over SSH through `net.sock` (route `ssh`, the grant upgrade).
///
/// Step 6 note: when kore-host spawns `rsync --server` for `pipe.open`, it adds its own
/// `--timeout` (openrsync never passes one to the server, spike 0f).
@MainActor
package final class HostNet {
    nonisolated package static let port = NetListener.port
    /// The interface installed Tailscale makes on Linux.
    package static let interface = "tailscale0"
    /// Tailnet handshakes under way at once; more are closed.
    package static let maxHandshakes = 16
    /// `attach --proto 2` handshakes (this user only), counted apart so tailnet peers can't
    /// crowd them out.
    package static let maxSSHHandshakes = 4

    func handshaking(_ route: Binding.Route) -> Int { handshakes.values.filter { $0.route == route }.count }

    unowned let host: HostDaemon
    /// The tailnet while the box is on KoreNet (`join`); nil while off: no port, no LocalAPI, no
    /// netlink or bus.
    package private(set) var tailnet: (any Tailnet)?
    package let identity: BoxIdentity
    private let limiter: PreAuthLimiter
    private let tickets = ResumeTickets()
    /// The port the next bind uses.
    package var port: UInt16

    /// The sockets bound now, and the addresses they're on.
    package private(set) var bound: [String] = []
    private var listeners: [(fd: Int32, source: DispatchSourceRead)] = []
    /// The first listening socket (tests read the port the kernel picked).
    var firstListener: Int32? { listeners.first?.fd }
    private var boundIndex: Int32 = 0
    /// `tailscale0`'s index now (0 off Linux; tests set their own).
    package var interfaceIndex: () -> Int32 = {
        #if os(Linux)
        kore_interface_index(HostNet.interface)
        #else
        0
        #endif
    }
    /// Times the port was bound (tests read it).
    package private(set) var binds = 0
    /// This node as its own Status says: node key, user (nil when tagged).
    package private(set) var selfNode: TailnetStatus.SelfNode?
    /// Why the port couldn't be bound, for `status` and the journal.
    package private(set) var bindProblem: String?
    private var netlink: (fd: Int32, source: DispatchSourceRead)?
    private var busWatch: Task<Void, Never>?
    private var ssh: (fd: Int32, source: DispatchSourceRead)?
    private var handshakes: [ObjectIdentifier: Handshake] = [:]

    /// One session before its proof: its socket's read source and its 2 s deadline.
    private final class Handshake {
        let session: NetSession
        let route: Binding.Route
        let facts: NetPeerFacts
        var read: DispatchSourceRead?
        var deadline: DispatchSourceTimer?
        init(session: NetSession, route: Binding.Route, facts: NetPeerFacts) {
            self.session = session
            self.route = route
            self.facts = facts
        }
        func cancel() {
            read?.cancel()
            read = nil
            deadline?.cancel()
            deadline = nil
        }
    }

    package init(host: HostDaemon, identity: BoxIdentity, port: UInt16 = HostNet.port, limiter: PreAuthLimiter = PreAuthLimiter()) {
        self.host = host
        self.identity = identity
        self.port = port
        self.limiter = limiter
    }

    /// `net.sock`, for `attach --proto 2` (SSH works with KoreNet on or off).
    package func start() { openSSH() }

    /// On KoreNet: watch the interface, bind the port.
    package func join(_ tailnet: any Tailnet) {
        guard self.tailnet == nil else { return }
        self.tailnet = tailnet
        watchInterfaces()
        rebind()
    }

    /// Off KoreNet: the port and every watcher go (links already up are the daemon's to end).
    package func leave() {
        closeListeners()
        netlink?.source.cancel()
        netlink = nil
        busWatch?.cancel()
        busWatch = nil
        tailnet = nil
        selfNode = nil
        for (key, shake) in handshakes where shake.route == .tailnet {
            shake.cancel()
            shake.session.close(NetControl.Reason.refused)
            handshakes[key] = nil
        }
    }

    /// Whether a port is bound now.
    package var listening: Bool { !listeners.isEmpty }
    /// Whether anything watches the network now (netlink, the IPN bus).
    package var watching: Bool { netlink != nil || busWatch != nil }

    package func stop() {
        leave()
        ssh?.source.cancel()
        ssh = nil
        unlink(host.paths.netSocket.path)
        for shake in handshakes.values {
            shake.cancel()
            shake.session.close(NetControl.Reason.refused)
        }
        handshakes = [:]
    }

    // MARK: Binding

    /// The addresses to listen on: this node's tailnet addresses while Tailscale runs; none
    /// otherwise. A wildcard (or anything outside the node's own) is refused.
    nonisolated package static func addresses(_ status: TailnetStatus) throws -> [String] {
        guard status.backendState == .running, let me = status.selfNode, !me.tailscaleIPs.isEmpty else { return [] }
        try NetListener.check(me.tailscaleIPs, allowed: Set(me.tailscaleIPs))
        return me.tailscaleIPs
    }

    /// Whether the sockets bound now still fit: the same addresses, and the same `tailscale0`
    /// (a tailscaled restart makes a new interface: a socket held to the old index hears nothing).
    nonisolated static func keeps(want: [String], bound: [String], listening: Bool, boundIndex: Int32, index: Int32) -> Bool {
        listening && want == bound && boundIndex == index
    }

    /// Looks at Tailscale again and binds what it says (or closes, when it's stopped).
    package func rebind() {
        guard let tailnet else { return closeListeners() }
        let status: TailnetStatus
        do {
            status = try tailnet.status()
        } catch {
            if !bound.isEmpty { HostJournal.note("korenet closed", ["reason": "\(error)"]) }
            closeListeners()
            selfNode = nil
            return
        }
        selfNode = status.selfNode
        let want: [String]
        do {
            want = try Self.addresses(status)
        } catch {
            HostJournal.note("korenet refused", ["reason": "\(error)"])
            closeListeners()
            return
        }
        let index = interfaceIndex()
        if Self.keeps(want: want, bound: bound, listening: !listeners.isEmpty, boundIndex: boundIndex, index: index) { return }
        closeListeners()
        guard !want.isEmpty else { return }
        #if os(Linux)
        let device: String? = index > 0 ? Self.interface : nil
        // Userspace Tailscale has no interface: its addresses aren't this kernel's to bind.
        guard device != nil else {
            bindProblem = "no \(Self.interface) interface"
            return
        }
        #else
        let device: String? = nil
        #endif
        boundIndex = index
        var fds: [Int32] = []
        for address in want {
            var fd = device.map { kore_listen_on(address, port, $0, 16) } ?? kore_listen_on(address, port, nil, 16)
            // Kernels before 5.7 keep SO_BINDTODEVICE for CAP_NET_RAW: the tailnet address alone
            // (only `tailscale0` routes it) still holds the port to the tailnet.
            if fd < 0, errno == EPERM, device != nil {
                fd = kore_listen_on(address, port, nil, 16)
                if fd >= 0 { HostJournal.note("korenet bound by address", ["address": address, "reason": "SO_BINDTODEVICE not permitted"]) }
            }
            guard fd >= 0 else {
                let code = errno
                for open in fds { close(open) }
                bindProblem = code == EADDRINUSE ? "port \(port) in use" : String(cString: strerror(code))
                HostJournal.note("korenet bind failed", ["address": address, "port": "\(port)", "reason": bindProblem])
                return
            }
            fds.append(fd)
        }
        bindProblem = nil
        bound = want
        binds += 1
        for fd in fds {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll(fd) } }
            source.setCancelHandler { close(fd) }
            source.resume()
            listeners.append((fd, source))
        }
        busWatch?.cancel()
        busWatch = nil
        HostJournal.note("korenet listening", ["addresses": want.joined(separator: ","), "port": "\(port)"])
    }

    private func closeListeners() {
        for listener in listeners {
            // The descriptor closes in the source's cancel handler.
            listener.source.cancel()
        }
        listeners = []
        bound = []
    }

    /// Linux: netlink says when `tailscale0` or its addresses come or go. A Mac dev build: the
    /// IPN bus, held only until the port is bound.
    private func watchInterfaces() {
        #if os(Linux)
        let fd = kore_netlink_open()
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if kore_netlink_drain(fd, Self.interface, self.boundIndex) != 0 { self.rebind() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        netlink = (fd, source)
        #else
        guard let tailnet else { return }
        let events = tailnet.events()
        busWatch = Task { [weak self] in
            for await event in events {
                guard case .state = event else { continue }
                guard let self else { return }
                self.rebind()
                if !self.bound.isEmpty { return }
            }
        }
        #endif
    }

    // MARK: Accepting

    private func acceptAll(_ listener: Int32) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            guard fd >= 0 else { return }
            Self.noSigPipe(fd)
            // Room first: a connection turned away for capacity doesn't spend its source's limit.
            guard handshaking(.tailnet) < Self.maxHandshakes, let remote = Sockets.peerAddress(fd)?.description, limiter.admit(remote) else {
                close(fd)
                continue
            }
            whoisThenGreet(fd, remote: remote)
        }
    }

    /// WhoIs off the main thread (a local socket round trip), then the session. A WhoIs failure
    /// closes the connection: no node key is ever taken from the peer's own word.
    private func whoisThenGreet(_ fd: Int32, remote: String) {
        guard let tailnet else { return Sockets.closeFD(fd) }
        DispatchQueue.global(qos: .userInitiated).async {
            let who = try? tailnet.whois(remote)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let who else {
                        HostJournal.note("korenet refused", ["from": remote, "reason": "whois"])
                        return Sockets.closeFD(fd)
                    }
                    self.greet(fd, route: .tailnet, facts: Self.facts(who), whois: who)
                }
            }
        }
    }

    /// The peer as its WhoIs says: node key, user or tags, and Kore's app capability.
    nonisolated static func facts(_ who: TailnetWhoIs) -> NetPeerFacts {
        NetPeerFacts(
            nodeKey: who.node.key, userId: who.userId, tags: who.node.tags, cap: AppCap.abilities(capMap: who.capMap, tagged: !who.node.tags.isEmpty))
    }

    /// A connected socket's session, server side: the challenge goes now, the proof has 2 s.
    package func greet(_ fd: Int32, route: Binding.Route, facts: NetPeerFacts, whois: TailnetWhoIs?) {
        let nodeKey = route == .ssh ? Binding.Route.sshNodeKey : (selfNode?.publicKey ?? "")
        guard !nodeKey.isEmpty else { return Sockets.closeFD(fd) }
        let local = NetLocal(device: identity.device, kind: .box, nodeKey: nodeKey, signer: identity.signer)
        var setup = NetSession.Server(local: local, route: route, peer: facts, book: host.devices.book, tickets: tickets)
        setup.ownUser = selfNode?.owner
        setup.stranger = { [weak self] hello in
            MainActor.assumeIsolated { self?.stranger(hello, route: route, facts: facts, whois: whois) ?? .refuse(NetControl.Reason.unknown) }
        }
        let session = NetSession(fd: fd, role: .server(setup), clock: host.now)
        let shake = Handshake(session: session, route: route, facts: facts)
        let key = ObjectIdentifier(shake)
        handshakes[key] = shake
        // The session owns `fd` and closes it; the source watches its own duplicate, closed when
        // the source is cancelled.
        let watched = dup(fd)
        guard watched >= 0 else {
            handshakes[key] = nil
            return session.close(NetControl.Reason.limit)
        }
        let read = DispatchSource.makeReadSource(fileDescriptor: watched, queue: .main)
        read.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.advance(key) } }
        read.setCancelHandler { close(watched) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + NetSession.preAuthWindow + 0.05)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.advance(key) } }
        shake.read = read
        shake.deadline = timer
        session.start()
        read.resume()
        timer.resume()
    }

    /// Pumps a handshake: established goes to the daemon, closed is let go.
    private func advance(_ key: ObjectIdentifier) {
        guard let shake = handshakes[key] else { return }
        _ = shake.session.pump()
        switch shake.session.state {
        case .handshaking:
            return
        case .closed(let reason):
            shake.cancel()
            handshakes[key] = nil
            if reason == NetControl.Reason.timeout || reason == NetControl.Reason.limit {
                HostJournal.note("korenet refused", ["route": shake.route.rawValue, "reason": reason])
            }
        case .established(let peer):
            shake.cancel()
            handshakes[key] = nil
            established(shake, peer)
        }
    }

    private func established(_ shake: Handshake, _ peer: NetPeer) {
        let session = shake.session
        guard let verified = session.verified else { return session.close(NetControl.Reason.proof) }
        let id = peer.record.id.uuidString.lowercased()
        if case .appended(let dropped)? = session.nodeKeyAppend {
            HostJournal.audit("node-key", ["device": id, "dropped": dropped == nil ? nil : "1"])
        }
        let wire = NetLinkWire(session)
        host.accepted(wire, device: peer.record, peer: verified, route: shake.route)
    }

    // MARK: Strangers

    /// A hello from a device the book doesn't hold. Over SSH: the grant upgrade (`enroll` +
    /// `legacyGrant`), else refused. Over the tailnet: an owner Mac claiming this box, or pending.
    func stranger(_ hello: NetControl.Hello, route: Binding.Route, facts: NetPeerFacts, whois: TailnetWhoIs?) -> NetSession.Stranger {
        if route == .ssh {
            guard let enroll = hello.enroll, let legacy = hello.legacyGrant else { return .refuse(NetControl.Reason.unknown) }
            return upgrade(hello, enroll, legacy)
        }
        guard let whois else { return .refuse(NetControl.Reason.unknown) }
        // Shared-in nodes and other people's: closed, nothing kept.
        let ownerUser = selfNode?.owner
        let cap = AppCap.abilities(capMap: whois.capMap, tagged: !whois.node.tags.isEmpty)
        let sameUser = ownerUser != nil && whois.userId == ownerUser
        guard sameUser || cap != nil else { return .refuse(NetControl.Reason.unknown) }
        let now = host.now()
        let store = host.devices
        let fresh = PendingDevice(
            nodeKey: whois.node.key, device: hello.device, name: hello.enroll?.name ?? Self.shortName(whois.node.name), kind: hello.enroll?.kind,
            identityKey: hello.enroll?.identityKey, raiseKey: hello.enroll?.raiseKey, userId: whois.userId, tags: whois.node.tags,
            fqdn: whois.node.name, login: whois.user.loginName, at: now)
        // An unclaimed box: within 10 minutes of `kore-host join`, the first Mac of its own user
        // (or, for a tagged box, one Kore's app capability lets run) waits as its claimant until
        // its owner Allows it. Outside the window it's an ordinary pending device.
        let mayOwn = ownerUser == nil ? cap?.allows(.run) == true : sameUser
        if mayOwn, let enroll = hello.enroll, enroll.kind == .mac, !store.claimed {
            let window = NetJoin.open(host.paths, now: now)
            if let claimant = store.claimant, claimant.device == hello.device {
                // The claimant's device id is only the claimant's: its key, from its node.
                guard claimant.identityKey == enroll.identityKey, claimant.nodeKey == whois.node.key else {
                    HostJournal.audit("deny", ["node": whois.node.key, "device": hello.device.uuidString.lowercased(), "reason": "not the claimant"])
                    return .refuse(NetControl.Reason.unknown)
                }
                if enroll.claim == true {
                    guard window else {
                        HostJournal.audit("deny", ["device": hello.device.uuidString.lowercased(), "reason": "claim window closed"])
                        return .refuse(NetControl.Reason.unknown)
                    }
                    return claim(claimant, hello: hello)
                }
            } else if store.claimant == nil, window {
                var entry = fresh
                entry.claim = true
                notePending(entry, at: now)
                return .refuse(NetControl.Reason.unknown)
            }
        }
        notePending(fresh, at: now)
        return .refuse(NetControl.Reason.unknown)
    }

    private func notePending(_ entry: PendingDevice, at now: Date) {
        switch host.devices.notePending(entry, at: now) {
        case .added, .seen:
            HostJournal.audit("pending", [
                "node": entry.nodeKey, "device": entry.device.map { $0.uuidString.lowercased() }, "kind": entry.kind?.rawValue,
                "claim": entry.claim ? "1" : nil,
            ])
            host.pushPending()
        case .conflict:
            HostJournal.audit("deny", ["node": entry.nodeKey, "device": entry.device.map { $0.uuidString.lowercased() }, "reason": "pending conflict"])
        case .cooling, .full:
            break
        }
    }

    private func claim(_ claimant: PendingDevice, hello: NetControl.Hello) -> NetSession.Stranger {
        let now = host.now()
        guard let record = try? DeviceStore.record(from: claimant, owner: true, at: now) else { return .refuse(NetControl.Reason.unknown) }
        let host = host
        return .enroll(record) { _ in
            MainActor.assumeIsolated {
                let store = host.devices
                guard !store.claimed else { return false }
                do {
                    try store.book.update { devices in
                        devices.removeAll { $0.id == record.id }
                        devices.append(record)
                    }
                } catch {
                    return false
                }
                store.dropPending(device: record.id, nodeKey: claimant.nodeKey)
                HostJournal.audit("allow", ["device": record.id.uuidString.lowercased(), "kind": "mac", "how": "claim"])
                return true
            }
        }
    }

    /// The SSH → KoreNet upgrade: a grant's Mac enrolls as a device. The grant's secret is
    /// honoured once; the device's abilities follow the grant (full → run), the grant expires in
    /// 30 days, and the chats it held become the device's.
    private func upgrade(_ hello: NetControl.Hello, _ enroll: NetControl.Enroll, _ legacy: NetControl.LegacyGrant) -> NetSession.Stranger {
        let now = host.now()
        let grants = GrantStore(host.paths.grants)
        guard let grant = grants.load(legacy.name), Self.same(grant.secret, legacy.secret), !grant.expired(at: now) else {
            HostJournal.audit("deny", ["grant": legacy.name, "reason": "grant"])
            return .refuse(NetControl.Reason.grant)
        }
        guard grant.device == nil else {
            HostJournal.audit("deny", ["grant": legacy.name, "reason": "grant used"])
            return .refuse(NetControl.Reason.grant)
        }
        let kind = enroll.kind ?? .mac
        var abilities = grant.control.abilities
        if kind != .mac { abilities = abilities.intersection(DeviceStore.abilities(kind).effective) }
        let record = DeviceRecord(
            id: hello.device, name: enroll.name, kind: kind, abilities: abilities, owner: kind == .mac && grant.control == .full,
            identityKey: enroll.identityKey, nodeKeys: [Binding.Route.sshNodeKey], userId: nil, fqdn: "", raiseKey: enroll.raiseKey, added: now,
            lastSeen: now)
        guard (try? record.validate()) != nil, !abilities.isEmpty else { return .refuse(NetControl.Reason.refused) }
        let host = host
        return .enroll(record) { _ in
            MainActor.assumeIsolated {
                guard var used = grants.load(legacy.name), used.device == nil, used.secret == grant.secret else { return false }
                do {
                    try host.devices.book.update { devices in
                        guard !devices.contains(where: { $0.id == record.id }) else { throw TrustError.invalidRecord("duplicate id") }
                        devices.append(record)
                    }
                } catch {
                    return false
                }
                used.device = record.id
                used.expires = Int(now.addingTimeInterval(Grant.upgradeGrace).timeIntervalSince1970)
                do {
                    try grants.save(used)
                } catch {
                    _ = try? host.devices.book.remove(record.id)
                    return false
                }
                host.rehome(grant: legacy.name, to: record.id)
                HostJournal.audit("enroll", ["device": record.id.uuidString.lowercased(), "kind": kind.rawValue, "grant": legacy.name, "route": "ssh"])
                return true
            }
        }
    }

    /// A peer that went mid-write is an error to read, never SIGPIPE (macOS has no MSG_NOSIGNAL).
    nonisolated static func noSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Equal secrets, compared in constant time.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// `box-1.tail1234.ts.net.` → `box-1`.
    static func shortName(_ fqdn: String) -> String { String(fqdn.split(separator: ".").first ?? Substring(fqdn)) }

    // MARK: SSH (`attach --proto 2`)

    /// `net.sock` (0600, this user only): `attach --proto 2` passes an SSH session's bytes here.
    private func openSSH() {
        let path = host.paths.netSocket.path
        unlink(path)
        let fd = socket(AF_UNIX, Self.streamType, 0)
        guard fd >= 0 else { return }
        guard HostListener.bind(fd, path) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    guard let self, self.handshaking(.ssh) < Self.maxSSHHandshakes, HostListener.peerIsUser(client) else {
                        close(client)
                        continue
                    }
                    Self.noSigPipe(client)
                    self.greet(client, route: .ssh, facts: .ssh, whois: nil)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        ssh = (fd, source)
    }

    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif
}

/// A client's link over an established KoreNet session: link bodies (1.11) as messages on
/// stream 1, interactive queue. Woken by the socket only: a write source exists only while
/// something waits to go.
@MainActor
final class NetLinkWire: LinkWire {
    static let stream: UInt32 = 1
    private let session: NetSession
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var frame: (@MainActor (Data) -> Void)?
    private var ended: (@MainActor () -> Void)?
    private var done = false
    var drained: (@MainActor () -> Void)?
    /// The session's `bye` when this side ends it (the link's own reason).
    var reason = "quit"

    init(_ session: NetSession) { self.session = session }

    var backlog: Int { session.backlog }

    func start(max: Int, frame: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor () -> Void) {
        self.frame = frame
        self.ended = ended
        guard let watched = Self.watched(session.descriptor) else { return finish() }
        let source = DispatchSource.makeReadSource(fileDescriptor: watched, queue: .main)
        source.setCancelHandler { _ = Glue4.close(watched) }
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.pump() } }
        reader = source
        source.resume()
        // Anything that came with the handshake's last read.
        pump()
    }

    @discardableResult
    func send(_ payload: Data) -> Bool {
        guard !done else { return false }
        do {
            try session.send(payload, queue: .interactive, stream: Self.stream)
        } catch {
            finish()
            return false
        }
        guard session.backlog <= HostSocket.outboundCap else {
            reason = NetControl.Reason.limit
            close()
            ended?()
            return false
        }
        arm()
        return true
    }

    func close() {
        guard !done else { return }
        stopSources()
        session.close(reason)
        done = true
    }

    private func pump() {
        guard !done else { return }
        for message in session.pump() where !done { frame?(message.payload) }
        if case .closed = session.state { return finish() }
        arm()
        if session.backlog < HostSocket.lowWater { drained?() }
    }

    /// A write source while frames wait, none otherwise.
    private func arm() {
        guard !done else { return }
        // A write that failed ended the session (and closed its descriptor).
        if case .closed = session.state { return finish() }
        if session.wantsWrite {
            guard writer == nil else { return }
            guard let watched = Self.watched(session.descriptor) else { return finish() }
            let source = DispatchSource.makeWriteSource(fileDescriptor: watched, queue: .main)
            source.setCancelHandler { _ = Glue4.close(watched) }
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.pump() } }
            writer = source
            source.resume()
        } else {
            writer?.cancel()
            writer = nil
        }
    }

    /// A duplicate of the session's descriptor for one source (the session closes the
    /// original); the source closes it in its cancel handler.
    private static func watched(_ fd: Int32) -> Int32? {
        let copy = dup(fd)
        return copy >= 0 ? copy : nil
    }

    private func stopSources() {
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
    }

    private func finish() {
        guard !done else { return }
        done = true
        stopSources()
        ended?()
    }
}

/// Who holds a TCP port, from `/proc/net/tcp` and `tcp6` (Linux): `status` says "port 47470
/// held by uid N".
package enum PortHolder {
    /// The uid of the socket listening on `port` in these tables' text, if any.
    package static func uid(port: UInt16, tables: [String]) -> UInt32? {
        let hex = String(format: "%04X", port)
        for table in tables {
            for line in table.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count > 7, fields[1].uppercased().hasSuffix(":" + hex), fields[3] == "0A" else { continue }
                if let uid = UInt32(fields[7]) { return uid }
            }
        }
        return nil
    }

    package static func uid(port: UInt16) -> UInt32? {
        let tables = ["/proc/net/tcp", "/proc/net/tcp6"].compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        return uid(port: port, tables: tables)
    }
}

private enum Glue4 {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #else
        Musl.close(fd)
        #endif
    }
}

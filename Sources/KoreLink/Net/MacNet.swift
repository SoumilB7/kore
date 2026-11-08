import Darwin
import Foundation
import HostClient
import KoreNet
import KoreTrust
import KoreUI
import LinkProtocol
import Synchronization
import Tailnet

/// What the phone side needs of KoreNet on this Mac: in Kore, the KoreNet switch (step 5a: on/off,
/// the chosen tailnet, the identity, the device book); in tests, fakes.
@MainActor
package protocol MacNetHost: AnyObject, Sendable {
    /// The tailnet while KoreNet is on and one is chosen; nil while off (nothing then: no
    /// listener, no LocalAPI read).
    var tailnet: (any Tailnet)? { get }
    /// This Mac's device book: the boxes it dials, the phones it allowed.
    var book: DeviceBook { get }
    /// This Mac's name, for a phone's directory.
    var macName: String { get }
    /// How to read this Mac's identity (made on first use) while KoreNet is on. The reader may
    /// block on the Keychain: it's called off the main actor.
    func identityReader() -> (@Sendable () throws -> (device: UUID, signer: any IdentitySigner))?
}

/// Audit lines (phase 18 §1 "Audit"): `audit <event>` in hosts.log, ids and kinds only, never content.
@MainActor
package enum NetAudit {
    /// Tests: every line, as `event key=value…`.
    package static var watch: ((String) -> Void)?

    package static func line(_ event: String, _ fields: KeyValuePairs<String, String?>) {
        HostLog.audit(event, fields)
        if let watch {
            watch(([event] + fields.compactMap { key, value in value.map { "\(key)=\($0)" } }).joined(separator: " "))
        }
    }
}

/// Kore.app serving phones over KoreNet (phase 18 step 5b). The port (47470) is bound only to this
/// node's own tailnet addresses (`Status.Self.TailscaleIPs`, never a wildcard), and only while
/// KoreNet is on and either a phone is allowed here or the Add device window is open: a Mac with
/// no phone holds no socket. Each connection passes the pre-auth limits (3 a minute per address,
/// one frame of at most 4 KiB, 2 s) and a WhoIs, then the device's identity proof over B, before
/// anything else is decided: an unknown, paused or badly proven device is refused exactly as
/// kore-host refuses it. Inside the Add device window a phone of this Mac's own Tailscale user (or
/// a tagged node Kore's app capability lets in) waits for the owner's Allow card; shared-in nodes
/// are closed without a word. Allowed phones are welcomed with this Mac's directory, pushed to the
/// boxes it reaches (`devices.set`, merging), and served as `PhoneLink`s.
@MainActor
package final class MacNet {
    /// Kore's, while KoreNet is on (set by the switch).
    package static var shared: MacNet?

    nonisolated package static let port = NetListener.port
    /// The Add device window's length.
    package static var addWindowLength: TimeInterval = 600
    /// How long a held stranger waits (a little past its card).
    package static var holdFor: TimeInterval { DeviceAsks.wait + 10 }
    /// Handshakes under way at once; more are closed.
    package static let maxHandshakes = 16
    /// What a phone was sent, kept this long for its resume.
    package static var keepProjectors: TimeInterval = 120

    package let host: any MacNetHost
    package let feed: LinkFeed
    package let asks: DeviceAsks
    package let clock: @Sendable () -> Date
    private let limiter: PreAuthLimiter
    private let tickets = ResumeTickets()
    /// What the connection queues read of this Mac's state.
    private let shared = SharedState()

    final class SharedState: Sendable {
        private let lock = Mutex(Shared())
        func withLock<T>(_ body: (inout Shared) -> T) -> T { lock.withLock { body(&$0) } }
    }

    /// The pieces of this Mac's state a handshake reads off the main actor.
    struct Shared: Sendable {
        var addUntil: Date?
        var ownUser: Int64?
        var selfNode: TailnetStatus.SelfNode?
        var identity: (device: UUID, key: Data)?
        var macName = "Mac"
        var handshakes = 0
        /// How long a held stranger waits (a little past its card).
        var holdFor: TimeInterval = 110
    }

    package private(set) var addUntil: Date?
    private var addCancel: (() -> Void)?
    /// The listening sockets, and the addresses they're on.
    package private(set) var bound: [String] = []
    private var sockets: [TailnetListenSocket] = []
    private var sources: [DispatchSourceRead] = []
    private var listener: NetListener?
    package var listening: Bool { listener != nil }
    /// Binds made (tests).
    package private(set) var binds = 0
    private var generation = 0
    private let acceptQueue = DispatchQueue(label: "dev.kore.net.accept")
    package private(set) var phones: [UUID: PhoneLink] = [:]
    /// What changed, for tests awaiting it: `listening`, `closed`, `up <id>`, `gone <id>`, `kept <id>`.
    package var changed: (@MainActor (String) -> Void)?
    /// Handshakes held for an Allow, by connection.
    private var held: [ObjectIdentifier: (connection: PhoneConnection, ask: DeviceAsks.Ask)] = [:]
    /// Connections whose handshake is under way.
    private var shaking: [ObjectIdentifier: PhoneConnection] = [:]
    private var kept: [UUID: (projector: LinkProjector, at: Date)] = [:]
    /// Node keys first seen, for the card's line.
    private var firstSeen: [String: Date] = [:]

    /// Pushes the phones this Mac issued to the boxes it reaches (Kore: every held box link that
    /// takes a merging `devices.set`).
    package var pushDevices: @MainActor ([DeviceRecord]) -> Void = { records in MacNet.pushToBoxes(records) }
    /// Runs `work` after `seconds` (tests: a hand clock); the closure it gives back cancels.
    package var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
    /// Work off the main actor (tests: run inline).
    package var background: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.global(qos: .utility).async(execute: work) }
    /// Back on the main actor.
    package var foreground: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    package init(host: any MacNetHost, feed: LinkFeed = .shared, asks: DeviceAsks = DeviceAsks(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.feed = feed
        self.asks = asks
        self.clock = clock
        limiter = PreAuthLimiter(clock: clock)
        let name = host.macName
        let hold = Self.holdFor
        shared.withLock {
            $0.macName = name
            $0.holdFor = hold
        }
    }

    // MARK: When it listens

    /// The rule (owner, phase 18 §11 answer 3): KoreNet on, its tailnet running, and a phone
    /// allowed or the Add device window open.
    nonisolated package static func listens(on: Bool, running: Bool, phones: Int, addOpen: Bool) -> Bool {
        on && running && (phones > 0 || addOpen)
    }

    /// The addresses to bind: this node's tailnet addresses while Tailscale runs; none otherwise.
    /// A wildcard (or anything outside the node's own) is refused.
    nonisolated package static func addresses(_ status: TailnetStatus) throws -> [String] {
        guard status.backendState == .running, let me = status.selfNode, !me.tailscaleIPs.isEmpty else { return [] }
        try NetListener.check(me.tailscaleIPs, allowed: Set(me.tailscaleIPs))
        return me.tailscaleIPs
    }

    /// The Add device window is open now.
    package var addOpen: Bool { addUntil.map { clock() < $0 } ?? false }

    /// Phones this Mac allowed (its book's; paused ones too: they're refused, not forgotten).
    package func allowedPhones() -> [DeviceRecord] { ((try? host.book.read().devices) ?? []).filter { $0.kind == .phone } }

    /// Opens the Add device window for 10 minutes (step 7's "+" drives it): the port opens, and a
    /// phone's enroll is taken while it's open.
    package func openAddWindow() {
        let until = clock().addingTimeInterval(Self.addWindowLength)
        addUntil = until
        shared.withLock { $0.addUntil = until }
        addCancel?()
        addCancel = schedule(Self.addWindowLength) { [weak self] in self?.closeAddWindow() }
        NetAudit.line("add-window", ["open": "1"])
        refresh()
        Devices.shared.changed()
    }

    package func closeAddWindow() {
        guard addUntil != nil else { return }
        addUntil = nil
        shared.withLock { $0.addUntil = nil }
        addCancel?()
        addCancel = nil
        refusals = []
        refresh()
        Devices.shared.changed()
    }

    /// Tagged nodes without Kore's app capability turned away while the window is open: the one
    /// place a refusal shows (Devices, one quiet line each).
    package private(set) var refusals: [DeviceRefusal] = []

    /// This Mac's device id, once read (the first `refresh` reads it off the main actor).
    package var device: UUID? { shared.withLock { $0.identity?.device } }

    /// Looks again (KoreNet switched, Tailscale's state changed, a phone allowed or removed, the
    /// window opened or closed): binds what the rule and Tailscale say, or closes.
    package func refresh() {
        generation += 1
        let mine = generation
        guard let tailnet = host.tailnet, Self.listens(on: true, running: true, phones: allowedPhones().count, addOpen: addOpen) else {
            return close()
        }
        let name = host.macName
        shared.withLock { $0.macName = name }
        let had = bound
        let listening = self.listening
        let reader = host.identityReader()
        let foreground = foreground
        background { [weak self] in
            let status = try? tailnet.status()
            let want = status.flatMap { try? MacNet.addresses($0) } ?? []
            var made: [TailnetListenSocket]?
            var problem: String?
            if !want.isEmpty, !(listening && want == had) {
                do {
                    let sockets = try tailnet.listen(port: MacNet.port)
                    try MacNet.check(sockets, within: want)
                    made = sockets
                } catch {
                    problem = "\(error)"
                }
            }
            let identity = try? reader?()
            let found = (status, want, made, problem, identity)
            _ = self
            foreground { [weak self] in
                guard let self else {
                    for socket in made ?? [] { Sockets.closeFD(socket.fd) }
                    return
                }
                self.settle(mine, status: found.0, want: found.1, made: found.2, problem: found.3, identity: found.4)
            }
        }
    }

    private func settle(
        _ mine: Int, status: TailnetStatus?, want: [String], made: [TailnetListenSocket]?, problem: String?,
        identity: (device: UUID, signer: any IdentitySigner)?
    ) {
        guard mine == generation else {
            for socket in made ?? [] { Sockets.closeFD(socket.fd) }
            return
        }
        shared.withLock {
            $0.selfNode = status?.selfNode
            $0.ownUser = status?.selfNode?.owner
            if let identity { $0.identity = (identity.device, identity.signer.publicKey) }
        }
        if let identity { signer = identity.signer }
        guard !want.isEmpty else { return close() }
        if let problem { HostLog.note("korenet", "listen failed", problem) }
        guard let made else {
            if problem != nil { close() }
            return
        }
        close()
        let listener = NetListener(sockets: made, limiter: limiter)
        self.listener = listener
        bound = want
        binds += 1
        for socket in made { watch(socket, listener) }
        HostLog.note("korenet", "listening", want.joined(separator: ","))
        changed?("listening")
    }

    /// Every TCP socket the tailnet bound is on one of this node's tailnet addresses.
    nonisolated static func check(_ sockets: [TailnetListenSocket], within allowed: [String]) throws {
        for socket in sockets {
            guard case .tcp(let fd) = socket else { continue }
            guard let address = localAddress(fd), allowed.contains(address) else {
                for socket in sockets { Sockets.closeFD(socket.fd) }
                throw SocketError.badAddress(localAddress(fd) ?? "?")
            }
        }
    }

    nonisolated static func localAddress(_ fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard ok == 0 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let named = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) }
        }
        guard named == 0 else { return nil }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.split(separator: "%").first.map(String.init)
    }

    /// No port: the sockets and their sources go (links already up stay until KoreNet goes off).
    private func close() {
        let was = listener != nil || !bound.isEmpty
        for source in sources { source.cancel() }
        sources = []
        sockets = []
        if !bound.isEmpty { HostLog.note("korenet", "closed", nil) }
        bound = []
        listener = nil
        if was { changed?("closed") }
    }

    /// KoreNet went off: the port, every phone and every handshake go.
    package func stop() {
        generation += 1
        close()
        closeAddWindow()
        for phone in Array(phones.values) { phone.end(NetControl.Reason.refused) }
        for (_, entry) in held { asks.cancel(entry.ask) }
        for connection in shaking.values { connection.end(NetControl.Reason.refused) }
        held = [:]
        shaking = [:]
    }

    private func watch(_ socket: TailnetListenSocket, _ listener: NetListener) {
        if case .tcp(let fd) = socket { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: acceptQueue)
        let accepted: @Sendable (Int32, String) -> Void = { [weak self] fd, remote in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.whois(fd, remote: remote) ?? Sockets.closeFD(fd) } }
        }
        source.setEventHandler {
            while true {
                guard let next = try? listener.accept(on: socket) else { return }
                accepted(next.fd, next.remote)
                // The sidecar's handoff socket gives one connection per message.
                if case .handoff = socket { return }
            }
        }
        source.setCancelHandler { Sockets.closeFD(socket.fd) }
        sources.append(source)
        source.resume()
    }

    // MARK: Connections

    /// WhoIs off the main actor, then the session. A WhoIs that fails closes the connection: no
    /// node key is ever taken from the peer's own word.
    private func whois(_ fd: Int32, remote: String) {
        guard let tailnet = host.tailnet else { return Sockets.closeFD(fd) }
        guard shared.withLock({ $0.handshakes }) < Self.maxHandshakes else { return Sockets.closeFD(fd) }
        let foreground = foreground
        background { [weak self] in
            let who = try? tailnet.whois(remote)
            _ = self
            foreground { [weak self] in
                guard let self, let who else {
                    HostLog.note("korenet", "refused", "whois")
                    return Sockets.closeFD(fd)
                }
                self.greet(fd, remote: remote, whois: who)
            }
        }
    }

    /// The peer as its WhoIs says: node key, user or tags, and Kore's app capability.
    nonisolated static func facts(_ who: TailnetWhoIs) -> NetPeerFacts {
        NetPeerFacts(
            nodeKey: who.node.key, userId: who.userId, tags: who.node.tags, cap: AppCap.abilities(capMap: who.capMap, tagged: !who.node.tags.isEmpty))
    }

    /// A connected socket's session, server side (tests hand theirs here as an accepted
    /// connection would come).
    package func greet(_ fd: Int32, remote: String, whois: TailnetWhoIs) {
        let state = shared.withLock { $0 }
        if addOpen, let tag = whois.node.tags.first, AppCap.abilities(capMap: whois.capMap, tagged: true) == nil {
            let name = Self.shortName(whois.node.name)
            if !refusals.contains(where: { $0.name == name }) {
                refusals.append(DeviceRefusal(name: name, tag: tag))
                Devices.shared.changed()
            }
        }
        guard let identity = state.identity, let me = state.selfNode, let signer else {
            return Sockets.closeFD(fd)
        }
        let local = NetLocal(device: identity.device, kind: .mac, nodeKey: me.publicKey, signer: signer)
        var setup = NetSession.Server(local: local, route: .tailnet, peer: Self.facts(whois), book: host.book, tickets: tickets)
        setup.ownUser = me.owner
        let shared = shared
        let clock = clock
        setup.stranger = { hello in MacNet.stranger(hello, whois: whois, state: shared.withLock { $0 }, now: clock()) }
        let book = host.book
        setup.directory = { record in record.kind == .phone ? MacNet.directory(state: shared.withLock { $0 }, book: book) : nil }
        let seen = firstSeen[whois.node.key] ?? clock()
        if firstSeen[whois.node.key] == nil {
            if firstSeen.count > 256 { firstSeen = [:] }
            firstSeen[whois.node.key] = seen
        }
        let box = WeakNet(self)
        let connection = PhoneConnection(fd: fd, setup: setup, remote: remote, whois: whois, firstSeen: seen, clock: clock) { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let net = box.net, let connection = box.connection else { return }
                    net.heard(event, from: connection)
                }
            }
        }
        box.connection = connection
        shaking[ObjectIdentifier(connection)] = connection
        shared.withLock { $0.handshakes += 1 }
        connection.start()
    }

    /// The identity's signer: read (the Keychain) off the main actor at a `refresh`.
    private var signer: (any IdentitySigner)?

    /// A stranger's hello: inside the Add device window, a phone of this Mac's own user (or a
    /// tagged node with Kore's app capability, read+ask at most) waits for the owner's card.
    /// Anything else is refused (`bye unknown`), nothing kept: shared-in nodes, other people's,
    /// enrolls outside the window.
    nonisolated static func stranger(_ hello: NetControl.Hello, whois: TailnetWhoIs, state: Shared, now: Date) -> NetSession.Stranger {
        guard let enroll = hello.enroll, (enroll.kind ?? .phone) == .phone, let until = state.addUntil, now < until,
              let issuer = state.identity?.device
        else { return .refuse(NetControl.Reason.unknown) }
        let tagged = !whois.node.tags.isEmpty
        let abilities: Ability
        if tagged {
            guard let cap = AppCap.abilities(capMap: whois.capMap, tagged: true) else { return .refuse(NetControl.Reason.unknown) }
            abilities = cap.effective.intersection(AppCap.taggedCap)
        } else {
            guard let own = state.ownUser, whois.userId == own else { return .refuse(NetControl.Reason.unknown) }
            abilities = [.read, .ask]
        }
        guard !abilities.isEmpty else { return .refuse(NetControl.Reason.unknown) }
        let record = DeviceRecord(
            id: hello.device, name: clean(enroll.name), kind: .phone, abilities: abilities, owner: false, identityKey: enroll.identityKey,
            nodeKeys: [whois.node.key], userId: tagged ? nil : whois.userId, tags: whois.node.tags, fqdn: whois.node.name, raiseKey: enroll.raiseKey,
            issuedBy: issuer, added: now, lastSeen: now)
        guard (try? record.validate()) != nil else { return .refuse(NetControl.Reason.unknown) }
        return .hold(record, seconds: state.holdFor)
    }

    /// What a phone's welcome tells it: this Mac's record first (pinned on first contact), then
    /// the boxes it knows on the tailnet (public data only).
    nonisolated static func directory(state: Shared, book: DeviceBook) -> [DeviceRecord]? {
        guard let identity = state.identity, let me = state.selfNode else { return nil }
        let tagged = !(me.tags ?? []).isEmpty
        let mac = DeviceRecord(
            id: identity.device, name: state.macName, kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: identity.key,
            nodeKeys: [me.publicKey], userId: tagged ? nil : me.userID, tags: me.tags ?? [], fqdn: me.dnsName, added: Date(timeIntervalSince1970: 0))
        var out = [mac]
        for record in (try? book.read().devices) ?? [] where record.kind == .box && !record.isPaused {
            var box = record
            box.nodeKeys = record.nodeKeys.filter { $0 != Binding.Route.sshNodeKey }
            box.raiseKey = nil
            guard !box.nodeKeys.isEmpty, (try? box.validate()) != nil else { continue }
            out.append(box)
        }
        return out
    }

    private func heard(_ event: PhoneConnection.Event, from connection: PhoneConnection) {
        let key = ObjectIdentifier(connection)
        switch event {
        case .held(let record):
            NetAudit.line("enroll", ["device": record.id.uuidString.lowercased(), "kind": record.kind.rawValue, "node": connection.whois.node.key])
            let info = DeviceCardInfo.phone(
                name: record.name, node: Self.shortName(connection.whois.node.name), address: connection.remote, login: connection.whois.user.loginName,
                firstSeen: connection.firstSeen)
            let ask = asks.ask(info) { [weak self] answer in self?.answered(answer, record: record, connection: connection) }
            held[key] = (connection, ask)
        case .established(let peer, let binding):
            shaking[key] = nil
            shared.withLock { $0.handshakes = max(0, $0.handshakes - 1) }
            phoneUp(peer, connection: connection, binding: binding)
        case .messages(let incoming, let record, let settled, let cursors):
            for phone in phones.values where phone.connection === connection {
                phone.take(incoming, record: record, cursorsSettled: settled, cursors: cursors)
            }
        case .closed(let reason):
            if shaking.removeValue(forKey: key) != nil { shared.withLock { $0.handshakes = max(0, $0.handshakes - 1) } }
            if let entry = held.removeValue(forKey: key) { asks.cancel(entry.ask) }
            if let phone = phones.values.first(where: { $0.connection === connection }) {
                if !phone.ended { HostLog.note("korenet", "phone gone", reason) }
                phone.gone()
            }
        }
    }

    /// The owner's answer to a phone's card.
    private func answered(_ answer: DeviceAsks.Answer, record: DeviceRecord, connection: PhoneConnection) {
        held[ObjectIdentifier(connection)] = nil
        let id = record.id.uuidString.lowercased()
        switch answer {
        case .allow:
            do {
                try host.book.update { devices in
                    devices.removeAll { $0.id == record.id }
                    devices.append(record)
                }
            } catch {
                NetAudit.line("deny", ["device": id, "reason": "book"])
                return connection.admit(nil)
            }
            NetAudit.line("allow", ["device": id, "kind": record.kind.rawValue])
            connection.admit(record)
            phonesChanged()
        case .deny:
            NetAudit.line("deny", ["device": id])
            connection.admit(nil, reason: NetControl.Reason.refused)
        case .timeout:
            NetAudit.line("deny", ["device": id, "reason": "timeout"])
            connection.admit(nil, reason: NetControl.Reason.timeout)
        case .gone:
            break
        }
    }

    /// The phones changed: the boxes hear (merging, only what this Mac issued), the port follows.
    package func phonesChanged() {
        let state = shared.withLock { $0 }
        // Every record this Mac issued (its phones, and devices it allowed at a box).
        let mine = ((try? host.book.read().devices) ?? []).filter { $0.kind != .mac && $0.issuedBy == state.identity?.device }
        pushDevices(mine)
        refresh()
        Devices.shared.changed()
    }

    private func phoneUp(_ peer: NetPeer, connection: PhoneConnection, binding: Data) {
        // One link per phone: a newer one takes over.
        if let old = phones[peer.record.id] { old.end(LinkMessage.ByeReason.replaced.rawValue) }
        let phone = PhoneLink(net: self, record: peer.record, connection: connection, binding: binding, resumed: peer.resumed)
        phones[peer.record.id] = phone
        NetAudit.line("connect", ["device": peer.record.id.uuidString.lowercased(), "resumed": peer.resumed ? "1" : nil])
        StayAwakePhones.connected(phones.count)
        changed?("up \(peer.record.id.uuidString)")
        Devices.shared.changed()
        if phone.waitsForCursors {
            // Its cursors come first; a phone with none sends something else, or a second goes by.
            _ = schedule(1) { [weak phone] in phone?.beginIfWaiting() }
        } else {
            phone.begin(cursors: nil)
        }
    }

    func phoneGone(_ phone: PhoneLink) {
        if phones[phone.id] === phone { phones[phone.id] = nil }
        StayAwakePhones.connected(phones.count)
        changed?("gone \(phone.id.uuidString)")
        Devices.shared.changed()
    }

    // MARK: Resume

    func retain(_ id: UUID, _ projector: LinkProjector) {
        guard projector.started else { return }
        kept[id] = (projector, clock())
        changed?("kept \(id.uuidString)")
    }

    /// What `id` was last sent, when it's still kept and at `rev`.
    func retained(_ id: UUID, rev: Int) -> LinkProjector? {
        let now = clock()
        kept = kept.filter { now.timeIntervalSince($0.value.at) < Self.keepProjectors }
        guard let entry = kept.removeValue(forKey: id), entry.projector.rev == rev else { return nil }
        return entry.projector
    }

    // MARK: A new fingerprint key

    /// `raise.key{pub}`: a new `kore_raise` (a new fingerprint enrolled on the phone). It's taken
    /// only once the owner Allows it on the card; until then raises fail.
    func newRaiseKey(_ phone: PhoneLink, id: String, pub: Data) {
        let device = phone.id
        let info = DeviceCardInfo(
            title: "\(phone.record.name): new fingerprint key", note: "Raises from this phone will take the new fingerprint.",
            node: Self.shortName(phone.connection.whois.node.name), address: phone.connection.remote, login: phone.connection.whois.user.loginName,
            firstSeen: phone.connection.firstSeen, kind: .phone, name: phone.record.name)
        NetAudit.line("raise-key", ["device": device.uuidString.lowercased(), "asked": "1"])
        asks.ask(info) { [weak self, weak phone] answer in
            guard let self else { return }
            let resultId = "\(LinkRaiseWire.key):\(id)"
            guard answer == .allow else {
                NetAudit.line("deny", ["device": device.uuidString.lowercased(), "what": "raise-key", "reason": answer == .timeout ? "timeout" : nil])
                phone?.answer(.init(id: resultId, ok: false, code: .raiseMode, message: answer == .timeout ? "The Mac didn't answer in time." : "Not allowed on the Mac."))
                return
            }
            do {
                try self.host.book.update { devices in
                    guard let i = devices.firstIndex(where: { $0.id == device }) else { throw TrustError.unknownDevice }
                    devices[i].raiseKey = pub
                }
            } catch {
                phone?.answer(.init(id: resultId, ok: false, code: .goneChat, message: "This phone isn't allowed here any more."))
                return
            }
            NetAudit.line("allow", ["device": device.uuidString.lowercased(), "what": "raise-key"])
            phone?.answer(.init(id: resultId, ok: true))
            self.phonesChanged()
        }
    }

    // MARK: Boxes

    /// The phones this Mac issued, to every box link that takes a merging `devices.set`.
    package static func pushToBoxes(_ records: [DeviceRecord]) {
        for connection in HostConnection.held where connection.caps.contains(DevicesWire.mergeCap) {
            let set = DevicesWire.Set(id: UUID().uuidString, rev: 0, records: records, merge: true)
            _ = connection.post(DevicesWire.encode(set))
        }
    }

    /// A self-given name as a card shows it: printable, one line, at most 64 characters.
    nonisolated static func clean(_ name: String) -> String {
        let kept = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? "A phone" : String(kept.prefix(64))
    }

    /// `box-1.tail1234.ts.net.` → `box-1`.
    nonisolated static func shortName(_ fqdn: String) -> String { String(fqdn.split(separator: ".").first ?? Substring(fqdn)) }

    // MARK: Tests

    /// Learns this node's state and identity now (tests; `refresh` does it in Kore).
    package func learn(status: TailnetStatus, identity: (device: UUID, signer: any IdentitySigner)) {
        signer = identity.signer
        shared.withLock {
            $0.selfNode = status.selfNode
            $0.ownUser = status.selfNode?.owner
            $0.identity = (identity.device, identity.signer.publicKey)
        }
    }

    /// Handshakes under way.
    package var handshaking: Int { shaking.count }

    /// What `id` was last sent is kept for its resume.
    package func keeps(_ id: UUID) -> Bool { kept[id] != nil }
}

/// A weak reference to the net and its connection, handed to the connection's queue (set before
/// the connection starts, read on the main actor only).
private final class WeakNet: @unchecked Sendable {
    weak var net: MacNet?
    weak var connection: PhoneConnection?
    init(_ net: MacNet) { self.net = net }
}

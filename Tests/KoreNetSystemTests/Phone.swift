import Darwin
import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet

/// One KoreNet session pumped by its socket on a queue of its own (as the phone's are), its
/// events handed to the main actor.
final class Wire: @unchecked Sendable {
    enum Event: Sendable {
        case up(NetPeer, [DeviceRecord]?)
        case message([String: JSONValue])
        case closed(String)
    }

    private let queue = DispatchQueue(label: "kns.phone.wire")
    private let session: NetSession
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var toldUp = false
    private var toldClosed = false
    private let told: @Sendable (Event) -> Void

    init(_ session: NetSession, told: @escaping @Sendable (Event) -> Void) {
        self.session = session
        self.told = told
        queue.async { [self] in
            let fd = Darwin.dup(self.session.descriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.pump() }
            source.setCancelHandler { Darwin.close(fd) }
            reader = source
            source.resume()
            pump()
        }
    }

    deinit {
        reader?.cancel()
        writer?.cancel()
    }

    func send(_ json: String) {
        queue.async { [self] in
            try? session.send(Data(json.utf8), queue: .interactive, stream: 1)
            pump()
        }
    }

    /// The phone's side goes (the app quit, the link dropped): its socket closes.
    func close(_ reason: String = "quit") {
        queue.async { [self] in
            session.close(reason)
            pump()
        }
    }

    private func pump() {
        guard !toldClosed else { return }
        let messages = session.pump()
        if case .established(let peer) = session.state, !toldUp {
            toldUp = true
            told(.up(peer, session.directory))
        }
        for message in messages {
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: message.payload) else { continue }
            told(.message(object))
        }
        if case .closed(let why) = session.state {
            toldClosed = true
            reader?.cancel()
            writer?.cancel()
            told(.closed(why))
            return
        }
        if session.wantsWrite, writer == nil {
            let fd = Darwin.dup(session.descriptor)
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.writer?.cancel()
                self.writer = nil
                self.pump()
            }
            source.setCancelHandler { Darwin.close(fd) }
            writer = source
            source.resume()
        }
    }
}

/// The wire a callback belongs to, set once it's made.
final class Slot: @unchecked Sendable {
    weak var wire: Wire?
}

/// The phone's `NodeMachine` (android/link node/NodeMachine.kt), line for line, on virtual time.
struct NodeMachine: Equatable {
    enum AwayWhy: String { case asleep, off, unreachable, waiting }
    enum State: Equatable {
        case idle, connecting, awaitingAllow, up
        case away(AwayWhy, at: Int64?, attempt: Int)
        case denied(String)
        case removed, signedOut
    }
    enum Event: Equatable {
        case start, stop, enrolling, connected, failed, ended(String?), peerOffline, peerOnline, trigger, signedOut, signedIn, allowed, tick
    }

    static let capMS: Int64 = 300_000
    /// A box waiting for its Mac's push is tried at least this often while on screen.
    static let waitingCapMS: Int64 = 60_000
    private(set) var state = State.idle
    private var attempt = 0
    /// A box's machine: `unknown` there means its Mac's push is on its way.
    var box = false

    mutating func on(_ event: Event, now: Int64) {
        let s = state
        switch event {
        case .start: if s == .idle { state = connecting(reset: true) }
        case .stop: state = .idle
        case .enrolling: if s == .connecting { state = .awaitingAllow }
        case .connected:
            attempt = 0
            state = .up
        case .failed: if s == .connecting || s == .awaitingAllow { state = backoff(now, .unreachable) }
        case .ended(let reason): if !passive(s) { state = ended(reason, now) }
        case .peerOffline:
            switch s {
            case .connecting, .away: state = .away(.asleep, at: nil, attempt: 0)
            default: break
            }
        case .peerOnline: if case .away = s { state = connecting(reset: true) }
        case .trigger:
            switch s {
            case .away, .denied: state = connecting(reset: true)
            default: break
            }
        case .signedOut: if s != .idle && s != .removed { state = .signedOut }
        case .signedIn: if s == .signedOut { state = connecting(reset: true) }
        case .allowed:
            switch s {
            case .removed, .denied, .away, .signedOut: state = connecting(reset: true)
            default: break
            }
        case .tick: if case .away(_, let at?, _) = s, now >= at { state = connecting(reset: false) }
        }
    }

    var wakeAt: Int64? { if case .away(_, let at, _) = state { at } else { nil } }

    private func passive(_ s: State) -> Bool { s == .idle || s == .removed || s == .signedOut }

    private mutating func ended(_ reason: String?, _ now: Int64) -> State {
        switch reason {
        case "revoked": return .removed
        case "unknown": return box ? backoff(now, .waiting, cap: Self.waitingCapMS) : .denied("unknown")
        case "refused", "proof": return .denied(reason!)
        case "paused": return .away(.off, at: nil, attempt: 0)
        case "online": return connecting(reset: true)
        case "quit", "sleep": return .away(.asleep, at: now + Self.capMS, attempt: 0)
        case "abandoned": return connecting(reset: true)
        default: return state == .awaitingAllow && reason == nil ? .denied("closed") : backoff(now, .unreachable)
        }
    }

    private mutating func connecting(reset: Bool) -> State {
        if reset { attempt = 0 }
        return .connecting
    }

    private mutating func backoff(_ now: Int64, _ why: AwayWhy, cap: Int64 = NodeMachine.capMS) -> State {
        let base = min(Double(cap), 1000.0 * Double(1 << min(attempt, 16)))
        attempt += 1
        return .away(why, at: now + Int64(base), attempt: attempt)
    }
}

/// A Home row on the phone: the node's name, its pill (`stateWords`) and glyph (`nodeLook`).
struct PhoneRow: Equatable, CustomStringConvertible {
    var id: UUID
    var kind: NodeKind
    var name: String
    var words: String
    var glyph: String
    var description: String { "\(glyph) \(name)\(words.isEmpty ? "" : " " + words)" }

    static func words(_ s: NodeMachine.State) -> String {
        switch s {
        case .up: ""
        case .connecting: "● Reconnecting"
        case .awaitingAllow: "● Waiting for Allow"
        case .away(let why, _, _):
            switch why {
            case .asleep: "● Asleep"
            case .off: "● Offline"
            case .unreachable: "● Offline · retrying"
            case .waiting: "● Waiting for MacBook"
            }
        case .denied: "● Not allowed"
        case .removed: "● Removed"
        case .signedOut: "● Signed out"
        case .idle: "● Off"
        }
    }

    static func glyph(_ s: NodeMachine.State) -> String {
        switch s {
        case .up: "●"
        case .connecting, .awaitingAllow: "◌"
        case .denied, .removed: "○!"
        default: "○"
        }
    }
}

/// The Android app's `:link` (JoinFlow, NodeClient, NetDialer) as Swift over the real `KoreNet`
/// client session: the Join screen knocking on the tailnet's Macs, Allow on the Mac, the Mac's
/// directory kept, one node client per Mac and box with its own `NodeMachine`, resume tickets,
/// presence on each new link, and the tailnet's peer changes as triggers.
///
/// One shortcut: the Swift client session dials a server it already has a record of, so first
/// contact is given the Mac's record (the app pins it from the Mac's welcome).
@MainActor
final class PhoneEmu {
    enum JoinStep: Equatable, CustomStringConvertible {
        case join, finding(addClosed: Bool), allowing(String), denied(String), noMac, joined(String)
        var description: String {
            switch self {
            case .join: "Join"
            case .finding(let closed): closed ? "Finding your Mac · Add window closed" : "Finding your Mac…"
            case .allowing(let mac): "Allow on \(mac)"
            case .denied(let mac): "Not allowed on \(mac)"
            case .noMac: "No Mac"
            case .joined(let mac): "Joined \(mac)"
            }
        }
    }

    final class Client {
        var record: DeviceRecord
        var machine = NodeMachine()
        var wire: Wire?
        var dialing = false
        var ticket: Data?
        var hostName: String?
        var rev: Int?
        var wake: Task<Void, Never>?
        /// Taken offline on the Mac: the link stays, parked, until its `bye online`.
        var parked = false
        init(_ record: DeviceRecord) {
            self.record = record
            machine.box = record.kind == .box
        }
    }

    let label: String
    var name: String
    private(set) var device = UUID()
    private(set) var key = SoftwareIdentity()
    private(set) var raise = SoftwareIdentity()
    private(set) var ip: String
    private(set) var nodeKey: String
    private let net: SharedTailnet
    private let clock: VirtualClock
    private let pulse: Pulse
    private let folder: URL
    private let macRecord: @MainActor () -> DeviceRecord
    private(set) var step = JoinStep.join
    /// The nodes it keeps (the app's own store): the Mac, then the boxes its directory listed.
    private(set) var known: [DeviceRecord] = []
    private(set) var clients: [UUID: Client] = [:]
    private(set) var running = false
    private var knocking: Task<Void, Never>?
    private var bus: Task<Void, Never>?
    private var generation = 0
    private var reinstalls = 0
    /// Every node's machine state as it changed (debugging a stuck run).
    private(set) var trail: [String] = []

    init(label: String, name: String, ip: String, net: SharedTailnet, clock: VirtualClock, pulse: Pulse, folder: URL, mac: @escaping @MainActor () -> DeviceRecord) {
        self.label = label
        self.name = name
        self.ip = ip
        nodeKey = "nodekey:\(label)"
        self.net = net
        self.clock = clock
        self.pulse = pulse
        self.folder = folder
        macRecord = mac
    }

    private var tailnet: NodeNet { NodeNet(net, ip: ip) }

    // MARK: The owner's taps

    /// "Join KoreNet": signs in to Tailscale (the embedded tailnet) and knocks on the Macs.
    func join() {
        if net.node(ip) == nil { net.add(SharedTailnet.Node(name: label, kind: .phone, ip: ip, nodeKey: nodeKey, bindIP: ip)) }
        net.setState(ip, .running)
        running = true
        listenToTailnet()
        knocking?.cancel()
        step = .finding(addClosed: false)
        let mine = generation
        knocking = Task { await self.knock(mine) }
        pulse.beat()
    }

    /// The app is killed and opened again: links go (sockets close), tickets with them; the
    /// nodes it keeps start again.
    func restart() {
        stopAll()
        start()
    }

    /// The app reinstalled: a new device id and keys; with `newNode`, a new tailnet node too.
    func reinstall(newNode: Bool) {
        stopAll()
        known = []
        clients = [:]
        step = .join
        device = UUID()
        key = SoftwareIdentity()
        raise = SoftwareIdentity()
        reinstalls += 1
        if newNode {
            net.remove(ip)
            ip = ip.split(separator: ".").dropLast().joined(separator: ".") + ".\(200 + reinstalls)"
            nodeKey = "nodekey:\(label)-\(reinstalls)"
        }
        pulse.beat()
    }

    func quit() {
        stopAll()
    }

    private func stopAll() {
        generation += 1
        running = false
        knocking?.cancel()
        bus?.cancel()
        bus = nil
        for client in clients.values {
            client.wake?.cancel()
            client.wire?.close("quit")
            client.wire = nil
            client.ticket = nil
            client.dialing = false
            client.machine.on(.stop, now: clock.nowMS)
        }
    }

    private func start() {
        guard step.isJoined else { return }
        running = true
        listenToTailnet()
        for record in known { client(record).machine.on(.start, now: clock.nowMS) }
        for c in clients.values { drive(c) }
        pulse.beat()
    }

    // MARK: Join

    private func knock(_ mine: Int) async {
        let started = clock.now
        while generation == mine, !Task.isCancelled, clock.now - started < .seconds(600) {
            let status = net.status(of: ip)
            let macs = status.peers.filter { $0.os == "macOS" && $0.online && $0.tags.isEmpty && $0.userID == status.selfNode?.userID }
            for mac in macs {
                let outcome = await enroll(mac)
                guard generation == mine else { return }
                switch outcome {
                case .joined: return
                case .unknown: step = .finding(addClosed: true)
                case .refused:
                    step = .denied(mac.hostName)
                    return
                case .unreachable: break
                }
            }
            if case .finding(true) = step { await clock.wait(.seconds(20)) } else { await clock.wait(.seconds(2)) }
        }
        if generation == mine, !step.isJoined, case .finding = step { step = .noMac }
        pulse.beat()
    }

    private enum Knock { case joined, unknown, refused, unreachable }

    private func enroll(_ mac: TailnetStatus.Peer) async -> Knock {
        guard let address = mac.tailscaleIPs.first, let fd = try? tailnet.dial(address, port: NetListener.port) else { return .unreachable }
        guard let who = try? tailnet.whois(address) else {
            Sockets.closeFD(fd)
            return .unreachable
        }
        let pinned = macRecord()
        let book = DeviceBook(url: folder.appendingPathComponent("enroll-\(UUID().uuidString.prefix(6)).json"))
        _ = try? book.update { $0 = [pinned] }
        var setup = NetSession.Client(
            local: NetLocal(device: device, kind: .phone, nodeKey: nodeKey, signer: key), route: .tailnet,
            peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId), book: book, server: pinned.id, service: "link")
        setup.enroll = .init(name: name, kind: .phone, identityKey: key.publicKey, raiseKey: raise.publicKey)
        step = .allowing(mac.hostName)
        pulse.beat()
        let ended = Feed<Wire.Event>()
        let wire = Wire(NetSession(fd: fd, role: .client(setup))) { event in
            switch event {
            case .up, .closed: ended.send(event)
            case .message: break
            }
        }
        let event = await ended.next()
        switch event {
        case .up(let peer, let directory):
            wire.close("quit")
            joined(peer.record, directory: directory ?? [])
            return .joined
        case .closed(let why):
            if why == "bye \(NetControl.Reason.unknown)" { return .unknown }
            if why.hasPrefix("bye ") { return .refused }
            return .unreachable
        case .message:
            return .unreachable
        }
    }

    /// The Mac's welcome: pin it, keep its directory, go Home; its node client dials at once.
    private func joined(_ mac: DeviceRecord, directory: [DeviceRecord]) {
        step = .joined(mac.name)
        known = [mac]
        keepDirectory(directory)
        let c = client(mac)
        c.ticket = nil
        c.machine.on(.allowed, now: clock.nowMS)
        c.machine.on(.start, now: clock.nowMS)
        for c in clients.values { drive(c) }
        pulse.beat()
    }

    /// The boxes an owner Mac's directory lists (its own record first).
    private func keepDirectory(_ directory: [DeviceRecord]) {
        let boxes = directory.filter { $0.kind == .box }
        guard let mac = known.first(where: { $0.kind == .mac }) else { return }
        known = [mac] + boxes
        for box in boxes where clients[box.id] == nil {
            let c = client(box)
            if running {
                c.machine.on(.start, now: clock.nowMS)
                drive(c)
            }
        }
        for box in boxes { clients[box.id]?.record = box }
        // A box the Mac names now holds this phone, or can be reached: tried again at once
        // (`NodeClient.named`); boxes that said `paused` hear the Mac took it back.
        for box in boxes {
            guard let c = clients[box.id], running, !c.parked else { continue }
            switch c.machine.state {
            case .denied, .away(.waiting, _, _), .away(.unreachable, _, _), .away(.off, _, _):
                c.machine.on(.trigger, now: clock.nowMS)
                drive(c)
            case .removed:
                // Named again by the Mac: allowed again (`NodeClient.named` on a box).
                c.ticket = nil
                c.machine.on(.allowed, now: clock.nowMS)
                drive(c)
            default: break
            }
        }
    }

    private func client(_ record: DeviceRecord) -> Client {
        if let c = clients[record.id] { return c }
        let c = Client(record)
        clients[record.id] = c
        return c
    }

    // MARK: Node clients

    private func drive(_ c: Client) {
        trail.append("\(c.record.name):\(c.machine.state)")
        c.wake?.cancel()
        c.wake = nil
        if let at = c.machine.wakeAt {
            let wait = Duration.milliseconds(max(0, at - clock.nowMS))
            let id = c.record.id
            c.wake = Task { [weak self] in
                await self?.clock.wait(wait)
                guard !Task.isCancelled, let self, let c = self.clients[id], !c.parked else { return }
                c.machine.on(.tick, now: self.clock.nowMS)
                self.drive(c)
            }
        }
        if running, c.machine.state == .connecting, !c.dialing, c.wire == nil { dial(c) }
        pulse.beat()
    }

    /// `NetDialer.dial`: the node's address by its node key, WhoIs of it, the session.
    private func dial(_ c: Client) {
        let status = net.status(of: ip)
        guard let peer = status.peers.first(where: { c.record.nodeKeys.contains($0.publicKey) }) else {
            c.machine.on(.peerOffline, now: clock.nowMS)
            return drive(c)
        }
        guard peer.online, let address = peer.tailscaleIPs.first else {
            c.machine.on(.peerOffline, now: clock.nowMS)
            return drive(c)
        }
        guard let fd = try? tailnet.dial(address, port: NetListener.port), let who = try? tailnet.whois(address) else {
            c.machine.on(.failed, now: clock.nowMS)
            return drive(c)
        }
        let book = DeviceBook(url: folder.appendingPathComponent("node-\(UUID().uuidString.prefix(6)).json"))
        _ = try? book.update { $0 = [c.record] }
        let resume = c.ticket.map { NetControl.Resume(ticket: $0, cursors: LinkResume.cursors(aid: 0, rev: c.rev)) }
        let setup = NetSession.Client(
            local: NetLocal(device: device, kind: .phone, nodeKey: nodeKey, signer: key), route: .tailnet,
            peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId), book: book, server: c.record.id, service: "link", resume: resume)
        c.dialing = true
        let id = c.record.id
        let mine = generation
        let slot = Slot()
        let wire = Wire(NetSession(fd: fd, role: .client(setup))) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.heard(event, id: id, generation: mine, wire: slot.wire) }
            }
        }
        slot.wire = wire
        c.wire = wire
    }

    private func heard(_ event: Wire.Event, id: UUID, generation mine: Int, wire: Wire?) {
        guard mine == generation, let c = clients[id], c.wire === wire else { return }
        let now = clock.nowMS
        switch event {
        case .up(let peer, let directory):
            c.dialing = false
            c.ticket = peer.ticket
            if peer.record != c.record { c.record = peer.record }
            if c.record.kind == .mac, let directory { keepDirectory(directory) }
            c.machine.on(.connected, now: now)
            c.wire?.send(#"{"t":"presence","onScreen":true}"#)
            for other in clients.values where other !== c { drive(other) }
        case .message(let m):
            if case .string("welcome")? = m["t"], case .object(let host)? = m["host"], case .string(let n)? = host["name"] { c.hostName = n }
            if case .string("snapshot")? = m["t"], case .int(let rev)? = m["rev"] { c.rev = Int(rev) }
            if c.record.kind == .mac, case .string("paused")? = m["t"], c.wire != nil {
                c.parked = true
                c.machine.on(.ended("paused"), now: now)
            }
            if c.record.kind == .mac, case .string("devices.set")? = m["t"], let records = Self.records(m["records"]) { keepDirectory(records) }
        case .closed(let why):
            let wasUp = !c.dialing
            c.dialing = false
            c.wire = nil
            c.parked = false
            let reason: String? = why.hasPrefix("bye ") ? String(why.dropFirst(4)) : nil
            if wasUp {
                c.machine.on(.ended(reason), now: now)
            } else if let reason {
                c.machine.on(.ended(reason), now: now)
            } else {
                c.machine.on(.failed, now: now)
            }
        }
        drive(c)
    }

    /// The tailnet's peer changes: a node coming online is tried at once.
    private func listenToTailnet() {
        bus?.cancel()
        let events = tailnet.events()
        bus = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if case .peer(_, let key?, let online?) = event, online {
                    for c in self.clients.values where c.record.nodeKeys.contains(key) && !c.parked {
                        c.machine.on(.peerOnline, now: self.clock.nowMS)
                        self.drive(c)
                    }
                }
            }
        }
    }

    /// A `devices.set`'s records, as the wire carries them.
    static func records(_ value: JSONValue?) -> [DeviceRecord]? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return DevicesWire.decode([DeviceRecord].self, data)
    }

    // MARK: What it shows

    /// Home: the Mac first, then its boxes.
    var rows: [PhoneRow] {
        known.compactMap { record in
            guard let c = clients[record.id] else { return nil }
            return PhoneRow(
                id: record.id, kind: record.kind, name: c.hostName ?? record.name, words: PhoneRow.words(c.machine.state),
                glyph: PhoneRow.glyph(c.machine.state))
        }
    }

    func state(of id: UUID) -> NodeMachine.State? { clients[id]?.machine.state }
}

extension PhoneEmu.JoinStep {
    var isJoined: Bool { if case .joined = self { true } else { false } }
    var over: Bool {
        switch self {
        case .joined, .denied, .noMac, .join: true
        case .finding, .allowing: false
        }
    }
}

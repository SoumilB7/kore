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
    /// The boxes this Mac knows on KoreNet: what each last took of this Mac's pushes, and the
    /// devices waiting there.
    var directory: NodeDirectory { get }
    /// This Mac's name, for a phone's directory.
    var macName: String { get }
    /// How to read this Mac's identity (made on first use) while KoreNet is on. The reader may
    /// block on a file read: it's called off the main actor.
    func identityReader() -> (@Sendable () throws -> (device: UUID, signer: any IdentitySigner))?
    /// Holds the tailnet's IPN bus (`key` held) or lets it go: held while a phone is allowed or
    /// the Add device window is open, so Tailscale coming back rebinds the port with no window.
    func hold(_ key: String, _ held: Bool)
}

/// A box link as an owner Mac's push sees it (Kore: a `HostConnection`; tests: fakes).
@MainActor
package protocol BoxDevicesLink: AnyObject {
    /// The box as the link's KoreNet session proved it (its record, its book's rev); nil on a
    /// plain SSH grant link, which the box never takes a `devices.set` from.
    var boxPeer: NetPeer? { get }
    /// Up, and the box says it takes a merging `devices.set`.
    var takesMerge: Bool { get }
    /// Which dial the link is on: an answer is awaited only on the dial its push went out on.
    var dialNumber: Int { get }
    func post(_ payload: Data) -> Bool
}

extension HostConnection: BoxDevicesLink {
    package var boxPeer: NetPeer? { netPeer }
    package var takesMerge: Bool { isOnline && caps.contains(DevicesWire.mergeCap) }
}

/// Audit lines (phase 18 §1 "Audit"): `audit <event>` in hosts.log, ids and kinds only, never content.
@MainActor
package enum NetAudit {
    /// Tests: each watcher hears every line, as `event key=value…` (suites run side by side, so
    /// one global slot let one suite's teardown silence another's).
    private static var watchers: [UUID: (String) -> Void] = [:]

    /// Sends every line to `sink` until `unwatch` with the id it returns.
    @discardableResult package static func watch(_ sink: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        watchers[id] = sink
        return id
    }

    package static func unwatch(_ id: UUID?) {
        guard let id else { return }
        watchers[id] = nil
    }

    package static func line(_ event: String, _ fields: KeyValuePairs<String, String?>) {
        HostLog.audit(event, fields)
        let sinks = Array(watchers.values)
        guard !sinks.isEmpty else { return }
        let text = ([event] + fields.compactMap { key, value in value.map { "\(key)=\($0)" } }).joined(separator: " ")
        for sink in sinks { sink(text) }
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

    nonisolated package static let port = NetListener.macPort
    /// The Add device window's length.
    package static var addWindowLength: TimeInterval = 600
    /// How long a held stranger waits (a little past its card).
    package static var holdFor: TimeInterval { DeviceAsks.wait + 10 }
    /// Handshakes under way at once; more are closed.
    package static let maxHandshakes = 16
    /// What a phone was sent, kept this long for its resume.
    package static var keepProjectors: TimeInterval = 120
    /// Nodes whose first knock is remembered (a card's "first seen").
    package static let firstSeenCap = 64

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
    /// The owner's other Macs linked now (a login moving), by device.
    package private(set) var macs: [UUID: MacPeerLink] = [:]
    /// This Mac's side of a login moved from or to another of the owner's Macs.
    package lazy var loginMoves = MacLoginMoves()
    /// While the Add device window is open: knocks at the owner's other Macs, to pair.
    package lazy var pairing = MacPairing(net: self)
    /// What changed, for tests awaiting it: `listening`, `closed`, `kept` (a rebind failed, the
    /// working listener stayed), `up <id>`, `gone <id>`, `kept <id>`.
    package var changed: (@MainActor (String) -> Void)?
    /// Handshakes held for an Allow, by connection.
    private var held: [ObjectIdentifier: (connection: PhoneConnection, ask: DeviceAsks.Ask)] = [:]
    /// The device each held handshake is, by connection.
    private var heldDevices: [ObjectIdentifier: UUID] = [:]
    /// Connections whose handshake is under way.
    private var shaking: [ObjectIdentifier: PhoneConnection] = [:]
    /// WhoIs lookups under way (counted against `maxHandshakes` with the handshakes).
    package private(set) var whoising = 0
    /// Times `stop` ran: a lookup from before the last one isn't counted down twice.
    private var stops = 0
    private var kept: [UUID: (projector: LinkProjector, at: Date)] = [:]
    /// Node keys first seen, for the card's line.
    private var firstSeen: [String: Date] = [:]

    /// Tests: takes the phones this Mac issued instead of the box links (Kore: nil, every box
    /// link that takes a merging `devices.set` hears).
    package var pushDevices: (@MainActor ([DeviceRecord]) -> Void)?
    /// The box links held now (tests: fakes).
    package var boxLinks: @MainActor () -> [any BoxDevicesLink] = { HostConnection.held }
    /// Pushes sent and not answered yet, by the set's id.
    private var sent: [String: Sent] = [:]

    private struct Sent {
        var box: UUID
        /// The link's dial it went out on: a link that dropped since never answers it.
        var dial: Int
        var pushed: NodeDirectory.Pushed
        /// The box book's rev before it (its welcome's, or the last push's answer).
        var before: Int?
    }
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
    /// allowed, another of the owner's Macs paired, or the Add device window open.
    nonisolated package static func listens(on: Bool, running: Bool, phones: Int, macs: Int = 0, addOpen: Bool) -> Bool {
        on && running && (phones > 0 || macs > 0 || addOpen)
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
    /// Read from memory until the book's file changes; a read that fails keeps the last good one.
    package func allowedPhones() -> [DeviceRecord] {
        if bookCache?.book.url != host.book.url { bookCache = DeviceBookCache(host.book) }
        return (bookCache?.read().devices ?? []).filter { $0.kind == .phone }
    }
    private var bookCache: DeviceBookCache?

    /// The owner's other Macs paired with this one (kind mac, owner, in its own book; never itself).
    package func pairedMacs() -> [DeviceRecord] {
        if bookCache?.book.url != host.book.url { bookCache = DeviceBookCache(host.book) }
        let me = device
        return (bookCache?.read().devices ?? []).filter { $0.kind == .mac && $0.owner && $0.id != me }
    }

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
        pairing.start()
        Devices.shared.changed()
    }

    package func closeAddWindow() {
        guard addUntil != nil else { return }
        addUntil = nil
        shared.withLock { $0.addUntil = nil }
        addCancel?()
        addCancel = nil
        refusals = []
        pairing.stop()
        refresh()
        Devices.shared.changed()
    }

    /// Tagged nodes without Kore's app capability turned away while the window is open: the one
    /// place a refusal shows (Devices, one quiet line each).
    package private(set) var refusals: [DeviceRefusal] = []

    /// This Mac's device id, once read (the first `refresh` reads it off the main actor).
    package var device: UUID? { shared.withLock { $0.identity?.device } }

    /// Looks again (KoreNet switched, Tailscale's state changed, a phone allowed or removed, the
    /// window opened or closed, the Mac woke, the network changed): binds what the rule and
    /// Tailscale say, or closes. An event: a failed look's retries start again from the first.
    package func refresh() {
        retryStep = 0
        clashLooked = false
        cancelRetry()
        look()
    }

    private func look() {
        // Retired: replaced by another listener, it never takes the port again.
        guard !retired else { return }
        generation += 1
        let mine = generation
        let macs = pairedMacs().count
        host.hold(Self.busKey, !allowedPhones().isEmpty || macs > 0 || addOpen)
        guard let tailnet = host.tailnet, Self.listens(on: true, running: true, phones: allowedPhones().count, macs: macs, addOpen: addOpen) else {
            cancelRetry()
            // No port, but pushes still need who this Mac is (a revoke owed to a box).
            learnIdentity()
            return close()
        }
        // One look at a time: two binds at once refused each other (the second hit the first's
        // sockets, the first was stale by then and closed them: no port at all, 2026-11-15). A
        // look asked for meanwhile runs once this one has settled.
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        let name = host.macName
        shared.withLock { $0.macName = name }
        let had = bound
        let listening = self.listening
        let reader = host.identityReader()
        let foreground = foreground
        background { [weak self] in
            let found = MacNet.bind(tailnet, had: had, listening: listening)
            let identity = try? reader?()
            _ = self
            foreground { [weak self] in
                guard let self else {
                    for socket in found.made ?? [] { Sockets.closeFD(socket.fd) }
                    return
                }
                self.looking = false
                self.settle(mine, found, identity: identity)
                if self.lookAgain {
                    self.lookAgain = false
                    self.look()
                }
            }
        }
    }

    /// A look's bind is under way off the main actor; another was asked for meanwhile.
    private var looking = false
    private var lookAgain = false

    /// What one look found (off the main actor): Tailscale's status, the addresses to bind, the
    /// sockets made, and why not (one word, `cause`).
    struct Found {
        var status: TailnetStatus?
        var want: [String] = []
        var made: [TailnetListenSocket]?
        var problem: String?
        /// The bind was refused because the port is held (by this Mac's own sockets, still closing).
        var clash = false
    }

    /// Reads Tailscale's status and binds its addresses, unless they're bound already. A status
    /// that can't be read, a running node with no address, a bind refused, or a socket on an
    /// address not its own is a problem (retried); a node not running is not (its bus says when).
    nonisolated static func bind(_ tailnet: any Tailnet, had: [String], listening: Bool) -> Found {
        var found = Found()
        do {
            let status = try tailnet.status()
            found.status = status
            found.want = try addresses(status)
            if status.backendState == .running, found.want.isEmpty { found.problem = "tailscale-no-address" }
        } catch {
            found.problem = "status-" + cause(error)
            return found
        }
        guard found.problem == nil, !found.want.isEmpty, !(listening && found.want == had) else { return found }
        do {
            let sockets = try tailnet.listen(port: port)
            try check(sockets, within: found.want)
            found.made = sockets
        } catch {
            found.problem = cause(error)
            found.clash = addressInUse(error)
        }
        return found
    }

    private func settle(_ mine: Int, _ found: Found, identity: (device: UUID, signer: any IdentitySigner)?) {
        guard mine == generation else {
            for socket in found.made ?? [] { Sockets.closeFD(socket.fd) }
            return
        }
        let knew = device != nil
        defer { if !knew, device != nil { identityLearned() } }
        shared.withLock {
            // An unreadable status keeps what was known: handshakes under way still need it.
            if let status = found.status {
                $0.selfNode = status.selfNode
                $0.ownUser = status.selfNode?.owner
            }
            if let identity { $0.identity = (identity.device, identity.signer.publicKey) }
        }
        if let identity { signer = identity.signer }
        if let problem = found.problem {
            HostLog.note("korenet", "listen failed", problem)
            changed?("failed " + problem)
            // The port is held: by this Mac's own sockets when the addresses moved under them (or a
            // close still under way). They go, and once they're gone it looks again, once.
            if found.clash, !clashLooked {
                clashLooked = true
                close()
                return afterClosing { [weak self] in self?.look() }
            }
            // Any other failure: a working listener stays, and the look comes again later.
            if listener != nil { changed?("kept") }
            return retryLater(problem)
        }
        guard !found.want.isEmpty else {
            // Tailscale isn't running: no port, and nothing to retry (its bus says when it runs).
            cancelRetry()
            return close()
        }
        retryStep = 0
        clashLooked = false
        cancelRetry()
        // Listening on these addresses already.
        guard let made = found.made else { return }
        close()
        let listener = NetListener(sockets: made, limiter: limiter)
        self.listener = listener
        bound = found.want
        binds += 1
        for socket in made { watch(socket, listener) }
        HostLog.note("korenet", "listening", found.want.joined(separator: ","))
        changed?("listening")
    }

    // MARK: A look that failed

    /// After a look that wanted the port and got none, the next looks come after these; then it
    /// waits for an event (Tailscale's bus, wake, a network change, the Devices popup, a phone
    /// allowed), each of which starts them again. Never a poll.
    nonisolated package static let retrySteps: [TimeInterval] = [1, 5, 30, 120]
    /// The next retry's step.
    private var retryStep = 0
    private var retryCancel: (() -> Void)?
    /// A clash (the port held) was looked at again once since the last event or bind.
    private var clashLooked = false
    /// A retry is waiting (tests).
    package var retrying: Bool { retryCancel != nil }
    /// The descriptors of sockets let go and not closed yet (their sources close them).
    private let closing = DispatchGroup()
    /// The last stopped listener's `closing` (KoreNet turned off, or this Mac's Kore restarting in
    /// one process): a new one's bind that clashes waits for it too, as its descriptors may still
    /// hold the port.
    private static var stopped: DispatchGroup?
    /// The longest a clash waits for descriptors to close before it looks again anyway (then the
    /// retry steps): a close that never comes can't hold the listener off for good.
    nonisolated(unsafe) package static var closeWait: TimeInterval = 2
    /// Whether a one-shot ran (main actor only).
    private final class Ran: @unchecked Sendable { var done = false }
    /// The queue the listening sockets' sources run on (tests hold it to keep a close pending).
    package var listenQueue: DispatchQueue { acceptQueue }

    private func retryLater(_ problem: String) {
        cancelRetry()
        guard retryStep < Self.retrySteps.count else {
            HostLog.note("korenet", "listen waits", problem)
            changed?("waits")
            return
        }
        let seconds = Self.retrySteps[retryStep]
        retryStep += 1
        retryCancel = schedule(seconds) { [weak self] in
            guard let self else { return }
            self.retryCancel = nil
            self.clashLooked = false
            self.look()
        }
    }

    private func cancelRetry() {
        retryCancel?()
        retryCancel = nil
    }

    /// Runs `work` once every socket let go is closed, this listener's and the last stopped one's,
    /// or after `closeWait` at most, whichever comes first.
    private func afterClosing(_ work: @escaping @MainActor () -> Void) {
        let groups = [closing] + (Self.stopped.map { $0 === closing ? [] : [$0] } ?? [])
        let all = DispatchGroup()
        for group in groups {
            all.enter()
            group.notify(queue: .main) { all.leave() }
        }
        let ran = Ran()
        let fire = { @MainActor in
            guard !ran.done else { return }
            ran.done = true
            work()
        }
        all.notify(queue: .main) { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeWait) { MainActor.assumeIsolated { fire() } }
    }

    /// The identity was read for the first time: every box linked now is caught up, and every
    /// enrolled box that owes a push is dialled once for it (at launch no window holds a link,
    /// and a box allowed a phone before it was caught up would wait for one).
    private func identityLearned() {
        catchUpBoxes()
        if pushDevices == nil { reachOwed() }
    }

    /// A failure in one word for hosts.log (`bind-EADDRNOTAVAIL`, `tailscale-Stopped`,
    /// `status-localapi-http-503`): never empty, never a sentence (a log that keeps only
    /// one-word reasons keeps it).
    nonisolated package static func cause(_ error: any Error) -> String {
        let text: String =
            switch error {
            case SocketError.failed(let what, let code): (what.split(separator: " ").first.map(String.init) ?? "socket") + "-" + errnoName(code)
            case SocketError.wildcard: "wildcard-address"
            case SocketError.badAddress: "not-own-address"
            case SocketError.closed: "closed"
            case SocketError.timedOut: "timed-out"
            case SocketError.notThisUser: "not-this-user"
            case TailnetError.unavailable: "localapi-unavailable"
            case TailnetError.unauthorized: "localapi-unauthorized"
            case TailnetError.http(let code): "localapi-http-\(code)"
            case TailnetError.malformed: "localapi-malformed"
            case TailnetError.notTailnet: "not-tailnet"
            case TailnetError.sidecar: "sidecar"
            case TailnetError.notRunning(let state): "tailscale-\(state.rawValue)"
            default: "\(type(of: error))-\((error as NSError).code)"
            }
        return word(text)
    }

    /// `text` with anything but letters, digits and `-_.:` made `-`, at most 48 long; `unknown` when empty.
    nonisolated static func word(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        let kept = String(text.map { allowed.contains($0) ? $0 : "-" }.prefix(48))
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "unknown" : kept
    }

    /// An errno's name (`EADDRNOTAVAIL`), or `errno-<n>`.
    nonisolated static func errnoName(_ code: Int32) -> String {
        let names: [Int32: String] = [
            EADDRINUSE: "EADDRINUSE", EADDRNOTAVAIL: "EADDRNOTAVAIL", EACCES: "EACCES", EPERM: "EPERM", EINVAL: "EINVAL", ENOBUFS: "ENOBUFS",
            EMFILE: "EMFILE", ENFILE: "ENFILE", ECONNREFUSED: "ECONNREFUSED", ENETDOWN: "ENETDOWN", ENETUNREACH: "ENETUNREACH",
            EHOSTUNREACH: "EHOSTUNREACH", EAFNOSUPPORT: "EAFNOSUPPORT", ENOTCONN: "ENOTCONN", ETIMEDOUT: "ETIMEDOUT", EBADF: "EBADF",
        ]
        return names[code] ?? "errno-\(code)"
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

    /// Another listener takes over (the switch started again in this process): this one stops
    /// for good, whatever still asks it to look.
    package func retire() {
        retired = true
        stop()
    }
    private var retired = false

    /// KoreNet went off: the port, every phone and every handshake go.
    package func stop() {
        generation += 1
        lookAgain = false
        cancelRetry()
        retryStep = 0
        for held in reaching.values { held.release() }
        reaching = [:]
        host.hold(Self.busKey, false)
        close()
        Self.stopped = closing
        closeAddWindow()
        // Switched off, not refused: each phone retries by itself and is back once it's on.
        for phone in Array(phones.values) { phone.end(NetControl.Reason.off) }
        for mac in Array(macs.values) { mac.end(NetControl.Reason.off) }
        for (_, entry) in held { asks.cancel(entry.ask) }
        for connection in shaking.values { connection.end(NetControl.Reason.off) }
        held = [:]
        shaking = [:]
        whoising = 0
        stops += 1
        // Their `closed` events find nothing left to count down: the count starts again here.
        shared.withLock { $0.handshakes = 0 }
    }

    /// The Mac is going to sleep: each phone hears `bye sleep` (shown asleep, not unreachable),
    /// and dials again when the Mac is back. The port stays as it is.
    package func sleeps() {
        for phone in Array(phones.values) { phone.end(NetControl.Reason.sleep) }
        for mac in Array(macs.values) { mac.end(NetControl.Reason.sleep) }
        for connection in shaking.values { connection.end(NetControl.Reason.sleep) }
    }

    private func watch(_ socket: TailnetListenSocket, _ listener: NetListener) {
        if case .tcp(let fd) = socket { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: acceptQueue)
        let accepted: @Sendable (Int32, String) -> Void = { [weak self] fd, remote in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.whois(fd, remote: remote) ?? Sockets.closeFD(fd) } }
        }
        // Runs on `acceptQueue`, not the main actor: `@Sendable` keeps it out of MacNet's isolation
        // (an inferred @MainActor handler traps there, Swift's runtime isolation check).
        let broke: @Sendable (String) -> Void = { [weak self] why in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerBroke(why) } }
        }
        source.setEventHandler { @Sendable [weak source] in
            while true {
                let next: (fd: Int32, remote: String)?
                do {
                    next = try listener.accept(on: socket)
                } catch {
                    // Nothing more now: the source fires again when there is.
                    if MacNet.transient(error) { return }
                    // The sidecar's handoff socket at its end (the helper died), or the listener
                    // itself failing: a source left readable would fire forever.
                    source?.cancel()
                    return broke(MacNet.cause(error))
                }
                // The limiter turned it away (closed): the next one may be waiting.
                guard let next else { continue }
                accepted(next.fd, next.remote)
                // The sidecar's handoff socket gives one connection per message.
                if case .handoff = socket { return }
            }
        }
        // Its descriptor closes here, after the source let go of it: a bind waiting on the port
        // (`afterClosing`) runs once every one has.
        let closing = closing
        closing.enter()
        source.setCancelHandler { @Sendable in
            Sockets.closeFD(socket.fd)
            closing.leave()
        }
        sources.append(source)
        source.resume()
    }

    /// A bind refused because the port is held (by our own listener, when addresses overlap).
    nonisolated static func addressInUse(_ error: any Error) -> Bool {
        if case SocketError.failed(_, let code) = error { return code == EADDRINUSE }
        return false
    }

    /// An accept error that only means "not now".
    nonisolated static func transient(_ error: any Error) -> Bool {
        guard case SocketError.failed(_, let code) = error else { return false }
        return code == EAGAIN || code == EWOULDBLOCK || code == EINTR || code == ECONNABORTED
    }

    /// A listening socket stopped working: the port closes, and opens again by the retries (or
    /// any event before them).
    private func listenerBroke(_ why: String) {
        guard listener != nil else { return }
        HostLog.note("korenet", "listener broke", why)
        changed?("broke " + why)
        close()
        retryStep = 0
        retryLater(why)
    }

    // MARK: Connections

    /// WhoIs off the main actor, then the session. A WhoIs that fails closes the connection: no
    /// node key is ever taken from the peer's own word.
    private func whois(_ fd: Int32, remote: String) {
        guard let tailnet = host.tailnet else { return Sockets.closeFD(fd) }
        // WhoIs lookups under way count too: each holds a LocalAPI round trip off the main actor.
        guard shared.withLock({ $0.handshakes }) + whoising < Self.maxHandshakes else { return Sockets.closeFD(fd) }
        whoising += 1
        let mine = stops
        let foreground = foreground
        background { [weak self] in
            let who = try? tailnet.whois(remote)
            _ = self
            foreground { [weak self] in
                if let self, self.stops == mine { self.whoising = max(0, self.whoising - 1) }
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
        // A phone taken offline is parked, not refused: Bring online reaches it (`PhoneLink.park`).
        setup.admitPaused = true
        let shared = shared
        let clock = clock
        setup.stranger = { hello in MacNet.stranger(hello, whois: whois, state: shared.withLock { $0 }, now: clock()) }
        let book = host.book
        // A phone hears this Mac and its boxes; another of the owner's Macs, this Mac only (what it pins).
        // Read on the connection's queue: nothing of the main actor's.
        setup.directory = { @Sendable record in
            guard record.kind != .box, let all = MacNet.directory(state: shared.withLock { $0 }, book: book) else { return nil }
            return record.kind == .mac ? Array(all.prefix(1)) : all
        }
        let seen = firstSeen[whois.node.key] ?? clock()
        if firstSeen[whois.node.key] == nil {
            // Bounded: the oldest goes first.
            if firstSeen.count >= Self.firstSeenCap, let oldest = firstSeen.min(by: { $0.value < $1.value })?.key { firstSeen[oldest] = nil }
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

    /// The identity's signer: read (its file) off the main actor at a `refresh`.
    private var signer: (any IdentitySigner)?
    private var learning = false

    /// Reads this Mac's identity off the main actor once, when no listening `refresh` did: the
    /// boxes are then caught up (what this Mac issued, even nothing at all).
    private func learnIdentity() {
        guard device == nil, !learning, let reader = host.identityReader() else { return }
        learning = true
        let foreground = foreground
        background { [weak self] in
            let identity = try? reader()
            _ = self
            foreground { [weak self] in
                guard let self else { return }
                self.learning = false
                guard let identity, self.device == nil else { return }
                self.signer = identity.signer
                self.shared.withLock { $0.identity = (identity.device, identity.signer.publicKey) }
                self.identityLearned()
            }
        }
    }

    /// A stranger's hello: inside the Add device window, a phone of this Mac's own user (or a
    /// tagged node with Kore's app capability, read+ask at most) waits for the owner's card.
    /// Anything else is refused (`bye unknown`), nothing kept: shared-in nodes, other people's,
    /// enrolls outside the window.
    nonisolated static func stranger(_ hello: NetControl.Hello, whois: TailnetWhoIs, state: Shared, now: Date) -> NetSession.Stranger {
        guard let enroll = hello.enroll, let until = state.addUntil, now < until, let issuer = state.identity?.device
        else { return .refuse(NetControl.Reason.unknown) }
        if enroll.kind == .mac { return macStranger(hello, enroll: enroll, whois: whois, state: state, issuer: issuer, now: now) }
        guard (enroll.kind ?? .phone) == .phone else { return .refuse(NetControl.Reason.unknown) }
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
        var held = record
        held.model = enroll.model.map(clean)
        guard (try? held.validate()) != nil else { return .refuse(NetControl.Reason.unknown) }
        return .hold(held, seconds: state.holdFor)
    }

    /// Another of the owner's Macs, inside the Add device window: the same Tailscale user, never a
    /// tagged node, never this Mac. It waits for the owner's card; Allowed, it's kept as an owner
    /// Mac that may move logins to and from this one (`MacPeerLink`), nothing more.
    nonisolated static func macStranger(
        _ hello: NetControl.Hello, enroll: NetControl.Enroll, whois: TailnetWhoIs, state: Shared, issuer: UUID, now: Date
    ) -> NetSession.Stranger {
        guard whois.node.tags.isEmpty, let own = state.ownUser, whois.userId == own, hello.device != issuer else {
            return .refuse(NetControl.Reason.unknown)
        }
        let record = DeviceRecord(
            id: hello.device, name: clean(enroll.name), kind: .mac, abilities: .run, owner: true, identityKey: enroll.identityKey,
            nodeKeys: [whois.node.key], userId: whois.userId, fqdn: whois.node.name, issuedBy: issuer, added: now, lastSeen: now)
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
        // A paused box stays in the directory with `paused` (A7): phones list it "taken offline" and
        // don't dial it, rather than the row vanishing with no word.
        for record in (try? book.read().devices) ?? [] where record.kind == .box {
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
            let node = Self.shortName(connection.whois.node.name)
            let login = connection.whois.user.loginName
            let info = record.kind == .mac
                ? DeviceCardInfo.mac(name: record.name, node: node, address: connection.remote, login: login, firstSeen: connection.firstSeen)
                : DeviceCardInfo.phone(name: record.name, node: node, address: connection.remote, login: login, firstSeen: connection.firstSeen)
            // This Mac paired with it meanwhile (its own knock was Allowed there): no second card.
            if record.kind == .mac, let pinned = pairedMacs().first(where: { $0.id == record.id }) {
                return pinned.identityKey == record.identityKey ? connection.admit(pinned) : connection.admit(nil, reason: NetControl.Reason.unknown)
            }
            // The tailnet now (one status read, off the main actor): a record this phone clearly
            // replaces (reinstalled or left) shows on the card; Allow looks again before retiring.
            peers { [weak self] peers in
                // Gone meanwhile: no card.
                guard let self, self.shaking[key] != nil else { return }
                var card = info
                card.replaces = self.replacing(record, peers: peers).first.map { MacNet.replacesLine($0, peers: peers ?? [], now: self.clock()) }
                let ask = self.asks.ask(card) { [weak self] answer in
                    guard let self else { return }
                    guard answer == .allow else { return self.answered(answer, record: record, connection: connection) }
                    // Looked at again now: a phone that came online since is kept.
                    self.peers { [weak self] peers in
                        guard let self else { return }
                        self.answered(.allow, record: record, connection: connection, retire: self.replacing(record, peers: peers).map(\.id))
                    }
                }
                self.held[key] = (connection, ask)
                self.heldDevices[key] = record.id
            }
        case .established(let peer, let binding):
            shaking[key] = nil
            shared.withLock { $0.handshakes = max(0, $0.handshakes - 1) }
            if peer.record.kind == .mac { return macUp(peer, connection: connection) }
            phoneUp(peer, connection: connection, binding: binding)
        case .messages(let incoming, let record, let settled, let cursors):
            for phone in phones.values where phone.connection === connection {
                phone.take(incoming, record: record, cursorsSettled: settled, cursors: cursors)
            }
            for mac in macs.values where mac.connection === connection { mac.take(incoming, record: record) }
        case .closed(let reason):
            if shaking.removeValue(forKey: key) != nil { shared.withLock { $0.handshakes = max(0, $0.handshakes - 1) } }
            heldDevices[key] = nil
            if let entry = held.removeValue(forKey: key) { asks.cancel(entry.ask) }
            if let phone = phones.values.first(where: { $0.connection === connection }) {
                if !phone.ended { HostLog.note("korenet", "phone gone", reason) }
                phone.gone()
            }
            macs.values.first { $0.connection === connection }?.gone()
        }
    }

    /// The tailnet's peers as one status read off the main actor says (nil: unreadable), then `then`.
    func peers(_ then: @escaping @MainActor ([TailnetStatus.Peer]?) -> Void) {
        let tailnet = host.tailnet
        let foreground = foreground
        background {
            let peers = (try? tailnet?.status())?.peers
            foreground { then(peers) }
        }
    }

    /// The records `record` replaces now (`replaced`), never one whose phone is linked here.
    func replacing(_ record: DeviceRecord, peers: [TailnetStatus.Peer]?) -> [DeviceRecord] {
        guard let peers else { return [] }
        let devices = (try? host.book.read().devices) ?? []
        return Self.replaced(by: record, model: record.model, in: devices, peers: peers).filter { phones[$0.id].map { $0.ended } ?? true }
    }

    /// The owner's answer to a phone's card; Allow retires the records it replaces (`retire`).
    private func answered(_ answer: DeviceAsks.Answer, record: DeviceRecord, connection: PhoneConnection, retire: [UUID] = []) {
        held[ObjectIdentifier(connection)] = nil
        heldDevices[ObjectIdentifier(connection)] = nil
        let id = record.id.uuidString.lowercased()
        switch answer {
        case .allow:
            do {
                try host.book.update { devices in
                    devices.removeAll { $0.id == record.id || ($0.kind == .phone && retire.contains($0.id)) }
                    devices.append(record)
                }
            } catch {
                NetAudit.line("deny", ["device": id, "reason": "book"])
                return connection.admit(nil)
            }
            for old in retire { NetAudit.line("retire", ["device": old.uuidString.lowercased(), "by": id]) }
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
        if let pushDevices {
            pushDevices(issued()?.records ?? [])
        } else {
            catchUpBoxes()
            reachOwed()
        }
        refresh()
        Devices.shared.changed()
    }

    /// Boxes held open for a push no window's link could carry, by box: released once the box
    /// answered it, or after `reachFor`.
    private var reaching: [UUID: (hold: Int, release: () -> Void)] = [:]
    private var holds = 0
    package static var reachFor: TimeInterval = 30
    /// Holds a box's link until released (Kore: its connection, retained; its link-up catches it up).
    package var reachBox: @MainActor (String) -> (() -> Void)? = { key in
        let connection = HostConnection.named(key)
        connection.retain()
        return { connection.release() }
    }

    /// The phones changed, or this Mac's identity was first read (launch): every enrolled box
    /// that hasn't taken the change is held until it answers (dialled now when its link is down;
    /// kept up when its last holder is letting go), so the box holds it before a phone tries it
    /// (S1: a box set up first, then a phone, no window; a box an older Kore never caught up).
    private func reachOwed() {
        guard let (_, rev, me) = issued() else { return }
        for entry in host.directory.all.values where entry.enrolled && entry.on && reaching[entry.device] == nil {
            if let last = entry.pushed, last.by == me, last.bookRev == rev { continue }
            let key = entry.rekeyed ? entry.id.raw : (entry.ssh ?? entry.id.raw)
            guard !NetPauses.shared.contains(key), let release = reachBox(key) else { continue }
            let box = entry.device
            holds += 1
            let hold = holds
            reaching[box] = (hold, release)
            // Its own end only: an earlier hold's timer never lets go of this one mid-dial.
            _ = schedule(Self.reachFor) { [weak self] in self?.reached(box, hold: hold) }
        }
    }

    /// The box answered (any hold), or a hold's time is up (that hold only).
    private func reached(_ box: UUID, hold: Int? = nil) {
        guard let held = reaching[box], hold == nil || held.hold == hold else { return }
        reaching[box] = nil
        held.release()
    }

    private func phoneUp(_ peer: NetPeer, connection: PhoneConnection, binding: Data) {
        // One link per phone: a newer one takes over.
        if let old = phones[peer.record.id] { old.end(LinkMessage.ByeReason.replaced.rawValue) }
        let phone = PhoneLink(net: self, record: peer.record, connection: connection, binding: binding, resumed: peer.resumed)
        phones[peer.record.id] = phone
        NetAudit.line("connect", ["device": peer.record.id.uuidString.lowercased(), "resumed": peer.resumed ? "1" : nil])
        StayAwakePhones.connected(awakePhones)
        changed?("up \(peer.record.id.uuidString)")
        Devices.shared.changed()
        if phone.waitsForCursors {
            // Its cursors come first; a phone with none sends something else, or a second goes by.
            _ = schedule(1) { [weak phone] in phone?.beginIfWaiting() }
        } else {
            phone.begin(cursors: nil)
        }
    }

    /// Paired from this side: another Mac's Allow card took this Mac's knock, and its record is
    /// pinned here. That Mac's own knock, waiting here for a card, is welcomed as it is now (one
    /// Allow pairs both ways); the port follows.
    package func paired(with record: DeviceRecord) {
        for (key, device) in heldDevices where device == record.id {
            heldDevices[key] = nil
            guard let entry = held.removeValue(forKey: key) else { continue }
            asks.cancel(entry.ask)
            entry.connection.admit(record)
        }
        NetAudit.line("pair", ["device": record.id.uuidString.lowercased()])
        refresh()
        Devices.shared.changed()
    }

    /// This Mac's identity, once read (what it dials another Mac with).
    package var identity: (device: UUID, signer: any IdentitySigner)? {
        guard let device, let signer else { return nil }
        return (device, signer)
    }

    /// The tailnet's own word about this node (its user, its node key), once read.
    package var selfNode: TailnetStatus.SelfNode? { shared.withLock { $0.selfNode } }

    /// Another of the owner's Macs linked (a login moving): the lean link, never a phone's.
    private func macUp(_ peer: NetPeer, connection: PhoneConnection) {
        guard peer.record.owner else { return connection.end(NetControl.Reason.refused) }
        if let old = macs[peer.record.id] { old.end(LinkMessage.ByeReason.replaced.rawValue) }
        macs[peer.record.id] = MacPeerLink(net: self, record: peer.record, connection: connection)
        NetAudit.line("connect", ["device": peer.record.id.uuidString.lowercased(), "kind": "mac"])
        changed?("mac up \(peer.record.id.uuidString)")
    }

    func macGone(_ mac: MacPeerLink) {
        if macs[mac.id] === mac { macs[mac.id] = nil }
        changed?("mac gone \(mac.id.uuidString)")
    }

    /// Phones that keep the Mac awake: linked and served (a parked one, taken offline, doesn't).
    package var awakePhones: Int { phones.values.count { !$0.ended && !$0.parked } }

    /// A link parked or brought back: Stay awake hears.
    func phoneParked() { StayAwakePhones.connected(awakePhones) }

    func phoneGone(_ phone: PhoneLink) {
        if phones[phone.id] === phone {
            phones[phone.id] = nil
            // Last seen is when its link went (in memory: no book write per disconnect).
            linkWent[phone.id] = clock()
        }
        StayAwakePhones.connected(awakePhones)
        changed?("gone \(phone.id.uuidString)")
        Devices.shared.changed()
    }

    // MARK: Resume

    func retain(_ id: UUID, _ projector: LinkProjector) {
        guard projector.started else { return }
        kept[id] = (projector, clock())
        changed?("kept \(id.uuidString)")
        // Let go once its resume can't come any more (nothing else would free it).
        _ = schedule(Self.keepProjectors) { [weak self] in self?.dropStaleKept() }
    }

    private func dropStaleKept() {
        let now = clock()
        kept = kept.filter { now.timeIntervalSince($0.value.at) < Self.keepProjectors }
    }

    /// When each phone's link last went, since launch (`MacNetDevices`: a row's "last seen").
    package private(set) var linkWent: [UUID: Date] = [:]

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

    /// The IPN bus hold the phones keep.
    nonisolated static let busKey = "phones"

    /// Every record this Mac issued (its phones, paused ones too, and devices it allowed at a
    /// box), and its book's rev; nil before the identity is read.
    func issued() -> (records: [DeviceRecord], rev: Int, by: UUID)? {
        guard let me = device, let book = try? host.book.read() else { return nil }
        return (book.devices.filter { $0.kind != .mac && $0.issuedBy == me }, book.rev, me)
    }

    /// Whether a box owes a push: nothing it took is known, or it was another identity's, or this
    /// Mac's book moved on since, or the box's book is behind what it took (a lost or restored
    /// book). A box whose book moved on by itself (its own allow, another Mac's push) is left be.
    nonisolated static func owes(_ last: NodeDirectory.Pushed?, by: UUID, bookRev: Int, boxRev: Int?) -> Bool {
        guard let last, last.by == by, last.bookRev == bookRev, let boxRev else { return true }
        return boxRev < last.boxRev
    }

    /// Every box link up now hears what it owes.
    package func catchUpBoxes() {
        for link in boxLinks() { catchUp(link) }
    }

    /// A box link came up (any route): it gets the records this Mac issued when it owes them
    /// (`owes`), at most once per link-up. Nothing polls: the next link-up looks again.
    package func catchUp(_ link: any BoxDevicesLink) {
        guard link.takesMerge, let peer = link.boxPeer, let (records, rev, me) = issued() else { return }
        let box = peer.record.id
        let last = host.directory.all[box.uuidString.lowercased()]?.pushed
        // Pushes to this box on a dial that's gone will never be answered.
        sent = sent.filter { $0.value.box != box || $0.value.dial == link.dialNumber }
        // A push on this very link that carries this rev is on its way: nothing more.
        if sent.values.contains(where: { $0.box == box && $0.pushed.by == me && $0.pushed.bookRev == rev }) { return }
        guard Self.owes(last, by: me, bookRev: rev, boxRev: peer.devicesRev) else { return }
        let set = DevicesWire.Set(id: UUID().uuidString, rev: 0, records: records, merge: true)
        guard link.post(DevicesWire.encode(set)) else { return }
        if sent.count >= 64 { sent = [:] }
        sent[set.id] = Sent(box: box, dial: link.dialNumber, pushed: .init(by: me, bookRev: rev, boxRev: peer.devicesRev ?? 0), before: peer.devicesRev)
        NetAudit.line("push", ["box": box.uuidString.lowercased(), "records": "\(records.count)", "rev": "\(rev)"])
    }

    /// The box answered a push: what it took is noted (a refusal notes nothing, so the next
    /// link-up pushes again). When its book changed, phones hear the directory: one waiting at
    /// that box dials again at once.
    package func took(_ result: DevicesWire.Result) {
        guard let entry = sent.removeValue(forKey: result.id) else { return }
        defer { reached(entry.box) }
        guard result.ok else {
            HostLog.note("korenet", "push refused", result.message)
            host.directory.notePushed(nil, device: entry.box)
            return
        }
        var pushed = entry.pushed
        pushed.boxRev = result.rev
        host.directory.notePushed(pushed, device: entry.box)
        if result.rev != entry.before { pushDirectory() }
    }

    /// This Mac's directory (itself, its boxes on the tailnet) to every phone linked now, as a
    /// `devices.set` a phone takes from a Mac: a box that joined, gained a node key, was renamed,
    /// taken offline or removed, or now holds the phones, reaches them at once.
    package func pushDirectory() {
        let live = phones.values.filter { !$0.ended }
        guard !live.isEmpty, let records = Self.directory(state: shared.withLock { $0 }, book: host.book) else { return }
        let set = DevicesWire.Set(id: UUID().uuidString, rev: (try? host.book.read().rev) ?? 0, records: records)
        let data = DevicesWire.encode(set)
        for phone in live { phone.tell(data) }
    }

    // MARK: A phone reinstalled or left (ID3 b)

    /// The phone records a newly allowed phone replaces, on a strong signal only (a phone asleep,
    /// or a second phone of the same model, is never one): another id, the same Tailscale user, the
    /// same model (an older record without one: its name, which was the model unless renamed), and
    /// its node gone from the tailnet altogether, none of its node keys among the peers at all.
    /// A name with Tailscale's "-N" suffix is no signal: phones name their node per install
    /// (`kore-pixel-9-7f3a`), and a same-model phone that is merely off screen still has its node,
    /// so allowing a second one never retires the first (T-A8). Most recently seen first.
    nonisolated static func replaced(by record: DeviceRecord, model: String?, in devices: [DeviceRecord], peers: [TailnetStatus.Peer]) -> [DeviceRecord] {
        guard record.kind == .phone, let user = record.userId else { return [] }
        let present = Set(peers.map(\.publicKey))
        return devices.filter { old in
            guard old.kind == .phone, old.id != record.id, old.userId == user else { return false }
            let gone = old.nodeKeys.allSatisfy { !present.contains($0) }
            let sameModel = model.map { !$0.isEmpty && (old.model ?? old.name) == $0 } ?? false
            return gone && sameModel
        }
        .sorted { lastSeen($0, peers) ?? .distantPast > lastSeen($1, peers) ?? .distantPast }
    }

    /// When a record's phone was last on: the tailnet's word for its node, else the record's.
    nonisolated static func lastSeen(_ record: DeviceRecord, _ peers: [TailnetStatus.Peer]) -> Date? {
        peers.filter { record.nodeKeys.contains($0.publicKey) }.compactMap(\.lastSeen).max() ?? record.lastSeen
    }

    /// The card's line: "Replaces Pixel 9 · last seen 2 h ago".
    nonisolated static func replacesLine(_ old: DeviceRecord, peers: [TailnetStatus.Peer], now: Date) -> String {
        "Replaces \(old.name)" + (lastSeen(old, peers).map { " · last seen " + DevicesWords.ago($0, now: now) } ?? "")
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

    /// Handshakes under way that aren't waiting on the owner's card: work still running (a WhoIs,
    /// the proofs), each inside its pre-auth window.
    package var handshakesRunning: Int { shaking.keys.count { held[$0] == nil } }

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

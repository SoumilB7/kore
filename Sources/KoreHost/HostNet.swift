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
/// is up: an interface or address change (netlink on Linux) makes it look again, and while
/// Tailscale isn't running yet (Starting, signed out, its LocalAPI not there at boot) its IPN bus
/// is held until bound, reopened after 1, 2, 5, 10, 30, 60 s when it can't be; nothing polls. An
/// unclaimed box listens too: its first owner Mac has to reach it.
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
    /// SSH connects over the cap wait their turn (a Mac's relinks can briefly overlap), up to
    /// this many; never closed without a word while a slot is about to free.
    package static let maxSSHWaiting = 16
    private var sshWaiting: [Int32] = []

    func handshaking(_ route: Binding.Route) -> Int { handshakes.values.filter { $0.route == route }.count }

    unowned let host: HostDaemon
    /// The tailnet while the box is on KoreNet (`join`); nil while off: no port, no LocalAPI, no
    /// netlink or bus.
    package private(set) var tailnet: (any Tailnet)?
    /// The tailnet is Kore's own (`kore-tailnet`, tsnet in userspace): its port is its listen,
    /// each connection handed over on its socket, and its bus says when it signs in.
    package private(set) var userspace = false
    package let identity: BoxIdentity
    private let limiter: PreAuthLimiter
    private let tickets = ResumeTickets()
    /// The port the next bind uses.
    package var port: UInt16

    /// The sockets bound now, and the addresses they're on.
    package private(set) var bound: [String] = []
    private var listeners: [(fd: Int32, source: DispatchSourceRead)] = []
    /// Kore's own tailnet's listens: each a socket its connections come over, read on a thread.
    private var handoffs: [Handoff] = []
    /// The first listening socket (tests read the port the kernel picked).
    package var firstListener: Int32? { listeners.first?.fd }

    /// One handed-off listen: open until `close`, which wakes its thread (it closes the socket).
    private final class Handoff: @unchecked Sendable {
        let socket: TailnetListenSocket
        private let lock = NSLock()
        private var shut = false
        init(_ socket: TailnetListenSocket) { self.socket = socket }
        var open: Bool { lock.withLock { !shut } }
        func close() {
            let first = lock.withLock {
                defer { shut = true }
                return !shut
            }
            if first { _ = shutdown(socket.fd, Int32(SHUT_RDWR)) }
        }
    }
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
    /// Installed Tailscale's choice as its state last said (`TailnetChooser`): a box that came up
    /// signed out or starting ends `installed` once it runs.
    package private(set) var choice: TailnetChooser.Choice?
    /// Waiting for installed Tailscale and its bus couldn't be held: its next try, the tries that
    /// failed in a row, and which bus is current (an older one's end is dropped).
    private var busRetry: (@MainActor () -> Void)?
    private var busTries = 0
    private var busGeneration = 0
    /// The waits before each new try at the bus; the last repeats.
    package static let busBackoff: [TimeInterval] = [1, 2, 5, 10, 30, 60]
    /// Runs `work` on the main queue after a delay; returns its cancel (tests: their own clock).
    package var later: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void = { delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
    /// A try at the bus waits now.
    package var retrying: Bool { busRetry != nil }
    private var ssh: (fd: Int32, source: DispatchSourceRead)?
    private var handshakes: [ObjectIdentifier: Handshake] = [:]
    /// WhoIs lookups under way (each a LocalAPI round trip off the main thread), counted with the
    /// tailnet handshakes against `maxHandshakes`.
    package private(set) var whoising = 0
    /// A status read under way (off the main thread), whether another was asked for meanwhile,
    /// and who waits for it to settle (tests).
    private var reading = false
    private var readAgain = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped by `leave`: a read or WhoIs from before it is dropped.
    private var joins = 0

    /// One session before its proof: its socket's read source and its 2 s deadline.
    private final class Handshake {
        let session: NetSession
        let route: Binding.Route
        let facts: NetPeerFacts
        /// The tailnet address the limiter admitted it as.
        let remote: String?
        var read: DispatchSourceRead?
        var deadline: DispatchSourceTimer?
        /// Bytes came from the peer; or it closed before any did (a probe: refunded).
        var heard = false
        var quietEnd = false
        /// The source's own descriptor for the socket (open until the source is cancelled).
        var watched: Int32 = -1

        /// Before the session reads: did the peer say anything, or only go (a close, a reset)?
        func look() {
            guard !heard, !quietEnd, watched >= 0 else { return }
            var byte: UInt8 = 0
            let peeked = recv(watched, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
            if peeked > 0 {
                heard = true
            } else if peeked == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                quietEnd = true
            }
        }
        init(session: NetSession, route: Binding.Route, facts: NetPeerFacts, remote: String?) {
            self.session = session
            self.route = route
            self.facts = facts
            self.remote = remote
        }
        func cancel() {
            watched = -1
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

    /// On KoreNet: watch the interface, bind the port (`userspace`: Kore's own tailnet, whose
    /// listen and bus are its socket's). `choice`: installed Tailscale's, as the daemon chose it.
    package func join(_ tailnet: any Tailnet, userspace: Bool = false, choice: TailnetChooser.Choice? = nil) {
        guard self.tailnet == nil else { return }
        joins += 1
        self.tailnet = tailnet
        self.userspace = userspace
        self.choice = choice
        watchInterfaces()
        rebind()
    }

    /// Off KoreNet: the port and every watcher go (links already up are the daemon's to end).
    package func leave() {
        joins += 1
        closeListeners()
        bindProblem = nil
        try? FileManager.default.removeItem(at: host.paths.netState)
        netlink?.source.cancel()
        netlink = nil
        stopWaiting()
        tailnet = nil
        userspace = false
        selfNode = nil
        choice = nil
        for (key, shake) in handshakes where shake.route == .tailnet {
            shake.cancel()
            shake.session.close(NetControl.Reason.off)
            handshakes[key] = nil
        }
    }

    /// Whether a port is bound now.
    package var listening: Bool { !listeners.isEmpty || !handoffs.isEmpty }

    /// Kore's own tailnet was chosen and couldn't start: said for `status` and `upgrade`.
    package func unavailable(_ why: String) {
        bindProblem = why
        writeState(BoxTailnet.unavailablePrefix + why)
    }

    /// A tailnet is being chosen (Kore's own may take a few seconds to start).
    package func choosing() { writeState("not listening: choosing a tailnet") }
    /// Whether anything watches the network now (netlink, the IPN bus, a try at it).
    package var watching: Bool { netlink != nil || busWatch != nil || busRetry != nil }

    package func stop() {
        leave()
        ssh?.source.cancel()
        ssh = nil
        for fd in sshWaiting { close(fd) }
        sshWaiting = []
        unlink(host.paths.netSocket.path)
        for shake in handshakes.values {
            shake.cancel()
            shake.session.close(NetControl.Reason.off)
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

    /// Looks at Tailscale again and binds what it says (or closes, when it's stopped). The status
    /// read (a LocalAPI round trip, up to its 5 s timeout) runs off the main thread; what it says
    /// is applied back on it. A look asked for while one runs takes another after it.
    /// Work off the main thread, told as it begins (true) and ends (false): the KoreNet system
    /// tests' world doesn't move its clock on while any is under way. kore-host: nothing listens.
    nonisolated(unsafe) package static var counting: @Sendable (Bool) -> Void = { _ in }

    package func rebind() {
        guard let tailnet else { return closeListeners() }
        guard !reading else { return readAgain = true }
        reading = true
        let mine = joins
        let (userspace, had, listening, port) = (self.userspace, bound, !handoffs.isEmpty, self.port)
        let counting = Self.counting
        counting(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { DispatchQueue.main.async { counting(false) } }
            let read = Result { try tailnet.status() }
            // Kore's own: its listen is a request on its socket, made here off the main thread.
            var made: Result<[TailnetListenSocket], any Error>?
            if userspace, case .success(let status) = read, let want = try? Self.addresses(status), !want.isEmpty, !(listening && want == had) {
                made = Result { try tailnet.listen(port: port) }
            }
            let listened = made
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        if case .success(let sockets)? = listened { for socket in sockets { Sockets.closeFD(socket.fd) } }
                        return
                    }
                    self.reading = false
                    if mine == self.joins, self.tailnet != nil {
                        self.apply(read, listened: listened)
                    } else if case .success(let sockets)? = listened {
                        for socket in sockets { Sockets.closeFD(socket.fd) }
                    }
                    if self.readAgain {
                        self.readAgain = false
                        if self.tailnet != nil { return self.rebind() }
                    }
                    let waiting = self.readWaiters
                    self.readWaiters = []
                    for waiter in waiting { waiter.resume() }
                }
            }
        }
    }

    /// Returns once no status read is under way (tests: what `join`, `rebind` or a reload set
    /// going has been applied).
    package func settled() async {
        guard reading else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    private func apply(_ read: Result<TailnetStatus, any Error>, listened: Result<[TailnetListenSocket], any Error>? = nil) {
        func drop() { if case .success(let sockets)? = listened { for socket in sockets { Sockets.closeFD(socket.fd) } } }
        let status: TailnetStatus
        switch read {
        case .success(let got):
            status = got
        case .failure(let error):
            drop()
            if !bound.isEmpty { HostJournal.note("korenet closed", ["reason": "\(error)"]) }
            closeListeners()
            selfNode = nil
            noteProblem("Tailscale isn't answering (\(error))")
            // It was up and its daemon went (`systemctl stop tailscaled`): as a stop, Kore's own
            // takes over beside it. Never at boot (not up yet): its bus says when it is.
            if !userspace, choice == .installed, host.installedTailscaleWentDown() {
                choice = .stopped
                return
            }
            return waitForTailnet()
        }
        // Kore's own: signed in as whom, or signed out (said to the owner's Macs at once).
        if userspace { host.ownStatus(status) }
        let before = selfNode?.publicKey
        selfNode = status.selfNode
        // Macs linked now hear this box's node key once it's listening (below), or here when the
        // key changed under a listener that stays: never before the port takes connections, or a
        // Mac would dial, fail and settle back on SSH.
        let keyChanged = selfNode?.publicKey != before && selfNode?.publicKey != nil
        let want: [String]
        do {
            want = try Self.addresses(status)
        } catch {
            drop()
            HostJournal.note("korenet refused", ["reason": "\(error)"])
            closeListeners()
            noteProblem("\(error)")
            return
        }
        if userspace { return applyUserspace(status, want: want, keyChanged: keyChanged, listened: listened) }
        if status.backendState == .running, let key = selfNode?.publicKey, key != host.installedNodeKey { host.installedNodeKey = key }
        if status.backendState == .running { host.ownStillListed(status) }
        noteChoice(TailnetChooser.choose(.state(status.backendState)))
        let index = interfaceIndex()
        if Self.keeps(want: want, bound: bound, listening: !listeners.isEmpty, boundIndex: boundIndex, index: index) {
            if keyChanged { host.netNodeChanged() }
            return stopWaiting()
        }
        closeListeners()
        guard !want.isEmpty else {
            noteProblem("Tailscale is \(status.backendState.rawValue)")
            // Starting or signed out: no interface or address change need come when it runs
            // (tailscale0 and its addresses can be up already at boot), its bus says.
            return waitForTailnet()
        }
        #if os(Linux)
        let device: String? = index > 0 ? Self.interface : nil
        // Userspace Tailscale has no interface: its addresses aren't this kernel's to bind. Its
        // bus can't change that; netlink says when `tailscale0` comes.
        guard device != nil else {
            stopWaiting()
            return noteProblem("no \(Self.interface) interface")
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
                let why = code == EADDRINUSE ? "port \(port) in use" : String(cString: strerror(code))
                HostJournal.note("korenet bind failed", ["address": address, "port": "\(port)", "reason": why])
                return noteProblem(why)
            }
            fds.append(fd)
        }
        bindProblem = nil
        writeState("listening " + want.joined(separator: ",") + " port \(fds.first.flatMap(Sockets.localPort) ?? port)")
        bound = want
        binds += 1
        for fd in fds {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll(fd) } }
            source.setCancelHandler { close(fd) }
            source.resume()
            listeners.append((fd, source))
        }
        // Now taking connections: every linked Mac hears the node key (it moves to KoreNet).
        host.netNodeChanged()
        stopWaiting()
        HostJournal.note("korenet listening", ["addresses": want.joined(separator: ","), "port": "\(port)"])
    }

    /// Kore's own tailnet: its listen (made off the main thread) taken, each connection it hands
    /// over read on a thread of its own and greeted here. Its bus stays watched: a sign-in, a
    /// sign-out or new addresses come that way.
    private func applyUserspace(_ status: TailnetStatus, want: [String], keyChanged: Bool, listened: Result<[TailnetListenSocket], any Error>?) {
        if !handoffs.isEmpty, want == bound, listened == nil {
            if keyChanged { host.netNodeChanged() }
            return
        }
        closeListeners()
        guard !want.isEmpty else {
            if case .success(let sockets)? = listened { for socket in sockets { Sockets.closeFD(socket.fd) } }
            return noteProblem("kore-tailnet is \(status.backendState.rawValue)")
        }
        let sockets: [TailnetListenSocket]
        switch listened {
        case .success(let made)?:
            sockets = made
        case .failure(let error)?:
            HostJournal.note("korenet listen failed", ["reason": "\(error)", "tailnet": "kore"])
            return noteProblem("\(error)")
        case nil:
            // Read while a listen was still held: the next look listens.
            return rebind()
        }
        bindProblem = nil
        writeState("listening " + want.joined(separator: ",") + " port \(port) (kore-tailnet)")
        bound = want
        binds += 1
        for socket in sockets { serve(socket) }
        host.netNodeChanged()
        HostJournal.note("korenet listening", ["addresses": want.joined(separator: ","), "port": "\(port)", "tailnet": "kore"])
    }

    /// One handed-off listen: its thread takes each connection and greets it on the main queue,
    /// until the listen closes.
    private func serve(_ socket: TailnetListenSocket) {
        let handoff = Handoff(socket)
        handoffs.append(handoff)
        Thread.detachNewThread { [weak self] in
            defer { Sockets.closeFD(socket.fd) }
            while handoff.open {
                guard let (fd, remote) = try? socket.accept() else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, handoff.open, self.handoffs.contains(where: { $0 === handoff }) else { return Sockets.closeFD(fd) }
                        self.admit(fd, remote: remote)
                    }
                }
            }
        }
    }

    /// Why the port isn't bound, kept for `status` (another process: a file in the runtime folder).
    private func noteProblem(_ why: String) {
        bindProblem = why
        writeState("not listening: " + why)
    }

    private func writeState(_ line: String) {
        try? HostPaths.privateFile(Data((line + "\n").utf8), to: host.paths.netState)
    }

    private func closeListeners() {
        for listener in listeners {
            // The descriptor closes in the source's cancel handler.
            listener.source.cancel()
        }
        listeners = []
        for handoff in handoffs { handoff.close() }
        handoffs = []
        bound = []
    }

    /// Linux: netlink says when `tailscale0` or its addresses come or go. Installed Tailscale's
    /// state changes come over its bus, held only while waiting for it (`waitForTailnet`).
    private func watchInterfaces() {
        if userspace { return watchBus() }
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
        #endif
    }

    /// Installed Tailscale isn't running yet (or its LocalAPI isn't answering): its bus is held
    /// until the port is bound. Kore's own holds its bus while on already.
    private func waitForTailnet() {
        guard !userspace, tailnet != nil, busWatch == nil, busRetry == nil else { return }
        watchBus()
    }

    /// Bound, or off: the bus and any try at it go.
    private func stopWaiting() {
        busGeneration += 1
        busWatch?.cancel()
        busWatch = nil
        busRetry?()
        busRetry = nil
        busTries = 0
    }

    /// The tailnet's bus: each state it says makes a look (installed Tailscale: held until bound;
    /// Kore's own: held while on, its sign-ins come this way). Its first message is the state now.
    private func watchBus() {
        guard let tailnet else { return }
        busGeneration += 1
        let mine = busGeneration
        let events = tailnet.events()
        busWatch = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                // It answered: the next try, if one is needed, starts from the first wait.
                case .state, .loginFinished: self.busTries = 0
                // Kore's own: its addresses can come after its state says Running.
                case .status where self.userspace && !self.listening: break
                default: continue
                }
                // Bound, the read drops the bus (and ends this loop's stream).
                self.rebind()
            }
            self?.busEnded(mine)
        }
    }

    /// The bus ended by itself (tailscaled not there yet, or restarted) while still waiting: tried
    /// again after the next wait, never at once.
    private func busEnded(_ generation: Int) {
        guard generation == busGeneration, !Task.isCancelled else { return }
        busWatch = nil
        guard !userspace, tailnet != nil, !listening else { return }
        let wait = Self.busBackoff[min(busTries, Self.busBackoff.count - 1)]
        busTries += 1
        busRetry = later(wait) { [weak self] in
            guard let self else { return }
            self.busRetry = nil
            guard self.tailnet != nil, !self.listening else { return }
            self.waitForTailnet()
        }
    }

    /// Installed Tailscale's choice as its state says now; a change is journaled.
    private func noteChoice(_ now: TailnetChooser.Choice) {
        guard now != choice else { return }
        let was = choice
        if let was { HostJournal.note("korenet choice", ["tailnet": "tailscale", "choice": "\(now)", "was": "\(was)"]) }
        choice = now
        // Up, then down (stopped, signed out): Kore's own takes over beside it.
        if was == .installed, now == .stopped || now == .signedOut { host.installedTailscaleWentDown() }
    }

    // MARK: Accepting

    private func acceptAll(_ listener: Int32) {
        while true {
            // Close-on-exec at once: never inherited by the `gh`, `git` or CLI children it starts.
            let fd = Sockets.accept(listener)
            guard fd >= 0 else { return }
            admit(fd, remote: Sockets.peerAddress(fd)?.description)
        }
    }

    /// A tailnet connection in: room first (handshakes and WhoIs lookups under way: one turned
    /// away for capacity doesn't spend its source's limit), then its source's limit, then WhoIs.
    private func admit(_ fd: Int32, remote: String?) {
        guard handshaking(.tailnet) + whoising < Self.maxHandshakes, let remote, limiter.admit(remote) else { return Sockets.closeFD(fd) }
        whoisThenGreet(fd, remote: remote)
    }

    /// WhoIs off the main thread (a local socket round trip), then the session. A WhoIs failure
    /// closes the connection: no node key is ever taken from the peer's own word.
    private func whoisThenGreet(_ fd: Int32, remote: String) {
        guard let tailnet else { return Sockets.closeFD(fd) }
        whoising += 1
        let mine = joins
        let counting = Self.counting
        counting(true)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { counting(false) } }
            let who = try? tailnet.whois(remote)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.whoising -= 1
                    guard mine == self.joins, self.tailnet != nil else { return Sockets.closeFD(fd) }
                    guard let who else {
                        HostJournal.note("korenet refused", ["from": remote, "reason": "whois"])
                        return Sockets.closeFD(fd)
                    }
                    self.greet(fd, route: .tailnet, facts: Self.facts(who), whois: who, remote: remote)
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
    package func greet(_ fd: Int32, route: Binding.Route, facts: NetPeerFacts, whois: TailnetWhoIs?, remote: String? = nil) {
        let nodeKey = route == .ssh ? Binding.Route.sshNodeKey : (selfNode?.publicKey ?? "")
        guard !nodeKey.isEmpty else { return Sockets.closeFD(fd) }
        let local = NetLocal(device: identity.device, kind: .box, nodeKey: nodeKey, signer: identity.signer)
        var setup = NetSession.Server(local: local, route: route, peer: facts, book: host.devices.book, tickets: tickets)
        setup.ownUser = selfNode?.owner
        setup.stranger = { [weak self] hello in
            MainActor.assumeIsolated { self?.stranger(hello, route: route, facts: facts, whois: whois) ?? .refuse(NetControl.Reason.unknown) }
        }
        if route == .ssh {
            setup.rekey = { [weak self] hello, known in MainActor.assumeIsolated { self?.rekey(hello, known) } }
        }
        let session = NetSession(fd: fd, role: .server(setup), clock: host.now)
        let shake = Handshake(session: session, route: route, facts: facts, remote: remote)
        let key = ObjectIdentifier(shake)
        handshakes[key] = shake
        // The session owns `fd` and closes it; the source watches its own duplicate, closed when
        // the source is cancelled.
        guard let watched = Sockets.duplicate(fd) else {
            handshakes[key] = nil
            return session.close(NetControl.Reason.limit)
        }
        let read = DispatchSource.makeReadSource(fileDescriptor: watched, queue: .main)
        shake.watched = watched
        read.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handshakes[key]?.look()
                self?.advance(key)
            }
        }
        read.setCancelHandler { close(watched) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + NetSession.preAuthWindow + 0.05)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.advance(key) } }
        shake.read = read
        shake.deadline = timer
        session.start()
        read.resume()
        timer.resume()
        // Its challenge couldn't go (the peer left already): let it go now, not at its deadline.
        if case .closed = session.state { advance(key) }
    }

    /// Pumps a handshake: established goes to the daemon, closed is let go.
    private func advance(_ key: ObjectIdentifier) {
        guard let shake = handshakes[key] else { return }
        _ = shake.session.pump()
        switch shake.session.state {
        case .handshaking:
            return
        case .closed(let reason):
            // Closed on its first write (the peer gone already): looked at before the source goes.
            shake.look()
            shake.cancel()
            handshakes[key] = nil
            // A connect that closed without a word (Kore's "is kore-host there?" probe) costs no
            // pre-auth slot; a silent one held to its deadline still does.
            let probe = shake.quietEnd && !shake.heard
            if probe, let remote = shake.remote { limiter.refund(remote) }
            // Every refusal before the proof, and every peer that hung up after the challenge
            // (its `bye`, or gone), says who and why; a probe that never spoke isn't one.
            if !probe || reason == NetControl.Reason.timeout || reason == NetControl.Reason.limit { refused(shake, reason) }
        case .established(let peer):
            shake.cancel()
            handshakes[key] = nil
            // Proven as a device the book holds: not the pre-auth traffic the limit is for. A Mac
            // following this box between its nodes dials it several times a minute, and must
            // never be turned away unread for that.
            if let remote = shake.remote { limiter.refund(remote) }
            established(shake, peer)
        }
        greetWaiting()
    }

    /// A handshake that ended before its proof held: the device as its hello named it, else (on
    /// the tailnet) as its node key's record here names it.
    private func refused(_ shake: Handshake, _ reason: String) {
        let route = shake.route
        let device = shake.session.hello?.device
            ?? (route == .tailnet ? (try? host.devices.book.record(nodeKey: shake.facts.nodeKey))?.id : nil)
        HostJournal.audit("refused", [
            "device": device?.uuidString.lowercased(), "node": route == .tailnet ? shake.facts.nodeKey : nil, "from": shake.remote,
            "route": route.rawValue, "reason": reason,
        ])
    }

    /// A handshake slot freed: the SSH connects that waited for one are greeted, oldest first.
    private func greetWaiting() {
        while !sshWaiting.isEmpty, handshaking(.ssh) < Self.maxSSHHandshakes, ssh != nil {
            greet(sshWaiting.removeFirst(), route: .ssh, facts: .ssh, whois: nil)
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
                // Its Mac asks again before its owner's Allow: still the claimant.
                if window { return .refuse(NetControl.Reason.claim) }
            } else if store.claimant == nil, window {
                var entry = fresh
                entry.claim = true
                notePending(entry, at: now)
                // The Mac shows its claim card on this answer; `unknown` tells it to run join again.
                return .refuse(NetControl.Reason.claim)
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

    /// Over SSH only: a Mac this book holds, with a new identity key (Kore 0.3.7 keeps it in a
    /// file and made a new one, never reading the Keychain's). The grant it came in on (`attach`
    /// fills it in, so the secret never left this box) must be the one that Mac enrolled with:
    /// the same trust as its first enroll, given by the SSH login that runs `attach`. An expired
    /// grant counts (its Mac proves itself on it from then on). Only the key changes: its name,
    /// abilities, owner and node keys stay. Anything else is refused as unknown.
    func rekey(_ hello: NetControl.Hello, _ known: DeviceRecord) -> NetSession.Stranger? {
        let id = known.id.uuidString.lowercased()
        guard let enroll = hello.enroll, let legacy = hello.legacyGrant, known.kind == .mac, enroll.kind ?? .mac == .mac else {
            HostJournal.audit("deny", ["device": id, "reason": "rekey without a grant"])
            return nil
        }
        let grants = GrantStore(host.paths.grants)
        let now = host.now()
        guard let grant = grants.load(legacy.name), Self.same(grant.secret, legacy.secret), Self.rekeys(grant, for: known.id, among: grants.all(), at: now)
        else {
            HostJournal.audit("deny", ["device": id, "grant": legacy.name, "reason": "rekey grant"])
            return nil
        }
        // A grant issued again before `allow` kept its device (kore-host 0.3.6, or Set up's
        // `allow` on one) is tied to this Mac now, as its upgrade would have.
        let binds = grant.device == nil
        var record = known
        record.identityKey = enroll.identityKey
        guard (try? record.validate()) != nil else { return nil }
        let host = host
        let old = known.identityKey
        return .enroll(record) { _ in
            MainActor.assumeIsolated {
                if binds {
                    guard var unbound = grants.load(legacy.name), unbound.device == nil, unbound.secret == grant.secret else { return false }
                    unbound.device = record.id
                    unbound.expires = unbound.expires ?? Int(now.addingTimeInterval(Grant.upgradeGrace).timeIntervalSince1970)
                    do { try grants.save(unbound) } catch { return false }
                }
                do {
                    try host.devices.book.update { devices in
                        guard let i = devices.firstIndex(where: { $0.id == record.id }), devices[i].identityKey == old else {
                            throw TrustError.refused("changed meanwhile")
                        }
                        devices[i].identityKey = record.identityKey
                    }
                } catch {
                    if binds, var undo = grants.load(legacy.name), undo.device == record.id, undo.secret == grant.secret {
                        undo.device = nil
                        undo.expires = grant.expires
                        try? grants.save(undo)
                    }
                    return false
                }
                if binds { HostJournal.audit("bind", ["device": id, "grant": legacy.name, "how": "rekey"]) }
                HostJournal.audit("rekey", ["device": id, "grant": legacy.name, "route": "ssh"])
                return true
            }
        }
    }

    /// The grants a Mac's SSH re-key may come in on: the one it enrolled with (expired too), or
    /// an unexpired one issued again with no device yet, while no grant here is that Mac's
    /// own. Another device's grant never is.
    nonisolated static func rekeys(_ grant: Grant, for device: UUID, among all: [Grant], at now: Date) -> Bool {
        if let bound = grant.device { return bound == device }
        return !grant.expired(at: now) && !all.contains { $0.device == device }
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
        Sockets.closeOnExec(fd)
        guard HostListener.bind(fd, path) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                while true {
                    let client = Sockets.accept(fd)
                    guard client >= 0 else { return }
                    guard let self, HostListener.peerIsUser(client) else {
                        close(client)
                        continue
                    }
                    Self.noSigPipe(client)
                    guard self.handshaking(.ssh) < Self.maxSSHHandshakes else {
                        if self.sshWaiting.count < Self.maxSSHWaiting { self.sshWaiting.append(client) } else { close(client) }
                        continue
                    }
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

    /// B: what a phone's raises on this session sign over.
    var bindingDigest: Data? { session.bindingDigest }

    /// The hello's ticket was honoured: the client's cursors (`resume`) are on their way.
    var resumed: Bool {
        if case .established(let peer) = session.state { return peer.resumed }
        return false
    }

    /// The client's cursors once they came (or nil once anything else came first).
    var cursors: [String: JSONValue]? { session.cursors }

    /// Whether the cursors may still come.
    var awaitingCursors: Bool { session.awaitingCursors }

    /// Called once, when nothing more is awaited before the client's first answer (its cursors
    /// came, or anything else did).
    var cursorsSettled: (@MainActor () -> Void)?

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
        let messages = session.pump()
        if let settled = cursorsSettled, !session.awaitingCursors {
            cursorsSettled = nil
            settled()
        }
        for message in messages where !done { frame?(message.payload) }
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
    private static func watched(_ fd: Int32) -> Int32? { Sockets.duplicate(fd) }

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

import Foundation
import HostClient
import KoreCore
import KoreNet
import KoreTrust
import KoreUI
import LinkProtocol
import Tailnet

/// The owner's other Macs this Mac is paired with (their records in its own book, kind mac,
/// owner), as a login's move needs them: whether each is on the tailnet now, whether its Kore
/// takes a login (`loginMove` in its link's welcome), and one command at a time over a KoreNet
/// session dialled on demand (both identities proven; the other's as pinned at pairing). A
/// session is kept a minute after its last command, for the next step of the same move.
@MainActor
package final class MacPeers {
    package static let shared = MacPeers()

    package struct Peer: Equatable, Sendable {
        package var id: UUID
        package var name: String
        package var online: Bool
        package var takesLoginMove: Bool
        /// Whether its caps were heard yet (a dial since launch).
        package var capsKnown: Bool

        package init(id: UUID, name: String, online: Bool, takesLoginMove: Bool, capsKnown: Bool = true) {
            (self.id, self.name, self.online, self.takesLoginMove, self.capsKnown) = (id, name, online, takesLoginMove, capsKnown)
        }
    }

    /// Something a peer's row says changed (online, its caps).
    package var changed: () -> Void = {}

    /// A change heard: the Devices rows and a login's ⋯ (its Mac places) both look again.
    private func told() {
        changed()
        LoginMoves.shared.placesChanged()
    }
    /// The net it rides on (Kore: the KoreNet switch's; tests: their own).
    package var net: () -> MacNet? = { MacNet.shared }
    /// How long a session stays after its last command.
    package static var idle: TimeInterval = 60
    /// How long one command waits for its answer (a commit reads the login with its CLI).
    package static var answerWithin: TimeInterval = 60

    private var online: [UUID: Bool] = [:]
    private var caps: [UUID: [String]] = [:]
    private var links: [UUID: PeerLink] = [:]
    private var refreshing = false
    private var capsAsked: Set<UUID> = []
    private let queue = DispatchQueue(label: "dev.kore.mac-peers")

    package init() {}

    /// Paired Macs, as last read.
    package func paired() -> [Peer] {
        guard let net = net() else { return [] }
        return net.pairedMacs().map {
            Peer(
                id: $0.id, name: $0.name, online: online[$0.id] ?? false, takesLoginMove: caps[$0.id]?.contains(LinkLogins.cap) ?? false,
                capsKnown: caps[$0.id] != nil)
        }
    }

    /// Reads who's online (one status read, off the main actor), then each online peer's caps
    /// not known yet (one dial each, at most once until `refresh` comes again).
    package func refresh() {
        guard !refreshing, let net = net(), let tailnet = net.host.tailnet else { return }
        refreshing = true
        capsAsked = []
        let records = net.pairedMacs()
        queue.async {
            let status = try? tailnet.status()
            var found: [UUID: Bool] = [:]
            for record in records { found[record.id] = status.flatMap { MacPeers.node(record, in: $0) }?.online ?? false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    self.online = found
                    self.told()
                    for record in records where found[record.id] == true && self.caps[record.id] == nil && !self.capsAsked.contains(record.id) {
                        self.capsAsked.insert(record.id)
                        Task { @MainActor in await self.open(record.id) }
                    }
                }
            }
        }
    }

    /// One 1.14 command to a paired Mac, its raw answer; on no answer or a drop, `ok` false with
    /// no code (the engine reads that as unreachable). The login's bytes are never logged.
    package func command(_ peer: UUID, _ kind: ControlKind, _ args: ControlArgs) async -> LoginMoveResult {
        let id = UUID().uuidString.lowercased()
        guard let ready = prepared(peer) else { return LoginMoveResult(id: id, ok: false, message: "unreachable") }
        let (link, dial) = ready
        let payload = HostWire.command(id: id, .control(kind, args))
        let within = Self.answerWithin
        let (raw, heard): (Data?, [String]?) = await withCheckedContinuation { done in
            link.queue.async {
                let answer = link.request(id: id, payload, dial: dial, within: within)
                done.resume(returning: (answer, link.caps))
            }
        }
        noteCaps(peer, heard)
        guard let raw, let result = try? JSONDecoder().decode(LoginMoveResult.self, from: raw) else {
            return LoginMoveResult(id: id, ok: false, message: "unreachable")
        }
        return result
    }

    // MARK: Its usage

    /// Each request a paired Mac's Kore chats made, as this Mac's forwarded usage (awaited, so the
    /// card splits a limit only once it's in).
    package static var requestSink: @Sendable (ForwardedRequest) async -> Void = { await KoreUsage.shared.forwarded($0) }
    /// Each plan reading a paired Mac heard, as evidence for that login here.
    package static var planSink: @Sendable (PlanSnapshot) -> Void = { PlanSnapshotLog.shared.append($0) }
    /// Where each paired Mac's ledger was read to, by its id (`usage/peer-cursors.json`).
    package var cursorsFile: URL? = KoreFolders.support.appendingPathComponent("usage/peer-cursors.json")
    /// How long one page waits for its answer.
    package static var pageWithin: TimeInterval = 15
    private var pulling: [UUID: Task<Void, Never>] = [:]

    /// Every paired Mac's usage brought up to date (the usage card opening): one pull each, in
    /// parallel; a pull under way is waited for.
    package func catchUpUsage() async {
        let tasks = paired().filter(\.online).map { peer in Task { await self.pullUsage(peer.id) } }
        for task in tasks { await task.value }
    }

    /// A paired Mac's ledger brought up to date, one pull at a time: one asked for while another
    /// runs waits for it, then reads what came since.
    func pullUsage(_ peer: UUID) async {
        // The running pull clears itself as it ends: a waiter woken by it never sees it again
        // (left for the caller to clear, a waiter on the main actor spun on the finished task
        // and the caller never ran).
        while let running = pulling[peer] { await running.value }
        let task = Task {
            await self.pullPages(peer)
            self.pulling[peer] = nil
        }
        pulling[peer] = task
        await task.value
    }

    /// A paired Mac's ledger after the cursor kept, a page at a time: its requests as Kore's
    /// ("mac:<id>/<session>", for the login each ran on), its readings into the snapshot log
    /// (source "mac"). A Mac whose Kore doesn't serve usage is left alone.
    private func pullPages(_ peer: UUID) async {
        guard let ready = prepared(peer) else { return }
        let (link, dial) = ready
        var cursor = cursors()[peer.uuidString.lowercased()]
        for _ in 0..<100 {
            let id = UUID().uuidString.lowercased()
            let ask = (try? JSONEncoder().encode(UsageWire.Since(id: id, cursor: cursor, plan: true))) ?? Data()
            let within = Self.pageWithin
            let (raw, heard): (Data?, [String]?) = await withCheckedContinuation { done in
                link.queue.async {
                    // Caps first: an older Kore wouldn't answer the ask at all.
                    guard link.ensure(dial) != nil, link.caps?.contains(MacPeerLink.usageCap) == true else { return done.resume(returning: (nil, link.caps)) }
                    done.resume(returning: (link.request(id: id, ask, dial: dial, within: within), link.caps))
                }
            }
            noteCaps(peer, heard)
            guard let raw, let page = try? JSONDecoder().decode(UsageWire.Page.self, from: raw), page.id == id else { return }
            let key = LoginMoves.macKey(peer)
            for line in page.lines {
                if line.isPlan {
                    if let snapshot = HostConnection.planSnapshot(line, key: key, source: "mac") { Self.planSink(snapshot) }
                } else if line.acct != nil {
                    // Never a line without its login: on this Mac it would count for the wrong one.
                    var request = HostConnection.forwarded(line, key: key, title: nil)
                    request.account = line.acct
                    await Self.requestSink(request)
                }
            }
            cursor = page.cursor
            saveCursor(peer, page.cursor)
            guard page.more, !page.lines.isEmpty else { return }
        }
    }

    private func cursors() -> [String: Int] {
        guard let file = cursorsFile, let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private func saveCursor(_ peer: UUID, _ cursor: Int) {
        guard let file = cursorsFile else { return }
        var all = cursors()
        all[peer.uuidString.lowercased()] = cursor
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Opens a session to read its welcome (its caps).
    private func open(_ peer: UUID) async {
        guard let ready = prepared(peer) else { return }
        let (link, dial) = ready
        let heard: [String]? = await withCheckedContinuation { done in
            link.queue.async {
                _ = link.ensure(dial)
                done.resume(returning: link.caps)
            }
        }
        noteCaps(peer, heard)
    }

    private func noteCaps(_ peer: UUID, _ heard: [String]?) {
        guard let known = heard, caps[peer] != known else { return }
        let first = caps[peer] == nil
        caps[peer] = known
        online[peer] = true
        told()
        // Its link just came up and it serves usage: what it did meanwhile comes now.
        if first, known.contains(MacPeerLink.usageCap) { Task { await self.pullUsage(peer) } }
    }

    /// The peer's link and what dialling it needs, while KoreNet runs and the peer is paired.
    private func prepared(_ peer: UUID) -> (PeerLink, PeerLink.Dial)? {
        guard let net = net(), let tailnet = net.host.tailnet, let me = net.identity, let selfNode = net.selfNode,
              let record = net.pairedMacs().first(where: { $0.id == peer })
        else { return nil }
        let link = links[peer] ?? PeerLink(idle: Self.idle)
        links[peer] = link
        return (link, PeerLink.Dial(tailnet: tailnet, record: record, device: me.device, signer: me.signer, selfNode: selfNode, book: net.host.book))
    }

    /// A peer's node on the tailnet: by a node key its record holds, else by its host name.
    nonisolated static func node(_ record: DeviceRecord, in status: TailnetStatus) -> TailnetStatus.Peer? {
        if let peer = status.peers.first(where: { record.nodeKeys.contains($0.publicKey) }) { return peer }
        let host = MacNet.shortName(record.fqdn).lowercased()
        guard !host.isEmpty else { return nil }
        return status.peers.first { $0.hostName.lowercased() == host && $0.os == "macOS" && !$0.shared }
    }
}

/// One paired Mac's KoreNet session, touched on its own queue only (calls block there).
final class PeerLink: @unchecked Sendable {
    struct Dial: @unchecked Sendable {
        var tailnet: any Tailnet
        var record: DeviceRecord
        var device: UUID
        var signer: any IdentitySigner
        var selfNode: TailnetStatus.SelfNode
        var book: DeviceBook
    }

    let queue = DispatchQueue(label: "dev.kore.mac-peer")
    private var session: NetSession?
    /// Its link welcome's caps, once heard.
    private(set) var caps: [String]?
    private var used = Date()
    /// How long it stays after its last command.
    let idle: TimeInterval

    init(idle: TimeInterval) { self.idle = idle }

    /// A session up and welcomed (dialled now when there's none).
    func ensure(_ dial: Dial) -> NetSession? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let session, case .established = session.state { return session }
        session = nil
        guard let (opened, early) = Self.connect(dial) else { return nil }
        // Its link's welcome follows the handshake (it may have come in the handshake's last read).
        for payload in early { take(payload) }
        let until = Date().addingTimeInterval(5)
        while caps == nil, Date() < until {
            guard case .established = opened.state else { return nil }
            for message in opened.pump() { take(message.payload) }
            if caps == nil { _ = Sockets.wait(opened.descriptor, write: opened.wantsWrite, timeoutMs: 100) }
        }
        session = opened
        return opened
    }

    /// Sends one command, waits for its result (by id): its raw bytes, or nil.
    func request(id: String, _ payload: Data, dial: Dial, within: TimeInterval) -> Data? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session = ensure(dial) else { return nil }
        do { try session.send(payload, queue: .interactive, stream: 1) } catch { return drop() }
        let until = Date().addingTimeInterval(within)
        while Date() < until {
            for message in session.pump() {
                if let answer = take(message.payload, waiting: id) {
                    used = Date()
                    closeWhenIdle()
                    return answer
                }
            }
            guard case .established = session.state else { return drop() }
            _ = Sockets.wait(session.descriptor, write: session.wantsWrite, timeoutMs: 250)
        }
        return drop()
    }

    private func drop() -> Data? {
        session?.close("quit")
        session = nil
        return nil
    }

    /// A message: a welcome's caps are kept; a result with `waiting`'s id is the answer.
    @discardableResult
    private func take(_ payload: Data, waiting: String? = nil) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any], let type = object["t"] as? String else { return nil }
        if type == "welcome" { caps = object["caps"] as? [String] ?? [] }
        if type == "result" || type == UsageWire.page, let waiting, object["id"] as? String == waiting { return payload }
        return nil
    }

    private func closeWhenIdle() {
        let idle = self.idle
        queue.asyncAfter(deadline: .now() + idle) { [weak self] in
            guard let self, Date().timeIntervalSince(self.used) >= idle - 0.5 else { return }
            _ = self.drop()
        }
    }

    /// Dials the peer and runs the handshake to its end: the session, established, and what came
    /// with its last read; or nil.
    static func connect(_ dial: Dial) -> (NetSession, [Data])? {
        guard let status = try? dial.tailnet.status(), let own = dial.selfNode.owner, let node = MacPeers.node(dial.record, in: status), node.online,
              let address = node.tailscaleIPs.first, let who = try? dial.tailnet.whois(address),
              who.userId == own, who.node.tags.isEmpty
        else { return nil }
        var setup = NetSession.Client(
            local: NetLocal(device: dial.device, kind: .mac, nodeKey: dial.selfNode.publicKey, signer: dial.signer), route: .tailnet,
            peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId, tags: who.node.tags), book: dial.book, server: dial.record.id, service: "link")
        setup.ownUser = own
        guard let fd = try? dial.tailnet.dial(address, port: NetListener.macPort) else { return nil }
        let session = NetSession(fd: fd, role: .client(setup))
        var early: [Data] = []
        guard case .established = handshake(session, early: &early) else { return nil }
        return (session, early)
    }

    /// Runs a handshake to its end; what arrived with it (the link's welcome, read in the same
    /// pass) is kept in `early`, never dropped.
    static func handshake(_ session: NetSession, early: inout [Data]) -> NetSession.State {
        while true {
            early += session.pump().map(\.payload)
            guard case .handshaking = session.state else { return session.state }
            _ = Sockets.wait(session.descriptor, write: session.wantsWrite, timeoutMs: 250)
        }
    }
}

/// While this Mac's Add device window is open, it knocks at the owner's other Macs on the
/// tailnet (same user, untagged, macOS, online, not paired yet) with an enroll of kind mac. A Mac
/// whose own window is open shows its Allow card; Allowed, this Mac pins that Mac from its
/// welcome (the identity its challenge named and the welcome proved), and the pair holds both
/// ways. A Mac that said no isn't asked again until the window opens again.
@MainActor
package final class MacPairing {
    private unowned let net: MacNet
    private var tick: (() -> Void)?
    /// Node keys being asked now, and those that said no in this window.
    private var asking: Set<String> = []
    private var declined: Set<String> = []
    private let queue = DispatchQueue(label: "dev.kore.mac-pairing", attributes: .concurrent)
    /// Between knocks while the window is open.
    package static var every: TimeInterval = 3
    /// Pairs made (tests).
    package var paired: (DeviceRecord) -> Void = { _ in }

    init(net: MacNet) { self.net = net }

    func start() {
        stop()
        declined = []
        knock()
    }

    func stop() {
        tick?()
        tick = nil
    }

    enum Outcome: Sendable {
        case paired(DeviceRecord)
        /// Its owner said no, or let the card go.
        case declined
        /// Not listening, not waiting, or unreachable: asked again at the next knock.
        case notNow
    }

    /// One knock at every candidate not being asked already; the next one is scheduled.
    package func knock() {
        tick = nil
        guard net.addOpen else { return }
        tick = net.schedule(Self.every) { [weak self] in self?.knock() }
        guard let tailnet = net.host.tailnet, let me = net.identity, let selfNode = net.selfNode, let own = selfNode.owner else { return }
        let known = Set(net.pairedMacs().flatMap(\.nodeKeys))
        let skip = known.union(asking).union(declined).union([selfNode.publicKey])
        let book = net.host.book
        let name = net.host.macName
        let window = MacNet.holdFor + 5
        queue.async { [weak self] in
            guard let status = try? tailnet.status() else { return }
            let candidates = status.peers.filter { $0.online && $0.os == "macOS" && $0.userID == own && $0.tags.isEmpty && !$0.shared && !skip.contains($0.publicKey) }
            for peer in candidates {
                guard let address = peer.tailscaleIPs.first else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.asking.insert(peer.publicKey) } }
                self?.queue.async {
                    let outcome = MacPairing.enroll(
                        tailnet: tailnet, address: address, nodeKey: peer.publicKey, device: me.device, signer: me.signer, selfNode: selfNode, book: book,
                        name: name, window: window)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.settle(peer.publicKey, outcome) } }
                }
            }
        }
    }

    private func settle(_ nodeKey: String, _ outcome: Outcome) {
        asking.remove(nodeKey)
        switch outcome {
        case .paired(let record):
            do {
                try net.host.book.update { devices in
                    if let held = devices.first(where: { $0.id == record.id }) {
                        guard held.identityKey == record.identityKey else { throw TrustError.refused("identity key differs") }
                        return
                    }
                    devices.append(record)
                }
            } catch {
                NetAudit.line("pair", ["device": record.id.uuidString.lowercased(), "outcome": "book"])
                return
            }
            net.paired(with: record)
            paired(record)
            MacPeers.shared.refresh()
        case .declined:
            declined.insert(nodeKey)
        case .notNow:
            break
        }
    }

    /// One knock: an enroll of kind mac, first contact. Blocks (a dial, a handshake that waits
    /// for the other's card): off the main actor.
    nonisolated static func enroll(
        tailnet: any Tailnet, address: String, nodeKey: String, device: UUID, signer: any IdentitySigner, selfNode: TailnetStatus.SelfNode,
        book: DeviceBook, name: String, window: TimeInterval
    ) -> Outcome {
        guard let own = selfNode.owner, let who = try? tailnet.whois(address), who.node.key == nodeKey, who.userId == own, who.node.tags.isEmpty else {
            return .notNow
        }
        var setup = NetSession.Client(
            local: NetLocal(device: device, kind: .mac, nodeKey: selfNode.publicKey, signer: signer), route: .tailnet,
            peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId, tags: who.node.tags), book: book, server: UUID(), service: "link")
        setup.ownUser = own
        setup.pinFirst = true
        setup.window = window
        setup.enroll = NetControl.Enroll(name: name, kind: .mac, identityKey: signer.publicKey)
        guard let fd = try? tailnet.dial(address, port: NetListener.macPort) else { return .notNow }
        let session = NetSession(fd: fd, role: .client(setup))
        var early: [Data] = []
        switch PeerLink.handshake(session, early: &early) {
        case .established:
            defer { session.close("quit") }
            guard let learned = session.learned else { return .notNow }
            let said = session.directory?.first { $0.id == learned.device && $0.identityKey == learned.identityKey }
            let record = DeviceRecord(
                id: learned.device, name: MacNet.clean(said?.name ?? MacNet.shortName(who.node.name)), kind: .mac, abilities: .run, owner: true,
                identityKey: learned.identityKey, nodeKeys: [who.node.key], userId: who.userId, fqdn: who.node.name, issuedBy: device, added: Date(),
                lastSeen: Date())
            guard (try? record.validate()) != nil else { return .notNow }
            return .paired(record)
        case .closed(let reason):
            return reason == "bye " + NetControl.Reason.refused || reason == "bye " + NetControl.Reason.timeout ? .declined : .notNow
        case .handshaking:
            return .notNow
        }
    }
}

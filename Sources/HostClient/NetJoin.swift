import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Observation
import Tailnet

/// KoreNet on this Mac as the Devices popup and the Welcome use it (Kore: `KoreNetSwitch`;
/// storylines and tests: their own).
@MainActor
package protocol DevicesNet: AnyObject {
    var facts: NetFacts { get }
    /// Kore's own tailnet's sign-in page while it isn't signed in.
    var authURL: String? { get }
    func set(_ on: Bool)
    /// The IPN bus is held while something visible holds it (the Devices popup, the Welcome).
    func hold(_ key: String, _ held: Bool)
    /// One status read, off the main actor; the popup draws from the cache meanwhile.
    func readStatus()
}

extension KoreNetSwitch: DevicesNet {
    package var facts: NetFacts { NetFacts(on: on, state: state, status: status) }
    package var authURL: String? { status?.authURL }
}

// MARK: SSH box → KoreNet (frame D2)

/// The join sheet of an SSH box ("mybox joins KoreNet"): its rows tick in order, and it ends
/// done (closing itself), relayed (waiting for Done), or on what the owner has to answer. Pure
/// state: a runner (`BoxNetJoinRun` over the box's link, or a test's) tells it what happened.
@MainActor @Observable
package final class BoxNetJoin {
    package enum Mark: Equatable, Sendable {
        case done, working, attention, skipped
    }

    package struct Row: Equatable, Sendable {
        package var title: String
        package var detail: String?
        package var mark: Mark
        /// The detail says "it works, slower" ("relayed").
        package var warns = false

        package init(_ title: String, detail: String? = nil, mark: Mark, warns: Bool = false) {
            self.title = title
            self.detail = detail
            self.mark = mark
            self.warns = warns
        }
    }

    package enum Ending: Equatable, Sendable {
        /// Under way: Cancel.
        case working
        /// The box's Tailscale is down and starting it needs sudo: Copy sudo line, Use Kore's tailnet.
        case needsSudo
        /// Kore's tailnet on the box waits for a sign-in, opened on this Mac: Use an auth key…, Sign in.
        case signIn
        /// "Use an auth key…": the field.
        case authKey
        case signInCancelled
        /// Done, over the relays: the one end that waits for Done.
        case relayed
        /// Done: the sheet closes itself a second later.
        case done
        /// The box can't reach Tailscale (or the join timed out): it stays on SSH.
        case unreachable
        case failed(String)

        /// Over: nothing more happens by itself.
        package var over: Bool {
            switch self {
            case .done, .relayed, .unreachable, .failed, .signInCancelled: true
            default: false
            }
        }
    }

    package let key: String
    package let name: String
    package private(set) var rows: [Row] = []
    package private(set) var ending = Ending.working
    /// The sheet's one sentence, under the rows.
    package private(set) var note: String?
    /// The box runs Kore's own tailnet (no root).
    package private(set) var sidecar = false
    private var enrolled = false
    private var onTailnet: Bool?
    private var sshAfterNet = 0

    /// Why the last join of each box ended unreachable: its Welcome line says so after.
    package static var unreachable: Set<String> = []

    package init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    /// The command that starts the box's own Tailscale, for "Copy sudo line".
    package static let sudoLine = "sudo tailscale up"

    // What happened, in order.

    package func started(version: String?) {
        rows = [Row("kore-host" + (version.map { " " + $0 } ?? ""), detail: "over SSH", mark: .done), Row("Tailscale on \(name)…", mark: .working)]
        ending = .working
        note = nil
    }

    package func failed(_ why: String) {
        ending = .failed(why)
        note = why
        if let i = rows.firstIndex(where: { $0.mark == .working }) { rows[i].mark = .attention }
    }

    /// The box said how it's on KoreNet now: its node key while its Tailscale runs.
    package func node(on: Bool, nodeKey: String?, sidecar: Bool = false) {
        guard !ending.over else { return }
        self.sidecar = sidecar
        let tailscale = sidecar ? Row("Kore's tailnet on \(name)", detail: "no root", mark: .done) : Row("Tailscale on \(name)", detail: "running", mark: .done)
        guard on, nodeKey != nil else {
            rows = Array(rows.prefix(1)) + [Row("Tailscale on \(name) is stopped", mark: .attention)]
            note = "Starting it needs sudo. Kore's tailnet can run instead, without root."
            ending = .needsSudo
            return
        }
        rows = Array(rows.prefix(1)) + [tailscale, Row("Reaching \(name) on the tailnet…", mark: .working), Row("Allowed by SSH", mark: enrolled ? .done : .skipped)]
        note = nil
        ending = .working
        settle()
    }

    /// Kore's tailnet on the box waits for a sign-in.
    package func needsSignIn() {
        sidecar = true
        rows = Array(rows.prefix(1)) + [Row("Kore's tailnet on \(name)", detail: "no root", mark: .done), Row("Sign in for \(name)", mark: .attention)]
        note = "The sign-in page opens here, on this Mac."
        ending = .signIn
    }

    package func askAuthKey() { if ending == .signIn { ending = .authKey } }

    package func signInCancelled() {
        rows = Array(rows.prefix(2)) + [Row("Sign-in was cancelled", mark: .attention)]
        note = nil
        ending = .signInCancelled
    }

    /// The box's SSH link vouched for this Mac (`attach --proto 2`).
    package func allowedBySSH() {
        enrolled = true
        if let i = rows.firstIndex(where: { $0.title == "Allowed by SSH" }) { rows[i].mark = .done }
        settle()
    }

    /// The link came up: over the tailnet (direct or relayed), or over SSH again.
    package func linked(net: Bool, relayed: Bool = false) {
        guard !ending.over, ending == .working else { return }
        if net {
            onTailnet = relayed
            if let i = rows.firstIndex(where: { $0.title.hasPrefix("Reaching ") || $0.title == "On the tailnet" }) {
                rows[i] = Row("On the tailnet", detail: relayed ? "relayed" : "direct", mark: .done, warns: relayed)
            }
            settle()
        } else if rows.contains(where: { $0.title.hasPrefix("Reaching ") }) {
            // Its tailnet route failed and the link fell back to SSH (`NetPaths`): once may be a
            // blip while the box's node settles; twice, it can't reach Tailscale.
            sshAfterNet += 1
            if sshAfterNet >= 2 { unreachableNow() }
        }
    }

    package func unreachableNow() {
        if let i = rows.firstIndex(where: { $0.title.hasPrefix("Reaching ") }) { rows[i] = Row("Can't reach Tailscale", detail: "stays on SSH", mark: .attention) }
        rows.removeAll { $0.title == "Allowed by SSH" && $0.mark != .done }
        note = "\(name) stays on SSH."
        ending = .unreachable
        Self.unreachable.insert(key)
    }

    private func settle() {
        guard enrolled, let relayed = onTailnet, ending == .working else { return }
        Self.unreachable.remove(key)
        if relayed {
            note = "UDP is blocked on \(name)'s network, so traffic goes through Tailscale's relays. Chats are fine, and syncs run slower."
            ending = .relayed
        } else {
            note = "SSH stays as a backup."
            ending = .done
        }
    }
}

/// What a join sheet asks of the box and this Mac (Kore: `BoxNetJoinRun`; storylines: a script).
@MainActor
package protocol BoxNetJoinRunner: AnyObject {
    func start(_ join: BoxNetJoin)
    func cancel(_ join: BoxNetJoin)
    /// "Use Kore's tailnet": the box runs `kore-tailnet` as its user.
    func useKoreTailnet(_ join: BoxNetJoin)
    /// "Sign in ↗": the box's sign-in page, on this Mac.
    func signIn(_ join: BoxNetJoin)
    func authKey(_ join: BoxNetJoin, _ key: String)
    /// "Stay on SSH": Kore's tailnet on the box stops.
    func stayOnSSH(_ join: BoxNetJoin)
    /// Whether the box can run Kore's tailnet without root (its kore-host says so).
    func offersKoreTailnet(_ join: BoxNetJoin) -> Bool
}

/// The join over a box's live SSH link (phase 18 step 4's upgrade): this Mac's KoreNet on,
/// `net.set{on}` to the box, its link dialled again so its `net.node` says how it's on the
/// tailnet; KoreNet's switch then enrolls this Mac there over SSH (`attach --proto 2`, so no Allow
/// card) and moves the link to the tailnet once the box's node key is known. Nothing polls: every
/// step waits on what the link or the tailnet says.
@MainActor
package final class BoxNetJoinRun: BoxNetJoinRunner {
    private let connection: HostConnection
    private let net: KoreNetSwitch
    private let directory: NodeDirectory
    private var watching = false
    private var cancelled = false

    package init(connection: HostConnection, net: KoreNetSwitch, directory: NodeDirectory = .shared) {
        self.connection = connection
        self.net = net
        self.directory = directory
    }

    package func start(_ join: BoxNetJoin) {
        cancelled = false
        join.started(version: connection.hostVersion)
        guard connection.boxMinor >= 12, connection.control == .full else {
            return join.failed("kore-host on \(join.name) needs an update first.")
        }
        connection.retain()
        net.hold("join." + join.key, true)
        Task {
            if !net.on { net.set(true) }
            await Observed.until { self.net.state != .choosing }
            guard !cancelled else { return }
            guard net.state.reaches else { return join.failed("Tailscale is off on this Mac.") }
            guard let answer = await connection.setBoxNet(true), answer.ok else {
                return join.failed("\(join.name) didn't turn KoreNet on.")
            }
            watch(join)
            connection.relink("korenet on")
        }
    }

    private func watch(_ join: BoxNetJoin) {
        guard !watching else { return }
        watching = true
        let key = connection.alias
        net.watchNode(key) { [weak self, weak join] node in
            guard let self, let join, !self.cancelled else { return }
            join.node(on: node.on, nodeKey: node.nodeKey)
            if self.directory.entry(forKey: self.connection.alias)?.enrolled == true { join.allowedBySSH() }
        }
        connection.onLink("netjoin") { [weak self, weak join] up in
            guard let self, let join, up, !self.cancelled else { return }
            if self.directory.entry(forKey: self.connection.alias)?.enrolled == true { join.allowedBySSH() }
            let relayed = self.relayed()
            join.linked(net: self.connection.route == .net, relayed: relayed)
            if join.ending.over { self.finish(join) }
        }
        net.watchEnroll(key) { [weak self, weak join] ok in
            guard let self, let join, !self.cancelled, ok else { return }
            join.allowedBySSH()
            if join.ending.over { self.finish(join) }
        }
        // Waiting on sudo: the box's node coming online on the tailnet is the cue to look again.
        followTailnet(join)
    }

    private func followTailnet(_ join: BoxNetJoin) {
        withObservationTracking { _ = net.status } onChange: { [weak self, weak join] in
            Task { @MainActor in
                guard let self, let join, !self.cancelled, !join.ending.over else { return }
                if join.ending == .needsSudo, self.peerOnline(named: join.name) { self.connection.relink("tailscale on the box") }
                self.followTailnet(join)
            }
        }
    }

    private func peerOnline(named name: String) -> Bool {
        net.status?.peers.contains { $0.online && $0.hostName.caseInsensitiveCompare(name) == .orderedSame } ?? false
    }

    private func relayed() -> Bool {
        guard let key = directory.entry(forKey: connection.alias)?.nodeKey else { return false }
        return net.status?.peers.first { $0.publicKey == key }?.relayed ?? false
    }

    private func finish(_ join: BoxNetJoin) {
        guard watching else { return }
        watching = false
        net.watchNode(connection.alias, nil)
        net.watchEnroll(connection.alias, nil)
        connection.onLink("netjoin", nil)
        net.hold("join." + join.key, false)
        connection.release()
    }

    package func cancel(_ join: BoxNetJoin) {
        cancelled = true
        finish(join)
    }

    // Kore's tailnet on a box (no root) needs kore-host's own `kore-tailnet`, which the box
    // doesn't carry yet: the sheet offers it only once the box says it can.
    package func offersKoreTailnet(_ join: BoxNetJoin) -> Bool { connection.caps.contains("net.sidecar") }
    package func useKoreTailnet(_ join: BoxNetJoin) {}
    package func signIn(_ join: BoxNetJoin) {}
    package func authKey(_ join: BoxNetJoin, _ key: String) {}
    package func stayOnSSH(_ join: BoxNetJoin) { cancel(join) }
}

/// Waits, without polling, until `condition` holds: it's checked now and after each change of
/// what it read.
package enum Observed {
    @MainActor
    package static func until(_ condition: @escaping @MainActor () -> Bool) async {
        while !(await holdsOrChanged(condition)) {}
    }

    @MainActor
    private static func holdsOrChanged(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await withCheckedContinuation { wake in
            let gate = Gate(wake)
            let holds = withObservationTracking { condition() } onChange: { Task { @MainActor in gate.open(false) } }
            if holds { gate.open(true) }
        }
    }

    /// One wake, whichever comes first.
    @MainActor
    private final class Gate {
        private var wake: CheckedContinuation<Bool, Never>?
        init(_ wake: CheckedContinuation<Bool, Never>) { self.wake = wake }
        func open(_ holds: Bool) {
            wake?.resume(returning: holds)
            wake = nil
        }
    }
}

// MARK: Boxes on the tailnet (the Welcome "+" list, New box…)

/// A tailnet peer that answered on KoreNet's port.
package struct TailnetBox: Equatable, Sendable {
    package var name: String
    package var address: String
    package var nodeKey: String
    package var login: String
}

extension KoreNetSwitch {
    /// Peers that could be this Mac's boxes: same user, untagged, online, Linux, not known here.
    package nonisolated static func candidates(_ status: TailnetStatus, known: Set<String>) -> [TailnetStatus.Peer] {
        guard let owner = status.selfNode?.owner else { return [] }
        return status.peers.filter {
            $0.online && $0.tags.isEmpty && !$0.shared && $0.userID == owner && $0.os.lowercased() == "linux" && !known.contains($0.publicKey)
                && !$0.tailscaleIPs.isEmpty
        }
    }

    /// Node keys this Mac knows as boxes.
    package var knownNodeKeys: Set<String> { Set(directory.all.values.compactMap(\.nodeKey)) }

    /// The candidates that answer on KoreNet's port, probed once each (a connect, closed at once),
    /// off the main actor: when the Welcome "+" list opens, at no other time.
    package func koreHostPeers(among peers: [TailnetStatus.Peer]? = nil) async -> [TailnetBox] {
        guard let tailnet, let status = status else { return [] }
        let candidates = peers ?? Self.candidates(status, known: knownNodeKeys)
        guard !candidates.isEmpty else { return [] }
        return await Task.detached {
            await withTaskGroup(of: TailnetBox?.self) { group in
                for peer in candidates {
                    group.addTask {
                        guard let address = peer.tailscaleIPs.first, let fd = try? tailnet.dial(address, port: NetListener.port) else { return nil }
                        Sockets.closeFD(fd)
                        let login = (try? tailnet.whois(address))?.user.loginName ?? ""
                        let name = peer.hostName.isEmpty ? address : peer.hostName
                        return TailnetBox(name: name, address: address, nodeKey: peer.publicKey, login: login)
                    }
                }
                var found: [TailnetBox] = []
                for await box in group { if let box { found.append(box) } }
                return found.sorted { $0.name < $1.name }
            }
        }.value
    }
}

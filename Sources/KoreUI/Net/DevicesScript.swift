import Foundation
import HostClient
import Observation
import Tailnet

// Scripted stand-ins for KoreNet's sides (storylines and snapshots): a switch that's on or off
// as told, phones and a knocking phone, tailnet boxes to claim, and a join that goes as its
// script says. No tailnet, no socket, no LocalAPI: nothing here leaves the process.

/// KoreNet's switch as a script sets it.
@MainActor @Observable
package final class ScriptedNet: DevicesNet {
    package var facts: NetFacts
    package var authURL: String?
    @ObservationIgnored package private(set) var held: Set<String> = []
    @ObservationIgnored package private(set) var reads = 0

    package init(on: Bool = false, state: NetState = .off, status: TailnetStatus? = nil, authURL: String? = nil) {
        facts = NetFacts(on: on, state: state, status: status)
        self.authURL = authURL
    }

    package func set(_ on: Bool) {
        facts.on = on
        facts.state = on ? .installed : .off
        facts.status = on ? (facts.status ?? Self.running) : nil
        Devices.shared.changed()
    }

    package func hold(_ key: String, _ held: Bool) {
        if held { self.held.insert(key) } else { self.held.remove(key) }
    }

    package func readStatus() { reads += 1 }

    /// The tailnet changes (Tailscale stopped, signed in, a key expiring).
    package func set(state: NetState, status: TailnetStatus?) {
        facts.state = state
        facts.status = status
        Devices.shared.changed()
    }

    package static let running = TailnetStatus(
        backendState: .running, selfNode: .init(publicKey: "nodekey:mac", tailscaleIPs: ["100.64.0.1"], userID: 7))
}

/// Phones as a script has them, and a phone knocking in the Add device window.
@MainActor
package final class ScriptedPhones: PhoneDevices {
    package var phones: [PhoneFacts] = []
    package var addUntil: Date?
    package var refusals: [DeviceRefusal] = []
    package private(set) var log: [String] = []
    package var addLength: TimeInterval = 600

    package init() {}

    package func openAddWindow() {
        addUntil = Date().addingTimeInterval(addLength)
        log.append("add")
    }

    package func closeAddWindow() {
        guard addUntil != nil else { return }
        addUntil = nil
        log.append("add closed")
    }

    package func rename(_ id: UUID, to name: String) {
        if let i = phones.firstIndex(where: { $0.id == id }) { phones[i].name = name }
        log.append("rename \(name)")
    }

    package func remove(_ id: UUID) {
        phones.removeAll { $0.id == id }
        log.append("remove")
    }

    package func fetchLogs(_ id: UUID, name: String) async -> URL? {
        log.append("logs")
        return nil
    }

    package func setPaused(_ id: UUID, _ paused: Bool) {
        if let i = phones.firstIndex(where: { $0.id == id }) {
            phones[i].paused = paused
            phones[i].connected = !paused
        }
        log.append(paused ? "offline" : "online")
    }

    package func ask(_ pending: PendingRow) {
        log.append("ask \(pending.name)")
        let info = DeviceCardInfo.phone(name: pending.name, node: pending.device.fqdn, address: "100.101.7.22", login: pending.device.login, firstSeen: pending.device.firstSeen)
        DeviceCardPanel.show(info) { [weak self] allow in self?.answered(allow, name: pending.name) }
    }

    /// A phone joins from the Add device window: its card comes up (only while the window is open).
    package func knock(name: String) {
        guard let until = addUntil, Date() < until else { return }
        let info = DeviceCardInfo.phone(name: name, node: name.lowercased().replacingOccurrences(of: " ", with: "-"), address: "100.101.7.22", login: "you@example.com", firstSeen: Date())
        DeviceCardPanel.show(info) { [weak self] allow in self?.answered(allow, name: name) }
    }

    /// It gave up before an answer.
    package func giveUp() { DeviceCardPanel.stopWaiting() }

    private func answered(_ allow: Bool, name: String) {
        log.append(allow ? "allow \(name)" : "deny \(name)")
        guard allow else { return }
        phones.append(PhoneFacts(id: UUID(), name: name, connected: true, presence: nil, lastSeen: Date()))
        Devices.shared.changed()
    }
}

/// Tailnet boxes a script lists, and its claims.
@MainActor
package final class ScriptedClaims: BoxClaims {
    package var listed: [ClaimPeer] = []
    package var refusal: String?
    package var arriving: ClaimPeer?
    package private(set) var allowed: [String] = []
    private var wake: CheckedContinuation<ClaimPeer?, Never>?

    package init() {}

    package func peers() async -> [ClaimPeer] { listed }

    package func newBox() async -> ClaimPeer? {
        if let arriving { return arriving }
        return await withCheckedContinuation { wake = $0 }
    }

    /// The box ran `kore-host join`.
    package func arrive(_ peer: ClaimPeer) {
        arriving = peer
        wake?.resume(returning: peer)
        wake = nil
    }

    package func cancel() {
        wake?.resume(returning: nil)
        wake = nil
    }

    package func claim(_ peer: ClaimPeer) async -> Result<DeviceCardInfo, ClaimRefusal> {
        if let refusal { return .failure(ClaimRefusal(refusal)) }
        return .success(.box(name: peer.name, node: peer.name, address: peer.address, login: peer.login, firstSeen: Date().addingTimeInterval(-40), device: UUID(uuidString: "7F3A91C2-0000-4000-8000-000000000000")))
    }

    package func allow(_ peer: ClaimPeer) async -> String? {
        allowed.append(peer.name)
        return peer.name
    }
}

/// A join that goes as its script says, step by step.
@MainActor
package final class ScriptedJoin: BoxNetJoinRunner {
    package enum Path: Sendable { case usual, relayed, noSudo, signIn, unreachable }
    package var path: Path
    package private(set) var log: [String] = []
    package var offersSidecar = true

    package init(_ path: Path = .usual) { self.path = path }

    package func start(_ join: BoxNetJoin) {
        log.append("start")
        join.started(version: "0.31")
    }

    /// The next thing the box says.
    package func advance(_ join: BoxNetJoin) {
        switch (path, join.ending) {
        case (.noSudo, .working) where join.rows.count == 2:
            join.node(on: true, nodeKey: nil)
        case (.signIn, .working) where join.rows.count == 2:
            join.needsSignIn()
        case (.unreachable, .working) where join.rows.count == 4:
            join.linked(net: false)
            join.linked(net: false)
        case (_, .working) where join.rows.count == 2:
            join.node(on: true, nodeKey: "nodekey:box")
        case (_, .working):
            join.allowedBySSH()
            join.linked(net: true, relayed: path == .relayed)
        default:
            break
        }
    }

    package func cancel(_ join: BoxNetJoin) { log.append("cancel") }
    package func useKoreTailnet(_ join: BoxNetJoin) {
        log.append("kore tailnet")
        join.needsSignIn()
    }
    package func signIn(_ join: BoxNetJoin) {
        log.append("sign in")
        join.node(on: true, nodeKey: "nodekey:box", sidecar: true)
    }
    package func authKey(_ join: BoxNetJoin, _ key: String) {
        log.append("auth key")
        join.node(on: true, nodeKey: "nodekey:box", sidecar: true)
    }
    package func stayOnSSH(_ join: BoxNetJoin) { log.append("stay on ssh") }
    package func offersKoreTailnet(_ join: BoxNetJoin) -> Bool { offersSidecar }
}

/// A box's SSH → KoreNet upgrade as its `kore-host upgrade` report says: read by the same
/// `BoxNetJoin.outcome` the real run uses; on, its link moves to the tailnet at once.
@MainActor
package final class ScriptedUpgrade: BoxNetJoinRunner {
    package let report: String
    package let macAccount: String?
    /// The link moved (the box list shows it on the tailnet).
    package var linked: (@MainActor () -> Void)?

    package init(report: String, macAccount: String?, linked: (@MainActor () -> Void)? = nil) {
        self.report = report
        self.macAccount = macAccount
        self.linked = linked
    }

    package func start(_ join: BoxNetJoin) {
        join.checking()
        guard let parsed = BoxUpgradeReport.parse(report) else { return join.failed("\(join.name) didn't answer like kore-host") }
        join.started(version: parsed.version)
        let outcome = BoxNetJoin.outcome(parsed, name: join.name, macAccount: macAccount)
        join.take(outcome, report: parsed)
        guard outcome == .link else { return }
        join.node(on: true, nodeKey: parsed["node"] ?? "nodekey:" + join.key, sidecar: parsed.kore)
        join.allowedBySSH()
        join.linked(net: true)
        linked?()
    }

    package func cancel(_ join: BoxNetJoin) {}
    package func useKoreTailnet(_ join: BoxNetJoin) {}
    package func signIn(_ join: BoxNetJoin) {}
    package func authKey(_ join: BoxNetJoin, _ key: String) {}
    package func stayOnSSH(_ join: BoxNetJoin) {}
    package func offersKoreTailnet(_ join: BoxNetJoin) -> Bool { false }
}

/// The box list as a script has it (Devices' "Add a box", Use SSH…): SSH config hosts, boxes
/// listed, each answering and setting up a step at a time as told. No ssh runs.
@MainActor @Observable
package final class ScriptedBoxes: BoxAdding {
    package var hosts: [String]
    package private(set) var boxes: [BoxList.Box] = []
    @ObservationIgnored package private(set) var log: [String] = []
    /// Set up's steps, as the box list says them.
    @ObservationIgnored package var steps: [String]
    /// The boxes' upgrades, for their rows' lines (storylines: their own).
    @ObservationIgnored package var upgrades: BoxUpgrades?
    /// Boxes whose link moved to the tailnet, with the tailnet they said.
    package private(set) var onNet: [String: String] = [:]

    package init(hosts: [String] = ["mybox", "gpu-box", "pi"], steps: [String]? = nil) {
        self.hosts = hosts
        self.steps = steps ?? [
            "Checking mybox…", "Getting kore-host for Linux · x86_64…",
            BoxHostBuild.stepLine("Building kore-host for Linux x86_64", hint: BoxHostBuild.firstBuildHint), "Copying kore-host to mybox…",
        ]
    }

    package func suggestions(_ typed: String) -> [String] {
        let shown = Set(boxes.map(\.alias))
        let typed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return hosts.filter { !shown.contains($0) && (typed.isEmpty || $0.lowercased().hasPrefix(typed)) }
    }

    package func addBox(_ alias: String) {
        guard let alias = BoxList.alias(alias), !boxes.contains(where: { $0.alias == alias }) else { return }
        var box = BoxList.Box(alias: alias)
        box.status = .probing
        boxes.append(box)
        log.append(["add", alias].joined(separator: " "))
        Devices.shared.changed()
    }

    package func note(_ alias: String) -> BoxList.Note? { boxes.first { $0.alias == alias }?.note }

    package func act(_ action: BoxFix, on alias: String) async {
        log.append([action.title, alias].joined(separator: " "))
        guard action == .setUp || action == .setUpAnyway, let first = steps.first else { return }
        update(alias) { $0.status = .working(first) }
    }

    /// The box answers its first probe: SSH works, kore-host isn't there.
    package func answer(_ alias: String) { update(alias) { $0.status = .notSetUp } }

    /// The set-up's next step, and after the last, the box ready.
    package func advance(_ alias: String) {
        guard case .working(let now)? = boxes.first(where: { $0.alias == alias })?.status else { return }
        if let at = steps.firstIndex(of: now), at + 1 < steps.count {
            update(alias) { $0.status = .working(self.steps[at + 1]) }
        } else {
            update(alias) {
                $0.status = .ready
                $0.fresh = true
            }
        }
    }

    /// The box's link moved to the tailnet (`tailnet`: what the box said it's on).
    package func joinNet(_ alias: String, tailnet: String) {
        onNet[alias] = tailnet
        Devices.shared.changed()
    }

    /// Devices' rows for the boxes listed.
    package func facts() -> [BoxFacts] {
        boxes.map { box in
            var facts = BoxFacts(key: box.alias, name: box.alias)
            facts.listed = box.status
            facts.online = box.status == .ready
            facts.route = facts.online ? .ssh(alias: box.alias, grant: "mac") : nil
            if let tailnet = onNet[box.alias] {
                facts.route = .net
                var entry = NodeDirectory.Entry(device: UUID(), name: box.alias, ssh: box.alias, nodeKey: "nodekey:" + box.alias, identityKey: Data([1]), enrolled: true)
                entry.tailnet = tailnet
                facts.entry = entry
            }
            facts.upgrade = upgrades?.facts(box.alias)
            return facts
        }
    }

    private func update(_ alias: String, _ change: (inout BoxList.Box) -> Void) {
        guard let i = boxes.firstIndex(where: { $0.alias == alias }) else { return }
        change(&boxes[i])
        Devices.shared.changed()
    }
}

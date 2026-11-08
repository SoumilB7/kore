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

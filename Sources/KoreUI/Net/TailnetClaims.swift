import Foundation
import HostClient

/// Kore's claims of tailnet boxes. Finding them is real: same-user, untagged, online Linux peers
/// that answer on KoreNet's port, probed when the Welcome "+" list opens, and New box… looking
/// again each time the tailnet says something while it's open. Claiming one needs a session that
/// learns an unknown box's identity from its challenge (the box side is in kore-host's
/// `claim`); until this Mac's side has it, a claim says so and points at SSH.
@MainActor
final class TailnetClaims: BoxClaims {
    private var waiting: Task<Void, Never>?
    private var wake: CheckedContinuation<ClaimPeer?, Never>?

    private var net: KoreNetSwitch? { KoreNetSwitch.shared }

    func peers() async -> [ClaimPeer] {
        guard let net, net.state.reaches else { return [] }
        return await net.koreHostPeers().map(Self.peer)
    }

    func newBox() async -> ClaimPeer? {
        cancel()
        guard let net, net.state.reaches else { return nil }
        net.hold("newbox", true)
        defer { net.hold("newbox", false) }
        let before = Set(net.status.map { KoreNetSwitch.candidates($0, known: net.knownNodeKeys) }?.map(\.publicKey) ?? [])
        return await withCheckedContinuation { wake in
            self.wake = wake
            waiting = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await Observed.until { net.status != nil }
                    let fresh = net.status.map { KoreNetSwitch.candidates($0, known: net.knownNodeKeys) }?.filter { !before.contains($0.publicKey) } ?? []
                    if !fresh.isEmpty, let found = await net.koreHostPeers(among: fresh).first {
                        self?.answer(Self.peer(found))
                        return
                    }
                    // Wait for the tailnet to say something, then read it whole.
                    let seen = net.status
                    await Observed.until { net.status != seen || Task.isCancelled }
                    net.readStatus()
                }
            }
        }
    }

    private func answer(_ peer: ClaimPeer?) {
        wake?.resume(returning: peer)
        wake = nil
    }

    func cancel() {
        waiting?.cancel()
        waiting = nil
        answer(nil)
    }

    func claim(_ peer: ClaimPeer) async -> Result<DeviceCardInfo, ClaimRefusal> {
        .failure(ClaimRefusal("can't be claimed from here yet · use SSH"))
    }

    func allow(_ peer: ClaimPeer) async -> String? { nil }

    private static func peer(_ box: TailnetBox) -> ClaimPeer {
        ClaimPeer(name: box.name, address: box.address, nodeKey: box.nodeKey, login: box.login)
    }
}

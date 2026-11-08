import Foundation
import HostClient

/// Kore's claims of tailnet boxes. Finding them: same-user, untagged, online Linux peers that
/// answer on KoreNet's port, probed when the Welcome "+" list opens, and New box… looking again
/// each time the tailnet says something while it's open. Claiming one (`NetClaim`): a first hello
/// learns the box's device and identity key from its challenge and makes this Mac its claimant
/// (only within 10 minutes of `kore-host join`, same Tailscale user: the box decides); the card
/// shows its device code; Allow pins the box and claims it.
@MainActor
final class TailnetClaims: BoxClaims {
    private var waiting: Task<Void, Never>?
    private var wake: CheckedContinuation<ClaimPeer?, Never>?
    /// What each box's challenge named, by node key, until its card is answered.
    private var learned: [String: BoxClaim] = [:]

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
        guard let mac = net?.claimMac() else { return .failure(ClaimRefusal("Turn KoreNet on first")) }
        let (nodeKey, name) = (peer.nodeKey, peer.name)
        let result = await Task.detached { () -> Result<BoxClaim, ClaimFailure> in
            do {
                return NetClaim.learn(try mac(), nodeKey: nodeKey, name: name)
            } catch {
                return .failure(.unreachable("\(error)"))
            }
        }.value
        switch result {
        case .success(let claim):
            learned[peer.nodeKey] = claim
            return .success(.box(name: peer.name, node: peer.name, address: claim.address, login: peer.login, firstSeen: Date(), device: claim.device))
        case .failure(let why):
            HostLog.note("korenet", "claim", "\(peer.name): \(why)")
            return .failure(ClaimRefusal(why.line))
        }
    }

    func allow(_ peer: ClaimPeer) async -> String? {
        guard let claim = learned.removeValue(forKey: peer.nodeKey), let net, let mac = net.claimMac() else { return nil }
        let result = await Task.detached { () -> Result<Void, ClaimFailure> in
            do {
                return NetClaim.finish(try mac(), claim)
            } catch {
                return .failure(.unreachable("\(error)"))
            }
        }.value
        guard case .success = result else {
            HostLog.note("korenet", "claim", "\(peer.name): \(result)")
            return nil
        }
        net.claimed(claim)
        return claim.id.raw
    }

    private static func peer(_ box: TailnetBox) -> ClaimPeer {
        ClaimPeer(name: box.name, address: box.address, nodeKey: box.nodeKey, login: box.login)
    }
}

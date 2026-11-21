import Foundation
import KoreNet
import KoreTrust
import Tailnet

// Claiming a box over the tailnet (phase 18 §1 "Claim a new box", G15): a box that ran
// `kore-host join` takes the first Mac of its own Tailscale user within 10 minutes as its
// claimant, and that Mac's owner's Allow makes it the box's owner. Two dials:
//   1. learn: a hello with `enroll{kind: mac}` to a box this Mac has no record of. The box's
//      challenge names its device and identity key; the box answers `bye claim` (this Mac is its
//      claimant, the card may show) or `bye unknown` (its window is closed: run join again).
//   2. finish, after Allow on the claim card: the box's record is pinned in this Mac's book (the
//      key the challenge named, the node key from this Mac's own status and WhoIs), then a hello
//      with `enroll.claim`; the box's welcome proves that key and records this Mac as its owner.

/// A box being claimed: what its challenge named, and Tailscale's word for its node.
package struct BoxClaim: Equatable, Sendable {
    package var device: UUID
    package var identityKey: Data
    package var nodeKey: String
    package var userId: Int64?
    package var name: String
    package var fqdn: String
    package var address: String

    package var id: NodeID { NodeID(device.uuidString.lowercased()) }
}

/// Why a claim stopped, as the "+" list's row says it.
package enum ClaimFailure: Error, Equatable, Sendable {
    /// The box isn't waiting for a Mac: `kore-host join` was more than 10 minutes ago (or never).
    case notWaiting
    /// Another user's node, or not the node the list showed.
    case notYours
    /// It didn't answer, or the session broke.
    case unreachable(String)

    package var line: String {
        switch self {
        case .notWaiting: "waiting · run kore-host join again"
        case .notYours: "isn't on your account"
        case .unreachable: "didn't answer · try again"
        }
    }
}

package enum NetClaim {
    /// What a claim reads of this Mac: its tailnet, identity, book and name.
    package struct Mac: @unchecked Sendable {
        package var tailnet: any Tailnet
        package var device: UUID
        package var signer: any IdentitySigner
        package var book: DeviceBook
        package var name: String

        package init(tailnet: any Tailnet, device: UUID, signer: any IdentitySigner, book: DeviceBook, name: String) {
            self.tailnet = tailnet
            self.device = device
            self.signer = signer
            self.book = book
            self.name = name
        }
    }

    /// Dial 1: the box's device and identity key, when it takes this Mac as its claimant. Blocks
    /// (LocalAPI, a dial, a handshake of at most `NetSession.clientWindow`): call it off the main
    /// actor.
    package static func learn(_ mac: Mac, nodeKey: String, name: String) -> Result<BoxClaim, ClaimFailure> {
        let facts: Facts
        switch Self.facts(mac, nodeKey: nodeKey) {
        case .success(let found): facts = found
        case .failure(let why): return .failure(why)
        }
        var setup = facts.setup(mac, server: UUID())
        setup.learn = true
        setup.enroll = NetControl.Enroll(name: mac.name, kind: .mac, identityKey: mac.signer.publicKey)
        let session: NetSession
        do {
            session = NetSession(fd: try mac.tailnet.dial(facts.address, port: NetListener.port), role: .client(setup))
        } catch {
            return .failure(.unreachable("\(error)"))
        }
        let end = handshake(session)
        guard case .closed(let reason) = end else {
            session.close(NetControl.Reason.refused)
            return .failure(.unreachable("welcomed while learning"))
        }
        switch reason {
        case "bye " + NetControl.Reason.claim:
            guard let learned = session.learned else { return .failure(.unreachable("no identity key")) }
            return .success(BoxClaim(
                device: learned.device, identityKey: learned.identityKey, nodeKey: facts.who.node.key, userId: facts.who.userId, name: name,
                fqdn: facts.who.node.name, address: facts.address))
        case "bye " + NetControl.Reason.unknown:
            return .failure(.notWaiting)
        default:
            return .failure(.unreachable(reason))
        }
    }

    /// Dial 2, after Allow: the box pinned, then claimed. A claim that doesn't take leaves the
    /// book as it was.
    package static func finish(_ mac: Mac, _ claim: BoxClaim, now: Date = Date()) -> Result<Void, ClaimFailure> {
        let facts: Facts
        switch Self.facts(mac, nodeKey: claim.nodeKey) {
        case .success(let found): facts = found
        case .failure(let why): return .failure(why)
        }
        let record = DeviceRecord(
            id: claim.device, name: claim.name, kind: .box, abilities: [.read, .ask, .run], identityKey: claim.identityKey, nodeKeys: [claim.nodeKey],
            userId: facts.who.userId, tags: facts.who.node.tags, fqdn: facts.who.node.name, added: now)
        var pinned = false
        do {
            try mac.book.update { devices in
                if let held = devices.first(where: { $0.id == claim.device }) {
                    guard held.identityKey == claim.identityKey else { throw TrustError.refused("identity key differs") }
                    return
                }
                devices.append(record)
                pinned = true
            }
        } catch {
            return .failure(.unreachable("\(error)"))
        }
        let unpin = {
            if pinned { _ = try? mac.book.update { $0.removeAll { $0.id == claim.device } } }
        }
        var setup = facts.setup(mac, server: claim.device)
        setup.enroll = NetControl.Enroll(name: mac.name, kind: .mac, identityKey: mac.signer.publicKey, claim: true)
        let session: NetSession
        do {
            session = NetSession(fd: try mac.tailnet.dial(facts.address, port: NetListener.port), role: .client(setup))
        } catch {
            unpin()
            return .failure(.unreachable("\(error)"))
        }
        switch handshake(session) {
        case .established:
            session.close("quit")
            return .success(())
        case .closed(let reason):
            unpin()
            return .failure(reason == "bye " + NetControl.Reason.unknown ? .notWaiting : .unreachable(reason))
        case .handshaking:
            unpin()
            return .failure(.unreachable("handshake"))
        }
    }

    /// The box as this Mac's own status and WhoIs say it: online, of this Mac's user, the node
    /// the list showed. Node keys never come from the box's word.
    struct Facts {
        var me: TailnetStatus.SelfNode
        var who: TailnetWhoIs
        var address: String

        func setup(_ mac: Mac, server: UUID) -> NetSession.Client {
            var setup = NetSession.Client(
                local: NetLocal(device: mac.device, kind: .mac, nodeKey: me.publicKey, signer: mac.signer), route: .tailnet,
                peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId, tags: who.node.tags), book: mac.book, server: server, service: "link")
            setup.ownUser = me.owner
            return setup
        }
    }

    static func facts(_ mac: Mac, nodeKey: String) -> Result<Facts, ClaimFailure> {
        do {
            let status = try mac.tailnet.status()
            guard status.backendState == .running, let me = status.selfNode else { return .failure(.unreachable("Tailscale isn't running")) }
            guard let peer = status.peers.first(where: { $0.publicKey == nodeKey }), peer.online, let address = peer.tailscaleIPs.first else {
                return .failure(.unreachable("offline"))
            }
            let who = try mac.tailnet.whois(address)
            guard who.node.key == nodeKey, let own = me.owner, who.userId == own else { return .failure(.notYours) }
            return .success(Facts(me: me, who: who, address: address))
        } catch {
            return .failure(.unreachable("\(error)"))
        }
    }

    /// Runs a client handshake to its end (a welcome, a `bye`, or the client window's timeout).
    static func handshake(_ session: NetSession) -> NetSession.State {
        while true {
            _ = session.pump()
            guard case .handshaking = session.state else { return session.state }
            _ = Sockets.wait(session.descriptor, write: session.wantsWrite, timeoutMs: 250)
        }
    }
}

extension KoreNetSwitch {
    /// What a claim reads of this Mac, while KoreNet reaches a tailnet; the identity (the
    /// identity file) is read when the returned closure runs, off the main actor.
    package func claimMac() -> (@Sendable () throws -> NetClaim.Mac)? {
        guard state.reaches, let tailnet, let env else { return nil }
        let book = book(env)
        let identities = identities
        return {
            let identity = try identities.get(env)
            return NetClaim.Mac(tailnet: tailnet, device: identity.device, signer: identity.signer, book: book, name: env.macName())
        }
    }

    /// A claimed box: in this Mac's directory, enrolled, reached over the tailnet by its id.
    package func claimed(_ claim: BoxClaim) {
        directory.upsert(
            NodeDirectory.Entry(
                device: claim.device, name: claim.name, ssh: nil, nodeKey: claim.nodeKey, identityKey: claim.identityKey, enrolled: true, rekeyed: true))
        HostLog.note(claim.id.raw, "korenet claim", "owner")
    }
}

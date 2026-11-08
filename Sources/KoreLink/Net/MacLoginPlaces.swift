import Foundation
import HostClient
import KoreCore
import KoreUI
import LinkProtocol

/// The owner's paired Macs as places a login can move to (`LoginMoves`): "Move to MacBook Air"
/// in a login's ⋯, over `MacPeers`' link. One offline is listed dimmed ("isn't reachable"); one
/// that said it doesn't take login moves, "needs a newer Kore". Caps not heard yet don't hold a
/// move back: only a Kore that takes moves can pair at all.
extension MacPeers {
    /// At launch: the Account popup's ⋯ lists the paired Macs, and its opening asks them again.
    package static func installLoginPlaces() {
        LoginMoves.shared.macs = { MacPeers.shared.paired().map { MacPeers.place($0) } }
        LoginMoves.shared.lookAgain = { MacPeers.shared.refresh() }
    }

    /// Why a paired Mac can't take a login now; nil: it can.
    static func unready(_ peer: Peer) -> LoginMove.Failure? {
        guard peer.online else { return .unreachable }
        if peer.capsKnown, !peer.takesLoginMove { return .tooOld }
        return nil
    }

    static func place(_ peer: Peer) -> LoginMoves.Box {
        let id = peer.id
        let host = Foundation.Host.current().localizedName ?? "Mac"
        let send: PeerLogins.Send = { @MainActor kind, args in await MacPeers.shared.command(id, kind, args) }
        let whyNot: @Sendable () async -> LoginMove.Failure? = { @MainActor in
            MacPeers.shared.paired().first { $0.id == id }.map(MacPeers.unready) ?? .unreachable
        }
        return LoginMoves.Box(
            key: LoginMoves.macKey(id), name: peer.name, unready: Self.unready(peer), device: id.uuidString.lowercased(),
            remote: { cli, login, profile, force in PeerLogins(cli: cli, login: login, host: host, profile: profile, force: force, unready: whyNot, send: send) },
            prints: { cli, key in
                let result = await send(.accountFingerprints, ControlArgs(provider: cli, key: key.base64EncodedString()))
                return result.ok ? result.prints ?? [] : nil
            },
            login: { cli, email in await MacPeers.login(cli: cli, email: email, send: send) }, mac: true)
    }

    /// The other Mac's name for its `cli` login with this email: what its fingerprints list says
    /// (under a throwaway key: only the names are read).
    package static func login(cli: String, email: String?, send: PeerLogins.Send) async -> String? {
        guard let email = email?.lowercased(), !email.isEmpty else { return nil }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let result = await send(.accountFingerprints, ControlArgs(provider: cli, key: key.base64EncodedString()))
        return result.prints?.first { $0.email?.lowercased() == email }?.login
    }
}

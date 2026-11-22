import Foundation
import Synchronization
import Tailnet

/// The tailnet nodes a box may be on now, best first (`z-docs/phases/phase-18-korenet/
/// connection-cases.md`): a box has up to two at once (installed Tailscale's, and Kore's own
/// `<host>-kore`), one online at a time, and moves between them whenever Tailscale starts or
/// stops there. Every node key known for it (what it said in `net.node`, what its record in this
/// Mac's book holds after a proof) online first, in the order known; then, when none of those
/// is online, the same user's online nodes named after it (`mybox`, `mybox-kore`, `mybox-1`,
/// `mybox-kore-2`) that no other known device holds. Never a tagged, shared or other user's
/// node. The dial's identity proof decides which really is the box: a wrong one fails its
/// handshake (the box's device id and signature), and a right one's key is appended after it.
package enum BoxNodes {
    package struct Candidate: Equatable, Sendable {
        package var key: String
        package var address: String
        /// Its tailnet name (`mybox-kore`): the reconnect card says which it's trying.
        package var name: String
        /// One of the box's known keys (else found by its name).
        package var known: Bool

        package init(key: String, address: String, name: String, known: Bool) {
            self.key = key
            self.address = address
            self.name = name
            self.known = known
        }
    }

    /// The nodes to dial, best first; empty when none is online.
    /// - keys: the box's known node keys, newest first.
    /// - names: what it goes by (its host name, its SSH alias).
    /// - others: node keys other known devices hold (never taken for this box).
    /// - offline: with nothing online, the newest known node listed offline is tried once anyway
    ///   (a peer's online flag lags its coming up; the dial's connect is bounded at 5 s).
    package static func candidates(keys: [String], names: [String], status: TailnetStatus, others: Set<String> = [], offline: Bool = false) -> [Candidate] {
        let online = status.peers.filter { $0.online && !$0.tailscaleIPs.isEmpty }
        var out: [Candidate] = []
        for key in keys {
            guard let peer = online.first(where: { $0.publicKey == key }), let address = peer.tailscaleIPs.first else { continue }
            out.append(Candidate(key: key, address: address, name: peer.hostName, known: true))
        }
        guard out.isEmpty else { return out }
        let me = status.selfNode?.userID
        let known = Set(keys).union(others)
        for peer in online where me != nil && !known.contains(peer.publicKey) && peer.userID == me && peer.tags.isEmpty && !peer.shared {
            guard named(peer.hostName, after: names), let address = peer.tailscaleIPs.first else { continue }
            out.append(Candidate(key: peer.publicKey, address: address, name: peer.hostName, known: false))
        }
        if out.isEmpty, offline {
            for key in keys {
                guard let peer = status.peers.first(where: { $0.publicKey == key }), let address = peer.tailscaleIPs.first else { continue }
                return [Candidate(key: key, address: address, name: peer.hostName, known: true)]
            }
        }
        return out
    }

    /// Every node to dial at once after a box's `restart` (it may be moving between its nodes,
    /// and the control server reports a node coming online seconds late): each known key's node
    /// the tailnet lists, online or not, then the online ones found by name. The first that takes
    /// the connection wins; the identity proof decides as ever.
    package static func every(keys: [String], names: [String], status: TailnetStatus, others: Set<String> = []) -> [Candidate] {
        var out = candidates(keys: keys, names: names, status: status, others: others)
        for key in keys where !out.contains(where: { $0.key == key }) {
            guard let peer = status.peers.first(where: { $0.publicKey == key }), let address = peer.tailscaleIPs.first else { continue }
            out.append(Candidate(key: key, address: address, name: peer.hostName, known: true))
        }
        return out
    }

    /// Dials `nodes` at once, each on its own thread (each connect bounded as `dial` bounds it):
    /// the first connected, the rest closed as they come; the last error when none connects.
    package static func race<T: Sendable>(
        _ nodes: [Candidate], close: @escaping @Sendable (T) -> Void, _ dial: @escaping @Sendable (Candidate) throws -> T
    ) throws -> (T, Candidate) {
        guard nodes.count > 1 else {
            guard let node = nodes.first else { throw RaceError.none }
            return (try dial(node), node)
        }
        let state = Mutex<(won: (T, Candidate)?, left: Int, error: (any Error)?, told: Bool)>((nil, nodes.count, nil, false))
        let done = DispatchSemaphore(value: 0)
        for node in nodes {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try dial(node) }
                let (keep, tell) = state.withLock { s -> (Bool, Bool) in
                    s.left -= 1
                    var keep = false
                    switch result {
                    case .success(let made) where s.won == nil:
                        s.won = (made, node)
                        keep = true
                    case .success: break
                    case .failure(let error): s.error = error
                    }
                    let tell = !s.told && (s.won != nil || s.left == 0)
                    if tell { s.told = true }
                    return (keep, tell)
                }
                if case .success(let made) = result, !keep { close(made) }
                if tell { done.signal() }
            }
        }
        done.wait()
        return try state.withLock { s in
            guard let won = s.won else { throw s.error ?? RaceError.none }
            return won
        }
    }

    package enum RaceError: Error { case none }

    /// Whether a tailnet host name is one a box called one of `names` gets: the name itself,
    /// Kore's own node's `<name>-kore`, and either with the `-N` Tailscale adds to a name taken.
    package static func named(_ host: String, after names: [String]) -> Bool {
        let host = host.lowercased()
        for raw in names {
            let name = raw.lowercased().split(separator: ".").first.map(String.init) ?? ""
            guard !name.isEmpty else { continue }
            for base in [name, name + "-kore"] {
                if host == base { return true }
                if host.hasPrefix(base + "-"), let n = Int(host.dropFirst(base.count + 1)), n > 0 { return true }
            }
        }
        return false
    }

    /// Whether a node is Kore's own (`<host>-kore`, `-kore-N`): userspace, so no sshd answers there.
    package static func isOwnNode(_ name: String) -> Bool {
        let name = name.lowercased()
        if name.hasSuffix("-kore") { return true }
        guard let dash = name.lastIndex(of: "-"), Int(name[name.index(after: dash)...]) != nil else { return false }
        return name[..<dash].hasSuffix("-kore")
    }

    /// Whether an SSH host only works over a tailnet: a tailnet address or a MagicDNS name.
    package static func overTailnet(_ host: String) -> Bool { isTailnetAddress(host) || host.lowercased().hasSuffix(".ts.net") }

    /// Whether an address is a tailnet one (100.64.0.0/10, fd7a:115c:a1e0::/48): an SSH alias
    /// whose host is one only works while that node is online.
    package static func isTailnetAddress(_ host: String) -> Bool {
        if host.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}

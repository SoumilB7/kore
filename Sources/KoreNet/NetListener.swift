import Foundation
import Tailnet

/// KoreNet's port, bound only to the addresses given (this node's tailnet addresses), never
/// 0.0.0.0 or ::. Each connection passes the pre-auth limiter before a session sees a byte.
package final class NetListener: Sendable {
    /// Port 47470 until the owner settles it (plan §11 q2).
    package static let port: UInt16 = 47470

    package let sockets: [TailnetListenSocket]
    private let limiter: PreAuthLimiter

    /// Listens on each of `addresses`, refusing any wildcard, and when `allowed` is given (the
    /// tailnet's own addresses), any address outside it.
    package init(addresses: [String], port: UInt16 = NetListener.port, allowed: Set<String>? = nil, limiter: PreAuthLimiter = PreAuthLimiter()) throws {
        try Self.check(addresses, allowed: allowed)
        var bound: [TailnetListenSocket] = []
        do {
            for address in addresses { bound.append(.tcp(try Sockets.listenTCP(address, port: port))) }
        } catch {
            for socket in bound { Sockets.closeFD(socket.fd) }
            throw error
        }
        sockets = bound
        self.limiter = limiter
    }

    /// The sockets a tailnet gave (`Tailnet.listen`): installed Tailscale's addresses or the
    /// sidecar's handoff socket.
    package init(sockets: [TailnetListenSocket], limiter: PreAuthLimiter = PreAuthLimiter()) {
        self.sockets = sockets
        self.limiter = limiter
    }

    /// The addresses' own rules: none empty or a wildcard, each one in `allowed` when given.
    package static func check(_ addresses: [String], allowed: Set<String>?) throws {
        guard !addresses.isEmpty else { throw SocketError.wildcard("") }
        for address in addresses {
            guard let ip = IPAddress(address) else {
                if address.isEmpty || address == "*" { throw SocketError.wildcard(address) }
                throw SocketError.badAddress(address)
            }
            guard !ip.isUnspecified else { throw SocketError.wildcard(address) }
            if let allowed, !allowed.contains(ip.description) && !allowed.contains(address) { throw SocketError.badAddress(address) }
        }
    }

    /// The next connection on `socket` that the limiter admits; one it refuses is closed and nil
    /// comes back.
    package func accept(on socket: TailnetListenSocket) throws -> (fd: Int32, remote: String)? {
        let (fd, remote) = try socket.accept()
        guard let remote, limiter.admit(remote) else {
            Sockets.closeFD(fd)
            return nil
        }
        return (fd, remote)
    }

    package func close() {
        for socket in sockets { Sockets.closeFD(socket.fd) }
    }
}

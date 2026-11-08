import Foundation
import Synchronization

/// Where installed Tailscale's LocalAPI answers (spike 0d).
package enum LocalAPIEndpoint: Equatable, Sendable {
    /// tailscaled's Unix socket: Linux, and open-source tailscaled on a Mac.
    case unix(String)
    /// The standalone Mac app: `127.0.0.1:<port>` with Basic auth `":" + token`.
    case tcp(port: UInt16, token: String)
    case unavailable(Missing)

    package enum Missing: String, Sendable {
        case absent
        /// The App Store build keeps its token in another app's group container; Kore doesn't
        /// reach in there (a TCC prompt) and uses its own tailnet instead.
        case appStore
        /// The standalone token is root:admin 0640: a non-admin user can't read it.
        case unreadable
    }
}

/// Finds the LocalAPI without lsof or scanning other apps' folders. `root` prefixes every path
/// (tests).
package struct LocalAPIDiscovery: Sendable {
    package enum Platform: Sendable { case mac, linux }

    package var platform: Platform
    package var root: String

    package init(platform: Platform = Self.here, root: String = "") {
        self.platform = platform
        self.root = root
    }

    #if os(macOS)
    package static let here = Platform.mac
    #else
    package static let here = Platform.linux
    #endif

    package static let linuxSocket = "/var/run/tailscale/tailscaled.sock"
    package static let macSocket = "/var/run/tailscaled.socket"
    package static let macPortLink = "/Library/Tailscale/ipnport"
    package static let macTokenPrefix = "/Library/Tailscale/sameuserproof-"
    package static let macApp = "/Applications/Tailscale.app"

    package func find() -> LocalAPIEndpoint {
        let fm = FileManager.default
        switch platform {
        case .linux:
            return fm.fileExists(atPath: root + Self.linuxSocket) ? .unix(root + Self.linuxSocket) : .unavailable(.absent)
        case .mac:
            if let target = try? fm.destinationOfSymbolicLink(atPath: root + Self.macPortLink), let port = UInt16(target) {
                guard let token = try? String(contentsOfFile: root + Self.macTokenPrefix + target, encoding: .utf8) else {
                    return .unavailable(.unreadable)
                }
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? .unavailable(.unreadable) : .tcp(port: port, token: trimmed)
            }
            if fm.fileExists(atPath: root + Self.macSocket) { return .unix(root + Self.macSocket) }
            if fm.fileExists(atPath: root + Self.macApp) { return .unavailable(.appStore) }
            return .unavailable(.absent)
        }
    }
}

/// Hand-written HTTP/1.1 GETs to the LocalAPI over POSIX sockets. The endpoint is found once and
/// found again when it stops answering or refuses the token (tailscaled restarted on a new port).
package final class LocalAPIClient: Sendable {
    private let discover: @Sendable () -> LocalAPIEndpoint
    private let connect: @Sendable (LocalAPIEndpoint) throws -> Int32
    private let endpoint = Mutex<LocalAPIEndpoint?>(nil)

    package init(
        discover: @escaping @Sendable () -> LocalAPIEndpoint = { LocalAPIDiscovery().find() },
        connect: @escaping @Sendable (LocalAPIEndpoint) throws -> Int32 = LocalAPIClient.connect
    ) {
        self.discover = discover
        self.connect = connect
    }

    /// What the client would use now.
    package var current: LocalAPIEndpoint {
        endpoint.withLock { held in
            if let held { return held }
            let found = discover()
            held = found
            return found
        }
    }

    private func rediscover() -> LocalAPIEndpoint {
        let found = discover()
        endpoint.withLock { $0 = found }
        return found
    }

    package func get(_ path: String) throws -> Data {
        let (fd, reader) = try open(path, readTimeout: 5)
        defer { Sockets.closeFD(fd) }
        var body = reader
        return try body.body()
    }

    /// A connection whose response head was 200, its reader at the body. One retry after a fresh
    /// discovery when the connect fails or the token is refused.
    func open(_ path: String, readTimeout: Int?) throws -> (Int32, HTTP1.Reader) {
        var target = current
        for attempt in 0..<2 {
            let last = attempt == 1
            if case .unavailable(let why) = target { throw TailnetError.unavailable(why) }
            let fd: Int32
            do {
                fd = try connect(target)
            } catch {
                if last { throw error }
                target = rediscover()
                continue
            }
            if let readTimeout { Sockets.setReadTimeout(fd, seconds: readTimeout) }
            do {
                try Sockets.writeAll(fd, HTTP1.request(path, authorization: authorization(target)))
                var reader = HTTP1.Reader(fd: fd)
                let head = try reader.head()
                switch head.status {
                case 200:
                    return (fd, reader)
                case 401, 403:
                    if last { throw TailnetError.unauthorized }
                    target = rediscover()
                default:
                    throw TailnetError.http(head.status)
                }
            } catch {
                Sockets.closeFD(fd)
                throw error
            }
            // Refused: try again with what discovery finds now.
            Sockets.closeFD(fd)
        }
        throw TailnetError.unauthorized
    }

    private func authorization(_ endpoint: LocalAPIEndpoint) -> String? {
        if case .tcp(_, let token) = endpoint { return HTTP1.basic(token: token) }
        return nil
    }

    /// The real connection: the Unix socket, or loopback TCP.
    @Sendable package static func connect(_ endpoint: LocalAPIEndpoint) throws -> Int32 {
        switch endpoint {
        case .unix(let path): return try Sockets.connectUnix(path)
        case .tcp(let port, _): return try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: port)
        case .unavailable(let why): throw TailnetError.unavailable(why)
        }
    }
}

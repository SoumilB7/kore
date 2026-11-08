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
        /// Installed (its app bundle, or tailscaled's launch daemon, is there) but not running
        /// now: quit, or never started. The user's own node, so never a second one of Kore's.
        case notRunning
    }
}

/// Finds the LocalAPI without lsof or scanning other apps' folders. `root` prefixes every path
/// (tests).
///
/// On a Mac, installed means installed now: the Tailscale app bundle (standalone or App Store, by
/// its bundle id) or open-source tailscaled (its socket answering, or its launch daemon). What an
/// uninstalled Tailscale leaves behind (`/Library/Tailscale/ipnport`, `sameuserproof-*`, a dead
/// socket file) counts as absent, so Kore's own tailnet takes over; with the app there, a stale
/// port link is the app not running (stopped), never "absent".
package struct LocalAPIDiscovery: Sendable {
    package enum Platform: Sendable { case mac, linux }

    package var platform: Platform
    package var root: String
    /// Whether a Unix socket at the path answers a connect (tests: a fake).
    package var answers: @Sendable (String) -> Bool

    package init(platform: Platform = Self.here, root: String = "", answers: @escaping @Sendable (String) -> Bool = Self.socketAnswers) {
        self.platform = platform
        self.root = root
        self.answers = answers
    }

    #if os(macOS)
    package static let here = Platform.mac
    #else
    package static let here = Platform.linux
    #endif

    package static let linuxSocket = "/var/run/tailscale/tailscaled.sock"
    /// Where Linux packages put tailscaled: installed, its socket gone, is stopped (never a
    /// second node of Kore's own beside it).
    package static let linuxDaemons = ["/usr/sbin/tailscaled", "/usr/bin/tailscaled", "/usr/local/sbin/tailscaled", "/usr/local/bin/tailscaled"]
    package static let macSocket = "/var/run/tailscaled.socket"
    package static let macPortLink = "/Library/Tailscale/ipnport"
    package static let macTokenPrefix = "/Library/Tailscale/sameuserproof-"
    package static let macApp = "/Applications/Tailscale.app"
    /// Open-source tailscaled installed as a system daemon (`tailscaled install-system-daemon`).
    package static let macDaemon = "/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
    /// The two builds of the Mac app, by bundle id.
    package static let standaloneID = "io.tailscale.ipn.macsys"
    package static let appStoreID = "io.tailscale.ipn.macos"

    /// The Mac app as found in /Applications.
    package enum MacApp: Equatable, Sendable {
        case none
        /// The standalone build (or one whose id can't be read: its LocalAPI is looked for).
        case standalone
        case appStore
    }

    package func app() -> MacApp {
        let bundle = root + Self.macApp
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle, isDirectory: &isDir), isDir.boolValue else { return .none }
        guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String
        else { return .standalone }
        return id == Self.appStoreID ? .appStore : .standalone
    }

    package func find() -> LocalAPIEndpoint {
        let fm = FileManager.default
        switch platform {
        case .linux:
            if fm.fileExists(atPath: root + Self.linuxSocket) { return .unix(root + Self.linuxSocket) }
            return Self.linuxDaemons.contains { fm.isExecutableFile(atPath: root + $0) } ? .unavailable(.notRunning) : .unavailable(.absent)
        case .mac:
            switch app() {
            case .appStore:
                return .unavailable(.appStore)
            case .none:
                // No app: open-source tailscaled, or nothing. Leftovers of an uninstalled app
                // (port link, token, a socket file nobody serves) are nothing.
                if answers(root + Self.macSocket) { return .unix(root + Self.macSocket) }
                if fm.fileExists(atPath: root + Self.macDaemon) { return .unavailable(.notRunning) }
                return .unavailable(.absent)
            case .standalone:
                if let target = try? fm.destinationOfSymbolicLink(atPath: root + Self.macPortLink), let port = UInt16(target) {
                    let token = root + Self.macTokenPrefix + target
                    // The link outlived its token: the app isn't running now.
                    guard fm.fileExists(atPath: token) else { return .unavailable(.notRunning) }
                    guard let text = try? String(contentsOfFile: token, encoding: .utf8) else { return .unavailable(.unreadable) }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? .unavailable(.unreadable) : .tcp(port: port, token: trimmed)
                }
                if answers(root + Self.macSocket) { return .unix(root + Self.macSocket) }
                return .unavailable(.notRunning)
            }
        }
    }

    /// A connect to the Unix socket at `path` succeeds (closed at once).
    @Sendable package static func socketAnswers(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path), let fd = try? Sockets.connectUnix(path) else { return false }
        Sockets.closeFD(fd)
        return true
    }

    /// The Mac app's bundle path, when the app is installed (what `watchApp` watches).
    package var appPath: String? {
        platform == .mac && app() != .none ? root + Self.macApp : nil
    }
}

/// Hand-written HTTP/1.1 GETs to the LocalAPI over POSIX sockets. The endpoint is found once and
/// found again when it stops answering, refuses the token (tailscaled restarted on a new port) or
/// was missing when last looked.
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

    /// One POST with a JSON body (Tailnet Lock's sign): its answer's body once it said 200.
    package func post(_ path: String, body: Data) throws -> Data {
        let (fd, reader) = try open(path, readTimeout: 10, body: body)
        defer { Sockets.closeFD(fd) }
        var answer = reader
        return try answer.body()
    }

    /// A connection whose response head was 200, its reader at the body. One retry after a fresh
    /// discovery when the connect fails or the token is refused.
    func open(_ path: String, readTimeout: Int?, body: Data? = nil) throws -> (Int32, HTTP1.Reader) {
        var target = current
        // Missing when last looked (kore-host up before tailscaled at boot, Tailscale installed or
        // started since): looked for again, never kept missing for good.
        if case .unavailable = target { target = rediscover() }
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
                try Sockets.writeAll(fd, HTTP1.request(path, authorization: authorization(target), body: body))
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

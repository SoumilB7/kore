import Foundation
import Synchronization
@testable import Tailnet
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A Mac as Tailscale left it: the app (by bundle id), `/Library/Tailscale`'s port link and token,
/// open-source tailscaled's socket and launch daemon, and what the LocalAPI port says when dialled
/// (nil: nothing listens there).
struct MacTailscale: Sendable, CustomTestStringConvertible {
    enum Token: Sendable { case none, readable, unreadable, empty }

    var name: String
    /// The app bundle's id; "" a bundle with no readable Info.plist; nil no app.
    var app: String?
    var port: String?
    var token: Token = .none
    var socketFile = false
    var socketAnswers = false
    var daemon = false
    var says: BackendState?
    var endpoint: LocalAPIEndpoint
    var choice: TailnetChooser.Choice

    var testDescription: String { name }

    static let standalone = LocalAPIDiscovery.standaloneID
    static let appStore = LocalAPIDiscovery.appStoreID

    /// Every combination the owner's uninstall (and its neighbours) can leave.
    static let all: [MacTailscale] = [
        // Absent: nothing, or only what an uninstall leaves.
        .init(name: "never installed", endpoint: .unavailable(.absent), choice: .sidecar),
        .init(name: "uninstalled: stale port link and token, port dead", port: "59495", token: .readable, endpoint: .unavailable(.absent), choice: .sidecar),
        .init(name: "uninstalled: stale port link, token root:admin", port: "59495", token: .unreadable, endpoint: .unavailable(.absent), choice: .sidecar),
        .init(name: "uninstalled: port link only", port: "59495", endpoint: .unavailable(.absent), choice: .sidecar),
        .init(
            name: "uninstalled: its extension still answers Running", port: "59495", token: .readable, says: .running, endpoint: .unavailable(.absent),
            choice: .sidecar),
        .init(name: "uninstalled: a socket file nobody serves", socketFile: true, endpoint: .unavailable(.absent), choice: .sidecar),
        // The standalone app.
        .init(
            name: "app running", app: standalone, port: "59495", token: .readable, says: .running, endpoint: .tcp(port: 59495, token: "tok-1"),
            choice: .installed),
        .init(
            name: "app quit: stale port link and token, port dead", app: standalone, port: "59495", token: .readable,
            endpoint: .tcp(port: 59495, token: "tok-1"), choice: .stopped),
        .init(name: "app quit: port link outlived its token", app: standalone, port: "59495", endpoint: .unavailable(.notRunning), choice: .stopped),
        .init(name: "app installed, never started", app: standalone, endpoint: .unavailable(.notRunning), choice: .stopped),
        .init(
            name: "app stopped (its switch off)", app: standalone, port: "59495", token: .readable, says: .stopped,
            endpoint: .tcp(port: 59495, token: "tok-1"), choice: .stopped),
        .init(
            name: "app signed out", app: standalone, port: "59495", token: .readable, says: .needsLogin, endpoint: .tcp(port: 59495, token: "tok-1"),
            choice: .signedOut),
        .init(
            name: "app running, non-admin user", app: standalone, port: "59495", token: .unreadable, says: .running, endpoint: .unavailable(.unreadable),
            choice: .sidecar),
        .init(name: "app running, empty token", app: standalone, port: "59495", token: .empty, says: .running, endpoint: .unavailable(.unreadable), choice: .sidecar),
        .init(name: "app with a port link that isn't a port", app: standalone, port: "junk", endpoint: .unavailable(.notRunning), choice: .stopped),
        .init(name: "app bundle without a readable Info.plist", app: "", endpoint: .unavailable(.notRunning), choice: .stopped),
        // The App Store app: its token is out of reach, leftovers or not.
        .init(name: "App Store app", app: appStore, endpoint: .unavailable(.appStore), choice: .sidecar),
        .init(name: "App Store app over standalone leftovers", app: appStore, port: "59495", token: .readable, endpoint: .unavailable(.appStore), choice: .sidecar),
        // Open-source tailscaled.
        .init(
            name: "tailscaled running", socketFile: true, socketAnswers: true, says: .running, endpoint: .unix("/var/run/tailscaled.socket"),
            choice: .installed),
        .init(name: "tailscaled installed, not running", daemon: true, endpoint: .unavailable(.notRunning), choice: .stopped),
        .init(
            name: "app beside a running tailscaled, no port link", app: standalone, socketFile: true, socketAnswers: true, says: .running,
            endpoint: .unix("/var/run/tailscaled.socket"), choice: .installed),
    ]

    /// Lays the Mac out under `root`.
    func make(_ root: URL) throws {
        let fm = FileManager.default
        if let app {
            let contents = root.path + LocalAPIDiscovery.macApp + "/Contents"
            try fm.createDirectory(atPath: contents, withIntermediateDirectories: true)
            if !app.isEmpty {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": app], format: .xml, options: 0)
                try plist.write(to: URL(fileURLWithPath: contents + "/Info.plist"))
            }
        }
        if port != nil || token != .none { try fm.createDirectory(atPath: root.path + "/Library/Tailscale", withIntermediateDirectories: true) }
        if let port { try fm.createSymbolicLink(atPath: root.path + LocalAPIDiscovery.macPortLink, withDestinationPath: port) }
        let tokenPath = root.path + LocalAPIDiscovery.macTokenPrefix + (port ?? "59495")
        switch token {
        case .none: break
        case .readable: try "tok-1\n".write(toFile: tokenPath, atomically: true, encoding: .utf8)
        case .empty: try "\n".write(toFile: tokenPath, atomically: true, encoding: .utf8)
        case .unreadable:
            try "tok-1\n".write(toFile: tokenPath, atomically: true, encoding: .utf8)
            chmod(tokenPath, 0)
        }
        if socketFile {
            try fm.createDirectory(atPath: root.path + "/var/run", withIntermediateDirectories: true)
            fm.createFile(atPath: root.path + LocalAPIDiscovery.macSocket, contents: nil)
        }
        if daemon {
            try fm.createDirectory(atPath: root.path + "/Library/LaunchDaemons", withIntermediateDirectories: true)
            fm.createFile(atPath: root.path + LocalAPIDiscovery.macDaemon, contents: Data("<plist/>".utf8))
        }
    }
}

@Suite("installed Tailscale: present, stopped or absent")
struct TailscaleInstallTests {
    /// Discovery finds what each layout should, and the chooser then picks the owner's rule:
    /// running → installed; installed but stopped or signed out → no second node; absent or
    /// unreadable → Kore's own tailnet. Leftovers alone are absent.
    @Test(arguments: MacTailscale.all)
    func layout(_ mac: MacTailscale) throws {
        let root = try TestKit.scratch("ts")
        defer { try? FileManager.default.removeItem(at: root) }
        try mac.make(root)
        let discovery = LocalAPIDiscovery(platform: .mac, root: root.path, answers: { _ in mac.socketAnswers })
        var want = mac.endpoint
        if case .unix(let path) = want { want = .unix(root.path + path) }
        #expect(discovery.find() == want)
        #expect((discovery.appPath != nil) == (mac.app != nil))
        let server = FakeHTTPServer()
        let api = LocalAPIClient(
            discover: { discovery.find() },
            connect: { _ in
                guard let says = mac.says else { throw SocketError.failed("connect", ECONNREFUSED) }
                return try server.connection(answering: FakeHTTPServer.ok(#"{"BackendState":"\#(says.rawValue)"}"#))
            })
        let (installed, local) = TailnetChooser.installed(api)
        let choice = TailnetChooser.choose(installed)
        #expect(choice == mac.choice, "\(installed)")
        // A client comes with every choice but Kore's own: a stopped app is found when it starts.
        #expect((local != nil) == !choice.startsSidecar)
    }

    /// The app was there when found, then uninstalled before its port answered: the failed read
    /// looks again and finds it absent (never "stopped", which would leave KoreNet off for good).
    @Test func uninstalledBetweenTheLookAndTheRead() throws {
        let found = LockedQueue<LocalAPIEndpoint>([.tcp(port: 59495, token: "tok-1"), .unavailable(.absent)])
        let api = LocalAPIClient(discover: { found.next() }, connect: { _ in throw SocketError.failed("connect", ECONNREFUSED) })
        let (installed, local) = TailnetChooser.installed(api)
        #expect(installed == .missing(.absent) && local == nil)
        #expect(TailnetChooser.choose(installed) == .sidecar)
    }

    /// Quit, then started again: the stopped client finds the new port by itself.
    @Test func aStoppedAppIsFoundWhenItStarts() throws {
        let found = LockedQueue<LocalAPIEndpoint>([.unavailable(.notRunning), .tcp(port: 60001, token: "tok-2")])
        let server = FakeHTTPServer()
        let api = LocalAPIClient(
            discover: { found.next() },
            connect: { endpoint in
                guard endpoint == .tcp(port: 60001, token: "tok-2") else { throw SocketError.failed("connect", ECONNREFUSED) }
                return try server.connection(answering: FakeHTTPServer.ok(#"{"BackendState":"Running"}"#))
            })
        let (installed, local) = TailnetChooser.installed(api)
        #expect(installed == .state(.stopped))
        #expect(try #require(local).status().backendState == .running)
    }

    /// The status as text keeps the sign-in page out (logs, errors).
    @Test func statusTextHidesTheSignInPage() throws {
        let status = try JSONDecoder().decode(
            TailnetStatus.self, from: Data(#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/0123abcd"}"#.utf8))
        #expect(status.authURL == "https://login.tailscale.com/a/0123abcd")
        for text in ["\(status)", String(describing: status), String(reflecting: status), "\([status])", "\(Optional(status) as Any)"] {
            #expect(!text.contains("login.tailscale.com") && !text.contains("0123abcd"), "\(text)")
        }
    }

    /// The bus says when the sign-in page is ready, never the page itself.
    @Test func theBusTellsTheSignInPageCameNotWhatItIs() throws {
        let notify = try JSONDecoder().decode(BusNotify.self, from: Data(#"{"BrowseToURL":"https://login.tailscale.com/a/0123abcd"}"#.utf8))
        #expect(notify.events == [.state(.needsLogin)])
        let both = try JSONDecoder().decode(BusNotify.self, from: Data(#"{"State":6,"BrowseToURL":"https://login.tailscale.com/a/x"}"#.utf8))
        #expect(both.events == [.state(.running)])
    }
}

/// Hands out its values in order, the last one for good.
final class LockedQueue<T: Sendable>: Sendable {
    private let values: Mutex<[T]>
    init(_ values: [T]) { self.values = Mutex(values) }
    func next() -> T { values.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

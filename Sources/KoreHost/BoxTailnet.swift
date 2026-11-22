import Foundation
import KoreTrust
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension HostPaths {
    /// Kore's own tailnet on this box: `kore-tailnet`'s socket and its sealed state (0700).
    package var tailnetFolder: URL { state.appendingPathComponent("tailnet") }
    package var tailnetSocket: URL { tailnetFolder.appendingPathComponent("kt.sock") }
    /// Its 32-byte state key (0600): a box keeps nothing in a keychain.
    package var tailnetKey: URL { state.appendingPathComponent("tailnet.key") }
}

/// The system a box runs, as the lines a person is shown depend on it.
package enum BoxOS: String, Equatable, Sendable {
    case linux, macos

    package static var here: BoxOS {
        #if os(macOS)
        .macos
        #else
        .linux
        #endif
    }
}

/// Which tailnet this box is on KoreNet with (phase 18 §1, the Mac's rule, `TailnetChooser`):
/// installed Tailscale running → it; installed but stopped or signed out → Kore's own beside it
/// until it's up again (`TailscaleBesideWatch`), so the box stays reachable; absent, or its
/// LocalAPI unreadable (the Mac App Store build, a non-admin user) → Kore's own `kore-tailnet`,
/// started by the daemon beside kore-host, its state sealed under a key in a 0600 file. Its
/// lifetime is the daemon's; KoreNet off stops it. Without the helper, beside a stopped or
/// signed-out Tailscale, the box waits for that node as before.
package struct BoxTailnet: Sendable {
    /// What the daemon got.
    package enum Pick: @unchecked Sendable {
        /// Installed Tailscale (running, stopped or signed out: its own node, never a second one).
        case installed(any Tailnet, TailnetChooser.Choice)
        /// Kore's own, up: its tailnet, whether its program still runs, and how it stops; beside
        /// installed Tailscale that's stopped or signed out, that Tailscale's client (to hear it
        /// come back up).
        case kore(any Tailnet, alive: @Sendable () -> Bool, stop: @Sendable () -> Void, beside: (any Tailnet)? = nil)
        /// Kore's own was chosen and couldn't start: why, in a few words.
        case unavailable(String)
    }

    /// Installed Tailscale as found now, and its client when it has one.
    package var installed: @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?)
    /// `kore-tailnet`'s path, when it's there.
    package var helper: @Sendable () -> URL?
    /// Runs the helper and brings its node up with the key.
    package var start: @Sendable (_ helper: URL, _ key: Data) throws -> (tailnet: any Tailnet, alive: @Sendable () -> Bool, stop: @Sendable () -> Void)
    package var key: @Sendable () throws -> Data
    /// Kore's own whatever is installed (`KORE_HOST_TAILNET=kore`: the live test's second node).
    package var forced = false

    package init(
        installed: @escaping @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?), helper: @escaping @Sendable () -> URL?,
        start: @escaping @Sendable (URL, Data) throws -> (tailnet: any Tailnet, alive: @Sendable () -> Bool, stop: @Sendable () -> Void),
        key: @escaping @Sendable () throws -> Data, forced: Bool = false
    ) {
        self.installed = installed
        self.helper = helper
        self.start = start
        self.key = key
        self.forced = forced
    }

    /// The helper's name beside kore-host (`~/.local/bin/kore-tailnet`).
    package static let helperName = NetSidecar.helperName
    /// Why Kore's own can't start when there's no helper.
    package static let noHelper = "no kore-tailnet beside kore-host"

    /// The choice now, without starting anything.
    package func choice() -> TailnetChooser.Choice {
        forced ? .sidecar : TailnetChooser.chooseBeside(installed().0)
    }

    /// Chooses, and starts Kore's own when that's the choice. Blocks while it starts (up to its
    /// helper's `ready` and the node's start): run it off the main thread.
    package func choose() -> Pick {
        let (found, local) = installed()
        let choice = forced ? .sidecar : TailnetChooser.chooseBeside(found)
        guard choice.startsSidecar else { return .installed(local ?? TailnetLocal(), choice) }
        // Beside a stopped or signed-out Tailscale and Kore's own can't run: that node, waited for.
        let waitForInstalled = Pick.installed(local ?? TailnetLocal(), TailnetChooser.fallback(found))
        guard let helper = helper() else { return choice == .beside ? waitForInstalled : .unavailable(Self.noHelper) }
        do {
            let made = try start(helper, try key())
            return .kore(made.tailnet, alive: made.alive, stop: made.stop, beside: choice == .beside ? (local ?? TailnetLocal()) : nil)
        } catch {
            return choice == .beside ? waitForInstalled : .unavailable("\(error)")
        }
    }

    /// This box's own: LocalAPI discovery, the helper beside kore-host, its key file.
    package static func standard(_ paths: HostPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> BoxTailnet {
        let extra = arguments(environment)
        return BoxTailnet(
            installed: { TailnetChooser.installed(LocalAPIClient()) },
            helper: { helper(executable: URL(fileURLWithPath: HostService.executable()), environment: environment) },
            start: { helper, key in
                let sidecar: NetSidecar
                do {
                    sidecar = try NetSidecar.start(helper: helper, folder: paths.tailnetFolder, key: key, arguments: extra)
                } catch let error as TailnetError where error.wrongKey {
                    // Sealed under a key this box no longer has: started afresh, its sign-in gone
                    // (the owner is told: "its saved sign-in couldn't be opened").
                    HostJournal.note("korenet own", ["state": "unreadable", "action": "started afresh"])
                    try? FileManager.default.removeItem(at: paths.tailnetFolder.appendingPathComponent("state"))
                    BoxOwnRecord.unreadable(paths)
                    sidecar = try NetSidecar.start(helper: helper, folder: paths.tailnetFolder, key: key, arguments: extra)
                }
                return (sidecar.tailnet, { sidecar.running }, { sidecar.stop() })
            },
            key: { try key(paths) },
            forced: forced(environment))
    }

    /// `kore-tailnet` beside this kore-host, else `KORE_TAILNET_BIN`.
    package static func helper(executable: URL, environment: [String: String]) -> URL? {
        let files = FileManager.default
        let beside = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(helperName)
        if files.isExecutableFile(atPath: beside.path) { return beside }
        if let set = environment["KORE_TAILNET_BIN"], !set.isEmpty, files.isExecutableFile(atPath: set) { return URL(fileURLWithPath: set) }
        return nil
    }

    /// `KORE_HOST_TAILNET=kore`: Kore's own tailnet even where Tailscale is installed.
    package static func forced(_ environment: [String: String]) -> Bool { environment["KORE_HOST_TAILNET"] == "kore" }

    /// The node's name ("<host>-kore", or `KORE_HOST_TAILNET_NAME`) and lifetime
    /// (`KORE_HOST_TAILNET_EPHEMERAL=1`).
    package static func arguments(_ environment: [String: String], host: String = ProcessInfo.processInfo.hostName) -> [String] {
        var out: [String] = []
        if let name = environment["KORE_HOST_TAILNET_NAME"], !name.isEmpty, name.count <= 63,
           name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            out += ["-hostname", name]
        } else {
            out += ["-hostname", NetSidecar.nodeName(host)]
        }
        if environment["KORE_HOST_TAILNET_EPHEMERAL"] == "1" { out.append("-ephemeral") }
        return out
    }

    /// The state key: 32 random bytes in a 0600 file, made on first use.
    package static func key(_ paths: HostPaths) throws -> Data {
        try HostPaths.privateFolder(paths.state)
        if let kept = try PrivateFile.read(paths.tailnetKey), kept.count == 32 { return kept }
        let made = secureRandom(32)
        try PrivateFile.write(made, to: paths.tailnetKey)
        return made
    }

    // MARK: As `kore-host upgrade` sees it

    /// Kore's own tailnet as the running daemon has it.
    package enum Kore: Equatable, Sendable {
        case running(node: String?, account: String?)
        /// Waiting for a sign-in: its page, once tsnet has one.
        case signIn(String?)
        case unavailable(String)
    }

    /// What `net.state` says when the daemon couldn't start Kore's own.
    package static let unavailablePrefix = "not listening: kore-tailnet unavailable: "

    /// Kore's own as its socket answers (the running daemon's), waiting up to `within` for a
    /// sign-in page or a running node: tsnet takes a moment to hear from its control server.
    package static func read(
        _ paths: HostPaths, within: TimeInterval = 10, relogin: Bool = false, now: () -> Date = Date.init, pause: () -> Void = { usleep(200_000) }
    ) -> Kore {
        let sidecar = TailnetSidecar(path: paths.tailnetSocket.path, answerWait: 3000)
        if relogin { try? sidecar.logout() }
        let end = now().addingTimeInterval(within)
        var last: TailnetStatus?
        while true {
            if let said = (try? String(contentsOf: paths.netState, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
               said.hasPrefix(unavailablePrefix) {
                return .unavailable(String(said.dropFirst(unavailablePrefix.count)))
            }
            if let status = try? sidecar.status() {
                last = status
                if status.backendState == .running { return .running(node: status.selfNode?.publicKey, account: status.login) }
                if let page = status.authURL, page.hasPrefix("https://") { return .signIn(page) }
            }
            guard now() < end else { break }
            pause()
        }
        if let last { return last.backendState == .running ? .running(node: last.selfNode?.publicKey, account: last.login) : .signIn(nil) }
        return .unavailable("kore-tailnet isn't running")
    }
}

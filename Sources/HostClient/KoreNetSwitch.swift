import Foundation
import KoreCore
import KoreNet
import KoreTrust
import LinkProtocol
import Observation
import Synchronization
import Tailnet

/// What KoreNet on this Mac is doing (phase 18 §1 "Choose").
package enum NetState: Equatable, Sendable {
    /// Off: no tailnet client, LocalAPI read, bus, helper, listener or probe.
    case off
    case choosing
    /// Installed Tailscale, running: Kore adds no process.
    case installed
    /// Installed Tailscale, stopped, and Kore's own can't run beside it: SSH only.
    case stopped
    /// Installed Tailscale, signed out, and Kore's own can't run beside it: SSH only; the UI says
    /// "Sign in to Tailscale".
    case signedOut
    /// Kore's own `kore-tailnet`: no installed Tailscale (or its LocalAPI unreadable), or beside
    /// an installed app that's quit or signed out.
    case sidecar
    /// Kore's own couldn't start (no helper, or it failed): SSH only.
    case unavailable(String)

    /// Boxes can be reached over the tailnet.
    package var reaches: Bool { self == .installed || self == .sidecar }
}

/// Everything KoreNet on this Mac reaches out to, made only when it turns on (tests: fakes).
package struct NetEnvironment: @unchecked Sendable {
    /// Installed Tailscale as found now, and its client when its LocalAPI answers.
    package var installed: @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?)
    /// Kore's own `kore-tailnet`, up: its tailnet, and how it stops.
    package var sidecar: @Sendable (_ key: Data) throws -> (tailnet: any Tailnet, stop: @Sendable () -> Void)
    package var secrets: any NetSecrets
    package var defaults: UserDefaults
    /// Kore's Application Support folder (`Kore/`).
    package var support: URL
    /// `ssh <alias> kore-host attach --as <grant> --proto 2`, as a connected socket (the upgrade,
    /// and an enrolled box's SSH route).
    package var upgradeDial: @Sendable (_ alias: String, _ grant: String, _ command: String) throws -> (fd: Int32, onClose: @Sendable () -> Void)
    /// The same, to `host` in place of the alias's own (`ssh -o HostName=<host> <alias>`): a box
    /// whose alias names a tailnet address it's no longer on.
    package var upgradeDialVia: @Sendable (_ alias: String, _ grant: String, _ command: String, _ host: String) throws -> (fd: Int32, onClose: @Sendable () -> Void)
    /// The host an SSH alias reaches (`ssh -G`), nil when it can't be read.
    package var hostOf: @Sendable (_ alias: String) -> String?
    /// This Mac's name, as a box's enroll shows it.
    package var macName: @Sendable () -> String
    /// Calls `changed` once when installed Tailscale's app leaves its place (moved to the Trash,
    /// deleted, replaced by an update): KoreNet chooses again. Nil when there's no app to watch.
    /// The closure it gives back stops watching. One descriptor, no poll.
    package var watchApp: @Sendable (_ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?
    /// Calls `changed` each time installed Tailscale's app is launched or quits (the system's
    /// own notices, no poll), so KoreNet chooses again. Nil when there's no app to watch. The
    /// closure it gives back stops watching.
    package var watchRunning: @Sendable (_ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    package init(
        installed: @escaping @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?),
        sidecar: @escaping @Sendable (Data) throws -> (tailnet: any Tailnet, stop: @Sendable () -> Void), secrets: any NetSecrets, defaults: UserDefaults,
        support: URL, upgradeDial: @escaping @Sendable (String, String, String) throws -> (fd: Int32, onClose: @Sendable () -> Void),
        macName: @escaping @Sendable () -> String,
        watchApp: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)? = { _ in nil },
        watchRunning: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)? = { _ in nil },
        upgradeDialVia: (@Sendable (String, String, String, String) throws -> (fd: Int32, onClose: @Sendable () -> Void))? = nil,
        hostOf: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.upgradeDialVia = upgradeDialVia ?? { alias, grant, command, _ in try upgradeDial(alias, grant, command) }
        self.hostOf = hostOf
        self.installed = installed
        self.sidecar = sidecar
        self.secrets = secrets
        self.defaults = defaults
        self.support = support
        self.upgradeDial = upgradeDial
        self.macName = macName
        self.watchApp = watchApp
        self.watchRunning = watchRunning
    }

    /// Why Kore's own tailnet can't start in a copy built without it (`Contents/Helpers` has no
    /// `kore-tailnet`: built without Go, or not a signed release): the hover's words.
    package static let noHelper = "This copy of Kore has no tailnet of its own"

    /// The Mac's own: LocalAPI discovery, `Contents/Helpers/kore-tailnet`, Kore's secrets files, ssh.
    package static func standard(defaults: UserDefaults = .standard) -> NetEnvironment {
        let support = NodeMigration.standardRoot()
        return NetEnvironment(
            installed: { installedTailscale(LocalAPIClient()) },
            sidecar: { key in
                guard let helper = NetSidecar.helper() else {
                    throw TailnetError.sidecar(NetEnvironment.noHelper)
                }
                let sidecar = try NetSidecar.start(
                    helper: helper, folder: support.appendingPathComponent("net/tailnet", isDirectory: true), key: key,
                    arguments: ["-hostname", NetSidecar.nodeName(ProcessInfo.processInfo.hostName)])
                return (sidecar.tailnet, { sidecar.stop() })
            },
            secrets: FileSecrets(folder: FileSecrets.folder(support: support)), defaults: defaults, support: support,
            upgradeDial: { alias, grant, command in try sshDial(alias, grant, command, host: nil) },
            macName: { String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "Mac") },
            watchApp: { changed in AppWatch.start(LocalAPIDiscovery().appPath, changed: changed) },
            watchRunning: { changed in AppRunWatch.start(LocalAPIDiscovery().appPath ?? LocalAPIDiscovery.macApp, changed: changed) },
            upgradeDialVia: { alias, grant, command, host in try sshDial(alias, grant, command, host: host) },
            hostOf: { SSHTransport.hostName(alias: $0) })
    }

    /// `ssh <alias> kore-host attach --as <grant> --proto 2` (to `host`, when given, in place of
    /// the alias's own), as a connected socket.
    static func sshDial(_ alias: String, _ grant: String, _ command: String, host: String?) throws -> (fd: Int32, onClose: @Sendable () -> Void) {
                let (mine, theirs) = try Sockets.pair()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: SSHTransport.ssh)
                let args = SSHTransport.arguments(alias: alias, grant: grant, command: command) + ["--proto", "2"]
                process.arguments = host.map { ["-o", "HostName=" + $0] + args } ?? args
                let handle = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
                process.standardInput = handle
                process.standardOutput = handle
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    Sockets.closeFD(mine)
                    Sockets.closeFD(theirs)
                    throw error
                }
                Sockets.closeFD(theirs)
                return (mine, { if process.isRunning { process.terminate() } })
    }
}

extension NetEnvironment {
    /// Installed Tailscale as its LocalAPI says. Installed but not answering (Kore at login before
    /// tailscaled listens, Tailscale quitting) is stopped, never "unreadable": that would start a
    /// second node of Kore's own for this Mac. The bus and the next read see it come up.
    package static func installedTailscale(_ api: LocalAPIClient) -> (TailnetChooser.Installed, (any Tailnet)?) {
        TailnetChooser.installed(api)
    }
}

/// This Mac's identity, read from its file once, off the main actor, on first need.
package final class NetIdentityBox: Sendable {
    private let held = Mutex<MacIdentity?>(nil)

    package init() {}

    package func get(_ env: NetEnvironment) throws -> MacIdentity {
        try held.withLock { held in
            if let held { return held }
            let made = try MacIdentity.loadOrCreate(secrets: env.secrets, defaults: env.defaults)
            held = made
            return made
        }
    }
}

/// KoreNet on this Mac (phase 18 step 5a): off by default, kept in Kore's settings. Off, it holds
/// nothing at all and every box link goes over SSH exactly as before. On, it picks the tailnet
/// (`TailnetChooser`: installed Tailscale running → it; installed but stopped or signed out →
/// none, SSH only; absent or unreadable → Kore's own `kore-tailnet`, run only while on), routes
/// box links over it when the box is known there, enrolls this Mac at SSH boxes once
/// (`attach --proto 2`), rekeys a box's stores on its first KoreNet welcome, and holds the IPN bus
/// only while a box window (or the Devices popup) is open. Nothing here polls or pings.
@MainActor @Observable
package final class KoreNetSwitch: NetRouter {
    package static let onKey = "koreNetOn"
    /// Kore's (set at launch).
    package static var shared: KoreNetSwitch?

    package private(set) var on: Bool
    package private(set) var state = NetState.off
    /// The chosen tailnet's status as last read or heard (the Devices popup draws from it, never
    /// waiting on a read); nil while off or not read yet.
    package private(set) var status: TailnetStatus? { didSet { SSHTailnetRoute.heard(status) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: () -> NetEnvironment
    @ObservationIgnored package let directory: NodeDirectory
    @ObservationIgnored package let rekeyer: NodeRekeyer
    /// Environments made: each turn on makes one (a test checks off makes none).
    @ObservationIgnored package private(set) var made = 0
    @ObservationIgnored package private(set) var env: NetEnvironment?
    @ObservationIgnored package private(set) var tailnet: (any Tailnet)? {
        // Kore's ssh follows the tailnet chosen (`SSHTailnetRoute`): Kore's own, or installed.
        didSet { if global { Self.routeSSH(tailnet) } }
    }
    @ObservationIgnored private var stopSidecar: (@Sendable () -> Void)?
    @ObservationIgnored private var bus: Task<Void, Never>?
    @ObservationIgnored private var holders: Set<String> = []
    /// This Mac's identity while on (read from its file once, off the main actor). The
    /// phones' listener (`MacNet`, KoreLink) reads it too.
    @ObservationIgnored package private(set) var identities = NetIdentityBox()
    @ObservationIgnored private var upgrading: Set<String> = []
    /// Bumped each time it turns on or off (a box's upgrade tries once per run of KoreNet).
    @ObservationIgnored package private(set) var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    /// A join sheet's ears: what each box says on KoreNet, and how its enroll ended.
    @ObservationIgnored private var nodeWatchers: [String: @MainActor (NetNodeWire.Node) -> Void] = [:]
    @ObservationIgnored private var enrollWatchers: [String: @MainActor (Bool) -> Void] = [:]
    /// Every bus subscription held now (tests).
    @ObservationIgnored package var busHeld: Bool { bus != nil }
    /// Finished upgrades and choices (tests wait on them).
    @ObservationIgnored package var settled: (@MainActor (String) -> Void)?
    /// What phones are told of the boxes changed (a box enrolled, gained a tailnet node key, was
    /// renamed, taken offline or removed): the phones' listener sends them the directory.
    @ObservationIgnored package var directoryChanged: (@MainActor () -> Void)?
    /// Work off the main actor, told as it begins (true) and ends (false): the KoreNet system
    /// tests' world doesn't move its clock on while any is under way (a sidecar's start, a status
    /// read). Kore: nothing listens.
    @ObservationIgnored package var counting: @Sendable (Bool) -> Void = { _ in }

    /// `work` off the main actor, counted while it runs.
    private func offMain(_ work: @escaping @Sendable () async -> Void) {
        let counting = counting
        counting(true)
        Task.detached {
            await work()
            counting(false)
        }
    }

    /// A value worked out off the main actor, counted while it's worked out.
    nonisolated private static func offMain<T: Sendable>(_ counting: @Sendable (Bool) -> Void, _ work: @escaping @Sendable () -> T) async -> T {
        counting(true)
        defer { counting(false) }
        return await Task.detached { work() }.value
    }
    /// Bumped when a box says something its row or card shows (Kore's tailnet there): what
    /// draws them reads it, so the change shows the moment `net.node` comes.
    package private(set) var nodeRevision = 0
    /// This Mac's book lost a record it issued to the boxes (a box it allowed from a pending
    /// row, forgotten): the boxes hear the change (`devices.set{merge}`).
    @ObservationIgnored package var issuedChanged: (@MainActor () -> Void)?
    /// The Mac woke or its network changed: the phones' listener looks again.
    @ObservationIgnored package var phonesLook: (@MainActor () -> Void)?
    /// The boxes' SSH → KoreNet upgrades (Kore: `BoxUpgrades.shared`; tests: their own or none):
    /// told when KoreNet can reach boxes, and when a box's link says who it is.
    @ObservationIgnored package var upgrades: BoxUpgrades?

    /// The links it routes (Kore: every held one; a test: its own).
    @ObservationIgnored private let connections: @MainActor () -> [HostConnection]
    /// Whether it's Kore's router for every link (`HostConnection.net`); a test's routes its own.
    @ObservationIgnored private let global: Bool

    package init(
        defaults: UserDefaults, directory: NodeDirectory, rekeyer: NodeRekeyer, global: Bool = true,
        connections: @escaping @MainActor () -> [HostConnection] = { HostConnection.held }, environment: @escaping () -> NetEnvironment
    ) {
        self.global = global
        self.connections = connections
        self.defaults = defaults
        self.directory = directory
        self.rekeyer = rekeyer
        self.environment = environment
        on = defaults.bool(forKey: Self.onKey)
    }

    /// At launch: on as it was left.
    package func start() { if on { begin() } }

    package func set(_ on: Bool) {
        guard on != self.on else { return }
        self.on = on
        defaults.set(on, forKey: Self.onKey)
        on ? begin() : end()
    }

    private func begin() {
        guard env == nil else { return }
        let env = environment()
        made += 1
        self.env = env
        identities = NetIdentityBox()
        generation += 1
        state = .choosing
        busRetry = 0
        holders = Set(connections().filter(\.inUse).map(\.alias))
        if global { HostConnection.net = self }
        choose(env, generation, grace: 0)
    }

    /// At launch (or KoreNet switched on) with installed Tailscale there but its daemon not
    /// answering yet (the login race): looked at again these many seconds apart before Kore's own
    /// starts beside it, so a Tailscale that's coming up is taken with no second node and no flap.
    /// A quit later hands over at once (no grace).
    nonisolated package static let launchGrace: [TimeInterval] = [1, 2, 3, 4, 5]
    @ObservationIgnored private var graceCancel: (() -> Void)?

    /// Discovery and the choice off the main actor (Kore's own tailnet started when chosen),
    /// then `chose` on it.
    private func choose(_ env: NetEnvironment, _ mine: Int, keep: Sidecar? = nil, grace: Int? = nil) {
        offMain {
            let (installed, local) = env.installed()
            // The login race: installed Tailscale's daemon not answering yet. Looked at again
            // shortly, Kore's own not started meanwhile ("Starting KoreNet").
            if let grace, grace < Self.launchGrace.count, keep == nil, installed == .missing(.notRunning) {
                await MainActor.run {
                    guard self.generation == mine, self.env != nil else { return }
                    if grace == 0 { HostLog.note("korenet", "tailscale not answering yet", "waiting before Kore's own starts") }
                    self.graceCancel = self.schedule(Self.launchGrace[grace]) { [weak self] in
                        guard let self, self.generation == mine, self.env != nil else { return }
                        self.graceCancel = nil
                        self.choose(env, mine, grace: grace + 1)
                    }
                }
                return
            }
            var choice = TailnetChooser.chooseBeside(installed)
            var sidecar: Sidecar?
            var problem: String?
            var resealed = false
            // Kore's own already running (signing in, as the Mac's node or beside Tailscale): the
            // same node goes on as whichever it is now, its sign-in page still the one opened.
            var standby: Sidecar?
            if let keep {
                if choice.startsSidecar { sidecar = keep } else if choice == .installed { standby = keep } else { keep.stop() }
            }
            if choice.startsSidecar, sidecar == nil {
                do {
                    let started = try Self.startSidecar(env)
                    sidecar = started.sidecar
                    resealed = started.resealed
                } catch {
                    problem = "\(error)"
                }
            }
            // Beside the app, Kore's own couldn't start (a copy built without it): SSH only, as
            // before Kore's own ran beside it.
            if choice == .beside, sidecar == nil {
                HostLog.note("korenet", "own tailnet beside tailscale unavailable", problem ?? "")
                choice = TailnetChooser.fallback(installed)
                problem = nil
            }
            let (made, failure, signInAgain, chosen, waiting) = (sidecar, problem, resealed, choice, standby)
            await MainActor.run {
                guard self.generation == mine, self.env != nil else {
                    made?.stop()
                    waiting?.stop()
                    return
                }
                if signInAgain { self.tailnetSignInAgain = true }
                if let waiting {
                    if self.ownReady {
                        self.offMain { waiting.stop() }
                    } else {
                        HostLog.note("korenet", "own tailnet", "kept running beside tailscale until signed in")
                        self.standby = waiting
                        self.watchStandby(waiting.tailnet, mine)
                    }
                }
                self.chose(chosen, local: local, sidecar: made, problem: failure)
            }
        }
    }

    /// Kore's own tailnet started with its key, made on first use. A fresh key can't open state
    /// sealed under an earlier one (kept in the Keychain before 0.3.7), so that goes first; state
    /// the key still doesn't open (another Kore process's key won the race) goes once more and the
    /// start is tried again. `resealed`: a node's sign-in went with it.
    private static func routeSSH(_ tailnet: (any Tailnet)?) {
        SSHTailnetRoute.set(tailnet.map { chosen in
            let own = (chosen as? TailnetSidecar).flatMap { sidecar in NetSidecar.helper().map { (helper: $0.path, socket: sidecar.path) } }
            return SSHTailnetRoute.Current(tailnet: chosen, own: own)
        })
    }

    package nonisolated static func startSidecar(_ env: NetEnvironment) throws -> (sidecar: (tailnet: any Tailnet, stop: @Sendable () -> Void), resealed: Bool) {
        let state = env.support.appendingPathComponent("net/tailnet/state/state.sealed")
        let files = FileManager.default
        var resealed = false
        let key = try MacIdentity.tailnetKey(secrets: env.secrets) {
            resealed = files.fileExists(atPath: state.path)
            try? files.removeItem(at: state)
        }
        do {
            return (try env.sidecar(key), resealed)
        } catch let error as TailnetError where error.wrongKey {
            HostLog.note("korenet", "tailnet state", "sealed under another key: dropped, started again")
            try? files.removeItem(at: state)
            return (try env.sidecar(key), true)
        }
    }

    /// Kore's own tailnet lost its sign-in with its state (the key change): one line until it's
    /// signed in again. Kept across launches.
    package static let signInAgainKey = "koreNetTailnetSignInAgain"
    package static let signInAgainLine = "Kore's tailnet needs signing in again after the key change"

    package var tailnetSignInAgain: Bool {
        get {
            access(keyPath: \.tailnetSignInAgain)
            return defaults.bool(forKey: Self.signInAgainKey)
        }
        set {
            guard newValue != defaults.bool(forKey: Self.signInAgainKey) else { return }
            withMutation(keyPath: \.tailnetSignInAgain) { defaults.set(newValue, forKey: Self.signInAgainKey) }
        }
    }

    /// The line, while Kore's own tailnet waits for that sign-in.
    package var tailnetNote: String? {
        guard tailnetSignInAgain, state == .sidecar, status?.backendState != .running else { return nil }
        return Self.signInAgainLine
    }

    /// The sign-in line's words when Kore's own lost its sign-in with the key change (as the
    /// Mac's node, or signing in while Tailscale runs).
    package var signInAgainNote: String? {
        guard tailnetSignInAgain, state == .sidecar || state == .installed else { return nil }
        return Self.signInAgainLine
    }

    /// Signed in again: the line goes for good.
    private func signedInAgain() {
        noteOwn()
        guard state == .sidecar, status?.signedIn == true else { return }
        if tailnetSignInAgain { tailnetSignInAgain = false }
        if !ownReady { ownReady = true }
    }

    // MARK: Kore's own on this Mac, as its row says it

    nonisolated package static let ownKey = "koreNetOwnTailnet"
    nonisolated package static let ownExpiryKey = "koreNetOwnTailnetExpiry"

    /// Kore's own as last heard while it ran: signed in as whom, or signed out and why. Kept
    /// across launches, so it's known while Tailscale overrides.
    package var ownHeard: NetNodeWire.Own? {
        get {
            access(keyPath: \.ownHeard)
            return defaults.data(forKey: Self.ownKey).flatMap { try? JSONDecoder().decode(NetNodeWire.Own.self, from: $0) }
        }
        set {
            guard newValue != ownHeard else { return }
            withMutation(keyPath: \.ownHeard) { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.ownKey) }
        }
    }

    /// Kore's own on this Mac now (nil while KoreNet is off).
    package var own: NetNodeWire.Own? {
        guard env != nil else { return nil }
        switch state {
        case .sidecar:
            return ownHeard
        case .installed:
            // Overriding: Kore's own as it was left, or its sign-in waiting.
            if ownReady { return ownHeard ?? .signedIn(nil) }
            let why: NetNodeWire.Own.Why = tailnetSignInAgain ? .unreadable : (ownHeard?.why ?? .never)
            return .signedOut(why, page: ownSignIn)
        default:
            return ownHeard
        }
    }

    @ObservationIgnored private var ownExpiry: DispatchWorkItem?

    /// What Kore's own node's status says, while it's this Mac's node.
    private func noteOwn() {
        guard state == .sidecar, let status else { return }
        let page = status.authURL.flatMap { $0.hasPrefix("https://") ? $0 : nil }
        guard var next = NetNodeWire.Own.heard(
            running: status.backendState == .running, needsLogin: status.backendState == .needsLogin, login: status.login, page: page,
            keyExpiry: status.selfNode?.keyExpiry, before: ownHeard, now: Date()) else { return }
        if !next.signedIn, tailnetSignInAgain { next.why = .unreadable }
        ownSaid(next, expiry: next.signedIn ? status.selfNode?.keyExpiry : nil)
    }

    /// Kore's own changed: kept, and a signed-in node's key running out is a sign-out at that
    /// moment (no polling).
    private func ownSaid(_ next: NetNodeWire.Own, expiry: Date? = nil) {
        if next != ownHeard {
            HostLog.note("korenet", "own tailnet", next.line)
            ownHeard = next
        }
        if !next.signedIn, next.why != .never, ownReady { ownReady = false }
        if next.signedIn, let expiry { defaults.set(expiry.timeIntervalSince1970, forKey: Self.ownExpiryKey) }
        if !next.signedIn { defaults.removeObject(forKey: Self.ownExpiryKey) }
        armOwnExpiry()
    }

    private func armOwnExpiry() {
        ownExpiry?.cancel()
        ownExpiry = nil
        let at = defaults.double(forKey: Self.ownExpiryKey)
        guard at > 0, ownHeard?.signedIn == true else { return }
        let wait = at - Date().timeIntervalSince1970
        guard wait > 0 else { return ownSaid(.signedOut(.expired)) }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ownHeard?.signedIn == true else { return }
                self.ownSaid(.signedOut(.expired))
                // Overriding: Kore's own signs in again beside Tailscale.
                if self.state == .installed, let env = self.env { self.prepareOwn(env) }
            }
        }
        ownExpiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + min(wait, 400 * 86400), execute: item)
    }

    private func chose(_ choice: TailnetChooser.Choice, local: (any Tailnet)?, sidecar: Sidecar?, problem: String?) {
        // Installed Tailscale there (running, quit or signed out): its app leaving chooses again,
        // so an uninstall hands over to Kore's own tailnet with no restart; its launches and
        // quits choose again too, so the Mac moves between the app's node and Kore's own.
        self.chosen = choice
        besideRetry = 0
        watchApp(choice == .sidecar ? nil : env)
        watchRunning(env)
        watchBeside(local, beside: choice == .beside)
        switch choice {
        case .installed:
            tailnet = local
            state = .installed
        case .stopped:
            tailnet = local
            state = .stopped
        case .signedOut:
            tailnet = local
            state = .signedOut
        case .sidecar, .beside:
            if let sidecar {
                tailnet = sidecar.tailnet
                stopSidecar = sidecar.stop
                state = .sidecar
            } else {
                state = .unavailable(problem ?? "no tailnet")
            }
        }
        // Unavailable reads plainly: `chose unavailable detail="kore-tailnet: no helper in …"`.
        if case .unavailable(let why) = state {
            HostLog.note("korenet", "chose unavailable", why)
        } else {
            HostLog.note("korenet", "chose", "\(state)")
        }
        readStatus()
        if !holders.isEmpty { holdBus() }
        if state.reaches {
            // Chosen again (this Mac moved nodes): links on the old node go now, onto this one.
            let moved = relinkOnChoice
            relinkOnChoice = false
            for connection in connections() {
                if moved, connection.route == .net { connection.relink("this Mac moved tailnet nodes") } else { connection.peerOnline() }
            }
        }
        // U-b: every SSH box not on KoreNet yet upgrades now, with no window.
        if state.reaches { upgrades?.switchedOn() }
        // Tailscale runs: Kore's own signs in now if it never has, then stops (its state kept),
        // so the Mac moves to it with no sign-in the moment Tailscale stops.
        armOwnExpiry()
        if state == .installed, let env { prepareOwn(env) }
        settled?("chose")
    }

    // MARK: Installed Tailscale's app comes or goes

    @ObservationIgnored private var appWatch: (@Sendable () -> Void)?
    /// Choices made again after the app moved (tests).
    @ObservationIgnored package private(set) var rechosen = 0
    /// A choice made again: its tailnet links redial on the new node once it's up.
    @ObservationIgnored private var relinkOnChoice = false
    /// Called as this Mac is about to leave its tailnet node for another (the phones' listener).
    @ObservationIgnored package var willMove: (@MainActor () -> Void)?

    private func watchApp(_ env: NetEnvironment?) {
        appWatch?()
        appWatch = nil
        guard let env else { return }
        let mine = generation
        appWatch = env.watchApp { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.rechoose("tailscale app moved")
            }
        }
    }

    /// What was chosen last (Kore's own beside the app reads `.sidecar` in `state`).
    @ObservationIgnored private var chosen: TailnetChooser.Choice?

    // MARK: Kore's own, signed in while Tailscale runs

    /// Kore's own tailnet signed in once on this Mac (its state sealed in its folder): moving to
    /// it needs no sign-in. Kept across launches.
    nonisolated package static let ownReadyKey = "koreNetOwnTailnetReady"
    package var ownReady: Bool {
        get { defaults.bool(forKey: Self.ownReadyKey) }
        set { defaults.set(newValue, forKey: Self.ownReadyKey) }
    }
    /// While Tailscale runs and Kore's own has never signed in: its sign-in page (Devices' line).
    package private(set) var ownSignIn: String?
    /// The hold a sign-in pressed on this Mac keeps until it's signed in.
    package static let signInHold = "signin"
    package typealias Sidecar = (tailnet: any Tailnet, stop: @Sendable () -> Void)
    @ObservationIgnored private var standby: Sidecar?
    @ObservationIgnored private var standbyWatch: Task<Void, Never>?
    @ObservationIgnored private var preparing = false

    /// Starts Kore's own while Tailscale runs, only to sign it in: once its node runs, it stops,
    /// its state kept. One node of the Mac's carries traffic all along (Tailscale's): Kore's own
    /// listens for nothing meanwhile.
    private func prepareOwn(_ env: NetEnvironment) {
        guard state == .installed, !ownReady, standby == nil, !preparing else { return }
        preparing = true
        let mine = generation
        offMain {
            let started = try? Self.startSidecar(env)
            await MainActor.run {
                self.preparing = false
                guard let started else { return }
                // Its sealed state couldn't be opened (the key changed): the line says so.
                if started.resealed { self.tailnetSignInAgain = true }
                guard self.generation == mine, self.state == .installed, self.standby == nil else {
                    self.offMain { started.sidecar.stop() }
                    return
                }
                self.standby = started.sidecar
                self.watchStandby(started.sidecar.tailnet, mine)
            }
        }
    }

    private func watchStandby(_ tailnet: any Tailnet, _ mine: Int) {
        let events = tailnet.events()
        let counting = counting
        standbyWatch = Task { [weak self] in
            let first = await Self.offMain(counting) { try? tailnet.status() }
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            if self.standbyHeard(first) { return }
            for await event in events {
                guard !Task.isCancelled, self.generation == mine else { return }
                switch event {
                case .status(let status): if self.standbyHeard(status) { return }
                case .state:
                    let read = await Self.offMain(counting) { try? tailnet.status() }
                    if self.standbyHeard(read) { return }
                case .loginFinished:
                    for wait in [Duration.zero] + TailnetEvent.signInRereads {
                        if wait > .zero { try? await Task.sleep(for: wait) }
                        guard !Task.isCancelled, self.generation == mine else { return }
                        let read = await Self.offMain(counting) { try? tailnet.status() }
                        if self.standbyHeard(read) { return }
                        // The sign-in finished (`TailnetStatus.loggedIn`).
                        if let read, read.loggedIn {
                            self.ownSignedIn(read)
                            return
                        }
                    }
                default: break
                }
            }
        }
    }

    /// True once it's signed in (and stopped); else its page is kept for the line.
    private func standbyHeard(_ status: TailnetStatus?) -> Bool {
        guard let status else { return false }
        if status.signedIn {
            ownSignedIn(status)
            return true
        }
        if let page = status.authURL, !page.isEmpty, page != ownSignIn { ownSignIn = page }
        return false
    }

    private func ownSignedIn(_ status: TailnetStatus? = nil) {
        ownSaid(.signedIn(status?.login ?? ownHeard?.login), expiry: status?.selfNode?.keyExpiry)
        ownReady = true
        tailnetSignInAgain = false
        HostLog.note("korenet", "own tailnet", "signed in · stopped while Tailscale runs")
        if let stop = stopStandby() { offMain { stop() } }
        settled?("own signed in")
    }

    /// Stops watching Kore's own signing in; how it stops (run it off the main actor).
    private func stopStandby() -> (@Sendable () -> Void)? { takeStandby()?.stop }

    /// Kore's own signing in beside Tailscale, no longer watched here: stopped, or handed on.
    private func takeStandby() -> Sidecar? {
        standbyWatch?.cancel()
        standbyWatch = nil
        ownSignIn = nil
        defer { standby = nil }
        return standby
    }

    // MARK: Kore's own beside a quit or signed-out app

    @ObservationIgnored private var runWatch: (@Sendable () -> Void)?
    /// The app's bus while Kore's own runs beside it: heard only for its node coming up again.
    @ObservationIgnored private var besideBus: Task<Void, Never>?
    @ObservationIgnored private var besideRetry = 0
    @ObservationIgnored private var besideRetryCancel: (() -> Void)?
    /// When the app's daemon isn't answering beside Kore's own (quit, or not up yet at login):
    /// looked at again this many seconds apart, then only when the app is launched.
    package static let besideRetrySteps: [TimeInterval] = [2, 5, 15, 60]

    private func watchRunning(_ env: NetEnvironment?) {
        runWatch?()
        runWatch = nil
        guard let env else { return }
        let mine = generation
        runWatch = env.watchRunning { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.besideRetry = 0
                self.rechoose("tailscale app launched or quit")
            }
        }
    }

    /// Listens to the quit or signed-out app beside Kore's own: once its node runs signed in
    /// again, the Mac moves back to it (and Kore's own stops). A daemon that isn't answering is
    /// looked at again a few times (`besideRetrySteps`), then at the app's next launch.
    private func watchBeside(_ local: (any Tailnet)?, beside: Bool) {
        besideBus?.cancel()
        besideBus = nil
        besideRetryCancel?()
        besideRetryCancel = nil
        guard beside else { return }
        let mine = generation
        guard let local else { return lookAgainBeside(mine) }
        let events = local.events()
        besideBus = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.generation == mine else { return }
                if case .state(let backend) = event, TailnetChooser.chooseBeside(.state(backend)) == .installed {
                    self.rechoose("tailscale up again")
                    return
                }
            }
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.besideBus = nil
            self.lookAgainBeside(mine)
        }
    }

    /// The app's daemon isn't answering beside Kore's own: looked at again a few times, further
    /// apart each time, then only at the app's next launch.
    private func lookAgainBeside(_ mine: Int) {
        guard chosen == .beside || chosen == .stopped || chosen == .signedOut, besideRetry < Self.besideRetrySteps.count else { return }
        let seconds = Self.besideRetrySteps[besideRetry]
        besideRetry += 1
        besideRetryCancel = schedule(seconds) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.besideRetryCancel = nil
            self.rechoose("tailscale looked at again")
        }
    }

    /// Looks at installed Tailscale again (its app moved: uninstalled, or updated in place). The
    /// same choice keeps everything (the watch is armed again); a new one lets the old tailnet
    /// go (bus, Kore's own helper) and takes the new one as a first choice would: the listener
    /// looks, box links redial on it, and a box's or phone's next proof appends this Mac's new
    /// node key. Holders (a window, the popup, phones) keep holding.
    package func rechoose(_ why: String) {
        guard on, let env, state != .choosing else { return }
        let mine = generation
        offMain {
            let (installed, local) = env.installed()
            let next = TailnetChooser.chooseBeside(installed)
            await MainActor.run {
                guard self.generation == mine, self.env != nil else { return }
                guard !self.keeps(next) else {
                    // Kore's own goes on running whether the app beside it is quit, signed out or
                    // gone: the same node, no restart.
                    if next.startsSidecar, self.chosen?.startsSidecar == true { self.chosen = next }
                    self.watchApp(next == .sidecar ? nil : env)
                    self.watchRunning(env)
                    self.watchBeside(local, beside: next == .beside)
                    self.settled?("choice kept")
                    return
                }
                HostLog.note("korenet", "choose again", why)
                // Phones hear it over the old node while it's still there: they come back from
                // their quick waits on the new one, never after their 5-minute cap.
                self.willMove?()
                self.relinkOnChoice = true
                self.rechosen += 1
                self.generation += 1
                self.bus?.cancel()
                self.bus = nil
                self.cancelBusRetry()
                self.busRetry = 0
                let sidecarNet = self.state == .sidecar ? self.tailnet : nil
                self.tailnet = nil
                self.status = nil
                // Kore's own not signed in yet goes on running, so a sign-in under way isn't cut
                // off (its page stays the one opened): beside Tailscale until it's signed in, or
                // as the Mac's node again. Signed in, the Mac's node stops as before.
                var keep = self.takeStandby()
                if let stop = self.stopSidecar {
                    self.stopSidecar = nil
                    if keep == nil, !self.ownReady, let own = sidecarNet {
                        keep = (own, stop)
                    } else {
                        self.offMain { stop() }
                    }
                }
                self.state = .choosing
                self.choose(env, self.generation, keep: keep)
            }
        }
    }

    /// Whether `next` keeps what runs now: the same choice; Kore's own running beside the app or
    /// alone (it goes on); or SSH only because Kore's own can't run beside it (it still can't).
    private func keeps(_ next: TailnetChooser.Choice) -> Bool {
        guard let chosen else { return false }
        if next == chosen { return true }
        if next.startsSidecar, chosen.startsSidecar, state == .sidecar { return true }
        return next == .beside && (chosen == .stopped || chosen == .signedOut)
    }

    private func end() {
        graceCancel?()
        graceCancel = nil
        let standby = stopStandby()
        if let standby { offMain { standby() } }
        watchApp(nil)
        watchRunning(nil)
        watchBeside(nil, beside: false)
        chosen = nil
        generation += 1
        if global, HostConnection.net === self { HostConnection.net = nil }
        bus?.cancel()
        bus = nil
        cancelBusRetry()
        tailnet = nil
        status = nil
        env = nil
        upgrading = []
        if let stop = stopSidecar {
            stopSidecar = nil
            offMain { stop() }
        }
        state = .off
    }

    // MARK: The IPN bus

    package func using(_ connection: HostConnection, _ inUse: Bool) {
        hold(connection.alias, inUse)
        // A window or a link opening on a box is a fresh reach: a failed upgrade tries again.
        if inUse { upgrades?.retryFailed(connection.alias) }
    }

    /// The Devices popup (step 7) or a box window holds the bus while visible.
    package func hold(_ key: String, _ held: Bool) {
        // Sign in pressed while Tailscale runs: Kore's own runs for it if it isn't already.
        if held, key == Self.signInHold, state == .installed, let env { prepareOwn(env) }
        // A first holder: a bus that ends by itself is held again from the first step.
        if held, holders.isEmpty { busRetry = 0 }
        if held { holders.insert(key) } else { holders.remove(key) }
        if holders.isEmpty {
            bus?.cancel()
            bus = nil
            cancelBusRetry()
        } else {
            holdBus()
        }
    }

    /// A bus that ended by itself while held (Tailscale restarted, its LocalAPI went away) is
    /// held again after each of these; past them, the next hold does it (the phones' listener
    /// looks, and so holds, on wake, a network change and its own retries). Never a poll.
    package static let busRetrySteps: [TimeInterval] = [1, 5, 30, 120]
    @ObservationIgnored private var busRetry = 0
    @ObservationIgnored private var busRetryCancel: (() -> Void)?
    /// Runs `work` after `seconds` (tests: virtual time); the closure it gives back cancels.
    @ObservationIgnored package var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
    /// Buses held so far (tests).
    @ObservationIgnored package private(set) var busesHeld = 0

    private func holdBus(again: Bool = false) {
        guard bus == nil, let tailnet else { return }
        cancelBusRetry()
        busesHeld += 1
        let events = tailnet.events()
        let mine = generation
        bus = Task { [weak self] in
            var first = true
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.heard(event)
                // Held again after it ended: Tailscale may have restarted under the listener,
                // which looks again (once; cheap while it listens).
                if first, again { self.phonesLook?() }
                first = false
            }
            // A cancelled bus's tail runs after a newer one may be held: that one's handle stays.
            guard !Task.isCancelled, let self else { return }
            self.bus = nil
            self.busEnded(mine)
        }
    }

    private func busEnded(_ mine: Int) {
        guard mine == generation, !holders.isEmpty, tailnet != nil, busRetry < Self.busRetrySteps.count else { return }
        let seconds = Self.busRetrySteps[busRetry]
        busRetry += 1
        HostLog.note("korenet", "bus ended", "retry-\(Int(seconds))s")
        busRetryCancel = schedule(seconds) { [weak self] in
            guard let self, self.generation == mine, !self.holders.isEmpty else { return }
            self.busRetryCancel = nil
            self.holdBus(again: true)
        }
    }

    private func cancelBusRetry() {
        busRetryCancel?()
        busRetryCancel = nil
    }

    /// Reads the tailnet's status once, off the main actor (about 2 ms over LocalAPI): when
    /// KoreNet chooses its tailnet, and when the Devices popup or the Welcome opens. Never on a
    /// timer; a read under way takes the next ask too.
    package func readStatus() {
        guard let tailnet else { return }
        // Asked again while a read is out: that read may have been taken before what the caller
        // knows changed, so one more follows it (however many asked meanwhile).
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        let mine = generation
        offMain {
            let read = try? tailnet.status()
            await MainActor.run {
                self.reading = false
                defer {
                    if self.readAgain {
                        self.readAgain = false
                        self.readStatus()
                    }
                }
                guard self.generation == mine, self.env != nil, let read else { return }
                if read != self.status {
                    self.status = read
                    self.dialable()
                }
                self.learnPending()
                self.signedInAgain()
                // A read is as good as the bus: Tailscale stopped or signed out shows without one.
                self.follow(read.backendState)
            }
        }
    }

    private func heard(_ event: TailnetEvent) {
        let before = status?.backendState
        note(event)
        signedInAgain()
        switch event {
        case .peer(_, let key?, let online?) where online:
            for connection in connections() {
                guard let entry = directory.entry(forKey: connection.alias), isNode(key, of: entry) else { continue }
                // Up on a node that's gone (the box moved from it): the link moves now, to this one.
                if connection.route == .net, let on = linkNode[connection.alias], on != key, !peerOnline(on) {
                    connection.relink("\(entry.ssh ?? entry.name) is on another node")
                } else {
                    connection.peerOnline()
                }
            }
        case .peer(_, let key?, let online?) where !online:
            // The node a link is on went offline: checked now, so it moves as soon as the box is
            // heard on another node (or stays, should it answer).
            for connection in connections() where connection.route == .net && linkNode[connection.alias] == key {
                // Another node of the box is up (it moved there): the link goes there now.
                if let entry = directory.entry(forKey: connection.alias), entry.knownKeys.contains(where: { $0 != key && peerOnline($0) }) {
                    connection.relink("\(entry.ssh ?? entry.name) moved to another node")
                } else {
                    connection.probe("node offline")
                }
            }
        case .loginFinished:
            readStatus()
        case .peer(_, nil, false?):
            // A node removed from the tailnet (deleted in the admin console): the bus doesn't say
            // which key it had, and a link on it is dead with no word. Links on KoreNet are checked
            // now (a probe: any word back), so one on that node moves within its wait.
            for connection in connections() where connection.route == .net { connection.probe("a node left the tailnet") }
            readStatus()
        case .status where !held(parked: true).isEmpty:
            // Given up (parked): a node of the box online now dials it, whichever node that is.
            guard let status, let env else { break }
            let book = book(env)
            for connection in held(parked: true) {
                guard let entry = directory.entry(forKey: connection.alias), entry.enrolled,
                      !BoxNodes.candidates(keys: boxKeys(entry, book: book), names: boxNames(entry), status: status, others: otherKeys(entry, book: book)).isEmpty
                else { continue }
                connection.peerOnline()
            }
        case .state(let backend) where state == .sidecar:
            // Kore's own tailnet signed in (its addresses and peers), or waiting for its sign-in
            // (the page): either comes with a fresh read.
            if backend != .running || before != .running { readStatus() }
            // Just signed in: links waiting on SSH move now, not at their next retry.
            if backend == .running, before != .running { for connection in connections() { connection.peerOnline() } }
        case .state(let backend):
            follow(backend)
        default:
            break
        }
    }

    /// The installed Tailscale's backend now (the bus, or a read): KoreNet's state follows.
    private func follow(_ backend: BackendState) {
        guard state == .installed || state == .stopped || state == .signedOut else { return }
        // The app's node went down (quit, signed out): Kore's own takes over beside it.
        if state == .installed, TailnetChooser.chooseBeside(.state(backend)) == .beside { return rechoose("tailscale went down") }
        let next: NetState = switch TailnetChooser.choose(.state(backend)) {
        case .installed: .installed
        case .stopped: .stopped
        case .signedOut, .sidecar, .beside: .signedOut
        }
        guard next != state else { return }
        state = next
        chosen = switch next {
        case .installed: .installed
        case .signedOut: .signedOut
        default: .stopped
        }
        if next.reaches { for connection in connections() { connection.peerOnline() } }
    }

    /// What the bus says, kept in the cached status: a peer's online flag, the backend's state,
    /// a whole status.
    private func note(_ event: TailnetEvent) {
        switch event {
        case .status(let next):
            if next != status {
                status = next
                learnPending()
                dialable()
            }
        case .peer(_, let key?, let online?):
            guard var next = status, let i = next.peers.firstIndex(where: { $0.publicKey == key }), next.peers[i].online != online else { return }
            next.peers[i].online = online
            if !online { next.peers[i].lastSeen = Date() }
            status = next
        case .state(let backend):
            guard var next = status, next.backendState != backend else { return }
            next.backendState = backend
            status = next
        default:
            break
        }
    }

    /// A new status: links that wanted KoreNet while this Mac couldn't dial their box move now if
    /// it can.
    private func dialable() {
        guard state.reaches else { return }
        for connection in connections() { connection.netDialable() }
    }

    // MARK: Routes

    /// The Mac's own book of the devices it dials (box records pinned over SSH).
    package func book(_ env: NetEnvironment) -> DeviceBook { DeviceBook(url: env.support.appendingPathComponent("net/devices.json")) }

    /// This Mac's book now (on or off).
    package var book: DeviceBook {
        if let env { return book(env) }
        return DeviceBook(url: NodeMigration.standardRoot().appendingPathComponent("net/devices.json"))
    }

    /// A box changed in Devices: renamed (`name`), taken offline or brought online (`paused`), or
    /// removed. Its record in this Mac's book follows, and the phones hear the directory.
    package func boxChanged(_ key: String, name: String? = nil, paused: Bool? = nil, removed: Bool = false) {
        guard let entry = directory.entry(forKey: key) else { return }
        var changed = false
        _ = try? book.update { devices in
            guard let i = devices.firstIndex(where: { $0.id == entry.device && $0.kind == .box }) else { return }
            let before = devices[i]
            if removed {
                devices.remove(at: i)
            } else {
                if let name, !name.isEmpty { devices[i].name = String(name.prefix(64)) }
                if let paused { devices[i].paused = paused ? true : nil }
            }
            changed = removed || devices[i] != before
        }
        if changed { directoryChanged?() }
    }

    /// A box forgotten on this Mac, by every key it went by: an enroll under way for it is
    /// dropped when it ends, and no join sheet hears it.
    package func forgetBox(_ keys: Set<String>) {
        for key in keys {
            upgrading.remove(key)
            nodeWatchers[key] = nil
            enrollWatchers[key] = nil
        }
    }

    /// A forgotten box's records left this Mac's book: phones hear the directory without it, and
    /// boxes the record was issued to hear it went.
    package func boxForgotten(issued: Bool) {
        directoryChanged?()
        if issued { issuedChanged?() }
    }

    /// The box's node keys said over a proven link (`net.node`): each one this Mac's own tailnet
    /// shows as a node of its own user (online or not: Kore's own stops once signed in beside
    /// Tailscale) joins the box's record in this Mac's book (at most 3), so this Mac and its
    /// phones know that node is the box before the box moves onto it. Never a key another
    /// device holds, a tagged or another user's node, or an SSH-only pin's (its first dial's
    /// WhoIs gives it a user).
    private func learnKeys(_ entry: NodeDirectory.Entry, book: DeviceBook, readIfMissing: Bool = false) {
        // A key this Mac's status doesn't list yet (the box's own just signed in beside its
        // Tailscale): learned again at the next status (one read asked for now, never a loop).
        let listed = { (key: String) in self.status?.peers.contains { $0.publicKey == key } == true }
        if entry.knownKeys.allSatisfy(listed) {
            toLearn[entry.device] = nil
        } else if readIfMissing {
            toLearn[entry.device] = 0
            readStatus()
        } else if let tries = toLearn[entry.device] {
            // At most a few statuses later it's given up (the key may be a node long gone).
            toLearn[entry.device] = tries >= 10 ? nil : tries + 1
        }
        guard let status, let me = status.selfNode?.userID else { return }
        let held = Set(((try? book.record(entry.device)) ?? nil)?.nodeKeys ?? [])
        let keys = entry.knownKeys.filter { key in
            !held.contains(key) && status.peers.contains { $0.publicKey == key && $0.userID == me && $0.tags.isEmpty && !$0.shared }
        }
        guard !keys.isEmpty else { return }
        var changed = false
        _ = try? book.update { devices in
            guard let i = devices.firstIndex(where: { $0.id == entry.device && $0.kind == .box }), !devices[i].sshOnly, devices[i].userId == me else { return }
            let taken = Set(devices.filter { $0.id != entry.device }.flatMap(\.nodeKeys))
            var next = devices[i].nodeKeys
            for key in keys.reversed() where !taken.contains(key) && !next.contains(key) {
                next.append(key)
                if next.count > DeviceRecord.maxNodeKeys {
                    // The oldest goes, never one the box said it has now.
                    if let old = next.firstIndex(where: { !keys.contains($0) }) { next.remove(at: old) } else { next.removeFirst() }
                }
            }
            guard next != devices[i].nodeKeys else { return }
            devices[i].nodeKeys = next
            changed = true
        }
        if changed {
            HostLog.note(entry.ssh ?? entry.id.raw, "korenet", "knows its nodes")
            directoryChanged?()
        }
    }

    /// Boxes with a node key said that this Mac's status didn't list yet.
    @ObservationIgnored private var toLearn: [UUID: Int] = [:]

    /// A new status: keys said before it listed them are learned now.
    private func learnPending() {
        guard !toLearn.isEmpty, let env else { return }
        let book = book(env)
        for id in Array(toLearn.keys) {
            guard let entry = directory.all[id.uuidString.lowercased()] else {
                toLearn[id] = nil
                continue
            }
            learnKeys(entry, book: book)
        }
    }

    /// Every node key the Mac knows for a box: its entry's, then its record's in the book.
    package func boxKeys(_ entry: NodeDirectory.Entry, book: DeviceBook) -> [String] {
        var keys = entry.knownKeys
        for key in ((try? book.record(entry.device))??.nodeKeys ?? []).reversed() where key != Binding.Route.sshNodeKey && !keys.contains(key) { keys.append(key) }
        return keys
    }

    /// The names a box goes by on the tailnet, for finding a node of it not known yet.
    package func boxNames(_ entry: NodeDirectory.Entry) -> [String] {
        var names = [entry.name]
        if let ssh = entry.ssh, !names.contains(ssh) { names.append(ssh) }
        return names
    }

    /// Node keys other devices this Mac knows hold (never dialled as this box).
    private func otherKeys(_ entry: NodeDirectory.Entry, book: DeviceBook) -> Set<String> {
        var keys = Set(((try? book.read().devices) ?? []).filter { $0.id != entry.device }.flatMap(\.nodeKeys))
        for other in directory.all.values where other.device != entry.device { keys.formUnion(other.knownKeys) }
        return keys
    }

    /// The node the box's link is dialling now, by its tailnet name (the reconnect card's words).
    @ObservationIgnored package private(set) var dialling: [String: String] = [:]
    /// The node key each box link reached, by link key.
    @ObservationIgnored package private(set) var linkNode: [String: String] = [:]

    /// Whether a tailnet node is a box's: one of its known keys, or (none of those online) a
    /// node of this Mac's user named after it that no other device holds.
    private func isNode(_ key: String, of entry: NodeDirectory.Entry) -> Bool {
        if entry.isPeer(key) { return true }
        guard let status, let env else { return false }
        let book = book(env)
        return BoxNodes.candidates(keys: boxKeys(entry, book: book), names: boxNames(entry), status: status, others: otherKeys(entry, book: book))
            .contains { $0.key == key }
    }

    /// Links in use that gave up dialling (only an event dials them again).
    private func held(parked: Bool) -> [HostConnection] { connections().filter { $0.inUse && $0.parked == parked && !$0.isOnline } }

    private func peerOnline(_ key: String) -> Bool { status?.peers.first { $0.publicKey == key }?.online ?? false }

    package func otherNodeOnline(_ connection: HostConnection) -> Bool {
        guard let entry = directory.entry(forKey: connection.alias) else { return false }
        let on = linkNode[connection.alias]
        return entry.knownKeys.contains { $0 != on && peerOnline($0) }
    }

    package func canDial(_ connection: HostConnection) -> Bool {
        guard state.reaches, tailnet != nil, let env, let entry = directory.entry(forKey: connection.alias), entry.enrolled else { return false }
        let book = book(env)
        let keys = boxKeys(entry, book: book)
        guard let status else { return !keys.isEmpty }
        guard status.backendState == .running else { return false }
        return !BoxNodes.candidates(keys: keys, names: boxNames(entry), status: status, others: otherKeys(entry, book: book), offline: true).isEmpty
    }

    package func transport(for connection: HostConnection) -> (any HostTransport)? {
        guard state.reaches, let tailnet, let env, let entry = directory.entry(forKey: connection.alias), entry.enrolled else { return nil }
        let book = book(env)
        let keys = boxKeys(entry, book: book)
        let names = boxNames(entry)
        let others = otherKeys(entry, book: book)
        // Nothing known online (as last heard): straight to SSH, no dial that can only fail. With
        // no status read yet, the dial reads one.
        if let status, BoxNodes.candidates(keys: keys, names: names, status: status, others: others, offline: true).isEmpty { return nil }
        guard !keys.isEmpty || status != nil else { return nil }
        if pinGone(entry, book: book, connection: connection) { return nil }
        let identities = identities
        let server = entry.device
        let alias = connection.alias
        let everyNode = connection.everyNode
        let reached = Mutex<String?>(nil)
        return NetTransport(
            route: .tailnet,
            open: { [weak self] in
                let status = try tailnet.status()
                guard status.backendState == .running, let me = status.selfNode else { throw TailnetError.notRunning(status.backendState) }
                // Every node it may be on, online first: the first that takes the connection. After
                // the box's `restart`, every node it's known on at once, whatever the tailnet says.
                let candidates = everyNode
                    ? BoxNodes.every(keys: keys, names: names, status: status, others: others)
                    : BoxNodes.candidates(keys: keys, names: names, status: status, others: others, offline: true)
                guard !candidates.isEmpty else { throw TailnetError.sidecar("the box is offline") }
                var dialled: (fd: Int32, who: TailnetWhoIs, node: BoxNodes.Candidate)?
                if everyNode {
                    let (made, node) = try BoxNodes.race(candidates, close: { Sockets.closeFD($0.fd) }) { node in
                        let who = try tailnet.whois(node.address)
                        return Opening(fd: try tailnet.dial(node.address, port: NetListener.port), who: who)
                    }
                    dialled = (made.fd, made.who, node)
                } else {
                    var lastError: (any Error)?
                    for node in candidates {
                        do {
                            let who = try tailnet.whois(node.address)
                            let fd = try tailnet.dial(node.address, port: NetListener.port)
                            dialled = (fd, who, node)
                            break
                        } catch {
                            lastError = error
                        }
                    }
                    if dialled == nil { throw lastError ?? TailnetError.sidecar("the box is offline") }
                }
                guard let dialled else { throw TailnetError.sidecar("the box is offline") }
                let name = dialled.node.name
                HostLog.note(alias, "korenet dial", "\(name) \(dialled.node.address)")
                Task { @MainActor in self?.dialling[alias] = name }
                if !dialled.node.known { HostLog.note(alias, "korenet", "trying \(name), a node named after it") }
                let who = dialled.who
                reached.withLock { $0 = who.node.key }
                let identity: MacIdentity
                do {
                    identity = try identities.get(env)
                } catch {
                    Sockets.closeFD(dialled.fd)
                    throw error
                }
                let fd = dialled.fd
                var setup = NetSession.Client(
                    local: NetLocal(device: identity.device, kind: .mac, nodeKey: me.publicKey, signer: identity.signer), route: .tailnet,
                    peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId, tags: who.node.tags), book: book, server: server, service: "link")
                setup.ownUser = me.owner
                return NetTransport.Opened(fd: fd, setup: setup)
            },
            established: { [weak self, weak connection] _, append in
                Task { @MainActor in
                    guard let self, let connection else { return }
                    // Its first tailnet node key (or a new one): phones may dial it now.
                    if case .appended? = append { self.directoryChanged?() }
                    // The node it answered on, proven: kept with its others.
                    if let key = reached.withLock({ $0 }) {
                        self.directory.know(key, device: entry.device)
                        self.linkNode[connection.alias] = key
                        SSHTailnetRoute.linked(connection.sshAlias, node: key)
                    }
                    await self.welcomed(connection, id: entry.id)
                }
            })
    }

    /// A pipe's session to the node the box's link reached (proven by its welcome): this Mac's
    /// identity, service "pipe". Nil while the link isn't on the tailnet.
    package func pipeDial(for connection: HostConnection) -> (@Sendable () throws -> NetTransport.Opened)? {
        guard state.reaches, let tailnet, let env, connection.route == .net, let key = linkNode[connection.alias],
              let entry = directory.entry(forKey: connection.alias), entry.enrolled
        else { return nil }
        let book = book(env)
        let identities = identities
        let server = entry.device
        return {
            let status = try tailnet.status()
            guard status.backendState == .running, let me = status.selfNode else { throw TailnetError.notRunning(status.backendState) }
            guard let address = status.peers.first(where: { $0.publicKey == key })?.tailscaleIPs.first else {
                throw TailnetError.sidecar("the box's node is gone from the tailnet")
            }
            let who = try tailnet.whois(address)
            guard who.node.key == key else { throw TailnetError.sidecar("another node answers at the box's address") }
            let identity = try identities.get(env)
            let fd = try tailnet.dial(address, port: NetListener.port)
            var setup = NetSession.Client(
                local: NetLocal(device: identity.device, kind: .mac, nodeKey: me.publicKey, signer: identity.signer), route: .tailnet,
                peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId, tags: who.node.tags), book: book, server: server, service: "pipe")
            setup.ownUser = me.owner
            return NetTransport.Opened(fd: fd, setup: setup)
        }
    }

    /// A node's connection as a restart's race made it.
    private struct Opening: Sendable {
        var fd: Int32
        var who: TailnetWhoIs
    }

    /// Made for the SSH route while KoreNet is off (closures only: nothing runs until a dial).
    @ObservationIgnored private var sshEnvironment: NetEnvironment?

    package func sshTransport(for connection: HostConnection) -> (any HostTransport)? {
        guard let entry = directory.entry(forKey: connection.alias), entry.enrolled else { return nil }
        let env: NetEnvironment
        if let on = self.env {
            env = on
        } else if let made = sshEnvironment {
            env = made
        } else {
            env = environment()
            sshEnvironment = env
        }
        let book = book(env)
        if pinGone(entry, book: book, connection: connection) { return nil }
        let identities = identities
        let (alias, grant, command, server) = (connection.sshAlias, connection.grant, connection.sshCommand, entry.device)
        // The box's nodes now, for an alias whose host is a tailnet address (`SSHTailnetRoute`,
        // the one rule): its node offline, another of the box's; this Mac on Kore's own tailnet,
        // through it. Only with neither installed Tailscale nor Kore's own carrying this Mac is an
        // alias whose host is a tailnet address out of reach, said at once.
        let routes = state == .installed || state == .sidecar
        let tailnet = routes ? self.tailnet : nil
        let own = state == .sidecar ? (self.tailnet as? TailnetSidecar).flatMap { sidecar in NetSidecar.helper().map { (helper: $0.path, socket: sidecar.path) } } : nil
        let noRoute = on && !routes
        let (keys, names, others) = (boxKeys(entry, book: book), boxNames(entry), otherKeys(entry, book: book))
        let key = connection.alias
        return NetTransport(route: .ssh) { [weak self] in
            let identity = try identities.get(env)
            if noRoute, let host = env.hostOf(alias), BoxNodes.overTailnet(host) {
                Task { @MainActor in self?.sshNoRoute.insert(key) }
                throw TailnetError.sidecar(Self.sshNeedsTailscale)
            }
            Task { @MainActor in self?.sshNoRoute.remove(key) }
            let via = tailnet.flatMap { Self.sshHost(alias: alias, env: env, tailnet: $0, keys: keys, names: names, others: others, own: own) }
            Task { @MainActor in self?.sshVia[key] = via }
            let (fd, onClose) = try via.map { try env.upgradeDialVia(alias, grant, command, $0) } ?? env.upgradeDial(alias, grant, command)
            var setup = NetSession.Client(
                local: NetLocal(device: identity.device, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: identity.signer), route: .ssh, peer: .ssh,
                book: book, server: server, service: "link")
            // Its key, said every time over SSH: a box that holds an older one for this Mac (kept
            // in the Keychain before 0.3.7) takes this one on the grant `attach` fills in (`rekey`).
            setup.enroll = NetControl.Enroll(name: env.macName(), kind: .mac, identityKey: identity.signer.publicKey)
            return NetTransport.Opened(fd: fd, setup: setup, onClose: onClose)
        }
    }

    /// Where an SSH dial to a box goes instead of its alias's host, when that host is a tailnet
    /// address whose node is offline (or gone) and the box is online on another node of this
    /// Mac's tailnet: that node's address (`ssh -o HostName=`). Nil: the alias as it is.
    nonisolated static func sshHost(
        alias: String, env: NetEnvironment, tailnet: any Tailnet, keys: [String], names: [String], others: Set<String>,
        own: (helper: String, socket: String)? = nil
    ) -> String? {
        guard let host = env.hostOf(alias), BoxNodes.overTailnet(host), let status = try? tailnet.status(), status.backendState == .running else { return nil }
        let known = BoxNodes.candidates(keys: keys, names: names, status: status, others: others)
        // `jump` and `keyAlias` don't move the target: SSHTransport's own options carry them.
        return SSHTailnetRoute.route(host: host, jump: false, keyAlias: true, status: status, own: own, known: known).target
    }

    /// Why SSH to a box can't go now: its alias's host is on the tailnet, and only installed
    /// Tailscale routes this Mac's own connections there.
    nonisolated package static let sshNeedsTailscale = "SSH goes over Tailscale, which isn't running on this Mac"
    /// Boxes whose SSH host can't be reached now for that reason, by link key.
    @ObservationIgnored package private(set) var sshNoRoute: Set<String> = []

    /// The address an SSH dial went to instead of its alias's host, by link key (nil: the alias's).
    @ObservationIgnored package private(set) var sshVia: [String: String?] = [:]

    /// An enrolled box whose pin left this Mac's book (a Remove cut short, another Kore over the
    /// same folder): its proof can't be checked here, so every dial would end at its challenge.
    /// It isn't counted enrolled any more and its upgrade runs again: the enroll over SSH pins it
    /// anew, with the same trust as the first time, while this dial goes over SSH with the grant.
    /// An unreadable book isn't a missing pin: nothing changes.
    private func pinGone(_ entry: NodeDirectory.Entry, book: DeviceBook, connection: HostConnection) -> Bool {
        do {
            guard try book.record(entry.device) == nil else { return false }
        } catch {
            return false
        }
        directory.update { $0[entry.id.raw]?.enrolled = false }
        HostLog.note(connection.alias, "korenet", "box record missing · re-enrolling")
        directoryChanged?()
        upgrades?.repin(connection.alias)
        settled?("repin")
        return true
    }

    /// The box's first KoreNet welcome: its stores move from its alias to its id.
    private func welcomed(_ connection: HostConnection, id: NodeID) async {
        guard !NodeDirectory.isNodeKey(connection.alias) else { return }
        let outcome = await rekey(connection, to: id)
        settled?("rekey \(outcome)")
    }

    /// The box's stores move to `id`, and the node its link reached with them: known under both
    /// keys while they move, so a pipe (or a node going offline) finds it throughout.
    private func rekey(_ connection: HostConnection, to id: NodeID) async -> NodeMigration.Outcome {
        let old = connection.alias
        if let key = linkNode[old] { linkNode[id.raw] = key }
        let outcome = await rekeyer.rekey(connection, to: id, directory: directory)
        if connection.alias != old { linkNode[old] = nil }
        return outcome
    }

    /// The box forgot this Mac: not enrolled there any more, and its upgrade runs again (the box
    /// makes this Mac's grant afresh, and this Mac enrolls over it).
    package func forgotten(_ connection: HostConnection) -> Bool {
        guard let entry = directory.entry(forKey: connection.alias), entry.enrolled else { return false }
        directory.update { $0[entry.id.raw]?.enrolled = false }
        HostLog.note(connection.alias, "korenet", "the box forgot this Mac")
        directoryChanged?()
        upgrades?.reached(connection.alias, fresh: true)
        return true
    }

    package func oldKeyOnNet(_ connection: HostConnection) -> String? {
        guard let entry = directory.entry(forKey: connection.alias), entry.ssh == nil else { return nil }
        let device = defaults.string(forKey: MacIdentity.deviceKey).flatMap(UUID.init(uuidString:))
        return Self.oldKeyLine(NodeNames.name(connection.alias), mac: device)
    }

    /// A box claimed over the tailnet, with no SSH, that holds this Mac's old key: its record goes
    /// there and the box is claimed again as at first (`join`'s 10 minutes, then Allow here).
    package static func oldKeyLine(_ box: String, mac: UUID?) -> String {
        let remove = mac.map { "kore-host devices remove '\(DeviceRecord.code($0))'" } ?? "kore-host devices remove <this Mac>"
        return "\(box) has this Mac's old key · on \(box) run \(remove), then kore-host join, and Allow it here"
    }

    package func watchNode(_ key: String, _ watcher: (@MainActor (NetNodeWire.Node) -> Void)?) { nodeWatchers[key] = watcher }
    package func watchesNode(_ key: String) -> Bool { nodeWatchers[key] != nil }
    package func watchEnroll(_ key: String, _ watcher: (@MainActor (Bool) -> Void)?) { enrollWatchers[key] = watcher }

    package func said(_ node: NetNodeWire.Node, on connection: HostConnection) {
        guard let env else { return }
        defer { nodeWatchers[connection.alias]?(node) }
        let heard = NodeDirectory.heard(
            node, before: directory.entry(forKey: connection.alias), own: directory.all[node.device.uuidString.lowercased()], ssh: connection.sshAlias)
        let entry = heard.entry
        let ownBefore = directory.entry(forKey: connection.alias)?.own
        defer {
            if entry.own != ownBefore { nodeRevision += 1 }
            // A box claimed from here: its sign-in followed (New box…).
            BoxOwnFollow.shared.heard([connection.alias, entry.id.raw], own: entry.own)
        }
        if heard.refused {
            // Its row says so (Forget and set up again); nothing else is taken from it.
            if directory.all[entry.id.raw] != entry { directory.upsert(entry) }
            HostLog.note(connection.alias, "korenet refused", "the box's identity key changed")
            return
        }
        directory.update { entries in
            // One entry per alias: the device that was behind it before goes (its pause stays by
            // the alias it shares).
            if let old = heard.replaced { entries[old.id.raw] = nil }
            entries[entry.id.raw] = entry
        }
        if let old = heard.replaced {
            HostLog.audit("replaced", ["alias": connection.sshAlias, "old": old.id.raw, "device": entry.id.raw])
            // The dead box's pin goes from this Mac's book, and phones hear the directory without it.
            _ = try? book(env).update { $0.removeAll { $0.id == old.device } }
            directoryChanged?()
            // Its stores were kept under the old device's id: they move to the new one's.
            if connection.alias == old.id.raw { Task { _ = await rekey(connection, to: entry.id) } }
        }
        learnKeys(entry, book: book(env), readIfMissing: true)
        // U0: a box reached over SSH that isn't on KoreNet yet upgrades (once per state).
        let viaSSH = connection.route.map { !$0.isNet } ?? false
        defer { if viaSSH { upgrades?.reached(connection.alias, fresh: false) } }
        if entry.enrolled {
            if entry.listening { connection.preferNet() }
            return
        }
        guard connection.boxMinor >= 12, connection.control == .full, case .ssh(let alias, let grant)? = connection.route,
              upgrading.insert(connection.alias).inserted
        else { return }
        let book = book(env)
        let identities = identities
        let command = connection.sshCommand
        let key = connection.alias
        offMain {
            let outcome = await Self.enroll(env: env, identities: identities, book: book, node: node, alias: alias, grant: grant, command: command)
            await MainActor.run {
                self.upgraded(key, connection: connection, device: node.device, outcome: outcome)
            }
        }
    }

    package enum Enrolled: Equatable, Sendable {
        case enrolled
        /// The box says this Mac enrolled there already.
        case already
        case failed(String)
    }

    private func upgraded(_ key: String, connection: HostConnection, device: UUID, outcome: Enrolled) {
        // Forgotten while it enrolled: the pin it made goes again, and nothing more is kept.
        guard upgrading.remove(key) != nil, directory.all[device.uuidString.lowercased()] != nil else {
            if let env, connection.forgotten { _ = try? book(env).update { $0.removeAll { $0.id == device && $0.kind == .box } } }
            settled?("enroll forgotten")
            return
        }
        HostLog.note(key, "korenet enroll", "\(outcome)")
        if outcome == .enrolled || outcome == .already {
            directory.update { $0[device.uuidString.lowercased()]?.enrolled = true }
            directoryChanged?()
            // Its enroll over `attach --proto 2` proved this Mac's key there (taken, or re-keyed).
            connection.keyTaken()
            if outcome == .enrolled { connection.ownRouteCameUp() }
            // KoreNet off there, or this Mac's tailnet can't dial it yet (`preferNet` false: it
            // moves once it can): the link still dials again, over `attach --proto 2`, so it's
            // this Mac's proven device there (an owner Mac may switch it on).
            let moving = directory.all[device.uuidString.lowercased()]?.nodeKey != nil && connection.preferNet()
            if !moving, outcome == .enrolled { connection.relink("enrolled") }
        }
        settled?("enroll \(outcome)")
        enrollWatchers[key]?(outcome == .enrolled || outcome == .already)
    }

    /// Pins the box's identity key (the SSH route vouches for it), then enrolls this Mac once over
    /// `attach --proto 2`: the box fills in the grant (`legacyGrant`) and records this Mac as an
    /// owner device that may run. Off the main actor.
    package nonisolated static func enroll(
        env: NetEnvironment, identities: NetIdentityBox, book: DeviceBook, node: NetNodeWire.Node, alias: String, grant: String, command: String
    ) async -> Enrolled {
        let identity: MacIdentity
        do {
            identity = try identities.get(env)
            try book.update { devices in
                if let i = devices.firstIndex(where: { $0.id == node.device }) {
                    guard devices[i].identityKey == node.identityKey else { throw TrustError.refused("identity key differs") }
                    return
                }
                devices.append(
                    DeviceRecord(
                        id: node.device, name: node.name, kind: .box, abilities: [.read, .ask, .run], identityKey: node.identityKey,
                        nodeKeys: [Binding.Route.sshNodeKey], userId: nil, fqdn: "", added: Date()))
            }
        } catch {
            return .failed("\(error)")
        }
        if node.enrolled == identity.device { return .already }
        let first = await enrollOnce(env: env, identity: identity, book: book, node: node, alias: alias, grant: grant, command: command)
        // Dialled, then ended before the box answered (its pre-auth window ran out on a slow link or
        // a busy box): tried once more. A refusal, or a dial that failed, stands; nothing was used
        // on the box yet.
        guard case .failed(let why) = first, Self.mayEnrollAgain(why) else { return first }
        return await enrollOnce(env: env, identity: identity, book: book, node: node, alias: alias, grant: grant, command: command)
    }

    /// Whether an enroll that ended this way is worth one more try: only the line closing after
    /// the dial worked, or the box's own timeout. Never a dial that failed (a dead alias, SSH
    /// unreachable): nothing waits twice on that.
    package nonisolated static func mayEnrollAgain(_ why: String) -> Bool {
        why == "closed" || why == "bye " + NetControl.Reason.timeout
    }

    private nonisolated static func enrollOnce(
        env: NetEnvironment, identity: MacIdentity, book: DeviceBook, node: NetNodeWire.Node, alias: String, grant: String, command: String
    ) async -> Enrolled {
        let transport = NetTransport(route: .ssh) {
            let (fd, onClose) = try env.upgradeDial(alias, grant, command)
            var setup = NetSession.Client(
                local: NetLocal(device: identity.device, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: identity.signer), route: .ssh,
                peer: .ssh, book: book, server: node.device, service: "link")
            setup.enroll = NetControl.Enroll(name: env.macName(), kind: .mac, identityKey: identity.signer.publicKey)
            return NetTransport.Opened(fd: fd, setup: setup, onClose: onClose)
        }
        try? transport.start()
        for await event in transport.events {
            switch event {
            case .frame:
                // The welcome's proof held and the box's link speaks: enrolled.
                transport.close()
                return .enrolled
            case .closed(let why):
                return .failed(why ?? "closed")
            }
        }
        return .failed("closed")
    }
}

/// A box's stores, moved from its alias to its KoreNet id on its first KoreNet welcome, with
/// everything live kept from writing the alias back: running carries stop first
/// (`koreNodeWillRekey`), the link's copy holds its writes, Kore's usage moves in memory, then
/// `NodeMigration` moves what's on disk off the main actor; the link takes the id, and windows
/// open on the alias open on the id (`koreNodeRekeyed`).
@MainActor
package final class NodeRekeyer {
    package var migration: NodeMigration
    package var center: NotificationCenter
    /// Kore's usage in memory, moved (before the files, and after, for what came meanwhile).
    package var usage: @Sendable (String, String) async -> Void = { old, new in await KoreUsage.shared.rekeyBox(from: old, to: new) }
    private var running: Set<String> = []

    package init(migration: NodeMigration, center: NotificationCenter = .default) {
        self.migration = migration
        self.center = center
    }

    package func rekey(_ connection: HostConnection, to id: NodeID, directory: NodeDirectory) async -> NodeMigration.Outcome {
        let old = connection.alias
        let new = id.raw
        guard old != new, running.insert(old).inserted else { return .nothing }
        defer { running.remove(old) }
        center.post(name: .koreNodeWillRekey, object: nil, userInfo: ["old": old, "new": new])
        connection.holdCache()
        await usage(old, new)
        // `NodeMigration` holds UserDefaults and a test hook: it runs on one task at a time.
        let migration = Unchecked(migration)
        let outcome = await Task.detached { (try? migration.value.rekey(from: old, to: id)) ?? .waiting }.value
        guard outcome != .waiting else {
            connection.releaseCache()
            center.post(name: .koreNodeRekeyed, object: nil, userInfo: ["old": old, "new": old])
            return .waiting
        }
        directory.update { $0[new]?.rekeyed = true }
        connection.rekey(to: new)
        await usage(old, new)
        center.post(name: .koreNodeRekeyed, object: nil, userInfo: ["old": old, "new": new])
        return outcome
    }
}

/// A value handed to one other task that alone uses it.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

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
    /// Installed Tailscale, stopped: SSH only.
    case stopped
    /// Installed Tailscale, signed out: SSH only; the UI says "Sign in to Tailscale".
    case signedOut
    /// Kore's own `kore-tailnet` (no installed Tailscale, or its LocalAPI unreadable).
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
    /// This Mac's name, as a box's enroll shows it.
    package var macName: @Sendable () -> String
    /// Calls `changed` once when installed Tailscale's app leaves its place (moved to the Trash,
    /// deleted, replaced by an update): KoreNet chooses again. Nil when there's no app to watch.
    /// The closure it gives back stops watching. One descriptor, no poll.
    package var watchApp: @Sendable (_ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    package init(
        installed: @escaping @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?),
        sidecar: @escaping @Sendable (Data) throws -> (tailnet: any Tailnet, stop: @Sendable () -> Void), secrets: any NetSecrets, defaults: UserDefaults,
        support: URL, upgradeDial: @escaping @Sendable (String, String, String) throws -> (fd: Int32, onClose: @Sendable () -> Void),
        macName: @escaping @Sendable () -> String,
        watchApp: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)? = { _ in nil }
    ) {
        self.installed = installed
        self.sidecar = sidecar
        self.secrets = secrets
        self.defaults = defaults
        self.support = support
        self.upgradeDial = upgradeDial
        self.macName = macName
        self.watchApp = watchApp
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
                let sidecar = try NetSidecar.start(helper: helper, folder: support.appendingPathComponent("net/tailnet", isDirectory: true), key: key)
                return (sidecar.tailnet, { sidecar.stop() })
            },
            secrets: FileSecrets(folder: FileSecrets.folder(support: support)), defaults: defaults, support: support,
            upgradeDial: { alias, grant, command in
                let (mine, theirs) = try Sockets.pair()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: SSHTransport.ssh)
                process.arguments = SSHTransport.arguments(alias: alias, grant: grant, command: command) + ["--proto", "2"]
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
            },
            macName: { String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "Mac") },
            watchApp: { changed in AppWatch.start(LocalAPIDiscovery().appPath, changed: changed) })
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
    package private(set) var status: TailnetStatus?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: () -> NetEnvironment
    @ObservationIgnored package let directory: NodeDirectory
    @ObservationIgnored package let rekeyer: NodeRekeyer
    /// Environments made: each turn on makes one (a test checks off makes none).
    @ObservationIgnored package private(set) var made = 0
    @ObservationIgnored package private(set) var env: NetEnvironment?
    @ObservationIgnored package private(set) var tailnet: (any Tailnet)?
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
        choose(env, generation)
    }

    /// Discovery and the choice off the main actor (Kore's own tailnet started when chosen),
    /// then `chose` on it.
    private func choose(_ env: NetEnvironment, _ mine: Int) {
        Task.detached {
            let (installed, local) = env.installed()
            let choice = TailnetChooser.choose(installed)
            var sidecar: (tailnet: any Tailnet, stop: @Sendable () -> Void)?
            var problem: String?
            var resealed = false
            if choice.startsSidecar {
                do {
                    let started = try Self.startSidecar(env)
                    sidecar = started.sidecar
                    resealed = started.resealed
                } catch {
                    problem = "\(error)"
                }
            }
            let (made, failure, signInAgain) = (sidecar, problem, resealed)
            await MainActor.run {
                guard self.generation == mine, self.env != nil else {
                    made?.stop()
                    return
                }
                if signInAgain { self.tailnetSignInAgain = true }
                self.chose(choice, local: local, sidecar: made, problem: failure)
            }
        }
    }

    /// Kore's own tailnet started with its key, made on first use. A fresh key can't open state
    /// sealed under an earlier one (kept in the Keychain before 0.3.7), so that goes first; state
    /// the key still doesn't open (another Kore process's key won the race) goes once more and the
    /// start is tried again. `resealed`: a node's sign-in went with it.
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

    /// Signed in again: the line goes for good.
    private func signedInAgain() {
        if state == .sidecar, status?.backendState == .running, tailnetSignInAgain { tailnetSignInAgain = false }
    }

    private func chose(_ choice: TailnetChooser.Choice, local: (any Tailnet)?, sidecar: (tailnet: any Tailnet, stop: @Sendable () -> Void)?, problem: String?) {
        // Installed Tailscale chosen (running, stopped or signed out): its app leaving chooses
        // again, so an uninstall hands over to Kore's own tailnet with no restart.
        watchApp(choice == .sidecar ? nil : env)
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
        case .sidecar:
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
        if state.reaches { for connection in connections() { connection.peerOnline() } }
        // U-b: every SSH box not on KoreNet yet upgrades now, with no window.
        if state.reaches { upgrades?.switchedOn() }
        settled?("chose")
    }

    // MARK: Installed Tailscale's app comes or goes

    @ObservationIgnored private var appWatch: (@Sendable () -> Void)?
    /// Choices made again after the app moved (tests).
    @ObservationIgnored package private(set) var rechosen = 0

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

    /// The choice as the state shows it (`.choosing`, `.off`: none).
    private var choice: TailnetChooser.Choice? {
        switch state {
        case .installed: .installed
        case .stopped: .stopped
        case .signedOut: .signedOut
        case .sidecar, .unavailable: .sidecar
        case .off, .choosing: nil
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
        Task.detached {
            let (installed, _) = env.installed()
            let next = TailnetChooser.choose(installed)
            await MainActor.run {
                guard self.generation == mine, self.env != nil else { return }
                guard next != self.choice else {
                    self.watchApp(next == .sidecar ? nil : env)
                    self.settled?("choice kept")
                    return
                }
                HostLog.note("korenet", "choose again", why)
                self.rechosen += 1
                self.generation += 1
                self.bus?.cancel()
                self.bus = nil
                self.cancelBusRetry()
                self.busRetry = 0
                self.tailnet = nil
                self.status = nil
                if let stop = self.stopSidecar {
                    self.stopSidecar = nil
                    Task.detached { stop() }
                }
                self.state = .choosing
                self.choose(env, self.generation)
            }
        }
    }

    private func end() {
        watchApp(nil)
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
            Task.detached { stop() }
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
        Task.detached {
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
                if read != self.status { self.status = read }
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
            for connection in connections() where directory.entry(forKey: connection.alias)?.isPeer(key) == true { connection.peerOnline() }
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
        let next: NetState = switch TailnetChooser.choose(.state(backend)) {
        case .installed: .installed
        case .stopped: .stopped
        case .signedOut, .sidecar: .signedOut
        }
        guard next != state else { return }
        state = next
        if next.reaches { for connection in connections() { connection.peerOnline() } }
    }

    /// What the bus says, kept in the cached status: a peer's online flag, the backend's state,
    /// a whole status.
    private func note(_ event: TailnetEvent) {
        switch event {
        case .status(let next):
            if next != status { status = next }
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

    package func transport(for connection: HostConnection) -> (any HostTransport)? {
        guard state.reaches, let tailnet, let env, let entry = directory.entry(forKey: connection.alias), entry.enrolled, let nodeKey = entry.nodeKey
        else { return nil }
        let book = book(env)
        if pinGone(entry, book: book, connection: connection) { return nil }
        let identities = identities
        let server = entry.device
        return NetTransport(
            route: .tailnet,
            open: {
                let status = try tailnet.status()
                guard status.backendState == .running, let me = status.selfNode else { throw TailnetError.notRunning(status.backendState) }
                guard let peer = status.peers.first(where: { $0.publicKey == nodeKey }), let address = peer.tailscaleIPs.first else {
                    throw TailnetError.notTailnet(nodeKey)
                }
                guard peer.online else { throw TailnetError.sidecar("the box is offline") }
                let who = try tailnet.whois(address)
                let identity = try identities.get(env)
                let fd = try tailnet.dial(address, port: NetListener.port)
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
                    await self.welcomed(connection, id: entry.id)
                }
            })
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
        return NetTransport(route: .ssh) {
            let identity = try identities.get(env)
            let (fd, onClose) = try env.upgradeDial(alias, grant, command)
            var setup = NetSession.Client(
                local: NetLocal(device: identity.device, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: identity.signer), route: .ssh, peer: .ssh,
                book: book, server: server, service: "link")
            // Its key, said every time over SSH: a box that holds an older one for this Mac (kept
            // in the Keychain before 0.3.7) takes this one on the grant `attach` fills in (`rekey`).
            setup.enroll = NetControl.Enroll(name: env.macName(), kind: .mac, identityKey: identity.signer.publicKey)
            return NetTransport.Opened(fd: fd, setup: setup, onClose: onClose)
        }
    }

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
        let outcome = await rekeyer.rekey(connection, to: id, directory: directory)
        settled?("rekey \(outcome)")
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
    package func watchEnroll(_ key: String, _ watcher: (@MainActor (Bool) -> Void)?) { enrollWatchers[key] = watcher }

    package func said(_ node: NetNodeWire.Node, on connection: HostConnection) {
        guard let env else { return }
        defer { nodeWatchers[connection.alias]?(node) }
        let heard = NodeDirectory.heard(
            node, before: directory.entry(forKey: connection.alias), own: directory.all[node.device.uuidString.lowercased()], ssh: connection.sshAlias)
        let entry = heard.entry
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
            if connection.alias == old.id.raw { Task { _ = await rekeyer.rekey(connection, to: entry.id, directory: directory) } }
        }
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
        Task.detached {
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
            if outcome == .enrolled { connection.ownRouteCameUp() }
            if directory.all[device.uuidString.lowercased()]?.nodeKey != nil {
                connection.preferNet()
            } else if outcome == .enrolled {
                // The box's KoreNet is off: the link still dials again, over `attach --proto 2`,
                // so it's this Mac's proven device there (an owner Mac may switch it on).
                connection.relink("enrolled")
            }
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

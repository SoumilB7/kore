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

    package init(
        installed: @escaping @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?),
        sidecar: @escaping @Sendable (Data) throws -> (tailnet: any Tailnet, stop: @Sendable () -> Void), secrets: any NetSecrets, defaults: UserDefaults,
        support: URL, upgradeDial: @escaping @Sendable (String, String, String) throws -> (fd: Int32, onClose: @Sendable () -> Void),
        macName: @escaping @Sendable () -> String
    ) {
        self.installed = installed
        self.sidecar = sidecar
        self.secrets = secrets
        self.defaults = defaults
        self.support = support
        self.upgradeDial = upgradeDial
        self.macName = macName
    }

    /// The Mac's own: LocalAPI discovery, `Contents/Helpers/kore-tailnet`, the Keychain, ssh.
    package static func standard(defaults: UserDefaults = .standard) -> NetEnvironment {
        let support = NodeMigration.standardRoot()
        return NetEnvironment(
            installed: {
                let api = LocalAPIClient()
                if case .unavailable(let why) = api.current { return (.missing(why), nil) }
                let local = TailnetLocal(api: api)
                guard let status = try? local.status() else { return (.missing(.unreadable), nil) }
                return (.state(status.backendState), local)
            },
            sidecar: { key in
                guard let helper = NetSidecar.helper() else { throw TailnetError.sidecar("Kore's tailnet helper isn't here") }
                let sidecar = try NetSidecar.start(helper: helper, folder: support.appendingPathComponent("net/tailnet", isDirectory: true), key: key)
                return (sidecar.tailnet, { sidecar.stop() })
            },
            secrets: KeychainSecrets(), defaults: defaults, support: support,
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
            macName: { String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "Mac") })
    }
}

/// This Mac's identity, read from the Keychain once, off the main actor, on first need.
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
    /// This Mac's identity while on (read from the Keychain once, off the main actor). The
    /// phones' listener (`MacNet`, KoreLink) reads it too.
    @ObservationIgnored package private(set) var identities = NetIdentityBox()
    @ObservationIgnored private var upgrading: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    /// A join sheet's ears: what each box says on KoreNet, and how its enroll ended.
    @ObservationIgnored private var nodeWatchers: [String: @MainActor (NetNodeWire.Node) -> Void] = [:]
    @ObservationIgnored private var enrollWatchers: [String: @MainActor (Bool) -> Void] = [:]
    /// Every bus subscription held now (tests).
    @ObservationIgnored package var busHeld: Bool { bus != nil }
    /// Finished upgrades and choices (tests wait on them).
    @ObservationIgnored package var settled: (@MainActor (String) -> Void)?

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
        let mine = generation
        state = .choosing
        holders = Set(connections().filter(\.inUse).map(\.alias))
        if global { HostConnection.net = self }
        Task.detached {
            let (installed, local) = env.installed()
            let choice = TailnetChooser.choose(installed)
            var sidecar: (tailnet: any Tailnet, stop: @Sendable () -> Void)?
            var problem: String?
            if choice.startsSidecar {
                do {
                    sidecar = try env.sidecar(try MacIdentity.tailnetKey(secrets: env.secrets))
                } catch {
                    problem = "\(error)"
                }
            }
            let (made, failure) = (sidecar, problem)
            await MainActor.run {
                guard self.generation == mine, self.env != nil else {
                    made?.stop()
                    return
                }
                self.chose(choice, local: local, sidecar: made, problem: failure)
            }
        }
    }

    private func chose(_ choice: TailnetChooser.Choice, local: (any Tailnet)?, sidecar: (tailnet: any Tailnet, stop: @Sendable () -> Void)?, problem: String?) {
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
        HostLog.note("korenet", "chose", "\(state)")
        readStatus()
        if !holders.isEmpty { holdBus() }
        if state.reaches { for connection in connections() { connection.peerOnline() } }
        settled?("chose")
    }

    private func end() {
        generation += 1
        if global, HostConnection.net === self { HostConnection.net = nil }
        bus?.cancel()
        bus = nil
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

    package func using(_ connection: HostConnection, _ inUse: Bool) { hold(connection.alias, inUse) }

    /// The Devices popup (step 7) or a box window holds the bus while visible.
    package func hold(_ key: String, _ held: Bool) {
        if held { holders.insert(key) } else { holders.remove(key) }
        if holders.isEmpty {
            bus?.cancel()
            bus = nil
        } else {
            holdBus()
        }
    }

    private func holdBus() {
        guard bus == nil, let tailnet else { return }
        let events = tailnet.events()
        bus = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.heard(event)
            }
            self?.bus = nil
        }
    }

    /// Reads the tailnet's status once, off the main actor (about 2 ms over LocalAPI): when
    /// KoreNet chooses its tailnet, and when the Devices popup or the Welcome opens. Never on a
    /// timer; a read under way takes the next ask too.
    package func readStatus() {
        guard let tailnet, !reading else { return }
        reading = true
        let mine = generation
        Task.detached {
            let read = try? tailnet.status()
            await MainActor.run {
                self.reading = false
                guard self.generation == mine, self.env != nil, let read else { return }
                if read != self.status { self.status = read }
            }
        }
    }

    private func heard(_ event: TailnetEvent) {
        let before = status?.backendState
        note(event)
        switch event {
        case .peer(_, let key?, let online?) where online:
            for connection in connections() where directory.entry(forKey: connection.alias)?.nodeKey == key { connection.peerOnline() }
        case .state(.running) where state == .sidecar && before != .running:
            // Kore's own tailnet signed in: its addresses and peers come with a fresh read.
            readStatus()
        case .state(let backend):
            guard state != .sidecar, state != .off else { return }
            let next: NetState = switch TailnetChooser.choose(.state(backend)) {
            case .installed: .installed
            case .stopped: .stopped
            case .signedOut, .sidecar: .signedOut
            }
            guard next != state else { return }
            state = next
            if next.reaches { for connection in connections() { connection.peerOnline() } }
        default:
            break
        }
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

    package func transport(for connection: HostConnection) -> (any HostTransport)? {
        guard state.reaches, let tailnet, let env, let entry = directory.entry(forKey: connection.alias), entry.enrolled, let nodeKey = entry.nodeKey
        else { return nil }
        let book = book(env)
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
            established: { [weak self, weak connection] _, _ in
                Task { @MainActor in
                    guard let self, let connection else { return }
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
        let identities = identities
        let (alias, grant, command, server) = (connection.sshAlias, connection.grant, connection.sshCommand, entry.device)
        return NetTransport(route: .ssh) {
            let identity = try identities.get(env)
            let (fd, onClose) = try env.upgradeDial(alias, grant, command)
            let setup = NetSession.Client(
                local: NetLocal(device: identity.device, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: identity.signer), route: .ssh, peer: .ssh,
                book: book, server: server, service: "link")
            return NetTransport.Opened(fd: fd, setup: setup, onClose: onClose)
        }
    }

    /// The box's first KoreNet welcome: its stores move from its alias to its id.
    private func welcomed(_ connection: HostConnection, id: NodeID) async {
        guard !NodeDirectory.isNodeKey(connection.alias) else { return }
        let outcome = await rekeyer.rekey(connection, to: id, directory: directory)
        settled?("rekey \(outcome)")
    }

    package func watchNode(_ key: String, _ watcher: (@MainActor (NetNodeWire.Node) -> Void)?) { nodeWatchers[key] = watcher }
    package func watchEnroll(_ key: String, _ watcher: (@MainActor (Bool) -> Void)?) { enrollWatchers[key] = watcher }

    package func said(_ node: NetNodeWire.Node, on connection: HostConnection) {
        guard let env else { return }
        defer { nodeWatchers[connection.alias]?(node) }
        let before = directory.entry(forKey: connection.alias)
        if let before, before.device == node.device, before.identityKey != node.identityKey {
            HostLog.note(connection.alias, "korenet refused", "the box's identity key changed")
            return
        }
        var entry = before ?? NodeDirectory.Entry(device: node.device, name: node.name, ssh: connection.sshAlias, nodeKey: nil, identityKey: node.identityKey)
        if entry.device != node.device {
            // Another box behind the same alias: a new entry, never the old one's trust.
            entry = NodeDirectory.Entry(device: node.device, name: node.name, ssh: connection.sshAlias, nodeKey: nil, identityKey: node.identityKey)
        }
        entry.name = node.name
        entry.nodeKey = node.on ? node.nodeKey : nil
        directory.upsert(entry)
        if entry.enrolled {
            if entry.nodeKey != nil { connection.preferNet() }
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
        upgrading.remove(key)
        HostLog.note(key, "korenet enroll", "\(outcome)")
        if outcome == .enrolled || outcome == .already {
            directory.update { $0[device.uuidString.lowercased()]?.enrolled = true }
            if outcome == .enrolled { connection.ownRouteCameUp() }
            if directory.all[device.uuidString.lowercased()]?.nodeKey != nil { connection.preferNet() }
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

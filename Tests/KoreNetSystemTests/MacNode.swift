import Foundation
import Observation
import HostClient
import KoreHost
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet

@testable import KoreLink
@testable import KoreUI

/// The boxes' SSH ends by alias, for the Mac's `upgradeDial` (read off the main actor), routed
/// as ssh is: each alias's host (`ssh -G`) is a LAN or public address (`lan`: reachable while the
/// box is) or a tailnet address, reachable while this Mac has a route there (installed
/// Tailscale running, or Kore's own: `SSHTailnetRoute`'s `kore-tailnet nc`) and that node is
/// online; a box's own userspace node takes SSH too (`OwnSSHForward`).
final class SSHRoutes: Sendable {
    static let lan = "lan"
    private let routes = Mutex<[String: InProcessAttach]>([:])
    private let hosts = Mutex<[String: String]>([:])
    /// Every dial's host, newest last (`via` the address it went to instead of the alias's).
    let dialled = Mutex<[String]>([])
    private let net: SharedTailnet
    private let macRoutes: @Sendable () -> Bool

    init(net: SharedTailnet, macRoutes: @escaping @Sendable () -> Bool) {
        self.net = net
        self.macRoutes = macRoutes
    }

    func set(_ alias: String, _ attach: InProcessAttach) { routes.withLock { $0[alias] = attach } }
    /// What the alias's `HostName` is (default `lan`).
    func setHost(_ alias: String, _ host: String) { hosts.withLock { $0[alias] = host } }
    func host(_ alias: String) -> String { hosts.withLock { $0[alias] } ?? Self.lan }

    func routable(_ host: String) -> Bool {
        guard host != Self.lan else { return true }
        guard macRoutes(), let node = net.node(host) else { return false }
        return node.online && !node.dark && node.kind == .box
    }

    func reachable(_ alias: String) -> Bool { routable(host(alias)) && routes.withLock({ $0[alias] })?.reachable.withLock({ $0 }) != false }

    func dial(_ alias: String, via: String? = nil) throws -> (fd: Int32, onClose: @Sendable () -> Void) {
        let target = via ?? host(alias)
        dialled.withLock { $0.append(target) }
        guard routable(target), let attach = routes.withLock({ $0[alias] }) else { throw SocketError.failed("ssh: connect to host \(target)", ETIMEDOUT) }
        return try attach.dial()
    }
}

/// Kore.app's KoreNet as it runs, made the way `NetLiveness.start` and `main.swift` make it: the
/// real `KoreNetSwitch` (global, routing every held link), `NodeDirectory`, `NodeRekeyer`, the
/// phones' listener `MacNet` following the switch (`MacNetSwitch.follow`), `MacNetDevices`, and
/// `Devices.shared` over all of them. Kore's settings are the test process's own defaults
/// (Kore reads `.standard` and `BoxList.shared`/`NetPauses.shared` can't be given others); the
/// Keychain is memory that outlives a restart, Application Support a scratch folder. A restart
/// drops every object and makes them again from what was kept.
@MainActor
final class MacNode {
    /// Installed Tailscale's node, and Kore's own (`kore-tailnet`) once the app is gone: a new
    /// node key and address for the same Mac, signed in as the same user.
    let installedIP = "100.64.0.1"
    let installedKey = "nodekey:mac"
    let ownIP = "100.64.0.250"
    let ownKey = "nodekey:mac-kore"
    /// The node this Mac is on now.
    var ip: String { switcher?.state == .sidecar ? ownIP : installedIP }
    var nodeKey: String { switcher?.state == .sidecar ? ownKey : installedKey }
    /// Installed Tailscale's app is in /Applications (an uninstall takes it away).
    private let app: TailscaleApp
    let root: URL
    let support: URL
    let defaults = UserDefaults.standard
    let secrets = MemorySecrets()
    let net: SharedTailnet
    let pulse: Pulse
    let clock: VirtualClock
    let ssh: SSHRoutes
    /// The SSH boxes this Mac set up, by alias (their links' transports).
    private(set) var sshBoxes: [String: BoxNode] = [:]

    private(set) var switcher: KoreNetSwitch!
    private(set) var upgrades: BoxUpgrades!
    /// `kore-host upgrade` runs, by box alias (I25).
    private(set) var upgradeRuns: [String: Int] = [:]
    private(set) var directory: NodeDirectory!
    private(set) var macNet: MacNet!
    private(set) var asks: DeviceAsks!
    /// Each box link made this run, by the key it was made under.
    private(set) var links: [HostConnection] = []
    /// Allow cards shown and not answered.
    private(set) var cards: [DeviceCardInfo] = []
    private(set) var audits: [String] = []
    private var auditWatch: UUID?
    /// Traced events, audit lines among them, at their virtual times (KNS_DEBUG prints them).
    private(set) var traced: [String] = []
    func trace(_ line: String) { traced.append("\(clock.nowMS / 1000)s \(line)") }
    private(set) var starts = 0
    /// Windows open now, by box key.
    private(set) var windows: [String: HostConnection] = [:]
    /// The Devices popup is open (it holds the bus).
    private(set) var popupOpen = false
    /// The Mac's wake and network changes, made as `NetLiveness` and `NetworkWatch` make them
    /// (their default hooks), on a center and a path of the test's own.
    let wakeCenter = NotificationCenter()
    static let woke = Notification.Name("KNSWoke")
    private var wake: LinkWake?
    private var paths: PathChanges?
    private var interfaces = 0

    init(root: URL, net: SharedTailnet, pulse: Pulse, clock: VirtualClock) {
        self.root = root
        support = root.appendingPathComponent("Kore", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.net = net
        self.pulse = pulse
        self.clock = clock
        let app = TailscaleApp()
        self.app = app
        let ip = "100.64.0.1"
        // A route to tailnet addresses: installed Tailscale running, or Kore's own (its node up).
        let ownIP = "100.64.0.250"
        ssh = SSHRoutes(net: net) { (app.present && net.node(ip)?.state == .running) || net.node(ownIP)?.state == .running }
        net.add(SharedTailnet.Node(name: "macbook", kind: .mac, ip: installedIP, nodeKey: installedKey, bindIP: installedIP))
    }

    /// Kore launches: as `NetLiveness.start`, KoreNet on as it was left.
    func launch() {
        starts += 1
        let tailnet = NodeNet(net, ip: installedIP)
        let shared = net
        let (ip, ownIP, ownKey) = (installedIP, ownIP, ownKey)
        let ssh = ssh
        let app = app
        let env = NetEnvironment(
            installed: {
                // Uninstalled: what it left behind reads absent (`LocalAPIDiscovery`).
                guard app.present else { return (.missing(.absent), nil) }
                guard app.answering else { return (.missing(.notRunning), nil) }
                let state = shared.node(ip)?.state ?? .noState
                return (.state(state), tailnet)
            },
            sidecar: { _ in
                app.ownStarted()
                // Kore's own node: new the first time (waiting for its one sign-in), as it was
                // left after that (its state sealed under the Keychain's key).
                if shared.node(ownIP) == nil {
                    shared.add(SharedTailnet.Node(name: "macbook-1", kind: .mac, ip: ownIP, nodeKey: ownKey, state: .needsLogin, bindIP: ownIP))
                } else {
                    shared.setState(ownIP, app.ownSignedIn ? .running : .needsLogin)
                }
                return (NodeNet(shared, ip: ownIP), { shared.setState(ownIP, .stopped) })
            },
            secrets: secrets, defaults: defaults, support: support,
            upgradeDial: { alias, _, _ in try ssh.dial(alias) }, macName: { "MacBook" },
            watchApp: { app.watch($0) },
            upgradeDialVia: { alias, _, _, host in try ssh.dial(alias, via: host) },
            hostOf: { ssh.host($0) == SSHRoutes.lan ? "192.168.1.20" : ssh.host($0) })
        directory = NodeDirectory(defaults: defaults)
        NodeDirectory.shared = directory
        let rekeyer = NodeRekeyer(migration: NodeMigration(root: support, defaults: defaults), center: NotificationCenter())
        rekeyer.usage = { _, _ in }
        switcher = KoreNetSwitch(defaults: defaults, directory: directory, rekeyer: rekeyer, environment: { env })
        KoreNetSwitch.shared = switcher
        HostConnection.sshNet = switcher
        let pulse = pulse
        switcher.settled = { _ in pulse.beat() }
        // Its work off the main actor (a sidecar's start, a status read), counted while under way.
        switcher.counting = { $0 ? pulse.began() : pulse.ended() }
        // The box list's copies, rekey journals and book are this world's, never Kore's real
        // Application Support (a Remove deletes them).
        BoxList.shared.cacheRoot = support.appendingPathComponent("hosts", isDirectory: true)
        BoxList.shared.reload()
        // As `NetLiveness.start`: KoreNet's leftovers of boxes no longer listed go.
        BoxList.shared.dropOrphans()
        // Every box this Mac lists gets its link object (asleep: no window holds it).
        for box in BoxList.shared.boxes { makeLink(box.alias) }
        // SSH boxes move to KoreNet by themselves (§2g): `kore-host upgrade` runs on the box in
        // this process, as ssh would carry it.
        let upgrades = BoxUpgrades()
        let clock = clock
        upgrades.directory = directory
        upgrades.sleep = clock.sleep
        upgrades.now = { Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(Double(clock.nowMS) / 1000) }
        upgrades.shell = BoxUpgradeShell(
            upgrade: { [weak self] alias, _, grant, want in
                await self?.upgradeOnBox(alias, grant: grant, want: want) ?? BoxRan(status: 255, output: "ssh: no route")
            },
            push: { _, _ in BoxSetup.Failure(message: "no push here") })
        switcher.upgrades = upgrades
        Devices.shared.upgrades = upgrades
        Devices.shared.joinRunner = { upgrades.runner(for: $0) }
        self.upgrades = upgrades
        switcher.start()
        asks = DeviceAsks()
        asks.present = { [weak self] info, _ in
            self?.cards.append(info)
            pulse.beat()
        }
        asks.dismiss = { pulse.beat() }
        // The real glue (`MacNetSwitch.install` + `follow`), with the listener's clock on virtual
        // time (its pre-auth limit of 3 a minute per address counts the world's minutes).
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        MacNetSwitch.install()
        macNet = MacNetSwitch.follow(switcher, feed: LinkFeed(source: EmptySource(), taps: false), asks: asks) {
            base.addingTimeInterval(Double(clock.nowMS) / 1000)
        }
        // Traced (KNS_DEBUG): box links' catch-ups and the holds for a push.
        let catchUp = HostConnection.devicesCatchUp
        HostConnection.devicesCatchUp = { [weak self] link in
            self?.trace("catchUp \(link.alias.prefix(6)) online=\(link.isOnline) merge=\(link.takesMerge) peer=\(link.boxPeer != nil) route=\(String(describing: link.route)) dial=\(link.dialNumber)")
            catchUp?(link)
        }
        let reach = macNet.reachBox
        macNet.reachBox = { [weak self] key in
            let release = reach(key)
            self?.trace("reach \(key.prefix(6)) held=\(release != nil)")
            guard let release else { return nil }
            return { [weak self] in
                self?.trace("release \(key.prefix(6))")
                release()
            }
        }
        // Its timers (the Add window's end, a resumed phone's cursor wait) on virtual time too.
        macNet.schedule = { seconds, work in
            let task = Task { @MainActor in
                await clock.wait(.milliseconds(Int64(seconds * 1000)))
                if !Task.isCancelled { work() }
            }
            return { task.cancel() }
        }
        asks.schedule = macNet.schedule
        // Its work off the main actor (binds, WhoIs, the Keychain read), counted while under way.
        macNet.background = { work in
            pulse.began()
            DispatchQueue.global(qos: .utility).async {
                work()
                pulse.ended()
            }
        }
        MacNet.shared = macNet
        macNet.changed = { [weak self] what in
            self?.trace("macnet \(what)")
            pulse.beat()
        }
        switcher.schedule = macNet.schedule
        wake = LinkWake(center: wakeCenter, name: Self.woke)
        let paths = PathChanges(wait: .seconds(1))
        paths.sleep = clock.sleep
        paths.observe(.init(satisfied: true, interfaces: ["en0"]))
        self.paths = paths
        HostLog.tap = { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trace("log " + line) } }
        }
        auditWatch = NetAudit.watch { [weak self] line in
            self?.audits.append(line)
            self?.trace("audit " + line)
            pulse.beat()
        }
        Devices.shared.phones = MacNetDevices()
        Devices.shared.macNameOverride = "MacBook"
        Devices.shared.boxes = nil
        Devices.shared.net = nil
        pulse.beat()
    }

    /// A box link as Kore makes it (`HostConnection.named`), over the box's SSH `attach --as`.
    @discardableResult
    func makeLink(_ key: String) -> HostConnection? {
        let alias = directory.sshAlias(forKey: key) ?? key
        guard let box = sshBoxes[alias] else { return nil }
        let grant = box.grant!
        let path = box.paths.socket.path
        let ssh = ssh
        let connection = HostConnection(alias: key, grant: "laptop", cache: HostCache(alias: key, root: support.appendingPathComponent("hosts"))) {
            DaemonTransport(path: path, grant: grant) { ssh.reachable(alias) }
        }
        connection.router = switcher
        connection.sleep = clock.sleep
        let pulse = pulse
        connection.onLink("world") { [weak self, weak connection] up in
            if let connection {
                self?.trace("link \(connection.alias.prefix(6)) \(up ? "up" : "down") phase=\(connection.phase) route=\(String(describing: connection.route)) users=\(connection.inUse) reason=\(connection.lastReason ?? "-")")
            }
            pulse.beat()
        }
        HostConnection.adopt(connection)
        // Made, but no window holds it: asleep.
        connection.release()
        links.append(connection)
        return connection
    }

    /// Kore quits (the process ends: its sockets just go) and launches again from what it kept.
    func restart() {
        quit()
        launch()
    }

    /// The owner quits installed Tailscale, then drags it to the Trash: what's left of it reads
    /// absent, and the app's watch fires.
    func uninstallTailscale() { app.uninstall() }

    /// Installed Tailscale's daemon answers (or not, as at login before it's up).
    func tailscaleAnswers(_ answering: Bool) { app.answering = answering }
    var ownStarts: Int { app.ownStarts }

    /// Kore 0.3.7's update: the identity key read from the Keychain before is gone, a new one is
    /// made in its file (same device id); with `losePins`, the boxes' pins left this Mac's book
    /// too (as found on the owner's Mac, 2026-11-23).
    func newIdentityKey(losePins: Bool) {
        try? secrets.write(SoftwareIdentity().raw, MacIdentity.identityAccount)
        guard losePins else { return }
        _ = try? DeviceBook(url: support.appendingPathComponent("net/devices.json")).update { $0.removeAll { $0.kind == .box } }
    }

    /// The one browser sign-in of Kore's own tailnet.
    func signInOwnTailnet() {
        app.ownSignedIn = true
        net.setState(ownIP, .running)
    }

    /// The Mac wakes from sleep.
    func wakeUp() { wakeCenter.post(name: Self.woke, object: nil) }

    /// Its network path changes (Wi-Fi to another Wi-Fi).
    func networkChanged() {
        interfaces += 1
        paths?.observe(.init(satisfied: true, interfaces: ["en\(interfaces)"]))
    }

    func quit() {
        wake = nil
        paths = nil
        net.cut(ip)
        for (key, connection) in windows {
            while connection.inUse { connection.release() }
            windows[key] = nil
        }
        for connection in links { while connection.inUse { connection.release() } }
        links = []
        // Its switch isn't turned off (a quit, not the owner's switch): retired, its state's
        // changes can't have it bind the port again.
        macNet?.retire()
        MacNet.shared = nil
        NetAudit.unwatch(auditWatch)
        if KoreNetSwitch.shared === switcher { KoreNetSwitch.shared = nil }
        if HostConnection.sshNet === switcher { HostConnection.sshNet = nil }
        if HostConnection.net === switcher { HostConnection.net = nil }
        switcher = nil
        macNet = nil
        Devices.shared.phones = nil
        popupOpen = false
        cards = []
    }

    /// `kore-host upgrade --grant <grant>` on the box, over its SSH (unreachable: ssh's own failure).
    func upgradeOnBox(_ alias: String, grant: String, want: String?) async -> BoxRan {
        guard let box = sshBoxes[alias], ssh.reachable(alias), let host = box.host else {
            return BoxRan(status: 255, output: "ssh: connect to host \(alias) port 22: Operation timed out")
        }
        upgradeRuns[alias, default: 0] += 1
        let paths = box.paths
        let up = net.node(box.ip)?.state == .running
        // A box with both on Kore's own now (no Tailscale yet, or it's down): as `upgrade` reads it there.
        let onOwn = box.beside && host.net?.userspace == true
        let ownUp = net.node(box.ownIP)?.state == .running
        let tailscale: HostUpgrade.Tailscale = box.own
            ? .kore(up ? .running(node: box.nodeKey, account: "me@example.com") : .signIn("https://login.example/a/\(alias)"))
            : onOwn ? .kore(ownUp ? .running(node: box.ownKey, account: "me@example.com") : .signIn("https://login.example/a/\(alias)"))
            : up ? .running(node: box.nodeKey) : .stopped(.stopped, login: nil)
        let report = HostUpgrade(
            paths: paths, update: { nil }, service: { .running }, installService: { [] }, startDaemon: { true }, linger: { true },
            tailscale: { _ in tailscale }, reload: { MainActor.assumeIsolated { host.reloadNet() } }, listen: { _ in nil }
        ).run(want: want, grant: grant)
        await host.net?.settled()
        pulse.beat()
        return BoxRan(status: report.exit, output: report.text.joined(separator: "\n"))
    }

    // MARK: Set up over SSH (before KoreNet)

    /// "Add a box…" with an SSH alias that runs kore-host (`kore-host allow laptop` done).
    func addSSHBox(_ box: BoxNode) {
        sshBoxes[box.alias] = box
        ssh.set(box.alias, box.attach)
        BoxList.shared.add(box.alias)
        makeLink(box.alias)
    }

    /// Removed in Devices: this Mac no longer sets it up (the box itself stays, and SSH reaches it).
    func forgot(_ box: BoxNode) { sshBoxes[box.alias] = nil }

    /// The box's link object now (its alias, or its id once rekeyed).
    func link(_ box: BoxNode) -> HostConnection? {
        let key = HostConnection.current(box.alias)
        return links.last { $0.alias == key } ?? links.last { $0.alias == box.alias }
    }

    // MARK: What the owner does

    /// A box window opens (holds the link) or closes.
    func openWindow(_ box: BoxNode, onScreen: Bool = false) {
        guard let connection = link(box) else { return }
        windows[connection.alias] = connection
        connection.retain()
        if onScreen { connection.onScreen("window", true) }
    }

    /// The box's window comes on screen or leaves it (hidden, minimised, covered).
    func showWindow(_ box: BoxNode, _ shown: Bool) { link(box)?.onScreen("window", shown) }

    func closeWindow(_ box: BoxNode) {
        guard let connection = link(box), connection.inUse else { return }
        windows[connection.alias] = nil
        connection.onScreen("window", false)
        connection.release()
    }

    /// The Devices popup opens: it holds the bus and reads the status once (as the view does).
    func openPopup() {
        guard !popupOpen else { return }
        popupOpen = true
        switcher.hold("popup", true)
        switcher.readStatus()
    }

    func closePopup() {
        guard popupOpen else { return }
        popupOpen = false
        switcher.hold("popup", false)
    }

    /// The Allow card's answer.
    func answerCard(_ allow: Bool) {
        guard !cards.isEmpty else { return }
        cards.removeFirst()
        asks.answer(allow)
    }

    // MARK: What it holds

    var identity: MacIdentity { try! MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults) }

    /// This Mac as a phone pins it on first contact.
    var record: DeviceRecord {
        let id = identity
        return DeviceRecord(
            id: id.device, name: "MacBook", kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: id.signer.publicKey, nodeKeys: [nodeKey],
            userId: 7, fqdn: "macbook.tail.ts.net.", added: Date(timeIntervalSince1970: 0))
    }

    /// The Mac's own device book (boxes it dials, phones it allowed).
    /// Off, there's no book (KoreNet's own folder is only read while on: the switch's fallback
    /// is Kore's real Application Support, never read here).
    var book: [DeviceRecord] {
        guard let switcher, let env = switcher.env else { return [] }
        return (try? switcher.book(env).read().devices) ?? []
    }
    var phones: [DeviceRecord] { book.filter { $0.kind == .phone } }

    /// The boxes a phone's welcome lists now: boxes in the book with a tailnet node key.
    var listedBoxes: [DeviceRecord] {
        book.filter { $0.kind == .box && !$0.isPaused && $0.nodeKeys.contains { $0 != Binding.Route.sshNodeKey } }
    }
}

/// Installed Tailscale's app on the test Mac, and its watch (`AppWatch` in Kore).
final class TailscaleApp: @unchecked Sendable {
    private let lock = NSLock()
    private var installed = true
    private var signedIn = false
    private var daemon = true
    private var owns = 0
    /// Kore's own started on this Mac so far (as its node or to sign in beside Tailscale).
    var ownStarts: Int { lock.withLock { owns } }
    func ownStarted() { lock.withLock { owns += 1 } }
    private var changed: (@Sendable () -> Void)?
    /// Its daemon answers its LocalAPI (false: at login, before tailscaled is up).
    var answering: Bool {
        get { lock.withLock { daemon } }
        set { lock.withLock { daemon = newValue } }
    }

    var present: Bool { lock.withLock { installed } }
    var ownSignedIn: Bool {
        get { lock.withLock { signedIn } }
        set { lock.withLock { signedIn = newValue } }
    }

    func watch(_ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        lock.withLock {
            guard installed else { return nil }
            self.changed = changed
            return { [weak self] in self?.lock.withLock { self?.changed = nil } }
        }
    }

    func uninstall() {
        let fire = lock.withLock { () -> (@Sendable () -> Void)? in
            installed = false
            defer { changed = nil }
            return changed
        }
        fire?()
    }
}

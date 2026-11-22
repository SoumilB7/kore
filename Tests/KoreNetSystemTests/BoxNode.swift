import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet

@testable import KoreHost

/// A reference handed to the tailnet's queues, read on the main actor only.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// A box: a real `HostDaemon` (kore-host) with its own state folder, its `HostNet` on the shared
/// tailnet, the grant an SSH box was set up with, and `attach --proto 2` in process. It restarts
/// from the same folder.
@MainActor
final class BoxNode {
    let alias: String
    let root: URL
    let paths: HostPaths
    let ip: String
    let nodeKey: String
    let net: SharedTailnet
    private(set) var host: HostDaemon!
    private(set) var grant: Grant!
    private(set) var attach: InProcessAttach!
    private var journal: UUID?
    private let pulse: Pulse
    /// Restarts so far.
    private(set) var starts = 0
    /// Its kore-host is running (a link to it that's dialing is real work under way, not a box
    /// that will never answer).
    private(set) var up = false
    /// No Tailscale on it: Kore's own tailnet (`kore-tailnet`) is its node, `tailscale` its state
    /// (`.needsLogin`: never signed in).
    let own: Bool
    /// Installed Tailscale and Kore's own both there (mybox, 2026-11-23): `ip`/`nodeKey` are
    /// installed Tailscale's node, `ownIP`/`ownKey` Kore's own (`<alias>-kore`, userspace), each
    /// online only while it runs. kore-host chooses between them as it does on the box
    /// (`BoxTailnet`), and hears tailscaled come back by its socket's folder (`appears`).
    let beside: Bool
    let ownIP: String
    let ownKey: String
    /// Kore's own there was signed in once (its state kept): it starts running, else waiting.
    private let ownState: OwnState
    /// The box's journal lines (KNS_DEBUG prints them).
    let journalBox = JournalLines()
    final class JournalLines: Sendable { let lines = Mutex<[String]>([]) }
    var journalLines: [String] { journalBox.lines.withLock { $0 } }
    final class OwnState: Sendable {
        let signed: Mutex<Bool>
        /// Installed Tailscale is on the box (false: never installed, until `installTailscale`).
        let installed = Mutex(true)
        /// Its key ran out: its next start reads Running from its cached state until its control
        /// server answers (signed out).
        let expired = Mutex(false)
        let watches = Mutex<[Int: @Sendable () -> Void]>([:])
        init(_ signed: Bool) { self.signed = Mutex(signed) }
    }

    init(
        alias: String, root: URL, ip: String, net: SharedTailnet, pulse: Pulse, tailscale: BackendState = .running, own: Bool = false, beside: Bool = false,
        ownSignedIn: Bool = false, tailscaleInstalled: Bool = true
    ) throws {
        self.own = own
        self.beside = beside
        ownIP = "100.64.2." + (ip.split(separator: ".").last.map(String.init) ?? "1")
        ownKey = "nodekey:\(alias)-kore"
        ownState = OwnState(ownSignedIn)
        ownState.installed.withLock { $0 = tailscaleInstalled }
        self.alias = alias
        self.root = root
        self.ip = ip
        nodeKey = "nodekey:\(alias)"
        self.net = net
        self.pulse = pulse
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [work.path]).save(paths.config)
        var node = SharedTailnet.Node(name: alias, kind: .box, ip: ip, nodeKey: nodeKey, bindIP: "127.0.0.1")
        node.state = tailscale
        node.userspace = own
        let me = WeakRef(self)
        let state = paths.netState
        node.greet = { fd, remote in
            // Only while the box's port is bound (its `net.state`, as `kore-host status` reads it).
            let line = (try? String(contentsOf: state, encoding: .utf8)) ?? ""
            guard line.hasPrefix("listening") else { return false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let box = me.value, let hostNet = box.host?.net, hostNet.listening, let tailnet = hostNet.tailnet,
                          let who = try? tailnet.whois(remote)
                    else { return Sockets.closeFD(fd) }
                    hostNet.greet(fd, route: .tailnet, facts: HostNet.facts(who), whois: who, remote: remote)
                }
            }
            return true
        }
        net.add(node)
        if beside {
            // Kore's own node: there (signed in or not) and stopped until kore-host starts it.
            var ownNode = SharedTailnet.Node(name: alias + "-kore", kind: .box, ip: ownIP, nodeKey: ownKey, bindIP: "127.0.0.1")
            ownNode.state = .stopped
            ownNode.userspace = true
            ownNode.greet = node.greet
            net.add(ownNode)
        }
        let lines = journalBox
        journal = HostJournal.watch { [pulse] line in
            lines.lines.withLock { $0.append("\(line)") }
            pulse.beat()
        }
        try start()
        grant = try GrantStore(paths.grants).allow("laptop", control: .full, socket: paths.socket)
        attach = InProcessAttach(socket: paths.netSocket, grant: grant)
    }

    private func start() throws {
        let host = HostDaemon(paths: paths)
        let tailnet = NodeNet(net, ip: ip)
        if beside {
            let (net, ip, ownIP, ownKey, alias) = (net, ip, ownIP, ownKey, alias)
            let state = ownState
            let installedNet = NodeNet(net, ip: ip)
            let ownNet = NodeNet(net, ip: ownIP)
            host.boxTailnet = BoxTailnet(
                installed: {
                    guard state.installed.withLock({ $0 }) else { return (.missing(.absent), nil) }
                    // `systemctl stop tailscaled`: its daemon and socket gone (installed, not running).
                    switch net.node(ip)?.state ?? .noState {
                    case .stopped: return (.missing(.notRunning), nil)
                    case let state: return (.state(state), installedNet)
                    }
                },
                helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
                start: { _, _ in
                    // Removed in the admin console: a new node, waiting for its sign-in.
                    if net.node(ownIP) == nil {
                        var fresh = SharedTailnet.Node(name: alias + "-kore", kind: .box, ip: ownIP, nodeKey: ownKey + "-2", bindIP: "127.0.0.1")
                        fresh.userspace = true
                        fresh.greet = net.node(ip)?.greet
                        fresh.state = .needsLogin
                        net.add(fresh)
                    } else if state.expired.withLock({ $0 }) {
                        net.update(ownIP) { $0.staleRunning = true }
                        net.setState(ownIP, .running)
                    } else {
                        net.setState(ownIP, state.signed.withLock { $0 } ? .running : .needsLogin)
                    }
                    return (ownNet, { true }, { net.setState(ownIP, .stopped) })
                },
                key: { Data(repeating: 7, count: 32) },
                appears: { changed in
                    let id = state.watches.withLock { w -> Int in
                        let id = (w.keys.max() ?? 0) + 1
                        w[id] = changed
                        return id
                    }
                    return { state.watches.withLock { _ = $0.removeValue(forKey: id) } }
                })
            // Only the socket's folder brings it back quickly: the slow looks never come in a test.
            host.besideWait = { _ in 3600 }
        } else if own {
            // Kore's own, as the daemon starts it: absent Tailscale, the helper beside kore-host.
            host.boxTailnet = BoxTailnet(
                installed: { (.missing(.absent), nil) }, helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
                start: { _, _ in (tailnet, { true }, {}) }, key: { Data(repeating: 7, count: 32) })
        } else {
            host.makeTailnet = { tailnet }
        }
        host.netPort = 0
        try host.start()
        self.host = host
        starts += 1
        up = true
        pulse.beat()
    }

    /// Kore's own tailnet there signs in (the page the Mac opened, finished in the browser).
    func signInOwn() {
        guard beside else { return net.setState(ip, .running) }
        ownState.signed.withLock { $0 = true }
        ownState.expired.withLock { $0 = false }
        // Deleted in the admin console: the sign-in makes it a new node (a new key) there.
        if net.node(ownIP)?.deleted == true {
            net.update(ownIP) {
                $0.deleted = false
                $0.dark = false
                $0.nodeKey = ownKey + "-new"
            }
        }
        if net.node(ownIP)?.state == .needsLogin { net.setState(ownIP, .running) }
    }

    /// `systemctl stop tailscaled` there: installed Tailscale's node goes offline, its socket goes.
    func stopTailscaled() {
        net.setState(ip, .stopped)
        // `tailscale0` goes with it: netlink makes HostNet look again.
        host.net?.rebind()
    }

    /// `systemctl start tailscaled`: its node runs again and its socket's folder is made.
    func startTailscaled() {
        net.setState(ip, .running)
        for watch in ownState.watches.withLock({ Array($0.values) }) { watch() }
    }

    /// `tailscale logout` there: installed's node waits for a sign-in, its addresses go (netlink).
    func signOutTailscale() {
        net.setState(ip, .needsLogin)
        host.net?.rebind()
    }

    /// `tailscale up` signed in again: its bus says so (no socket change).
    func signInTailscale() { net.setState(ip, .running) }

    /// A box on Kore's own only: Tailscale installed now (its node signs in and runs, its socket appears).
    func installTailscale() {
        ownState.installed.withLock { $0 = true }
        startTailscaled()
    }

    /// Installed Tailscale's node re-registered (a new machine key): a new node, `<alias>-1` at
    /// `address`, the old one gone offline. kore-host keeps its own client (KoreNet off here).
    func reregisterTailscale(_ address: String) {
        var fresh = SharedTailnet.Node(name: alias + "-1", kind: .box, ip: address, nodeKey: nodeKey + "-re", bindIP: "127.0.0.1")
        fresh.greet = net.node(ip)?.greet
        net.setState(ip, .stopped)
        net.add(fresh)
    }

    /// Kore's own node there removed in the admin console (it was signed in, now stopped).
    func removeOwnInAdmin() {
        ownState.signed.withLock { $0 = false }
        net.remove(ownIP)
    }

    /// Kore's own node deleted in the admin console while it carries the box: the box hears it
    /// signed out, every other node hears it removed, its links go quiet.
    func deleteOwn() {
        ownState.signed.withLock { $0 = false }
        net.delete(ownIP)
    }

    /// Kore's own node's key runs out while Tailscale overrides (signed in, stopped): the box's
    /// timer fires; started again, it reads Running from its cached state before its control
    /// server says it expired.
    func expireOwn() {
        ownState.signed.withLock { $0 = false }
        ownState.expired.withLock { $0 = true }
        host.ownHeard(.signedOut(.expired))
    }

    /// The node it's on now (installed Tailscale's or Kore's own), as the tailnet shows it online.
    var onOwn: Bool { net.node(ownIP)?.online == true && host.net?.userspace == true }

    /// Signed out there (logged out, removed in the admin console): its node waits for a sign-in.
    func signOutOwn() { net.setState(ip, .needsLogin) }

    /// Kore's own tailnet there, as the box has it.
    var ownTailnet: NetNodeWire.Own? { host.ownTailnet }

    /// `kore-host net on|off` on the box itself.
    func setNet(_ on: Bool) throws { try host.setNet(on) }

    /// kore-host restarts (a service restart: its links told `restart`) from the same folder.
    func restart() throws {
        host.stop(restarting: true)
        host = nil
        try start()
    }

    func stop() {
        up = false
        host?.stop()
        if let journal { HostJournal.unwatch(journal) }
        journal = nil
    }

    /// The box's device book, as `kore-host devices` lists it.
    var devices: [DeviceRecord] { host.devices.all() }
    var device: UUID? { host.net?.identity.device }
    var netOn: Bool { host.config.netOn }
    var listening: Bool { host.net?.listening == true }
    /// A tailnet handshake under way at its kore-host (work the world waits for).
    var handshaking: Bool { (host?.net?.handshaking(.tailnet) ?? 0) > 0 }
    /// Devices waiting at the box for an owner Mac's Allow.
    var pending: [PendingDevice] { host.devices.pending() }
}

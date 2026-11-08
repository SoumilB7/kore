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

    init(alias: String, root: URL, ip: String, net: SharedTailnet, pulse: Pulse, tailscale: BackendState = .running) throws {
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
        journal = HostJournal.watch { [pulse] _ in pulse.beat() }
        try start()
        grant = try GrantStore(paths.grants).allow("laptop", control: .full, socket: paths.socket)
        attach = InProcessAttach(socket: paths.netSocket, grant: grant)
    }

    private func start() throws {
        let host = HostDaemon(paths: paths)
        let tailnet = NodeNet(net, ip: ip)
        host.makeTailnet = { tailnet }
        host.netPort = 0
        try host.start()
        self.host = host
        starts += 1
        pulse.beat()
    }

    /// `kore-host net on|off` on the box itself.
    func setNet(_ on: Bool) throws { try host.setNet(on) }

    /// kore-host stops (its links told `quit`, as a service restart does) and starts again from
    /// the same folder.
    func restart() throws {
        host.stop()
        host = nil
        try start()
    }

    func stop() {
        host?.stop()
        if let journal { HostJournal.unwatch(journal) }
        journal = nil
    }

    /// The box's device book, as `kore-host devices` lists it.
    var devices: [DeviceRecord] { host.devices.all() }
    var device: UUID? { host.net?.identity.device }
    var netOn: Bool { host.config.netOn }
    var listening: Bool { host.net?.listening == true }
    /// Devices waiting at the box for an owner Mac's Allow.
    var pending: [PendingDevice] { host.devices.pending() }
}

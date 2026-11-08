import Foundation
import HostClient
import KoreCore
import KoreHost
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing
import src

/// Whether `feed` gives a value matching `match` within 5 s. The wait runs in a task of its own:
/// a feed that never gives one fails the test instead of hanging the run (the 5 s only bounds a
/// failure; a pass is the event itself).
@MainActor
func arrives<T: Sendable>(_ feed: Feed<T>, _ match: @escaping @Sendable (T) -> Bool = { _ in true }) async -> Bool {
    let done = Feed<Bool>()
    let waiter = Task { _ = await feed.next(match); done.send(true) }
    let bound = Task {
        try? await Task.sleep(for: .seconds(5))
        done.send(false)
    }
    let arrived = await done.next()
    waiter.cancel()
    bound.cancel()
    return arrived
}

/// Whether `condition` holds (now, or once what it reads changes) within 5 s: woken by
/// observation, never polled.
@MainActor
func holds(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let held = Feed<Bool>()
    let watcher = Task { @MainActor in
        await Observed.until(condition)
        held.send(true)
    }
    let arrived = await arrives(held)
    watcher.cancel()
    return arrived
}

/// `kore-host attach --proto 2` in this process: the real `NetAttach` relay between a socket the
/// Mac's transport holds and the daemon's `net.sock`, as ssh would carry it. Dialled on the
/// transport's queue; the relay runs on its own (nothing here hops to the main actor).
final class InProcessAttach: Sendable {
    let socket: URL
    let grant: Grant
    let dials = Feed<Int>()
    private let held = Mutex<[NetAttach]>([])

    init(socket: URL, grant: Grant) {
        self.socket = socket
        self.grant = grant
    }

    func dial() throws -> (fd: Int32, onClose: @Sendable () -> Void) {
        let (mine, theirs) = try Sockets.pair()
        let attach: NetAttach
        do {
            attach = try NetAttach(grant: grant, socket: socket, input: theirs, output: theirs) { _ in Sockets.closeFD(theirs) }
        } catch {
            Sockets.closeFD(mine)
            Sockets.closeFD(theirs)
            throw error
        }
        attach.start()
        let count = held.withLock { $0.append(attach); return $0.count }
        dials.send(count)
        return (mine, {})
    }
}

/// The Mac side of KoreNet, swept: each test fails on the code before its fix.
@MainActor
@Suite("korenet sweep, mac", .serialized, .timeLimit(.minutes(1)))
struct NetSweepMacTests {
    /// The P0 end to end, both halves real: a never-enrolled box on its `attach --as` link, this
    /// Mac's KoreNet on. It enrolls silently over `attach --proto 2`, and its link dials again over
    /// that route at once (it's a proven owner Mac there now), so "Join KoreNet"'s `net.set` is
    /// taken; the box binds its tailnet port and the link moves onto it.
    @Test func joinOnANeverEnrolledSSHBoxEndsOnTheTailnet() async throws {
        let root = URL(fileURLWithPath: "/tmp/kj-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [work.path]).save(paths.config)

        // The box: its own tailnet says it's `nodekey:box` on 127.0.0.1, and that the Mac
        // dialling from there is `nodekey:mac`, the same user.
        let boxNet = FakeTailnet()
        boxNet.held.withLock {
            $0.status = TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:box", tailscaleIPs: ["127.0.0.1"], userID: 7))
            $0.whois["127.0.0.1"] = try! JSONDecoder().decode(
                TailnetWhoIs.self, from: Data(#"{"Node":{"Key":"nodekey:mac","Name":"mac.tail.ts.net."},"UserProfile":{"ID":7,"LoginName":"me@example.com"}}"#.utf8))
        }
        let host = HostDaemon(paths: paths)
        host.makeTailnet = { boxNet }
        host.netPort = 0
        try host.start()
        defer { host.stop() }
        let grant = try GrantStore(paths.grants).allow("laptop", control: .full, socket: paths.socket)
        let attach = InProcessAttach(socket: paths.netSocket, grant: grant)

        // This Mac: installed Tailscale running, the box its peer at 127.0.0.1.
        let macNet = FakeTailnet()
        let peer = #"{"PublicKey":"nodekey:box","TailscaleIPs":["127.0.0.1"],"Online":true,"UserID":7,"HostName":"box-1"}"#
        let boxWho = #"{"Node":{"Key":"nodekey:box","Name":"box-1.tail.ts.net."},"UserProfile":{"ID":7,"LoginName":"me@example.com"}}"#
        let netState = paths.netState
        macNet.held.withLock {
            $0.status.peers = [try! JSONDecoder().decode(TailnetStatus.Peer.self, from: Data(peer.utf8))]
            $0.whois["127.0.0.1"] = try! JSONDecoder().decode(TailnetWhoIs.self, from: Data(boxWho.utf8))
            // The box's real tailnet port, as it bound it (its `net.state`, read here off the
            // main actor: "listening <addresses> port <n>").
            $0.dial = { _ in
                let state = (try? String(contentsOf: netState, encoding: .utf8)) ?? ""
                guard state.hasPrefix("listening"), let port = state.split(separator: " ").last.flatMap({ UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                else { throw TailnetError.sidecar("the box isn't listening") }
                return try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: port)
            }
        }
        let defaults = suite()
        let support = root.appendingPathComponent("Kore")
        let env = NetEnvironment(
            installed: { (.state(.running), macNet) }, sidecar: { _ in throw TailnetError.sidecar("none") }, secrets: MemorySecrets(), defaults: defaults,
            support: support, upgradeDial: { _, _, _ in try attach.dial() }, macName: { "MacBook" })
        let alias = "jn-\(UUID().uuidString.prefix(6).lowercased())"
        let directory = NodeDirectory(defaults: defaults)
        let hosts = support.appendingPathComponent("hosts")
        let connection = HostConnection(alias: alias, grant: "laptop", cache: HostCache(alias: alias, root: hosts)) {
            DaemonTransport(path: paths.socket.path, grant: grant)
        }
        let rekeyer = NodeRekeyer(migration: NodeMigration(root: support, defaults: defaults))
        rekeyer.usage = { _, _ in }
        let switcher = KoreNetSwitch(
            defaults: defaults, directory: directory, rekeyer: rekeyer, global: false, connections: { [connection] }, environment: { env })
        connection.router = switcher
        let settled = Feed<String>()
        switcher.settled = { settled.send($0) }
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        #expect(switcher.state == .installed)

        // The legacy link; the box says who it is; this Mac enrolls there.
        let ups = links(connection)
        connection.retain()
        defer { connection.release() }
        #expect(await arrives(ups) { $0 })
        #expect(await arrives(settled) { $0 == "enroll enrolled" })
        #expect(directory.entry(forKey: connection.alias)?.enrolled == true)
        // The fix: the link dials again over `attach --proto 2` without waiting for anything.
        #expect(await arrives(attach.dials) { $0 == 2 }, "the link stayed on `attach --as`")
        #expect(await arrives(ups) { $0 })

        // Join KoreNet: the box's node key comes once its port listens, and the link moves to
        // the tailnet (however `net.node` and `net.set`'s answer interleave with Join's relink).
        let join = BoxNetJoin(key: alias, name: "box-1")
        let run = BoxNetJoinRun(connection: connection, net: switcher, directory: directory)
        run.start(join)
        #expect(await holds { join.ending.over }, "\(join.rows) · \(String(describing: connection.route))")
        #expect(join.ending == .done, "\(join.ending) · \(join.rows)")
        #expect(connection.route == .net && connection.isOnline)
        #expect(host.config.netOn && host.net?.listening == true)
        // The box holds this Mac with its tailnet node key now.
        let mac = try #require(try host.devices.book.read().devices.first { $0.kind == .mac })
        #expect(mac.owner && mac.nodeKeys.contains("nodekey:mac"))
        // And the link answers over it.
        #expect(await connection.listFolders().map(\.path) == [work.path])
        if !join.ending.over { run.cancel(join) }
        switcher.set(false)
    }

    /// The bus held, let go and held again before the first task's tail runs: one bus stays held
    /// and the switch keeps its handle (it would leak or double otherwise).
    @Test func releaseThenHoldKeepsOneBus() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let local = FakeTailnet()
        let calls = EnvCalls()
        let switcher = KoreNetSwitch(
            defaults: defaults, directory: NodeDirectory(defaults: defaults), rekeyer: NodeRekeyer(migration: NodeMigration(root: root, defaults: defaults)),
            global: false, connections: { [] }, environment: { fakeEnv(.state(.running), local: local, root: root, defaults: defaults, calls: calls) })
        let settled = Feed<String>()
        switcher.settled = { settled.send($0) }
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        switcher.hold("popup", true)
        #expect(switcher.busHeld && local.buses == 1)
        switcher.hold("popup", false)
        switcher.hold("popup", true)
        // The first bus ends; its task's tail runs after that.
        #expect(await arrives(local.busEnded))
        await Task.yield()
        #expect(local.buses == 1)
        #expect(switcher.busHeld, "the second bus is held but the switch forgot it")
        switcher.hold("popup", false)
        #expect(await arrives(local.busEnded))
        #expect(local.buses == 0, "a bus outlived the last release")
        switcher.set(false)
    }

    /// Installed Tailscale whose LocalAPI is there but doesn't answer counts as stopped (SSH
    /// only until it does), never "unreadable", which would start a second node for this Mac.
    @Test func installedButNotAnsweringIsStoppedNeverASecondNode() {
        let api = LocalAPIClient(discover: { .unix("/var/run/tailscaled.socket") }, connect: { _ in throw SocketError.failed("connect", ECONNREFUSED) })
        let (installed, local) = NetEnvironment.installedTailscale(api)
        #expect(installed == .state(.stopped) && local != nil)
        #expect(TailnetChooser.choose(installed) == .stopped)
    }

    /// A join that fails (Tailscale off on this Mac) lets go of the link and the bus it held,
    /// so the box link isn't dialled on with no window, and "Try again" starts clean.
    @Test func aFailedJoinLetsGoOfTheLinkAndTheBus() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let local = FakeTailnet(.stopped)
        let switcher = KoreNetSwitch(
            defaults: defaults, directory: NodeDirectory(defaults: defaults), rekeyer: NodeRekeyer(migration: NodeMigration(root: root, defaults: defaults)),
            global: false, connections: { [] }, environment: { fakeEnv(.state(.stopped), local: local, root: root, defaults: defaults, calls: calls) })
        let alias = "jf-\(UUID().uuidString.prefix(6).lowercased())"
        let dials = Dials()
        let connection = HostConnection(alias: alias, grant: "laptop", cache: HostCache(alias: alias, root: root)) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            dials.made.send(dials.hosts.count - 1)
            return client
        }
        connection.router = switcher
        // The link up at 1.12, full, as Join needs it.
        connection.retain()
        #expect(await arrives(dials.made))
        guard let ssh = dials.hosts.first else { return }
        await welcome112(ssh)
        #expect(await holds { connection.isOnline })
        connection.release()
        #expect(!connection.inUse)

        let join = BoxNetJoin(key: alias, name: "box-1")
        let run = BoxNetJoinRun(connection: connection, net: switcher, directory: NodeDirectory(defaults: defaults))
        run.start(join)
        #expect(await holds { join.ending.over })
        #expect(join.ending == .failed("Tailscale is off on this Mac."))
        #expect(!connection.inUse, "the join still holds the link")
        #expect(!switcher.busHeld, "the join still holds the bus")
        switcher.set(false)
    }
}

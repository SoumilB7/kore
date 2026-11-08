import Foundation
import HostClient
import KoreHost
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing

/// A box's shell as the upgrade reaches it: each `kore-host upgrade` answered from `answers` in
/// turn (the last repeats), each push told, every call counted. No ssh.
final class FakeUpgradeShell: Sendable {
    struct Held {
        var answers: [BoxRan]
        var runs: [(grant: String, want: String?)] = []
        var pushes = 0
        var pushFails: BoxSetup.Failure?
    }

    let held: Mutex<Held>

    init(_ answers: BoxRan...) { held = Mutex(Held(answers: answers)) }

    static func report(_ lines: [String: String], exit: Int32 = 0) -> BoxRan {
        var all = ["version": "0.2.3", "link": "1.12"]
        all.merge(lines) { _, new in new }
        return BoxRan(status: exit, output: all.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

    var runs: Int { held.withLock { $0.runs.count } }
    var pushes: Int { held.withLock { $0.pushes } }

    var shell: BoxUpgradeShell {
        BoxUpgradeShell(
            upgrade: { [self] _, _, grant, want in
                held.withLock {
                    $0.runs.append((grant, want))
                    return $0.answers.count > 1 ? $0.answers.removeFirst() : $0.answers[0]
                }
            },
            push: { [self] _, _ in
                held.withLock {
                    $0.pushes += 1
                    return $0.pushFails
                }
            })
    }
}

/// `kore-host upgrade` on a box whose daemon runs in this process: what ssh would carry, with
/// Tailscale running there; each report also on `ran`.
func inProcessUpgrade(_ host: HostDaemon, paths: HostPaths, ran: Reports? = nil) -> BoxUpgradeShell {
    BoxUpgradeShell(
        upgrade: { _, _, grant, want in
            let report = await MainActor.run {
                HostUpgrade(
                    paths: paths, update: { nil }, service: { .running }, installService: { [] }, startDaemon: { true }, linger: { true },
                    tailscale: { .running(node: "nodekey:box") }, reload: { MainActor.assumeIsolated { host.reloadNet() } }, listen: { _ in nil }
                ).run(want: want, grant: grant)
            }
            let net = await MainActor.run { host.net }
            await net?.settled()
            ran?.add(report)
            return BoxRan(status: report.exit, output: report.text.joined(separator: "\n"))
        },
        push: { _, _ in BoxSetup.Failure(message: "no push here") })
}

/// Each upgrade report as it comes, counted on `count`.
final class Reports: Sendable {
    private let held = Mutex<[HostUpgrade.Report]>([])
    let count = Feed<Int>()
    func add(_ report: HostUpgrade.Report) { count.send(held.withLock { $0.append(report); return $0.count }) }
    subscript(_ i: Int) -> HostUpgrade.Report { held.withLock { $0[i] } }
}

/// `attach --proto 2` relays dialled in this process, kept alive while the test runs.
final class Attaches: Sendable {
    private let held = Mutex<[InProcessAttach]>([])
    func dial(_ socket: URL, _ grant: Grant) throws -> (fd: Int32, onClose: @Sendable () -> Void) {
        let attach = InProcessAttach(socket: socket, grant: grant)
        held.withLock { $0.append(attach) }
        return try attach.dial()
    }
}

/// The SSH → KoreNet upgrade from the Mac's side (phase 18 §2g, I24 I25): the report's words,
/// each failure's one line, the trigger that runs once per state and never loops, Join with no
/// window, and the whole of it over a real kore-host daemon. Virtual clocks; no ssh, no sleeps.
@MainActor
@Suite("box upgrade over ssh", .serialized, .timeLimit(.minutes(1)))
struct BoxUpgradeTests {
    /// A switch on fakes, on and chosen, and an upgrades registry over it.
    func rig(_ state: TailnetChooser.Installed = .state(.running), shell: FakeUpgradeShell) async -> (KoreNetSwitch, BoxUpgrades, NodeDirectory, URL) {
        let root = netScratch()
        let defaults = suite()
        let directory = NodeDirectory(defaults: defaults)
        // The fake's own read says what the test's state does (a read now moves KoreNet's state).
        let backend: BackendState = switch state {
        case .state(let backend): backend
        default: .stopped
        }
        let local = FakeTailnet(backend)
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory) {
            fakeEnv(state, local: local, root: root, defaults: defaults, calls: EnvCalls())
        }
        switcher.set(true)
        _ = await arrives(settled) { $0 == "chose" }
        let upgrades = BoxUpgrades()
        upgrades.net = { switcher }
        upgrades.directory = directory
        upgrades.shell = shell.shell
        upgrades.boxes = { [] }
        upgrades.sleep = VirtualClock().sleep
        upgrades.want = "0.2.3"
        let made = Box<[String: HostConnection]>([:])
        upgrades.link = { alias in
            if let held = made.value[alias] { return held }
            let connection = HostConnection(alias: alias, grant: "MacBook", cache: HostCache(alias: alias, root: root)) { FakeHost.pair().0 }
            connection.router = switcher
            made.value[alias] = connection
            return connection
        }
        return (switcher, upgrades, directory, root)
    }

    @Test func theReportParses() {
        let text = "version: 0.2.2\nlink: 1.12\nupdate: 0.2.2 → 0.2.3\nversion: 0.2.3\nservice: running\nlogin: https://login.tailscale.com/a/x\nstate: done\n"
        let report = BoxUpgradeReport.parse(text)
        #expect(report?.version == "0.2.3" && report?.state == "done" && report?["service"] == "running" && report?.login == "https://login.tailscale.com/a/x")
        #expect(report?.old(want: "0.2.3") == false && report?.old(want: "0.2.4") == true)
        #expect(BoxUpgradeReport.parse("version: 0.2.3\nlink: 1.11\nstate: done")?.old(want: nil) == true)
        #expect(BoxUpgradeReport.parse("version: 0.2.3\nupdate: failed no network\nstate: failed")?.old(want: nil) == true)
        // An older kore-host without `upgrade` prints its usage: not a report.
        #expect(BoxUpgradeReport.parse("usage: kore-host run\n       kore-host join") == nil)
        #expect(BoxUpgradeShell.line(command: "~/.local/bin/kore-host", grant: "MacBook", want: "0.2.3") == "~/.local/bin/kore-host upgrade --grant 'MacBook' --want '0.2.3'")
    }

    /// Each stop has its one line and at most one action; none is a silent end.
    @Test func eachFailureHasItsLine() async throws {
        let cases: [(BoxRan, String, BoxFix?)] = [
            (BoxRan(status: 255, output: "ssh: connect to host box-1 port 22: Operation timed out"), "Can't reach box-1", .tryAgain),
            (FakeUpgradeShell.report(["error": "tailscale stopped", "state": "needs you"], exit: 2), "Tailscale is off on box-1", .copy(BoxNetJoin.sudoLine)),
            (FakeUpgradeShell.report(["error": "no sudo", "state": "needs you"], exit: 2), "Tailscale is off on box-1", .copy(BoxNetJoin.sudoLine)),
            (FakeUpgradeShell.report(["error": "tailscale absent", "state": "needs you"], exit: 2), "Install Tailscale on box-1", .copy(BoxNetJoin.installLine)),
            (FakeUpgradeShell.report(["error": "port held by uid 1001", "state": "needs you"], exit: 2), "Port 47470 on box-1 is held by another program", .tryAgain),
            (FakeUpgradeShell.report(["error": "service didn't start", "state": "failed"], exit: 1), "box-1 couldn't join KoreNet: service didn't start", .tryAgain),
        ]
        for (answer, line, fix) in cases {
            let shell = FakeUpgradeShell(answer)
            let (switcher, upgrades, _, root) = await rig(shell: shell)
            defer { try? FileManager.default.removeItem(at: root) }
            upgrades.reached("box-1", fresh: true)
            #expect(await holds { upgrades.running("box-1") == nil && upgrades.joins["box-1"] != nil })
            let facts = upgrades.facts("box-1")
            #expect(facts?.note == line && facts?.fix == fix, "\(String(describing: facts))")
            #expect(!upgrades.link("box-1").inUse, "a stopped upgrade still holds the link")
            #expect(!switcher.busHeld)
            switcher.set(false)
        }
    }

    /// The box's own Tailscale is signed out with its page open. By itself the upgrade never
    /// opens it (not at the first reach, not at the next): the row says "Sign in for box-1 ·
    /// Sign in ↗" and lets go. From Join, the page opens here once.
    @Test func aSignedOutBoxOpensItsPageOnlyWhenAsked() async {
        let page = "https://login.tailscale.com/a/abc"
        let shell = FakeUpgradeShell(FakeUpgradeShell.report(["error": "tailscale signed out", "login": page, "state": "needs you"], exit: 2))
        let (switcher, upgrades, _, root) = await rig(shell: shell)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        upgrades.now = { now }
        var opened: [URL] = []
        upgrades.openURL = { opened.append($0) }
        upgrades.reached("box-1", fresh: true)
        #expect(await holds { upgrades.running("box-1") == nil && upgrades.joins["box-1"]?.ending == .signIn })
        #expect(upgrades.facts("box-1") == BoxUpgradeFacts(note: "Sign in for box-1", fix: .signIn(page)))
        #expect(!upgrades.link("box-1").inUse)
        now += BoxUpgrades.retryAfter
        upgrades.reached("box-1", fresh: true)
        #expect(await holds { upgrades.running("box-1") == nil && shell.runs == 2 })
        #expect(opened.isEmpty, "the upgrade opened a page by itself")

        let join = BoxNetJoin(key: "box-1", name: "box-1")
        let runner = upgrades.runner(for: "box-1")!
        upgrades.adopt(join, runner)
        runner.start(join)
        #expect(await holds { join.ending == .signIn })
        #expect(opened == [URL(string: page)!])
        runner.cancel(join)
        switcher.set(false)
    }

    /// "Can't reach Tailscale · stays on SSH" offers Try again.
    @Test func unreachableOffersTryAgain() {
        let join = BoxNetJoin(key: "box-1", name: "box-1")
        join.started(version: "0.2.3")
        join.node(on: true, nodeKey: "nodekey:box")
        join.unreachableNow()
        #expect(join.line == "Can't reach Tailscale · stays on SSH" && join.fix == .tryAgain)
    }

    /// G31: the box forgot this Mac (its record gone): this Mac's proof over SSH gets `bye
    /// unknown`. It isn't enrolled there any more, the link stops (the row: hasn't allowed this
    /// Mac) instead of backing off forever, and the upgrade runs again.
    @Test func aBoxThatForgotThisMacUpgradesAgain() async throws {
        let shell = FakeUpgradeShell(FakeUpgradeShell.report(["error": "tailscale stopped", "state": "needs you"], exit: 2))
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let directory = NodeDirectory(defaults: defaults)
        let box = FakeNetBox(root: root)
        box.takesEnroll = false
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory) {
            fakeEnv(.state(.running), local: FakeTailnet(), box: box, root: root, defaults: defaults, calls: EnvCalls())
        }
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        let alias = "fg-\(UUID().uuidString.prefix(6).lowercased())"
        directory.upsert(NodeDirectory.Entry(device: box.device, name: "box-1", ssh: alias, nodeKey: nil, identityKey: box.identity.publicKey, enrolled: true, on: false))
        try switcher.book(switcher.env!).update { $0.append(box.pinned) }
        let connection = HostConnection(alias: alias, grant: "MacBook", cache: HostCache(alias: alias, root: root))
        connection.router = switcher
        let upgrades = BoxUpgrades()
        upgrades.net = { switcher }
        upgrades.directory = directory
        upgrades.shell = shell.shell
        upgrades.sleep = VirtualClock().sleep
        upgrades.link = { _ in connection }
        switcher.upgrades = upgrades
        let clock = VirtualClock()
        connection.sleep = clock.sleep
        connection.retain()
        #expect(await holds { connection.phase == .refused(.auth) }, "\(connection.phase) · \(connection.lastReason ?? "")")
        #expect(directory.entry(forKey: alias)?.enrolled == false)
        #expect(upgrades.started == 1)
        connection.release()
        switcher.set(false)
    }

    /// The Mac's own tailnet can't reach boxes: Join says which (G24), and nothing runs on the box.
    @Test func theMacsOwnStateHasItsWords() async {
        for (state, line) in [(TailnetChooser.Installed.state(.stopped), "Tailscale is off on this Mac."), (.state(.needsLogin), "Tailscale is signed out on this Mac.")] {
            let shell = FakeUpgradeShell(FakeUpgradeShell.report(["state": "done"]))
            let (switcher, upgrades, _, root) = await rig(state, shell: shell)
            defer { try? FileManager.default.removeItem(at: root) }
            let join = BoxNetJoin(key: "box-1", name: "box-1")
            let runner = upgrades.runner(for: "box-1")!
            upgrades.adopt(join, runner)
            runner.start(join)
            #expect(await holds { join.ending.over })
            #expect(join.ending == .failed(line) && shell.runs == 0)
            switcher.set(false)
        }
    }

    /// An older kore-host (no `upgrade`, or older link): this Mac's build goes first, then the
    /// upgrade again; a push that fails says "needs an update · Update". Busy chats are asked first.
    @Test func anOldBoxGetsThisMacsBuildFirst() async {
        let usage = BoxRan(status: 2, output: "usage: kore-host run\n       kore-host join")
        let shell = FakeUpgradeShell(usage, FakeUpgradeShell.report(["error": "tailscale stopped", "state": "needs you"], exit: 2))
        let (switcher, upgrades, _, root) = await rig(shell: shell)
        defer { try? FileManager.default.removeItem(at: root) }
        upgrades.reached("box-1", fresh: true)
        #expect(await holds { upgrades.running("box-1") == nil && upgrades.joins["box-1"]?.ending == .needsSudo })
        #expect(shell.pushes == 1 && shell.runs == 2)

        let failing = FakeUpgradeShell(FakeUpgradeShell.report(["link": "1.11", "state": "done"]))
        failing.held.withLock { $0.pushFails = BoxSetup.Failure(message: "no kit") }
        let (other, more, _, root2) = await rig(shell: failing)
        defer { try? FileManager.default.removeItem(at: root2) }
        more.reached("box-2", fresh: true)
        #expect(await holds { more.running("box-2") == nil && more.joins["box-2"] != nil })
        #expect(more.facts("box-2")?.note == "box-2 needs an update" && more.facts("box-2")?.fix == .update)
        #expect(failing.pushes == 1 && failing.runs == 1)
        switcher.set(false)
        other.set(false)
    }

    /// U0 runs once per state and never loops: the same state again (a link back, a probe)
    /// starts nothing; a fresh reach after `retryAfter` tries a failed box again; a changed state
    /// (KoreNet off and on) tries at once; KoreNet off starts nothing.
    @Test func theTriggerRunsOncePerState() async {
        let shell = FakeUpgradeShell(FakeUpgradeShell.report(["error": "tailscale stopped", "state": "needs you"], exit: 2))
        let (switcher, upgrades, _, root) = await rig(shell: shell)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        upgrades.now = { now }
        // What's observed first, so a change wakes the look (the shell's count isn't observed).
        func settledRuns(_ n: Int) async -> Bool { await holds { upgrades.running("box-1") == nil && shell.runs == n } }

        upgrades.reached("box-1", fresh: false)
        #expect(await settledRuns(1))
        for _ in 0..<3 {
            upgrades.reached("box-1", fresh: false)
            upgrades.reached("box-1", fresh: true)
        }
        #expect(shell.runs == 1 && upgrades.started == 1, "the same state ran again")
        now += BoxUpgrades.retryAfter
        upgrades.reached("box-1", fresh: false)
        #expect(upgrades.started == 1, "a link's net.node retried a failed box")
        upgrades.reached("box-1", fresh: true)
        #expect(await settledRuns(2))

        switcher.set(false)
        upgrades.reached("box-1", fresh: true)
        #expect(upgrades.started == 2, "KoreNet off still upgraded")
        let settled = Feed<String>()
        switcher.settled = { settled.send($0) }
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        upgrades.reached("box-1", fresh: false)
        #expect(await settledRuns(3))
        switcher.set(false)
    }

    /// KoreNet switched on upgrades every SSH box (U-b); a box on KoreNet already is left alone.
    @Test func switchingOnUpgradesEachBoxNotOnKoreNet() async {
        let shell = FakeUpgradeShell(FakeUpgradeShell.report(["error": "tailscale absent", "state": "needs you"], exit: 2))
        let (switcher, upgrades, directory, root) = await rig(shell: shell)
        defer { try? FileManager.default.removeItem(at: root) }
        var on = NodeDirectory.Entry(device: UUID(), name: "box-on", ssh: "box-on", nodeKey: "nodekey:on", identityKey: Data([1]), enrolled: true)
        directory.upsert(on)
        upgrades.boxes = { ["box-a", "box-on", "box-b"] }
        switcher.upgrades = upgrades
        upgrades.switchedOn()
        #expect(await holds { upgrades.running("box-a") == nil && upgrades.running("box-b") == nil && shell.runs == 2 })
        #expect(upgrades.joins["box-on"] == nil && !upgrades.needs("box-on"))
        // On with its Tailscale off (no node key now): the row says so, nothing to upgrade, on
        // any reach.
        on.nodeKey = nil
        directory.upsert(on)
        #expect(!upgrades.needs("box-on"))
        for _ in 0..<3 { upgrades.reached("box-on", fresh: true) }
        #expect(upgrades.started == 2 && upgrades.joins["box-on"] == nil)
        // Enrolled, but its KoreNet off: it isn't on KoreNet.
        on.on = false
        directory.upsert(on)
        #expect(upgrades.needs("box-on"))
        switcher.set(false)
    }

    /// The whole of it, both halves real, no window: a never-enrolled box's daemon with KoreNet
    /// off; this Mac's KoreNet on starts the upgrade by itself. `kore-host upgrade` (in process)
    /// turns the box on, the link it holds says `net.node`, this Mac enrolls over `attach --proto
    /// 2`, the link moves to the tailnet, then it lets go. Run again (Join): the box is unchanged
    /// and this Mac isn't enrolled twice.
    @Test func noWindowUpgradeEndsOnTheTailnetAndRunsTwiceTheSame() async throws {
        let root = URL(fileURLWithPath: "/tmp/kz-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [work.path]).save(paths.config)
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
        #expect(!host.config.netOn)

        // `kore-host upgrade` on the box, run in this process against the daemon above.
        let ran = Reports()
        let box = inProcessUpgrade(host, paths: paths, ran: ran)
        let attaches = Attaches()

        // This Mac: installed Tailscale running, the box its peer at 127.0.0.1.
        let macNet = FakeTailnet()
        let peer = #"{"PublicKey":"nodekey:box","TailscaleIPs":["127.0.0.1"],"Online":true,"UserID":7,"HostName":"box-1"}"#
        let boxWho = #"{"Node":{"Key":"nodekey:box","Name":"box-1.tail.ts.net."},"UserProfile":{"ID":7,"LoginName":"me@example.com"}}"#
        let netState = paths.netState
        macNet.held.withLock {
            $0.status.peers = [try! JSONDecoder().decode(TailnetStatus.Peer.self, from: Data(peer.utf8))]
            $0.whois["127.0.0.1"] = try! JSONDecoder().decode(TailnetWhoIs.self, from: Data(boxWho.utf8))
            $0.dial = { _ in
                let state = (try? String(contentsOf: netState, encoding: .utf8)) ?? ""
                guard state.hasPrefix("listening"), let port = state.split(separator: " ").last.flatMap({ UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                else { throw TailnetError.sidecar("the box isn't listening") }
                return try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: port)
            }
        }
        // The grant the upgrade makes, read when the link dials (as `attach --as` reads it there).
        let grantName = "MacBook"
        let defaults = suite()
        let support = root.appendingPathComponent("Kore")
        let env = NetEnvironment(
            installed: { (.state(.running), macNet) }, sidecar: { _ in throw TailnetError.sidecar("none") }, secrets: MemorySecrets(), defaults: defaults,
            support: support,
            upgradeDial: { _, _, _ in
                guard let grant = GrantStore(paths.grants).load(grantName) else { throw TailnetError.sidecar("no grant yet") }
                return try attaches.dial(paths.netSocket, grant)
            }, macName: { "MacBook" })
        let alias = "nz-\(UUID().uuidString.prefix(6).lowercased())"
        let directory = NodeDirectory(defaults: defaults)
        let connection = HostConnection(alias: alias, grant: grantName, cache: HostCache(alias: alias, root: support.appendingPathComponent("hosts"))) {
            guard let grant = GrantStore(paths.grants).load(grantName) else { return DaemonTransport(path: "/nonexistent", grant: Grant(name: grantName, socket: "", secret: "", control: .full, created: 0)) }
            return DaemonTransport(path: paths.socket.path, grant: grant)
        }
        let rekeyer = NodeRekeyer(migration: NodeMigration(root: support, defaults: defaults))
        rekeyer.usage = { _, _ in }
        let switcher = KoreNetSwitch(
            defaults: defaults, directory: directory, rekeyer: rekeyer, global: false, connections: { [connection] }, environment: { env })
        connection.router = switcher
        let upgrades = BoxUpgrades()
        upgrades.net = { switcher }
        upgrades.directory = directory
        upgrades.shell = box
        upgrades.boxes = { [alias] }
        upgrades.link = { _ in connection }
        let clock = VirtualClock()
        upgrades.sleep = clock.sleep
        upgrades.want = nil
        switcher.upgrades = upgrades
        let settled = Feed<String>()
        switcher.settled = { settled.send($0) }

        // KoreNet on: U-b starts the box's upgrade with no window and no click.
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        let arrived1 = await arrives(ran.count) { $0 == 1 }
        #expect(arrived1, "no upgrade ran")
        guard arrived1 else { return switcher.set(false) }
        let first = ran[0]
        #expect(first.value("state") == "done" && first.value("mac") == "allowed", "\(first.text)")
        #expect(await holds { upgrades.joinedAt[alias] != nil }, "\(upgrades.joins[alias]?.rows ?? []) · \(String(describing: connection.route))")
        #expect(upgrades.started == 1 && upgrades.facts(alias)?.joinedAt != nil)
        let entry = try #require(directory.entry(forKey: connection.alias))
        #expect(entry.enrolled && entry.nodeKey == "nodekey:box")
        #expect(host.config.netOn && host.net?.listening == true)
        let macs = try host.devices.book.read().devices.filter { $0.kind == .mac }
        #expect(macs.count == 1 && macs[0].owner)
        // It let go: no window holds the box, so nothing of the link runs.
        #expect(await holds { !connection.inUse })
        // A probe now: on KoreNet already, nothing runs.
        upgrades.reached(alias, fresh: true)
        #expect(upgrades.started == 1 && upgrades.running(alias) == nil)
        // "on KoreNet" for 5 s, then quiet.
        await clock.pending(BoxUpgrades.shownFor)
        clock.advance(BoxUpgrades.shownFor)
        #expect(await holds { upgrades.facts(alias) == nil })

        // Join again by hand: the same box state, no second enroll, done again.
        let join = BoxNetJoin(key: connection.alias, name: "box-1")
        let runner = try #require(upgrades.runner(for: connection.alias))
        upgrades.adopt(join, runner)
        runner.start(join)
        let arrived2 = await arrives(ran.count) { $0 == 2 }
        #expect(arrived2, "no upgrade ran")
        guard arrived2 else { return switcher.set(false) }
        let second = ran[1]
        #expect(second.value("mac") == "enrolled" && second.value("state") == "done", "\(second.text)")
        #expect(await holds { join.ending.over })
        #expect(join.ending == .done, "\(join.ending) · \(join.rows)")
        #expect(try host.devices.book.read().devices.filter { $0.kind == .mac }.count == 1)
        #expect(GrantStore(paths.grants).all().count == 1)
        #expect(await holds { !connection.inUse })
        switcher.set(false)
    }
}

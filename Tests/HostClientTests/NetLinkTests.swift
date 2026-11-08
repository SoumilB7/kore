import Foundation
import HostClient
import KoreCore
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing
import src

/// Counts what an environment was asked for.
final class EnvCalls: Sendable {
    let held = Mutex((installed: 0, sidecars: 0, stops: 0, upgrades: 0))
    /// Each helper stop, as it happens.
    let stopped = Feed<Int>()
}

/// An environment of fakes: installed Tailscale as `installed` says (its client `local`), Kore's
/// own as `sidecar` (or failing), the box's SSH upgrade through `box`.
func fakeEnv(
    _ installed: TailnetChooser.Installed, local: FakeTailnet? = nil, sidecar: FakeTailnet? = nil, box: FakeNetBox? = nil, root: URL,
    defaults: UserDefaults, calls: EnvCalls, secrets: MemorySecrets = MemorySecrets()
) -> NetEnvironment {
    NetEnvironment(
        installed: {
            calls.held.withLock { $0.installed += 1 }
            return (installed, local)
        },
        sidecar: { key in
            #expect(key.count == 32)
            calls.held.withLock { $0.sidecars += 1 }
            guard let sidecar else { throw TailnetError.sidecar("no helper") }
            return (sidecar, {
                calls.held.withLock { $0.stops += 1 }
                calls.stopped.send(1)
            })
        },
        secrets: secrets, defaults: defaults, support: root.appendingPathComponent("Kore"),
        upgradeDial: { _, _, _ in
            calls.held.withLock { $0.upgrades += 1 }
            guard let box else { throw TailnetError.sidecar("no box") }
            return (try box.accept(.ssh), {})
        },
        macName: { "MacBook" })
}

func suite() -> UserDefaults { UserDefaults(suiteName: "kore-net-\(UUID().uuidString)")! }

/// The box's welcome at link 1.12 with full control.
@MainActor
func welcome112(_ host: FakeHost) async {
    host.send(.challenge(nonce: "bm9uY2U="))
    _ = await host.take("hello")
    host.send(json: [
        "t": "welcome", "proto": ["major": 1, "minor": 12], "epoch": "e1", "host": ["name": "box-1", "koreVersion": "1", "kind": "box"],
        "providers": [], "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream"],
    ])
    host.send(.snapshot(rev: 1, windows: [], chats: [], extras: nil))
}

/// SSH dials of fake hosts, each as it's made.
@MainActor
final class Dials {
    var hosts: [FakeHost] = []
    let made = Feed<Int>()

    /// The next host dialled.
    func next() async -> FakeHost { hosts[await made.next()] }
}

/// A link's ups (true) and downs (false), as `onLink` tells them.
@MainActor
func links(_ connection: HostConnection) -> Feed<Bool> {
    let feed = Feed<Bool>()
    connection.onLink("test") { feed.send($0) }
    return feed
}

/// A switch on fakes, its choices and upgrades told on `settled`.
@MainActor
func netSwitch(
    _ defaults: UserDefaults, root: URL, directory: NodeDirectory? = nil, connections: @escaping @MainActor () -> [HostConnection] = { [] },
    env: @escaping () -> NetEnvironment
) -> (KoreNetSwitch, Feed<String>) {
    let switcher = KoreNetSwitch(
        defaults: defaults, directory: directory ?? NodeDirectory(defaults: defaults),
        rekeyer: NodeRekeyer(migration: NodeMigration(root: root, defaults: defaults)), global: false, connections: connections, environment: env)
    let settled = Feed<String>()
    switcher.settled = { settled.send($0) }
    return (switcher, settled)
}

@MainActor
@Suite("korenet on the Mac", .serialized, .timeLimit(.minutes(1)))
struct NetLinkTests {
    /// Backoff steps no other wait uses, so a test waits for exactly these.
    static let backoff: [Duration] = [.seconds(3), .seconds(7)]

    /// A link with a KoreNet route through `router` and SSH through fake hosts, on a virtual clock.
    func link(_ alias: String, router: FakeRouter, dials: Dials, clock: VirtualClock, root: URL) -> HostConnection {
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: root.appendingPathComponent("hosts"))) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            dials.made.send(dials.hosts.count - 1)
            return client
        }
        connection.router = router
        connection.sleep = clock.sleep
        connection.backoff = Self.backoff
        return connection
    }

    // MARK: Off, and the choice

    @Test func offCreatesNothing() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let secrets = MemorySecrets()
        let made = Box(0)
        let (net, _) = netSwitch(defaults, root: root) {
            made.value += 1
            return fakeEnv(.state(.running), local: FakeTailnet(), root: root, defaults: defaults, calls: calls, secrets: secrets)
        }
        net.start()
        let connection = HostConnection(alias: "off-box", cache: HostCache(alias: "off-box", root: root)) { FakeHost.pair().client }
        net.using(connection, true)
        #expect(!net.on && net.state == .off && made.value == 0 && net.made == 0 && net.env == nil && net.tailnet == nil && !net.busHeld)
        #expect(net.transport(for: connection) == nil)
        #expect(calls.held.withLock { $0 } == (0, 0, 0, 0) && secrets.reads == 0)
        #expect(defaults.object(forKey: MacIdentity.deviceKey) == nil)
        // On, then off again: the helper stops, the bus goes, nothing is held.
        let local = FakeTailnet()
        let (on, settled) = netSwitch(defaults, root: root) { fakeEnv(.missing(.absent), sidecar: local, root: root, defaults: defaults, calls: calls) }
        on.set(true)
        await settled.next { $0 == "chose" }
        #expect(on.state == .sidecar)
        on.hold("devices", true)
        #expect(local.buses == 1)
        on.set(false)
        await calls.stopped.next()
        #expect(on.state == .off && on.tailnet == nil && on.env == nil && !on.busHeld && !defaults.bool(forKey: KoreNetSwitch.onKey))
        await local.busEnded.next()
        #expect(local.buses == 0 && calls.held.withLock { $0.stops } == 1)
    }

    @Test(arguments: [
        (TailnetChooser.Installed.state(.running), NetState.installed, 0, true),
        (.state(.starting), .installed, 0, true),
        (.state(.stopped), .stopped, 0, false),
        (.state(.needsLogin), .signedOut, 0, false),
        (.state(.noState), .signedOut, 0, false),
        (.state(.inUseOtherUser), .signedOut, 0, false),
        (.missing(.absent), .sidecar, 1, true),
        (.missing(.appStore), .sidecar, 1, true),
        (.missing(.unreadable), .sidecar, 1, true),
    ])
    func theRouteFollowsTheTailnet(installed: TailnetChooser.Installed, state: NetState, sidecars: Int, net: Bool) async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let directory = NodeDirectory(defaults: defaults)
        let box = FakeNetBox(root: root)
        var entry = NodeDirectory.Entry(device: box.device, name: "box-1", ssh: "route-box", nodeKey: box.nodeKey, identityKey: box.identity.publicKey)
        directory.upsert(entry)
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory) {
            fakeEnv(installed, local: FakeTailnet(), sidecar: FakeTailnet(), root: root, defaults: defaults, calls: calls)
        }
        switcher.set(true)
        await settled.next { $0 == "chose" }
        #expect(switcher.state == state)
        #expect(calls.held.withLock { $0.sidecars } == sidecars)
        let connection = HostConnection(alias: "route-box", cache: HostCache(alias: "route-box", root: root)) { FakeHost.pair().client }
        // Not enrolled there yet: SSH.
        #expect(switcher.transport(for: connection) == nil)
        entry.enrolled = true
        directory.upsert(entry)
        #expect((switcher.transport(for: connection) != nil) == net)
        switcher.set(false)
    }

    @Test func koreTailnetThatWontStartLeavesSSHOnly() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let (switcher, settled) = netSwitch(defaults, root: root) { fakeEnv(.missing(.absent), root: root, defaults: defaults, calls: EnvCalls()) }
        switcher.set(true)
        await settled.next { $0 == "chose" }
        guard case .unavailable = switcher.state else { return #expect(Bool(false), "\(switcher.state)") }
        #expect(switcher.tailnet == nil)
    }

    // MARK: Routes, backoff, outbox

    @Test func aKoreNetDialThatFailsGoesOverSSHAtOnceAndBackoffSpansBoth() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (box, mac, book) = try pairedBox(root)
        let clock = VirtualClock()
        let router = FakeRouter()
        let netUp = Box(true)
        router.make = { netUp.value ? netTransport(to: box, mac: mac, book: book) : NetTransport(route: .tailnet) { throw TailnetError.notTailnet("box") } }
        let dials = Dials()
        let connection = link("both-box", router: router, dials: dials, clock: clock, root: root)
        let up = links(connection)
        connection.retain()
        #expect(await up.next())
        #expect(connection.route == .net && dials.hosts.isEmpty)
        // The tailnet link goes: the first wait, then KoreNet fails and SSH dials at once.
        netUp.value = false
        box.cut(0)
        #expect(await up.next() == false)
        await clock.pending(Self.backoff[0])
        clock.advance(Self.backoff[0])
        let ssh = await dials.next()
        // The KoreNet dial that failed said so too.
        #expect(await up.next() == false)
        await welcome112(ssh)
        #expect(await up.next())
        #expect(connection.route == .ssh(alias: "both-box", grant: HostConnection.defaultGrant))
        // SSH goes too: the next wait is the second step; then KoreNet is back and taken first.
        netUp.value = true
        ssh.close()
        #expect(await up.next() == false)
        await clock.pending(Self.backoff[1])
        clock.advance(Self.backoff[0])
        #expect(dials.hosts.count == 1 && box.count == 1)
        clock.advance(Self.backoff[1] - Self.backoff[0])
        #expect(await up.next())
        #expect(connection.route == .net && box.count == 2 && dials.hosts.count == 1)
        connection.release()
    }

    @Test func aCallSentOnTheTailnetThenDroppedIsSentOnceMoreOverSSH() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (box, mac, book) = try pairedBox(root)
        let clock = VirtualClock()
        let router = FakeRouter()
        let netUp = Box(true)
        router.make = { netUp.value ? netTransport(to: box, mac: mac, book: book) : nil }
        let dials = Dials()
        let connection = link("resend-box", router: router, dials: dials, clock: clock, root: root)
        let up = links(connection)
        // Asked before the link is up: it waits in the outbox, then goes on the tailnet.
        let answer = Task { await connection.call("chat-1", .send(text: "hi", files: [], queued: nil, id: "m1")) }
        connection.retain()
        let first = await box.received.next { $0.type == "chat.call" }
        let id = try #require(first.id)
        netUp.value = false
        box.cut(0)
        #expect(await up.next { !$0 } == false)
        await clock.pending(Self.backoff[0])
        clock.advance(Self.backoff[0])
        let ssh = await dials.next()
        await welcome112(ssh)
        let again = await ssh.take("chat.call")
        #expect(again["id"] as? String == id)
        ssh.send(json: ["t": "result", "id": id, "ok": true])
        let result = await answer.value
        #expect(result.ok && result.id == id)
        #expect(box.sent("chat.call").count == 1 && ssh.pending.filter { $0["t"] as? String == "chat.call" }.isEmpty)
        connection.release()
    }

    // MARK: Replaced

    @Test func aReplacedFromBeforeThisMacsOwnNewerSessionDialsAgain() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dials = Dials()
        let connection = link("stale-box", router: FakeRouter(), dials: dials, clock: VirtualClock(), root: root)
        let up = links(connection)
        connection.retain()
        let first = await dials.next()
        await welcome112(first)
        #expect(await up.next())
        connection.ownRouteCameUp()
        first.send(.bye(.replaced))
        // Not refused: dialled again at once, no wait.
        let second = await dials.next()
        #expect(connection.phase != .refused(.replaced))
        await welcome112(second)
        #expect(await up.next { $0 })
        // From another Kore (nothing of this Mac's newer): refused, no dial.
        second.send(.bye(.replaced))
        await second.ended.next()
        #expect(connection.phase == .refused(.replaced) && dials.hosts.count == 2)
        connection.release()
    }

    // MARK: Liveness

    @Test func wakeProbesAndASilentLinkDrops() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (box, mac, book) = try pairedBox(root)
        let clock = VirtualClock()
        let router = FakeRouter()
        router.make = { netTransport(to: box, mac: mac, book: book) }
        let connection = link("wake-box", router: router, dials: Dials(), clock: clock, root: root)
        let up = links(connection)
        connection.retain()
        #expect(await up.next())
        let center = NotificationCenter()
        let woke = Notification.Name("wake-test")
        let wake = LinkWake(center: center, name: woke) { connection.probe($0) }
        // Answered: the probe's wait is given up and the link stays.
        center.post(name: woke, object: nil)
        let probe = await box.received.next { $0.command == "folders.list" }
        box.reply(0, json: ["t": "result", "id": try #require(probe.id), "ok": true])
        await clock.gaveUp(connection.probeWait)
        #expect(connection.isOnline)
        // Silent: it drops and dials again.
        center.post(name: woke, object: nil)
        _ = await box.received.next { $0.command == "folders.list" }
        await clock.pending(connection.probeWait)
        clock.advance(connection.probeWait)
        #expect(await up.next() == false)
        #expect(connection.probes == 2)
        _ = wake
        connection.release()
    }

    @Test func aCommandUnansweredForTenSecondsProbes() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (box, mac, book) = try pairedBox(root)
        let clock = VirtualClock()
        let router = FakeRouter()
        router.make = { netTransport(to: box, mac: mac, book: book) }
        let connection = link("quiet-box", router: router, dials: Dials(), clock: clock, root: root)
        let up = links(connection)
        connection.retain()
        #expect(await up.next())
        let asked = Task { await connection.command { HostWire.command(id: $0, type: "git.status", [:]) } }
        _ = await box.received.next { $0.command == "git.status" }
        await clock.pending(connection.unansweredAfter)
        clock.advance(connection.unansweredAfter - .seconds(1))
        #expect(connection.probes == 0)
        clock.advance(.seconds(1))
        _ = await box.received.next { $0.command == "folders.list" }
        #expect(connection.probes == 1)
        connection.release()
        _ = await asked.value
    }

    @Test func aPeerComingOnlineRedialsAtOnceAndTheBusIsHeldOnlyWhileInUse() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let local = FakeTailnet()
        let directory = NodeDirectory(defaults: defaults)
        directory.upsert(.init(device: UUID(), name: "box-1", ssh: "peer-box", nodeKey: "nodekey:peer", identityKey: Data([1])))
        let clock = VirtualClock()
        let dials = Dials()
        let mine = Box<[HostConnection]>([])
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory, connections: { mine.value }) {
            fakeEnv(.state(.running), local: local, root: root, defaults: defaults, calls: EnvCalls())
        }
        switcher.set(true)
        await settled.next { $0 == "chose" }
        #expect(switcher.state == .installed && local.buses == 0)
        let connection = link("peer-box", router: FakeRouter(), dials: dials, clock: clock, root: root)
        connection.router = switcher
        mine.value = [connection]
        let up = links(connection)
        connection.retain()
        #expect(local.buses == 1)
        let first = await dials.next()
        await welcome112(first)
        #expect(await up.next())
        first.close()
        #expect(await up.next() == false)
        await clock.pending(Self.backoff[0])
        // Another peer: nothing. This box's: it dials now, no wait.
        local.push(.peer(nodeID: 1, key: "nodekey:other", online: true))
        local.push(.peer(nodeID: 2, key: "nodekey:peer", online: true))
        _ = await dials.next()
        #expect(dials.hosts.count == 2)
        connection.release()
        await local.busEnded.next()
        #expect(local.buses == 0 && !switcher.busHeld)
        switcher.set(false)
    }

    @Test func anEnrolledBoxIsReachedOverSSHWithThisMacsProofKoreNetOnOrOff() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let secrets = MemorySecrets()
        let identity = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
        let box = FakeNetBox(root: root)
        try box.allow(mac: identity.device, key: identity.signer.publicKey)
        let calls = EnvCalls()
        let env = fakeEnv(.state(.stopped), local: FakeTailnet(), box: box, root: root, defaults: defaults, calls: calls, secrets: secrets)
        try DeviceBook(url: env.support.appendingPathComponent("net/devices.json")).update { $0 = [box.pinned] }
        let directory = NodeDirectory(defaults: defaults)
        directory.upsert(.init(device: box.device, name: "box-1", ssh: "proof-box", nodeKey: box.nodeKey, identityKey: box.identity.publicKey, enrolled: true))
        let (switcher, _) = netSwitch(defaults, root: root, directory: directory) { env }
        // KoreNet off: no tailnet, but the SSH route is `attach --proto 2` with the identity proof.
        let dials = Dials()
        let connection = link("proof-box", router: FakeRouter(), dials: dials, clock: VirtualClock(), root: root)
        connection.router = switcher
        let up = links(connection)
        connection.retain()
        #expect(await up.next())
        #expect(connection.route == .ssh(alias: "proof-box", grant: HostConnection.defaultGrant))
        #expect(box.dialled == [.ssh] && dials.hosts.isEmpty && calls.held.withLock { $0.upgrades } == 1)
        #expect(switcher.state == .off && switcher.tailnet == nil && calls.held.withLock { $0.installed } == 0)
        connection.release()
        // Not enrolled there: today's `attach` with the grant.
        let other = link("grant-box", router: FakeRouter(), dials: dials, clock: VirtualClock(), root: root)
        other.router = switcher
        other.retain()
        _ = await dials.next()
        other.release()
    }

    @Test func aPathChangeBetweenWorkingNetworksIsDebouncedIntoOneRedial() async throws {
        let clock = VirtualClock()
        let fired = Feed<Int>()
        let changes = PathChanges(wait: .seconds(1)) { fired.send(1) }
        changes.sleep = clock.sleep
        func path(_ satisfied: Bool, _ names: String...) -> PathChanges.Path { .init(satisfied: satisfied, interfaces: Set(names)) }
        changes.observe(path(true, "en0", "gw 192.168.1.1"))
        changes.observe(path(true, "en0", "gw 192.168.1.1"))
        #expect(clock.waiting == 0)
        // Wi-Fi to another Wi-Fi: the same interface, another gateway; a roam says it twice.
        changes.observe(path(true, "en0", "gw 10.0.0.1"))
        changes.observe(path(true, "en0", "gw 10.0.0.254"))
        await clock.pending(.seconds(1))
        clock.advance(.seconds(1))
        await fired.next()
        #expect(changes.fired == 1)
        // Wi-Fi to Ethernet.
        changes.observe(path(true, "en7", "gw 10.0.0.254"))
        await clock.pending(.seconds(1))
        clock.advance(.seconds(1))
        await fired.next()
        // Offline, then offline on other interfaces: once.
        changes.observe(path(false))
        changes.observe(path(false, "en0"))
        await clock.pending(.seconds(1))
        clock.advance(.seconds(1))
        await fired.next()
        #expect(changes.fired == 3)
        // Back online: once more, a whole wait after.
        changes.observe(path(true, "en0", "gw 10.0.0.1"))
        await clock.pending(.seconds(1))
        clock.advance(.milliseconds(500))
        #expect(changes.fired == 3)
        clock.advance(.milliseconds(500))
        await fired.next()
        #expect(changes.fired == 4)
    }

    // MARK: Usage

    @Test(arguments: ["claude", "codex"])
    func usagePulledOnLinkUpIsCountedOnce(provider: String) async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = "usage-\(provider)"
        let clock = VirtualClock()
        let dials = Dials()
        let connection = link(alias, router: FakeRouter(), dials: dials, clock: clock, root: root)
        let pulled = Feed<ForwardedRequest>()
        let old = HostConnection.usageSink
        HostConnection.usageSink = { request in if request.chat.hasPrefix(alias + "/") { pulled.send(request) } else { old(request) } }
        defer { HostConnection.usageSink = old }
        let up = links(connection)
        connection.retain()
        let first = await dials.next()
        await welcome112(first)
        let ask = await first.take("usage.since")
        #expect(ask["cursor"] == nil)
        func line(_ n: Int, _ id: String) -> [String: Any] {
            ["n": n, "at": 1_800_000_000_000, "chat": "c1", "provider": provider, "id": id, "model": provider == "codex" ? "gpt-5" : "claude-haiku-4-5",
             "input": 100, "output": 50, "cacheRead": 10, "cacheWrite5m": 0, "cacheWrite1h": 0]
        }
        first.send(json: ["t": "usage.page", "id": try #require(ask["id"]), "lines": [line(1, "r1"), line(2, "r2")], "cursor": 2, "more": false])
        let requests = [await pulled.next(), await pulled.next()]
        // Into the Mac's usage beside the same request counted live from the chat's events: once.
        let support = root.appendingPathComponent("support")
        let usage = KoreUsage(paths: UsagePaths(support: support, caches: nil, claudeProjects: root, codexSessions: root))
        var live = try #require(requests.first)
        live.units /= 2
        await usage.forwarded(live)
        for request in requests { await usage.forwarded(request) }
        let kept = try JSONDecoder().decode([ForwardedRequest].self, from: Data(contentsOf: support.appendingPathComponent("forwarded.json")))
        #expect(kept.count == 2 && Set(kept.map(\.chat)) == [alias + "/c1"] && kept.allSatisfy { $0.units > 0 && $0.cli == provider })
        // Next link-up: from the cursor kept.
        #expect(await up.next())
        first.close()
        #expect(await up.next() == false)
        await clock.pending(Self.backoff[0])
        clock.advance(Self.backoff[0])
        let second = await dials.next()
        await welcome112(second)
        let next = await second.take("usage.since")
        #expect(next["cursor"] as? Int == 2)
        connection.release()
    }
}

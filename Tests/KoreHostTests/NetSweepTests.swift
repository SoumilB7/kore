import Foundation
import KoreNet
import KoreTrust
import Synchronization
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

#if canImport(Darwin)
import Darwin
#endif

/// A tailnet that notes the thread each status read ran on, and whose WhoIs can be held until a
/// test lets it go.
final class WatchedTailnet: Tailnet {
    let inner: FakeTailnet
    /// Whether each `status()` ran on the main thread.
    let reads = Mutex<[Bool]>([])
    let whoisCalls = Mutex(0)
    private let gate = Mutex<DispatchSemaphore?>(nil)

    init(status: TailnetStatus) { inner = FakeTailnet(status: status) }

    /// WhoIs waits from now until `open()`.
    func hold() { gate.withLock { $0 = DispatchSemaphore(value: 0) } }
    func open() {
        guard let held = gate.withLock({ held in defer { held = nil }; return held }) else { return }
        for _ in 0..<64 { held.signal() }
    }

    func status() throws -> TailnetStatus {
        reads.withLock { $0.append(Thread.isMainThread) }
        return try inner.status()
    }
    func whois(_ address: String) throws -> TailnetWhoIs {
        whoisCalls.withLock { $0 += 1 }
        gate.withLock { $0 }?.wait()
        return try inner.whois(address)
    }
    func events() -> AsyncStream<TailnetEvent> { inner.events() }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
}

/// Waits, yielding to the main queue (never sleeping), until `check` holds; false after 5 s.
@MainActor
func eventually(_ check: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while !check() {
        guard ContinuousClock.now < end else { return false }
        await Task.yield()
    }
    return true
}

/// Every descriptor of this process that is a socket bound to TCP `port`.
func descriptors(onPort port: UInt16) -> [Int32] {
    let open = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
    return open.compactMap(Int32.init).filter { fd in
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard ok == 0, Int32(storage.ss_family) == AF_INET || Int32(storage.ss_family) == AF_INET6 else { return false }
        return Sockets.localPort(fd) == port
    }
}

/// The final fix sweep on the box: the regressions each fix answers.
@Suite("korenet sweep, box", .serialized)
@MainActor
struct NetSweepTests {
    func daemon(on: Bool, tailnet: any Tailnet) async throws -> HostRig {
        let rig = try HostRig()
        if on { try HostConfig(folders: [rig.folder.path], net: true).save(rig.paths.config) }
        rig.restart()
        rig.host.makeTailnet = { tailnet }
        rig.host.netPort = 0
        try rig.host.start()
        await rig.host.net?.settled()
        return rig
    }

    /// "Join KoreNet" on a box whose Mac is still on its `attach --as` link (never enrolled, or
    /// enrolled a moment ago): a full grant switches the box's KoreNet on; an act grant can't, and
    /// neither switches it off.
    @Test func aFullLegacyLinkTurnsKoreNetOnAnActOneCant() async throws {
        let tailnet = FakeTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
        let rig = try await daemon(on: false, tailnet: tailnet)
        defer { rig.finish() }
        let grants = GrantStore(rig.paths.grants)
        func linked(_ grant: Grant) async throws -> Client {
            let client = try Client(rig.paths.socket)
            #expect(await eventually { !client.got.isEmpty })
            client.hello(grant: grant)
            #expect(await eventually { client.got.contains { if case .snapshot = $0 { true } else { false } } })
            return client
        }
        func ask(_ client: Client, _ id: String, on: Bool) async -> NetSwitchWire.Result? {
            client.socket.send(DevicesWire.encode(NetSwitchWire.Set(id: id, on: on)))
            _ = await eventually { client.raws.contains { StreamWire.type($0) == NetSwitchWire.result && StreamWire.id($0) == id } }
            return client.raws.lazy.filter { StreamWire.id($0) == id }.compactMap { try? JSONDecoder().decode(NetSwitchWire.Result.self, from: $0) }.first
        }

        let act = try await linked(try grants.allow("tablet", control: .act, socket: rig.paths.socket))
        #expect(await ask(act, "a", on: true)?.ok == false)
        #expect(!rig.host.config.netOn)

        let full = try await linked(try grants.allow("laptop", control: .full, socket: rig.paths.socket))
        let on = await ask(full, "f", on: true)
        #expect(on == .init(id: "f", ok: true, on: true))
        let net = try #require(rig.host.net)
        #expect(rig.host.config.netOn && HostConfig.load(rig.paths.config).netOn && net.listening)
        // Off stays an owner Mac's (proven over KoreNet) to say.
        #expect(await ask(full, "off", on: false)?.ok == false)
        #expect(rig.host.config.netOn)
    }

    /// The status read (a LocalAPI round trip, up to 5 s) never runs on the main thread: not at
    /// start, not on a Mac's `net.set`, not on a rebind.
    @Test func statusIsNeverReadOnTheMainThread() async throws {
        let tailnet = WatchedTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
        let rig = try await daemon(on: true, tailnet: tailnet)
        defer { rig.finish() }
        let net = try #require(rig.host.net)
        #expect(net.listening)
        net.rebind()
        await net.settled()
        try rig.host.setNet(false)
        try rig.host.setNet(true)
        await net.settled()
        let reads = tailnet.reads.withLock { $0 }
        #expect(reads.count >= 3 && !reads.contains(true), "\(reads)")
    }

    /// Why the port isn't bound reaches `status` (another process), and goes once it is.
    @Test func statusSaysWhyThePortIsntBound() async throws {
        let tailnet = FakeTailnet(status: FakeTailnet.status(.stopped, ips: ["127.0.0.1"]))
        let rig = try await daemon(on: true, tailnet: tailnet)
        defer { rig.finish() }
        let net = try #require(rig.host.net)
        func listen() -> String? { HostStatus.net(paths: rig.paths, on: true, tailnet: { tailnet }, portHolder: { nil }).first { $0.hasPrefix("listen") } }
        #expect(listen() == "listen   not listening: Tailscale is Stopped")
        #expect(net.bindProblem == "Tailscale is Stopped")
        tailnet.state.withLock { $0.status = FakeTailnet.status(.running, ips: ["127.0.0.1"]) }
        net.rebind()
        await net.settled()
        let port = try #require(net.firstListener.flatMap(Sockets.localPort))
        #expect(listen() == "listen   listening 127.0.0.1 port \(port)")
        #expect(net.bindProblem == nil)
        try rig.host.setNet(false)
        #expect(listen() == nil)
    }

    /// WhoIs lookups under way count against the 16 handshakes: a flood waiting on a slow
    /// LocalAPI is turned away at the door, not queued as threads.
    @Test func whoisUnderWayCountsAgainstTheRoom() async throws {
        let tailnet = WatchedTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
        tailnet.inner.state.withLock { $0.whois["127.0.0.1"] = FakeTailnet.who(key: "nodekey:lo") }
        tailnet.hold()
        let rig = try await daemon(on: false, tailnet: tailnet)
        defer { rig.finish() }
        // A clock that moves a minute per look: the limiter never turns anyone away here.
        let minutes = Mutex(Date(timeIntervalSince1970: 0))
        let net = HostNet(
            host: rig.host, identity: try BoxIdentity.loadOrCreate(rig.paths), port: 0,
            limiter: PreAuthLimiter(clock: { minutes.withLock { $0 = $0.addingTimeInterval(61); return $0 } }))
        net.join(tailnet)
        await net.settled()
        defer {
            tailnet.open()
            net.stop()
        }
        let port = try #require(net.firstListener.flatMap(Sockets.localPort))
        var clients: [Int32] = []
        defer { clients.forEach(Sockets.closeFD) }
        var refused = 0
        for i in 0..<(HostNet.maxHandshakes + 4) {
            let fd = try Sockets.connectTCP(try #require(IPAddress("127.0.0.1")), port: port)
            clients.append(fd)
            if i < HostNet.maxHandshakes {
                #expect(await eventually { tailnet.whoisCalls.withLock { $0 } == i + 1 })
            } else {
                // Closed unread: the read sees the end.
                Sockets.setNonBlocking(fd)
                if await eventually({ (try? Sockets.read(fd, max: 16))?.isEmpty == true }) { refused += 1 }
            }
        }
        #expect(refused == 4)
        #expect(tailnet.whoisCalls.withLock { $0 } == HostNet.maxHandshakes && net.whoising == HostNet.maxHandshakes)
    }

    /// Every descriptor on the tailnet port (the listener, an accepted connection, a source's
    /// duplicate) and the `net.sock` listener close at exec: none leaks into `gh`, `git` or a CLI.
    @Test func everyKoreNetDescriptorClosesOnExec() async throws {
        let tailnet = FakeTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
        tailnet.state.withLock { $0.whois["127.0.0.1"] = FakeTailnet.who(key: "nodekey:lo") }
        let rig = try await daemon(on: true, tailnet: tailnet)
        defer { rig.finish() }
        let net = try #require(rig.host.net)
        let port = try #require(net.firstListener.flatMap(Sockets.localPort))
        let client = try Sockets.connectTCP(try #require(IPAddress("127.0.0.1")), port: port)
        defer { Sockets.closeFD(client) }
        #expect(await eventually { net.handshaking(.tailnet) == 1 })
        // The client's own end is on an ephemeral port: these are the box's.
        let held = descriptors(onPort: port)
        #expect(held.count >= 3, "listener, accepted, its source's duplicate: \(held)")
        #expect(held.allSatisfy(Sockets.closesOnExec), "\(held.map { ($0, Sockets.closesOnExec($0)) })")
        // `net.sock`'s listener.
        let unix = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap(Int32.init).filter { fd in
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            guard ok == 0, Int32(address.sun_family) == AF_UNIX else { return false }
            let path = withUnsafeBytes(of: &address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return path == rig.paths.netSocket.path
        }
        #expect(!unix.isEmpty && unix.allSatisfy(Sockets.closesOnExec))
    }

    /// `attach --proto 2` whose client side can't take bytes (stdout gone) ends, never drops them
    /// and carries on with a broken stream.
    @Test func netAttachEndsWhenItCantPassBytesOn() async throws {
        let root = URL(fileURLWithPath: "/tmp/kna-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("net.sock")
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Sockets.closeFD(listener) }
        #expect(HostListener.bind(listener, path.path) == 0 && Darwin.listen(listener, 1) == 0)
        let grant = try GrantStore(root.appendingPathComponent("grants")).allow("laptop", control: .full, socket: path)
        let (input, inputPeer) = try Sockets.pair()
        defer { Sockets.closeFD(inputPeer) }
        // A client side that takes no bytes at all.
        let output = open("/dev/null", O_RDONLY)
        defer { Sockets.closeFD(output) }
        var code: Int32?
        let attach = try NetAttach(grant: grant, socket: path, input: input, output: output) { code = $0 }
        let daemon = Sockets.accept(listener)
        defer { Sockets.closeFD(daemon) }
        attach.start()
        try Sockets.writeAll(daemon, Data("frame".utf8))
        #expect(await eventually { code != nil })
        #expect(code == AttachExit.ended.rawValue)
        // The other way too: a daemon side gone.
        #expect(!NetAttach.write(-1, Data([1])))
        Sockets.closeFD(input)
    }

    /// `kore-host update` (and Kore's box Update, which runs `install-service`) writes the unit
    /// as this release does, so an old unit's rules don't outlive it, and restarts it.
    @Test func anUpdateRewritesTheUnitAndRestartsIt() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let home = rig.root.appendingPathComponent("home")
        let unit = HostService.unitFile(home: home)
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[Service]\nExecStart=/opt/kore-host run\nRestart=on-failure\n".utf8).write(to: unit)
        let ran = Mutex<[[String]]>([])
        let said = HostUpdate.restart(paths: rig.paths, home: home, executable: "/opt/kore-host", user: "u") { args in
            ran.withLock { $0.append(args) }
            return args.starts(with: ["loginctl", "show-user"]) ? HostRan(status: 0, output: "yes\n") : HostRan(status: 0)
        }
        let text = try String(contentsOf: unit, encoding: .utf8)
        #expect(text.contains("Restart=always") && !text.contains("on-failure"))
        let systemctl = ran.withLock { $0 }.filter { $0.first == "systemctl" }.map { $0.dropFirst(2).joined(separator: " ") }
        #expect(systemctl.suffix(3) == ["daemon-reload", "enable kore-host.service", "restart kore-host.service"])
        #expect(said.hasSuffix("kore-host is running (/opt/kore-host)"))
    }

    /// Kore's "is kore-host there?" probe (a connect, closed at once) costs none of a source's
    /// three handshakes a minute; one that speaks still does.
    @Test func aSilentProbeSpendsNoPreAuthSlot() async throws {
        let tailnet = WatchedTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
        tailnet.inner.state.withLock { $0.whois["127.0.0.1"] = FakeTailnet.who(key: "nodekey:lo") }
        let rig = try await daemon(on: true, tailnet: tailnet)
        defer { rig.finish() }
        let net = try #require(rig.host.net)
        let port = try #require(net.firstListener.flatMap(Sockets.localPort))
        let lo = try #require(IPAddress("127.0.0.1"))
        for i in 0..<5 {
            Sockets.closeFD(try Sockets.connectTCP(lo, port: port))
            // Accepted, looked up, greeted and let go.
            #expect(await eventually { tailnet.whoisCalls.withLock { $0 } == i + 1 && net.whoising == 0 && net.handshaking(.tailnet) == 0 })
        }
        // A real client still gets its challenge.
        let fd = try Sockets.connectTCP(lo, port: port)
        defer { Sockets.closeFD(fd) }
        Sockets.setNonBlocking(fd)
        var got: [UInt8]?
        #expect(await eventually {
            got = try? Sockets.read(fd, max: 64)
            return got != nil
        })
        #expect(got?.isEmpty == false, "closed unread: the probes spent the source's slots")
    }
}

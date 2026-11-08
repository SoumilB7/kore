import Foundation
import KoreHostSys
@testable import KoreNet
import KoreTrust
import Tailnet
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A Mac (client) and a box (server) over an in-memory socketpair, each with its own device book
/// in a scratch folder and a hand-turned clock.
final class Pairing {
    let folder: URL
    let macKey = SoftwareIdentity()
    let boxKey = SoftwareIdentity()
    let mac: DeviceRecord
    let box: DeviceRecord
    let macBook: DeviceBook
    let boxBook: DeviceBook
    let clock = FakeClock()
    let tickets = ResumeTickets()

    init(macAbilities: Ability = .run, boxKnowsMac: Bool = true) throws {
        folder = try TestKit.scratch("session")
        mac = TestKit.record(kind: .mac, abilities: macAbilities, key: macKey, nodeKeys: ["nodekey:mac"], owner: true)
        box = TestKit.record(kind: .box, abilities: .run, key: boxKey, nodeKeys: ["nodekey:box"])
        macBook = DeviceBook(url: folder.appendingPathComponent("mac/devices.json"))
        boxBook = DeviceBook(url: folder.appendingPathComponent("box/devices.json"))
        try macBook.update { $0 = [self.box] }
        if boxKnowsMac { try boxBook.update { $0 = [self.mac] } }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func server(fd: Int32, sawNodeKey: String = "nodekey:mac", sawUser: Int64? = 7) -> NetSession {
        let local = NetLocal(device: box.id, kind: .box, nodeKey: "nodekey:box", signer: boxKey)
        let setup = NetSession.Server(local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: sawNodeKey, userId: sawUser), book: boxBook, tickets: tickets)
        return NetSession(fd: fd, role: .server(setup), clock: clock.function)
    }

    func client(fd: Int32, ownNodeKey: String = "nodekey:mac", service: String = "link", resume: NetControl.Resume? = nil) -> NetSession {
        let local = NetLocal(device: mac.id, kind: .mac, nodeKey: ownNodeKey, signer: macKey)
        let setup = NetSession.Client(local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: "nodekey:box", userId: 7), book: macBook, server: box.id, service: service, resume: resume)
        return NetSession(fd: fd, role: .client(setup), clock: clock.function)
    }

    /// Both ends of a fresh pair, the server's challenge sent.
    func connect(sawNodeKey: String = "nodekey:mac", sawUser: Int64? = 7, ownNodeKey: String = "nodekey:mac", service: String = "link",
                 resume: NetControl.Resume? = nil) throws -> (client: NetSession, server: NetSession) {
        let (a, b) = try Sockets.pair()
        let s = server(fd: b, sawNodeKey: sawNodeKey, sawUser: sawUser)
        let c = client(fd: a, ownNodeKey: ownNodeKey, service: service, resume: resume)
        s.start()
        _ = Self.run(c, s)
        return (c, s)
    }

    /// Pumps both until two rounds pass with nothing received or waiting (or `rounds` run out);
    /// what each received.
    @discardableResult
    static func run(_ c: NetSession, _ s: NetSession, rounds: Int = 400) -> (client: [NetMessage], server: [NetMessage]) {
        var got: ([NetMessage], [NetMessage]) = ([], [])
        var idle = 0
        for _ in 0..<rounds {
            let a = c.pump(), b = s.pump()
            got.0 += a
            got.1 += b
            idle = a.isEmpty && b.isEmpty && !c.wantsWrite && !s.wantsWrite ? idle + 1 : 0
            if idle >= 2 { break }
        }
        return got
    }
}

extension NetSession.State {
    var peer: NetPeer? {
        if case .established(let p) = self { return p }
        return nil
    }
}

@Suite("net session")
struct SessionTests {
    @Test func handshakeProvesBothSides() throws {
        let p = try Pairing()
        let (c, s) = try p.connect()
        let atBox = try #require(s.state.peer)
        let atMac = try #require(c.state.peer)
        #expect(atBox.record.id == p.mac.id && atBox.abilities == [.read, .ask, .run] && atBox.service == "link")
        #expect(atMac.record.id == p.box.id && atMac.abilities == atBox.abilities)
        #expect(atMac.ticket == atBox.ticket && atMac.ticket.count == ResumeTickets.size)
        #expect(!atBox.resumed && s.deadline == nil && c.deadline == nil)
    }

    @Test func messagesFlowAndCreditComesBack() throws {
        let p = try Pairing()
        let (c, s) = try p.connect()
        let before = c.credit
        try c.send(Data("cmd".utf8), queue: .interactive, stream: 1)
        try c.send(Data(count: 200_000), queue: .stream, stream: 2)
        try s.send(Data("result".utf8), queue: .interactive, stream: 1)
        let got = Pairing.run(c, s)
        #expect(got.server.map(\.stream) == [1, 2])
        #expect(got.server[1].payload.count == 200_000)
        #expect(got.client == [NetMessage(queue: .interactive, stream: 1, payload: Data("result".utf8))])
        #expect(c.credit == before)
        #expect(throws: NetSessionError.controlStream) { try c.send(Data(), queue: .interactive, stream: 0) }
    }

    /// Over a real socket: a 1 MiB stream message is under way when a command is queued; the
    /// command arrives first.
    @Test func interactiveOvertakesOverTheSocket() throws {
        let p = try Pairing()
        let (c, s) = try p.connect()
        try c.send(Data(repeating: 3, count: 1 << 20), queue: .stream, stream: 5)
        #expect(c.wantsWrite)
        try c.send(Data("stop".utf8), queue: .interactive, stream: 6)
        let got = Pairing.run(c, s, rounds: 2000)
        #expect(got.server.map(\.stream) == [6, 5])
        #expect(got.server.last?.payload == Data(repeating: 3, count: 1 << 20))
    }

    @Test func aMITMNodeKeyFailsTheProof() throws {
        let p = try Pairing()
        // The box's WhoIs of the caller sees another node than the Mac's own Status.
        let (c, s) = try p.connect(sawNodeKey: "nodekey:mitm")
        #expect(s.state == .closed(NetControl.Reason.proof))
        #expect(c.state == .closed("bye proof"))
    }

    @Test func anUnknownDeviceGetsByeUnknown() throws {
        let p = try Pairing(boxKnowsMac: false)
        let (c, s) = try p.connect()
        #expect(s.state == .closed(NetControl.Reason.unknown))
        #expect(c.state == .closed("bye unknown"))
    }

    @Test func tooLittleAbilityIsRefusedByThePolicyTable() throws {
        let p = try Pairing(macAbilities: [.read, .ask])
        let (_, s) = try p.connect()
        #expect(s.state == .closed(NetControl.Reason.refused))
    }

    @Test func anUnknownServiceIsRefused() throws {
        let p = try Pairing()
        let (_, s) = try p.connect(service: "shell")
        #expect(s.state == .closed(NetControl.Reason.service))
    }

    @Test func aRotatedNodeKeyIsKeptAfterTheProof() throws {
        let p = try Pairing()
        let (_, s) = try p.connect(sawNodeKey: "nodekey:mac2", ownNodeKey: "nodekey:mac2")
        #expect(s.state.peer != nil)
        #expect(try p.boxBook.record(p.mac.id)?.nodeKeys == ["nodekey:mac", "nodekey:mac2"])
        // From another Tailscale user, the same proof keeps nothing and opens nothing.
        let q = try Pairing()
        let (_, t) = try q.connect(sawNodeKey: "nodekey:mac2", sawUser: 8, ownNodeKey: "nodekey:mac2")
        #expect(t.state == .closed(NetControl.Reason.proof))
        #expect(try q.boxBook.record(q.mac.id)?.nodeKeys == ["nodekey:mac"])
    }

    @Test func resumeTicketsAreSingleUseAndCursorsFollowTheWelcome() throws {
        let p = try Pairing()
        let first = try p.connect().client.state.peer!.ticket
        let cursors: [String: JSONValue] = ["chat.events": .object(["log": .string("c-1"), "s": .int(42)])]
        let (c, s) = try p.connect(resume: .init(ticket: first, cursors: cursors))
        #expect(s.state.peer!.resumed && s.cursors == cursors)
        // The service's own messages come after, untouched.
        try c.send(Data("cmd".utf8), queue: .interactive, stream: 1)
        #expect(Pairing.run(c, s).server.map(\.stream) == [1])
        let third = try p.connect(resume: .init(ticket: first, cursors: cursors))
        #expect(!third.server.state.peer!.resumed && third.server.cursors == cursors)
        // No cursors, no message.
        #expect(try p.connect().server.cursors == nil)
    }

    /// The hello is the one pre-auth frame: with a ticket it stays far under 4 KiB, whatever the
    /// client's cursors.
    @Test func helloStaysSmall() throws {
        let hello = NetControl.hello(.init(
            service: "link", device: UUID(), nonce: Data(count: 32), sig: Data(count: 72), credit: NetSession.initialCredit,
            ticket: Data(count: ResumeTickets.size)))
        let frame = NetFrame(queue: .interactive, stream: 0, payload: try hello.encoded()).encoded
        #expect(frame.count < 512)
    }
}

/// What a server takes before the hello is verified: one control frame ≤ 4 KiB within 2 s.
@Suite("pre-auth limits")
struct PreAuthTests {
    func server() throws -> (Pairing, NetSession, Int32) {
        let p = try Pairing()
        let (raw, b) = try Sockets.pair()
        let s = p.server(fd: b)
        s.start()
        _ = s.pump()
        return (p, s, raw)
    }

    @Test func aFrameOverFourKiBEndsIt() throws {
        let (_, s, raw) = try server()
        defer { Sockets.closeFD(raw) }
        try Sockets.writeAll(raw, NetFrame(queue: .interactive, stream: 0, payload: Data(count: 5000)).encoded.prefix(4096))
        _ = s.pump()
        #expect(s.state == .closed(NetControl.Reason.limit))
    }

    @Test func silenceEndsItAtTwoSeconds() throws {
        let (p, s, raw) = try server()
        defer { Sockets.closeFD(raw) }
        p.clock.advance(1.9)
        _ = s.pump()
        #expect(s.state == .handshaking)
        p.clock.advance(0.1)
        _ = s.pump()
        #expect(s.state == .closed(NetControl.Reason.timeout))
    }

    @Test func aDataFrameBeforeTheHelloEndsIt() throws {
        let (_, s, raw) = try server()
        defer { Sockets.closeFD(raw) }
        try Sockets.writeAll(raw, NetFrame(queue: .interactive, stream: 1, payload: Data("x".utf8)).encoded)
        _ = s.pump()
        #expect(s.state == .closed(NetControl.Reason.limit))
    }

    @Test func aControlMessageOtherThanHelloEndsIt() throws {
        let (_, s, raw) = try server()
        defer { Sockets.closeFD(raw) }
        try Sockets.writeAll(raw, NetFrame(queue: .interactive, stream: 0, payload: Data("{\"t\":\"credit\",\"n\":1}".utf8)).encoded)
        _ = s.pump()
        #expect(s.state == .closed(NetControl.Reason.protocolError))
    }

    @Test func threeConnectionsPerMinutePerSource() {
        let clock = FakeClock()
        let limiter = PreAuthLimiter(clock: clock.function)
        #expect((0..<3).allSatisfy { _ in limiter.admit("100.64.0.9") })
        #expect(!limiter.admit("100.64.0.9"))
        #expect(limiter.admit("100.64.0.10"))
        clock.advance(60)
        #expect(limiter.admit("100.64.0.9"))
    }

    @Test func aClientGivesUpAfterTwentySeconds() throws {
        let p = try Pairing()
        let (a, raw) = try Sockets.pair()
        defer { Sockets.closeFD(raw) }
        let c = p.client(fd: a)
        p.clock.advance(19.9)
        _ = c.pump()
        #expect(c.state == .handshaking)
        p.clock.advance(0.1)
        _ = c.pump()
        #expect(c.state == .closed(NetControl.Reason.timeout))
    }
}

@Suite("paths and listener")
struct PathsListenerTests {
    @Test func tailnetFirstThenSSH() {
        #expect(NetPaths.ordered([.ssh, .tailnet]) == [.tailnet, .ssh])
        #expect(NetPaths.ordered([.ssh]) == [.ssh])
        #expect(NetPaths.replaces(incoming: .tailnet, existing: .ssh))
        #expect(!NetPaths.replaces(incoming: .ssh, existing: .tailnet))
        #expect(NetPaths.replaces(incoming: .tailnet, existing: .tailnet))
        var backoff = NetPaths.Backoff()
        #expect((0..<8).map { _ in backoff.next() } == [1, 2, 5, 10, 30, 60, 60, 60])
        backoff.reset()
        #expect(backoff.next() == 1)
        #expect(ServiceTable.v1.entries.keys.sorted() == ["link", "pipe"])
    }

    @Test(arguments: ["0.0.0.0", "::", "::0", "0:0:0:0:0:0:0:0", "", "*", "0000::"])
    func wildcardsAreRefused(_ address: String) {
        #expect(throws: SocketError.wildcard(address)) { try NetListener(addresses: [address], port: 0) }
        #expect(throws: SocketError.wildcard(address)) { try Sockets.listenTCP(address, port: 0) }
    }

    @Test func onlyGivenAndAllowedAddressesBind() throws {
        #expect(throws: SocketError.wildcard("")) { try NetListener(addresses: [], port: 0) }
        #expect(throws: SocketError.badAddress("127.0.0.1")) { try NetListener(addresses: ["127.0.0.1"], port: 0, allowed: ["100.64.0.1"]) }
        #expect(throws: SocketError.badAddress("mybox")) { try NetListener(addresses: ["mybox"], port: 0) }
        let listener = try NetListener(addresses: ["127.0.0.1"], port: 0, allowed: ["127.0.0.1"])
        defer { listener.close() }
        #expect(listener.sockets.count == 1)
        let port = try #require(Sockets.localPort(listener.sockets[0].fd))
        // It holds the address given, not the wildcard.
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.sockets[0].fd, $0, &length) } }
        #expect(storage.sin_addr.s_addr == inet_addr("127.0.0.1"))
        #expect(port > 0)
    }

    @Test func acceptedConnectionsPassTheLimiter() throws {
        let clock = FakeClock()
        let listener = try NetListener(addresses: ["127.0.0.1"], port: 0, limiter: PreAuthLimiter(clock: clock.function))
        defer { listener.close() }
        let port = try #require(Sockets.localPort(listener.sockets[0].fd))
        var admitted = 0
        var dialled: [Int32] = []
        for _ in 0..<4 {
            dialled.append(try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: port))
            if let (fd, remote) = try listener.accept(on: listener.sockets[0]) {
                #expect(remote == "127.0.0.1")
                Sockets.closeFD(fd)
                admitted += 1
            }
        }
        for fd in dialled { Sockets.closeFD(fd) }
        #expect(admitted == 3)
    }

    /// A TCP session gets TCP_NODELAY and TCP_NOTSENT_LOWAT 16 KiB.
    @Test func tcpSessionsAreTuned() throws {
        let listener = try Sockets.listenTCP("127.0.0.1", port: 0)
        defer { Sockets.closeFD(listener) }
        let dialled = try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: Sockets.localPort(listener)!)
        let accepted = Sockets.accept(listener)
        defer { Sockets.closeFD(accepted) }
        let p = try Pairing()
        let session = p.client(fd: dialled)
        #expect(kore_tcp_notsent_lowat(dialled) == Int32(NetSession.notSentLowWater))
        var nodelay: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(dialled, Int32(IPPROTO_TCP), TCP_NODELAY, &nodelay, &size)
        #expect(nodelay != 0)
        session.close("done")
    }
}

import Foundation
import KoreTrust
import Synchronization
@testable import Tailnet
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A trimmed LocalAPI status (spike 0a's shape, with fields KoreNet ignores left in).
let statusJSON = #"""
{"Version":"1.104.5","BackendState":"Running","HaveNodeKey":true,"TailscaleIPs":["100.91.66.71","fd7a:115c:a1e0::3738:4248"],
"Self":{"ID":"nHM","PublicKey":"nodekey:1387","HostName":"mybox","UserID":118279842635465,"TailscaleIPs":["100.91.66.71","fd7a:115c:a1e0::3738:4248"],"Online":true,"CapMap":{"default-auto-update":[true],"https://tailscale.com/cap/is-admin":null}},
"Peer":{"nodekey:0b99":{"PublicKey":"nodekey:0b99","UserID":118279842635465,"TailscaleIPs":["100.104.65.22"],"Online":true,"OS":"macOS"},
        "nodekey:4bd1":{"PublicKey":"nodekey:4bd1","TailscaleIPs":["100.70.1.2"],"Online":false,"Tags":["tag:box"]}},
"User":{"118279842635465":{"ID":118279842635465,"LoginName":"owner@example.com"}}}
"""#

let whoisJSON = #"""
{"Node":{"ID":5810962271697991,"Name":"phone.tail.ts.net.","User":1,"Key":"nodekey:0b99","Addresses":["100.104.65.22/32"],"Tags":["tag:phone"]},
"UserProfile":{"ID":42,"LoginName":"tagged-devices","DisplayName":"Tagged Devices"},
"CapMap":{"kore.invalid/cap/kore":[{"v":1,"abilities":["read","ask","run"]}],"other":null}}
"""#

/// Hands out prepared connections in order (each a fake server), counting discoveries.
final class Script: Sendable {
    let server = FakeHTTPServer()
    private let answers: Mutex<[String?]>
    private let found: Mutex<[LocalAPIEndpoint]>
    let discoveries = Mutex(0)

    /// `nil` in `answers`: that connect fails.
    init(answers: [String?], endpoints: [LocalAPIEndpoint] = [.tcp(port: 41112, token: "tok-1")]) {
        self.answers = Mutex(answers)
        self.found = Mutex(endpoints)
    }

    var client: LocalAPIClient {
        LocalAPIClient(
            discover: {
                self.discoveries.withLock { $0 += 1 }
                return self.found.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
            },
            connect: { _ in
                guard let answer = self.answers.withLock({ $0.removeFirst() }) else { throw SocketError.failed("connect", ECONNREFUSED) }
                return try self.server.connection(answering: answer)
            })
    }
}

@Suite("tailnet local api")
struct LocalAPITests {
    @Test func statusDecodesOnlyWhatsUsed() throws {
        let script = Script(answers: [FakeHTTPServer.ok(statusJSON)])
        let status = try TailnetLocal(api: script.client).status()
        #expect(status.backendState == .running)
        #expect(status.selfNode == .init(publicKey: "nodekey:1387", tailscaleIPs: ["100.91.66.71", "fd7a:115c:a1e0::3738:4248"], userID: 118279842635465))
        #expect(status.peers.map(\.publicKey) == ["nodekey:0b99", "nodekey:4bd1"])
        #expect(status.peers[1].tags == ["tag:box"] && !status.peers[1].online)
        let request = try #require(script.server.requests.first)
        #expect(request.hasPrefix("GET /localapi/v0/status HTTP/1.1\r\n"))
        #expect(request.contains("Host: local-tailscaled.sock\r\n"))
        #expect(request.contains("Authorization: Basic \(Data(":tok-1".utf8).base64EncodedString())\r\n"))
    }

    @Test func whoisGivesKeyTagsUserAndCapability() throws {
        let script = Script(answers: [FakeHTTPServer.chunked([String(whoisJSON.prefix(40)), String(whoisJSON.dropFirst(40))])])
        let whois = try TailnetLocal(api: script.client).whois("fd7a:115c:a1e0::3738:4248")
        #expect(whois.node.key == "nodekey:0b99" && whois.node.tags == ["tag:phone"] && whois.node.name == "phone.tail.ts.net.")
        #expect(whois.userId == nil && whois.user.loginName == "tagged-devices")
        #expect(AppCap.abilities(capMap: whois.capMap, tagged: !whois.node.tags.isEmpty) == [.read, .ask])
        #expect(script.server.requests.first?.hasPrefix("GET /localapi/v0/whois?addr=%5Bfd7a:115c:a1e0::3738:4248%5D:1 ") == true)
        #expect(TailnetLocal.whoisAddress("100.64.0.1") == "100.64.0.1:1")
        #expect(TailnetLocal.whoisAddress("100.64.0.1:47470") == "100.64.0.1:47470")
    }

    @Test func a401FindsTheEndpointAgainOnce() throws {
        let script = Script(
            answers: [FakeHTTPServer.unauthorized, FakeHTTPServer.ok(statusJSON)],
            endpoints: [.tcp(port: 41112, token: "old"), .tcp(port: 41113, token: "new")])
        _ = try TailnetLocal(api: script.client).status()
        #expect(script.discoveries.withLock { $0 } == 2)
        #expect(script.server.requests.count == 2)
        #expect(script.server.requests[1].contains(Data(":new".utf8).base64EncodedString()))
        // Refused twice: unauthorized, no third try.
        let refused = Script(answers: [FakeHTTPServer.unauthorized, FakeHTTPServer.unauthorized, FakeHTTPServer.ok(statusJSON)])
        #expect(throws: TailnetError.unauthorized) { try TailnetLocal(api: refused.client).status() }
        #expect(refused.server.requests.count == 2)
    }

    @Test func aRefusedConnectFindsTheEndpointAgain() throws {
        let script = Script(answers: [nil, FakeHTTPServer.ok(statusJSON)])
        #expect(try TailnetLocal(api: script.client).status().backendState == .running)
        #expect(script.discoveries.withLock { $0 } == 2)
    }

    @Test func otherStatusesAndUnavailable() throws {
        let script = Script(answers: ["HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n"])
        #expect(throws: TailnetError.http(500)) { try TailnetLocal(api: script.client).status() }
        let none = LocalAPIClient(discover: { .unavailable(.appStore) }, connect: { _ in Issue.record("connected"); return -1 })
        #expect(throws: TailnetError.unavailable(.appStore)) { try TailnetLocal(api: none).status() }
        let bad = Script(answers: [FakeHTTPServer.ok("{\"BackendState\":3}")])
        #expect(throws: TailnetError.malformed("TailnetStatus")) { try TailnetLocal(api: bad.client).status() }
    }

    @Test func dialAndListenStayOnTheTailnet() throws {
        let tailnet = TailnetLocal(api: Script(answers: [FakeHTTPServer.ok(#"{"BackendState":"NeedsLogin","Self":null}"#)]).client)
        #expect(throws: TailnetError.notTailnet("192.168.1.9")) { try tailnet.dial("192.168.1.9", port: 47470) }
        #expect(throws: TailnetError.notRunning(.needsLogin)) { try tailnet.listen(port: 47470) }
        #expect(IPAddress("100.64.0.1")!.isTailnet && IPAddress("100.127.255.255")!.isTailnet)
        #expect(!IPAddress("100.128.0.1")!.isTailnet && !IPAddress("100.63.0.1")!.isTailnet)
        #expect(IPAddress("fd7a:115c:a1e0::1")!.isTailnet && !IPAddress("fd7a:115c:a1e1::1")!.isTailnet)
        #expect(IPAddress("fe80::1%en0") == nil)
    }

    /// The bus: a long-lived chunked body of JSON lines. Engine messages give no events; lines
    /// split across chunks still parse; the stream ends with the body.
    @Test func busDropsEngineMessages() async throws {
        let engine = #"{"Version":"1.104","Engine":{"RBytes":1,"WBytes":2,"NumLive":1,"LiveDERPs":1}}"#
        let initial = #"{"Version":"1.104","SessionID":"s","State":6,"InitialStatus":\#(statusJSON.replacingOccurrences(of: "\n", with: ""))}"#
        let peer = #"{"Version":"1.104","PeerChanges":[{"NodeID":77,"Online":false,"Key":"nodekey:0b99"}]}"#
        let body = [initial, engine, engine, peer, engine].map { $0 + "\n" }.joined()
        let parts = stride(from: 0, to: body.utf8.count, by: 97).map { i in
            String(decoding: Array(body.utf8)[i..<min(i + 97, body.utf8.count)], as: UTF8.self)
        }
        let script = Script(answers: [FakeHTTPServer.chunked(parts)])
        var events: [TailnetEvent] = []
        for await event in TailnetLocal(api: script.client).events() { events.append(event) }
        #expect(events.count == 3)
        #expect(events.first == .state(.running))
        if case .status(let s) = events[1] { #expect(s.backendState == .running) } else { Issue.record("no status") }
        #expect(events.last == .peer(nodeID: 77, key: "nodekey:0b99", online: false))
        #expect(script.server.requests.first?.hasPrefix("GET /localapi/v0/watch-ipn-bus?mask=49154 ") == true)
    }

    @Test func endingTheBusStreamClosesTheConnection() async throws {
        let (client, server) = try Sockets.pair()
        defer { Sockets.closeFD(server) }
        let api = LocalAPIClient(discover: { .unix("/x") }, connect: { _ in client })
        do {
            var events = TailnetLocal(api: api).events().makeAsyncIterator()
            var request = Data()
            while !request.contains(Data("\r\n\r\n".utf8)) { request.append(contentsOf: try Sockets.read(server, max: 4096)) }
            // Head and one message, then the server stays quiet: only ending the stream frees the read.
            try Sockets.writeAll(server, Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nc\r\n{\"State\":4}\n\r\n".utf8))
            #expect(await events.next() == .state(.stopped))
        }
        // The iterator is gone: the client's end is shut, which the server reads as its end.
        #expect(Sockets.wait(server, write: false, timeoutMs: 5000))
        #expect(try Sockets.read(server, max: 16).isEmpty)
    }

    @Test func chunkSizesWithExtensionsAndSplitLines() throws {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;x=y\r\n{\"a\r\n2\r\n\":\r\n2\r\n1}\r\n0\r\n\r\n"
        let script = Script(answers: [response])
        #expect(try script.client.get("/x") == Data("{\"a\":1}".utf8))
        let bad = Script(answers: ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"])
        #expect(throws: TailnetError.malformed("chunk size")) { try bad.client.get("/x") }
    }
}

@Suite("tailnet discovery and choice")
struct DiscoveryTests {
    @Test func linuxSocket() throws {
        let root = try TestKit.scratch("disc")
        defer { try? FileManager.default.removeItem(at: root) }
        let linux = LocalAPIDiscovery(platform: .linux, root: root.path)
        #expect(linux.find() == .unavailable(.absent))
        try FileManager.default.createDirectory(atPath: root.path + "/var/run/tailscale", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.path + LocalAPIDiscovery.linuxSocket, contents: nil)
        #expect(linux.find() == .unix(root.path + LocalAPIDiscovery.linuxSocket))
    }

    @Test func macStandaloneAppStoreAndUnreadable() throws {
        let root = try TestKit.scratch("disc")
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = LocalAPIDiscovery(platform: .mac, root: root.path)
        #expect(mac.find() == .unavailable(.absent))
        try FileManager.default.createDirectory(atPath: root.path + "/Applications/Tailscale.app", withIntermediateDirectories: true)
        #expect(mac.find() == .unavailable(.appStore))
        try FileManager.default.createDirectory(atPath: root.path + "/Library/Tailscale", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.path + LocalAPIDiscovery.macPortLink, withDestinationPath: "41112")
        #expect(mac.find() == .unavailable(.unreadable))
        try "tok-xyz\n".write(toFile: root.path + LocalAPIDiscovery.macTokenPrefix + "41112", atomically: true, encoding: .utf8)
        #expect(mac.find() == .tcp(port: 41112, token: "tok-xyz"))
        chmod(root.path + LocalAPIDiscovery.macTokenPrefix + "41112", 0)
        #expect(mac.find() == .unavailable(.unreadable))
    }

    @Test(arguments: [
        (TailnetChooser.Installed.state(.running), TailnetChooser.Choice.installed),
        (.state(.starting), .installed),
        (.state(.stopped), .sshOnly),
        (.state(.needsLogin), .sidecar),
        (.state(.noState), .sidecar),
        (.missing(.absent), .sidecar),
        (.missing(.appStore), .sidecar),
        (.missing(.unreadable), .sidecar),
    ])
    func choice(_ installed: TailnetChooser.Installed, _ want: TailnetChooser.Choice) {
        #expect(TailnetChooser.choose(installed) == want)
    }

    @Test func choiceFollowsBusEventsOnly() async {
        let (events, feed) = AsyncStream<TailnetEvent>.makeStream()
        feed.yield(.state(.running))
        feed.yield(.peer(nodeID: 1, key: nil, online: true))
        feed.yield(.state(.stopped))
        feed.yield(.status(TailnetStatus(backendState: .stopped, selfNode: nil)))
        feed.yield(.state(.needsLogin))
        feed.finish()
        var got: [TailnetChooser.Choice] = []
        for await choice in TailnetChooser.follow(.state(.running), events: events) { got.append(choice) }
        #expect(got == [.installed, .sshOnly, .sidecar])
    }
}

final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// The `kore-tailnet` sidecar's socket, played by a thread on a real Unix socket in a scratch
/// folder: replies, handed-off descriptors, refusals.
@Suite("tailnet sidecar")
struct SidecarTests {
    final class FakeSidecar: Sendable {
        let path: String
        let listener: Int32
        let requests = Mutex<[[String: JSONValue]]>([])

        init(_ folder: URL) throws {
            let path = folder.appendingPathComponent("t.sock").path
            self.path = path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                let bytes = Array(path.utf8)
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else { throw SocketError.failed("bind", errno) }
            listener = fd
        }

        /// Serves one connection with `answer`, which writes whatever replies it likes.
        func serveOnce(_ answer: @escaping @Sendable (Int32, [String: JSONValue]) throws -> Void) {
            Thread.detachNewThread { [self] in
                let fd = Darwin.accept(listener, nil, nil)
                defer { close(fd) }
                guard let (data, _) = try? SidecarWire.receive(fd), let data,
                      let request = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return }
                requests.withLock { $0.append(request) }
                try? answer(fd, request)
            }
        }

        func stop() { close(listener) }
    }

    @Test func statusAndWhoisReplies() throws {
        let folder = try TestKit.scratch("car")
        defer { try? FileManager.default.removeItem(at: folder) }
        let car = try FakeSidecar(folder)
        defer { car.stop() }
        car.serveOnce { fd, _ in try SidecarWire.send(fd, Data("{\"ok\":true,\"status\":\(statusJSON)}".utf8)) }
        let sidecar = TailnetSidecar(path: car.path)
        #expect(try sidecar.status().selfNode?.publicKey == "nodekey:1387")
        car.serveOnce { fd, _ in try SidecarWire.send(fd, Data("{\"ok\":true,\"whois\":\(whoisJSON)}".utf8)) }
        #expect(try sidecar.whois("100.104.65.22").node.key == "nodekey:0b99")
        car.serveOnce { fd, _ in try SidecarWire.send(fd, Data(#"{"ok":false,"error":"NeedsLogin"}"#.utf8)) }
        #expect(throws: TailnetError.sidecar("NeedsLogin")) { try sidecar.status() }
        let asked = car.requests.withLock { $0 }
        #expect(asked.first == ["v": .int(1), "op": .string("status")])
        #expect(asked[1] == ["v": .int(1), "op": .string("whois"), "addr": .string("100.104.65.22")])
    }

    @Test func dialHandsOverAWorkingDescriptor() throws {
        let folder = try TestKit.scratch("car")
        defer { try? FileManager.default.removeItem(at: folder) }
        let car = try FakeSidecar(folder)
        defer { car.stop() }
        let (mine, theirs) = try Sockets.pair()
        // The sent end stays open until the test ends: on macOS, closing a descriptor just after
        // sending it while other Unix sockets in the process close sometimes delivered a dead one.
        defer { Sockets.closeFD(theirs); Sockets.closeFD(mine) }
        car.serveOnce { fd, _ in try SidecarWire.send(fd, Data(#"{"ok":true}"#.utf8), attach: mine) }
        let conn = try TailnetSidecar(path: car.path).dial("100.104.65.22", port: 47470)
        defer { Sockets.closeFD(conn) }
        try Sockets.writeAll(conn, Data("hello".utf8))
        #expect(try Sockets.read(theirs, max: 16) == Array("hello".utf8))
        #expect(car.requests.withLock { $0.first?["port"] } == .int(47470))
        #expect(throws: TailnetError.notTailnet("10.0.0.1")) { try TailnetSidecar(path: car.path).dial("10.0.0.1", port: 1) }
    }

    @Test func listenHandsOffEachConnectionWithItsAddress() throws {
        let folder = try TestKit.scratch("car")
        defer { try? FileManager.default.removeItem(at: folder) }
        let car = try FakeSidecar(folder)
        defer { car.stop() }
        let (mine, theirs) = try Sockets.pair()
        defer { Sockets.closeFD(theirs); Sockets.closeFD(mine) }
        let done = Flag()
        car.serveOnce { fd, _ in
            try SidecarWire.send(fd, Data(#"{"ok":true}"#.utf8))
            try SidecarWire.send(fd, Data(#"{"conn":{"remote":"[fd7a:115c:a1e0::9]:51000"}}"#.utf8), attach: mine)
            // Hold the socket until the test has taken the connection.
            while !done.isSet { _ = Sockets.wait(fd, write: false, timeoutMs: 5) }
        }
        let sockets = try TailnetSidecar(path: car.path).listen(port: 47470)
        defer { done.set(); Sockets.closeFD(sockets[0].fd) }
        guard case .handoff = sockets.first else {
            Issue.record("not a handoff socket")
            return
        }
        let (conn, remote) = try sockets[0].accept()
        defer { Sockets.closeFD(conn) }
        #expect(remote == "fd7a:115c:a1e0::9")
        try Sockets.writeAll(theirs, Data("hi".utf8))
        #expect(try Sockets.read(conn, max: 8) == Array("hi".utf8))
    }

    @Test func busOverTheSidecar() async throws {
        let folder = try TestKit.scratch("car")
        defer { try? FileManager.default.removeItem(at: folder) }
        let car = try FakeSidecar(folder)
        defer { car.stop() }
        car.serveOnce { fd, _ in
            try SidecarWire.send(fd, Data(#"{"notify":{"State":2}}"#.utf8))
            try SidecarWire.send(fd, Data(#"{"notify":{"Engine":{"RBytes":1}}}"#.utf8))
            try SidecarWire.send(fd, Data(#"{"notify":{"State":6}}"#.utf8))
        }
        var got: [TailnetEvent] = []
        for await event in TailnetSidecar(path: car.path).events() { got.append(event) }
        #expect(got == [.state(.needsLogin), .state(.running)])
        #expect(car.requests.withLock { $0.first?["mask"] } == .int(49154))
    }

    @Test func oversizedMessagesAreRefused() throws {
        let (a, b) = try Sockets.pair()
        defer { Sockets.closeFD(a); Sockets.closeFD(b) }
        try Sockets.writeAll(a, Data([0x7F, 0xFF, 0xFF, 0xFF]))
        #expect(throws: TailnetError.sidecar("message too big")) { try SidecarWire.receive(b) }
    }
}

import Foundation
@testable import KoreNet
import KoreTrust
import Synchronization
@testable import Tailnet
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A value handed to the one thread that alone uses it from then on.
struct Handed<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Deterministic SplitMix64.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The wire parsers fed over real sockets at random split points (the HTTP/1.1 compaction bug
/// that reached a Mac was one of these), and garbage that must throw, never trap.
@Suite("wire fuzz")
struct WireFuzzTests {
    /// The IPN bus shape: chunk boundaries anywhere (mid-line, mid-CRLF), chunk extensions, and the
    /// socket handing bytes over in random slices (1...N), so `fill()` compacts at random moments.
    @Test(arguments: [1 as UInt64, 2, 3, 4, 5, 6, 7, 8])
    func chunkedBodyAtRandomSplits(seed: UInt64) throws {
        var rng = Seeded(seed)
        let lines = (0..<120).map { n in "{\"n\":\(n),\"pad\":\"" + String(repeating: "x", count: Int.random(in: 0...1500, using: &rng)) + "\"}" }
        let body = Data(lines.map { $0 + "\n" }.joined().utf8)
        var wire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        var at = 0
        while at < body.count {
            let size = min(Int.random(in: 1...5000, using: &rng), body.count - at)
            let ext = Bool.random(using: &rng) ? ";x=1" : ""
            wire.append(Data((String(size, radix: 16) + ext + "\r\n").utf8))
            wire.append(body[at..<(at + size)])
            wire.append(Data("\r\n".utf8))
            at += size
        }
        wire.append(Data("0\r\n\r\n".utf8))
        let (client, server) = try Sockets.pair()
        let slices = Int.random(in: 1...400, using: &rng)
        let seedForWriter = rng.next()
        let bytes = wire
        let writer = Thread {
            var r = Seeded(seedForWriter)
            var done = 0
            while done < bytes.count {
                let n = min(Int.random(in: 1...slices, using: &r), bytes.count - done)
                try? Sockets.writeAll(server, bytes[done..<(done + n)])
                done += n
            }
            Sockets.closeFD(server)
        }
        writer.start()
        var reader = HTTP1.Reader(fd: client)
        #expect(try reader.head().status == 200)
        var got: [String] = []
        while let line = try reader.line() { got.append(String(decoding: line, as: UTF8.self)) }
        Sockets.closeFD(client)
        #expect(got == lines)
    }

    /// Garbage heads and bodies must throw, never trap.
    @Test func garbageHTTPNeverTraps() throws {
        var rng = Seeded(99)
        let samples: [String] = [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcdeXX",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n",
            "HTTP/1.1\r\n\r\n", "\r\n\r\n", "", "HTTP/1.1 200 OK\nContent-Length: 3\n\nabc",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nTrailer: x\r\n\r\n",
        ]
        for sample in samples + (0..<40).map({ _ in String(decoding: (0..<Int.random(in: 0...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }, as: UTF8.self) }) {
            let (client, server) = try Sockets.pair()
            try? Sockets.writeAll(server, Data(sample.utf8))
            Sockets.closeFD(server)
            var reader = HTTP1.Reader(fd: client)
            _ = try? { () throws -> Int in
                _ = try reader.head()
                var n = 0
                while let line = try reader.line() { n += line.count }
                return n
            }()
            Sockets.closeFD(client)
        }
    }

    /// Frames of several streams, fragmented, interleaved, fed in random slices.
    @Test(arguments: [11 as UInt64, 12, 13, 14, 15, 16])
    func frameDecoderAtRandomSplits(seed: UInt64) throws {
        var rng = Seeded(seed)
        var expected: [NetMessage] = []
        var wire = Data()
        var pending: [(stream: UInt32, queue: NetFrame.Queue, payload: Data, sent: Int)] = []
        for i in 0..<30 {
            let stream = UInt32(1 + i % 7)
            let queue: NetFrame.Queue = stream % 2 == 0 ? .stream : .interactive
            let payload = Data((0..<Int.random(in: 0...150_000, using: &rng)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })
            expected.append(NetMessage(queue: queue, stream: stream, payload: payload))
            pending.append((stream, queue, payload, 0))
        }
        // Each stream's messages stay in order; streams interleave a fragment at a time.
        var order: [UInt32: [Int]] = [:]
        for (i, p) in pending.enumerated() { order[p.stream, default: []].append(i) }
        while order.values.contains(where: { !$0.isEmpty }) {
            let streams = order.keys.filter { !(order[$0] ?? []).isEmpty }.sorted()
            let stream = streams[Int.random(in: 0..<streams.count, using: &rng)]
            let i = order[stream]!.first!
            var p = pending[i]
            let size = min(Int.random(in: 0...NetFrame.maxPayload, using: &rng), p.payload.count - p.sent)
            let chunk = p.payload[p.sent..<(p.sent + size)]
            p.sent += size
            let done = p.sent == p.payload.count
            wire.append(NetFrame(queue: p.queue, flags: done ? [] : .more, stream: stream, payload: Data(chunk)).encoded)
            pending[i] = p
            if done { order[stream]!.removeFirst() }
        }
        var decoder = NetFrameDecoder(preAuth: false)
        var got: [NetMessage] = []
        var at = 0
        while at < wire.count {
            let n = min(Int.random(in: 1...70_000, using: &rng), wire.count - at)
            got += try decoder.feed(wire[at..<(at + n)])
            at += n
        }
        // Messages land in the order their last fragment landed; compare per stream.
        for stream in Set(expected.map(\.stream)) {
            #expect(got.filter { $0.stream == stream } == expected.filter { $0.stream == stream }, "stream \(stream)")
        }
        #expect(decoder.pending == 0)
    }

    @Test func frameDecoderGarbageNeverTraps() throws {
        var rng = Seeded(7)
        for _ in 0..<200 {
            var decoder = NetFrameDecoder(preAuth: Bool.random(using: &rng))
            let bytes = Data((0..<Int.random(in: 0...300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            var at = 0
            while at < bytes.count {
                let n = min(Int.random(in: 1...20, using: &rng), bytes.count - at)
                guard (try? decoder.feed(bytes[at..<(at + n)])) != nil else { break }
                at += n
            }
        }
    }

    /// Two real sessions through a relay that re-slices every byte stream at random points, both
    /// ends pumped by poll on their own threads: the handshake and 200 messages each way.
    @Test(arguments: [21 as UInt64, 22, 23])
    func sessionsThroughARelayAtRandomSplits(seed: UInt64) throws {
        let pairing = try Pairing()
        let (cA, cB) = try Sockets.pair()
        let (sA, sB) = try Sockets.pair()
        // Relay cB <-> sB.
        let relaySeed = seed
        let relay = Thread {
            var rng = Seeded(relaySeed)
            Sockets.setNonBlocking(cB)
            Sockets.setNonBlocking(sB)
            var open = 2
            while open > 0 {
                var fds = [pollfd(fd: cB, events: Int16(POLLIN), revents: 0), pollfd(fd: sB, events: Int16(POLLIN), revents: 0)]
                guard poll(&fds, 2, 2000) > 0 else { break }
                for (i, p) in fds.enumerated() where p.revents != 0 {
                    let from = i == 0 ? cB : sB, to = i == 0 ? sB : cB
                    let n = Int.random(in: 1...3000, using: &rng)
                    guard let bytes = try? Sockets.read(from, max: n) else { continue }
                    if bytes.isEmpty {
                        Sockets.shutdownBoth(to)
                        open -= 1
                        fds[i].fd = -1
                        continue
                    }
                    try? Sockets.writeAll(to, Data(bytes))
                }
                if fds.allSatisfy({ $0.fd == -1 }) { break }
            }
            Sockets.closeFD(cB)
            Sockets.closeFD(sB)
        }
        relay.start()
        let server = pairing.server(fd: sA)
        let client = pairing.client(fd: cA)
        server.start()
        let want = 120
        @Sendable func drive(_ s: NetSession, sendAs: String) -> Int {
            var sent = 0, got = 0
            var rounds = 0
            while rounds < 50_000 {
                rounds += 1
                _ = Sockets.wait(s.descriptor, write: s.wantsWrite, timeoutMs: 5)
                let messages = s.pump()
                got += messages.count
                if case .established = s.state, sent < want {
                    for _ in 0..<5 where sent < want {
                        let big = sent % 10 == 0
                        try? s.send(Data(String(repeating: sendAs, count: big ? 40_000 : 10).utf8), queue: big ? .stream : .interactive, stream: big ? 9 : UInt32(1 + sent % 3))
                        sent += 1
                    }
                }
                if case .closed = s.state { break }
                if got >= want && sent >= want && !s.wantsWrite { break }
            }
            return got
        }
        let serverGot = Mutex<Int?>(nil)
        let serverDone = DispatchSemaphore(value: 0)
        let serverSide = Handed(server)
        let serverThread = Thread {
            let got = drive(serverSide.value, sendAs: "s")
            serverGot.withLock { $0 = got }
            serverDone.signal()
        }
        serverThread.start()
        let clientGot = drive(client, sendAs: "c")
        serverDone.wait()
        #expect(clientGot == want)
        #expect(serverGot.withLock { $0 } == want)
        client.close("done")
        server.close("done")
    }
}

/// The sweep's socket and sidecar fixes: each test fails on the code before its fix.
@Suite("korenet sweep, sockets")
struct NetSweepSocketTests {
    /// Runs `work` on a thread of its own; nil when it hadn't returned within `seconds` (a call
    /// that blocks for good fails the test instead of hanging the run).
    func bounded<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) -> T? {
        let result = Mutex<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let got = work()
            result.withLock { $0 = got }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return result.withLock { $0 }
    }

    /// A helper that takes a question and never answers: an error after `answerWait`, never a
    /// caller held for good.
    @Test func aWedgedSidecarTimesOut() throws {
        let folder = try TestKit.scratch("wg")
        defer { try? FileManager.default.removeItem(at: folder) }
        let car = try SidecarTests.FakeSidecar(folder)
        defer { car.stop() }
        let release = DispatchSemaphore(value: 0)
        car.serveOnce { _, _ in release.wait() }
        defer { release.signal() }
        let sidecar = TailnetSidecar(path: car.path, answerWait: 150)
        let outcome = bounded(3) { () -> String in
            do {
                _ = try sidecar.status()
                return "answered"
            } catch {
                return "\(error)"
            }
        }
        #expect(outcome == "\(SocketError.timedOut)", "\(outcome ?? "still waiting after 3 s")")
    }

    /// A handed-off connection whose message doesn't decode is closed, not leaked half open.
    @Test func aHandoffThatDoesntDecodeClosesItsDescriptor() throws {
        let (listen, helper) = try Sockets.pair()
        defer {
            Sockets.closeFD(listen)
            Sockets.closeFD(helper)
        }
        let (passed, peer) = try Sockets.pair()
        defer { Sockets.closeFD(peer) }
        try SidecarWire.send(helper, Data("not json".utf8), attach: passed)
        Sockets.closeFD(passed)
        #expect(throws: (any Error).self) { try TailnetListenSocket.handoff(listen).accept() }
        // The only copy left was the receiver's: closed, so the peer reads the end.
        Sockets.setReadTimeout(peer, milliseconds: 500)
        #expect((try? Sockets.read(peer, max: 1)) == [], "the passed descriptor is still open")
    }

    /// A reply that doesn't decode closes the descriptor it carried.
    @Test func aReplyThatDoesntDecodeClosesItsDescriptor() throws {
        let folder = try TestKit.scratch("br")
        defer { try? FileManager.default.removeItem(at: folder) }
        let car = try SidecarTests.FakeSidecar(folder)
        defer { car.stop() }
        let (passed, peer) = try Sockets.pair()
        defer { Sockets.closeFD(peer) }
        let sent = DispatchSemaphore(value: 0)
        car.serveOnce { fd, _ in
            try SidecarWire.send(fd, Data("{oops".utf8), attach: passed)
            Sockets.closeFD(passed)
            sent.signal()
        }
        #expect(throws: (any Error).self) { try TailnetSidecar(path: car.path).dial("100.104.65.22", port: 47470) }
        sent.wait()
        Sockets.setReadTimeout(peer, milliseconds: 500)
        #expect((try? Sockets.read(peer, max: 1)) == [], "the passed descriptor is still open")
    }

    /// A connect that gets no answer at all (a peer the tailnet calls online, its port
    /// filtered) gives up after its timeout, not the kernel's ~75 s. TEST-NET-1 is never routed
    /// anywhere: with a network its SYNs go unanswered; without one the connect fails at once.
    @Test func aConnectThatGetsNoAnswerTimesOut() throws {
        let outcome = bounded(3) { () -> String in
            do {
                Sockets.closeFD(try Sockets.connectTCP(IPAddress("192.0.2.1")!, port: 47470, timeoutMs: 300))
                return "connected"
            } catch {
                return "\(error)"
            }
        }
        let quick = ["\(SocketError.timedOut)", "\(SocketError.failed("connect 192.0.2.1:47470", EHOSTUNREACH))",
                     "\(SocketError.failed("connect 192.0.2.1:47470", ENETUNREACH))"]
        #expect(outcome.map(quick.contains) == true, "\(outcome ?? "still blocked after 3 s")")
        // A connected socket closes at exec from the start.
        let listener = try Sockets.listenTCP("127.0.0.1", port: 0)
        defer { Sockets.closeFD(listener) }
        let fd = try Sockets.connectTCP(IPAddress("127.0.0.1")!, port: try #require(Sockets.localPort(listener)))
        defer { Sockets.closeFD(fd) }
        #expect(Sockets.closesOnExec(fd))
    }

    /// Every descriptor these helpers make closes at exec: none leaks into a child process.
    @Test func socketsCloseOnExec() throws {
        let (a, b) = try Sockets.pair()
        defer {
            Sockets.closeFD(a)
            Sockets.closeFD(b)
        }
        #expect(Sockets.closesOnExec(a) && Sockets.closesOnExec(b))
        let copy = try #require(Sockets.duplicate(a))
        defer { Sockets.closeFD(copy) }
        #expect(Sockets.closesOnExec(copy))
    }
}

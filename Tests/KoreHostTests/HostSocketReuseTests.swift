import Foundation
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// A client's link closes while its sources are still being let go, and the next connection is
/// handed the same descriptor number: what that one is sent is its own, none of it taken by the
/// closed one's watch.
@MainActor
@Suite("host socket reuse", .serialized, .timeLimit(.minutes(1)))
struct HostSocketReuseTests {
    @Test func aClosedLinksWatchNeverTakesTheNextConnectionsBytes() async throws {
        for _ in 0..<50 {
            let (old, oldPeer) = try Sockets.pair()
            var stolen = 0
            let first = HostSocket(fd: old)
            first.start(max: 1 << 20, frame: { _ in stolen += 1 }, ended: {})
            first.close()
            Sockets.closeFD(oldPeer)
            // The next connection: most often given the number just freed.
            let (next, nextPeer) = try Sockets.pair()
            var got = 0
            let second = HostSocket(fd: next)
            second.start(max: 1 << 20, frame: { _ in got += 1 }, ended: {})
            let frame = LinkFrame.frame(Data("hello".utf8))
            for _ in 0..<3 { _ = frame.withUnsafeBytes { write(nextPeer, $0.baseAddress!, $0.count) } }
            let end = ContinuousClock.now + .seconds(30)
            while got < 3, ContinuousClock.now < end { await Task.yield() }
            #expect(got == 3 && stolen == 0, "got \(got), the closed one took \(stolen)")
            second.close()
            Sockets.closeFD(nextPeer)
        }
    }

    /// Something else closed the socket's descriptor and the number went to a pipe: the socket
    /// ends at its next read, and never reads the pipe (a blocking one would hold the main thread).
    @Test func aNumberTakenOverIsNeverReadAsTheSocket() async throws {
        let (mine, peer) = try Sockets.pair()
        var ended = false
        var frames = 0
        let socket = HostSocket(fd: mine)
        socket.start(max: 1 << 20, frame: { _ in frames += 1 }, ended: { ended = true })
        var pipe: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&pipe) == 0)
        // The stray close, and the number given out again: to the pipe, a byte waiting in it.
        #expect(dup2(pipe[0], mine) == mine)
        #expect(write(pipe[1], "p", 1) == 1)
        let frame = LinkFrame.frame(Data("hello".utf8))
        _ = frame.withUnsafeBytes { write(peer, $0.baseAddress!, $0.count) }
        let end = ContinuousClock.now + .seconds(30)
        while !ended, ContinuousClock.now < end { await Task.yield() }
        #expect(ended && frames == 0)
        var byte: UInt8 = 0
        #expect(read(pipe[0], &byte, 1) == 1 && byte == UInt8(ascii: "p"), "the pipe's byte is still there")
        for fd in [mine, pipe[0], pipe[1], peer] { Sockets.closeFD(fd) }
    }
}

import Foundation
@testable import Tailnet
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A socket this side ends while its peer is still writing: the peer gets what it was owed (its
/// `bye`), then the end, and a peer that never hangs up is let go at the bound.
@Suite("socket end", .timeLimit(.minutes(1)))
struct SocketEndTests {
    /// The peer's side: blocking, with a give-up time so a broken end fails rather than hangs.
    private static func peer(_ fd: Int32) {
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Off the test's thread: the peer blocks in its reads and writes.
    private static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: work()) } }
    }

    @Test func aPeerStillWritingGetsWhatItWasOwedThenTheEnd() async throws {
        let (mine, theirs) = try Sockets.pair()
        // Unread commands fill this side's buffer before it ends (a flood).
        Sockets.setNonBlocking(theirs)
        let chunk = [UInt8](repeating: 7, count: 4096)
        while write(theirs, chunk, chunk.count) > 0 {}
        _ = fcntl(theirs, F_SETFL, fcntl(theirs, F_GETFL) & ~O_NONBLOCK)
        Self.peer(theirs)
        // Its bound well past the test's own pace: the peer's thread may start late on a busy
        // Mac (the bound has a test of its own).
        SocketEnd.start(mine, owed: Data("bye".utf8), wait: .seconds(30))
        let got: (Data, Bool) = await Self.off {
            // Still writing, more than the buffers hold, before it reads anything.
            for _ in 0..<64 { guard write(theirs, chunk, chunk.count) == chunk.count else { return (Data(), false) } }
            var taken = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(theirs, &buffer, buffer.count)
                if n > 0 { taken.append(contentsOf: buffer[0..<n]); continue }
                return (taken, n == 0)
            }
        }
        #expect(got.0 == Data("bye".utf8))
        #expect(got.1, "the end came after the bye")
        Sockets.closeFD(theirs)
    }

    /// kore-host stopping: it waits for its links' byes to go before the tailnet under them does,
    /// as long as the peers take them, and never past the bound.
    @Test func settleWaitsForTheEndsThenReturnsAndIsBounded() async throws {
        // (Ends are counted process-wide and other suites run alongside: only lower bounds on
        // this end and the settle's own upper bound are this test's to check.)
        let (mine, theirs) = try Sockets.pair()
        Self.peer(theirs)
        SocketEnd.start(mine, owed: Data("bye restart".utf8), wait: .seconds(30))
        // The peer reads its bye and hangs up a little later.
        let read: Task<Data, Never> = Task.detached {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = Darwin.read(theirs, &buffer, buffer.count)
            usleep(150_000)
            Sockets.closeFD(theirs)
            return n > 0 ? Data(buffer[0..<n]) : Data()
        }
        let waited = ContinuousClock.now
        SocketEnd.settle(within: .seconds(5))
        let took = ContinuousClock.now - waited
        #expect(took >= .milliseconds(100), "settled before the peer took its bye: \(took)")
        #expect(took < .seconds(6), "\(took)")
        #expect(await read.value == Data("bye restart".utf8))
        // A peer that never hangs up: settle gives up at its own bound.
        let (a, b) = try Sockets.pair()
        SocketEnd.start(a, owed: Data(), wait: .seconds(30))
        let bounded = ContinuousClock.now
        SocketEnd.settle(within: .milliseconds(200))
        #expect(ContinuousClock.now - bounded < .seconds(2))
        Sockets.closeFD(b)
    }

    @Test func aPeerThatNeverHangsUpIsLetGoAtTheBound() async throws {
        let (mine, theirs) = try Sockets.pair()
        Self.peer(theirs)
        SocketEnd.start(mine, owed: Data("bye".utf8), wait: .milliseconds(50))
        let (bye, failed): (Data, Int32) = await Self.off {
            var buffer = [UInt8](repeating: 0, count: 16)
            let n = read(theirs, &buffer, buffer.count)
            let bye = n > 0 ? Data(buffer[0..<n]) : Data()
            // It keeps writing: taken and dropped until the end closes, then refused.
            let chunk = [UInt8](repeating: 7, count: 4096)
            while write(theirs, chunk, chunk.count) > 0 {}
            return (bye, errno)
        }
        #expect(bye == Data("bye".utf8))
        #expect(failed == EPIPE || failed == ECONNRESET, "refused once closed, not timed out (errno \(failed))")
        Sockets.closeFD(theirs)
    }
}

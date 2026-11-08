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
        SocketEnd.start(mine, owed: Data("bye".utf8))
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

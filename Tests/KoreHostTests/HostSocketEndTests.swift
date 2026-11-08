import Foundation
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// kore-host ends a client's link (`bye`, then close) while the client is still writing: the
/// client gets the bye, then the end.
@MainActor
@Suite("host socket end", .timeLimit(.minutes(1)))
struct HostSocketEndTests {
    @Test func aClientStillWritingGetsItsByeThenTheEnd() async throws {
        let (fd, client) = try Sockets.pair()
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let socket = HostSocket(fd: fd)
        socket.start(max: 1 << 20, frame: { _ in }, ended: {})
        let bye = try LinkMessage.bye(.rateLimited).encoded()
        socket.send(bye)
        socket.close()
        let got: (Data, Bool) = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                // A flood the host never reads, more than the buffers hold, before it reads.
                let frame = LinkFrame.frame(Data(repeating: 7, count: 4096))
                for _ in 0..<128 {
                    guard frame.withUnsafeBytes({ write(client, $0.baseAddress!, $0.count) }) == frame.count else {
                        return done.resume(returning: (Data(), false))
                    }
                }
                var taken = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(client, &buffer, buffer.count)
                    if n > 0 { taken.append(contentsOf: buffer[0..<n]); continue }
                    return done.resume(returning: (taken, n == 0))
                }
            }
        }
        #expect(got.0 == LinkFrame.frame(bye))
        #expect(got.1, "the end came after the bye")
        Sockets.closeFD(client)
    }
}

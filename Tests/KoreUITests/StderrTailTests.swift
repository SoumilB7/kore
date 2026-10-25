import Testing

@testable import KoreUI

/// A CLI's stderr reaches the session log as a reason and a byte count only, never its text.
@Suite("CLI stderr")
struct StderrTailTests {
    @Test func onlyAReasonAndACountAreTaken() {
        var tail = StderrTail()
        #expect(tail.take() == nil)
        tail.append("Error: 401 Unauthorized, please run /login (token sk-ant-secret)\n")
        let taken = tail.take()
        #expect(taken?.reason == "auth")
        #expect(taken?.bytes == 65)
        #expect(tail.take() == nil)
        tail.append("connect ECONNRESET 1.2.3.4:443")
        #expect(tail.take()?.reason == "network")
        tail.append("something odd")
        #expect(tail.take()?.reason == "unknown")
    }
}

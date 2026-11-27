import Foundation
import Testing

@testable import KoreCore

/// A process's end or the login shell's answer, awaited without holding a thread: it may come
/// before the wait or after it, and only once.
@Suite("Once signal")
struct OnceSignalTests {
    @Test func finishedBeforeTheWait() async {
        let signal = OnceSignal()
        signal.finish()
        signal.finish()
        await signal.wait()
    }

    @Test func finishedWhileWaitedOn() async {
        let signal = OnceSignal()
        async let waited: Void = signal.wait()
        Thread { signal.finish() }.start()
        await waited
    }

    @Test func aProcessExitAwaited() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exited = ProcessExit()
        process.terminationHandler = { _ in exited.finish() }
        try process.run()
        await exited.wait()
        #expect(process.terminationStatus == 0)
    }
}

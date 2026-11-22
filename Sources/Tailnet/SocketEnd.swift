import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A connected socket this side has finished with. What it still owes the peer (its `bye`) goes
/// out, this side shuts its writes, and what the peer still sends is read and dropped until the
/// peer hangs up, `wait` at most; then the descriptor closes. Closing at once instead loses
/// that last message: a peer still writing never reads it, and a close with the peer's bytes
/// unread resets the connection under what it hasn't read yet. Woken by the socket and one
/// timer on its own queue: nothing blocks, nothing sleeps.
package final class SocketEnd: @unchecked Sendable {
    package static let wait: DispatchTimeInterval = .seconds(1)
    private static let queue = DispatchQueue(label: "kore.socket-end")
    /// Ends under way, held until they're done (on `queue`).
    nonisolated(unsafe) private static var ending: [ObjectIdentifier: SocketEnd] = [:]

    private let fd: Int32
    private var owed: Data
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var bound: DispatchSourceTimer?
    private var done = false

    private init(_ fd: Int32, _ owed: Data) {
        self.fd = fd
        self.owed = owed
    }

    /// Takes `fd` (its close is this end's from now on) with `owed`, the bytes still to go.
    package static func start(_ fd: Int32, owed: Data = Data(), wait: DispatchTimeInterval = SocketEnd.wait) {
        guard fd >= 0 else { return }
        let end = SocketEnd(fd, owed)
        gate.lock()
        underWay += 1
        gate.unlock()
        queue.async { end.begin(wait) }
    }

    /// Ends a copy of `fd` (the owner still closes its own, as it always did).
    package static func start(copying fd: Int32, owed: Data = Data()) {
        guard let copy = Sockets.duplicate(fd) else { return }
        start(copy, owed: owed)
    }

    /// Ends started and not yet done, and `settle`'s wake-up: apart from `queue`, so a caller
    /// waiting here never holds up the queue the ends finish on.
    private static let gate = NSCondition()
    nonisolated(unsafe) private static var underWay = 0

    /// Ends still waiting on their peers.
    package static var open: Int {
        gate.lock()
        defer { gate.unlock() }
        return underWay
    }

    /// Waits, `within` at most, for the ends under way to finish: before what carries them goes
    /// (kore-host stopping Kore's own tailnet, then exiting), so their last message, the `bye
    /// restart` a Mac or phone dials straight back on, isn't lost with it. Blocks its caller;
    /// returns at once when nothing is ending.
    /// Ends under way when it was called, and how long it waited.
    @discardableResult
    package static func settle(within: Duration = .seconds(1)) -> (ending: Int, waited: Duration) {
        let clock = ContinuousClock()
        let began = clock.now
        let deadline = Date(timeIntervalSinceNow: within / .seconds(1))
        gate.lock()
        let ending = underWay
        while underWay > 0, gate.wait(until: deadline) {}
        gate.unlock()
        return (ending, clock.now - began)
    }

    private func begin(_ wait: DispatchTimeInterval) {
        Self.ending[ObjectIdentifier(self)] = self
        Sockets.setNonBlocking(fd)
        guard let watched = Sockets.duplicate(fd) else { return finish() }
        let reader = DispatchSource.makeReadSource(fileDescriptor: watched, queue: Self.queue)
        reader.setCancelHandler { Sockets.closeFD(watched) }
        reader.setEventHandler { [self] in drain() }
        self.reader = reader
        let bound = DispatchSource.makeTimerSource(queue: Self.queue)
        bound.schedule(deadline: .now() + wait)
        bound.setEventHandler { [self] in finish() }
        self.bound = bound
        reader.resume()
        bound.resume()
        flush()
        drain()
    }

    /// What the peer sends, dropped; its hang-up ends this.
    private func drain() {
        while !done {
            do {
                if try Sockets.read(fd, max: 64 << 10).isEmpty { return finish() }
            } catch SocketError.timedOut {
                return
            } catch {
                return finish()
            }
        }
    }

    private func flush() {
        while !done, !owed.isEmpty {
            let n: Int
            do {
                n = try owed.withUnsafeBytes { try Sockets.writeSome(fd, $0) }
            } catch {
                return finish()
            }
            if n == 0 { return waitWritable() }
            owed.removeFirst(n)
        }
        guard !done else { return }
        writer?.cancel()
        writer = nil
        _ = shutdown(fd, Int32(SHUT_WR))
    }

    private func waitWritable() {
        guard writer == nil, let watched = Sockets.duplicate(fd) else { return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: watched, queue: Self.queue)
        writer.setCancelHandler { Sockets.closeFD(watched) }
        writer.setEventHandler { [self] in
            self.writer?.cancel()
            self.writer = nil
            flush()
        }
        self.writer = writer
        writer.resume()
    }

    private func finish() {
        guard !done else { return }
        done = true
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        bound?.cancel()
        bound = nil
        owed = Data()
        // The sources watch their own copies, closed as they cancel: this one goes now.
        Sockets.closeFD(fd)
        Self.ending[ObjectIdentifier(self)] = nil
        Self.gate.lock()
        Self.underWay -= 1
        Self.gate.broadcast()
        Self.gate.unlock()
    }
}

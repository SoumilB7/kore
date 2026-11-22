import Foundation
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A pipe's own session (phase 18 §1 "Bulk"): a KoreNet session for the service "pipe", its
/// identity proven as any session's, then the ticket the link's `pipe.open` gave, on stream 1:
///
///     client → {"t":"ticket","ticket":<base64>}
///     server → {"t":"ready"}            (or `bye` with why it won't)
///     client → {"t":"go"}               (once the bytes have their process: `kore pipe`)
///
/// then rsync's bytes both ways on stream 2, the stream queue, under the peer's credit: each
/// message a kind byte, then its bytes (`data`), or `eof` (that side's input ended), or `exit`
/// with the far end's status (after its `eof`). The link's own session is another connection,
/// so nothing a pipe carries waits ahead of a command.
package enum PipeWire {
    package static let control: UInt32 = 1
    package static let data: UInt32 = 2
    /// The most a data message holds (one frame with its kind byte).
    package static let chunk = NetFrame.maxPayload - 1

    package enum Reason {
        /// No live ticket for this device by that value (spent, expired, or never given).
        package static let ticket = "ticket"
        /// The far end couldn't start its rsync.
        package static let spawn = "spawn"
        /// Revoked or stopped on the far end mid-copy.
        package static let stopped = "stopped"
        package static let done = "done"
    }

    package enum Piece: Equatable, Sendable {
        case data(Data)
        case eof
        case exit(Int32)
    }

    package static func encode(_ piece: Piece) -> Data {
        switch piece {
        case .data(let bytes):
            var out = Data([0])
            out.append(bytes)
            return out
        case .eof: return Data([1])
        case .exit(let status):
            var out = Data([2])
            out.appendBig(UInt32(bitPattern: status))
            return out
        }
    }

    package static func decode(_ payload: Data) -> Piece? {
        guard let kind = payload.first else { return nil }
        switch kind {
        case 0: return .data(payload.dropFirst())
        case 1: return payload.count == 1 ? .eof : nil
        case 2: return payload.count == 5 ? .exit(Int32(bitPattern: payload.readBig(at: payload.startIndex + 1))) : nil
        default: return nil
        }
    }

    /// Stream 1's few words: `ticket` (and, box to box, the sender's remote command, checked by
    /// the receiver then), `ready`, `go`.
    package struct Control: Codable, Equatable, Sendable {
        package var t: String
        package var ticket: String?
        package var argv: [String]?

        package init(_ t: String, ticket: Data? = nil, argv: [String]? = nil) {
            self.t = t
            self.ticket = ticket?.base64EncodedString()
            self.argv = argv
        }

        package var ticketBytes: Data? { ticket.flatMap { Data(base64Encoded: $0) } }

        package var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

        package static func decode(_ payload: Data) -> Control? { try? JSONDecoder().decode(Control.self, from: payload) }
    }
}

/// Moves a pipe's bytes between an established pipe session and two local descriptors until the
/// copy ends, on the calling thread (it blocks; one thread per pipe). `input` is read and sent;
/// what comes is written to `output`. A full `output` stops reads off the socket, so the peer's
/// credit runs out rather than this side's memory; a full session stops reads of `input`.
///
/// The client (`kore pipe`, rsync's remote shell) ends with the far end's exit status once all of
/// its output is written. The server (kore-host's rsync) sends its process's status once that
/// process's output has ended and it has exited (`exited`), then ends.
package final class PipeSplice: @unchecked Sendable {
    package enum Outcome: Equatable {
        /// The far end's rsync exited with this (client), or this side's did (server).
        case exited(Int32)
        /// The session ended first: the peer's `bye`, or the connection went.
        case broken(String)
        /// `stop` was called (a revoke, a quit).
        case stopped(String)
    }

    /// The session's unsent bytes past which `input` isn't read.
    package static let sendHigh = 1 << 20
    /// `output`'s unwritten bytes past which the socket isn't read.
    package static let receiveHigh = 1 << 20

    private let session: NetSession
    private var input: Int32?
    private var output: Int32?
    private let server: Bool
    private let exited: (() -> Int32?)?
    private var wake: (read: Int32, write: Int32)
    private let stopReason = StopFlag()

    private var first: [NetMessage]
    private var pending = Data()
    private var peerEOF = false
    private var inputEOF = false
    private var farStatus: Int32?
    private var sentStatus: Int32?

    /// `exited` (server): the local process's status once it has ended, else nil; asked after
    /// `input` ends, and on each `poke`.
    /// `first`: messages that came before the splice began (with the server's `go`).
    package init(session: NetSession, input: Int32?, output: Int32?, server: Bool, first: [NetMessage] = [], exited: (() -> Int32?)? = nil) {
        self.session = session
        self.first = first
        self.input = input
        self.output = output
        self.server = server
        self.exited = exited
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) != 0 { fds = [-1, -1] }
        wake = (fds[0], fds[1])
        for fd in [fds[0], fds[1]] where fd >= 0 { Sockets.setNonBlocking(fd); Sockets.closeOnExec(fd) }
        if let input { Sockets.setNonBlocking(input) }
        if let output { Sockets.setNonBlocking(output) }
    }

    deinit {
        for fd in [wake.read, wake.write] where fd >= 0 { _ = close(fd) }
    }

    /// Ends the copy from any thread: the session says `bye reason`.
    package func stop(_ reason: String) {
        stopReason.set(reason)
        poke()
    }

    /// Wakes the loop (any thread): a process ended, or `stop`.
    package func poke() {
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
    }

    package func run() -> Outcome {
        defer {
            if let input { _ = close(input) }
            if let output { _ = close(output) }
            input = nil
            output = nil
        }
        let early = first
        first = []
        for message in early where message.stream == PipeWire.data {
            guard let piece = PipeWire.decode(message.payload) else {
                session.close(NetControl.Reason.protocolError)
                return .broken(NetControl.Reason.protocolError)
            }
            take(piece)
        }
        while true {
            if let reason = stopReason.value {
                session.close(reason)
                return .stopped(reason)
            }
            if let outcome = settle() { return outcome }
            var fds: [pollfd] = []
            let sock = session.descriptor
            let readSocket = pending.count < Self.receiveHigh
            var sockEvents: Int16 = 0
            if readSocket { sockEvents |= Int16(POLLIN) }
            if session.wantsWrite { sockEvents |= Int16(POLLOUT) }
            // Left out while nothing is wanted of it: a hung-up socket would wake poll at once.
            fds.append(pollfd(fd: sockEvents == 0 ? -1 : sock, events: sockEvents, revents: 0))
            fds.append(pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0))
            let inputIndex: Int? = {
                guard let input, !inputEOF, session.backlog < Self.sendHigh else { return nil }
                fds.append(pollfd(fd: input, events: Int16(POLLIN), revents: 0))
                return fds.count - 1
            }()
            let outputIndex: Int? = {
                guard let output, !pending.isEmpty else { return nil }
                fds.append(pollfd(fd: output, events: Int16(POLLOUT), revents: 0))
                return fds.count - 1
            }()
            // The server looks for its process's end now and then too (a process that closed
            // its output and lingers); nothing else waits on a clock.
            let n = poll(&fds, nfds_t(fds.count), server && inputEOF ? 200 : -1)
            if n < 0 {
                if errno == EINTR { continue }
                session.close(NetControl.Reason.limit)
                return .broken("poll failed")
            }
            if fds[1].revents != 0 { drainWake() }
            if fds[0].revents != 0 || session.wantsWrite {
                for message in session.pump(reading: readSocket) where message.stream == PipeWire.data {
                    guard let piece = PipeWire.decode(message.payload) else {
                        session.close(NetControl.Reason.protocolError)
                        return .broken(NetControl.Reason.protocolError)
                    }
                    take(piece)
                }
            }
            if let inputIndex, fds[inputIndex].revents != 0 { readInput() }
            if let outputIndex, fds[outputIndex].revents != 0 { writeOutput() }
        }
    }

    /// What the loop has come to, if it's over.
    private func settle() -> Outcome? {
        if case .closed(let why) = session.state {
            // The far end said its status and closed: what's written is all there was.
            if !server, let farStatus, pending.isEmpty { return .exited(farStatus) }
            if !server, let farStatus {
                writeOutput(blocking: true)
                return .exited(farStatus)
            }
            return .broken(why.hasPrefix("bye ") ? String(why.dropFirst(4)) : why)
        }
        if !server {
            if peerEOF, pending.isEmpty, let output {
                _ = close(output)
                self.output = nil
            }
            if let farStatus, pending.isEmpty, !session.wantsWrite {
                session.close(PipeWire.Reason.done)
                return .exited(farStatus)
            }
            return nil
        }
        if peerEOF, pending.isEmpty, let output {
            _ = close(output)
            self.output = nil
        }
        if inputEOF, sentStatus == nil, let status = exited?() {
            sentStatus = status
            send(.exit(status))
        }
        if let sentStatus, !session.wantsWrite {
            session.close(PipeWire.Reason.done)
            return .exited(sentStatus)
        }
        return nil
    }

    private func take(_ piece: PipeWire.Piece) {
        switch piece {
        case .data(let bytes): pending.append(bytes)
        case .eof: peerEOF = true
        case .exit(let status): if !server { farStatus = status }
        }
        if !pending.isEmpty { writeOutput() }
    }

    private func send(_ piece: PipeWire.Piece) {
        do {
            try session.send(PipeWire.encode(piece), queue: .stream, stream: PipeWire.data)
        } catch {
            session.close(NetControl.Reason.limit)
        }
    }

    private func readInput() {
        guard let input else { return }
        var buffer = [UInt8](repeating: 0, count: PipeWire.chunk)
        let n = read(input, &buffer, buffer.count)
        if n > 0 {
            send(.data(Data(buffer[0..<n])))
        } else if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            inputEOF = true
            _ = close(input)
            self.input = nil
            send(.eof)
        }
    }

    private func writeOutput(blocking: Bool = false) {
        while let output, !pending.isEmpty {
            let n = pending.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
                continue
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard blocking else { return }
                var fd = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                _ = poll(&fd, 1, 1000)
                continue
            }
            // Whoever reads it has gone: what's left goes nowhere.
            pending = Data()
            _ = close(output)
            self.output = nil
        }
    }

    private func drainWake() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(wake.read, &buffer, buffer.count) > 0 {}
    }
}

/// A reason set once, read from the loop.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?

    var value: String? { lock.withLock { reason } }

    func set(_ why: String) { lock.withLock { if reason == nil { reason = why } } }
}

/// The words before a pipe's bytes, driven to their end on the calling thread (blocking, within a
/// time limit): the client's handshake, ticket and `ready`; the server's ticket, then `go`.
package enum PipeHandshake {
    package enum Failure: Error, Equatable, CustomStringConvertible {
        /// The session ended: the peer's `bye` reason, or how it went.
        case closed(String)
        case timedOut
        case protocolError

        package var description: String {
            switch self {
            case .closed(let why): why
            case .timedOut: "no answer in time"
            case .protocolError: "it answered out of turn"
            }
        }
    }

    /// Client: `session` (a fresh client session for "pipe", its challenge to come) through its
    /// welcome, then the ticket, until the server's `ready`.
    package static func open(_ session: NetSession, ticket: Data, argv: [String]? = nil, within seconds: TimeInterval) throws(Failure) {
        let end = Date().addingTimeInterval(seconds)
        var sent = false
        while true {
            let messages = try step(session, until: end)
            if !sent, case .established = session.state {
                sent = true
                do {
                    try session.send(PipeWire.Control("ticket", ticket: ticket, argv: argv).encoded, queue: .interactive, stream: PipeWire.control)
                } catch {
                    throw .closed("the connection broke")
                }
            }
            for message in messages {
                guard message.stream == PipeWire.control, PipeWire.Control.decode(message.payload)?.t == "ready" else { throw .protocolError }
                return
            }
        }
    }

    /// Server: the client's ticket (and its remote command, box to box), once its session is
    /// established; nothing else may come first.
    package static func ticket(_ session: NetSession, within seconds: TimeInterval) throws(Failure) -> PipeWire.Control {
        let end = Date().addingTimeInterval(seconds)
        while true {
            for message in try step(session, until: end) {
                guard message.stream == PipeWire.control, let control = PipeWire.Control.decode(message.payload), control.t == "ticket",
                      control.ticketBytes != nil
                else { throw .protocolError }
                return control
            }
        }
    }

    /// Server: says `ready`, then waits for the client's `go`; data that came with it is
    /// returned, for the splice to start with.
    package static func ready(_ session: NetSession, within seconds: TimeInterval) throws(Failure) -> [NetMessage] {
        do {
            try session.send(PipeWire.Control("ready").encoded, queue: .interactive, stream: PipeWire.control)
        } catch {
            throw .closed("the connection broke")
        }
        let end = Date().addingTimeInterval(seconds)
        while true {
            let messages = try step(session, until: end)
            guard let go = messages.firstIndex(where: { $0.stream == PipeWire.control }) else {
                if messages.isEmpty { continue }
                throw .protocolError
            }
            guard PipeWire.Control.decode(messages[go].payload)?.t == "go", go == 0 else { throw .protocolError }
            return Array(messages.dropFirst())
        }
    }

    /// Client, after a hand-over (`kore pipe`): `go`.
    package static func go(_ session: NetSession) throws(Failure) {
        do {
            try session.send(PipeWire.Control("go").encoded, queue: .interactive, stream: PipeWire.control)
        } catch {
            throw .closed("the connection broke")
        }
        _ = session.pump(reading: false)
    }

    /// One wait for the socket and one pump.
    private static func step(_ session: NetSession, until end: Date) throws(Failure) -> [NetMessage] {
        if case .closed(let why) = session.state { throw .closed(why.hasPrefix("bye ") ? String(why.dropFirst(4)) : why) }
        let left = end.timeIntervalSinceNow
        guard left > 0 else {
            session.close(NetControl.Reason.timeout)
            throw .timedOut
        }
        var fd = pollfd(fd: session.descriptor, events: Int16(POLLIN) | (session.wantsWrite ? Int16(POLLOUT) : 0), revents: 0)
        _ = poll(&fd, 1, Int32(min(left, 1) * 1000))
        let messages = session.pump()
        if case .closed(let why) = session.state, messages.isEmpty { throw .closed(why.hasPrefix("bye ") ? String(why.dropFirst(4)) : why) }
        return messages
    }
}

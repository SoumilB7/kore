import Foundation
import KoreNet
import KoreTrust
import Tailnet

/// The link over a KoreNet session (phase 18 step 5a): link 1.x bodies as messages on stream 1,
/// interactive queue, after the identity proofs over B. Everything runs on its own queue, woken
/// by the socket only (a write source exists only while frames wait); nothing touches the main
/// actor. `open` finds and dials the box and builds the session's setup there too (a LocalAPI
/// read, a WhoIs, the Keychain), so a dial never blocks navigation.
package final class NetTransport: HostTransport, @unchecked Sendable {
    package static let stream: UInt32 = 1

    /// What `open` hands back: a connected socket, the session's setup, and anything to end
    /// with it (an `ssh` process carrying `attach --proto 2`).
    package struct Opened {
        package var fd: Int32
        package var setup: NetSession.Client
        package var onClose: (@Sendable () -> Void)?

        package init(fd: Int32, setup: NetSession.Client, onClose: (@Sendable () -> Void)? = nil) {
            self.fd = fd
            self.setup = setup
            self.onClose = onClose
        }
    }

    package let route: Binding.Route
    package let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue = DispatchQueue(label: "kore.net.transport")
    private let open: @Sendable () throws -> Opened
    private let clock: @Sendable () -> Date
    /// The session's peer and any node key it kept for it, once the welcome's proof held.
    private let established: (@Sendable (NetPeer, DeviceBook.NodeKeyAppend?) -> Void)?

    // Touched on `queue` only.
    private var session: NetSession?
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var waiting: [Data] = []
    private var up = false
    private var ended = false
    private var onClose: (@Sendable () -> Void)?

    package init(
        route: Binding.Route, clock: @escaping @Sendable () -> Date = { Date() }, open: @escaping @Sendable () throws -> Opened,
        established: (@Sendable (NetPeer, DeviceBook.NodeKeyAppend?) -> Void)? = nil
    ) {
        self.route = route
        self.open = open
        self.clock = clock
        self.established = established
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    package func start() throws {
        queue.async { [self] in
            guard !ended else { return }
            let opened: Opened
            do {
                opened = try open()
            } catch {
                return end("couldn't reach it on KoreNet: \(error)")
            }
            onClose = opened.onClose
            let session = NetSession(fd: opened.fd, role: .client(opened.setup), clock: clock)
            self.session = session
            guard let watched = Self.watched(session.descriptor) else { return end("the connection broke") }
            let source = DispatchSource.makeReadSource(fileDescriptor: watched, queue: queue)
            source.setCancelHandler { Sockets.closeFD(watched) }
            source.setEventHandler { [weak self] in self?.pump() }
            reader = source
            source.resume()
            pump()
        }
    }

    package func send(_ payload: Data) {
        queue.async { [self] in
            guard !ended else { return }
            guard up, let session else { return waiting.append(payload) }
            do {
                try session.send(payload, queue: .interactive, stream: Self.stream)
            } catch {
                return end("the connection broke")
            }
            arm()
        }
    }

    package func close() {
        queue.async { [self] in
            session?.close("quit")
            end(nil)
        }
    }

    package func drain(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            let deadline = Date().addingTimeInterval(timeout)
            while let session, session.wantsWrite, !ended, Date() < deadline {
                _ = Sockets.wait(session.descriptor, write: true, timeoutMs: 50)
                _ = session.pump()
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout + 0.1)
    }

    // MARK: On the queue

    private func pump() {
        guard !ended, let session else { return }
        let messages = session.pump()
        if !up, case .established(let peer) = session.state {
            up = true
            established?(peer, session.nodeKeyAppend)
            let held = waiting
            waiting = []
            for payload in held { try? session.send(payload, queue: .interactive, stream: Self.stream) }
        }
        for message in messages where message.stream == Self.stream { continuation.yield(.frame(message.payload)) }
        if case .closed(let why) = session.state { return end(why == "closed" ? nil : why) }
        arm()
    }

    /// A write source while frames wait, none otherwise.
    private func arm() {
        guard !ended, let session else { return }
        if case .closed(let why) = session.state { return end(why) }
        if session.wantsWrite {
            guard writer == nil, let watched = Self.watched(session.descriptor) else { return }
            let source = DispatchSource.makeWriteSource(fileDescriptor: watched, queue: queue)
            source.setCancelHandler { Sockets.closeFD(watched) }
            source.setEventHandler { [weak self] in self?.pump() }
            writer = source
            source.resume()
        } else {
            writer?.cancel()
            writer = nil
        }
    }

    private func end(_ reason: String?) {
        guard !ended else { return }
        ended = true
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        if let session {
            if case .closed = session.state {} else { session.close("quit") }
        }
        onClose?()
        onClose = nil
        continuation.yield(.closed(reason))
        continuation.finish()
    }

    /// A duplicate of the session's descriptor for one source; the source closes it.
    private static func watched(_ fd: Int32) -> Int32? {
        let copy = dup(fd)
        return copy >= 0 ? copy : nil
    }
}

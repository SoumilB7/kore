import Darwin
import Foundation
import Tailnet

/// One caller's connection: lines in and out on the channel's queue. What Kore sends is queued,
/// and a caller more than `backlogMax` behind is dropped, so Kore never waits on it. One batch of
/// lines is with the main thread at a time: the reader stays suspended until it's done, so a
/// caller sending too fast fills its own socket and nothing of Kore's.
final class AgentConnection: @unchecked Sendable {
    static let backlogMax = 4 * 1024 * 1024
    /// The most a batch holds, in lines and in bytes (a longer line goes alone).
    static let batchLines = 32
    static let batchBytes = AgentProto.lineMax

    private let fd: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var inbox = Data()
    private var outbox = Data()
    private var closed = false
    /// A batch is with the main thread: the reader is suspended.
    private var waiting = false
    /// `onMoved` has run.
    private var toldMoved = false
    /// The peer's token as now, to compare: nil once it has gone.
    private let peerToken: @Sendable (Int32) -> Data?
    private let token: Data
    private let onLines: @Sendable ([Data]) -> Void
    private let onMoved: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private let onGone: @Sendable () -> Void

    /// `token`: whose this connection is. `onLines` ends with `batchDone()`. `onMoved`: another
    /// process is using it, once. `onClose`: it ended by itself. `onGone`: it ended, either way, once.
    init(
        fd: Int32, queue: DispatchQueue, token: Data, peerToken: @escaping @Sendable (Int32) -> Data?,
        onLines: @escaping @Sendable ([Data]) -> Void, onMoved: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable () -> Void, onGone: @escaping @Sendable () -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.token = token
        self.peerToken = peerToken
        self.onLines = onLines
        self.onMoved = onMoved
        self.onClose = onClose
        self.onGone = onGone
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    func start() {
        queue.async { [self] in
            guard !closed else { return }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.read() }
            let fd = self.fd
            reader.setCancelHandler { Darwin.close(fd) }
            self.reader = reader
            reader.resume()
        }
    }

    private func read() {
        guard !waiting, !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n > 0 {
            inbox.append(contentsOf: chunk[0..<n])
            return deliver()
        }
        if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { shut() }
    }

    /// The next batch to the main thread, if there's a whole line and none is there already.
    private func deliver() {
        guard !waiting, !closed else { return }
        var lines: [Data] = []
        var bytes = 0
        var start = inbox.startIndex
        while lines.count < Self.batchLines, bytes < Self.batchBytes, let end = inbox[start...].firstIndex(of: 0x0A) {
            guard end - start <= AgentProto.lineMax else { return shut() }
            if end > start {
                lines.append(Data(inbox[start..<end]))
                bytes += end - start
            }
            start = end + 1
        }
        inbox.removeSubrange(inbox.startIndex..<start)
        // Out of whole lines: what's left is one line so far.
        if lines.count < Self.batchLines, bytes < Self.batchBytes, inbox.count > AgentProto.lineMax { return shut() }
        guard !lines.isEmpty else { return }
        waiting = true
        reader?.suspend()
        // The kernel names the last process to use the socket: it has to be still the one that
        // connected, and alive.
        switch peerToken(fd) {
        case token: onLines(lines)
        case nil: shut()
        default:
            toldMoved = true
            onMoved()
        }
    }

    /// The batch is done with (any thread): reading goes on.
    func batchDone() {
        queue.async { [self] in
            guard waiting, !closed else { return }
            waiting = false
            reader?.resume()
            deliver()
        }
    }

    /// Queues one line, made on this connection's queue (from any thread), in the order asked. A
    /// caller that only reads, a follower, is checked here: reading names it to the kernel too.
    func send(_ line: @escaping @Sendable () -> Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            switch self.peerToken(self.fd) {
            case self.token: break
            case nil: return self.shut()
            default:
                if !self.toldMoved {
                    self.toldMoved = true
                    self.onMoved()
                }
                return
            }
            self.outbox.append(line())
            self.outbox.append(0x0A)
            guard self.outbox.count <= Self.backlogMax else { return self.shut() }
            self.flush()
        }
    }

    private func flush() {
        while !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeFirst(n)
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return waitWritable() }
            return shut()
        }
    }

    private func waitWritable() {
        guard writer == nil else { return }
        // Its own copy of the descriptor, closed as it's cancelled: the reader's cancel closes
        // `fd`, and nothing says this one's cancel has finished by then.
        guard let watched = Sockets.duplicate(fd) else { return shut() }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: watched, queue: queue)
        writer.setCancelHandler { Sockets.closeFD(watched) }
        writer.setEventHandler { [weak self] in
            guard let self else { return }
            self.writer?.cancel()
            self.writer = nil
            self.flush()
        }
        self.writer = writer
        writer.resume()
    }

    /// Sends `last` after what's queued, then closes, without telling `onClose` (any thread).
    /// The socket's end is `SocketEnd`'s: a caller still writing gets `last`, and reads to its end.
    func finish(after last: Data? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            var owed = outbox
            if let last {
                owed.append(last)
                owed.append(0x0A)
            }
            SocketEnd.start(copying: fd, owed: owed)
            close(notify: false)
        }
    }

    private func shut() { close(notify: true) }

    private func close(notify: Bool) {
        guard !closed else { return }
        closed = true
        writer?.cancel()
        writer = nil
        // A suspended source never runs its cancel handler, which closes the descriptor.
        if waiting { reader?.resume() }
        waiting = false
        if let reader { reader.cancel() } else { Darwin.close(fd) }
        reader = nil
        outbox = Data()
        inbox = Data()
        onGone()
        if notify { onClose() }
    }
}

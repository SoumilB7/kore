import Darwin
import Foundation

/// One caller's connection: lines in and out on the channel's queue. What Kore sends is queued,
/// and a caller more than `backlogMax` behind is dropped, so Kore never waits on it.
final class AgentConnection: @unchecked Sendable {
    static let backlogMax = 4 * 1024 * 1024

    private let fd: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var inbox = Data()
    private var outbox = Data()
    private var closed = false
    private let onLines: @Sendable ([Data]) -> Void
    private let onClose: @Sendable () -> Void

    init(fd: Int32, queue: DispatchQueue, onLines: @escaping @Sendable ([Data]) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onLines = onLines
        self.onClose = onClose
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
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                inbox.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { return shut() }
            break
        }
        var lines: [Data] = []
        while let end = inbox.firstIndex(of: 0x0A) {
            let line = inbox[inbox.startIndex..<end]
            if !line.isEmpty { lines.append(Data(line)) }
            inbox.removeSubrange(inbox.startIndex...end)
        }
        guard inbox.count <= AgentProto.lineMax, lines.allSatisfy({ $0.count <= AgentProto.lineMax }) else { return shut() }
        if !lines.isEmpty { onLines(lines) }
    }

    /// Queues one line (any thread).
    func send(_ line: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.outbox.append(line)
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
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writer.setEventHandler { [weak self] in
            guard let self else { return }
            self.writer?.cancel()
            self.writer = nil
            self.flush()
        }
        self.writer = writer
        writer.resume()
    }

    /// Sends `last` after what's queued (best effort, a quarter second at most, on this queue),
    /// then closes, without telling `onClose` (any thread).
    func finish(after last: Data? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            if let last {
                outbox.append(last)
                outbox.append(0x0A)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                var limit = timeval(tv_sec: 0, tv_usec: 250_000)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                while !outbox.isEmpty {
                    let n = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    guard n > 0 else { break }
                    outbox.removeFirst(n)
                }
            }
            close(notify: false)
        }
    }

    private func shut() { close(notify: true) }

    private func close(notify: Bool) {
        guard !closed else { return }
        closed = true
        writer?.cancel()
        writer = nil
        if let reader { reader.cancel() } else { Darwin.close(fd) }
        reader = nil
        outbox = Data()
        if notify { onClose() }
    }
}

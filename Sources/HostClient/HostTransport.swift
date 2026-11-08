import Foundation
import LinkProtocol

/// What a transport hands on: each whole frame's payload, then its end, once.
package enum TransportEvent: Sendable {
    case frame(Data)
    /// The other end went, or the transport was closed; a reason when there is one.
    case closed(String?)
}

/// A byte stream to a host, framed as the link frames it (a 4-byte big-endian length, then the
/// JSON). SSH's stdio is one; a direct socket can be another.
package protocol HostTransport: AnyObject, Sendable {
    var events: AsyncStream<TransportEvent> { get }
    /// Begins reading. Throws when the stream can't be opened at all.
    func start() throws
    /// Sends one message's payload; framing is the transport's.
    func send(_ payload: Data)
    /// Ends it. `events` ends with `.closed`.
    func close()
}

/// Frames over a pair of file handles: a pipe pair, a socketpair, or a process's stdio.
package final class PipeTransport: HostTransport, @unchecked Sendable {
    package let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let input: FileHandle
    private let output: FileHandle
    private let writes = DispatchQueue(label: "kore.host.transport.write")
    private let lock = NSLock()
    private var buffer = Data()
    private var ended = false
    /// Said as the reason when the read side ends by itself (a process's last words).
    package var reason: (@Sendable () -> String?)?

    /// `input`: what the host writes; `output`: where the client writes.
    package init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        // A write after the other end went fails with EPIPE instead of raising SIGPIPE in Kore.
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    package func start() throws {
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.end(self.reason?() ?? nil)
            } else {
                self.take(data)
            }
        }
    }

    private func take(_ data: Data) {
        let frames: [Data]
        do {
            frames = try lock.withLock {
                buffer.append(data)
                return try LinkFrame.take(&buffer, max: LinkFrame.outboundMax)
            }
        } catch {
            end("a frame over the limit")
            return
        }
        for frame in frames { continuation.yield(.frame(frame)) }
    }

    package func send(_ payload: Data) {
        let framed = LinkFrame.frame(payload)
        writes.async { [weak self] in
            // What was sent before a close still goes; the write side closes after it.
            guard let self, !self.outputClosed else { return }
            do {
                try self.output.write(contentsOf: framed)
            } catch {
                self.end("the connection broke")
            }
        }
    }

    package func close() { end(nil) }

    /// Touched on `writes` only.
    private var outputClosed = false

    private func end(_ reason: String?) {
        let first = lock.withLock {
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        input.readabilityHandler = nil
        try? input.close()
        writes.async { [self] in
            outputClosed = true
            try? output.close()
        }
        continuation.yield(.closed(reason))
        continuation.finish()
    }
}

/// `ssh <alias> ~/.local/bin/kore-host attach --as <grant>`: the link over SSH's stdin and stdout.
/// The command runs without a login shell, whose PATH often lacks `~/.local/bin`, so kore-host is
/// named by its path. BatchMode keeps SSH from asking for anything; the user's own SSH config and
/// agent do the rest.
package final class SSHTransport: HostTransport, @unchecked Sendable {
    package static let ssh = "/usr/bin/ssh"

    private let process = Process()
    private let pipe: PipeTransport
    private let stderr = Pipe()
    private let lock = NSLock()
    private var said = Data()

    package var events: AsyncStream<TransportEvent> { pipe.events }

    /// Where kore-host is on the box, unless the user says otherwise.
    package static let defaultCommand = "~/.local/bin/kore-host"

    package static func arguments(alias: String, grant: String, command: String = defaultCommand) -> [String] {
        // SSH notices a dead link itself (two missed keepalives, 15 s apart): the box never
        // wakes for a ping.
        ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", alias, command, "attach", "--as", grant]
    }

    package convenience init(alias: String, grant: String, command: String = defaultCommand) {
        self.init(executable: Self.ssh, arguments: Self.arguments(alias: alias, grant: grant, command: command))
    }

    /// Any command that speaks the link on its stdio (`kore-host attach` run here, in a check).
    package init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        pipe = PipeTransport(input: stdout.fileHandleForReading, output: stdin.fileHandleForWriting)
        pipe.reason = { [weak self] in self?.lastWords() }
    }

    package func start() throws {
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.said.append(data)
                if self.said.count > 4096 { self.said = self.said.suffix(2048) }
            }
        }
        try process.run()
        try pipe.start()
    }

    package func send(_ payload: Data) { pipe.send(payload) }

    package func close() {
        pipe.close()
        if process.isRunning { process.terminate() }
    }

    /// Why it ended: ssh's exit status (kore-host attach's own, or ssh's 255) and the last line
    /// either printed, as `ended(status:line:)` writes it.
    private func lastWords() -> String? {
        // A moment for the process to end and its stderr to arrive after stdout closed.
        let end = Date().addingTimeInterval(1)
        while process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.05)
        let text = lock.withLock { String(decoding: said, as: UTF8.self) }
        let line = text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !process.isRunning, process.terminationReason == .exit else { return line }
        return Self.ended(status: process.terminationStatus, line: line)
    }

    /// "exit 3: kore-host isn't running": a link's end with ssh's exit status.
    package static func ended(status: Int32, line: String?) -> String { "exit \(status)" + (line.map { ": " + $0 } ?? "") }

    /// The exit status in a reason `ended` wrote, and the line after it.
    package static func exit(of reason: String?) -> (status: Int32, line: String)? {
        guard let reason, reason.hasPrefix("exit ") else { return nil }
        let rest = reason.dropFirst(5)
        let number = rest.prefix { $0.isNumber || $0 == "-" }
        guard let status = Int32(number) else { return nil }
        let line = rest.dropFirst(number.count).drop { $0 == ":" || $0 == " " }
        return (status, String(line))
    }
}

import Foundation

/// A child process speaking newline-delimited JSON over stdin/stdout. Shared transport
/// for both CLIs; the protocol on top differs (Claude stream-json vs Codex JSON-RPC).
package final class StdioProcess: @unchecked Sendable {
    enum Output: Sendable {
        case line(Data)
        case stderr(String)
        /// Always last, after every stdout line has been delivered.
        case exited(status: Int32)
    }

    let output: AsyncStream<Output>
    // Only touched from the owning session actor (write/close) or Foundation's own
    // handlers, which is why the unchecked Sendable is safe.
    private let process = Process()
    private let stdin: FileHandle
    private let track: CassetteTrack?

    /// Records every CLI started from here into a cassette (phase 12's `--record`). Nil in Kore.
    package static let recorder = HostSetting<CassetteRecorder?>(nil)

    init(executable: URL, arguments: [String], cwd: URL?, environment: [String: String]) throws {
        // A write to a dead child must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdin = stdinPipe.fileHandleForWriting
        let track = Self.recorder.value?.begin(executable: executable, arguments: arguments, cwd: cwd)
        self.track = track

        let (output, sink) = AsyncStream<Output>.makeStream(bufferingPolicy: .unbounded)
        self.output = output

        let (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                chunkSink.finish()
            } else {
                chunkSink.yield(data)
            }
        }
        let (stderrEnded, stderrEnd) = AsyncStream<Void>.makeStream()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrEnd.finish()
            } else {
                let text = String(decoding: data, as: UTF8.self)
                if let track { for line in text.split(separator: "\n") { track.record(.err, String(line)) } }
                sink.yield(.stderr(text))
            }
        }
        let (exits, exitSink) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exitSink.yield(process.terminationStatus)
            exitSink.finish()
        }

        try process.run()

        Task {
            var lines = LineSplitter()
            for await chunk in chunks {
                for line in lines.feed(chunk) {
                    track?.record(.out, String(decoding: line, as: UTF8.self))
                    sink.yield(.line(line))
                }
            }
            if let last = lines.finish() {
                track?.record(.out, String(decoding: last, as: UTF8.self))
                sink.yield(.line(last))
            }
            var status: Int32 = -1
            for await s in exits { status = s }
            // What it last said on stderr (often why it ended) comes before `.exited`. A process
            // it left running can keep stderr open, so not for long.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in stderrEnded {} }
                group.addTask { try? await Task.sleep(for: .milliseconds(200)) }
                await group.next()
                group.cancelAll()
            }
            track?.exited(status)
            sink.yield(.exited(status: status))
            sink.finish()
        }
    }

    func write(_ message: JSONValue) throws {
        var data = try message.encoded()
        track?.record(.in, String(decoding: data, as: UTF8.self))
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    /// Closing stdin lets the child exit cleanly; terminate covers the rest.
    func close() {
        try? stdin.close()
        process.terminate()
    }
}

/// Splits a CLI's stdout into lines on \n. Not Foundation's `lines`, which also breaks on
/// U+2028/U+2029 (JSON strings may hold them unescaped). Only a chunk's new bytes are searched
/// and the buffer is trimmed once per chunk: a reply can be one line of tens of MB (a thread's
/// history) arriving 64 KB at a time. A line keeps a \r before its \n (JSON reads it as space).
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    /// The lines `chunk` completes, in order. Blank ones (spaces, \r) are dropped.
    public mutating func feed(_ chunk: Data) -> [Data] {
        var from = buffer.count
        buffer.append(chunk)
        var lines: [Data] = []
        var start = 0
        while let newline = Self.newline(in: buffer, from: from) {
            let line = buffer[(buffer.startIndex + start)..<(buffer.startIndex + newline)]
            if !Self.blank(line) { lines.append(Data(line)) }
            start = newline + 1
            from = start
        }
        if start > 0 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + start)) }
        return lines
    }

    /// A last line the stream ended without a \n after, if any.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty || Self.blank(buffer[...]) ? nil : buffer
    }

    private static func blank(_ line: Data.SubSequence) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x0D }
    }

    /// The offset of the first \n at or after `offset`.
    private static func newline(in data: Data, from offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        return data.withUnsafeBytes { bytes -> Int? in
            guard let base = bytes.baseAddress, let found = memchr(base + offset, 0x0A, bytes.count - offset) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }
}

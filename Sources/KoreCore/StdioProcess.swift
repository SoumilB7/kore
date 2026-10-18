import Foundation

/// A child process speaking newline-delimited JSON over stdin/stdout. Shared transport
/// for both CLIs; the protocol on top differs (Claude stream-json vs Codex JSON-RPC).
final class StdioProcess: @unchecked Sendable {
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
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                sink.yield(.stderr(String(decoding: data, as: UTF8.self)))
            }
        }
        let (exits, exitSink) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exitSink.yield(process.terminationStatus)
            exitSink.finish()
        }

        try process.run()

        Task {
            // Split on \n ourselves: Foundation's `lines` also breaks on U+2028/U+2029,
            // which JSON strings may legally contain unescaped.
            var buffer = Data()
            for await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { sink.yield(.line(Data(line))) }
                }
            }
            if !buffer.isEmpty { sink.yield(.line(buffer)) }
            var status: Int32 = -1
            for await s in exits { status = s }
            sink.yield(.exited(status: status))
            sink.finish()
        }
    }

    func write(_ message: JSONValue) throws {
        var data = try message.encoded()
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    /// Closing stdin lets the child exit cleanly; terminate covers the rest.
    func close() {
        try? stdin.close()
        process.terminate()
    }
}

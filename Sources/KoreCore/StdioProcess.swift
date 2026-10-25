import Foundation

/// How a CLI's process ended: its exit code, or the signal that ended it (`code` is then the
/// signal's number), as Foundation's `terminationReason` tells them apart.
public struct ProcessEnd: Sendable, Equatable {
    public let code: Int32
    public let signal: Bool

    public init(code: Int32, signal: Bool) {
        self.code = code
        self.signal = signal
    }

    /// "status=0", "signal=15": for logs.
    public var field: (key: String, value: String) { (signal ? "signal" : "status", String(code)) }
}

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

    /// Every child still running, for `closeAll`.
    static let running = Running()

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
        let key = ObjectIdentifier(self)
        let ending = ending
        process.terminationHandler = { process in
            // `terminationStatus` is the exit code, or the signal's number when one ended it.
            ending.set(ProcessEnd(code: process.terminationStatus, signal: process.terminationReason == .uncaughtSignal))
            Self.running.remove(key)
            ChildReaper.shared.forget(process.processIdentifier)
            exitSink.yield(process.terminationStatus)
            exitSink.finish()
        }

        // Foundation starts each child in a process group of its own, so the group is the CLI
        // and what it runs, and nothing else.
        Self.running.insert(self, key)
        do { try process.run() } catch {
            Self.running.remove(key)
            throw error
        }
        ChildReaper.shared.watch(process.processIdentifier)

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

    var isRunning: Bool { process.isRunning }
    var pid: pid_t { process.processIdentifier }
    /// How it ended, once it has.
    var end: ProcessEnd? { ending.value }
    private let ending = Ending()

    private final class Ending: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProcessEnd?
        var value: ProcessEnd? { lock.withLock { stored } }
        func set(_ end: ProcessEnd) { lock.withLock { stored = end } }
    }

    /// Closes stdin and sends SIGTERM to the child and its process group. Both CLIs exit within
    /// a second or two of SIGTERM, ending their tool processes and keeping their transcripts
    /// whole; on EOF alone `claude -p` would first finish its turn. Still running after `grace`,
    /// the child and every process under it get SIGKILL.
    func close(grace: Duration = .seconds(5)) {
        try? stdin.close()
        send(SIGTERM)
        let process = process, wait = Int(grace / .milliseconds(1))
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(wait)) {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            let all = Self.tree(pid)
            kill(-pid, SIGKILL)
            for pid in all { kill(pid, SIGKILL) }
        }
    }

    /// Closes every child (quitting). Waits up to `limit` for them to exit, so their last output
    /// still has a reader; `ChildReaper` ends any left once Kore has gone.
    package static func closeAll(waiting limit: Duration = .milliseconds(500)) {
        close(running.all, waiting: limit)
    }

    /// Everything under the children ends too: background shells, monitors and agents' tools
    /// run in process groups of their own, which the children's group signal misses, and would
    /// outlive Kore under launchd. Taken before any signal, while they are still under a child.
    static func close(_ all: [StdioProcess], waiting limit: Duration) {
        let under = all.filter(\.isRunning).flatMap { tree($0.process.processIdentifier).dropLast() }
        for child in all { child.close() }
        for pid in under { kill(-pid, SIGTERM); kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + limit
        while all.contains(where: \.isRunning) || under.contains(where: alive), ContinuousClock.now < deadline {
            usleep(10_000)
        }
        for pid in under where alive(pid) { kill(pid, SIGKILL) }
    }

    /// Running, not a zombie (one that has exited runs nothing).
    private static func alive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return !(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == SZOMB)
    }

    /// Signals the child and its group, only while it is running: once reaped, its pid may be
    /// another program's.
    private func send(_ signal: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(-pid, signal)
        kill(pid, signal)
    }

    /// `pid` and every process under it, deepest first. Taken before killing: a killed parent's
    /// children move to launchd.
    static func tree(_ pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        _ = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return buffer.filter { $0 > 0 }.flatMap(tree) + [pid]
    }

    final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var children: [ObjectIdentifier: StdioProcess] = [:]

        var all: [StdioProcess] { lock.withLock { Array(children.values) } }
        func contains(_ child: StdioProcess) -> Bool { lock.withLock { children[ObjectIdentifier(child)] != nil } }
        func insert(_ child: StdioProcess, _ key: ObjectIdentifier) { lock.withLock { children[key] = child } }
        func remove(_ key: ObjectIdentifier) { _ = lock.withLock { children.removeValue(forKey: key) } }
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

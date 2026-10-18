import Foundation

/// Kore's own diagnostic logs, one file per name in `~/Library/Logs/Kore` (`agents.log`, …).
/// One line per event: an ISO timestamp, a tab, the event's name, then space-separated
/// `key=value` pairs (a value with spaces or quotes is quoted):
///
///   2026-10-23T11:28:25.671Z	status cli=claude chat=4fb9… agent=toolu_01… from=running to=stopped source="tool_result error"
///
/// Lines are buffered and written off the main thread about once a second (at once past 256);
/// past `limit` a file moves to `<name>.log.1`, replacing the one before. `KORE_LOG_DIR=<path>`
/// writes elsewhere, `KORE_LOG_DIR=off` nowhere; test runs write nowhere unless they make a log
/// of their own (`init(url:)`).
public final class KoreLog: @unchecked Sendable {
    private let url: URL?
    private let limit: UInt64
    private let queue: DispatchQueue
    // Touched on `queue` only.
    private var pending: [(Date, String)] = []
    private var scheduled = false
    private var handle: FileHandle?
    private var size: UInt64 = 0

    public init(url: URL?, limit: UInt64 = 5 << 20) {
        self.url = url
        self.limit = limit
        queue = DispatchQueue(label: "Kore.log.\(url?.lastPathComponent ?? "off")", qos: .utility)
    }

    public var enabled: Bool { url != nil }

    /// The log `<name>.log` in Kore's logs folder: one writer per name.
    public static func named(_ name: String) -> KoreLog {
        lock.withLock {
            if let log = logs[name] { return log }
            let log = KoreLog(url: folder?.appendingPathComponent(name + ".log"))
            logs[name] = log
            return log
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var logs: [String: KoreLog] = [:]

    private static let folder: URL? = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["KORE_LOG_DIR"] {
            return ["", "0", "off", "no"].contains(path.lowercased()) ? nil : URL(fileURLWithPath: path)
        }
        if isTestProcess { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kore")
    }()

    /// A test run or a storyline host: it keeps nothing in the owner's folders unless told where.
    package static let isTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        let process = ProcessInfo.processInfo.processName
        return ["xctest", "swiftpm-testing-helper", "kore-storylines"].contains(process) || Bundle.main.bundlePath.hasSuffix(".xctest")
            || env["XCTestConfigurationFilePath"] != nil
    }()

    /// One event; fields with no value are left out.
    public func write(_ event: String, _ fields: KeyValuePairs<String, String?>) {
        guard url != nil else { return }
        var line = event
        for (key, value) in fields {
            guard let value else { continue }
            line += " " + key + "=" + Self.value(value)
        }
        let now = Date()
        let done = line
        queue.async { [self] in
            pending.append((now, done))
            if pending.count >= 256 {
                flushNow()
            } else if !scheduled {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 1) { [self] in flushNow() }
            }
        }
    }

    /// Waits until every line so far is written.
    public func sync() {
        queue.sync { flushNow() }
    }

    /// Bare when it's one word; else quoted, on one line, inner quotes made single.
    static func value(_ text: String) -> String {
        let flat = String(text.prefix(120).map { $0 == "\"" ? "'" : $0.isNewline || $0 == "\t" ? " " : $0 })
        return flat.isEmpty || flat.contains(" ") || flat.contains("'") || flat.contains("=") ? "\"" + flat + "\"" : flat
    }

    private func flushNow() {
        scheduled = false
        guard let url, !pending.isEmpty else { return }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = Data(pending.map { stamp.string(from: $0.0) + "\t" + $0.1 + "\n" }.joined().utf8)
        pending.removeAll(keepingCapacity: true)
        if handle == nil { open(url) }
        if size > 0, size + UInt64(data.count) > limit {
            try? handle?.close()
            handle = nil
            let older = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: older)
            try? FileManager.default.moveItem(at: url, to: older)
            open(url)
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func open(_ url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }
}

import Foundation

/// Kore's own diagnostic logs, one file per name in `~/Library/Logs/Kore` (`KoreFolders.logs`:
/// `agents.log`, …).
/// One line per event, the same shape in every log (and kore-host's journal, `HostJournal`): an
/// ISO timestamp, a level, the event's name, then space-separated `key=value` pairs. A value with
/// a space, a quote, `=` or `\` is quoted, its quotes and backslashes escaped with `\`:
///
///   2026-10-23T11:28:25.671Z info status cli=claude chat=4fb9… agent=toolu_01… to=stopped source="tool_result error"
///   2026-10-23T11:29:02.004Z info turn id=a91f03 chat=4fb9… cli=claude outcome=completed dur_ms=5120 tools=3
///
/// A finished unit of work (a turn, a carry, a link) is one wide line, its length in `dur_ms`.
/// Only keys in `keys` are written: ids, counts, kinds and times, never a message, a title or a
/// file's text. Paths are cut to their last part and a hash, and anything shaped like a token is
/// redacted (`safe`).
///
/// Levels: debug, info, warn, error; info and up are written unless `KORE_LOG_LEVEL` says
/// otherwise (`KORE_LOG_LEVEL=debug` adds the interface's noisy events). Lines are buffered and
/// written off the main thread about once a second (at once past 256); past `limit` a file moves
/// to `<name>.log.1`, replacing the one before. The folder keeps a week and 50 MB at most
/// (`prune`: before the first log opens, and again whenever a log moves aside). `KORE_LOG_DIR=<path>`
/// writes elsewhere, `KORE_LOG_DIR=off` nowhere; test runs write nowhere unless they make a log
/// of their own (`init(url:)`).
public final class KoreLog: @unchecked Sendable {
    public enum Level: Int, Comparable, Sendable, CaseIterable {
        case debug, info, warn, error

        public var name: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .warn: "warn"
            case .error: "error"
            }
        }

        public init?(name: String) {
            guard let level = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
            self = level
        }

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    private let url: URL?
    private let limit: UInt64
    private let prunes: Bool
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    /// The lowest level written.
    public let level: Level
    // Touched on `queue` only.
    private var pending: [(Date, Level, String)] = []
    private var scheduled = false
    private var handle: FileHandle?
    private var size: UInt64 = 0
    // Under `throttleLock`.
    private let throttleLock = NSLock()
    private var throttle = LogThrottle()

    /// `prunes`: the folder is Kore's own, kept by `prune` whenever this log moves aside.
    /// `now`: the clock lines are stamped and throttled by (tests move it by hand).
    public init(
        url: URL?, limit: UInt64 = 5 << 20, level: Level = KoreLog.threshold, prunes: Bool = false, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.limit = limit
        self.level = level
        self.prunes = prunes
        self.now = now
        queue = DispatchQueue(label: "Kore.log.\(url?.lastPathComponent ?? "off")", qos: .utility)
    }

    public var enabled: Bool { url != nil }

    /// Whether a line at `level` would be written.
    public func writes(_ level: Level) -> Bool { url != nil && level >= self.level }

    /// The lowest level the app's logs write: `KORE_LOG_LEVEL` (debug, info, warn, error), else info.
    public static let threshold: Level = ProcessInfo.processInfo.environment["KORE_LOG_LEVEL"].flatMap(Level.init(name:)) ?? .info

    /// The log `<name>.log` in Kore's logs folder: one writer per name.
    public static func named(_ name: String) -> KoreLog {
        lock.withLock {
            if let log = logs[name] { return log }
            if logs.isEmpty, let folder { prune(folder) }
            let log = KoreLog(url: folder?.appendingPathComponent(name + ".log"), prunes: true)
            logs[name] = log
            return log
        }
    }

    /// Logs no version writes any more: the folder lets them go whenever it's pruned.
    static let retired: Set<String> = ["relay", "remote-activity", "phone-addon"]

    /// What the logs folder keeps: nothing older than `ttl`, and `cap` bytes at most, and nothing
    /// of a retired log. A live log begun before `ttl` moves to `.1`, to go in turn; past `cap` the
    /// oldest files go first. `live` false (a log moving aside while the others are open) leaves
    /// every live `.log` where it is and lets only what's moved aside go.
    static func prune(_ folder: URL, ttl: TimeInterval = 7 * 86400, cap: UInt64 = 50 << 20, now: Date = Date(), live: Bool = true) {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        func entries() -> [(url: URL, modified: Date, created: Date, size: UInt64)] {
            ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).compactMap { url in
                guard url.lastPathComponent.contains(".log"), let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.contentModificationDate ?? now, values.creationDate ?? now, UInt64(values.fileSize ?? 0))
            }
        }
        for entry in entries() where retired.contains(String(entry.url.lastPathComponent.prefix { $0 != "." })) {
            try? files.removeItem(at: entry.url)
        }
        if live {
            for entry in entries() where entry.url.pathExtension == "log" && now.timeIntervalSince(entry.created) > ttl {
                let older = entry.url.appendingPathExtension("1")
                try? files.removeItem(at: older)
                try? files.moveItem(at: entry.url, to: older)
            }
        }
        let all = entries()
        var kept = all.filter { live || $0.url.pathExtension != "log" }.sorted { $0.modified < $1.modified }
        kept.removeAll { entry in
            guard now.timeIntervalSince(entry.modified) > ttl else { return false }
            try? files.removeItem(at: entry.url)
            return true
        }
        // Live logs count against the cap whether or not they may go.
        var total = kept.reduce(0) { $0 + $1.size } + (live ? 0 : all.filter { $0.url.pathExtension == "log" }.reduce(0) { $0 + $1.size })
        for entry in kept where total > cap {
            try? files.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var logs: [String: KoreLog] = [:]

    static let folder: URL? = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["KORE_LOG_DIR"] {
            return ["", "0", "off", "no"].contains(path.lowercased()) ? nil : URL(fileURLWithPath: path)
        }
        if keepsNothing { return nil }
        return KoreFolders.logs
    }()

    /// A test run or a storyline host: it keeps nothing in the owner's folders unless told where.
    package static let isTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        let process = ProcessInfo.processInfo.processName
        // A gate runs them side by side under names of their own (kore-storylines-2,
        // swiftpm-testing-helper-KoreUITests, …), each its own defaults domain: the same processes.
        return process == "xctest" || process.hasPrefix("swiftpm-testing-helper") || process.hasPrefix("kore-storylines")
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || env["XCTestConfigurationFilePath"] != nil
    }()

    /// A test run, a storyline host, or kore-host on a box: none keeps the Mac's bookkeeping (these
    /// logs, the usage index, plan snapshots, sessions), which only the Mac's app reads.
    package static let keepsNothing: Bool = isTestProcess || ProcessInfo.processInfo.processName == "kore-host"

    // MARK: Writing

    /// One info event; fields with no value, or a key not in `keys`, are left out.
    public func write(_ event: String, _ fields: KeyValuePairs<String, String?>) {
        write(.info, event, fields)
    }

    /// One event at `level`.
    public func write(_ level: Level, _ event: String, _ fields: KeyValuePairs<String, String?>) {
        guard writes(level) else { return }
        enqueue(now(), level, Self.body(event, Self.safe(fields)))
    }

    /// One event whose fields are put together as it goes.
    public func write(_ level: Level, _ event: String, _ fields: [(key: String, value: String?)]) {
        guard writes(level) else { return }
        enqueue(now(), level, Self.body(event, Self.safe(fields)))
    }

    /// An event that can come many times a second (a window's occlusion, the screens changing):
    /// one info line per `every` seconds at most for each `key` (the event's name by default), its
    /// `n` the times it came since the last line, this one included. At debug every one is written.
    public func throttled(_ event: String, key: String? = nil, every: TimeInterval = 10, _ fields: KeyValuePairs<String, String?> = [:]) {
        if writes(.debug) { return write(.debug, event, fields) }
        guard writes(.info) else { return }
        let at = now()
        guard let count = throttleLock.withLock({ throttle.pass(key ?? event, at: at, every: every) }) else { return }
        enqueue(at, .info, Self.body(event, Self.safe(fields) + [("n", String(count))]))
    }

    private func enqueue(_ at: Date, _ level: Level, _ line: String) {
        queue.async { [self] in
            pending.append((at, level, line))
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

    /// Writes every log's pending lines: at quit, so its last second isn't lost.
    public static func syncAll() {
        for log in lock.withLock({ Array(logs.values) }) { log.sync() }
    }

    // MARK: The line

    /// `event key=value…`: what follows a line's timestamp and level, and kore-host's journal
    /// line as its own sinks see it.
    public static func body(_ event: String, _ fields: [(String, String)]) -> String {
        var line = event
        for (key, value) in fields { line += " " + key + "=" + Self.value(value) }
        return line
    }

    /// A whole line: `<ISO time> <level> <body>`.
    public static func line(at date: Date, _ level: Level, _ body: String, stamp: ISO8601DateFormatter = stamper()) -> String {
        stamp.string(from: date) + " " + level.name + " " + body
    }

    /// UTC to the millisecond, as every line starts.
    public static func stamper() -> ISO8601DateFormatter {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return stamp
    }

    /// Bare when it's one word; else quoted on one line, a quote or backslash in it escaped with
    /// `\`. 120 characters at most.
    public static func value(_ text: String) -> String {
        let flat = String(text.prefix(120).map { $0.isNewline || $0 == "\t" ? " " : $0 })
        let plain = !flat.isEmpty && !flat.contains { $0 == " " || $0 == "\"" || $0 == "=" || $0 == "\\" }
        if plain { return flat }
        return "\"" + flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: What a line may say

    /// The keys a line may carry: ids, counts, kinds, states and times. A key that isn't here is
    /// dropped, so a title, a message or a free-text detail never reaches a log by a new field.
    public static let keys: Set<String> = [
        // Who and where.
        "cli", "chat", "turn", "id", "agent", "parent", "pid", "host", "box", "device", "node", "grant", "login", "tier", "caller",
        "group", "folder", "path", "tab", "provider", "model", "phone", "by", "alias", "old", "target",
        // What happened.
        "action", "kind", "type", "mode", "method", "state", "from", "to", "source", "via", "trigger", "result", "outcome", "reason",
        "cause", "code", "errno", "error", "end", "route", "launch", "read", "what", "item", "command", "step", "limit", "on", "off",
        "ok", "open", "live", "enabled", "custom", "visible", "active", "shown", "asked", "late", "corrected", "duplicate", "following",
        "immediate", "unfolded", "joined", "held", "kept", "made", "prepared", "resumed", "dropped", "how", "claim", "control", "all",
        "sheet", "used", "kore", "version", "build", "last_event", "signal", "status", "stderr", "at", "video", "cmd",
        // How much and how long.
        "n", "count", "rows", "lines", "bytes", "files", "tabs", "chats", "items", "kinds", "sections", "tools", "agents", "in_tok",
        "out_tok", "cache_tok", "ms", "s", "dur_ms", "busy", "shown_ms", "quiet", "attempt", "tried", "stderr_bytes", "size", "height",
        "offset", "tops", "first_top", "remounts", "drawn", "ak_height", "ak_y", "ak_visible", "mb", "now", "layers", "images", "heap",
        "commands", "axis", "snap", "aim",
    ]

    /// Keys whose value can be a path: only its last part goes in, with a hash of the whole to
    /// tell two apart.
    static let pathKeys: Set<String> = ["path", "folder"]

    /// `fields` as they go in a line: dropped when empty or not in `keys`, paths cut down, an
    /// email and anything token-shaped hidden.
    public static func safe(_ fields: KeyValuePairs<String, String?>) -> [(String, String)] {
        safe(fields.map { (key: $0.key, value: $0.value) })
    }

    public static func safe(_ fields: [(key: String, value: String?)]) -> [(String, String)] {
        fields.compactMap { key, value in value.flatMap { safe(key, $0) }.map { (key, $0) } }
    }

    static func safe(_ key: String, _ value: String) -> String? {
        guard keys.contains(key) else { return nil }
        if pathKeys.contains(key), value.contains("/") {
            let last = value.split(separator: "/").last.map(String.init) ?? "/"
            return redacted(last) + "#" + hash(value)
        }
        if value.contains("@"), value.contains(".") { return "h" + hash(value) }
        return redacted(value)
    }

    /// API keys, GitHub and Slack tokens, bearer headers, AWS key ids and JWTs, as `[redacted]`.
    public static func redacted(_ text: String) -> String {
        let text = String(text.prefix(512))
        // Every shape has one of these: most values (ids, counts) are let through unread.
        guard text.contains(where: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " || $0 == "A" }) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return tokens.stringByReplacingMatches(in: text, range: range, withTemplate: "[redacted]")
    }

    private static let tokens: NSRegularExpression = {
        let shapes = [
            #"sk-[A-Za-z0-9_\-]{6,}"#, #"gh[pousr]_[A-Za-z0-9]{6,}"#, #"github_pat_[A-Za-z0-9_]{6,}"#, #"xox[abprs]-[A-Za-z0-9\-]{6,}"#,
            #"(?i:bearer)\s+[A-Za-z0-9._~+/=\-]+"#, #"AKIA[0-9A-Z]{12,}"#, #"eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]*)?"#,
        ]
        // The shapes are fixed: they compile.
        return try! NSRegularExpression(pattern: shapes.joined(separator: "|"))
    }()

    /// Six hex digits of FNV-1a: the same every run, so a path's lines can be matched, and
    /// nothing of it read back.
    public static func hash(_ text: String) -> String {
        var value: UInt32 = 2_166_136_261
        for byte in text.utf8 { value = (value ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%06x", value & 0xFF_FFFF)
    }

    // MARK: Files

    private func flushNow() {
        scheduled = false
        guard let url, !pending.isEmpty else { return }
        let stamp = Self.stamper()
        let data = Data(pending.map { Self.line(at: $0.0, $0.1, $0.2, stamp: stamp) + "\n" }.joined().utf8)
        pending.removeAll(keepingCapacity: true)
        if handle == nil { open(url) }
        if size > 0, size + UInt64(data.count) > limit {
            try? handle?.close()
            handle = nil
            let older = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: older)
            try? FileManager.default.moveItem(at: url, to: older)
            // A busy log moves aside many times a launch: the folder is kept within its week and
            // its cap each time, not only as the app starts.
            if prunes { Self.prune(url.deletingLastPathComponent(), now: now(), live: false) }
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

/// One line per `every` seconds for a noisy event: the first goes at once, those after it within
/// `every` are counted, and the next one past it goes with the count (`n`, itself included).
public struct LogThrottle: Sendable {
    private var last: [String: (at: Date, held: Int)] = [:]

    public init() {}

    /// The `n` to write now, or nil to hold this one back.
    public mutating func pass(_ key: String, at now: Date, every: TimeInterval) -> Int? {
        if let seen = last[key], now.timeIntervalSince(seen.at) < every {
            last[key] = (seen.at, seen.held + 1)
            return nil
        }
        let count = (last[key]?.held ?? 0) + 1
        last[key] = (now, 0)
        return count
    }
}
